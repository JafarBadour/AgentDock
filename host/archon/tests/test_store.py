"""Archon's schedule and memory."""

from __future__ import annotations

import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


class ArchonStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        patch = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        patch.start()
        self.addCleanup(patch.stop)
        from archon import paths
        from archon.store import ArchonStore

        paths.ensure_layout()
        self.paths = paths
        self.store = ArchonStore()
        self.t0 = datetime(2026, 9, 30, 12, 0, tzinfo=timezone.utc)

    def test_state_lives_under_the_archon_folder(self) -> None:
        # Migration is a folder move, so nothing may live outside it.
        self.assertTrue(
            str(self.paths.db_path()).startswith(str(self.paths.archon_root()))
        )
        self.assertTrue(self.paths.db_path().exists())

    def test_a_timer_is_due_only_once_its_moment_arrives(self) -> None:
        self.store.schedule(label="check the build", due_at=self.t0)
        self.assertEqual([], self.store.due(self.t0 - timedelta(seconds=1)))
        self.assertEqual(1, len(self.store.due(self.t0)))

    def test_a_one_shot_stops_after_firing(self) -> None:
        entry = self.store.schedule(label="once", due_at=self.t0)
        self.assertIsNone(self.store.mark_fired(entry, at=self.t0))
        self.assertEqual([], self.store.due(self.t0 + timedelta(days=1)))

    def test_a_missed_repeat_fires_once_not_once_per_period(self) -> None:
        # Asleep for an hour with a five-minute timer: waking must not mean
        # twelve turns in a row.
        entry = self.store.schedule(
            label="poll", due_at=self.t0, repeat_seconds=300
        )
        woke = self.t0 + timedelta(hours=1)
        next_due = self.store.mark_fired(entry, at=woke)
        self.assertIsNotNone(next_due)
        self.assertGreater(next_due, woke)
        self.assertEqual([], self.store.due(woke))
        self.assertEqual(1, len(self.store.due(next_due)))

    def test_repeats_stay_on_their_original_cadence(self) -> None:
        entry = self.store.schedule(
            label="poll", due_at=self.t0, repeat_seconds=600
        )
        nxt = self.store.mark_fired(entry, at=self.t0)
        self.assertEqual(self.t0 + timedelta(seconds=600), nxt)

    def test_cancel_removes_it_from_the_wake_list(self) -> None:
        entry = self.store.schedule(label="drop me", due_at=self.t0)
        self.assertTrue(self.store.cancel(entry))
        self.assertEqual([], self.store.due(self.t0))
        self.assertFalse(self.store.cancel(entry))

    def test_next_due_at_is_the_earliest_pending(self) -> None:
        self.assertIsNone(self.store.next_due_at())
        self.store.schedule(label="later", due_at=self.t0 + timedelta(hours=2))
        self.store.schedule(label="sooner", due_at=self.t0 + timedelta(minutes=5))
        self.assertEqual(
            self.t0 + timedelta(minutes=5), self.store.next_due_at()
        )

    def test_a_repeat_must_have_a_positive_period(self) -> None:
        with self.assertRaises(ValueError):
            self.store.schedule(label="bad", due_at=self.t0, repeat_seconds=0)

    def test_payload_round_trips(self) -> None:
        self.store.schedule(
            label="job", due_at=self.t0, payload={"host": "a", "n": 2}
        )
        self.assertEqual({"host": "a", "n": 2}, self.store.due(self.t0)[0]["payload"])

    def test_memory_reads_back_oldest_first(self) -> None:
        for body in ["prefers short replies", "works in CET", "hates tables"]:
            self.store.remember("user", body)
        got = [m["body"] for m in self.store.recall("user")]
        self.assertEqual(
            ["prefers short replies", "works in CET", "hates tables"], got
        )

    def test_memory_is_scoped(self) -> None:
        self.store.remember("user", "global fact")
        self.store.remember("chat:abc", "local fact")
        self.assertEqual(
            ["global fact"], [m["body"] for m in self.store.recall("user")]
        )
        self.assertEqual(
            ["local fact"], [m["body"] for m in self.store.recall("chat:abc")]
        )

    def test_blank_memory_is_not_stored(self) -> None:
        self.assertIsNone(self.store.remember("user", "   "))
        self.assertEqual([], self.store.recall("user"))

    def test_recall_keeps_the_newest_when_over_the_limit(self) -> None:
        for i in range(10):
            self.store.remember("user", f"fact {i}")
        got = [m["body"] for m in self.store.recall("user", limit=3)]
        self.assertEqual(["fact 7", "fact 8", "fact 9"], got)

    def test_the_store_survives_a_restart(self) -> None:
        from archon.store import ArchonStore

        self.store.schedule(label="persisted", due_at=self.t0)
        self.store.remember("user", "persisted too")
        reopened = ArchonStore()
        self.assertEqual(1, len(reopened.due(self.t0)))
        self.assertEqual(1, len(reopened.recall("user")))


if __name__ == "__main__":
    unittest.main()
