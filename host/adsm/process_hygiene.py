"""Keep ACP worker process trees from bloating host RAM.

Claude ACP has been observed to leave multiple `claude` SDK child processes
alive under one `claude-agent-acp` parent after session/new or resume cycles.
Each child is typically 200–300 MB RSS — a handful looks like “ADSM used 1 GB”.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Optional


# Journals grow with every ACP stream line. Cap disk + future tail memory.
JOURNAL_MAX_BYTES = 8 * 1024 * 1024
JOURNAL_KEEP_BYTES = 2 * 1024 * 1024


def tmux_pane_pid(tmux_session: str) -> Optional[int]:
    try:
        r = subprocess.run(
            ["tmux", "list-panes", "-t", tmux_session, "-F", "#{pane_pid}"],
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.isdigit():
            return int(line)
    return None


def _cmdline(pid: int) -> str:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", "replace")


def _start_time(pid: int) -> float:
    try:
        # field 22 (1-based) of /proc/pid/stat is starttime in clock ticks
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        # comm can contain spaces/parens — split after last ')'
        rest = stat.rsplit(")", 1)[-1].strip().split()
        return float(rest[19]) if len(rest) > 19 else float(pid)
    except (OSError, IndexError, ValueError):
        return float(pid)


def _children(pid: int) -> list[int]:
    out: list[int] = []
    try:
        for ent in Path("/proc").iterdir():
            if not ent.name.isdigit():
                continue
            child = int(ent.name)
            try:
                status = (ent / "status").read_text(encoding="utf-8")
            except OSError:
                continue
            for line in status.splitlines():
                if line.startswith("PPid:"):
                    try:
                        ppid = int(line.split()[1])
                    except (IndexError, ValueError):
                        break
                    if ppid == pid:
                        out.append(child)
                    break
    except OSError:
        pass
    return out


def _descendants(root: int) -> list[int]:
    found: list[int] = []
    stack = [root]
    seen = {root}
    while stack:
        pid = stack.pop()
        for child in _children(pid):
            if child in seen:
                continue
            seen.add(child)
            found.append(child)
            stack.append(child)
    return found


def _is_claude_sdk(cmdline: str) -> bool:
    c = cmdline.lower()
    return "claude-agent-sdk" in c or (
        "/claude" in c and "stream-json" in c
    )


def list_claude_sdk_pids(acp_pid: int) -> list[tuple[int, float]]:
    """Return (pid, start_time) for Claude SDK processes under [acp_pid]."""
    rows: list[tuple[int, float]] = []
    for pid in _descendants(acp_pid):
        cmd = _cmdline(pid)
        if _is_claude_sdk(cmd):
            rows.append((pid, _start_time(pid)))
    rows.sort(key=lambda r: r[1])
    return rows


def reap_extra_claude_children(acp_pid: int) -> int:
    """Keep the newest Claude SDK child; SIGTERM the rest. Returns killed count."""
    rows = list_claude_sdk_pids(acp_pid)
    if len(rows) <= 1:
        return 0
    keep = rows[-1][0]
    killed = 0
    for pid, _ in rows[:-1]:
        if pid == keep:
            continue
        try:
            os.kill(pid, signal.SIGTERM)
            killed += 1
        except OSError:
            pass
    if killed:
        # Brief grace, then SIGKILL leftovers.
        time.sleep(0.4)
        for pid, _ in rows[:-1]:
            try:
                os.kill(pid, 0)
            except OSError:
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    return killed


def reap_claude_children_for_tmux(tmux_session: str) -> int:
    pane = tmux_pane_pid(tmux_session)
    if pane is None:
        return 0
    return reap_extra_claude_children(pane)


def trim_journal_file(
    path: Path,
    *,
    max_bytes: int = JOURNAL_MAX_BYTES,
    keep_bytes: int = JOURNAL_KEEP_BYTES,
) -> bool:
    """If journal exceeds [max_bytes], keep only the trailing [keep_bytes]."""
    try:
        size = path.stat().st_size
    except OSError:
        return False
    if size <= max_bytes:
        return False
    try:
        with path.open("rb") as fh:
            fh.seek(max(0, size - keep_bytes))
            # Align to next newline so we don't leave a torn JSON line.
            fh.readline()
            data = fh.read()
        path.write_bytes(data)
        return True
    except OSError:
        return False
