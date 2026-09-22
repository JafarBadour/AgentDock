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
from . import process_hygiene
from . import transcript as transcript_store

EmitFn = Callable[[dict[str, Any]], Awaitable[None]]
StatusFn = Callable[[str, str, Optional[str]], Awaitable[None]]


def _shell_quote(s: str) -> str:
    return shlex.quote(s)


def _is_acp_method_not_found(exc: BaseException, method: str) -> bool:
    """True when [exc] is JSON-RPC method-not-found for [method].

    Errors may be nested (`-32000` wrapping `-32601`) by SSH/tmux bridges.
    """
    text = str(exc)
    if method not in text:
        return False
    return "-32601" in text or "method not found" in text.lower()


def _is_session_not_found(exc: BaseException) -> bool:
    """Claude/Cursor ACP rejected the session id (often after cancel/restart)."""
    text = str(exc).lower()
    return (
        "session not found" in text
        or "unknown session" in text
        or ("-32603" in text and "session" in text)
    )

def _flatten_config_select_options(options: Any) -> list[dict[str, Any]]:
    """Flatten nested select option groups from ACP configOptions."""
    if not isinstance(options, list):
        return []
    out: list[dict[str, Any]] = []
    for entry in options:
        if not isinstance(entry, dict):
            continue
        nested = entry.get("options")
        if isinstance(nested, list):
            for sub in nested:
                if isinstance(sub, dict) and sub.get("value") is not None:
                    out.append(dict(sub))
        elif entry.get("value") is not None:
            out.append(dict(entry))
    return out


def models_from_config_options(config_options: Any) -> list[dict[str, Any]]:
    """Extract model catalogue from Claude-style session configOptions."""
    if not isinstance(config_options, list):
        return []
    model_opt: Optional[dict[str, Any]] = None
    for entry in config_options:
        if not isinstance(entry, dict):
            continue
        opt_id = entry.get("id") or entry.get("configId") or entry.get("config_id")
        category = entry.get("category")
        if opt_id == "model" or category == "model":
            model_opt = entry
            break
    if model_opt is None:
        return []
    out: list[dict[str, Any]] = []
    for item in _flatten_config_select_options(model_opt.get("options")):
        value = item.get("value")
        if value is None:
            continue
        name = item.get("name") or str(value)
        out.append({"modelId": str(value), "name": str(name)})
    return out


def current_model_from_config_options(config_options: Any) -> Optional[str]:
    if not isinstance(config_options, list):
        return None
    for entry in config_options:
        if not isinstance(entry, dict):
            continue
        opt_id = entry.get("id") or entry.get("configId") or entry.get("config_id")
        category = entry.get("category")
        if opt_id == "model" or category == "model":
            cur = entry.get("currentValue") or entry.get("current_value")
            return str(cur) if cur is not None else None
    return None


def _uses_config_options(provider: str) -> bool:
    """Providers whose ACP adapter exposes models via session configOptions."""
    return (provider or "").lower() in ("claude", "codex")


_CODEX_EFFORT_ATTR = "effort"


def _config_option(config_options: Any, opt_id: str) -> Optional[dict[str, Any]]:
    if not isinstance(config_options, list):
        return None
    for entry in config_options:
        if not isinstance(entry, dict):
            continue
        eid = entry.get("id") or entry.get("configId") or entry.get("config_id")
        if eid == opt_id:
            return entry
    return None


def split_codex_model_id(model_id: str) -> tuple[str, Optional[str]]:
    """`gpt-5.5[effort=high]` -> (`gpt-5.5`, `high`); plain ids pass through."""
    mid = (model_id or "").strip()
    open_i = mid.find("[")
    close_i = mid.rfind("]")
    if open_i < 0 or close_i <= open_i:
        return mid, None
    base = mid[:open_i]
    effort: Optional[str] = None
    for pair in mid[open_i + 1 : close_i].split(","):
        k, _, v = pair.partition("=")
        if k.strip() == _CODEX_EFFORT_ATTR and v.strip():
            effort = v.strip()
    return base, effort


def codex_models_from_config_options(config_options: Any) -> list[dict[str, Any]]:
    """Codex exposes model and reasoning effort as two independent selects.

    The app treats a model as a single preset string (like Cursor's
    `model[thinking=true]` ids), so we advertise the cross product as
    `model[effort=level]` presets. Without an effort option the plain model
    list is returned unchanged.
    """
    base = models_from_config_options(config_options)
    effort_opt = _config_option(config_options, "reasoning_effort")
    if not base or effort_opt is None:
        return base
    levels = [
        str(o.get("value"))
        for o in _flatten_config_select_options(effort_opt.get("options"))
        if o.get("value") is not None
    ]
    if not levels:
        return base
    out: list[dict[str, Any]] = []
    for m in base:
        for level in levels:
            out.append(
                {
                    "modelId": f"{m['modelId']}[{_CODEX_EFFORT_ATTR}={level}]",
                    "name": m["name"],
                }
            )
    return out


def codex_current_model_from_config_options(config_options: Any) -> Optional[str]:
    cur = current_model_from_config_options(config_options)
    if cur is None:
        return None
    effort_opt = _config_option(config_options, "reasoning_effort")
    if effort_opt is None:
        return cur
    level = effort_opt.get("currentValue") or effort_opt.get("current_value")
    if level is None:
        return cur
    return f"{cur}[{_CODEX_EFFORT_ATTR}={level}]"


def _run_script(
    *,
    dir_path: str,
    cwd: str,
    binary: str,
    provider: str,
    full_access: bool,
    model_id: Optional[str] = None,
) -> str:
    q = _shell_quote
    model_flag = ""
    if provider == "cursor" and model_id:
        model_flag = f"--model {q(model_id)} "
    if provider == "claude":
        agent_args = ""
        skip_perms = (
            "export CLAUDE_ACP_SKIP_PERMISSIONS=true\n" if full_access else ""
        )
    elif provider == "codex":
        # Zed's codex-acp is a bare ACP binary: model, reasoning effort and
        # the approval preset are all set per session over RPC.
        agent_args = ""
        skip_perms = ""
    else:
        agent_args = (
            f"{model_flag}--force --approve-mcps --trust acp"
            if full_access
            else f"{model_flag}acp"
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


def _env_file(
    provider: str,
    api_key: Optional[str],
    model_id: Optional[str] = None,
) -> Optional[str]:
    lines: list[str] = []
    if api_key:
        if provider == "claude":
            lines.append(f"ANTHROPIC_API_KEY={_shell_quote(api_key)}")
            lines.append("export ANTHROPIC_API_KEY")
        elif provider == "codex":
            lines.append(f"OPENAI_API_KEY={_shell_quote(api_key)}")
            lines.append("export OPENAI_API_KEY")
        else:
            lines.append(f"CURSOR_API_KEY={_shell_quote(api_key)}")
            lines.append("export CURSOR_API_KEY")
    if provider == "claude" and model_id:
        lines.append(f"CLAUDE_ACP_MODEL={_shell_quote(model_id)}")
        lines.append("export CLAUDE_ACP_MODEL")
    if not lines:
        return None
    return "\n".join(lines) + "\n"


def ensure_tmux_worker(
    *,
    chat_id: str,
    cwd: str,
    binary: str,
    provider: str = "cursor",
    api_key: Optional[str] = None,
    full_access: bool = True,
    model_id: Optional[str] = None,
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
        model_id=model_id,
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
    model_marker = dir_path / "desired_model"
    want_model = model_id or ""
    have_model = (
        model_marker.read_text(encoding="utf-8").strip()
        if model_marker.exists()
        else ""
    )

    env_body = _env_file(provider, api_key, model_id)

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
        model_marker.write_text(want_model, encoding="utf-8")
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
        if have == want and have_model == want_model:
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
        self.auth_methods: list[str] = []
        self._config_option_ids: set[str] = set()
        self._codex_plan = False
        self._term_output: dict[str, str] = {}
        self.binary = ""
        self.full_access = True
        self.acp_session_id: Optional[str] = None
        self._needs_history_bootstrap = False
        self.model_id: Optional[str] = None
        self.available_models: list[dict[str, Any]] = []
        self._models_via_config_option = False
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
        # Background ACP turn after early `session.prompt` accept reply.
        self._turn_task: Optional[asyncio.Task[None]] = None
        # Used by the daemon idle reaper (monotonic seconds).
        self.last_activity = time.monotonic()

    def touch_activity(self) -> None:
        self.last_activity = time.monotonic()

    def _hydrate_launch_fields(self) -> None:
        """Fill cwd/binary/provider from the on-disk agent record when missing."""
        if self.cwd and self.binary:
            return
        rec = paths.agent_record_path(self.chat_id)
        if not rec.exists():
            return
        try:
            data = json.loads(rec.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            return
        if not isinstance(data, dict):
            return
        if not self.cwd:
            self.cwd = str(data.get("cwd") or "")
        if not self.binary:
            self.binary = str(data.get("binary") or "")
        if not self.provider or self.provider == "cursor":
            prov = data.get("provider")
            if prov:
                self.provider = str(prov)
        if not self.acp_session_id:
            sid = data.get("acp_session_id") or data.get("acpSessionId")
            if sid:
                self.acp_session_id = str(sid)
        if not self.model_id:
            mid = data.get("model_id") or data.get("modelId")
            if mid:
                self.model_id = str(mid)

    async def _revive_transport(self) -> None:
        """Re-attach / restart tmux after idle-stop or daemon adopt left FIFO cold.

        Idle maintenance calls [stop] (kills tmux, closes FIFO) but keeps the
        ACP session id on disk. The phone still looks "live" and sends
        `session.prompt`, which used to fail with "FIFO not attached".
        """
        alive = await asyncio.to_thread(self._tmux_alive)
        if self._fifo_fd is not None and alive:
            return
        if self._fifo_fd is not None and not alive:
            await self._detach_fifo()

        self._hydrate_launch_fields()
        if not self.cwd or not self.binary:
            raise RuntimeError(
                "FIFO not attached — reopen this chat to reconnect the agent"
            )

        # Full ensure restarts tmux if needed, attaches the FIFO, and reloads
        # the ACP session. Safe to call from prompt/cancel before any write.
        await self.ensure(
            cwd=self.cwd,
            binary=self.binary,
            provider=self.provider or "cursor",
            api_key=None,
            full_access=self.full_access,
            resume_session_id=self.acp_session_id,
            mcp_servers=[],
            mode=self.mode,
            model_id=self.model_id,
            permission_ask=self._permission_policy_ask,
        )

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
        force_new_session: bool = False,
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

            sid_path = self.dir / "acp_session_id"

            # Drop the live ACP peer so session/new picks up current MCPs.
            # Resume/load keeps the old tool set; only a fresh session binds
            # newly deployed servers.
            if force_new_session:
                await self._detach_fifo()
                await asyncio.to_thread(
                    subprocess.run,
                    [
                        "tmux",
                        "kill-session",
                        "-t",
                        paths.tmux_session_name(self.chat_id),
                    ],
                    capture_output=True,
                )
                try:
                    sid_path.unlink(missing_ok=True)
                except OSError:
                    pass
                self.acp_session_id = None
                resume_session_id = None

            state, _size = await asyncio.to_thread(
                ensure_tmux_worker,
                chat_id=self.chat_id,
                cwd=cwd,
                binary=binary,
                provider=provider,
                api_key=api_key,
                full_access=full_access,
                model_id=model_id,
            )

            await self._attach_pipes()
            freshly = force_new_session or state != "RUNNING"

            stored = (
                sid_path.read_text(encoding="utf-8").strip()
                if sid_path.exists()
                else ""
            )
            effective = (
                None
                if force_new_session
                else (resume_session_id or (stored or None))
            )

            # Process is up but we have no session id to address it — recycle
            # so initialize + session/new can mint one. Otherwise set_mode /
            # set_model / model catalog all fail with "ACP session not ready".
            if not freshly and not effective:
                await self._detach_fifo()
                await asyncio.to_thread(
                    subprocess.run,
                    [
                        "tmux",
                        "kill-session",
                        "-t",
                        paths.tmux_session_name(self.chat_id),
                    ],
                    capture_output=True,
                )
                state, _size = await asyncio.to_thread(
                    ensure_tmux_worker,
                    chat_id=self.chat_id,
                    cwd=cwd,
                    binary=binary,
                    provider=provider,
                    api_key=api_key,
                    full_access=full_access,
                    model_id=model_id,
                )
                await self._attach_pipes()
                freshly = True
                effective = None

            if freshly:
                try:
                    await self._initialize()
                    await self._open_session(
                        mcp_servers=mcp_servers or [],
                        resume_session_id=effective,
                    )
                except Exception as e:  # noqa: BLE001
                    self.last_error = f"open_session: {e}"
                    await self._set_status(
                        self.chat_id, protocol.STATUS_ERROR, str(e)
                    )
                    await self._emit_event(
                        "status", status=protocol.STATUS_ERROR
                    )
                    return self.snapshot()

                if not self.acp_session_id:
                    self.last_error = (
                        "ACP session/new returned no session id "
                        "(agent may still be starting — reconnect)"
                    )
                    await self._set_status(
                        self.chat_id, protocol.STATUS_ERROR, self.last_error
                    )
                    return self.snapshot()

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
                if _uses_config_options(self.provider) and self.available_models:
                    self._models_via_config_option = True
                # Re-attach after daemon restart leaves availableModels empty.
                if not self.available_models and effective:
                    try:
                        await self._refresh_models_unlocked(mcp_servers or [])
                    except Exception as e:  # noqa: BLE001
                        self.last_error = f"refresh_models: {e}"
                # Never poke mode/model while a prompt is in flight — Claude
                # rejects app ids like "agent" (Invalid Mode) and the RPC can
                # race permission auto-allow on the same FIFO.
                if not self._turn_in_flight():
                    if model_id:
                        try:
                            await self.set_model(model_id)
                        except Exception as e:  # noqa: BLE001
                            self.last_error = f"set_model: {e}"
                            self.model_id = model_id
                    if mode:
                        try:
                            await self.set_mode(mode)
                        except Exception as e:  # noqa: BLE001
                            self.last_error = f"set_mode: {e}"
                            self.mode = mode

            # Re-ensure must not clobber a live turn back to idle (that used to
            # desync the phone busy chrome from the host).
            if not self._turn_in_flight():
                # Successful reconnect clears sticky MCP/open_session errors so
                # the health sheet stops looking broken after recovery.
                self.last_error = None
                await self._set_status(self.chat_id, protocol.STATUS_IDLE, "")
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
            # No addressable session — mint one so the model picker has a catalogue.
            try:
                await self._initialize()
            except Exception:  # noqa: BLE001
                pass
            try:
                await self._new_session(mcp_servers)
            except Exception as e:  # noqa: BLE001
                self.last_error = f"refresh_models new: {e}"
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
        if self._attached and self._fifo_fd is not None:
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

    async def _detach_fifo(self) -> None:
        """Close the write end so a recycled tmux worker can reopen cleanly."""
        if self._fifo_fd is not None:
            try:
                os.close(self._fifo_fd)
            except OSError:
                pass
            self._fifo_fd = None
        self._fifo_write = None
        self._attached = False
        self._buffer = ""
        self._epoch = hex(int(time.time() * 1e6))[2:]
        for fut in list(self._pending.values()):
            if not fut.done():
                fut.set_exception(RuntimeError("agent FIFO recycled"))
        self._pending.clear()

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
        # FIFO may briefly block; retry with a hard deadline so a stalled reader
        # cannot freeze the journal tail (and leave permissions unanswered).
        remaining = data
        deadline = time.monotonic() + 5.0
        while remaining:
            try:
                n = os.write(self._fifo_fd, remaining)
                remaining = remaining[n:]
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(
                        f"FIFO write timed out ({len(data) - len(remaining)}/"
                        f"{len(data)} bytes)"
                    )
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
        methods = result.get("authMethods") or result.get("auth_methods") or []
        self.auth_methods = [
            str(m.get("id"))
            for m in methods
            if isinstance(m, dict) and m.get("id")
        ]
        await self._notify("initialized", {})

    async def _authenticate_env_key(self) -> bool:
        """codex-acp only picks up OPENAI_API_KEY after an explicit ACP
        `authenticate` for that method; `chatgpt` must never be requested
        headless (it blocks on a browser)."""
        for method_id in ("api-key", "openai-api-key", "codex-api-key"):
            if method_id not in self.auth_methods:
                continue
            try:
                await self._request(
                    "authenticate", {"methodId": method_id}, timeout=20.0
                )
                return True
            except Exception:  # noqa: BLE001
                continue
        return False

    @staticmethod
    def _is_auth_required(exc: BaseException) -> bool:
        text = str(exc).lower()
        return "authentication required" in text or (
            "-32000" in text and "auth" in text
        )

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
        params = {"cwd": self.cwd, "mcpServers": mcp_servers}
        # codex-acp refreshes its model catalogue on first start.
        timeout = 45.0 if self.provider == "codex" else 25.0
        try:
            result = await self._request("session/new", params, timeout=timeout)
        except Exception as e:  # noqa: BLE001
            if not self._is_auth_required(e):
                raise
            if self.provider == "codex" and await self._authenticate_env_key():
                result = await self._request(
                    "session/new", params, timeout=timeout
                )
            else:
                raise RuntimeError(self._auth_required_hint()) from e
        self.acp_session_id = (
            result.get("sessionId") or result.get("session_id")
        )
        self._apply_models(result.get("models"))
        self._apply_config_options(
            result.get("configOptions") or result.get("config_options")
        )
        self._apply_modes(result.get("modes"))
        self._persist_session_id()
        # Fresh ACP sessions have no memory — inject durable chat on next prompt.
        self._needs_history_bootstrap = True
        self._reap_stale_claude_children()

    def _auth_required_hint(self) -> str:
        if self.provider == "codex":
            return (
                "Codex is not logged in on this host — run `codex login` "
                "there or save an OpenAI API key in Agent Dock Settings"
            )
        if self.provider == "claude":
            return (
                "Claude is not logged in on this host — run `claude login` "
                "there or save an Anthropic API key in Agent Dock Settings"
            )
        return "Agent authentication required — run `agent login` on this host"

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
            self._apply_config_options(
                result.get("configOptions") or result.get("config_options")
            )
            self._apply_modes(result.get("modes"))
            self._persist_session_id()
        finally:
            self._replaying = False
        self._reap_stale_claude_children()

    def _reap_stale_claude_children(self) -> None:
        """Drop leaked Claude SDK processes left behind by session/new cycles."""
        try:
            killed = process_hygiene.reap_claude_children_for_tmux(
                paths.tmux_session_name(self.chat_id)
            )
            if killed:
                # Best-effort log into the session journal via stderr of daemon.
                print(
                    f"ADSM reap: killed {killed} stale claude child(ren) "
                    f"for {self.chat_id}",
                    flush=True,
                )
        except Exception:  # noqa: BLE001
            pass

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

    def _apply_config_options(self, config_options: Any) -> None:
        if isinstance(config_options, list):
            ids = set()
            for entry in config_options:
                if isinstance(entry, dict):
                    eid = entry.get("id") or entry.get("configId")
                    if eid:
                        ids.add(str(eid))
                    if eid == "collaboration_mode":
                        cur = entry.get("currentValue") or entry.get("current_value")
                        self._codex_plan = str(cur or "") == "plan"
            if ids:
                self._config_option_ids = ids
        if self.provider == "codex":
            out = codex_models_from_config_options(config_options)
            cur = codex_current_model_from_config_options(config_options)
        else:
            out = models_from_config_options(config_options)
            cur = current_model_from_config_options(config_options)
        if out:
            self.available_models = out
            self._models_via_config_option = True
        if cur is not None:
            self.model_id = cur
        if out or cur is not None:
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
            self.mode = self._app_mode_id(str(cur))

    async def set_mode(self, mode_id: str) -> None:
        if not self.acp_session_id:
            raise RuntimeError("ACP session not ready")
        resolved = self._resolve_mode_id(mode_id)
        if not resolved:
            return
        # Avoid spamming Claude with ids it rejects (app uses ask/agent/plan).
        if (
            self.available_modes
            and resolved not in self.available_modes
            and resolved.lower()
            not in {m.lower() for m in self.available_modes}
        ):
            raise RuntimeError(
                f"Invalid Mode {resolved!r} (available: {self.available_modes})"
            )
        try:
            await self._request(
                "session/set_mode",
                {"sessionId": self.acp_session_id, "modeId": resolved},
                timeout=15.0,
            )
        except Exception as e:  # noqa: BLE001
            if not _is_acp_method_not_found(e, "session/set_mode"):
                raise
            await self._request(
                "session/set_config_option",
                {
                    "sessionId": self.acp_session_id,
                    "configId": "mode",
                    "type": "id",
                    "value": resolved,
                },
                timeout=15.0,
            )
        if self.provider == "codex":
            await self._set_codex_plan(mid_is_plan=mode_id.strip().lower() == "plan")
        self.mode = self._app_mode_id(resolved)
        await self._emit_event("mode", mode=self.mode)

    async def _set_codex_plan(self, *, mid_is_plan: bool) -> None:
        """Codex plan mode is `collaboration_mode=plan` on top of read-only."""
        if "collaboration_mode" not in self._config_option_ids:
            self._codex_plan = False
            return
        value = "plan" if mid_is_plan else "default"
        if self._codex_plan == mid_is_plan:
            return
        try:
            await self._request(
                "session/set_config_option",
                {
                    "sessionId": self.acp_session_id,
                    "configId": "collaboration_mode",
                    "type": "id",
                    "value": value,
                },
                timeout=15.0,
            )
            self._codex_plan = mid_is_plan
        except Exception as e:  # noqa: BLE001
            self.last_error = f"collaboration_mode: {e}"

    def _app_mode_id(self, native: str) -> str:
        """Map a provider mode id back to the app's ask/agent/plan."""
        n = (native or "").strip()
        low = n.lower()
        if self.provider == "codex":
            if self._codex_plan:
                return "plan"
            if low in ("ask", "agent"):
                return low
            if low == "read-only":
                return "ask"
            if low in ("agent-full-access", "full-access", "auto"):
                return "agent"
            return n
        if low in ("ask", "agent", "plan"):
            return low
        if self.provider == "claude":
            if low == "dontask":
                return "ask"
            if low in ("default", "acceptedits", "bypasspermissions", "auto"):
                return "agent"
            return n
        return n

    def _resolve_mode_id(self, mode_id: str) -> str:
        """Map app modes (ask/agent/plan) onto provider ACP mode ids."""
        mid = (mode_id or "").strip()
        if not mid:
            return mid
        available = list(self.available_modes or [])
        by_lower = {m.lower(): m for m in available}
        # Codex advertises an `agent` id too, but the app's "agent" must
        # become full access when the chat runs with the allow-all policy,
        # so map before the exact-match shortcut.
        if mid.lower() in by_lower and self.provider != "codex":
            return by_lower[mid.lower()]
        if self.provider == "codex":
            # codex-acp approval presets: read-only ("ask for approval"),
            # agent ("approve for me"), agent-full-access. Plan is a separate
            # `collaboration_mode` config option layered on read-only (see
            # set_mode), so it maps to read-only here.
            if mid.lower() == "agent":
                candidates = (
                    ["agent-full-access", "full-access", "agent", "auto"]
                    if self.full_access
                    else ["agent", "auto"]
                )
            elif mid.lower() in ("ask", "plan"):
                candidates = ["read-only"]
            else:
                candidates = [mid]
            for c in candidates:
                if c.lower() in by_lower:
                    return by_lower[c.lower()]
            return candidates[0]
        if self.provider == "claude":
            # Claude ACP: auto/default/acceptEdits/plan/dontAsk/bypassPermissions
            if mid.lower() == "agent":
                prefer = (
                    "bypassPermissions" if self.full_access else "default"
                )
            elif mid.lower() == "ask":
                prefer = "dontAsk"
            elif mid.lower() == "plan":
                prefer = "plan"
            else:
                prefer = mid
            if prefer.lower() in by_lower:
                return by_lower[prefer.lower()]
            if self.full_access and "bypasspermissions" in by_lower:
                return by_lower["bypasspermissions"]
            if "default" in by_lower:
                return by_lower["default"]
            return prefer
        return mid

    def _turn_in_flight(self) -> bool:
        if self._turn_task is not None and not self._turn_task.done():
            return True
        return self.status in (
            protocol.STATUS_RUNNING,
            protocol.STATUS_WAITING_PERMISSION,
        )

    async def set_model(self, model_id: str) -> None:
        if not self.acp_session_id:
            raise RuntimeError("ACP session not ready")

        async def via_config_option() -> None:
            result = await self._set_model_config_options(model_id)
            # Response carries the authoritative currentValue (may be a
            # canonical id rather than the alias we sent).
            opts = result.get("configOptions") or result.get("config_options")
            self._apply_config_options(opts)
            confirmed = (
                codex_current_model_from_config_options(opts)
                if self.provider == "codex"
                else current_model_from_config_options(opts)
            )
            self.model_id = confirmed or model_id
            self._models_via_config_option = True

        async def via_set_model() -> None:
            await self._request(
                "session/set_model",
                {"sessionId": self.acp_session_id, "modelId": model_id},
                timeout=15.0,
            )
            self.model_id = model_id
            self._models_via_config_option = False

        prefer_config = (
            _uses_config_options(self.provider) or self._models_via_config_option
        )
        switched = False
        if prefer_config:
            try:
                await via_config_option()
                switched = True
            except Exception as e:  # noqa: BLE001
                if not _is_acp_method_not_found(e, "session/set_config_option"):
                    raise
                try:
                    await via_set_model()
                    switched = True
                except Exception as e2:  # noqa: BLE001
                    if not _is_acp_method_not_found(e2, "session/set_model"):
                        raise
        else:
            try:
                await via_set_model()
                switched = True
            except Exception as e:  # noqa: BLE001
                if not _is_acp_method_not_found(e, "session/set_model"):
                    raise
                try:
                    await via_config_option()
                    switched = True
                except Exception as e2:  # noqa: BLE001
                    if not _is_acp_method_not_found(e2, "session/set_config_option"):
                        raise

        if not switched:
            await self._relaunch_for_model(model_id)

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

    async def _set_model_config_options(self, model_id: str) -> dict[str, Any]:
        """`session/set_config_option` for the model; Codex presets also
        carry a reasoning effort that is a second option."""
        value = model_id
        effort: Optional[str] = None
        if self.provider == "codex":
            value, effort = split_codex_model_id(model_id)
        result = await self._request(
            "session/set_config_option",
            {
                "sessionId": self.acp_session_id,
                "configId": "model",
                "type": "id",
                "value": value,
            },
            timeout=15.0,
        )
        if effort:
            result = await self._request(
                "session/set_config_option",
                {
                    "sessionId": self.acp_session_id,
                    "configId": "reasoning_effort",
                    "type": "id",
                    "value": effort,
                },
                timeout=15.0,
            )
        return result if isinstance(result, dict) else {}

    async def _relaunch_for_model(self, model_id: str) -> None:
        """Old ACP adapters lack model RPCs — restart with startup model flags."""
        self.model_id = model_id
        await self._detach_fifo()

        tmux = paths.tmux_session_name(self.chat_id)
        await asyncio.to_thread(
            subprocess.run,
            ["tmux", "kill-session", "-t", tmux],
            capture_output=True,
        )
        await asyncio.to_thread(
            ensure_tmux_worker,
            chat_id=self.chat_id,
            cwd=self.cwd,
            binary=self.binary,
            provider=self.provider,
            api_key=None,
            full_access=self.full_access,
            model_id=model_id,
        )
        await self._attach_pipes()
        await self._initialize()
        # Fresh session so startup --model / CLAUDE_ACP_MODEL apply cleanly.
        await self._open_session(mcp_servers=[], resume_session_id=None)
        self._persist_session_id()
        # Prefer the id we asked for when the agent omits currentModelId.
        if not self.model_id:
            self.model_id = model_id
        # One more RPC attempt in case the restarted binary is newer.
        try:
            if _uses_config_options(self.provider) or self._models_via_config_option:
                result = await self._set_model_config_options(model_id)
                opts = result.get("configOptions") or result.get("config_options")
                self._apply_config_options(opts)
                confirmed = (
                    codex_current_model_from_config_options(opts)
                    if self.provider == "codex"
                    else current_model_from_config_options(opts)
                )
                self.model_id = confirmed or model_id
        except Exception:  # noqa: BLE001
            pass
        if not self.model_id:
            self.model_id = model_id

    def _clear_acp_session(self) -> None:
        self.acp_session_id = None
        self._needs_history_bootstrap = True
        sid_path = self.dir / "acp_session_id"
        try:
            sid_path.unlink(missing_ok=True)
        except OSError:
            pass

    def _history_bootstrap_prompt(
        self, *, exclude_message_id: Optional[str] = None
    ) -> str:
        """Format recent durable transcript so a fresh session keeps context."""
        rows = transcript_store.list_messages(self.chat_id)
        if not rows:
            return ""
        budget = 28_000
        used = 0
        picked: list[dict[str, Any]] = []
        for row in reversed(rows):
            mid = str(row.get("id") or "")
            if exclude_message_id and mid == exclude_message_id:
                continue
            role = str(row.get("role") or "").lower()
            if role not in ("user", "assistant"):
                continue
            content = str(row.get("content") or "").strip()
            if not content:
                continue
            if len(content) > 6_000:
                content = content[:6_000].rstrip() + "\n…(truncated)"
            chunk_len = len(content) + 16
            if used + chunk_len > budget and picked:
                break
            picked.append(
                {"role": role, "content": content}
            )
            used += chunk_len
            if len(picked) >= 40:
                break
        picked.reverse()
        if not picked:
            return ""
        lines = []
        for row in picked:
            label = "User" if row["role"] == "user" else "Assistant"
            lines.append(f"{label}:\n{row['content']}")
        body = "\n\n".join(lines)
        return (
            "[Agent Dock] The previous ACP session ended (stop/cancel or "
            "restart). Here is the recent chat history from this agent so you "
            "keep full context. Do not re-explore work already covered below "
            "unless the user asks.\n\n"
            f"{body}\n\n"
            "---\n"
            "Continue from this history. The user's latest message follows."
        )

    async def _ensure_acp_session(self) -> None:
        """Mint a session when cancel/crash left us without a usable id."""
        if self.acp_session_id:
            return
        alive = await asyncio.to_thread(self._tmux_alive)
        if self._fifo_fd is None or not alive:
            await self._revive_transport()
            if self.acp_session_id:
                return
        await self._initialize()
        await self._open_session(mcp_servers=[], resume_session_id=None)

    async def prompt(
        self,
        text: str,
        images: Optional[list] = None,
        *,
        user_message_id: Optional[str] = None,
        user_created_at: Optional[str] = None,
    ) -> dict[str, Any]:
        self.touch_activity()
        try:
            await self._revive_transport()
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(f"FIFO not attached: {e}") from e
        if not self.acp_session_id:
            try:
                await self._ensure_acp_session()
            except Exception as e:  # noqa: BLE001
                raise RuntimeError(f"ACP session not ready: {e}") from e
        if not self.acp_session_id:
            raise RuntimeError("ACP session not ready")
        if self._turn_task is not None and not self._turn_task.done():
            raise RuntimeError(
                "agent is already running a turn — wait for it to finish"
            )
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
        # Ack to the phone *before* the long ACP call so the UI can leave
        # "Sending…" and enter Thinking, and so retries know the host has it.
        await self._emit_event(
            "prompt_accepted",
            userMessageId=self._turn_user_id,
            status=protocol.STATUS_RUNNING,
        )
        await self._emit_event("status", status=protocol.STATUS_RUNNING)
        await self._emit_event("activity", label="Thinking")

        async def _run_turn() -> None:
            try:
                result = await self._prompt_acp(blocks)
                stop = (
                    result.get("stopReason")
                    if isinstance(result, dict)
                    else "end_turn"
                )
                self._persist_assistant_turn()
                await self._emit_event(
                    "turn_complete", reason=stop or "end_turn"
                )
                await self._set_status(self.chat_id, protocol.STATUS_IDLE, None)
                await self._emit_event("status", status=protocol.STATUS_IDLE)
            except asyncio.CancelledError:
                self._persist_assistant_turn()
                await self._emit_event("turn_complete", reason="cancelled")
                await self._set_status(self.chat_id, protocol.STATUS_IDLE, None)
                await self._emit_event("status", status=protocol.STATUS_IDLE)
                raise
            except Exception as e:  # noqa: BLE001
                self.last_error = str(e)
                self._persist_assistant_turn()
                await self._set_status(
                    self.chat_id, protocol.STATUS_ERROR, str(e)
                )
                await self._emit_event("error", text=str(e))
                await self._set_status(self.chat_id, protocol.STATUS_IDLE, None)
                await self._emit_event("status", status=protocol.STATUS_IDLE)

        self._turn_task = asyncio.create_task(_run_turn())
        return {
            "accepted": True,
            "userMessageId": self._turn_user_id,
            "status": protocol.STATUS_RUNNING,
        }

    async def _prompt_acp(self, blocks: list[dict[str, Any]]) -> Any:
        """Run session/prompt; on Session not found, mint a new session and retry once."""

        async def _send(payload_blocks: list[dict[str, Any]]) -> Any:
            use_blocks = list(payload_blocks)
            if self._needs_history_bootstrap:
                hist = self._history_bootstrap_prompt(
                    exclude_message_id=self._turn_user_id
                )
                self._needs_history_bootstrap = False
                if hist:
                    use_blocks = [{"type": "text", "text": hist}, *use_blocks]
                    await self._emit_event(
                        "activity", label="Restoring chat context…"
                    )
            return await self._request(
                "session/prompt",
                {
                    "sessionId": self.acp_session_id,
                    "prompt": use_blocks,
                },
                timeout=600.0,
            )

        try:
            return await _send(blocks)
        except Exception as e:  # noqa: BLE001
            if not _is_session_not_found(e):
                raise
            await self._emit_event(
                "activity", label="Session expired — opening a new one…"
            )
            self._clear_acp_session()
            await self._ensure_acp_session()
            return await _send(blocks)

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
        task = self._turn_task
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
            except Exception:  # noqa: BLE001
                pass
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
        await self._emit_event("status", status=protocol.STATUS_IDLE)
        # Claude ACP often drops the session after cancel. Clear so the next
        # prompt mints session/new instead of failing with Session not found.
        if (self.provider or "").lower() == "claude":
            self._clear_acp_session()

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
        if kind not in ("text", "thought", "activity"):
            self.touch_activity()
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
        ):
            return

        if typ in ("config_option_update", "configOptionUpdate"):
            opts = (
                update.get("configOptions")
                or update.get("config_options")
                or update.get("options")
            )
            if opts is None and isinstance(update.get("configOption"), dict):
                opts = [update["configOption"]]
            if opts is not None:
                self._apply_config_options(opts)
                await self._emit_event(
                    "session",
                    acpSessionId=self.acp_session_id,
                    models=self.available_models,
                    modes=self.available_modes,
                    mode=self.mode,
                    modelId=self.model_id,
                    loadSession=self.load_session,
                )
            return

        if typ in ("current_mode_update", "currentModeUpdate"):
            mid = str(update.get("modeId") or update.get("currentModeId") or "")
            if mid:
                self.mode = self._app_mode_id(mid)
                await self._emit_event("mode", mode=self.mode)
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

        if typ == "plan":
            # Codex/Claude TODO lists: surface the active step as activity
            # and forward the entries for clients that render them.
            entries = update.get("entries")
            if isinstance(entries, list):
                active = next(
                    (
                        e
                        for e in entries
                        if isinstance(e, dict)
                        and str(e.get("status") or "") == "in_progress"
                    ),
                    None,
                )
                if active and active.get("content"):
                    label = str(active["content"])
                    if len(label) > 48:
                        label = label[:47] + "…"
                    await self._emit_event("activity", label=label)
                await self._emit_event("plan", entries=entries)
            return

        if typ in ("session_info_update", "sessionInfoUpdate"):
            title = update.get("title")
            if title:
                await self._emit_event("status", title=str(title))
            # codex-acp reports transport/auth failures here while it retries;
            # surface the final one so the phone can offer re-auth.
            meta = update.get("_meta")
            codex = meta.get("codex") if isinstance(meta, dict) else None
            err = codex.get("error") if isinstance(codex, dict) else None
            if isinstance(err, dict) and not err.get("willRetry"):
                detail = str(
                    err.get("additionalDetails") or err.get("message") or ""
                ).strip()
                if detail:
                    await self._emit_event("error", text=detail[:2000])
            return

        if typ in ("usage_update", "usageUpdate"):
            used = update.get("used")
            size = update.get("size")
            try:
                used_i = int(used) if used is not None else None
                size_i = int(size) if size is not None else None
            except (TypeError, ValueError):
                return
            if used_i is None or size_i is None:
                return
            cost = update.get("cost")
            await self._emit_event(
                "usage",
                used=used_i,
                size=size_i,
                cost=cost if isinstance(cost, dict) else None,
            )
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
                self._merge_terminal_output(update, tool)
                kind = (
                    "tool_start"
                    if typ in ("tool_call", "toolCall")
                    else "tool_update"
                )
                label = str(tool.get("title") or "Tool")
                if len(label) > 48:
                    label = label[:47] + "…"
                status = str(tool.get("status") or "").lower()
                if status in ("", "pending", "in_progress", "running"):
                    await self._emit_event("activity", label=label)
                await self._emit_event(kind, tool=tool)
            return

        text = _extract_text(update)
        if text:
            await self._emit_event("text", text=text)

    def _merge_terminal_output(
        self, update: dict[str, Any], tool: dict[str, Any]
    ) -> None:
        """codex-acp streams shell output as `_meta.terminal_output_delta`
        rather than through a client terminal; fold it into rawOutput so the
        phone's tool card shows live output."""
        meta = update.get("_meta")
        if not isinstance(meta, dict):
            return
        tid = str(tool.get("toolCallId") or "")
        if not tid:
            return
        delta = meta.get("terminal_output_delta")
        snapshot = meta.get("terminal_output")
        if isinstance(delta, dict) and isinstance(delta.get("data"), str):
            buf = self._term_output.get(tid, "") + delta["data"]
            if len(buf) > 64_000:
                buf = buf[-48_000:]
            self._term_output[tid] = buf
        elif isinstance(snapshot, dict) and isinstance(snapshot.get("data"), str):
            self._term_output[tid] = snapshot["data"][-64_000:]
        if tool.get("rawOutput") is None and tid in self._term_output:
            tool["rawOutput"] = self._term_output[tid]
        if isinstance(meta.get("terminal_exit"), dict) or str(
            tool.get("status") or ""
        ).lower() in ("completed", "failed", "error", "cancelled"):
            self._term_output.pop(tid, None)

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
            # Auto-allow: always pick an id that exists on the prompt.
            pick = None
            # ACP `kind` is authoritative; codex-acp's ids (`approved`,
            # `abort`) don't contain allow/always.
            for want in ("allow_always", "allow_once"):
                for o in options:
                    if str(o.get("kind") or "") == want and o.get("optionId"):
                        pick = str(o["optionId"])
                        break
                if pick is not None:
                    break
            if pick is None:
                for o in options:
                    oid = str(o.get("optionId") or "")
                    low = oid.lower()
                    if "always" in low:
                        pick = oid
                        break
            if pick is None:
                for o in options:
                    oid = str(o.get("optionId") or "")
                    low = oid.lower()
                    if "allow" in low and "reject" not in low:
                        pick = oid
                        break
            if pick is None and options:
                pick = str(options[0].get("optionId") or "allow")
            if not pick:
                pick = "allow"
            try:
                await self._write(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "outcome": {"outcome": "selected", "optionId": pick}
                        },
                    }
                )
            except Exception as e:  # noqa: BLE001
                self.last_error = f"auto_allow_permission: {e}"
                # Fall through to ask-mode UI so the phone can unblock.
            else:
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
        # Phone must learn the host stopped the worker (idle reaper) — otherwise
        # it keeps "live" chrome and the next prompt hits a cold FIFO.
        await self._emit_event("status", status=protocol.STATUS_DEAD)
        await self._emit_event(
            "activity",
            label="Agent paused on host — will resume on next message",
        )


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
    # Prefer MCP / Task descriptions when Claude only sends title=Tool.
    if title == "Tool" or title.lower() == "tool":
        raw_in = nested.get("rawInput") or update.get("rawInput")
        if isinstance(raw_in, str) and raw_in:
            head = raw_in[:4000]
            for key in ("description", "prompt", "command", "cmd", "path", "query"):
                marker = f'"{key}"'
                i = head.find(marker)
                if i < 0:
                    continue
                colon = head.find(":", i + len(marker))
                if colon < 0:
                    continue
                rest = head[colon + 1 :].lstrip()
                if rest.startswith('"'):
                    end = 1
                    while end < len(rest):
                        if rest[end] == '"' and rest[end - 1] != "\\":
                            break
                        end += 1
                    val = rest[1:end].replace("\\n", " ").replace('\\"', '"')
                    val = " ".join(val.split())
                    if val:
                        title = val[:80] + ("…" if len(val) > 80 else "")
                        break
        kind_l = str(nested.get("kind") or update.get("kind") or "").lower()
        if title in ("Tool", "tool"):
            if "think" in kind_l or "task" in kind_l or "agent" in kind_l:
                title = "Subagent"
            elif "read" in kind_l:
                title = "Read"
            elif "exec" in kind_l or "shell" in kind_l or "terminal" in kind_l:
                title = "Terminal"
            elif "mcp" in kind_l:
                title = "MCP"

    if not tid and title in ("Tool", "tool"):
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
