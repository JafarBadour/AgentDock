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
        # "c" has no goal, which is allowed — it gets the default.
        self._agent("c", title="Idle", permission_ask=False, archon_managed=True)
        got = self.run_cli(["goals"])
        titles = [e["title"] for e in got["here"]]
        self.assertEqual({"Build", "Idle"}, set(titles))

    def test_goals_says_when_it_could_not_check_the_other_hosts(self) -> None:
        # No app here, so `elsewhere` is unknown rather than empty. Reporting
        # it as empty would tell the user there is nothing to do when the
        # truth is that Archon could not look.
        self._agent("a", title="Build", permission_ask=False,
                    archon_managed=True, archon_goal="green CI")
        got = self.run_cli(["goals"])
        self.assertEqual([], got["elsewhere"])
        self.assertIn("routeError", got)

    def test_goals_includes_agents_the_app_manages_on_other_hosts(self) -> None:
        # The user switches an agent on in the app; that never reaches this
        # host's records, so without the relay `goals` reads empty even
        # straight after they set a goal.
        self._agent("a", title="Build", permission_ask=False,
                    archon_managed=True, archon_goal="green CI")
        answer = {
            "ok": True,
            "result": {
                "agents": [
                    {"chatId": "far", "title": "diegoRl2Grid", "hostId": "h2",
                     "managed": True, "goal": "verify his results"},
                    {"chatId": "idle", "title": "Idle", "managed": False},
                    # Already in `here`; the app's copy must not double it up.
                    {"chatId": "a", "title": "Build", "managed": True},
                ]
            },
        }
        with mock.patch.object(self.cli, "relay", return_value=answer):
            got = self.run_cli(["goals"])
        self.assertEqual(["Build"], [e["title"] for e in got["here"]])
        self.assertEqual(["diegoRl2Grid"], [e["title"] for e in got["elsewhere"]])
        self.assertNotIn("routeError", got)

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
        self.assertEqual([], self.run_cli(["goals"])["here"])

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


class ActionLogTest(unittest.TestCase):
    """Everything Archon does is written down, by the runner rather than by
    Archon — a manager acting while nobody watches is only acceptable if the
    user can see afterwards exactly what it did."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self._tmp.name})
        patch.start()
        self.addCleanup(patch.stop)
        from adsm import paths as adsm_paths
        from archon import cli
        from archon.store import ArchonStore

        adsm_paths.ensure_layout()
        self.adsm_paths = adsm_paths
        self.cli = cli
        self.store = ArchonStore()

    def _agent(self, chat_id: str, **fields) -> None:
        self.adsm_paths.agent_record_path(chat_id).write_text(
            json.dumps({"id": chat_id, **fields}), encoding="utf-8"
        )

    def run_cli(self, argv: list[str]) -> int:
        with redirect_stdout(io.StringIO()):
            return self.cli.main(argv)

    def _log(self) -> list[dict]:
        return self.store.actions()

    def test_an_action_is_recorded_without_being_asked_to_be(self) -> None:
        self._agent("a", title="Build", permission_ask=False)
        self.run_cli(["done", "a", "CI green since 14:02."])
        entry = self._log()[0]
        self.assertEqual("done", entry["command"])
        self.assertEqual("a", entry["target"])
        self.assertEqual("CI green since 14:02.", entry["summary"])
        self.assertTrue(entry["ok"])

    def test_a_refusal_is_recorded_with_its_reason(self) -> None:
        # What Archon was stopped from doing matters as much as what it did.
        self._agent("b", title="Deploy", permission_ask=True)
        self.run_cli(["prompt", "b", "deploy it"])
        entry = self._log()[0]
        self.assertEqual("prompt", entry["command"])
        self.assertFalse(entry["ok"])
        self.assertIn("Allow all", entry["summary"])

    def test_reading_is_not_doing_and_stays_out_of_the_log(self) -> None:
        # These run on every wake; logging them would bury the real actions.
        self._agent("a", title="Build", permission_ask=False)
        for argv in (["agents"], ["goals"], ["blocked"], ["due"], ["pending"],
                     ["recall", "user"], ["log"]):
            self.run_cli(argv)
        self.assertEqual([], self._log())

    def test_remote_calls_name_the_host_they_were_aimed_at(self) -> None:
        self.run_cli(["remote", "prompt", "hostB", "c9", "rerun the test"])
        entry = self._log()[0]
        self.assertEqual("remote prompt", entry["command"])
        self.assertEqual("hostB/c9", entry["target"])

    def test_remote_read_names_the_agent_it_went_to_look_at(self) -> None:
        # Plain `read` asks this host's daemon, which holds nothing for a chat
        # living elsewhere — so taking a remote chat over meant prompting
        # blind until `remote read` existed.
        self.run_cli(["remote", "read", "hostB", "c9", "--tail", "5"])
        entry = self._log()[0]
        self.assertEqual("remote read", entry["command"])
        self.assertEqual("hostB/c9", entry["target"])

    def test_the_log_is_newest_first(self) -> None:
        self._agent("a", title="Build", permission_ask=False)
        self.run_cli(["remember", "user", "first"])
        self.run_cli(["schedule", "second", "--in", "60"])
        self.assertEqual("schedule", self._log()[0]["command"])

    def test_the_log_is_bounded(self) -> None:
        for i in range(30):
            self.store.record_action("remember", target="user", summary=f"{i}")
        self.store.trim_actions(keep=10)
        self.assertEqual(10, len(self.store.actions(limit=100)))
        # The newest survive, not the oldest.
        self.assertEqual("29", self.store.actions()[0]["summary"])

    def test_a_broken_log_never_fails_the_command(self) -> None:
        # Bookkeeping must not turn a working action into a failed one: the
        # command already had its effect by the time the row is written.
        from archon.store import ArchonStore

        self._agent("a", title="Build", permission_ask=False)
        with mock.patch.object(
            ArchonStore, "record_action", side_effect=OSError("disk full")
        ):
            self.assertEqual(0, self.run_cli(["done", "a", "finished"]))
        # And the action really did happen, log or no log.
        from archon import directory

        self.assertFalse(directory.is_managed(directory.load_records()[0]))
