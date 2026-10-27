"""Tests for Worker launch-field hydration (idle FIFO revive)."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from adsm import paths
from adsm.worker import Worker


class HydrateLaunchFieldsTest(unittest.TestCase):
    def test_hydrate_fills_cwd_binary_from_agent_record(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with mock.patch.object(paths, "agentdock_root", return_value=root):
                chat_id = "chat-hydrate-1"
                rec = paths.agent_record_path(chat_id)
                rec.parent.mkdir(parents=True, exist_ok=True)
                rec.write_text(
                    json.dumps(
                        {
                            "id": chat_id,
                            "cwd": "/tmp/proj",
                            "binary": "/usr/bin/agent",
                            "provider": "claude",
                            "acp_session_id": "sess-9",
                            "model_id": "opus",
                        }
                    ),
                    encoding="utf-8",
                )

                async def _emit(_payload: dict) -> None:
                    return None

                async def _set_status(_cid: str, _st: str, _err: str | None) -> None:
                    return None

                w = Worker(chat_id, emit=_emit, set_status=_set_status)
                self.assertEqual(w.cwd, "")
                self.assertEqual(w.binary, "")
                w._hydrate_launch_fields()
                self.assertEqual(w.cwd, "/tmp/proj")
                self.assertEqual(w.binary, "/usr/bin/agent")
                self.assertEqual(w.provider, "claude")
                self.assertEqual(w.acp_session_id, "sess-9")
                self.assertEqual(w.model_id, "opus")


    def test_hydrate_falls_back_to_repo_path_for_cwd(self) -> None:
        # Records written by older builds carry an explicit null `cwd` while
        # `repo_path` survives. Ignoring it meant an idle-stopped chat could
        # never revive: the user got "reopen this chat" on every prompt.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with mock.patch.object(paths, "agentdock_root", return_value=root):
                chat_id = "chat-hydrate-2"
                rec = paths.agent_record_path(chat_id)
                rec.parent.mkdir(parents=True, exist_ok=True)
                rec.write_text(
                    json.dumps(
                        {
                            "id": chat_id,
                            "cwd": None,
                            "repo_path": "/home/u/Arts",
                            "binary": "/usr/bin/agent",
                            "provider": "claude",
                        }
                    ),
                    encoding="utf-8",
                )

                async def _emit(_payload: dict) -> None:
                    return None

                async def _set_status(_cid: str, _st: str, _err: str | None) -> None:
                    return None

                w = Worker(chat_id, emit=_emit, set_status=_set_status)
                w._hydrate_launch_fields()
                self.assertEqual(w.cwd, "/home/u/Arts")
                self.assertEqual(w.binary, "/usr/bin/agent")

    def test_an_explicit_cwd_still_wins_over_repo_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with mock.patch.object(paths, "agentdock_root", return_value=root):
                chat_id = "chat-hydrate-3"
                rec = paths.agent_record_path(chat_id)
                rec.parent.mkdir(parents=True, exist_ok=True)
                rec.write_text(
                    json.dumps({"cwd": "/a", "repo_path": "/b"}),
                    encoding="utf-8",
                )

                async def _emit(_payload: dict) -> None:
                    return None

                async def _set_status(_cid: str, _st: str, _err: str | None) -> None:
                    return None

                w = Worker(chat_id, emit=_emit, set_status=_set_status)
                w._hydrate_launch_fields()
                self.assertEqual(w.cwd, "/a")


if __name__ == "__main__":
    unittest.main()
