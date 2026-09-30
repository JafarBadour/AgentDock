"""The app is Archon's route to other hosts.

Archon has no credentials for the user's other hosts — those live in the app,
which already holds a bridge to each one. So a cross-host call goes
Archon -> this daemon -> a live app -> the far host, and back.
"""

from __future__ import annotations

import asyncio
import json
import os
import tempfile
import unittest
from unittest import mock


class _Writer:
    """Stands in for a connected app."""

    def __init__(self) -> None:
        self.lines: list[dict] = []

    def write(self, raw: bytes) -> None:
        for line in raw.decode("utf-8").splitlines():
            if line.strip():
                self.lines.append(json.loads(line))

    async def drain(self) -> None:
        return None

    def requests(self) -> list[dict]:
        return [
            m["params"]
            for m in self.lines
            if m.get("method") == "event"
            and m["params"].get("kind") == "archon_request"
        ]


class _DeadWriter(_Writer):
    def write(self, raw: bytes) -> None:
        raise ConnectionResetError("app went away")


class RelayTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        patch = mock.patch.dict(os.environ, {"HOME": self._tmp.name})
        patch.start()
        self.addCleanup(patch.stop)
        from adsm import paths
        from adsm.daemon import Daemon

        paths.ensure_layout()
        self.daemon = Daemon()

    async def _subscribe_app(self) -> _Writer:
        app = _Writer()
        await self.daemon._subscribe({"relay": True}, app)
        return app

    async def test_no_app_means_no_route_and_says_so(self) -> None:
        # A normal state to be in at 3am: reported, never left to hang.
        answer = await self.daemon._archon_relay({"action": "agents"})
        self.assertFalse(answer["ok"])
        self.assertEqual("no_app", answer["error"])
        self.assertIn("cannot reach other hosts", answer["message"])

    async def test_a_relayed_call_reaches_the_app_and_comes_back(self) -> None:
        app = await self._subscribe_app()

        call = asyncio.create_task(
            self.daemon._archon_relay(
                {"action": "agents", "payload": {"scope": "all"}}
            )
        )
        await asyncio.sleep(0)

        asked = app.requests()
        self.assertEqual(1, len(asked))
        self.assertEqual("agents", asked[0]["action"])
        self.assertEqual({"scope": "all"}, asked[0]["payload"])

        await self.daemon._archon_reply(
            {"callId": asked[0]["callId"], "ok": True, "result": [{"title": "Build"}]}
        )
        answer = await call
        self.assertTrue(answer["ok"])
        self.assertEqual([{"title": "Build"}], answer["result"])

    async def test_an_unanswered_call_gives_up_instead_of_hanging(self) -> None:
        await self._subscribe_app()
        answer = await self.daemon._archon_relay(
            {"action": "agents", "timeout": 0.05}
        )
        self.assertFalse(answer["ok"])
        self.assertEqual("timeout", answer["error"])

    async def test_every_app_is_offered_the_call(self) -> None:
        # Apps reach different sets of hosts, so the one that can do it is the
        # one that answers, rather than one picked here blind.
        apps = [await self._subscribe_app() for _ in range(3)]
        call = asyncio.create_task(
            self.daemon._archon_relay({"action": "agents", "timeout": 0.2})
        )
        await asyncio.sleep(0)
        for app in apps:
            self.assertEqual(1, len(app.requests()))

        await self.daemon._archon_reply(
            {"callId": apps[1].requests()[0]["callId"], "ok": True, "result": 42}
        )
        self.assertEqual(42, (await call)["result"])

    async def test_a_second_answer_is_ignored_not_an_error(self) -> None:
        app = await self._subscribe_app()
        call = asyncio.create_task(
            self.daemon._archon_relay({"action": "agents", "timeout": 0.2})
        )
        await asyncio.sleep(0)
        call_id = app.requests()[0]["callId"]

        first = await self.daemon._archon_reply(
            {"callId": call_id, "ok": True, "result": "first"}
        )
        second = await self.daemon._archon_reply(
            {"callId": call_id, "ok": True, "result": "second"}
        )
        self.assertTrue(first["accepted"])
        self.assertFalse(second["accepted"])
        self.assertEqual("first", (await call)["result"])

    async def test_answering_a_call_that_never_existed_is_harmless(self) -> None:
        self.assertFalse(
            (await self.daemon._archon_reply({"callId": "nope"}))["accepted"]
        )

    async def test_an_app_that_died_is_dropped_and_reported(self) -> None:
        await self.daemon._subscribe({"relay": True}, _DeadWriter())
        answer = await self.daemon._archon_relay({"action": "agents"})
        self.assertFalse(answer["ok"])
        self.assertEqual("no_app", answer["error"])
        self.assertEqual(0, len(self.daemon._relay_subscribers))

    async def test_a_failure_from_the_app_is_passed_through(self) -> None:
        app = await self._subscribe_app()
        call = asyncio.create_task(
            self.daemon._archon_relay({"action": "prompt", "timeout": 0.2})
        )
        await asyncio.sleep(0)
        await self.daemon._archon_reply(
            {
                "callId": app.requests()[0]["callId"],
                "ok": False,
                "error": "unreachable",
                "message": "That host is not connected in this app.",
            }
        )
        answer = await call
        self.assertFalse(answer["ok"])
        self.assertEqual("unreachable", answer["error"])

    async def test_an_action_is_required(self) -> None:
        with self.assertRaises(ValueError):
            await self.daemon._archon_relay({})

    async def test_relay_subscribers_do_not_get_the_token_stream(self) -> None:
        # A relay app is not a chat subscriber; streaming every token to it
        # would be the expensive habit the digest subscription exists to avoid.
        app = await self._subscribe_app()
        await self.daemon._worker_emit(
            {"chatId": "c1", "kind": "text", "text": "hello"}
        )
        self.assertEqual([], app.lines)


if __name__ == "__main__":
    unittest.main()
