"""Archon acts with the user's permissions — never past them."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


class DirectoryTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self._tmp.name})
        patch.start()
        self.addCleanup(patch.stop)
        from adsm import paths as adsm_paths
        from archon import directory

        adsm_paths.ensure_layout()
        self.adsm_paths = adsm_paths
        self.directory = directory

    def _record(self, chat_id: str, **fields) -> dict:
        record = {"id": chat_id, **fields}
        path = self.adsm_paths.agent_record_path(chat_id)
        path.write_text(json.dumps(record), encoding="utf-8")
        return record

    def test_allow_all_is_commandable(self) -> None:
        record = self._record("a", title="Build", permission_ask=False)
        self.assertEqual(self.directory.ALLOW_ALL, self.directory.policy_of(record))
        self.assertTrue(self.directory.is_commandable(record))
        self.assertIsNone(self.directory.refusal_for(record))

    def test_ask_is_off_limits(self) -> None:
        # The user wants to approve each tool on their device; Archon is not
        # that device and cannot stand in for the approval.
        record = self._record("b", title="Deploy", permission_ask=True)
        self.assertEqual(self.directory.ASK, self.directory.policy_of(record))
        self.assertFalse(self.directory.is_commandable(record))

    def test_an_unrecorded_permission_is_not_a_granted_one(self) -> None:
        # Records written before the field existed must fail closed.
        record = self._record("c", title="Legacy")
        self.assertEqual(self.directory.ASK, self.directory.policy_of(record))
        self.assertFalse(self.directory.is_commandable(record))

    def test_the_refusal_names_the_agent_and_the_way_out(self) -> None:
        record = self._record("d", title="Deploy", permission_ask=True)
        refusal = self.directory.refusal_for(record)
        self.assertIn("Deploy", refusal)
        self.assertIn("Allow all", refusal)

    def test_an_off_limits_agent_is_still_listed(self) -> None:
        # Hiding it would leave Archon unable to say why nothing is happening.
        self._record("a", title="Build", permission_ask=False)
        self._record("b", title="Deploy", permission_ask=True)
        listed = self.directory.describe(self.directory.load_records())
        self.assertEqual({"Build", "Deploy"}, {e["title"] for e in listed})
        by_title = {e["title"]: e for e in listed}
        self.assertTrue(by_title["Build"]["commandable"])
        self.assertFalse(by_title["Deploy"]["commandable"])

    def test_commandable_filters_to_what_archon_may_drive(self) -> None:
        self._record("a", title="Build", permission_ask=False)
        self._record("b", title="Deploy", permission_ask=True)
        self._record("c", title="Legacy")
        got = self.directory.commandable(self.directory.load_records())
        self.assertEqual(["Build"], [r["title"] for r in got])

    def test_describe_carries_what_archon_chooses_from(self) -> None:
        self._record(
            "a",
            title="Build",
            provider="claude",
            status="idle",
            repo_name="agentic-phone",
            updated_at="2026-09-30T12:00:00+00:00",
            permission_ask=False,
        )
        entry = self.directory.describe(
            self.directory.load_records(), host="this-mac"
        )[0]
        self.assertEqual("Build", entry["title"])
        self.assertEqual("claude", entry["provider"])
        self.assertEqual("idle", entry["status"])
        self.assertEqual("agentic-phone", entry["repo"])
        self.assertEqual("this-mac", entry["host"])
        # Not the transcript: pulling every chat to answer "what is going on"
        # is the habit the directory exists to avoid.
        self.assertNotIn("messages", entry)

    def test_a_corrupt_record_is_skipped_not_fatal(self) -> None:
        self._record("a", title="Build", permission_ask=False)
        self.adsm_paths.agent_record_path("broken").write_text(
            "{not json", encoding="utf-8"
        )
        self.assertEqual(
            ["Build"], [r["title"] for r in self.directory.load_records()]
        )

    def test_no_agents_is_an_empty_directory(self) -> None:
        self.assertEqual([], self.directory.load_records())
        self.assertEqual([], self.directory.describe([]))


class RecordedPolicyTest(unittest.TestCase):
    """The daemon has to write the field the gate reads."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self._tmp.name})
        patch.start()
        self.addCleanup(patch.stop)
        from adsm import paths as adsm_paths
        from adsm.daemon import Daemon

        adsm_paths.ensure_layout()
        self.adsm_paths = adsm_paths
        self.daemon = Daemon()

    def test_ensure_records_the_permission_choice(self) -> None:
        import asyncio

        from archon import directory

        for ask, expected in ((True, directory.ASK), (False, directory.ALLOW_ALL)):
            chat = f"chat-{ask}"
            asyncio.run(
                self.daemon._patch_agent_record(chat, permission_ask=ask)
            )
            record = json.loads(
                self.adsm_paths.agent_record_path(chat).read_text(encoding="utf-8")
            )
            self.assertEqual(expected, directory.policy_of(record))


if __name__ == "__main__":
    unittest.main()


class AutoManageTest(unittest.TestCase):
    """The user picks who Archon looks after, and what done means."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self._tmp.name})
        patch.start()
        self.addCleanup(patch.stop)
        from adsm import paths as adsm_paths
        from archon import directory

        adsm_paths.ensure_layout()
        self.adsm_paths = adsm_paths
        self.directory = directory

    def _record(self, chat_id: str, **fields) -> dict:
        record = {"id": chat_id, **fields}
        self.adsm_paths.agent_record_path(chat_id).write_text(
            json.dumps(record), encoding="utf-8"
        )
        return record

    def test_managed_with_a_goal_is_work_archon_picks_up(self) -> None:
        self._record(
            "a",
            title="Build",
            permission_ask=False,
            archon_managed=True,
            archon_goal="green CI on main",
        )
        got = self.directory.manageable(self.directory.load_records())
        self.assertEqual(["Build"], [r["title"] for r in got])

    def test_switched_on_without_a_goal_is_not_work(self) -> None:
        # Nothing to work toward means nothing to decide is finished.
        self._record("a", title="Build", permission_ask=False, archon_managed=True)
        self.assertEqual([], self.directory.manageable(self.directory.load_records()))

    def test_permission_beats_the_toggle(self) -> None:
        # The toggle is the user's intent; the permission is their authority.
        self._record(
            "a",
            title="Deploy",
            permission_ask=True,
            archon_managed=True,
            archon_goal="ship it",
        )
        records = self.directory.load_records()
        self.assertEqual([], self.directory.manageable(records))
        self.assertEqual(["Deploy"], [r["title"] for r in self.directory.blocked(records)])

    def test_finishing_switches_it_off_and_says_why(self) -> None:
        self._record(
            "a",
            title="Build",
            permission_ask=False,
            archon_managed=True,
            archon_goal="green CI on main",
        )
        updated = self.directory.complete("a", "CI green since 14:02; flake fixed.")
        self.assertFalse(self.directory.is_managed(updated))
        self.assertEqual("CI green since 14:02; flake fixed.", self.directory.note_of(updated))
        self.assertIn(self.directory.DONE_AT, updated)
        # A toggle left on beside a note would read as work still in progress.
        self.assertEqual([], self.directory.manageable(self.directory.load_records()))

    def test_finishing_survives_a_reread(self) -> None:
        self._record("a", title="Build", permission_ask=False, archon_managed=True,
                     archon_goal="g")
        self.directory.complete("a", "done")
        reread = self.directory.load_records()[0]
        self.assertFalse(self.directory.is_managed(reread))
        self.assertEqual("done", self.directory.note_of(reread))

    def test_finishing_keeps_everything_else_on_the_record(self) -> None:
        self._record(
            "a", title="Build", provider="claude", permission_ask=False,
            archon_managed=True, archon_goal="g", acp_session_id="sess-1",
        )
        updated = self.directory.complete("a", "done")
        self.assertEqual("Build", updated["title"])
        self.assertEqual("sess-1", updated["acp_session_id"])
        self.assertFalse(updated["permission_ask"])

    def test_finishing_an_agent_that_is_gone_is_not_fatal(self) -> None:
        self.assertIsNone(self.directory.complete("nope", "done"))

    def test_a_blank_goal_does_not_count_as_one(self) -> None:
        self._record("a", title="Build", permission_ask=False,
                     archon_managed=True, archon_goal="   ")
        self.assertEqual([], self.directory.manageable(self.directory.load_records()))

    def test_the_directory_shows_the_goal_and_the_note(self) -> None:
        self._record("a", title="Build", permission_ask=False,
                     archon_managed=True, archon_goal="green CI")
        entry = self.directory.describe(self.directory.load_records())[0]
        self.assertTrue(entry["managed"])
        self.assertEqual("green CI", entry["goal"])
        self.assertIsNone(entry["note"])

        self.directory.complete("a", "CI green")
        after = self.directory.describe(self.directory.load_records())[0]
        self.assertFalse(after["managed"])
        self.assertEqual("CI green", after["note"])
