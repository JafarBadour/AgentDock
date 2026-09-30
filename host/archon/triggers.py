"""What wakes Archon, and when it next wakes.

Archon sleeps by default. Four things start a turn: a chat message, a due
schedule entry, a carried-over Automate job, and a proactive tick that lets
Archon look around unprompted.
"""

from __future__ import annotations

import random
from datetime import datetime, timedelta
from typing import Optional

from .store import ArchonStore, now_utc

CHAT = "chat"
SCHEDULE = "schedule"
JOB = "job"
PROACTIVE = "proactive"

# The design asks for a proactive look every 15-30 minutes, jittered so
# Archon does not settle into a rhythm that lines up with anything else.
PROACTIVE_MIN_SECONDS = 15 * 60
PROACTIVE_MAX_SECONDS = 30 * 60


def next_proactive_tick(
    *,
    after: Optional[datetime] = None,
    rng: Optional[random.Random] = None,
) -> datetime:
    """When Archon should next look around of its own accord."""
    base = after or now_utc()
    source = rng or random
    delay = source.randint(PROACTIVE_MIN_SECONDS, PROACTIVE_MAX_SECONDS)
    return base + timedelta(seconds=delay)


def seconds_until(moment: datetime, *, now: Optional[datetime] = None) -> float:
    """Never negative — a moment already past means wake immediately."""
    return max(0.0, (moment - (now or now_utc())).total_seconds())


def next_wakeup(
    store: ArchonStore,
    *,
    proactive_at: Optional[datetime] = None,
    now: Optional[datetime] = None,
) -> tuple[str, datetime]:
    """The earlier of the next due entry and the next proactive tick.

    Returned as (reason, when) so the daemon can log why it woke.
    """
    moment = now or now_utc()
    tick = proactive_at or next_proactive_tick(after=moment)
    due = store.next_due_at()
    if due is not None and due <= tick:
        return (SCHEDULE, due)
    return (PROACTIVE, tick)


def proactive_is_worth_waking(
    *,
    running_agents: int,
    unread_chats: int,
    due_entries: int,
) -> bool:
    """Whether a proactive tick has anything to act on.

    Checked from records the app already holds, never by opening a bridge to
    every host. ADSM stops an idle worker after 15 minutes, and a tick that
    reconnected on that same cadence would keep resurrecting the workers the
    reaper had just stopped — a permanently warm host with nothing happening
    on it. So a tick that finds nothing pending goes back to sleep without
    touching a host at all.
    """
    return running_agents > 0 or unread_chats > 0 or due_entries > 0
