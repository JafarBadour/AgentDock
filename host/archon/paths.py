"""Filesystem layout under ~/.agentdock/archon.

All Archon state lives in one folder on whichever host currently runs it, so
migrating Archon between hosts is a folder move plus a restart.
"""

from __future__ import annotations

from pathlib import Path

from adsm import paths as adsm_paths


def archon_root() -> Path:
    return adsm_paths.agentdock_root() / "archon"


def chats_dir() -> Path:
    """One file per conversation Archon holds with an agent."""
    return archon_root() / "chats"


def memory_dir() -> Path:
    """What Archon chose to remember, outside any one conversation."""
    return archon_root() / "memory"


def db_path() -> Path:
    """Timers, reminders and scheduled jobs."""
    return archon_root() / "archon.db"


def workspace_dir() -> Path:
    """Archon's working directory.

    Its own folder rather than one of the user's repos: Archon directs agents
    and never executes anything itself, so it has no reason to sit inside code
    it might be asked about but must not touch.
    """
    return archon_root() / "workspace"


def chat_path(chat_id: str) -> Path:
    return chats_dir() / f"{adsm_paths.safe_chat_id(chat_id)}.jsonl"


def ensure_layout() -> None:
    for d in (archon_root(), chats_dir(), memory_dir(), workspace_dir()):
        d.mkdir(parents=True, exist_ok=True)
