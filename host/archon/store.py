"""Archon's own database: what wakes it, and what it remembers.

One SQLite file inside the Archon folder, so a host migration moves it with
everything else. Timers, reminders and carried-over Automate jobs share a
table because they differ only in where they came from, not in what the
daemon does with them: all three are "wake at this time and do this".
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator, Optional

from . import paths

# Where a scheduled entry came from. The daemon treats them alike; the label
# is kept so Archon can say "your reminder" rather than "your timer".
KIND_TIMER = "timer"
KIND_REMINDER = "reminder"
KIND_JOB = "job"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat()


def _parse(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


_SCHEMA = """
CREATE TABLE IF NOT EXISTS schedule (
  id TEXT PRIMARY KEY NOT NULL,
  kind TEXT NOT NULL,
  label TEXT NOT NULL,
  due_at TEXT NOT NULL,
  repeat_seconds INTEGER,
  payload TEXT,
  created_at TEXT NOT NULL,
  last_fired_at TEXT,
  done INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS schedule_due ON schedule (done, due_at);

CREATE TABLE IF NOT EXISTS memory (
  id TEXT PRIMARY KEY NOT NULL,
  scope TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS memory_scope ON memory (scope, created_at);
"""


class ArchonStore:
    """Timers and memory for one Archon instance."""

    def __init__(self, db_file: Optional[Path] = None) -> None:
        self._path = db_file or paths.db_path()
        self._path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as db:
            db.executescript(_SCHEMA)

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(str(self._path))
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        finally:
            db.close()

    # ---- schedule ----------------------------------------------------------

    def schedule(
        self,
        *,
        label: str,
        due_at: datetime,
        kind: str = KIND_TIMER,
        repeat_seconds: Optional[int] = None,
        payload: Optional[dict[str, Any]] = None,
        entry_id: Optional[str] = None,
    ) -> str:
        """Wake Archon at [due_at]. Returns the entry id."""
        if repeat_seconds is not None and repeat_seconds <= 0:
            raise ValueError("repeat_seconds must be positive")
        entry = entry_id or str(uuid.uuid4())
        with self._connect() as db:
            db.execute(
                "INSERT OR REPLACE INTO schedule "
                "(id, kind, label, due_at, repeat_seconds, payload, "
                " created_at, last_fired_at, done) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0)",
                (
                    entry,
                    kind,
                    label,
                    _iso(due_at),
                    repeat_seconds,
                    json.dumps(payload) if payload is not None else None,
                    _iso(now_utc()),
                ),
            )
        return entry

    def due(self, at: Optional[datetime] = None) -> list[dict[str, Any]]:
        """Entries that should fire by [at], oldest first."""
        moment = at or now_utc()
        with self._connect() as db:
            rows = db.execute(
                "SELECT * FROM schedule WHERE done = 0 AND due_at <= ? "
                "ORDER BY due_at ASC",
                (_iso(moment),),
            ).fetchall()
        return [self._row(r) for r in rows]

    def pending(self) -> list[dict[str, Any]]:
        with self._connect() as db:
            rows = db.execute(
                "SELECT * FROM schedule WHERE done = 0 ORDER BY due_at ASC"
            ).fetchall()
        return [self._row(r) for r in rows]

    def mark_fired(
        self, entry_id: str, *, at: Optional[datetime] = None
    ) -> Optional[datetime]:
        """Record that [entry_id] fired.

        A repeating entry is rolled forward past [at] and stays pending; a
        one-shot is closed. Rolling forward in whole periods (rather than
        adding one) means a daemon that was asleep for an hour fires a
        five-minute timer once on waking, not twelve times.

        Returns the next due time, or None when the entry is finished.
        """
        moment = at or now_utc()
        with self._connect() as db:
            row = db.execute(
                "SELECT * FROM schedule WHERE id = ?", (entry_id,)
            ).fetchone()
            if row is None:
                return None
            repeat = row["repeat_seconds"]
            if not repeat:
                db.execute(
                    "UPDATE schedule SET done = 1, last_fired_at = ? "
                    "WHERE id = ?",
                    (_iso(moment), entry_id),
                )
                return None
            step = timedelta(seconds=repeat)
            next_due = _parse(row["due_at"])
            while next_due <= moment:
                next_due += step
            db.execute(
                "UPDATE schedule SET due_at = ?, last_fired_at = ? "
                "WHERE id = ?",
                (_iso(next_due), _iso(moment), entry_id),
            )
            return next_due

    def cancel(self, entry_id: str) -> bool:
        with self._connect() as db:
            changed = db.execute(
                "UPDATE schedule SET done = 1 WHERE id = ? AND done = 0",
                (entry_id,),
            ).rowcount
        return changed > 0

    def next_due_at(self) -> Optional[datetime]:
        """When the daemon should next wake, or None if nothing is pending."""
        with self._connect() as db:
            row = db.execute(
                "SELECT due_at FROM schedule WHERE done = 0 "
                "ORDER BY due_at ASC LIMIT 1"
            ).fetchone()
        return _parse(row["due_at"]) if row else None

    @staticmethod
    def _row(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "kind": row["kind"],
            "label": row["label"],
            "due_at": row["due_at"],
            "repeat_seconds": row["repeat_seconds"],
            "payload": json.loads(row["payload"]) if row["payload"] else None,
            "created_at": row["created_at"],
            "last_fired_at": row["last_fired_at"],
        }

    # ---- memory ------------------------------------------------------------

    def remember(self, scope: str, body: str) -> Optional[str]:
        """Keep [body] under [scope]. Blank bodies are not worth a row."""
        text = body.strip()
        if not text:
            return None
        entry = str(uuid.uuid4())
        with self._connect() as db:
            db.execute(
                "INSERT INTO memory (id, scope, body, created_at) "
                "VALUES (?, ?, ?, ?)",
                (entry, scope, text, _iso(now_utc())),
            )
        return entry

    def recall(self, scope: str, *, limit: int = 50) -> list[dict[str, Any]]:
        """Newest [limit] memories in [scope], returned oldest first so they
        read as a history rather than a reversed list."""
        with self._connect() as db:
            rows = db.execute(
                "SELECT id, scope, body, created_at FROM memory "
                "WHERE scope = ? ORDER BY created_at DESC, id DESC LIMIT ?",
                (scope, max(1, limit)),
            ).fetchall()
        return [dict(r) for r in reversed(rows)]

    def forget(self, entry_id: str) -> bool:
        with self._connect() as db:
            return db.execute(
                "DELETE FROM memory WHERE id = ?", (entry_id,)
            ).rowcount > 0
