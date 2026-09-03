"""Unit tests for durable ADSM transcript store."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


class TranscriptStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        self._home_patch = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        self._home_patch.start()
        self.addCleanup(self._home_patch.stop)
        # Import after HOME is set so expanduser resolves into the temp tree.
        from adsm import transcript as transcript_store

        self.transcript = transcript_store
        self.chat_id = "chat-reconnect-1"

    def test_append_list_round_trip(self) -> None:
        self.transcript.append_message(
            self.chat_id,
            role="user",
            content="hello",
            message_id="u1",
            created_at="2026-01-01T10:00:00+00:00",
        )
        self.transcript.append_message(
            self.chat_id,
            role="assistant",
            content="hi there",
            message_id="a1",
            created_at="2026-01-01T10:00:01+00:00",
        )
        msgs = self.transcript.list_messages(self.chat_id)
        self.assertEqual([m["id"] for m in msgs], ["u1", "a1"])
        self.assertEqual(msgs[0]["content"], "hello")
        self.assertEqual(msgs[1]["role"], "assistant")
        path = self.transcript.messages_path(self.chat_id)
        self.assertTrue(path.exists())
        messages_root = (self.home / ".agentdock" / "messages").resolve()
        self.assertEqual(path.resolve().parent, messages_root)

    def test_list_dedupes_by_id_longest_content_wins(self) -> None:
        path = self.transcript.messages_path(self.chat_id)
        self.transcript.ensure_messages_dir()
        with path.open("w", encoding="utf-8") as fh:
            fh.write(
                json.dumps(
                    {
                        "id": "a1",
                        "chat_id": self.chat_id,
                        "role": "assistant",
                        "content": "partial",
                        "created_at": "2026-01-01T10:00:00+00:00",
                    }
                )
                + "\n"
            )
            fh.write(
                json.dumps(
                    {
                        "id": "a1",
                        "chat_id": self.chat_id,
                        "role": "assistant",
                        "content": "partial then more",
                        "created_at": "2026-01-01T10:00:00+00:00",
                    }
                )
                + "\n"
            )
        msgs = self.transcript.list_messages(self.chat_id)
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["content"], "partial then more")

    def test_upsert_merges_without_dropping_host_only(self) -> None:
        self.transcript.append_message(
            self.chat_id,
            role="user",
            content="from host turn",
            message_id="u-host",
            created_at="2026-01-01T10:00:00+00:00",
        )
        self.transcript.append_message(
            self.chat_id,
            role="assistant",
            content="host reply",
            message_id="a-host",
            created_at="2026-01-01T10:00:01+00:00",
        )
        changed = self.transcript.upsert_messages(
            self.chat_id,
            [
                {
                    "id": "u-phone",
                    "role": "user",
                    "content": "offline bubble",
                    "created_at": "2026-01-01T09:59:00+00:00",
                },
                {
                    "id": "a-host",
                    "role": "assistant",
                    "content": "host reply with more tokens",
                    "created_at": "2026-01-01T10:00:01+00:00",
                },
            ],
        )
        self.assertGreaterEqual(changed, 2)
        msgs = self.transcript.list_messages(self.chat_id)
        ids = [m["id"] for m in msgs]
        self.assertEqual(ids, ["u-phone", "u-host", "a-host"])
        self.assertEqual(
            next(m["content"] for m in msgs if m["id"] == "a-host"),
            "host reply with more tokens",
        )

    def test_upsert_accepts_camel_case_keys(self) -> None:
        self.transcript.upsert_messages(
            self.chat_id,
            [
                {
                    "id": "m1",
                    "chatId": self.chat_id,
                    "role": "user",
                    "content": "hi",
                    "createdAt": "2026-01-01T10:00:00Z",
                }
            ],
        )
        msgs = self.transcript.list_messages(self.chat_id)
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["created_at"], "2026-01-01T10:00:00Z")

    def test_upsert_skips_shorter_body(self) -> None:
        self.transcript.append_message(
            self.chat_id,
            role="assistant",
            content="already long body here",
            message_id="a1",
            created_at="2026-01-01T10:00:00+00:00",
        )
        changed = self.transcript.upsert_messages(
            self.chat_id,
            [
                {
                    "id": "a1",
                    "role": "assistant",
                    "content": "short",
                    "created_at": "2026-01-01T10:00:00+00:00",
                }
            ],
        )
        self.assertEqual(changed, 0)
        self.assertEqual(
            self.transcript.list_messages(self.chat_id)[0]["content"],
            "already long body here",
        )

    def test_clear_messages(self) -> None:
        self.transcript.append_message(
            self.chat_id, role="user", content="bye", message_id="u1"
        )
        self.assertTrue(self.transcript.clear_messages(self.chat_id))
        self.assertEqual(self.transcript.list_messages(self.chat_id), [])
        self.assertFalse(self.transcript.clear_messages(self.chat_id))

    def test_corrupt_lines_are_skipped(self) -> None:
        path = self.transcript.messages_path(self.chat_id)
        self.transcript.ensure_messages_dir()
        path.write_text(
            "not-json\n"
            + json.dumps(
                {
                    "id": "ok",
                    "role": "user",
                    "content": "kept",
                    "created_at": "2026-01-01T10:00:00+00:00",
                }
            )
            + "\n"
            + '{"id":"","role":"user","content":"bad"}\n',
            encoding="utf-8",
        )
        msgs = self.transcript.list_messages(self.chat_id)
        self.assertEqual([m["id"] for m in msgs], ["ok"])

    def test_safe_chat_id_in_filename(self) -> None:
        weird = "../evil;rm"
        self.transcript.append_message(
            weird, role="user", content="x", message_id="u1"
        )
        path = self.transcript.messages_path(weird)
        self.assertEqual(
            path.resolve().parent,
            (self.home / ".agentdock" / "messages").resolve(),
        )
        self.assertNotIn("..", path.name)
        self.assertTrue(path.exists())


class TranscriptRpcTest(unittest.IsolatedAsyncioTestCase):
    """Exercise daemon transcript.pull / transcript.sync without a live worker."""

    async def asyncSetUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        self._home_patch = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        self._home_patch.start()
        from adsm.daemon import Daemon

        self.daemon = Daemon()

    async def asyncTearDown(self) -> None:
        self._home_patch.stop()
        self._tmp.cleanup()

    async def test_pull_and_sync_rpc(self) -> None:
        chat_id = "rpc-chat"
        empty = await self.daemon._transcript_pull({"chatId": chat_id})
        self.assertEqual(empty["messages"], [])

        synced = await self.daemon._transcript_sync(
            {
                "chatId": chat_id,
                "messages": [
                    {
                        "id": "u1",
                        "role": "user",
                        "content": "prompt",
                        "created_at": "2026-01-01T10:00:00+00:00",
                    },
                    {
                        "id": "a1",
                        "role": "assistant",
                        "content": "reply",
                        "created_at": "2026-01-01T10:00:01+00:00",
                    },
                ],
            }
        )
        self.assertEqual(synced["count"], 2)
        self.assertGreaterEqual(synced["changed"], 2)

        pulled = await self.daemon._transcript_pull({"chatId": chat_id})
        self.assertEqual([m["id"] for m in pulled["messages"]], ["u1", "a1"])


if __name__ == "__main__":
    unittest.main()
