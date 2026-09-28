"""Every device connected to a chat sees what any one of them does."""

from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from adsm import paths
from adsm.daemon import Daemon


class _Writer:
    """Stands in for a client's asyncio.StreamWriter."""

    def __init__(self) -> None:
        self.lines: list[dict] = []

    def write(self, raw: bytes) -> None:
        for line in raw.decode("utf-8").splitlines():
            if line.strip():
                self.lines.append(json.loads(line))

    async def drain(self) -> None:
        return None

    def events(self, kind: str) -> list[dict]:
        return [
            m["params"]
            for m in self.lines
            if m.get("method") == "event" and m["params"].get("kind") == kind
        ]


class MultiDeviceTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self._patch = mock.patch.object(
            paths, "agentdock_root", return_value=Path(self._tmp.name)
        )
        self._patch.start()
        self.daemon = Daemon()

    async def asyncTearDown(self) -> None:
        self._patch.stop()
        self._tmp.cleanup()

    async def _subscribe(self, chat_id: str = "", **extra) -> _Writer:
        w = _Writer()
        params = {"chatId": chat_id} if chat_id else {}
        await self.daemon._subscribe({**params, **extra}, w)
        return w

    async def test_user_message_reaches_other_devices(self) -> None:
        phone = await self._subscribe("c1")
        mac = await self._subscribe("c1")
        everywhere = await self._subscribe()
        chat_list = await self._subscribe(digest=True)
        worker = self.daemon._worker("c1")
        worker.acp_session_id = "s1"

        async def _noop(*_a, **_k):
            return None

        async def _hang(_blocks):
            await asyncio.sleep(3600)

        with mock.patch.object(worker, "_revive_transport", _noop), mock.patch.object(
            worker, "_prompt_acp", _hang
        ):
            await worker.prompt(
                "hello from the phone",
                user_message_id="m-1",
                user_created_at="2026-09-28T10:00:00+00:00",
            )
            await worker.cancel()
        for device in (phone, mac, everywhere, chat_list):
            [msg] = device.events("user_message")
            self.assertEqual(msg["chatId"], "c1")
            self.assertEqual(msg["messageId"], "m-1")
            self.assertEqual(msg["text"], "hello from the phone")
            self.assertEqual(msg["createdAt"], "2026-09-28T10:00:00+00:00")
            self.assertGreater(msg["seq"], 0)

    async def test_chats_notify_reaches_global_listeners_only_live(self) -> None:
        everywhere = await self._subscribe()
        other_chat = await self._subscribe("c2")
        await self.daemon._chats_notify({"chatId": "c1", "change": "renamed"})
        [ev] = everywhere.events("chat_changed")
        self.assertEqual((ev["chatId"], ev["change"]), ("c1", "renamed"))
        self.assertEqual(other_chat.events("chat_changed"), [])
        # Not replayed to a device that subscribes later.
        late = await self._subscribe("c1")
        self.assertEqual(late.events("chat_changed"), [])


    async def test_reply_segments_persist_under_shared_ids(self) -> None:
        from adsm import transcript
        from adsm.worker import segment_message_id

        worker = self.daemon._worker("c1")
        worker._turn_assistant_id = "t1"
        await worker._emit_event("text", text="Let me ")
        await worker._emit_event("text", text="look.")
        first_seq = 1
        await worker._emit_event("tool_start", tool={"toolCallId": "x"})
        await worker._emit_event("text", text="Done.")
        second_seq = 4
        worker._persist_assistant_turn()
        rows = transcript.list_messages("c1")
        self.assertEqual(
            [(r["id"], r["content"]) for r in rows],
            [
                (segment_message_id("c1", "t1", first_seq), "Let me look."),
                (segment_message_id("c1", "t1", second_seq), "Done."),
            ],
        )
        # Same formula as the app's _streamMessageId (uuid v5, URL namespace).
        self.assertEqual(
            segment_message_id("c1", "t1", 7),
            "4a1bb356-cfdc-5e27-a855-443c38203e50",
        )

    async def test_digest_skips_token_stream(self) -> None:
        chat_list = await self._subscribe(digest=True)
        await self.daemon._worker_emit({"chatId": "c1", "kind": "text", "text": "hi"})
        await self.daemon._worker_emit(
            {"chatId": "c1", "kind": "turn_complete", "reason": "end_turn"}
        )
        kinds = [m["params"]["kind"] for m in chat_list.lines]
        self.assertEqual(kinds, ["turn_complete"])


if __name__ == "__main__":
    unittest.main()
