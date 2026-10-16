"""`agents.ensure` must not rewrite an agent it was not told about.

A caller that omits `provider` means "whatever this already is", not "make it
Cursor". Defaulting relaunched a Claude agent as Cursor in no working
directory, which is a chat that can never answer.
"""

from __future__ import annotations

import json
import unittest
from unittest import mock

from adsm.daemon import Daemon


class EnsureIdentityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.daemon = Daemon.__new__(Daemon)

    def _record(self, data: dict) -> mock._patch:
        payload = json.dumps(data)

        class _Path:
            def exists(self_inner) -> bool:
                return True

            def read_text(self_inner, encoding: str = "utf-8") -> str:
                return payload

        return mock.patch("adsm.daemon.paths.agent_record_path",
                          return_value=_Path())

    def test_an_existing_provider_wins_over_the_default(self) -> None:
        with self._record({"id": "archon", "provider": "claude"}):
            self.assertEqual("claude", self.daemon._recorded_provider("archon"))

    def test_no_record_means_no_opinion(self) -> None:
        with mock.patch("adsm.daemon.paths.agent_record_path") as p:
            p.return_value.exists.return_value = False
            self.assertIsNone(self.daemon._recorded_provider("new"))
            self.assertIsNone(self.daemon._recorded_cwd("new"))

    def test_cwd_falls_back_to_the_placement_path(self) -> None:
        # Archon's record carries repo_path even when cwd was never written,
        # and launching in no directory is what broke it.
        with self._record({"id": "archon", "repo_path": "/home/u/ws"}):
            self.assertEqual("/home/u/ws", self.daemon._recorded_cwd("archon"))

    def test_cwd_prefers_an_explicit_one(self) -> None:
        with self._record({"cwd": "/a", "repo_path": "/b"}):
            self.assertEqual("/a", self.daemon._recorded_cwd("archon"))

    def test_a_corrupt_record_is_not_fatal(self) -> None:
        class _Bad:
            def exists(self) -> bool:
                return True

            def read_text(self, encoding: str = "utf-8") -> str:
                return "{not json"

        with mock.patch("adsm.daemon.paths.agent_record_path",
                        return_value=_Bad()):
            self.assertIsNone(self.daemon._recorded_provider("x"))


if __name__ == "__main__":
    unittest.main()
