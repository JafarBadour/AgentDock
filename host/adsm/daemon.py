"""ADSM asyncio daemon — Unix socket control plane."""

from __future__ import annotations

import asyncio
import json
import os
import signal
import sys
from typing import Any, Optional

from . import paths, protocol, scheduler
from . import transcript as transcript_store
from .worker import Worker


class Daemon:
    def __init__(self) -> None:
        self.workers: dict[str, Worker] = {}
        self._seq = 0
        self._subscribers: dict[str, set[asyncio.StreamWriter]] = {}
        self._global_subscribers: set[asyncio.StreamWriter] = set()
        self._event_log: dict[str, list[dict[str, Any]]] = {}
        # In-flight `rpc.chunk` transfers: (writer_id, req_id) → buffer.
        self._chunk_bufs: dict[tuple[int, Any], dict[str, Any]] = {}
        self._server: Optional[asyncio.AbstractServer] = None
        self.scheduler = scheduler.Scheduler(self)

    async def start(self) -> None:
        paths.ensure_layout()
        sock = paths.socket_path()
        if sock.exists():
            try:
                sock.unlink()
            except OSError:
                pass

        self._server = await asyncio.start_unix_server(
            self._on_client,
            path=str(sock),
            limit=protocol.STREAM_LIMIT,
        )
        try:
            os.chmod(sock, 0o600)
        except OSError:
            pass

        pid = paths.pid_path()
        pid.write_text(str(os.getpid()), encoding="utf-8")

        # Adopt existing session dirs (status only until ensure attaches).
        for d in paths.sessions_dir().iterdir():
            if d.is_dir():
                chat_id = d.name
                if chat_id not in self.workers:
                    w = Worker(
                        chat_id,
                        emit=self._worker_emit,
                        set_status=self._set_status,
                    )
                    self.workers[chat_id] = w
                    import subprocess

                    alive = await asyncio.to_thread(
                        lambda cid=chat_id: subprocess.run(
                            [
                                "tmux",
                                "has-session",
                                "-t",
                                paths.tmux_session_name(cid),
                            ],
                            capture_output=True,
                        ).returncode
                        == 0
                    )
                    w.status = (
                        protocol.STATUS_IDLE if alive else protocol.STATUS_DEAD
                    )

        self.scheduler.start()

        async with self._server:
            await self._server.serve_forever()

    async def _set_status(
        self, chat_id: str, status: str, error: Optional[str]
    ) -> None:
        w = self.workers.get(chat_id)
        if w:
            w.status = status
            if error is not None:
                w.last_error = error
        await self._patch_agent_record(chat_id, status=status, error=error)

    async def _patch_agent_record(
        self,
        chat_id: str,
        *,
        status: Optional[str] = None,
        error: Optional[str] = None,
        acp_session_id: Optional[str] = None,
        model_id: Optional[str] = None,
        cwd: Optional[str] = None,
        binary: Optional[str] = None,
        provider: Optional[str] = None,
    ) -> None:
        path = paths.agent_record_path(chat_id)
        data: dict[str, Any] = {}
        if path.exists():
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                data = {"id": chat_id}
        else:
            data = {"id": chat_id}
        if status is not None:
            data["status"] = status
        if acp_session_id is not None:
            data["acp_session_id"] = acp_session_id
        if model_id is not None:
            data["model_id"] = model_id
        if cwd:
            data["cwd"] = cwd
        if binary:
            data["binary"] = binary
        if provider:
            data["provider"] = provider
        if error is not None:
            data["last_error"] = error
        from datetime import datetime, timezone

        data["updated_at"] = datetime.now(timezone.utc).isoformat()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2), encoding="utf-8")

    async def _worker_emit(self, payload: dict[str, Any]) -> None:
        chat_id = str(payload.get("chatId") or "")
        kind = str(payload.get("kind") or "status")
        self._seq += 1
        seq = self._seq
        event = protocol.event(chat_id, seq, kind, **{
            k: v for k, v in payload.items() if k not in ("chatId", "kind")
        })
        log = self._event_log.setdefault(chat_id, [])
        log.append(event)
        if len(log) > 5000:
            del log[:1000]

        dead: list[asyncio.StreamWriter] = []
        targets = set(self._global_subscribers)
        targets |= self._subscribers.get(chat_id, set())
        raw = protocol.encode(event)
        for w in targets:
            try:
                w.write(raw)
                await w.drain()
            except Exception:  # noqa: BLE001
                dead.append(w)
        for w in dead:
            self._drop_writer(w)

        # Keep agent json in sync for acp session id.
        if kind == "session":
            sid = payload.get("acpSessionId")
            if sid:
                await self._patch_agent_record(
                    chat_id, acp_session_id=str(sid)
                )

    def _drop_writer(self, writer: asyncio.StreamWriter) -> None:
        self._global_subscribers.discard(writer)
        for s in self._subscribers.values():
            s.discard(writer)
        wid = id(writer)
        stale = [k for k in self._chunk_bufs if k[0] == wid]
        for k in stale:
            self._chunk_bufs.pop(k, None)

    async def _on_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            while True:
                try:
                    line = await reader.readline()
                except ValueError as e:
                    # Still oversized relative to the reader limit — drop the
                    # client cleanly instead of taking down the task uncaught.
                    writer.write(
                        protocol.encode(
                            protocol.err(
                                None,
                                -32600,
                                f"NDJSON line too large: {e}",
                            )
                        )
                    )
                    await writer.drain()
                    break
                if not line:
                    break
                try:
                    msg = protocol.decode_line(line.decode("utf-8", "replace"))
                except Exception as e:  # noqa: BLE001
                    writer.write(
                        protocol.encode(
                            protocol.err(None, -32700, f"parse error: {e}")
                        )
                    )
                    await writer.drain()
                    continue
                if msg is None:
                    continue
                await self._dispatch(msg, writer)
        finally:
            self._drop_writer(writer)
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:  # noqa: BLE001
                pass

    async def _dispatch(
        self, msg: dict[str, Any], writer: asyncio.StreamWriter
    ) -> None:
        req_id = msg.get("id")
        method = msg.get("method")
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}

        try:
            if method == protocol.CHUNK_METHOD:
                try:
                    assembled = self._ingest_chunk(writer, params)
                except Exception as e:  # noqa: BLE001
                    rid = params.get("reqId")
                    self._chunk_bufs.pop((id(writer), rid), None)
                    writer.write(
                        protocol.encode(protocol.err(rid, -32000, str(e)))
                    )
                    await writer.drain()
                    return
                if assembled is None:
                    # Intermediate chunk — no reply until the transfer completes.
                    return
                await self._dispatch(assembled, writer)
                return

            if method == "ping":
                result: Any = {"ok": True, "version": protocol.VERSION}
            elif method == "daemon.status":
                result = {
                    "pid": os.getpid(),
                    "workers": len(self.workers),
                    "seq": self._seq,
                    "version": protocol.VERSION,
                }
            elif method == "agents.list":
                result = {
                    "agents": [w.snapshot() for w in self.workers.values()]
                }
            elif method == "agents.ensure":
                result = await self._ensure(params)
            elif method == "agents.stop":
                result = await self._stop(params, delete=False)
            elif method == "agents.delete":
                result = await self._stop(params, delete=True)
            elif method == "session.subscribe":
                result = await self._subscribe(params, writer)
            elif method == "session.prompt":
                result = await self._prompt(params)
            elif method == "session.cancel":
                result = await self._cancel(params)
            elif method == "session.respond_permission":
                result = await self._respond_permission(params)
            elif method == "session.set_mode":
                result = await self._set_mode(params)
            elif method == "session.set_model":
                result = await self._set_model(params)
            elif method == "session.refresh_models":
                result = await self._refresh_models(params)
            elif method == "schedules.list":
                result = {"schedules": scheduler.list_jobs()}
            elif method == "schedules.upsert":
                result = await self._schedules_upsert(params)
            elif method == "schedules.delete":
                result = await self._schedules_delete(params)
            elif method == "schedules.run_now":
                result = await self._schedules_run_now(params)
            elif method == "transcript.pull":
                result = await self._transcript_pull(params)
            elif method == "transcript.sync":
                result = await self._transcript_sync(params)
            else:
                writer.write(
                    protocol.encode(
                        protocol.err(
                            req_id, -32601, f"Method not found: {method}"
                        )
                    )
                )
                await writer.drain()
                return

            writer.write(protocol.encode(protocol.ok(req_id, result)))
            await writer.drain()
        except Exception as e:  # noqa: BLE001
            writer.write(
                protocol.encode(protocol.err(req_id, -32000, str(e)))
            )
            await writer.drain()

    def _ingest_chunk(
        self, writer: asyncio.StreamWriter, params: dict[str, Any]
    ) -> Optional[dict[str, Any]]:
        """Buffer an `rpc.chunk` piece; return the full request when complete."""
        req_id = params.get("reqId")
        if req_id is None:
            raise ValueError("rpc.chunk missing reqId")
        try:
            index = int(params.get("i"))
            total = int(params.get("n"))
        except (TypeError, ValueError) as e:
            raise ValueError(f"rpc.chunk bad i/n: {e}") from e
        if total < 1 or index < 0 or index >= total:
            raise ValueError(f"rpc.chunk out of range i={index} n={total}")
        data = params.get("data")
        if not isinstance(data, str):
            raise ValueError("rpc.chunk data must be a string")
        encoding = str(params.get("encoding") or "base64")

        key = (id(writer), req_id)
        buf = self._chunk_bufs.get(key)
        if buf is None:
            buf = {
                "n": total,
                "encoding": encoding,
                "parts": [None] * total,
            }
            self._chunk_bufs[key] = buf
        elif buf["n"] != total:
            self._chunk_bufs.pop(key, None)
            raise ValueError("rpc.chunk n mismatch mid-transfer")

        parts: list[Any] = buf["parts"]
        parts[index] = data
        if any(p is None for p in parts):
            return None

        self._chunk_bufs.pop(key, None)
        return protocol.assemble_chunk_payload(
            [str(p) for p in parts],
            encoding=str(buf.get("encoding") or encoding),
        )

    def _worker(self, chat_id: str) -> Worker:
        w = self.workers.get(chat_id)
        if w is None:
            w = Worker(
                chat_id, emit=self._worker_emit, set_status=self._set_status
            )
            self.workers[chat_id] = w
        return w

    async def _ensure(self, params: dict[str, Any]) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        if not chat_id:
            raise ValueError("chatId required")
        w = self._worker(chat_id)
        cwd = str(params.get("cwd") or "")
        binary = str(params.get("binary") or "")
        provider = str(params.get("provider") or "cursor")
        snap = await w.ensure(
            cwd=cwd,
            binary=binary,
            provider=provider,
            api_key=params.get("apiKey"),
            full_access=bool(params.get("fullAccess", True)),
            resume_session_id=params.get("resumeSessionId"),
            mcp_servers=params.get("mcpServers") or [],
            mode=params.get("mode"),
            model_id=params.get("modelId"),
            permission_ask=bool(params.get("permissionAsk", False)),
        )
        await self._patch_agent_record(
            chat_id,
            status=snap.get("status"),
            acp_session_id=snap.get("acpSessionId"),
            model_id=snap.get("modelId"),
            cwd=cwd or None,
            binary=binary or None,
            provider=provider or None,
        )
        return snap

    async def _stop(
        self, params: dict[str, Any], *, delete: bool
    ) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        w = self.workers.get(chat_id)
        if w:
            await w.stop(delete_files=delete)
            if delete:
                self.workers.pop(chat_id, None)
                rec = paths.agent_record_path(chat_id)
                if rec.exists():
                    rec.unlink(missing_ok=True)
                transcript_store.clear_messages(chat_id)
        return {"ok": True}

    async def _subscribe(
        self, params: dict[str, Any], writer: asyncio.StreamWriter
    ) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        after = int(params.get("afterSeq") or 0)
        if chat_id:
            self._subscribers.setdefault(chat_id, set()).add(writer)
            log = self._event_log.get(chat_id, [])
            for ev in log:
                seq = (ev.get("params") or {}).get("seq", 0)
                if seq > after:
                    writer.write(protocol.encode(ev))
            await writer.drain()
        else:
            self._global_subscribers.add(writer)
        w = self.workers.get(chat_id) if chat_id else None
        return {
            "subscribed": True,
            "seq": self._seq,
            "agent": w.snapshot() if w else None,
        }

    async def _prompt(self, params: dict[str, Any]) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        text = str(params.get("text") or "")
        images = params.get("images") or []
        if not isinstance(images, list):
            images = []
        w = self.workers.get(chat_id)
        if not w:
            raise RuntimeError("unknown chatId — call agents.ensure first")
        return await w.prompt(
            text,
            images=images,
            user_message_id=(
                str(params["userMessageId"])
                if params.get("userMessageId")
                else None
            ),
            user_created_at=(
                str(params["userCreatedAt"])
                if params.get("userCreatedAt")
                else None
            ),
        )

    async def _transcript_pull(self, params: dict[str, Any]) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        if not chat_id:
            raise ValueError("chatId required")
        return {"messages": transcript_store.list_messages(chat_id)}

    async def _transcript_sync(self, params: dict[str, Any]) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        if not chat_id:
            raise ValueError("chatId required")
        raw = params.get("messages") or []
        if not isinstance(raw, list):
            raise ValueError("messages must be a list")
        changed = transcript_store.upsert_messages(
            chat_id, [m for m in raw if isinstance(m, dict)]
        )
        return {
            "ok": True,
            "changed": changed,
            "count": len(transcript_store.list_messages(chat_id)),
        }

    async def _cancel(self, params: dict[str, Any]) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        w = self.workers.get(chat_id)
        if w:
            await w.cancel()
        return {"ok": True}

    async def _respond_permission(
        self, params: dict[str, Any]
    ) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        request_id = str(params.get("requestId") or "")
        option_id = str(params.get("optionId") or "")
        w = self.workers.get(chat_id)
        if not w:
            raise RuntimeError("unknown chatId")
        await w.respond_permission(request_id, option_id)
        return {"ok": True}

    async def _set_mode(self, params: dict[str, Any]) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        mode = str(params.get("mode") or params.get("modeId") or "")
        w = self.workers.get(chat_id)
        if not w:
            raise RuntimeError("unknown chatId")
        await w.set_mode(mode)
        return w.snapshot()

    async def _set_model(self, params: dict[str, Any]) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        model_id = str(params.get("modelId") or "")
        w = self.workers.get(chat_id)
        if not w:
            raise RuntimeError("unknown chatId")
        await w.set_model(model_id)
        await self._patch_agent_record(chat_id, model_id=model_id)
        return w.snapshot()

    async def _refresh_models(self, params: dict[str, Any]) -> dict[str, Any]:
        chat_id = str(params.get("chatId") or "")
        if not chat_id:
            raise ValueError("chatId required")
        w = self._worker(chat_id)
        return await w.refresh_models(
            mcp_servers=params.get("mcpServers") or [],
        )

    async def _schedules_upsert(self, params: dict[str, Any]) -> dict[str, Any]:
        job = params.get("job") if isinstance(params.get("job"), dict) else params
        if not isinstance(job, dict):
            raise ValueError("job object required")
        saved = scheduler.save_job(job)
        return {"schedule": saved}

    async def _schedules_delete(self, params: dict[str, Any]) -> dict[str, Any]:
        job_id = str(params.get("id") or params.get("jobId") or "")
        if not job_id:
            raise ValueError("id required")
        ok = scheduler.delete_job(job_id)
        return {"ok": ok}

    async def _schedules_run_now(self, params: dict[str, Any]) -> dict[str, Any]:
        job_id = str(params.get("id") or params.get("jobId") or "")
        job = scheduler.load_job(job_id)
        if not job:
            raise RuntimeError("unknown schedule id")
        updated = await self.scheduler.run_job(job, force=True)
        return {"schedule": updated}


async def run_serve() -> None:
    paths.ensure_layout()
    # Redirect logs
    log = paths.log_path()
    sys.stdout.flush()
    sys.stderr.flush()
    # Keep stderr for nohup redirect from installer.

    daemon = Daemon()

    loop = asyncio.get_running_loop()
    stop = asyncio.Event()

    def _stop(*_args: Any) -> None:
        stop.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _stop)
        except NotImplementedError:
            pass

    serve_task = asyncio.create_task(daemon.start())
    await stop.wait()
    await daemon.scheduler.stop()
    serve_task.cancel()
    try:
        await serve_task
    except asyncio.CancelledError:
        pass
    sock = paths.socket_path()
    if sock.exists():
        sock.unlink(missing_ok=True)
    pid = paths.pid_path()
    if pid.exists():
        pid.unlink(missing_ok=True)
