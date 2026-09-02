"""Unit tests for ADSM protocol helpers."""

from __future__ import annotations

import unittest

from adsm import protocol


class ProtocolTest(unittest.TestCase):
    def test_round_trip(self) -> None:
        raw = protocol.encode(protocol.ok(7, {"a": 1}))
        msg = protocol.decode_line(raw.decode("utf-8"))
        assert msg is not None
        self.assertEqual(msg["id"], 7)
        self.assertEqual(msg["result"]["a"], 1)

    def test_event(self) -> None:
        ev = protocol.event("chat-1", 3, "text", text="hi")
        self.assertEqual(ev["method"], "event")
        self.assertEqual(ev["params"]["seq"], 3)
        self.assertEqual(ev["params"]["kind"], "text")
        self.assertEqual(ev["params"]["text"], "hi")

    def test_err(self) -> None:
        e = protocol.err(1, -32000, "boom")
        self.assertEqual(e["error"]["code"], -32000)


class PathsTest(unittest.TestCase):
    def test_tmux_name_truncated(self) -> None:
        from adsm import paths

        long_id = "x" * 100
        name = paths.tmux_session_name(long_id)
        self.assertTrue(name.startswith("ad-"))
        self.assertLessEqual(len(name), 3 + 24)


if __name__ == "__main__":
    unittest.main()
