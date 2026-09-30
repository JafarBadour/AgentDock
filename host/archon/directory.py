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
            "managed": is_managed(record),
            "goal": goal_of(record),
            "effectiveGoal": effective_goal_of(record),
            "note": note_of(record),
        }
        if host:
            entry["host"] = host
        out.append(entry)
    return out


def commandable(records: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    return [r for r in records if is_commandable(r)]


# --- auto-management -------------------------------------------------------
#
# The user picks which agents Archon looks after and gives each a goal. Archon
# works toward that goal, and when it is met it switches the agent back off and
# leaves a note saying what happened — so the toggle means "Archon is still on
# this", not "Archon was once asked about this".

MANAGED = "archon_managed"
GOAL = "archon_goal"

# What Archon does for an agent switched on without a goal of its own. Most
# agents do not need a brief — the useful default is simply to keep the
# conversation moving the way the user would, and to interrupt them rarely.
DEFAULT_GOAL = (
    "Answer this agent's chat the way the user would, keeping its work "
    "moving. Only bring something to the user when it genuinely needs them."
)
NOTE = "archon_note"
DONE_AT = "archon_done_at"


def is_managed(record: dict[str, Any]) -> bool:
    return bool(record.get(MANAGED))


def goal_of(record: dict[str, Any]) -> Optional[str]:
    """The goal the user typed, or None if they did not type one."""
    goal = record.get(GOAL)
    return goal.strip() if isinstance(goal, str) and goal.strip() else None


def effective_goal_of(record: dict[str, Any]) -> str:
    """What Archon should actually work toward — never empty.

    A goal is optional. Requiring one made switching an agent on a small piece
    of paperwork, when the common case is "just keep this moving".
    """
    return goal_of(record) or DEFAULT_GOAL


def note_of(record: dict[str, Any]) -> Optional[str]:
    note = record.get(NOTE)
    return note.strip() if isinstance(note, str) and note.strip() else None


def manageable(records: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Agents Archon should actually be working on.

    Being switched on is not enough: the permission gate still applies, so an
    agent the user later moved to Ask drops out of Archon's work even though
    its toggle is still on. The toggle is the user's intent; the permission is
    the user's authority, and the narrower one wins.
    """
    return [r for r in records if is_managed(r) and is_commandable(r)]


def blocked(records: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Switched on, but Archon may not touch them — worth saying out loud."""
    return [r for r in records if is_managed(r) and not is_commandable(r)]


def complete(
    chat_id: str,
    note: str,
    *,
    at: Optional[str] = None,
    agents_dir: Optional[Path] = None,
) -> Optional[dict[str, Any]]:
    """Mark the goal met: switch the agent off and record why.

    Writing both in one step is the point — a toggle left on with a note
    attached would read as work still in progress.
    """
    from datetime import datetime, timezone

    directory = agents_dir or adsm_paths.agents_dir()
    path = directory / f"{adsm_paths.safe_chat_id(chat_id)}.json"
    if not path.exists():
        return None
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(record, dict):
        return None

    record[MANAGED] = False
    record[NOTE] = note.strip()
    record[DONE_AT] = at or datetime.now(timezone.utc).isoformat()
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, indent=2), encoding="utf-8")
    tmp.replace(path)
    return record
