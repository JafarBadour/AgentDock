"""Host-side schedule persistence and ticker for ADSM."""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

from . import paths

DONE_YES_RE = re.compile(r"DONE\s*:\s*yes", re.IGNORECASE)
DONE_NO_RE = re.compile(r"DONE\s*:\s*no", re.IGNORECASE)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_dt(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        dt = value
    else:
        try:
            dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _fmt_dt(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    return dt.astimezone(timezone.utc).isoformat()


def list_jobs() -> list[dict[str, Any]]:
    paths.ensure_layout()
    out: list[dict[str, Any]] = []
    for p in sorted(paths.schedules_dir().glob("*.json")):
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(data, dict) and data.get("id"):
                out.append(data)
        except (OSError, json.JSONDecodeError):
            continue
    out.sort(key=lambda j: (j.get("number") or 0, str(j.get("id") or "")))
    return out


def load_job(job_id: str) -> Optional[dict[str, Any]]:
    p = paths.schedule_path(job_id)
    if not p.exists():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def save_job(job: dict[str, Any]) -> dict[str, Any]:
    paths.ensure_layout()
    job_id = str(job.get("id") or "").strip()
    if not job_id:
        raise ValueError("id required")
    job = dict(job)
    job["id"] = job_id
    job["updatedAt"] = _fmt_dt(_now())
    if not job.get("createdAt"):
        job["createdAt"] = job["updatedAt"]
    path = paths.schedule_path(job_id)
    path.write_text(json.dumps(job, indent=2, ensure_ascii=False), encoding="utf-8")
    return job


def delete_job(job_id: str) -> bool:
    path = paths.schedule_path(job_id)
    if path.exists():
        path.unlink(missing_ok=True)
        return True
    return False


def due_jobs(now: Optional[datetime] = None) -> list[dict[str, Any]]:
    now = now or _now()
    out: list[dict[str, Any]] = []
    for job in list_jobs():
        if not job.get("enabled", True):
            continue
        next_run = _parse_dt(job.get("nextRunAt"))
        if next_run is None:
            continue
        if next_run <= now:
            out.append(job)
    out.sort(key=lambda j: str(j.get("nextRunAt") or ""))
    return out


def compute_next_run(job: dict[str, Any], from_dt: datetime) -> Optional[datetime]:
    kind = str(job.get("kind") or "once")
    if kind == "once":
        return None
    if kind == "interval":
        mins = int(job.get("intervalMinutes") or 60)
        mins = max(1, min(mins, 60 * 24 * 30))
        return from_dt + timedelta(minutes=mins)
    if kind == "daily":
        h = int(job.get("hour") if job.get("hour") is not None else 9)
        m = int(job.get("minute") if job.get("minute") is not None else 0)
        local = from_dt.astimezone()
        next_local = local.replace(hour=h, minute=m, second=0, microsecond=0)
        if next_local <= local:
            next_local = next_local + timedelta(days=1)
        return next_local.astimezone(timezone.utc)
    if kind == "weekly":
        h = int(job.get("hour") if job.get("hour") is not None else 9)
        m = int(job.get("minute") if job.get("minute") is not None else 0)
        days = job.get("weekdays") or []
        if not isinstance(days, list) or not days:
            days = [from_dt.astimezone().isoweekday()]
        days_i = sorted({int(d) for d in days if 1 <= int(d) <= 7})
        local = from_dt.astimezone()
        for offset in range(0, 8):
            candidate = local + timedelta(days=offset)
            if candidate.isoweekday() not in days_i:
                continue
            next_local = candidate.replace(hour=h, minute=m, second=0, microsecond=0)
            if next_local > local:
                return next_local.astimezone(timezone.utc)
        return (local.replace(hour=h, minute=m, second=0, microsecond=0) + timedelta(days=7)).astimezone(
            timezone.utc
        )
    return None


def wrap_auto_prompt(number: int, prompt: str) -> str:
    return f"[Auto #{number}]\n{prompt}"


def build_run_prompt(job: dict[str, Any]) -> str:
    number = int(job.get("number") or 0)
    prompt = str(job.get("prompt") or "").strip()
    ctx = str(job.get("contextSummary") or "").strip()
    body = prompt
    if ctx:
        body = (
            "Prior compressed context for this automation:\n"
            "-----\n"
            f"{ctx}\n"
            "-----\n\n"
            f"{prompt}"
        )
    return wrap_auto_prompt(number, body)


def build_done_prompt(job: dict[str, Any]) -> str:
    criteria = str(job.get("donePrompt") or "").strip()
    return (
        "You are checking whether a scheduled automation is finished.\n"
        f"Done criteria:\n{criteria}\n\n"
        "Answer with the first word yes or no, then a short explanation.\n"
        "yes = the work is done — stop this automation.\n"
        "no = not done yet — keep the schedule running.\n"
        "Example: yes The deploy succeeded.\n"
        "Example: no Still waiting on CI.\n"
    )


def parse_done_answer(text: str) -> Optional[bool]:
    if not text:
        return None
    if DONE_YES_RE.search(text):
        return True
    if DONE_NO_RE.search(text):
        return False
    # Prefer an explicit first-word yes/no (suffix instruction above).
    first = text.strip().split(None, 1)[0].rstrip(".,:;!?")
    low = first.lower()
    if low == "yes":
        return True
    if low == "no":
        return False
    return None


def mark_finished(
    job: dict[str, Any],
    *,
    now: Optional[datetime] = None,
    error: Optional[str] = None,
    disable: bool = False,
    advance: bool = True,
) -> dict[str, Any]:
    now = now or _now()
    job = dict(job)
    job["lastRunAt"] = _fmt_dt(now)
    if error:
        job["lastError"] = error
    else:
        job["lastError"] = None
    if disable or str(job.get("kind") or "") == "once":
        job["enabled"] = False
        # Keep nextRunAt as last run for history.
        job["nextRunAt"] = _fmt_dt(now)
    elif advance:
        nxt = compute_next_run(job, now)
        if nxt is None:
            job["enabled"] = False
            job["nextRunAt"] = _fmt_dt(now)
        else:
            job["nextRunAt"] = _fmt_dt(nxt)
    return save_job(job)


class Scheduler:
    """Periodic tick that runs due jobs against daemon workers."""

    def __init__(self, daemon: Any) -> None:
        self._daemon = daemon
        self._task: Any = None
        self._in_flight: set[str] = set()

    def start(self) -> None:
        import asyncio

        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._loop(), name="adsm-scheduler")

    async def stop(self) -> None:
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except BaseException:  # noqa: BLE001
                pass
        self._task = None

    async def _loop(self) -> None:
        import asyncio

        while True:
            try:
                await self.tick()
            except Exception:  # noqa: BLE001
                pass
            await asyncio.sleep(30)

    async def tick(self) -> None:
        for job in due_jobs():
            job_id = str(job.get("id") or "")
            if not job_id or job_id in self._in_flight:
                continue
            self._in_flight.add(job_id)
            try:
                await self.run_job(job, force=False)
            finally:
                self._in_flight.discard(job_id)

    async def run_job(self, job: dict[str, Any], *, force: bool = False) -> dict[str, Any]:
        now = _now()
        job_id = str(job.get("id") or "")
        if not force:
            if not job.get("enabled", True):
                return job
            nxt = _parse_dt(job.get("nextRunAt"))
            if nxt is not None and nxt > now:
                return job

        chat_id = str(job.get("chatId") or "")
        if not chat_id:
            return mark_finished(job, now=now, error="Missing chatId", disable=True)

        prompt = str(job.get("prompt") or "").strip()
        if not prompt:
            return mark_finished(job, now=now, error="Empty prompt", disable=True)

        try:
            await self._ensure_worker(job)
            text = build_run_prompt(job)
            w = self._daemon.workers.get(chat_id)
            if not w:
                raise RuntimeError("worker missing after ensure")
            await w.prompt(text)
            assistant = getattr(w, "last_turn_text", "") or ""

            done_prompt = str(job.get("donePrompt") or "").strip()
            repeat_until_done = bool(job.get("repeatUntilDone"))
            if done_prompt and (repeat_until_done or str(job.get("kind") or "") != "once"):
                await w.prompt(build_done_prompt(job))
                verdict_text = getattr(w, "last_turn_text", "") or ""
                verdict = parse_done_answer(verdict_text)
                if verdict is True:
                    return mark_finished(job, now=now, disable=True)
                # no / unclear → keep repeating
                return mark_finished(job, now=now, advance=True)

            # Ignore unused assistant var for linters in once path.
            _ = assistant
            if str(job.get("kind") or "") == "once":
                return mark_finished(job, now=now, disable=True)
            return mark_finished(job, now=now, advance=True)
        except Exception as e:  # noqa: BLE001
            return mark_finished(job, now=now, error=str(e), advance=True)

    async def _ensure_worker(self, job: dict[str, Any]) -> None:
        chat_id = str(job.get("chatId") or "")
        cwd = str(job.get("cwd") or "")
        binary = str(job.get("binary") or "")
        if not cwd or not binary:
            # Fall back to agent record / live worker snapshot.
            w = self._daemon.workers.get(chat_id)
            if w and w.cwd and w.binary:
                cwd = cwd or w.cwd
                binary = binary or w.binary
            rec = paths.agent_record_path(chat_id)
            if rec.exists():
                try:
                    data = json.loads(rec.read_text(encoding="utf-8"))
                    cwd = cwd or str(data.get("cwd") or "")
                    binary = binary or str(data.get("binary") or "")
                except (OSError, json.JSONDecodeError):
                    pass
        if not cwd or not binary:
            raise RuntimeError(
                "Schedule is missing cwd/binary — open the chat once from the phone "
                "so ADSM can ensure the agent, then re-save the schedule."
            )
        await self._daemon._ensure(
            {
                "chatId": chat_id,
                "cwd": cwd,
                "binary": binary,
                "provider": job.get("provider") or "cursor",
                "apiKey": job.get("apiKey"),
                "fullAccess": bool(job.get("fullAccess", True)),
                "permissionAsk": bool(job.get("permissionAsk", False)),
                "resumeSessionId": job.get("resumeSessionId") or job.get("acpSessionId"),
                "mcpServers": job.get("mcpServers") or [],
                "mode": job.get("mode"),
                "modelId": job.get("modelId"),
            }
        )
