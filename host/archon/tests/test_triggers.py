"""When Archon wakes, and whether waking was worth it."""

from __future__ import annotations

import os
import random
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


class TriggerTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self._tmp.name})
        patch.start()
        self.addCleanup(patch.stop)
        from archon import paths, triggers
        from archon.store import ArchonStore

        paths.ensure_layout()
        self.triggers = triggers
        self.store = ArchonStore()
        self.t0 = datetime(2026, 9, 30, 12, 0, tzinfo=timezone.utc)

    def test_proactive_tick_stays_inside_the_designed_window(self) -> None:
        rng = random.Random(7)
        for _ in range(200):
            nxt = self.triggers.next_proactive_tick(after=self.t0, rng=rng)
            delay = (nxt - self.t0).total_seconds()
            self.assertGreaterEqual(delay, self.triggers.PROACTIVE_MIN_SECONDS)
            self.assertLessEqual(delay, self.triggers.PROACTIVE_MAX_SECONDS)

    def test_the_tick_is_jittered_not_fixed(self) -> None:
        rng = random.Random(7)
        seen = {
            self.triggers.next_proactive_tick(after=self.t0, rng=rng)
            for _ in range(50)
        }
        self.assertGreater(len(seen), 1)

    def test_a_sooner_timer_wins_over_the_tick(self) -> None:
        self.store.schedule(
            label="soon", due_at=self.t0 + timedelta(minutes=2)
        )
        reason, when = self.triggers.next_wakeup(
            self.store,
            proactive_at=self.t0 + timedelta(minutes=20),
            now=self.t0,
        )
        self.assertEqual(self.triggers.SCHEDULE, reason)
        self.assertEqual(self.t0 + timedelta(minutes=2), when)

    def test_the_tick_wins_when_nothing_is_scheduled(self) -> None:
        tick = self.t0 + timedelta(minutes=20)
        reason, when = self.triggers.next_wakeup(
            self.store, proactive_at=tick, now=self.t0
        )
        self.assertEqual(self.triggers.PROACTIVE, reason)
        self.assertEqual(tick, when)

    def test_a_late_timer_means_wake_now_not_a_negative_sleep(self) -> None:
        past = self.t0 - timedelta(minutes=5)
        self.assertEqual(0.0, self.triggers.seconds_until(past, now=self.t0))

    def test_an_empty_tick_does_not_justify_touching_a_host(self) -> None:
        # ADSM stops idle workers after 15 minutes; a tick on that same
        # cadence that reconnected anyway would keep them permanently warm.
        self.assertFalse(
            self.triggers.proactive_is_worth_waking(
                running_agents=0, unread_chats=0, due_entries=0
            )
        )

    def test_any_pending_signal_justifies_the_tick(self) -> None:
        for kwargs in (
            {"running_agents": 1, "unread_chats": 0, "due_entries": 0},
            {"running_agents": 0, "unread_chats": 3, "due_entries": 0},
            {"running_agents": 0, "unread_chats": 0, "due_entries": 2},
        ):
            self.assertTrue(
                self.triggers.proactive_is_worth_waking(**kwargs), kwargs
            )


if __name__ == "__main__":
    unittest.main()
