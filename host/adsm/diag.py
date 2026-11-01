"""Daemon log lines, timestamped.

`~/.agentdock/adsm.log` is what the app shows when someone asks why their
agent disconnected, and an untimestamped line cannot answer "when" — which
is most of the question. The daemon's own prints go through here so every
line carries the moment it happened.

UTC with an explicit offset, so a log read from another timezone still sorts
and reads correctly. (A naive local stamp is what put assistant replies an
hour into the past in the transcript store; the same mistake is not worth
repeating in the log.)
"""

from __future__ import annotations

from datetime import datetime, timezone


def stamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def log(message: str) -> None:
    """One timestamped line on stdout, flushed so a tail sees it at once."""
    print(f"{stamp()} {message}", flush=True)
