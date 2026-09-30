"""Archon's wake loop — what makes it a daemon rather than a chat.

A chat answers when spoken to. Archon sleeps, wakes on its own, decides
whether anything is worth doing, and goes back to sleep. This module is only
the *when* and the *what to say*: it never reasons about agents itself and it
never talks to a model. When it decides Archon should be awake it builds one
prompt and hands it to an injected callback, which is where the real agent
session lives.

Two things wake the loop, both from [triggers]: the next due schedule entry,
and a jittered proactive tick. The tick is the dangerous one. ADSM stops an
idle worker after 15 minutes, and a tick on roughly that same cadence that
reconnected to a host "just to look" would keep resurrecting the workers the
reaper had just stopped — a permanently warm host, and a paid Archon turn,
with nothing happening on either. So a tick decides purely from records that
are already on this disk: the agent JSON files ADSM writes, and Archon's own
SQLite. A tick that finds nothing opens nothing and costs nothing.

Everything time-related is injected, so a test can run a simulated week in
milliseconds without sleeping.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import random
from dataclasses import dataclass, field
from datetime import datetime
from typing import Awaitable, Callable, Optional, Protocol, Sequence, Union

from adsm import protocol as adsm_protocol

from . import directory, triggers
from .store import ArchonStore, now_utc

# An agent mid-turn, or one holding a permission prompt, is work in flight and
# a reason to look. Every other status is a settled agent that a tick has no
# business reopening.
_BUSY_STATUSES = frozenset(
    {adsm_protocol.STATUS_RUNNING, adsm_protocol.STATUS_WAITING_PERMISSION}
)

# A cycle that raised has no business retrying at full speed: a store that
# fails on every call would otherwise spin the loop at the rate of the error.
_ERROR_BACKOFF_SECONDS = 60.0

# Why the sleep ended. Only _DUE means the wakeup we planned actually arrived.
_DUE = "due"
_CHANGED = "changed"
_STOPPED = "stopped"


class Clock(Protocol):  # pragma: no cover - structural type
    """Time as the loop sees it, so tests can make hours cost nothing."""

    def now(self) -> datetime:
        ...

    async def sleep(self, seconds: float) -> None:
        ...


class SystemClock:
    """Real time."""

    def now(self) -> datetime:
        return now_utc()

    async def sleep(self, seconds: float) -> None:
        await asyncio.sleep(seconds)


@dataclass(frozen=True)
class Survey:
    """What the records say, gathered without touching a host.

    Only agents Archon may actually drive are counted. An agent the user set
    to Ask, or never switched on, moving in the background is not Archon's
    work, and waking a paid turn over something it is not allowed to touch is
    the worst possible trade.
    """

    running: tuple = ()
    moved: tuple = ()
    due_entries: int = 0
    # chatId -> the updated_at this survey saw, so a wake can record what it
    # has now looked at. Kept here rather than in the daemon because a survey
    # that decides *not* to wake must not quietly mark anything as seen.
    stamps: dict = field(default_factory=dict)

    @property
    def worth_waking(self) -> bool:
        return triggers.proactive_is_worth_waking(
            running_agents=len(self.running),
            unread_chats=len(self.moved),
            due_entries=self.due_entries,
        )


@dataclass(frozen=True)
class Wake:
    """One handoff to Archon's agent session."""

    reason: str
    at: datetime
    prompt: str
    entries: tuple = ()
    survey: Optional[Survey] = None


# The callback that actually wakes Archon. Async or sync, both are accepted —
# the supervisor wiring this up should not have to care.
WakeAction = Callable[[Wake], Union[None, Awaitable[None]]]
Records = Callable[[], Sequence[dict]]


def _title(record: dict) -> str:
    return record.get("title") or record.get("id") or "an agent"


def _stamp(record: dict) -> str:
    return str(record.get("updated_at") or "")


def _describe_entry(entry: dict) -> str:
    line = '{} "{}"'.format(entry.get("kind") or "timer", entry.get("label"))
    payload = entry.get("payload")
    if payload:
        line += " " + json.dumps(payload, ensure_ascii=False, sort_keys=True)
    return line


def _when(at: datetime) -> str:
    return at.isoformat(timespec="seconds")


def schedule_prompt(entries: Sequence[dict], *, at: datetime) -> str:
    """What Archon is told when a timer, reminder or carried-over job fires.

    The entries are spelled out because the store rolls repeats forward on
    firing: by the time Archon reads this, the row no longer says what it was
    due for, and `archon due` would come back empty.
    """
    lines = [
        "Scheduled work came due at {}:".format(_when(at)),
        *["- " + _describe_entry(e) for e in entries],
        "",
        "Act on it. An entry that turns out to need nothing needs nothing — "
        "do not report it.",
    ]
    return "\n".join(lines)


def proactive_prompt(survey: Survey, *, at: datetime) -> str:
    """What Archon is told on a tick that found something.

    It carries the survey so Archon does not have to re-derive from scratch
    what already justified waking it, and it repeats the cheap-first rule,
    because the failure mode of an unprompted manager is filling a quiet tick
    with expensive activity.
    """
    lines = ["Proactive check at {}.".format(_when(at))]
    if survey.running:
        lines.append("Running now: " + ", ".join(survey.running) + ".")
    if survey.moved:
        lines.append(
            "Moved since you last looked: " + ", ".join(survey.moved) + "."
        )
    if survey.due_entries:
        lines.append("Due entries waiting: {}.".format(survey.due_entries))
    lines += [
        "",
        "Records first (archon goals, archon due). Open an agent chat only "
        "when you have a reason to act on it. Say nothing unless something "
        "changed, finished, or is blocked.",
    ]
    return "\n".join(lines)


class ArchonDaemon:
    """Sleep until the next wakeup, decide, hand off, repeat.

    Nothing here is a singleton and nothing reads the wall clock directly, so
    a test drives it the same way production does.
    """

    def __init__(
        self,
        *,
        wake: WakeAction,
        store: Optional[ArchonStore] = None,
        clock: Optional[Clock] = None,
        records: Optional[Records] = None,
        rng: Optional[random.Random] = None,
    ) -> None:
        self._wake = wake
        self._store = store if store is not None else ArchonStore()
        self._clock: Clock = clock or SystemClock()
        self._records: Records = records or directory.load_records
        self._rng = rng
        # Held across cycles so a mid-sleep change cannot re-roll the jitter.
        # Re-rolling on every interruption would let a busy evening push the
        # proactive tick out indefinitely, which is the one thing it exists to
        # stop happening.
        self._proactive_at: Optional[datetime] = None
        self._seen: dict = {}
        self._stopping = False
        # Created on the running loop: an asyncio.Event built at import or in
        # a constructor can end up bound to the wrong loop on 3.9.
        self._stop: Optional[asyncio.Event] = None
        self._changed: Optional[asyncio.Event] = None

    # ---- control -----------------------------------------------------------

    def request_stop(self) -> None:
        """Stop after the current cycle, interrupting the sleep."""
        self._stopping = True
        if self._stop is not None:
            self._stop.set()

    def schedule_changed(self) -> None:
        """Something added or cancelled a schedule entry — recompute now.

        Without this the loop would keep sleeping on a plan it made before the
        change: a timer set for two minutes' time during a chat turn would not
        fire until whatever wakeup was already pending came round.
        """
        if self._changed is not None:
            self._changed.set()

    @property
    def stopping(self) -> bool:
        return self._stopping

    # ---- the loop ----------------------------------------------------------

    async def run(self, *, max_cycles: Optional[int] = None) -> None:
        """Run until stopped or cancelled.

        [max_cycles] bounds a test run; production leaves it None.
        """
        self._ensure_events()
        cycles = 0
        while not self._stopping and (max_cycles is None or cycles < max_cycles):
            cycles += 1
            try:
                await self.cycle()
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                # One bad cycle must not end the daemon: Archon going quiet
                # forever is far worse than a missed tick.
                print("Archon wake loop error: {}".format(e), flush=True)
                await self._clock.sleep(_ERROR_BACKOFF_SECONDS)

    async def cycle(self) -> Optional[Wake]:
        """Sleep until the next wakeup and handle it. Returns any handoff."""
        self._ensure_events()
        at = self._clock.now()
        if self._proactive_at is None:
            self._proactive_at = triggers.next_proactive_tick(
                after=at, rng=self._rng
            )
        reason, when = triggers.next_wakeup(
            self._store, proactive_at=self._proactive_at, now=at
        )
        outcome = await self._sleep(triggers.seconds_until(when, now=at))
        if outcome != _DUE:
            # Stopped, or the schedule moved under us. Either way the decision
            # we made before sleeping is stale, so make a new one.
            return None
        at = self._clock.now()
        if reason == triggers.SCHEDULE:
            return await self._fire_due(at)
        return await self._tick(at)

    async def _sleep(self, seconds: float) -> str:
        """Sleep, but stay interruptible for the whole of it."""
        stop, changed = self._stop, self._changed
        assert stop is not None and changed is not None
        if stop.is_set():
            return _STOPPED
        if changed.is_set():
            changed.clear()
            return _CHANGED
        sleeper = asyncio.ensure_future(self._clock.sleep(seconds))
        waiters = [
            sleeper,
            asyncio.ensure_future(stop.wait()),
            asyncio.ensure_future(changed.wait()),
        ]
        try:
            await asyncio.wait(waiters, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in waiters:
                task.cancel()
            # Collect the cancellations so none of them surfaces later as an
            # unretrieved task exception.
            await asyncio.gather(*waiters, return_exceptions=True)
        if stop.is_set():
            return _STOPPED
        if changed.is_set():
            changed.clear()
            return _CHANGED
        return _DUE

    # ---- the two kinds of wakeup ------------------------------------------

    async def _fire_due(self, at: datetime) -> Optional[Wake]:
        entries = self._store.due(at)
        if not entries:
            # Cancelled while we slept. Nothing to say about it.
            return None
        for entry in entries:
            # Marked before the handoff, never after: the store decides what a
            # repeat does next, and a handoff that throws must not leave the
            # entry due and the loop firing it round and round.
            self._store.mark_fired(entry["id"], at=at)
        return await self._hand_off(
            Wake(
                reason=triggers.SCHEDULE,
                at=at,
                prompt=schedule_prompt(entries, at=at),
                entries=tuple(entries),
            )
        )

    async def _tick(self, at: datetime) -> Optional[Wake]:
        survey = self.survey(at)
        # Re-rolled here rather than on the next cycle so the jitter is
        # measured from the tick that just happened.
        self._proactive_at = triggers.next_proactive_tick(after=at, rng=self._rng)
        if not survey.worth_waking:
            # The whole point of the module: no host touched, no turn paid for,
            # and the idle workers ADSM just reaped stay reaped.
            return None
        self._seen.update(survey.stamps)
        return await self._hand_off(
            Wake(
                reason=triggers.PROACTIVE,
                at=at,
                prompt=proactive_prompt(survey, at=at),
                survey=survey,
            )
        )

    def survey(self, at: Optional[datetime] = None) -> Survey:
        """Read the records. No connection to anything is opened here."""
        moment = at or self._clock.now()
        records = directory.manageable(list(self._records()))
        running = tuple(
            _title(r) for r in records if r.get("status") in _BUSY_STATUSES
        )
        moved = tuple(
            _title(r)
            for r in records
            if self._seen.get(r.get("id")) != _stamp(r)
        )
        return Survey(
            running=running,
            moved=moved,
            due_entries=len(self._store.due(moment)),
            stamps={r.get("id"): _stamp(r) for r in records},
        )

    # ---- handoff -----------------------------------------------------------

    async def _hand_off(self, wake: Wake) -> Wake:
        ok = True
        try:
            result = self._wake(wake)
            if inspect.isawaitable(result):
                await result
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            ok = False
            print("Archon wake handoff failed: {}".format(e), flush=True)
        self._log(wake, ok=ok)
        return wake

    def _log(self, wake: Wake, *, ok: bool) -> None:
        """Only wakes that produced work are logged.

        The action log is what the user reads in the Archon tab. A row for
        every empty tick would be dozens a day saying nothing happened, and
        would bury the handful of rows where Archon actually did something.
        """
        try:
            self._store.record_action(
                "wake",
                target=wake.reason,
                summary=wake.prompt.splitlines()[0],
                ok=ok,
                at=wake.at,
            )
            self._store.trim_actions()
        except Exception:  # noqa: BLE001
            # Bookkeeping must never be the thing that stops Archon waking.
            pass

    def _ensure_events(self) -> None:
        if self._stop is None:
            self._stop = asyncio.Event()
            if self._stopping:
                self._stop.set()
        if self._changed is None:
            self._changed = asyncio.Event()
