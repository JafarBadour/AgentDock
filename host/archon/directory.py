"""What Archon can see, and what it is allowed to drive.

Archon acts with the user's own permissions — it is not a second authority.
So the line it must not cross is the one the user already drew per agent:

- **Allow all** — the user has said this agent may act without being asked.
  Archon may command it.
- **Ask** — the user wants to approve each tool on their device. Archon is
  not that device and cannot stand in for that approval, so it may look but
  not touch.

An agent Archon cannot command is still listed. Hiding it would leave Archon
unable to explain why work is not happening, and "that one is on Ask, switch
it if you want me to run it" is the useful answer.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable, Optional

from adsm import paths as adsm_paths

ASK = "ask"
ALLOW_ALL = "allow_all"


def policy_of(record: dict[str, Any]) -> str:
    """The user's permission choice for this agent.

    A record without the field predates it being written down, and an unknown
    permission is not a granted one: it reads as [ASK], so Archon leaves the
    agent alone until the user opens it once and the choice is recorded.
    """
    value = record.get("permission_ask")
    if value is None:
        return ASK
    return ASK if bool(value) else ALLOW_ALL


def is_commandable(record: dict[str, Any]) -> bool:
    """Whether Archon may send this agent work."""
    return policy_of(record) == ALLOW_ALL


def refusal_for(record: dict[str, Any]) -> Optional[str]:
    """Why Archon will not drive this agent, in words it can say aloud."""
    if is_commandable(record):
        return None
    title = record.get("title") or record.get("id") or "that agent"
    return (
        f'"{title}" is set to Ask, so it needs you to approve each tool. '
        "Switch it to Allow all if you want me to run it."
    )


def load_records(agents_dir: Optional[Path] = None) -> list[dict[str, Any]]:
    """Every agent record on this host, oldest id first for a stable order."""
    directory = agents_dir or adsm_paths.agents_dir()
    if not directory.exists():
        return []
    out: list[dict[str, Any]] = []
    for path in sorted(directory.glob("*.json")):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(record, dict) and record.get("id"):
            out.append(record)
    return out


def describe(
    records: Iterable[dict[str, Any]], *, host: Optional[str] = None
) -> list[dict[str, Any]]:
    """The directory Archon reads: who exists, and what may be done with them.

    Deliberately not the whole record — Archon decides what to look at next
    from names, recency and status, and pulling transcripts for every agent on
    every host to answer "what is going on" would be the expensive habit this
    directory exists to avoid.
    """
    out: list[dict[str, Any]] = []
    for record in records:
        entry = {
            "chatId": record.get("id"),
            "title": record.get("title"),
            "provider": record.get("provider"),
            "status": record.get("status"),
            "repo": record.get("repo_name") or record.get("repo_path"),
            "lastActivity": record.get("updated_at"),
            "permission": policy_of(record),
            "commandable": is_commandable(record),
        }
        if host:
            entry["host"] = host
        out.append(entry)
    return out


def commandable(records: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    return [r for r in records if is_commandable(r)]
