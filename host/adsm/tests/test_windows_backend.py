"""Windows transport and agent-process backend (skipped elsewhere)."""

from __future__ import annotations

import asyncio
import json
import sys
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from adsm import paths, protocol, transport, winproc


@unittest.skipUnless(sys.platform == "win32", "Windows backend")
class TransportAuthTest(unittest.IsolatedAsyncioTestCase):
    async def test_only_token_holders_reach_the_handler(self) -> None:
        paths.ensure_layout()

        async def echo(reader, writer):
            writer.write(await reader.readline())
            await writer.drain()
            writer.close()

        server = await transport.start_server(echo)
        try:
            reader, writer = await transport.open_connection()
            writer.write(protocol.encode({"id": 1}))
            await writer.drain()
            self.assertEqual(json.loads(await reader.readline()), {"id": 1})
            writer.close()

            port = json.loads(paths.endpoint_path().read_text())["port"]
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(protocol.encode({"auth": "wrong"}))
            writer.write(protocol.encode({"id": 2}))
            await writer.drain()
            self.assertEqual(await reader.read(), b"")
            writer.close()
        finally:
            server.close()
            transport.remove_endpoint()


@unittest.skipUnless(sys.platform == "win32", "Windows backend")
class WinprocTest(unittest.TestCase):
    def test_resolves_npm_style_cmd_shim_without_extension(self) -> None:
        with TemporaryDirectory() as tmp:
            shim = Path(tmp) / "claude-agent-acp.cmd"
            shim.write_text("@echo off\r\n", encoding="utf-8")
            self.assertEqual(
                winproc.resolve_binary(str(Path(tmp) / "claude-agent-acp"), ""),
                str(shim),
            )
            self.assertEqual(
                Path(winproc.resolve_binary("claude-agent-acp", tmp)).name.lower(),
                "claude-agent-acp.cmd",
            )
            with self.assertRaises(RuntimeError):
                winproc.resolve_binary("no-such-agent", tmp)

    def test_agent_stdin_to_journal_round_trip(self) -> None:
        with TemporaryDirectory() as tmp:
            echo = Path(tmp) / "echo.py"
            echo.write_text(
                "import os, sys\n"
                "for line in sys.stdin:\n"
                "    print(os.environ['ADSM_TEST'] + ':' + line.strip(), flush=True)\n",
                encoding="utf-8",
            )
            args = dict(
                chat_id="win-echo",
                cwd=tmp,
                binary=sys.executable,
                argv=[str(echo)],
                env={"ADSM_TEST": "ok"},
                full_access=True,
                model_id=None,
            )
            try:
                state, _ = winproc.ensure_worker(**args)
                self.assertEqual(state, "STARTED")
                self.assertTrue(winproc.alive("win-echo"))
                self.assertEqual(winproc.ensure_worker(**args)[0], "RUNNING")

                winproc.write("win-echo", b"hello\n")
                journal = paths.session_dir("win-echo") / "out.jsonl"
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if "ok:hello" in journal.read_text(encoding="utf-8"):
                        break
                    time.sleep(0.05)
                self.assertIn("ok:hello", journal.read_text(encoding="utf-8"))

                # A permission change restarts the process.
                self.assertEqual(
                    winproc.ensure_worker(**{**args, "full_access": False})[0],
                    "RESTARTED",
                )
            finally:
                winproc.kill("win-echo")
            self.assertFalse(winproc.alive("win-echo"))


if __name__ == "__main__":
    unittest.main()
