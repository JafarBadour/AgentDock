"""Windows ACP worker processes (POSIX hosts use tmux + FIFO in worker.py).

Windows has no tmux and no FIFOs, so the daemon owns each agent directly: a
child process whose stdin is a pipe held here, with stdout appended to the same
`out.jsonl` journal the tmux worker writes. The journal tail, RPC and event
code in `Worker` are therefore shared.

The agent cannot outlive the daemon: when the daemon exits its stdin closes and
the agent ends. On restart the session dir reads as dead and the next ensure
resumes the ACP session by id, which is the same path an idle-stopped tmux
worker takes.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Mapping, Optional, Sequence

from . import paths

_procs: dict[str, subprocess.Popen[bytes]] = {}
_lock = threading.Lock()

# No console window per agent, and its own group so Ctrl+C in a terminal that
# started the daemon does not reach it.
_CREATION_FLAGS = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(
    subprocess, "CREATE_NEW_PROCESS_GROUP", 0
)


def agent_path_env(base: Optional[str] = None) -> str:
    """PATH with the usual per-user tool dirs (npm globals, ~/.local/bin) first."""
    home = Path(os.path.expanduser("~"))
    extra = [home / ".local" / "bin", home / ".cursor" / "bin"]
    appdata = os.environ.get("APPDATA")
    if appdata:
        extra.append(Path(appdata) / "npm")
    program_files = os.environ.get("ProgramFiles")
    if program_files:
        extra.append(Path(program_files) / "nodejs")
    parts = [str(p) for p in extra if p.is_dir()]
    current = os.environ.get("PATH", "") if base is None else base
    return os.pathsep.join(parts + ([current] if current else []))


def resolve_binary(binary: str, path_env: str) -> str:
    """Find a runnable file for [binary] (npm installs `.cmd` shims on Windows)."""
    candidate = Path(binary)
    if candidate.suffix and candidate.is_file():
        return str(candidate)
    if candidate.parent != Path("."):
        # Absolute or relative path given without an extension.
        for ext in (".exe", ".cmd", ".bat"):
            with_ext = candidate.with_name(candidate.name + ext)
            if with_ext.is_file():
                return str(with_ext)
        lookup = candidate.name
    else:
        lookup = binary
    found = shutil.which(lookup, path=path_env)
    if not found:
        raise RuntimeError(
            f"agent binary not found on This PC: {binary} "
            "(install it, e.g. `npm install -g @agentclientprotocol/claude-agent-acp`)"
        )
    return found


def alive(chat_id: str) -> bool:
    with _lock:
        proc = _procs.get(chat_id)
    return proc is not None and proc.poll() is None


def kill(chat_id: str) -> None:
    with _lock:
        proc = _procs.pop(chat_id, None)
    if proc is None:
        return
    try:
        if proc.stdin:
            proc.stdin.close()
    except OSError:
        pass
    if proc.poll() is None:
        # /T: npm `.cmd` shims start node (and Claude starts its SDK) as
        # children; terminating only the top process would orphan them.
        subprocess.run(
            ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
            capture_output=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def write(chat_id: str, data: bytes) -> None:
    with _lock:
        proc = _procs.get(chat_id)
    if proc is None or proc.stdin is None or proc.poll() is not None:
        raise RuntimeError("agent process not running")
    proc.stdin.write(data)
    proc.stdin.flush()


def ensure_worker(
    *,
    chat_id: str,
    cwd: str,
    binary: str,
    argv: Sequence[str],
    env: Mapping[str, str],
    full_access: bool,
    model_id: Optional[str],
) -> tuple[str, int]:
    """Start or adopt the agent process. Returns (state, journal_size).

    Mirrors `ensure_tmux_worker`: a live process started with the same
    permissions and model is kept, otherwise it is (re)started.
    """
    dir_path = paths.session_dir(chat_id)
    dir_path.mkdir(parents=True, exist_ok=True)
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

    if alive(chat_id):
        if have == want and have_model == want_model:
            state = "RUNNING"
        else:
            kill(chat_id)
            _start(chat_id, dir_path, cwd, binary, argv, env)
            state = "RESTARTED"
    else:
        journal.write_text("", encoding="utf-8")
        _start(chat_id, dir_path, cwd, binary, argv, env)
        state = "STARTED"
    marker.write_text(want, encoding="utf-8")
    model_marker.write_text(want_model, encoding="utf-8")

    return state, journal.stat().st_size


def _start(
    chat_id: str,
    dir_path: Path,
    cwd: str,
    binary: str,
    argv: Sequence[str],
    env: Mapping[str, str],
) -> None:
    child_env = dict(os.environ)
    child_env.update(env)
    child_env["PATH"] = agent_path_env(child_env.get("PATH", ""))
    exe = resolve_binary(binary, child_env["PATH"])
    if not Path(cwd).is_dir():
        raise RuntimeError(f"project folder not found: {cwd}")

    with (dir_path / "out.jsonl").open("ab") as out, (
        dir_path / "err.log"
    ).open("ab") as err:
        proc = subprocess.Popen(
            [exe, *argv],
            stdin=subprocess.PIPE,
            stdout=out,
            stderr=err,
            cwd=cwd,
            env=child_env,
            creationflags=_CREATION_FLAGS,
        )
    with _lock:
        _procs[chat_id] = proc
