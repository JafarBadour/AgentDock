"""The `archon` command: Archon's tools are a shell command, so they are
checked the way Archon will actually use them — argv in, JSON out."""

from __future__ import annotations

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


class ArchonCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self._tmp.name})
        patch.start()
        self.addCleanup(patch.stop)
        from adsm import paths as adsm_paths
        from archon import cli

        adsm_paths.ensure_layout()
        self.adsm_paths = adsm_paths
        self.cli = cli

    def _agent(self, chat_id: str, **fields) -> None:
        self.adsm_paths.agent_record_path(chat_id).write_text(
            json.dumps({"id": chat_id, **fields}), encoding="utf-8"
        )

    def run_cli(self, argv: list[str]) -> object:
        out = io.StringIO()
        with redirect_stdout(out):
            code = self.cli.main(argv)
        self.assertEqual(0, code, f"archon {' '.join(argv)} failed")
        return json.loads(out.getvalue())

    def test_agents_lists_what_archon_can_see(self) -> None:
        self._agent("a", title="Build", permission_ask=False)
        self._agent("b", title="Deploy", permission_ask=True)
        got = self.run_cli(["agents"])
        self.assertEqual({"Build", "Deploy"}, {e["title"] for e in got})

    def test_goals_is_only_work_archon_may_do(self) -> None:
        self._agent("a", title="Build", permission_ask=False,
                    archon_managed=True, archon_goal="green CI")
        self._agent("b", title="Deploy", permission_ask=True,
                    archon_managed=True, archon_goal="ship")
        self._agent("c", title="Idle", permission_ask=False)
        self.assertEqual(["Build"], [e["title"] for e in self.run_cli(["goals"])])

    def test_blocked_says_why_and_how_to_unblock(self) -> None:
        self._agent("b", title="Deploy", permission_ask=True,
                    archon_managed=True, archon_goal="ship")
        entry = self.run_cli(["blocked"])[0]
        self.assertEqual("Deploy", entry["title"])
        self.assertIn("Allow all", entry["why"])

    def test_done_switches_it_off_and_drops_it_from_goals(self) -> None:
        self._agent("a", title="Build", permission_ask=False,
                    archon_managed=True, archon_goal="green CI")
        done = self.run_cli(["done", "a", "CI green since 14:02."])
        self.assertFalse(done["managed"])
        self.assertEqual("CI green since 14:02.", done["note"])
        self.assertEqual([], self.run_cli(["goals"]))

    def test_done_on_a_missing_agent_reports_failure(self) -> None:
        self.assertEqual(1, self.cli.main(["done", "nope", "x"]))

    def test_memory_round_trips(self) -> None:
        stored = self.run_cli(["remember", "user", "prefers short replies"])
        self.assertTrue(stored["stored"])
        recalled = self.run_cli(["recall", "user"])
        self.assertEqual(["prefers short replies"], [m["body"] for m in recalled])

    def test_blank_memory_is_not_kept(self) -> None:
        self.assertFalse(self.run_cli(["remember", "user", "   "])["stored"])

    def test_scheduling_shows_up_as_pending_with_a_wakeup(self) -> None:
        self.run_cli(["schedule", "check CI", "--in", "600"])
        pending = self.run_cli(["pending"])
        self.assertEqual(["check CI"], [e["label"] for e in pending["entries"]])
        self.assertIsNotNone(pending["nextWakeup"])

    def test_a_future_entry_is_not_due_yet(self) -> None:
        self.run_cli(["schedule", "later", "--in", "600"])
        self.assertEqual([], self.run_cli(["due"]))

    def test_cancel_removes_it(self) -> None:
        entry = self.run_cli(["schedule", "drop me", "--in", "600"])["id"]
        self.assertTrue(self.run_cli(["cancel", entry])["cancelled"])
        self.assertEqual([], self.run_cli(["pending"])["entries"])

    def test_every_command_prints_parsable_json(self) -> None:
        # The skill parses stdout; prose mixed in would break Archon's tools.
        self._agent("a", title="Build", permission_ask=False)
        for argv in (["agents"], ["goals"], ["blocked"], ["due"], ["pending"]):
            self.run_cli(argv)


if __name__ == "__main__":
    unittest.main()
