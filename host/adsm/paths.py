"""Filesystem layout under ~/.agentdock."""

from __future__ import annotations

import os
from pathlib import Path


def home() -> Path:
    return Path(os.path.expanduser("~")).resolve()


def agentdock_root() -> Path:
    return home() / ".agentdock"


def socket_path() -> Path:
    return agentdock_root() / "adsm.sock"


def pid_path() -> Path:
    return agentdock_root() / "adsm.pid"


def log_path() -> Path:
    return agentdock_root() / "adsm.log"


def agents_dir() -> Path:
    return agentdock_root() / "agents"


def sessions_dir() -> Path:
    return agentdock_root() / "sessions"


def safe_chat_id(chat_id: str) -> str:
    return "".join(c for c in chat_id if c.isalnum() or c in "-_")


def session_dir(chat_id: str) -> Path:
    return sessions_dir() / safe_chat_id(chat_id)


def tmux_session_name(chat_id: str) -> str:
    safe = safe_chat_id(chat_id)
    return f"ad-{safe[:24]}"


def agent_record_path(chat_id: str) -> Path:
    return agents_dir() / f"{safe_chat_id(chat_id)}.json"


def ensure_layout() -> None:
    agentdock_root().mkdir(parents=True, exist_ok=True)
    agents_dir().mkdir(parents=True, exist_ok=True)
    sessions_dir().mkdir(parents=True, exist_ok=True)
    # Restrict socket directory permissions.
    try:
        os.chmod(agentdock_root(), 0o700)
    except OSError:
        pass
