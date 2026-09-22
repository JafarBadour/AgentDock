#!/usr/bin/env python3
"""Create ACP sessions locally and verify model switching RPCs.

Usage:
  python3 tool/probe_acp_models.py cursor
  python3 tool/probe_acp_models.py claude
  python3 tool/probe_acp_models.py codex
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from typing import Any, Optional


def _which_agent(kind: str) -> list[str]:
    if kind == "cursor":
        for name in ("agent", "cursor-agent"):
            path = shutil.which(name)
            if path:
                return [path, "acp"]
        raise SystemExit("agent/cursor-agent not found on PATH")
    if kind == "codex":
        bin_path = shutil.which("codex-acp")
        if not bin_path:
            raise SystemExit(
                "codex-acp not found on PATH (npm i -g @agentclientprotocol/codex-acp)"
            )
        return [bin_path]
    # Prefer a modern Node for claude-agent-acp.
    bin_path = shutil.which("claude-agent-acp") or shutil.which("claude-code-acp")
    if not bin_path:
        raise SystemExit("claude-agent-acp not found on PATH")
    return [bin_path]


def probe(kind: str) -> None:
    cmd = _which_agent(kind)
    env = os.environ.copy()
    print(f"== {kind} via {cmd} ==")
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    out_q: queue.Queue[str] = queue.Queue()
    err_q: queue.Queue[str] = queue.Queue()
    threading.Thread(
        target=lambda: [out_q.put(line) for line in proc.stdout], daemon=True
    ).start()
    threading.Thread(
        target=lambda: [err_q.put(line) for line in proc.stderr], daemon=True
    ).start()

    def req(req_id: int, method: str, params: dict[str, Any], timeout: float = 30.0) -> dict[str, Any]:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}) + "\n")
        proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                line = out_q.get(timeout=0.4)
            except queue.Empty:
                while not err_q.empty():
                    err = err_q.get_nowait().strip()
                    if err:
                        print(f"  stderr: {err[:200]}")
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == req_id:
                return msg
        raise TimeoutError(method)

    try:
        init = req(
            1,
            "initialize",
            {
                "protocolVersion": 1,
                "clientInfo": {"name": "agentdock-probe", "version": "0"},
                "capabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
            },
        )
        if "error" in init:
            raise RuntimeError(init["error"])
        assert proc.stdin is not None
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}) + "\n")
        proc.stdin.flush()

        created = req(2, "session/new", {"cwd": "/tmp", "mcpServers": []}, timeout=60.0)
        if "error" in created:
            raise RuntimeError(created["error"])
        result = created.get("result") or {}
        sid = result.get("sessionId")
        models = result.get("models") or {}
        configs = result.get("configOptions") or result.get("config_options") or []
        print(f"  sessionId={sid}")
        print(f"  models.current={ (models or {}).get('currentModelId') }")
        print(f"  configOptions={len(configs) if isinstance(configs, list) else 0}")

        target: Optional[str] = None
        current: Optional[str] = None
        if isinstance(models, dict):
            current = models.get("currentModelId") or models.get("current_model_id")
            for item in models.get("availableModels") or models.get("available_models") or []:
                if isinstance(item, dict):
                    mid = item.get("modelId")
                    if mid and mid != current:
                        target = str(mid)
                        break
        if target is None and isinstance(configs, list):
            for entry in configs:
                if not isinstance(entry, dict):
                    continue
                cid = entry.get("id") or entry.get("configId")
                if cid != "model" and entry.get("category") != "model":
                    continue
                current = entry.get("currentValue")
                for raw in entry.get("options") or []:
                    group = raw.get("options") if isinstance(raw, dict) else None
                    options = group if isinstance(group, list) else [raw]
                    for opt in options:
                        if isinstance(opt, dict) and opt.get("value") and opt.get("value") != current:
                            target = str(opt["value"])
                            break
                    if target:
                        break
        print(f"  switch {current!r} -> {target!r}")
        if not sid or not target:
            print("  SKIP: no alternate model")
            return

        for label, method, params in [
            (
                "set_config_option",
                "session/set_config_option",
                {"sessionId": sid, "configId": "model", "type": "id", "value": target},
            ),
            (
                "set_model",
                "session/set_model",
                {"sessionId": sid, "modelId": target},
            ),
        ]:
            resp = req(10 + len(label), method, params, timeout=20.0)
            if "error" in resp:
                err = resp["error"]
                print(f"  {label}: FAIL {err.get('code')} {err.get('message')}")
            else:
                print(f"  {label}: OK")
    finally:
        proc.kill()


if __name__ == "__main__":
    kinds = sys.argv[1:] or ["cursor", "claude"]
    for kind in kinds:
        probe(kind)
