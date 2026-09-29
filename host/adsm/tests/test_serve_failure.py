"""A daemon whose server cannot start must exit, not linger as an orphan."""

from __future__ import annotations

import asyncio
import unittest
from unittest import mock

from adsm import daemon, transport


class ServeFailureTest(unittest.IsolatedAsyncioTestCase):
    async def test_serve_exits_when_the_server_fails_to_start(self) -> None:
        async def boom(_handler):
            raise AttributeError("no open_unix_server here")

        with mock.patch.object(transport, "start_server", boom):
            await asyncio.wait_for(daemon.run_serve(), timeout=10)


if __name__ == "__main__":
    unittest.main()
