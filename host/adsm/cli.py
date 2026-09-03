"""CLI entrypoints: serve / client / status."""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path

from . import paths, protocol


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="agentdock-adsm")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("serve", help="Run the ADSM daemon (Unix socket)")
    sub.add_parser(
        "client", help="Stdio NDJSON proxy to the daemon socket (for SSH)"
    )
    sub.add_parser("status", help="Ping the daemon and print status")
    p_ensure = sub.add_parser("ensure-running", help="Start daemon if needed")
    p_ensure.add_argument(
        "--python",
        default=sys.executable,
        help="Python used to spawn the daemon",
    )

    args = parser.parse_args(argv)

    if args.cmd == "serve":
        from .daemon import run_serve

        asyncio.run(run_serve())
        return 0
    if args.cmd == "client":
        return asyncio.run(_client())
    if args.cmd == "status":
        return asyncio.run(_status())
    if args.cmd == "ensure-running":
        return _ensure_running(args.python)
    return 1


def _daemon_alive() -> bool:
    sock = paths.socket_path()
    if not sock.exists():
        return False
    try:
        return asyncio.run(_ping_ok())
    except Exception:  # noqa: BLE001
        return False


async def _ping_ok() -> bool:
    try:
        reader, writer = await asyncio.open_unix_connection(
            path=str(paths.socket_path()),
            limit=protocol.STREAM_LIMIT,
        )
    except Exception:  # noqa: BLE001
        return False
    try:
        writer.write(protocol.encode({"id": 1, "method": "ping", "params": {}}))
        await writer.drain()
        line = await asyncio.wait_for(reader.readline(), timeout=3.0)
        msg = protocol.decode_line(line.decode("utf-8", "replace"))
        return bool(msg and "result" in msg)
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:  # noqa: BLE001
            pass


def _ensure_running(python: str) -> int:
    paths.ensure_layout()
    if _daemon_alive():
        print("ADSM already running")
        return 0

    # Stale socket.
    sock = paths.socket_path()
    if sock.exists():
        try:
            sock.unlink()
        except OSError:
            pass

    # Locate package root (parent of adsm/).
    pkg_root = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    pp = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = (
        f"{pkg_root}{os.pathsep}{pp}" if pp else str(pkg_root)
    )

    import subprocess

    log = paths.log_path()
    cmd = [python, "-m", "adsm", "serve"]
    logf = open(log, "a", encoding="utf-8")
    subprocess.Popen(
        cmd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=logf,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        cwd=str(pkg_root),
    )

    for _ in range(40):
        if _daemon_alive():
            print("ADSM started")
            return 0
        import time

        time.sleep(0.1)
    print("ADSM failed to start — see", log, file=sys.stderr)
    return 1


async def _status() -> int:
    if not paths.socket_path().exists():
        print("ADSM not running (no socket)")
        return 1
    try:
        reader, writer = await asyncio.open_unix_connection(
            path=str(paths.socket_path()),
            limit=protocol.STREAM_LIMIT,
        )
    except Exception as e:  # noqa: BLE001
        print(f"ADSM unreachable: {e}")
        return 1
    writer.write(
        protocol.encode({"id": 1, "method": "daemon.status", "params": {}})
    )
    await writer.drain()
    line = await reader.readline()
    print(line.decode("utf-8", "replace").rstrip())
    writer.close()
    await writer.wait_closed()
    return 0


async def _client() -> int:
    """Bridge stdio ↔ Unix socket (one long-lived SSH channel)."""
    paths.ensure_layout()
    sock = paths.socket_path()
    if not sock.exists():
        # Best-effort auto-start.
        _ensure_running(sys.executable)
    try:
        reader, writer = await asyncio.open_unix_connection(
            path=str(sock),
            limit=protocol.STREAM_LIMIT,
        )
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"ADSM connect failed: {e}\n")
        return 1

    async def stdin_to_sock() -> None:
        loop = asyncio.get_running_loop()
        while True:
            line = await loop.run_in_executor(None, sys.stdin.buffer.readline)
            if not line:
                break
            writer.write(line)
            await writer.drain()
        writer.close()

    async def sock_to_stdout() -> None:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()

    t1 = asyncio.create_task(stdin_to_sock())
    t2 = asyncio.create_task(sock_to_stdout())
    done, pending = await asyncio.wait(
        {t1, t2}, return_when=asyncio.FIRST_COMPLETED
    )
    for t in pending:
        t.cancel()
    try:
        writer.close()
        await writer.wait_closed()
    except Exception:  # noqa: BLE001
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
