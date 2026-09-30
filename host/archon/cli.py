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



def daemon_call(
    method: str, params: dict[str, Any], *, timeout: float = 60.0
) -> dict[str, Any]:
    """One request to the ADSM daemon on this host."""
    import asyncio

    from adsm import paths as adsm_paths
    from adsm import protocol

    async def call() -> dict[str, Any]:
        reader, writer = await asyncio.open_unix_connection(
            path=str(adsm_paths.socket_path()), limit=protocol.STREAM_LIMIT
        )
        try:
            writer.write(
                protocol.encode({"id": 1, "method": method, "params": params})
            )
            await writer.drain()
            line = await asyncio.wait_for(reader.readline(), timeout + 10)
            message = protocol.decode_line(line.decode("utf-8", "replace")) or {}
            if "error" in message:
                return {
                    "ok": False,
                    "error": "daemon_error",
                    "message": str(message["error"].get("message")),
                }
            return {"ok": True, "result": message.get("result")}
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
        return {"ok": False, "error": "call_failed", "message": str(e)}


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


# Detail the running command attaches to its own log row.
_DETAIL: dict[str, Any] = {}


def _detail(*, target: Optional[str] = None, summary: Optional[str] = None) -> None:
    if target is not None:
        _DETAIL["target"] = target
    if summary is not None:
        _DETAIL["summary"] = summary


# Reading is not doing. These answer questions Archon asks itself on every
# wake, and logging them would bury the things it actually did.
_QUIET = frozenset({"log", "agents", "goals", "blocked", "recall", "due",
                    "pending", "remote routes", "remote agents"})


def main(argv: Optional[list[str]] = None) -> int:
    """Run one command, and write down that it ran.

    Recorded here rather than inside each command so there is no way to act
    without it being visible: a manager working while nobody watches is only
    acceptable if the user can see afterwards exactly what it did.
    """
    _DETAIL.clear()
    code = _run(argv)
    argv_list = list(argv if argv is not None else sys.argv[1:])
    if not argv_list:
        return code
    # `remote agents` reads better than `remote`; everything else is one word.
    command = (
        f"{argv_list[0]} {argv_list[1]}"
        if argv_list[0] == "remote" and len(argv_list) > 1
        else argv_list[0]
    )
    if argv_list[0] not in _QUIET and command not in _QUIET:
        try:
            paths.ensure_layout()
            ArchonStore().record_action(
                command,
                target=_DETAIL.get("target"),
                summary=_DETAIL.get("summary"),
                ok=code == 0,
            )
        except Exception:  # noqa: BLE001
            # Never let bookkeeping turn a working command into a failure.
            pass
    return code


def _run(argv: Optional[list[str]] = None) -> int:
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
    p_prompt = sub.add_parser("prompt", help="Give an agent on this host work")
    p_prompt.add_argument("chat_id")
    p_prompt.add_argument("text")

    p_read = sub.add_parser("read", help="An agent's recent transcript")
    p_read.add_argument("chat_id")
    p_read.add_argument("--tail", type=int, default=20)

    p_status = sub.add_parser("status", help="What an agent is doing now")
    p_status.add_argument("chat_id")

    p_stop = sub.add_parser("stop", help="Stop an agent's current turn")
    p_stop.add_argument("chat_id")

    p_log = sub.add_parser("log", help="What I have been doing")
    p_log.add_argument("--limit", type=int, default=50)

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
            _detail(
                target=f"{args.host_id}/{args.chat_id}",
                summary=args.text[:200],
            )
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
        _detail(target=args.chat_id, summary=args.note[:200])
        updated = directory.complete(args.chat_id, args.note)
        if updated is None:
            print(f"no such agent: {args.chat_id}", file=sys.stderr)
            return 1
        _print(directory.describe([updated])[0])
        return 0

    store = ArchonStore()

    def guarded(chat_id: str) -> Optional[dict[str, Any]]:
        """Refuse an agent the user did not put on Allow all."""
        records = {r["id"]: r for r in directory.load_records()}
        record = records.get(chat_id)
        if record is None:
            return {"ok": False, "error": "no_agent",
                    "message": f"No agent {chat_id} on this host."}
        if not directory.is_commandable(record):
            return {"ok": False, "error": "not_permitted",
                    "message": directory.refusal_for(record)}
        return None

    if args.cmd == "prompt":
        refusal = guarded(args.chat_id)
        if refusal is not None:
            _detail(target=args.chat_id, summary=refusal["message"])
            _print(refusal)
            return 1
        answer = daemon_call(
            "session.prompt",
            {"chatId": args.chat_id,
             "blocks": [{"type": "text", "text": args.text}]},
        )
        _detail(target=args.chat_id, summary=args.text[:200])
        _print(answer)
        return 0 if answer.get("ok") else 1

    if args.cmd == "read":
        answer = daemon_call(
            "transcript.pull", {"chatId": args.chat_id, "limit": args.tail}
        )
        _detail(target=args.chat_id, summary=f"last {args.tail}")
        _print(answer)
        return 0 if answer.get("ok") else 1

    if args.cmd == "status":
        answer = daemon_call("agents.list", {})
        _detail(target=args.chat_id)
        _print(answer)
        return 0 if answer.get("ok") else 1

    if args.cmd == "stop":
        refusal = guarded(args.chat_id)
        if refusal is not None:
            _detail(target=args.chat_id, summary=refusal["message"])
            _print(refusal)
            return 1
        answer = daemon_call("session.cancel", {"chatId": args.chat_id})
        _detail(target=args.chat_id)
        _print(answer)
        return 0 if answer.get("ok") else 1

    if args.cmd == "log":
        _print(store.actions(limit=args.limit))
        return 0

    if args.cmd == "remember":
        _detail(target=args.scope, summary=args.body[:200])
        entry = store.remember(args.scope, args.body)
        _print({"id": entry, "stored": entry is not None})
        return 0

    if args.cmd == "recall":
        _print(store.recall(args.scope, limit=args.limit))
        return 0

    if args.cmd == "schedule":
        _detail(target=args.label, summary=f"in {args.seconds}s")
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
        _detail(target=args.entry_id)
        _print({"cancelled": store.cancel(args.entry_id)})
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
