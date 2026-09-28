"""Daemon control-plane endpoint: Unix socket on POSIX, loopback TCP on Windows.

Windows Python has no `asyncio` Unix sockets, so there the daemon listens on
127.0.0.1 with an ephemeral port and writes `{port, token}` to
`~/.agentdock/adsm.endpoint`. Any local user can reach a loopback port, so a
client must send the token as its first line before the daemon answers.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import secrets
import sys
from typing import Awaitable, Callable

from . import paths, protocol

IS_WINDOWS = sys.platform == "win32"

ClientHandler = Callable[
    [asyncio.StreamReader, asyncio.StreamWriter], Awaitable[None]
]

_AUTH_TIMEOUT_S = 5.0


def endpoint_exists() -> bool:
    return endpoint_path().exists()


def endpoint_path():
    return paths.endpoint_path() if IS_WINDOWS else paths.socket_path()


def remove_endpoint() -> None:
    try:
        endpoint_path().unlink(missing_ok=True)
    except OSError:
        pass


async def start_server(handler: ClientHandler) -> asyncio.AbstractServer:
    """Listen for clients; [handler] only sees authenticated connections."""
    remove_endpoint()
    if not IS_WINDOWS:
        sock = paths.socket_path()
        server = await asyncio.start_unix_server(
            handler, path=str(sock), limit=protocol.STREAM_LIMIT
        )
        try:
            os.chmod(sock, 0o600)
        except OSError:
            pass
        return server

    token = secrets.token_hex(32)

    async def authed(
        reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            line = await asyncio.wait_for(reader.readline(), _AUTH_TIMEOUT_S)
            msg = json.loads(line.decode("utf-8", "replace") or "{}")
            given = str(msg.get("auth") or "") if isinstance(msg, dict) else ""
        except Exception:  # noqa: BLE001
            given = ""
        if not hmac.compare_digest(given, token):
            writer.close()
            return
        await handler(reader, writer)

    server = await asyncio.start_server(
        authed, host="127.0.0.1", port=0, limit=protocol.STREAM_LIMIT
    )
    port = server.sockets[0].getsockname()[1]
    tmp = paths.endpoint_path().with_suffix(".tmp")
    tmp.write_text(json.dumps({"port": port, "token": token}), encoding="utf-8")
    os.replace(tmp, paths.endpoint_path())
    return server


async def open_connection() -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    """Connect to the running daemon (raises if it is not reachable)."""
    if not IS_WINDOWS:
        return await asyncio.open_unix_connection(
            path=str(paths.socket_path()), limit=protocol.STREAM_LIMIT
        )
    info = json.loads(paths.endpoint_path().read_text(encoding="utf-8"))
    reader, writer = await asyncio.open_connection(
        "127.0.0.1", int(info["port"]), limit=protocol.STREAM_LIMIT
    )
    writer.write(protocol.encode({"auth": str(info["token"])}))
    await writer.drain()
    return reader, writer
