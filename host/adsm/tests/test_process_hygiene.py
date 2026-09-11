"""Tests for Claude child reaping / journal trim helpers."""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

from adsm import process_hygiene


class ProcessHygieneTest(unittest.TestCase):
    def test_trim_journal_keeps_tail(self) -> None:
        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.jsonl"
            pad = "x" * 80
            lines = [f'{{"i":{i},"pad":"{pad}"}}\n' for i in range(200)]
            path.write_text("".join(lines), encoding="utf-8")
            self.assertGreater(path.stat().st_size, 5_000)
            changed = process_hygiene.trim_journal_file(
                path, max_bytes=5_000, keep_bytes=2_000
            )
            self.assertTrue(changed)
            self.assertLessEqual(path.stat().st_size, 2_500)
            # Surviving content should still be JSON lines.
            for line in path.read_text(encoding="utf-8").splitlines():
                self.assertTrue(line.startswith("{"))

    def test_is_claude_sdk_detects_sdk_binary(self) -> None:
        cmd = (
            "/home/u/.nvm/.../claude-agent-sdk-linux-x64/claude "
            "--output-format stream-json"
        )
        self.assertTrue(process_hygiene._is_claude_sdk(cmd))
        self.assertFalse(process_hygiene._is_claude_sdk("python3 -m adsm serve"))

    def test_reap_keeps_newest(self) -> None:
        # Fake three children; reap should kill the two older.
        with mock.patch.object(
            process_hygiene,
            "list_claude_sdk_pids",
            return_value=[(11, 1.0), (22, 2.0), (33, 3.0)],
        ), mock.patch.object(
            process_hygiene.os, "kill"
        ) as kill, mock.patch.object(
            process_hygiene.time, "sleep"
        ):
            # First pass SIGTERM; second pass SIGKILL checks use kill(pid,0)
            def _kill(pid: int, sig: int) -> None:
                if sig == 0 and pid in (11, 22):
                    return  # still alive → will SIGKILL
                if sig == 0 and pid == 33:
                    raise ProcessLookupError()

            kill.side_effect = _kill
            n = process_hygiene.reap_extra_claude_children(100)
            self.assertEqual(n, 2)
            term_pids = [
                c.args[0]
                for c in kill.call_args_list
                if c.args[1] == process_hygiene.signal.SIGTERM
            ]
            self.assertEqual(sorted(term_pids), [11, 22])


if __name__ == "__main__":
    unittest.main()
