"""Daemon log lines must say when they happened.

`adsm.log` is what the app shows when someone asks why their agent
disconnected. Untimestamped lines could say what happened but never when,
which is most of the question — and the app's parser keys off this shape.
"""

from __future__ import annotations

import io
import re
import unittest
from contextlib import redirect_stdout
from datetime import datetime

from adsm import diag

_STAMP = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+00:00 "
)


class DiagLogTest(unittest.TestCase):
    def test_a_line_is_prefixed_with_a_utc_timestamp(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            diag.log("ADSM maintenance: stopping idle worker abc (idle 900s)")
        line = buf.getvalue().rstrip("\n")
        self.assertRegex(line, _STAMP)
        self.assertTrue(line.endswith("(idle 900s)"))

    def test_the_stamp_is_utc_not_local(self) -> None:
        # A naive local stamp is what put assistant replies an hour into the
        # past in the transcript store; the log must not repeat it.
        value = diag.stamp()
        self.assertTrue(value.endswith("+00:00"), value)
        parsed = datetime.fromisoformat(value)
        self.assertIsNotNone(parsed.tzinfo)
        self.assertEqual(0, parsed.utcoffset().total_seconds())

    def test_the_message_is_left_alone(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            diag.log("weird: {braces} and 100% and \\backslash")
        self.assertIn("weird: {braces} and 100% and \\backslash",
                      buf.getvalue())

    def test_one_line_per_call(self) -> None:
        buf = io.StringIO()
        with redirect_stdout(buf):
            diag.log("a")
            diag.log("b")
        self.assertEqual(2, len(buf.getvalue().strip().split("\n")))


if __name__ == "__main__":
    unittest.main()
