"""NDJSON request / response / event framing for ADSM."""

from __future__ import annotations

import json
from typing import Any, Mapping, Optional


def encode(obj: Mapping[str, Any]) -> bytes:
    return (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def decode_line(line: str) -> Optional[dict[str, Any]]:
    line = line.strip()
    if not line:
        return None
    data = json.loads(line)
    if not isinstance(data, dict):
        raise ValueError("ADSM message must be a JSON object")
    return data


def ok(req_id: Any, result: Any = None) -> dict[str, Any]:
    return {"id": req_id, "result": result if result is not None else {}}


def err(req_id: Any, code: int, message: str, data: Any = None) -> dict[str, Any]:
    body: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        body["data"] = data
    return {"id": req_id, "error": body}


def event(chat_id: str, seq: int, kind: str, **payload: Any) -> dict[str, Any]:
    params: dict[str, Any] = {"chatId": chat_id, "seq": seq, "kind": kind}
    params.update(payload)
    return {"method": "event", "params": params}


# Agent status values (authoritative on the host).
STATUS_STARTING = "starting"
STATUS_IDLE = "idle"
STATUS_RUNNING = "running"
STATUS_WAITING_PERMISSION = "waiting_permission"
STATUS_DEAD = "dead"
STATUS_ERROR = "error"
