"""Archon's wake loop.

Time is simulated, so a day of ticks runs in milliseconds and no test ever
sleeps. The test that matters most is the quiet one: a tick with nothing to do
must not open a connection to anything, because ADSM reaps idle workers on
roughly the same cadence and a tick that reconnected regardless would keep
resurrecting them.
"""

from __future__ import annotations

import asyncio
import contextlib
import io
import json
import os
import random
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

T0 = datetime(2026, 9, 30, 12, 0, tzinfo=timezone.utc)


class _Clock:
    """Simulated time: a twenty-minute sleep costs one event-loop turn."""

    def __init__(self, start: datetime = T0) -> None:
        self.moment = start
        self.sleeps = 0

    def now(self) -> datetime:
        return self.moment

    async def sleep(self, seconds: float) -> None:
        self.sleeps += 1
        self.moment += timedelta(seconds=seconds)
        await asyncio.sleep(0)


class _HangingClock(_Clock):
    """A sleep that never ends on its own — only stopping can break it."""

    async def sleep(self, seconds: float) -> None:
        self.sleeps += 1
        await asyncio.Event().wait()


async def _settle(turns: int = 20) -> None:
    for _ in range(turns):
        await asyncio.sleep(0)


class DaemonTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self._tmp.name})
        patch.start()
        self.addCleanup(patch.stop)
        from adsm import paths as adsm_paths
        from archon import daemon, paths, triggers
        from archon.store import ArchonStore

        adsm_paths.ensure_layout()
        paths.ensure_layout()
        self.adsm_paths = adsm_paths
        self.daemon_mod = daemon
        self.triggers = triggers
        self.store = ArchonStore()
        self.clock = _Clock()
        self.wakes: list = []
        # Seeded so a failure is reproducible rather than "sometimes".
        self.rng = random.Random(11)

    # ---- helpers -----------------------------------------------------------

    def agent(self, chat_id: str, **fields) -> None:
        record = {"id": chat_id, "permission_ask": False,
                  "archon_managed": True, "archon_goal": "green CI"}
        record.update(fields)
        self.adsm_paths.agent_record_path(chat_id).write_text(
            json.dumps(record), encoding="utf-8"
        )

    def build(self, *, clock=None, wake=None):
        async def record(w) -> None:
            self.wakes.append(w)

        return self.daemon_mod.ArchonDaemon(
            wake=wake or record,
            store=self.store,
            clock=clock or self.clock,
            rng=self.rng,
        )

    def no_connections(self):
        """Every route off this host goes through one of these."""
        return (
            mock.patch("asyncio.open_unix_connection"),
            mock.patch("asyncio.open_connection"),
        )

    # ---- the quiet case ----------------------------------------------------

    async def test_a_quiet_day_never_opens_a_connection(self) -> None:
        unix, tcp = self.no_connections()
        with unix as unix_spy, tcp as tcp_spy:
            with mock.patch("archon.cli.daemon_call") as call_spy, \
                    mock.patch("archon.cli.relay") as relay_spy:
                await self.build().run(max_cycles=96)

        self.assertGreater(
            (self.clock.moment - T0).total_seconds(), 24 * 3600,
            "the simulated run was too short to be worth anything",
        )
        self.assertEqual([], self.wakes)
        self.assertFalse(unix_spy.called)
        self.assertFalse(tcp_spy.called)
        self.assertFalse(call_spy.called)
        self.assertFalse(relay_spy.called)

    async def test_a_quiet_day_writes_nothing_to_the_action_log(self) -> None:
        # The log is what the user reads. Dozens of "woke, did nothing" rows a
        # day would bury the handful where Archon acted.
        await self.build().run(max_cycles=50)
        self.assertEqual([], self.store.actions())

    async def test_an_agent_on_ask_is_not_worth_waking_for(self) -> None:
        # The toggle is the user's intent; the permission is their authority.
        self.agent("a", title="Deploy", permission_ask=True, status="running")
        await self.build().run(max_cycles=20)
        self.assertEqual([], self.wakes)

    async def test_an_agent_without_a_goal_is_not_worth_waking_for(self) -> None:
        self.agent("a", title="Idle", archon_managed=False, status="running")
        await self.build().run(max_cycles=20)
        self.assertEqual([], self.wakes)

    # ---- the tick that finds something ------------------------------------

    async def test_a_running_agent_earns_the_tick(self) -> None:
        self.agent("a", title="Build", status="running")
        await self.build().run(max_cycles=1)
        self.assertEqual(1, len(self.wakes))
        self.assertEqual(self.triggers.PROACTIVE, self.wakes[0].reason)
        self.assertIn("Build", self.wakes[0].prompt)

    async def test_an_agent_that_moved_wakes_archon_once_not_every_tick(self) -> None:
        # Otherwise every finished agent would be a standing invitation to
        # wake up and look at it again forever.
        self.agent("a", title="Build", status="idle", updated_at="2026-09-30T11:00:00Z")
        d = self.build()
        await d.run(max_cycles=1)
        self.assertEqual(1, len(self.wakes))
        await d.run(max_cycles=20)
        self.assertEqual(1, len(self.wakes))

    async def test_a_further_change_wakes_archon_again(self) -> None:
        self.agent("a", title="Build", status="idle", updated_at="2026-09-30T11:00:00Z")
        d = self.build()
        await d.run(max_cycles=1)
        self.agent("a", title="Build", status="idle", updated_at="2026-09-30T13:00:00Z")
        await d.run(max_cycles=1)
        self.assertEqual(2, len(self.wakes))

    async def test_a_tick_that_woke_archon_is_logged(self) -> None:
        self.agent("a", title="Build", status="running")
        await self.build().run(max_cycles=1)
        logged = self.store.actions()
        self.assertEqual(1, len(logged))
        self.assertEqual("wake", logged[0]["command"])
        self.assertEqual(self.triggers.PROACTIVE, logged[0]["target"])
        self.assertTrue(logged[0]["ok"])

    async def test_the_tick_stays_inside_the_designed_window(self) -> None:
        d = self.build()
        for _ in range(30):
            before = self.clock.moment
            await d.cycle()
            delay = (self.clock.moment - before).total_seconds()
            self.assertGreaterEqual(delay, self.triggers.PROACTIVE_MIN_SECONDS)
            self.assertLessEqual(delay, self.triggers.PROACTIVE_MAX_SECONDS)

    # ---- schedule entries --------------------------------------------------

    async def test_a_due_timer_fires_and_closes(self) -> None:
        self.store.schedule(
            label="check the build", due_at=T0 + timedelta(minutes=5)
        )
        await self.build().run(max_cycles=1)
        self.assertEqual(1, len(self.wakes))
        wake = self.wakes[0]
        self.assertEqual(self.triggers.SCHEDULE, wake.reason)
        self.assertEqual(T0 + timedelta(minutes=5), wake.at)
        self.assertIn("check the build", wake.prompt)
        self.assertEqual([], self.store.pending())

    async def test_a_timer_beats_a_later_tick(self) -> None:
        self.agent("a", title="Build", status="running")
        self.store.schedule(label="soon", due_at=T0 + timedelta(minutes=2))
        await self.build().run(max_cycles=1)
        self.assertEqual(self.triggers.SCHEDULE, self.wakes[0].reason)

    async def test_the_prompt_carries_the_payload_the_entry_was_for(self) -> None:
        # The store rolls a repeat forward on firing, so by the time Archon
        # reads this the row no longer says what it was due for.
        self.store.schedule(
            label="nightly", due_at=T0 + timedelta(minutes=1),
            payload={"chatId": "a"},
        )
        await self.build().run(max_cycles=1)
        self.assertIn('"chatId": "a"', self.wakes[0].prompt)

    async def test_a_repeat_keeps_waking_and_stays_pending(self) -> None:
        self.store.schedule(
            label="poll", due_at=T0 + timedelta(minutes=1), repeat_seconds=600
        )
        await self.build().run(max_cycles=6)
        reasons = [w.reason for w in self.wakes]
        self.assertGreaterEqual(reasons.count(self.triggers.SCHEDULE), 2)
        self.assertEqual(1, len(self.store.pending()))

    async def test_a_long_overdue_repeat_fires_once_not_once_per_period(self) -> None:
        # Host asleep for a day with a five-minute timer: waking must not mean
        # 288 turns in a row. The store owns that rule; the loop must not
        # undo it by firing again immediately.
        self.store.schedule(
            label="poll", due_at=T0 - timedelta(days=1), repeat_seconds=300
        )
        await self.build().run(max_cycles=1)
        self.assertEqual(1, len(self.wakes))
        self.assertEqual([], self.store.due(self.clock.moment))

    async def test_an_entry_cancelled_while_asleep_does_not_fire(self) -> None:
        entry = self.store.schedule(label="drop me", due_at=T0 + timedelta(minutes=5))
        self.store.cancel(entry)
        await self.build().run(max_cycles=1)
        self.assertEqual([], [w for w in self.wakes
                              if w.reason == self.triggers.SCHEDULE])

    # ---- failure and control ----------------------------------------------

    async def test_a_failing_handoff_does_not_stop_the_loop(self) -> None:
        calls = []

        async def broken(wake) -> None:
            calls.append(wake)
            raise RuntimeError("the agent session is gone")

        self.store.schedule(
            label="poll", due_at=T0 + timedelta(minutes=1), repeat_seconds=600
        )
        with contextlib.redirect_stdout(io.StringIO()):
            await self.build(wake=broken).run(max_cycles=4)
        self.assertGreaterEqual(len(calls), 2)
        failed = [a for a in self.store.actions() if not a["ok"]]
        self.assertTrue(failed, "a failed wake must still be visible")

    async def test_a_sync_callback_is_accepted(self) -> None:
        seen = []
        self.store.schedule(label="once", due_at=T0 + timedelta(minutes=1))
        await self.build(wake=seen.append).run(max_cycles=1)
        self.assertEqual(1, len(seen))

    async def test_stopping_interrupts_a_sleep_that_would_never_end(self) -> None:
        clock = _HangingClock()
        d = self.build(clock=clock)
        task = asyncio.ensure_future(d.run())
        await _settle()
        self.assertEqual(1, clock.sleeps)
        d.request_stop()
        await asyncio.wait_for(task, timeout=1.0)
        self.assertTrue(d.stopping)

    async def test_cancelling_the_task_ends_the_loop(self) -> None:
        d = self.build(clock=_HangingClock())
        task = asyncio.ensure_future(d.run())
        await _settle()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task

    async def test_a_new_entry_interrupts_the_sleep_to_be_replanned(self) -> None:
        # A two-minute timer set mid-conversation must not wait for whatever
        # wakeup was already pending.
        clock = _HangingClock()
        d = self.build(clock=clock)
        task = asyncio.ensure_future(d.run())
        await _settle()
        self.assertEqual(1, clock.sleeps)
        self.store.schedule(label="soon", due_at=T0 + timedelta(minutes=2))
        d.schedule_changed()
        await _settle()
        self.assertEqual(2, clock.sleeps)
        self.assertEqual([], self.wakes, "a replan is not a wakeup")
        d.request_stop()
        await asyncio.wait_for(task, timeout=1.0)

    async def test_stopping_before_the_loop_starts_is_honoured(self) -> None:
        d = self.build(clock=_HangingClock())
        d.request_stop()
        await asyncio.wait_for(d.run(), timeout=1.0)
        self.assertEqual([], self.wakes)

    # ---- the survey itself -------------------------------------------------

    async def test_the_survey_reads_records_only(self) -> None:
        self.agent("a", title="Build", status="running")
        unix, tcp = self.no_connections()
        with unix as unix_spy, tcp as tcp_spy:
            survey = self.build().survey(T0)
        self.assertEqual(("Build",), survey.running)
        self.assertTrue(survey.worth_waking)
        self.assertFalse(unix_spy.called or tcp_spy.called)

    async def test_an_empty_survey_is_not_worth_waking(self) -> None:
        self.assertFalse(self.build().survey(T0).worth_waking)


if __name__ == "__main__":
    unittest.main()
