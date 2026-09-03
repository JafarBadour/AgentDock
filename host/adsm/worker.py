"""Per-chat ACP worker: tmux + FIFO/journal owned exclusively by ADSM."""

from __future__ import annotations

import asyncio
import json
import os
import shlex
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

from . import paths, protocol
from . import transcript as transcript_store

EmitFn = Callable[[dict[str, Any]], Awaitable[None]]
StatusFn = Callable[[str, str, Optional[str]], Awaitable[None]]


def _shell_quote(s: str) -> str:
    return shlex.quote(s)


def _run_script(
    *,
    dir_path: str,
    cwd: str,
    binary: str,
    provider: str,
    full_access: bool,
) -> str:
    q = _shell_quote
    if provider == "claude":
        agent_args = ""
        skip_perms = (
            "export CLAUDE_ACP_SKIP_PERMISSIONS=true\n" if full_access else ""
        )
    else:
        agent_args = (
            "--force --approve-mcps --trust acp" if full_access else "acp"
        )
        skip_perms = ""
    exec_line = q(binary) if not agent_args else f"{q(binary)} {agent_args}"
    return f"""#!/bin/sh
DIR={q(dir_path)}

if [ -f "$DIR/env" ]; then
  . "$DIR/env"
  rm -f "$DIR/env"
fi

{skip_perms}for d in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH="$HOME/.local/bin:$HOME/.cursor/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
cd {q(cwd)} || exit 1

sleep 2147483647 > "$DIR/in" &
echo $! > "$DIR/holder.pid"

exec < "$DIR/in"
exec >> "$DIR/out.jsonl"
exec 2>> "$DIR/err.log"

if command -v stdbuf >/dev/null 2>&1; then
  exec stdbuf -oL -eL {exec_line}
fi
exec {exec_line}
"""


def _env_file(provider: str, api_key: Optional[str]) -> Optional[str]:
    if not api_key:
        return None
    if provider == "claude":
        return f"ANTHROPIC_API_KEY={_shell_quote(api_key)}\nexport ANTHROPIC_API_KEY\n"
    return f"CURSOR_API_KEY={_shell_quote(api_key)}\nexport CURSOR_API_KEY\n"


def ensure_tmux_worker(
    *,
    chat_id: str,
    cwd: str,
    binary: str,
    provider: str = "cursor",
    api_key: Optional[str] = None,
    full_access: bool = True,
) -> tuple[str, int]:
    """Start or adopt tmux worker. Returns (state, journal_size)."""
    dir_path = paths.session_dir(chat_id)
    tmux = paths.tmux_session_name(chat_id)
    dir_path.mkdir(parents=True, exist_ok=True)
    os.chmod(dir_path, 0o700)

    run_sh = _run_script(
        dir_path=str(dir_path),
        cwd=cwd,
        binary=binary,
        provider=provider,
        full_access=full_access,
    )
    (dir_path / "run.sh").write_text(run_sh, encoding="utf-8")
    os.chmod(dir_path / "run.sh", 0o755)

    fifo = dir_path / "in"
    if not fifo.exists():
        os.mkfifo(fifo, 0o600)
    journal = dir_path / "out.jsonl"
    journal.touch(exist_ok=True)

    want = "1" if full_access else "0"
    marker = dir_path / "full_access"
    have = marker.read_text(encoding="utf-8").strip() if marker.exists() else ""

    env_body = _env_file(provider, api_key)

    def _write_env() -> None:
        if env_body is None:
            return
        env_path = dir_path / "env"
        env_path.write_text(env_body, encoding="utf-8")
        os.chmod(env_path, 0o600)

    def _tmux_alive() -> bool:
        r = subprocess.run(
            ["tmux", "has-session", "-t", tmux],
            capture_output=True,
        )
        return r.returncode == 0

    def _start() -> None:
        _write_env()
        marker.write_text(want, encoding="utf-8")
        r = subprocess.run(
            [
                "tmux",
                "new-session",
                "-d",
                "-s",
                tmux,
                "-c",
                cwd,
                f"sh {dir_path / 'run.sh'}",
            ],
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            env_path = dir_path / "env"
            if env_path.exists():
                env_path.unlink(missing_ok=True)
            raise RuntimeError(
                f"tmux start failed: {r.stderr.strip() or r.stdout.strip() or r.returncode}"
            )

    if _tmux_alive():
        if have == want:
            state = "RUNNING"
        else:
            subprocess.run(
                ["tmux", "kill-session", "-t", tmux],
                capture_output=True,
            )
            _start()
            state = "RESTARTED"
    else:
        journal.write_text("", encoding="utf-8")
        _start()
        state = "STARTED"

    size = journal.stat().st_size if journal.exists() else 0
    return state, size


class Worker:
    """Owns ACP JSON-RPC for one chatId."""

    def __init__(
        self,
        chat_id: str,
        *,
        emit: EmitFn,
        set_status: StatusFn,
    ) -> None:
        self.chat_id = chat_id
        self._emit = emit
        self._set_status = set_status
        self.cwd = ""
        self.provider = "cursor"
        self.binary = ""
        self.full_access = True
        self.acp_session_id: Optional[str] = None
        self.model_id: Optional[str] = None
        self.available_models: list[dict[str, Any]] = []
        self.available_modes: list[str] = ["ask", "agent", "plan"]
        self.mode = "agent"
        self.load_session = False
        self.status = protocol.STATUS_DEAD
        self.last_error: Optional[str] = None
        self.last_turn_text = ""
        self._assistant_persisted = False
        self._turn_user_id: Optional[str] = None
        self._turn_assistant_id: Optional[str] = None

        self._fifo_write: Optional[asyncio.StreamWriter] = None
        self._fifo_fd: Optional[int] = None
        self._tail_task: Optional[asyncio.Task[None]] = None
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._req_n = 0
        self._epoch = hex(int(time.time() * 1e6))[2:]
        self._buffer = ""
        self._replaying = False
        self._prompt_key: Optional[str] = None
        self._open_permissions: dict[str, dict[str, Any]] = {}
        self._permission_policy_ask = False
        self._lock = asyncio.Lock()
        self._attached = False
        self._journal_pos = 0

    @property
    def dir(self) -> Path:
        return paths.session_dir(self.chat_id)

    def snapshot(self) -> dict[str, Any]:
        return {
            "chatId": self.chat_id,
            "cwd": self.cwd,
            "provider": self.provider,
            "status": self.status,
            "acpSessionId": self.acp_session_id,
            "modelId": self.model_id,
            "mode": self.mode,
            "availableModels": self.available_models,
            "availableModes": self.available_modes,
            "loadSession": self.load_session,
            "lastError": self.last_error,
            "tmuxSession": paths.tmux_session_name(self.chat_id),
        }

    async def ensure(
        self,
        *,
        cwd: str,
        binary: str,
        provider: str = "cursor",
        api_key: Optional[str] = None,
        full_access: bool = True,
        resume_session_id: Optional[str] = None,
        mcp_servers: Optional[list[Any]] = None,
        mode: Optional[str] = None,
        model_id: Optional[str] = None,
        permission_ask: bool = False,
    ) -> dict[str, Any]:
        async with self._lock:
            self.cwd = cwd
            self.binary = binary
            self.provider = provider
            self.full_access = full_access
            self._permission_policy_ask = permission_ask
            await self._set_status(
                self.chat_id, protocol.STATUS_STARTING, None
            )

            state, _size = await asyncio.to_thread(
                ensure_tmux_worker,
                chat_id=self.chat_id,
                cwd=cwd,
                binary=binary,
                provider=provider,
                api_key=api_key,
                full_access=full_access,
            )

            await self._attach_pipes()
            freshly = state != "RUNNING"

            sid_path = self.dir / "acp_session_id"
            stored = (
                sid_path.read_text(encoding="utf-8").strip()
                if sid_path.exists()
                else ""
            )
            effective = resume_session_id or (stored or None)

            if freshly:
                await self._initialize()
                await self._open_session(
                    mcp_servers=mcp_servers or [],
                    resume_session_id=effective,
                )
                if mode:
                    try:
                        await self.set_mode(mode)
                    except Exception as e:  # noqa: BLE001
                        self.last_error = f"set_mode: {e}"
                if model_id:
                    try:
                        await self.set_model(model_id)
                    except Exception as e:  # noqa: BLE001
                        self.last_error = f"set_model: {e}"
                self._persist_catalog()
            else:
                self.acp_session_id = effective
                self._restore_catalog()
                if model_id:
                    self.model_id = model_id
                if mode:
                    self.mode = mode
                # Re-attach after daemon restart leaves availableModels empty.
                if not self.available_models and effective:
                    try:
                        await self._refresh_models_unlocked(mcp_servers or [])
                    except Exception as e:  # noqa: BLE001
                        self.last_error = f"refresh_models: {e}"

            await self._set_status(self.chat_id, protocol.STATUS_IDLE, None)
            await self._emit_event(
                "session",
                acpSessionId=self.acp_session_id,
                state=state,
                models=self.available_models,
                modes=self.available_modes,
                mode=self.mode,
                modelId=self.model_id,
                loadSession=self.load_session,
            )
            return self.snapshot()

    async def refresh_models(
        self, *, mcp_servers: Optional[list[Any]] = None
    ) -> dict[str, Any]:
        async with self._lock:
            return await self._refresh_models_unlocked(mcp_servers or [])

    async def _refresh_models_unlocked(
        self, mcp_servers: list[Any]
    ) -> dict[str, Any]:
        """Populate availableModels via session/load (replay suppressed)."""
        if self.available_models:
            return self.snapshot()
        self._restore_catalog()
        if self.available_models:
            return self.snapshot()

        await self._attach_pipes()
        sid = self.acp_session_id
        if not sid:
            sid_path = self.dir / "acp_session_id"
            if sid_path.exists():
                sid = sid_path.read_text(encoding="utf-8").strip() or None
                self.acp_session_id = sid
        if not sid:
            return self.snapshot()

        # session/load needs an initialized ACP peer; after a daemon restart
        # the agent process is already up — initialize is usually a no-op /
        # harmless, but ignore failures and still try load.
        try:
            await self._initialize()
        except Exception:  # noqa: BLE001
            pass

        try:
            await self._load_session(sid, mcp_servers)
        except Exception as e:  # noqa: BLE001
            self.last_error = f"refresh_models load: {e}"
            # Last resort: some agents only advertise models on session/new.
            # Do not call session/new here — that would wipe the conversation.

        self._persist_catalog()
        await self._emit_event(
            "session",
            acpSessionId=self.acp_session_id,
            models=self.available_models,
            modes=self.available_modes,
            mode=self.mode,
            modelId=self.model_id,
            loadSession=self.load_session,
        )
        return self.snapshot()

    def _catalog_path(self) -> Path:
        return self.dir / "catalog.json"

    def _persist_catalog(self) -> None:
        try:
            self.dir.mkdir(parents=True, exist_ok=True)
            payload = {
                "availableModels": self.available_models,
                "modelId": self.model_id,
                "availableModes": self.available_modes,
                "mode": self.mode,
                "loadSession": self.load_session,
            }
            self._catalog_path().write_text(
                json.dumps(payload, ensure_ascii=False), encoding="utf-8"
            )
        except Exception:  # noqa: BLE001
            pass

    def _restore_catalog(self) -> None:
        path = self._catalog_path()
        if not path.exists():
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            return
        if not isinstance(data, dict):
            return
        models = data.get("availableModels")
        if isinstance(models, list) and models:
            self.available_models = [dict(m) for m in models if isinstance(m, dict)]
        mid = data.get("modelId")
        if mid:
            self.model_id = str(mid)
        modes = data.get("availableModes")
        if isinstance(modes, list) and modes:
            self.available_modes = [str(m) for m in modes]
        mode = data.get("mode")
        if mode:
            self.mode = str(mode)
        if "loadSession" in data:
            self.load_session = bool(data.get("loadSession"))

    async def _attach_pipes(self) -> None:
        if self._attached and self._fifo_write is not None:
            return
        fifo = self.dir / "in"
        journal = self.dir / "out.jsonl"
        # Open FIFO for write without blocking (holder keeps read side open).
        # Retry briefly — holder may not have opened the read end yet.
        fd = None
        for _ in range(50):
            try:
                fd = os.open(str(fifo), os.O_WRONLY | os.O_NONBLOCK)
                break
            except OSError:
                await asyncio.sleep(0.1)
        if fd is None:
            raise RuntimeError(f"could not open FIFO {fifo}")
        self._fifo_fd = fd
        self._fifo_write = None

        # Tail from current end so we don't re-ingest historical ACP into events.
        self._journal_pos = journal.stat().st_size if journal.exists() else 0
        if self._tail_task is None or self._tail_task.done():
            self._tail_task = asyncio.create_task(self._tail_journal())
        self._attached = True

    async def _tail_journal(self) -> None:
        journal = self.dir / "out.jsonl"
        while True:
            try:
                if not journal.exists():
                    await asyncio.sleep(0.2)
                    continue
                size = journal.stat().st_size
                if size < self._journal_pos:
                    # Truncated (restart).
                    self._journal_pos = 0
                if size > self._journal_pos:
                    with journal.open("rb") as fh:
                        fh.seek(self._journal_pos)
                        chunk = fh.read()
                        self._journal_pos = fh.tell()
                    if chunk:
                        text = chunk.decode("utf-8", errors="replace")
                        self._buffer += text
                        while "\n" in self._buffer:
                            line, self._buffer = self._buffer.split("\n", 1)
                            line = line.strip()
                            if line:
                                await self._handle_acp_line(line)
                else:
                    # Check tmux still alive occasionally.
                    alive = await asyncio.to_thread(self._tmux_alive)
                    if not alive and self.status not in (
                        protocol.STATUS_DEAD,
                        protocol.STATUS_ERROR,
                    ):
                        await self._set_status(
                            self.chat_id,
                            protocol.STATUS_DEAD,
                            "tmux session ended",
                        )
                        await self._emit_event(
                            "status", status=protocol.STATUS_DEAD
                        )
                        await self._emit_event("error", text="Agent process ended")
                    await asyncio.sleep(0.05)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                self.last_error = str(e)
                await asyncio.sleep(0.5)

    def _tmux_alive(self) -> bool:
        r = subprocess.run(
            ["tmux", "has-session", "-t", paths.tmux_session_name(self.chat_id)],
            capture_output=True,
        )
        return r.returncode == 0

    def _write_raw(self, obj: dict[str, Any]) -> None:
        if self._fifo_fd is None:
            raise RuntimeError("FIFO not attached")
        data = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
        # FIFO may briefly block; retry.
        remaining = data
        while remaining:
            try:
                n = os.write(self._fifo_fd, remaining)
                remaining = remaining[n:]
            except BlockingIOError:
                time.sleep(0.01)

    async def _write(self, obj: dict[str, Any]) -> None:
        await asyncio.to_thread(self._write_raw, obj)

    async def _request(
        self, method: str, params: dict[str, Any], timeout: float = 120.0
    ) -> dict[str, Any]:
        key = f"{self._epoch}-{self._req_n}"
        self._req_n += 1
        loop = asyncio.get_running_loop()
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[key] = fut
        if method == "session/prompt":
            self._prompt_key = key
        await self._write(
            {"jsonrpc": "2.0", "id": key, "method": method, "params": params}
        )
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        finally:
            if self._prompt_key == key:
                self._prompt_key = None
            self._pending.pop(key, None)

    async def _notify(self, method: str, params: dict[str, Any]) -> None:
        await self._write({"jsonrpc": "2.0", "method": method, "params": params})

    async def _initialize(self) -> None:
        result = await self._request(
            "initialize",
            {
                "protocolVersion": 1,
                "clientInfo": {"name": "agent_dock_adsm", "version": "0.1.0"},
                "capabilities": {
                    "fs": {"readTextFile": False, "writeTextFile": False}
                },
            },
            timeout=25.0,
        )
        caps = result.get("agentCapabilities") or result.get("agent_capabilities") or {}
        if isinstance(caps, dict):
            self.load_session = bool(
                caps.get("loadSession") or caps.get("load_session")
            )
        await self._notify("initialized", {})

    async def _open_session(
        self,
        *,
        mcp_servers: list[Any],
        resume_session_id: Optional[str],
    ) -> None:
        if resume_session_id and self.load_session:
            try:
                await self._load_session(resume_session_id, mcp_servers)
                return
            except Exception:  # noqa: BLE001
                pass
        await self._new_session(mcp_servers)

    async def _new_session(self, mcp_servers: list[Any]) -> None:
        result = await self._request(
            "session/new",
            {"cwd": self.cwd, "mcpServers": mcp_servers},
            timeout=25.0,
        )
        self.acp_session_id = (
            result.get("sessionId") or result.get("session_id")
        )
        self._apply_models(result.get("models"))
        self._apply_modes(result.get("modes"))
        self._persist_session_id()

    async def _load_session(
        self, session_id: str, mcp_servers: list[Any]
    ) -> None:
        # Replay must not hit phone subscribers.
        self._replaying = True
        try:
            result = await self._request(
                "session/load",
                {
                    "sessionId": session_id,
                    "cwd": self.cwd,
                    "mcpServers": mcp_servers,
                },
                timeout=60.0,
            )
            self.acp_session_id = session_id
            self._apply_models(result.get("models"))
            self._apply_modes(result.get("modes"))
            self._persist_session_id()
        finally:
            self._replaying = False

    def _persist_session_id(self) -> None:
        if not self.acp_session_id:
            return
        (self.dir / "acp_session_id").write_text(
            self.acp_session_id, encoding="utf-8"
        )

    def _apply_models(self, models: Any) -> None:
        if not isinstance(models, dict):
            return
        avail = models.get("availableModels") or models.get("available_models")
        out: list[dict[str, Any]] = []
        if isinstance(avail, list):
            for e in avail:
                if isinstance(e, dict):
                    out.append(dict(e))
        self.available_models = out
        cur = models.get("currentModelId") or models.get("current_model_id")
        if cur is not None:
            self.model_id = str(cur)
        self._persist_catalog()

    def _apply_modes(self, modes: Any) -> None:
        if not isinstance(modes, dict):
            return
        avail = modes.get("availableModes") or modes.get("available_modes")
        if isinstance(avail, list):
            ids = []
            for e in avail:
                if isinstance(e, dict):
                    i = e.get("id") or e.get("modeId")
                    if i:
                        ids.append(str(i))
                elif e:
                    ids.append(str(e))
            if ids:
                self.available_modes = ids
        cur = modes.get("currentModeId") or modes.get("current_mode_id")
        if cur is not None:
            self.mode = str(cur)

    async def set_mode(self, mode_id: str) -> None:
        if not self.acp_session_id:
            raise RuntimeError("ACP session not ready")
        await self._request(
            "session/set_mode",
            {"sessionId": self.acp_session_id, "modeId": mode_id},
            timeout=15.0,
        )
        self.mode = mode_id
        await self._emit_event("mode", mode=mode_id)

    async def set_model(self, model_id: str) -> None:
        if not self.acp_session_id:
            raise RuntimeError("ACP session not ready")
        await self._request(
            "session/set_model",
            {"sessionId": self.acp_session_id, "modelId": model_id},
            timeout=15.0,
        )
        self.model_id = model_id

    async def prompt(
        self,
        text: str,
        images: Optional[list] = None,
        *,
        user_message_id: Optional[str] = None,
        user_created_at: Optional[str] = None,
    ) -> dict[str, Any]:
        if not self.acp_session_id:
            raise RuntimeError("ACP session not ready")
        blocks: list[dict[str, Any]] = []
        for img in images or []:
            if not isinstance(img, dict):
                continue
            data = img.get("data")
            mime = img.get("mimeType") or img.get("mime_type") or "image/jpeg"
            if not data:
                continue
            blocks.append(
                {
                    "type": "image",
                    "mimeType": str(mime),
                    "data": str(data),
                }
            )
        if text:
            blocks.append({"type": "text", "text": text})
        if not blocks:
            raise ValueError("empty prompt")
        self.last_turn_text = ""
        self._assistant_persisted = False
        self._turn_assistant_id = str(uuid.uuid4())
        self._turn_user_id = user_message_id or str(uuid.uuid4())
        # Persist the user turn on the host so reconnects see it even if the
        # phone never flushed SQLite / SSH push.
        try:
            if text.strip():
                transcript_store.append_message(
                    self.chat_id,
                    role="user",
                    content=text,
                    message_id=self._turn_user_id,
                    created_at=user_created_at,
                )
        except Exception:  # noqa: BLE001
            pass
        await self._set_status(self.chat_id, protocol.STATUS_RUNNING, None)
        await self._emit_event("status", status=protocol.STATUS_RUNNING)
        try:
            result = await self._request(
                "session/prompt",
                {
                    "sessionId": self.acp_session_id,
                    "prompt": blocks,
                },
                timeout=600.0,
            )
            stop = (
                result.get("stopReason")
                if isinstance(result, dict)
                else "end_turn"
            )
            self._persist_assistant_turn()
            await self._emit_event("turn_complete", reason=stop or "end_turn")
            await self._set_status(self.chat_id, protocol.STATUS_IDLE, None)
            await self._emit_event("status", status=protocol.STATUS_IDLE)
            return result if isinstance(result, dict) else {"stopReason": "end_turn"}
        except Exception as e:  # noqa: BLE001
            self.last_error = str(e)
            self._persist_assistant_turn()
            await self._set_status(
                self.chat_id, protocol.STATUS_ERROR, str(e)
            )
            await self._emit_event("error", text=str(e))
            raise

    def _persist_assistant_turn(self) -> None:
        if self._assistant_persisted:
            return
        text = (self.last_turn_text or "").strip()
        if not text:
            return
        try:
            transcript_store.append_message(
                self.chat_id,
                role="assistant",
                content=text,
                message_id=self._turn_assistant_id or str(uuid.uuid4()),
            )
            self._assistant_persisted = True
        except Exception:  # noqa: BLE001
            pass

    async def cancel(self) -> None:
        if not self.acp_session_id:
            return
        try:
            await self._request(
                "session/cancel",
                {"sessionId": self.acp_session_id},
                timeout=10.0,
            )
        except Exception:  # noqa: BLE001
            pass
        key = self._prompt_key
        if key and key in self._pending:
            fut = self._pending[key]
            if not fut.done():
                fut.set_result({"stopReason": "cancelled"})
        self._persist_assistant_turn()
        await self._emit_event("turn_complete", reason="cancelled")
        await self._set_status(self.chat_id, protocol.STATUS_IDLE, None)

    async def respond_permission(self, request_id: str, option_id: str) -> None:
        pending = self._open_permissions.pop(str(request_id), None)
        raw_id: Any = request_id
        if pending and "raw_id" in pending:
            raw_id = pending["raw_id"]
        else:
            # Best-effort restore JSON-RPC id type.
            if request_id.isdigit():
                raw_id = int(request_id)
            elif request_id.startswith("{") or request_id.startswith("["):
                try:
                    raw_id = json.loads(request_id)
                except json.JSONDecodeError:
                    raw_id = request_id
        await self._write(
            {
                "jsonrpc": "2.0",
                "id": raw_id,
                "result": {
                    "outcome": {"outcome": "selected", "optionId": option_id}
                },
            }
        )
        label = option_id
        if pending:
            for o in pending.get("options") or []:
                if str(o.get("optionId")) == option_id:
                    label = str(o.get("name") or option_id)
                    break
        await self._emit_event("permission", text=label, resolved=True)
        if self.status == protocol.STATUS_WAITING_PERMISSION:
            await self._set_status(self.chat_id, protocol.STATUS_RUNNING, None)

    async def _emit_event(self, kind: str, **payload: Any) -> None:
        await self._emit({"chatId": self.chat_id, "kind": kind, **payload})

    async def _handle_acp_line(self, line: str) -> None:
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            return
        if not isinstance(msg, dict):
            return

        if "id" in msg and ("result" in msg or "error" in msg):
            key = str(msg["id"])
            fut = self._pending.get(key)
            if fut and not fut.done():
                if msg.get("error") is not None:
                    fut.set_exception(RuntimeError(str(msg["error"])))
                else:
                    result = msg.get("result")
                    fut.set_result(
                        result if isinstance(result, dict) else {"value": result}
                    )
            if self._prompt_key == key:
                self._prompt_key = None
            return

        method = msg.get("method")
        if not method:
            return
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}

        if method in ("session/update",) or str(method).endswith("/update"):
            if self._replaying:
                return
            await self._handle_update(params)
        elif method == "session/request_permission":
            await self._handle_permission(msg.get("id"), params)
        elif method == "cursor/create_plan":
            # Auto-accept plans.
            if msg.get("id") is not None:
                await self._write(
                    {
                        "jsonrpc": "2.0",
                        "id": msg["id"],
                        "result": {"outcome": {"outcome": "selected", "optionId": "accept"}},
                    }
                )
        elif method == "cursor/ask_question":
            if msg.get("id") is not None:
                await self._write(
                    {
                        "jsonrpc": "2.0",
                        "id": msg["id"],
                        "result": {
                            "outcome": {
                                "outcome": "selected",
                                "optionId": "ok",
                            }
                        },
                    }
                )

    async def _handle_update(self, params: dict[str, Any]) -> None:
        update = params.get("update") if isinstance(params.get("update"), dict) else params
        typ = str(update.get("sessionUpdate") or update.get("type") or "")

        if typ in (
            "available_commands_update",
            "availableCommandsUpdate",
            "config_option_update",
            "configOptionUpdate",
        ):
            return

        if typ in ("current_mode_update", "currentModeUpdate"):
            mid = str(update.get("modeId") or update.get("currentModeId") or "")
            if mid:
                self.mode = mid
                await self._emit_event("mode", mode=mid)
            return

        if typ in ("state_update", "stateUpdate"):
            state = str(update.get("state") or "").lower()
            stop = str(update.get("stopReason") or update.get("stop_reason") or "")
            if state == "idle" or stop:
                self._persist_assistant_turn()
                await self._emit_event(
                    "turn_complete", reason=stop or "end_turn"
                )
                await self._set_status(self.chat_id, protocol.STATUS_IDLE, None)
                key = self._prompt_key
                if key and key in self._pending:
                    fut = self._pending[key]
                    if not fut.done():
                        fut.set_result({"stopReason": stop or "end_turn"})
            return

        bare = update.get("stopReason") or update.get("stop_reason")
        if bare:
            self._persist_assistant_turn()
            await self._emit_event("turn_complete", reason=str(bare))
            return

        if typ in ("session_info_update", "sessionInfoUpdate"):
            title = update.get("title")
            if title:
                await self._emit_event("status", title=str(title))
            return

        if typ in (
            "agent_message_chunk",
            "agentMessageChunk",
            "agent_message",
            "agentMessage",
            "message",
        ):
            text = _extract_text(update)
            if text:
                self.last_turn_text = (self.last_turn_text or "") + text
                await self._emit_event("activity", label="Writing")
                await self._emit_event("text", text=text)
            return

        if "thought" in typ.lower() or "reasoning" in typ.lower():
            text = _extract_text(update)
            if text:
                await self._emit_event("thought", text=text)
            return

        if "tool" in typ.lower():
            tool = _parse_tool(update)
            if tool:
                kind = (
                    "tool_start"
                    if typ in ("tool_call", "toolCall")
                    else "tool_update"
                )
                await self._emit_event(kind, tool=tool)
            return

        text = _extract_text(update)
        if text:
            await self._emit_event("text", text=text)

    async def _handle_permission(
        self, req_id: Any, params: dict[str, Any]
    ) -> None:
        if req_id is None:
            return
        options = []
        raw_opts = params.get("options") or []
        if isinstance(raw_opts, list):
            for o in raw_opts:
                if isinstance(o, dict):
                    options.append(
                        {
                            "optionId": str(
                                o.get("optionId") or o.get("id") or ""
                            ),
                            "name": str(o.get("name") or o.get("label") or ""),
                            "kind": o.get("kind"),
                        }
                    )
        title = "Allow this action?"
        if params.get("title"):
            title = str(params["title"])
        elif isinstance(params.get("toolCall"), dict):
            t = params["toolCall"].get("title")
            if t:
                title = str(t)
        if not self._permission_policy_ask:
            # Auto-allow: prefer allow_always / allow-once style ids.
            pick = "allow_always"
            for o in options:
                oid = o["optionId"].lower()
                if "always" in oid:
                    pick = o["optionId"]
                    break
                if "allow" in oid and "reject" not in oid:
                    pick = o["optionId"]
            await self._write(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "outcome": {"outcome": "selected", "optionId": pick}
                    },
                }
            )
            return

        rid = str(req_id)
        self._open_permissions[rid] = {
            "raw_id": req_id,
            "options": options,
            "title": title,
        }
        await self._set_status(
            self.chat_id, protocol.STATUS_WAITING_PERMISSION, None
        )
        await self._emit_event(
            "permission",
            requestId=rid,
            title=title,
            options=options,
            text=title,
        )

    async def stop(self, delete_files: bool = False) -> None:
        if self._tail_task:
            self._tail_task.cancel()
            try:
                await self._tail_task
            except asyncio.CancelledError:
                pass
            self._tail_task = None
        if self._fifo_fd is not None:
            try:
                os.close(self._fifo_fd)
            except OSError:
                pass
            self._fifo_fd = None
        self._attached = False
        tmux = paths.tmux_session_name(self.chat_id)
        await asyncio.to_thread(
            subprocess.run,
            ["tmux", "kill-session", "-t", tmux],
            capture_output=True,
        )
        if delete_files:
            import shutil

            shutil.rmtree(self.dir, ignore_errors=True)
        await self._set_status(self.chat_id, protocol.STATUS_DEAD, None)


def _extract_text(update: dict[str, Any]) -> Optional[str]:
    content = update.get("content")
    if isinstance(content, dict) and content.get("text") is not None:
        return str(content["text"])
    if isinstance(content, str) and content:
        return content
    if update.get("text") is not None:
        return str(update["text"])
    message = update.get("message") or update.get("agentMessageChunk")
    if isinstance(message, dict):
        if message.get("text") is not None:
            return str(message["text"])
        inner = message.get("content")
        if isinstance(inner, dict) and inner.get("text") is not None:
            return str(inner["text"])
        if isinstance(inner, str):
            return inner
    if isinstance(message, str):
        return message
    return None


def _parse_tool(update: dict[str, Any]) -> Optional[dict[str, Any]]:
    nested = (
        dict(update["toolCall"])
        if isinstance(update.get("toolCall"), dict)
        else update
    )
    tid = str(
        nested.get("toolCallId")
        or nested.get("tool_call_id")
        or nested.get("id")
        or update.get("toolCallId")
        or ""
    )
    title = str(
        nested.get("title")
        or nested.get("name")
        or nested.get("toolName")
        or update.get("title")
        or "Tool"
    )
    if not tid and title == "Tool":
        return None
    locations: list[str] = []
    raw_locs = nested.get("locations") or update.get("locations")
    if isinstance(raw_locs, list):
        for loc in raw_locs:
            if isinstance(loc, dict) and loc.get("path"):
                path = str(loc["path"])
                line = loc.get("line")
                locations.append(f"{path}:{line}" if line is not None else path)
    return {
        "toolCallId": tid or title,
        "title": title,
        "kind": nested.get("kind") or update.get("kind"),
        "status": str(nested.get("status") or update.get("status") or "pending"),
        "locations": locations,
        "rawInput": nested.get("rawInput") or update.get("rawInput"),
        "rawOutput": nested.get("rawOutput") or update.get("rawOutput"),
        "content": nested.get("content") or update.get("content"),
    }
