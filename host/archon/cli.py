"""The `archon` command — how Archon acts.

Archon is an agent with a shell, so its tools are a command rather than an RPC
surface: it runs `archon agents`, reads JSON, and decides. Everything prints
JSON on stdout so nothing has to be parsed out of prose.

Scope: this reads the agent records on the host Archon runs on. Agents on
other hosts arrive through the app, not through here — so `agents` is "the
agents I can see from where I am", not "every agent that exists".
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Optional

from . import directory, paths, triggers
from .store import KIND_JOB, KIND_REMINDER, KIND_TIMER, ArchonStore, now_utc


def _print(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")



def relay(action: str, payload: Optional[dict[str, Any]] = None,
          *, timeout: float = 60.0) -> dict[str, Any]:
    """Ask a live app to reach another host on Archon's behalf.

    Archon has no credentials for the user's other hosts — those live in the
    app, which already holds a bridge to each host it can see. So the call
    goes Archon -> this host's daemon -> a live app -> the far host.

    With no app connected there is simply no route. That is a normal state to
    be in at 3am, and it comes back as an answer rather than an error.
    """
    import asyncio

    from adsm import protocol
    from adsm import paths as adsm_paths

    async def call() -> dict[str, Any]:
        reader, writer = await asyncio.open_unix_connection(
            path=str(adsm_paths.socket_path()), limit=protocol.STREAM_LIMIT
        )
        try:
            writer.write(
                protocol.encode(
                    {
                        "id": 1,
                        "method": "archon.relay",
                        "params": {
                            "action": action,
                            "payload": payload or {},
                            "timeout": timeout,
                        },
                    }
                )
            )
            await writer.drain()
            line = await asyncio.wait_for(reader.readline(), timeout + 10)
            message = protocol.decode_line(line.decode("utf-8", "replace"))
            return (message or {}).get("result") or {}
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:  # noqa: BLE001
                pass

    try:
        return asyncio.run(call())
    except FileNotFoundError:
        return {
            "ok": False,
            "error": "no_daemon",
            "message": "ADSM is not running on this host.",
        }
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": "relay_failed", "message": str(e)}


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="archon",
        description="What Archon can see on this host, and what it can do.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("agents", help="Every agent on this host")

    p_remote = sub.add_parser(
        "remote", help="Reach another host through a live app"
    )
    remote_sub = p_remote.add_subparsers(dest="remote_cmd", required=True)
    remote_sub.add_parser("agents", help="Agents on every host the app sees")
    remote_sub.add_parser("routes", help="Whether any app can route for me")
    p_rprompt = remote_sub.add_parser("prompt", help="Send an agent work")
    p_rprompt.add_argument("host_id")
    p_rprompt.add_argument("chat_id")
    p_rprompt.add_argument("text")
    sub.add_parser("goals", help="Agents switched on, with a goal, allowed")
    sub.add_parser("blocked", help="Switched on but set to Ask — off limits")

    p_done = sub.add_parser(
        "done", help="Goal met: switch the agent off and say why"
    )
    p_done.add_argument("chat_id")
    p_done.add_argument("note", help="What happened, in one or two sentences")

    p_remember = sub.add_parser("remember", help="Keep something worth keeping")
    p_remember.add_argument("scope", help="user, or chat:<id>, or host:<id>")
    p_remember.add_argument("body")

    p_recall = sub.add_parser("recall", help="What was kept under a scope")
    p_recall.add_argument("scope")
    p_recall.add_argument("--limit", type=int, default=50)

    p_sched = sub.add_parser("schedule", help="Wake later")
    p_sched.add_argument("label")
    p_sched.add_argument(
        "--in", dest="seconds", type=int, required=True, help="Seconds from now"
    )
    p_sched.add_argument("--repeat", type=int, help="Repeat every N seconds")
    p_sched.add_argument(
        "--kind",
        choices=[KIND_TIMER, KIND_REMINDER, KIND_JOB],
        default=KIND_TIMER,
    )

    sub.add_parser("due", help="What is due now")
    sub.add_parser("pending", help="Everything still scheduled")

    p_cancel = sub.add_parser("cancel", help="Drop a scheduled entry")
    p_cancel.add_argument("entry_id")

    args = parser.parse_args(argv)
    paths.ensure_layout()

    if args.cmd == "agents":
        _print(directory.describe(directory.load_records()))
        return 0

    if args.cmd == "remote":
        if args.remote_cmd == "routes":
            _print(relay("routes", timeout=10.0))
            return 0
        if args.remote_cmd == "agents":
            answer = relay("agents")
            _print(answer)
            return 0 if answer.get("ok") else 1
        if args.remote_cmd == "prompt":
            answer = relay(
                "prompt",
                {
                    "hostId": args.host_id,
                    "chatId": args.chat_id,
                    "text": args.text,
                },
            )
            _print(answer)
            return 0 if answer.get("ok") else 1
        return 1

    if args.cmd == "goals":
        _print(directory.describe(directory.manageable(directory.load_records())))
        return 0

    if args.cmd == "blocked":
        records = directory.blocked(directory.load_records())
        _print(
            [
                {
                    **entry,
                    "why": directory.refusal_for(record),
                }
                for entry, record in zip(directory.describe(records), records)
            ]
        )
        return 0

    if args.cmd == "done":
        updated = directory.complete(args.chat_id, args.note)
        if updated is None:
            print(f"no such agent: {args.chat_id}", file=sys.stderr)
            return 1
        _print(directory.describe([updated])[0])
        return 0

    store = ArchonStore()

    if args.cmd == "remember":
        entry = store.remember(args.scope, args.body)
        _print({"id": entry, "stored": entry is not None})
        return 0

    if args.cmd == "recall":
        _print(store.recall(args.scope, limit=args.limit))
        return 0

    if args.cmd == "schedule":
        from datetime import timedelta

        entry = store.schedule(
            label=args.label,
            due_at=now_utc() + timedelta(seconds=args.seconds),
            kind=args.kind,
            repeat_seconds=args.repeat,
        )
        _print({"id": entry})
        return 0

    if args.cmd == "due":
        _print(store.due())
        return 0

    if args.cmd == "pending":
        _print(
            {
                "entries": store.pending(),
                "nextWakeup": triggers.next_wakeup(store)[1].isoformat(),
            }
        )
        return 0

    if args.cmd == "cancel":
        _print({"cancelled": store.cancel(args.entry_id)})
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
