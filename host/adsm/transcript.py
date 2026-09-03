"""Durable UI transcript under ~/.agentdock/messages/<chatId>.jsonl."""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from . import paths


def messages_dir() -> Path:
    return paths.agentdock_root() / "messages"


def messages_path(chat_id: str) -> Path:
    return messages_dir() / f"{paths.safe_chat_id(chat_id)}.jsonl"


def ensure_messages_dir() -> None:
    messages_dir().mkdir(parents=True, exist_ok=True)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _normalize(row: dict[str, Any], chat_id: str) -> Optional[dict[str, Any]]:
    msg_id = str(row.get("id") or "").strip()
    role = str(row.get("role") or "").strip()
    content = row.get("content")
    if not msg_id or not role or content is None:
        return None
    created = str(row.get("created_at") or row.get("createdAt") or _now_iso())
    return {
        "id": msg_id,
        "chat_id": str(row.get("chat_id") or row.get("chatId") or chat_id),
        "role": role,
        "content": str(content),
        "created_at": created,
    }


def list_messages(chat_id: str) -> list[dict[str, Any]]:
    """Return deduped messages (longest content wins per id), sorted by time."""
    path = messages_path(chat_id)
    if not path.exists():
        return []
    by_id: dict[str, dict[str, Any]] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                raw = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(raw, dict):
                continue
            row = _normalize(raw, chat_id)
            if row is None:
                continue
            prev = by_id.get(row["id"])
            if prev is None or len(row["content"]) >= len(prev["content"]):
                by_id[row["id"]] = row
    except OSError:
        return []
    out = list(by_id.values())
    out.sort(key=lambda m: (str(m.get("created_at") or ""), str(m.get("id"))))
    return out


def append_message(
    chat_id: str,
    *,
    role: str,
    content: str,
    message_id: Optional[str] = None,
    created_at: Optional[str] = None,
) -> dict[str, Any]:
    ensure_messages_dir()
    row = {
        "id": message_id or str(uuid.uuid4()),
        "chat_id": chat_id,
        "role": role,
        "content": content,
        "created_at": created_at or _now_iso(),
    }
    path = messages_path(chat_id)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    return row


def upsert_messages(chat_id: str, messages: list[dict[str, Any]]) -> int:
    """Merge [messages] into the host file (id keyed, longer body wins)."""
    ensure_messages_dir()
    existing = {m["id"]: m for m in list_messages(chat_id)}
    changed = 0
    for raw in messages:
        if not isinstance(raw, dict):
            continue
        row = _normalize(raw, chat_id)
        if row is None:
            continue
        prev = existing.get(row["id"])
        if prev is None:
            existing[row["id"]] = row
            changed += 1
        elif len(row["content"]) > len(prev["content"]):
            existing[row["id"]] = row
            changed += 1
    if changed == 0 and messages:
        # Still rewrite if file was corrupt/empty but we had rows — cheap path.
        pass
    path = messages_path(chat_id)
    ordered = sorted(
        existing.values(),
        key=lambda m: (str(m.get("created_at") or ""), str(m.get("id"))),
    )
    tmp = path.with_suffix(".jsonl.tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        for row in ordered:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    tmp.replace(path)
    return changed


def clear_messages(chat_id: str) -> bool:
    path = messages_path(chat_id)
    if path.exists():
        path.unlink(missing_ok=True)
        return True
    return False
