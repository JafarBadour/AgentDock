"""NDJSON request / response / event framing for ADSM."""

from __future__ import annotations

import base64
import json
from typing import Any, Mapping, Optional

# Bump when the wire protocol or daemon behaviour changes in a way the
# phone must pick up (install script restarts the daemon on mismatch).
VERSION = "0.4.2"

# asyncio StreamReader.readline default is 64 KiB. Prompts with images and
# transcript.sync payloads routinely exceed that and used to kill the client
# with LimitOverrunError — which looks like the agent "dying" mid-send.
STREAM_LIMIT = 16 * 1024 * 1024

# Phone splits oversized RPCs into `rpc.chunk` lines under this size so SSH /
# stdio bridges and older readers never see a giant single line.
CHUNK_SOFT_LIMIT = 48 * 1024
CHUNK_METHOD = "rpc.chunk"


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


def assemble_chunk_payload(parts: list[str], encoding: str = "base64") -> dict[str, Any]:
    """Join `rpc.chunk` data parts back into the original request object."""
    blob = "".join(parts)
    if encoding == "base64":
        raw = base64.b64decode(blob.encode("ascii"))
        text = raw.decode("utf-8")
    elif encoding in ("utf-8", "plain", ""):
        text = blob
    else:
        raise ValueError(f"unsupported rpc.chunk encoding: {encoding}")
    msg = decode_line(text)
    if msg is None:
        raise ValueError("empty reassembled rpc.chunk payload")
    return msg


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
