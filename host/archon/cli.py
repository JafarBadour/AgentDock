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


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="archon",
        description="What Archon can see on this host, and what it can do.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("agents", help="Every agent on this host")
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
