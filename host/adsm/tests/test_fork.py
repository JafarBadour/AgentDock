"""Forking a chat: the copy carries the conversation, not the session."""

from __future__ import annotations

import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


class ForkMessagesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        self._home_patch = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        self._home_patch.start()
        self.addCleanup(self._home_patch.stop)
        from adsm import transcript as transcript_store

        self.transcript = transcript_store
        self.src = "chat-src"
        self.dst = "chat-fork"

    def _seed(self) -> None:
        for i, (role, text) in enumerate(
            [
                ("user", "add a login screen"),
                ("assistant", "done, added login.dart"),
                ("user", "now add tests"),
                ("assistant", "added login_test.dart"),
            ]
        ):
            self.transcript.append_message(
                self.src,
                role=role,
                content=text,
                message_id=f"m{i}",
                created_at=f"2026-01-01T10:00:0{i}+00:00",
            )

    def test_fork_copies_conversation_under_fresh_ids(self) -> None:
        self._seed()
        forked = self.transcript.fork_messages(self.src, self.dst)

        self.assertEqual(
            [m["content"] for m in forked],
            [
                "add a login screen",
                "done, added login.dart",
                "now add tests",
                "added login_test.dart",
            ],
        )
        # Ids must not be reused — they are unique per device database, not
        # per chat, so a copy would collide with the source once it syncs.
        self.assertEqual(set(), {m["id"] for m in forked} & {f"m{i}" for i in range(4)})
        self.assertEqual({self.dst}, {m["chat_id"] for m in forked})
        # Timestamps are kept so the fork reads in the original order.
        self.assertEqual(
            [m["created_at"] for m in forked],
            [f"2026-01-01T10:00:0{i}+00:00" for i in range(4)],
        )
        self.assertEqual(forked, self.transcript.list_messages(self.dst))

    def test_fork_leaves_the_source_untouched(self) -> None:
        self._seed()
        before = self.transcript.list_messages(self.src)
        self.transcript.fork_messages(self.src, self.dst)
        self.assertEqual(before, self.transcript.list_messages(self.src))

    def test_fork_through_a_message_drops_what_came_after(self) -> None:
        self._seed()
        forked = self.transcript.fork_messages(
            self.src, self.dst, through_id="m1"
        )
        self.assertEqual(
            [m["content"] for m in forked],
            ["add a login screen", "done, added login.dart"],
        )

    def test_fork_of_an_empty_chat_is_empty(self) -> None:
        self.assertEqual([], self.transcript.fork_messages(self.src, self.dst))
        self.assertEqual([], self.transcript.list_messages(self.dst))

    def test_fork_replaces_any_earlier_content_at_the_target(self) -> None:
        self._seed()
        self.transcript.append_message(
            self.dst, role="user", content="stale", message_id="old"
        )
        self.transcript.fork_messages(self.src, self.dst)
        rows = self.transcript.list_messages(self.dst)
        self.assertNotIn("stale", [m["content"] for m in rows])


class ForkRpcTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        self._home_patch = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        self._home_patch.start()
        self.addCleanup(self._home_patch.stop)
        from adsm import paths
        from adsm import transcript as transcript_store
        from adsm.daemon import Daemon

        self.paths = paths
        self.transcript = transcript_store
        paths.ensure_layout()
        self.daemon = Daemon()
        self.src = "chat-src"
        self.dst = "chat-fork"

    def _record(self, chat_id: str, **fields) -> None:
        path = self.paths.agent_record_path(chat_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"id": chat_id, **fields}), encoding="utf-8")

    def test_fork_seeds_the_record_but_never_the_acp_session(self) -> None:
        self._record(
            self.src,
            cwd="/Users/me/proj",
            binary="claude-acp",
            provider="claude",
            model_id="claude-opus-5",
            acp_session_id="sess-live-123",
        )
        self.transcript.append_message(
            self.src, role="user", content="hello", message_id="m0"
        )

        result = asyncio.run(
            self.daemon._chats_fork(
                {"fromChatId": self.src, "chatId": self.dst}
            )
        )
        self.assertEqual(1, result["messages"])

        rec = json.loads(
            self.paths.agent_record_path(self.dst).read_text(encoding="utf-8")
        )
        self.assertEqual("/Users/me/proj", rec["cwd"])
        self.assertEqual("claude", rec["provider"])
        self.assertEqual("claude-opus-5", rec["model_id"])
        # The whole point: the fork opens its own session.
        self.assertNotIn("acp_session_id", rec)

    def test_fork_marks_the_target_so_the_worker_explains_itself(self) -> None:
        self._record(self.src, cwd="/tmp/p", provider="claude")
        asyncio.run(
            self.daemon._chats_fork(
                {"fromChatId": self.src, "chatId": self.dst}
            )
        )
        marker = self.paths.session_dir(self.dst) / "forked_from"
        self.assertEqual(self.src, marker.read_text(encoding="utf-8").strip())

    def test_fork_refuses_to_overwrite_an_existing_chat(self) -> None:
        self._record(self.src, cwd="/tmp/p")
        self._record(self.dst, cwd="/tmp/other")
        self.transcript.append_message(
            self.dst, role="user", content="mine", message_id="keep"
        )
        with self.assertRaises(ValueError):
            asyncio.run(
                self.daemon._chats_fork(
                    {"fromChatId": self.src, "chatId": self.dst}
                )
            )
        # And the existing chat's transcript survived the refusal.
        self.assertEqual(
            ["mine"],
            [m["content"] for m in self.transcript.list_messages(self.dst)],
        )

    def test_fork_requires_both_ids_and_rejects_self(self) -> None:
        for params in (
            {"chatId": self.dst},
            {"fromChatId": self.src},
            {"fromChatId": self.src, "chatId": self.src},
        ):
            with self.assertRaises(ValueError):
                asyncio.run(self.daemon._chats_fork(params))


if __name__ == "__main__":
    unittest.main()
