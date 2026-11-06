"""A chat someone is watching should not be reaped out from under them.

The reaper exists because agents accumulate on shared hosts — one login node
had 26 orphans, the oldest 111 days. But a flat 15-minute timer also stops
the agent you are sitting in front of while you read its output or wait on a
job, which is what reads as the agent dying by itself. The window now depends
on whether any device is still subscribed.
"""

from __future__ import annotations

import unittest

from adsm.daemon import (
    _IDLE_STOP_SECONDS,
    _IDLE_STOP_SECONDS_ATTACHED,
    Daemon,
)


class IdleWindowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.daemon = Daemon.__new__(Daemon)
        self.daemon._subscribers = {}

    def test_a_chat_nobody_watches_keeps_the_short_window(self) -> None:
        self.assertEqual(_IDLE_STOP_SECONDS, self.daemon._idle_limit_for("a"))

    def test_an_attached_chat_gets_the_long_one(self) -> None:
        self.daemon._subscribers["a"] = {object()}
        self.assertEqual(
            _IDLE_STOP_SECONDS_ATTACHED, self.daemon._idle_limit_for("a")
        )

    def test_the_long_window_is_actually_longer(self) -> None:
        self.assertGreater(_IDLE_STOP_SECONDS_ATTACHED, _IDLE_STOP_SECONDS)

    def test_a_subscriber_set_emptied_on_disconnect_reverts(self) -> None:
        # `_drop_writer` discards from the set rather than deleting the key,
        # so an empty set must read as nobody watching.
        self.daemon._subscribers["a"] = set()
        self.assertEqual(_IDLE_STOP_SECONDS, self.daemon._idle_limit_for("a"))

    def test_watching_one_chat_does_not_shelter_another(self) -> None:
        self.daemon._subscribers["a"] = {object()}
        self.assertEqual(_IDLE_STOP_SECONDS, self.daemon._idle_limit_for("b"))

    def test_several_devices_count(self) -> None:
        self.daemon._subscribers["a"] = {object(), object()}
        self.assertEqual(2, self.daemon._watchers("a"))


if __name__ == "__main__":
    unittest.main()
