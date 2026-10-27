"""A transcript must come back in the order things actually happened.

The store accumulates three shapes of `created_at` at once — UTC with `Z`
from the app, UTC with `+00:00` from the daemon, and naive local time from
the app's own `DateTime.now()`. While the sort compared those as strings,
every UTC-stamped row sorted a whole timezone behind the naive ones. On a
CET host that put the agent's reply an hour into the past, more than a
hundred rows below the tool output of its own turn, so the answer never
appeared at the bottom of the chat and each new prompt surfaced a different
fragment of an older one.
"""

from __future__ import annotations

import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


class TranscriptOrderTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        home = Path(self._tmp.name)
        patch = mock.patch.dict(
            os.environ, {"HOME": str(home), "USERPROFILE": str(home)}
        )
        patch.start()
        self.addCleanup(patch.stop)
        from adsm import transcript as transcript_store

        self.transcript = transcript_store
        self.chat_id = "chat-order"

    def _add(self, msg_id: str, role: str, created: str) -> None:
        self.transcript.upsert_messages(
            self.chat_id,
            [
                {
                    "id": msg_id,
                    "role": role,
                    "content": msg_id,
                    "created_at": created,
                }
            ],
        )

    def test_naive_and_utc_stamps_interleave_by_true_instant(self) -> None:
        # One turn as it really arrives: tool rows carry naive local time,
        # the assistant's text carries UTC. Written in true order.
        naive = datetime(2026, 10, 26, 15, 31, 40)
        offset = naive.astimezone().utcoffset() or timedelta(0)
        utc = (naive + timedelta(seconds=6)).replace(tzinfo=None) - offset

        self._add("tool-a", "tool", naive.isoformat())
        self._add("answer", "assistant", utc.isoformat() + "Z")
        self._add("tool-b", "tool", (naive + timedelta(seconds=12)).isoformat())

        order = [m["id"] for m in self.transcript.list_messages(self.chat_id)]
        self.assertEqual(["tool-a", "answer", "tool-b"], order)

    def test_the_newest_reply_is_last_even_when_stamped_in_utc(self) -> None:
        naive = datetime(2026, 10, 26, 15, 31, 40)
        offset = naive.astimezone().utcoffset() or timedelta(0)
        newest = (naive + timedelta(minutes=1)).replace(tzinfo=None) - offset

        for i in range(5):
            self._add(
                f"tool-{i}", "tool", (naive + timedelta(seconds=i)).isoformat()
            )
        self._add("answer", "assistant", newest.isoformat() + "Z")

        rows = self.transcript.list_messages(self.chat_id)
        self.assertEqual("answer", rows[-1]["id"])

    def test_stored_stamps_are_canonical_utc(self) -> None:
        self._add("a", "user", "2026-10-26T15:31:40.123456")
        self._add("b", "user", "2026-10-26T14:31:40.123456Z")
        stored = [m["created_at"] for m in self.transcript.list_messages(self.chat_id)]
        for value in stored:
            parsed = datetime.fromisoformat(value)
            self.assertIsNotNone(parsed.tzinfo, f"{value} kept no offset")
            self.assertEqual(timezone.utc, parsed.tzinfo)

    def test_an_unparseable_stamp_sorts_oldest_instead_of_raising(self) -> None:
        self._add("junk", "tool", "not-a-date")
        self._add("good", "tool", "2026-10-26T15:31:40")
        order = [m["id"] for m in self.transcript.list_messages(self.chat_id)]
        self.assertEqual(["junk", "good"], order)

    def test_sort_instant_reads_every_shape_the_store_holds(self) -> None:
        same = datetime(2026, 10, 26, 14, 31, 46, tzinfo=timezone.utc)
        self.assertEqual(same, self.transcript.sort_instant("2026-10-26T14:31:46Z"))
        self.assertEqual(
            same, self.transcript.sort_instant("2026-10-26T14:31:46+00:00")
        )
        naive = datetime(2026, 10, 26, 14, 31, 46)
        self.assertEqual(
            naive.astimezone(timezone.utc),
            self.transcript.sort_instant("2026-10-26T14:31:46"),
        )


if __name__ == "__main__":
    unittest.main()
