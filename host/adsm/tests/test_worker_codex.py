"""Worker launch / mode / model behaviour per provider, with Codex in focus.

Codex runs through `@agentclientprotocol/codex-acp`: a bare stdio ACP binary
whose models come from `configOptions` (model × reasoning effort), whose
modes are approval presets (`read-only` / `agent` / `agent-full-access`) and
whose plan mode is a separate `collaboration_mode` option.
"""

from __future__ import annotations

import asyncio
import unittest

from adsm.worker import (
    Worker,
    _env_file,
    _run_script,
    codex_current_model_from_config_options,
    codex_models_from_config_options,
    split_codex_model_id,
)


CODEX_CONFIG_OPTIONS = [
    {
        "id": "mode",
        "category": "mode",
        "type": "select",
        "currentValue": "agent",
        "options": [
            {"value": "read-only", "name": "Ask for approval"},
            {"value": "agent", "name": "Approve for me"},
            {"value": "agent-full-access", "name": "Full access"},
        ],
    },
    {
        "id": "collaboration_mode",
        "category": "collaboration_mode",
        "type": "select",
        "currentValue": "default",
        "options": [{"value": "default", "name": "Default"}, {"value": "plan", "name": "Plan"}],
    },
    {
        "id": "model",
        "category": "model",
        "type": "select",
        "currentValue": "gpt-6-astra",
        "options": [
            {"value": "gpt-6-astra", "name": "6 Astra"},
            {"value": "gpt-5.6-sol", "name": "5.6 Sol"},
        ],
    },
    {
        "id": "reasoning_effort",
        "category": "thought_level",
        "type": "select",
        "currentValue": "medium",
        "options": [
            {"value": "low", "name": "Low"},
            {"value": "medium", "name": "Medium"},
            {"value": "high", "name": "High"},
        ],
    },
    {
        "id": "fast-mode",
        "category": "model_config",
        "type": "select",
        "currentValue": "off",
        "options": [{"value": "off"}, {"value": "on"}],
    },
]

CODEX_MODES = {
    "currentModeId": "agent",
    "availableModes": [
        {"id": "read-only", "name": "Ask for approval"},
        {"id": "agent", "name": "Approve for me"},
        {"id": "agent-full-access", "name": "Full access"},
    ],
}


def _worker(provider: str, *, full_access: bool = True) -> Worker:
    async def _emit(_payload: dict) -> None:
        return None

    async def _set_status(_cid: str, _st: str, _err: str | None) -> None:
        return None

    w = Worker(f"chat-{provider}", emit=_emit, set_status=_set_status)
    w.provider = provider
    w.full_access = full_access
    return w


class RunScriptTest(unittest.TestCase):
    def test_codex_execs_bare_binary(self) -> None:
        script = _run_script(
            dir_path="/d",
            cwd="/proj",
            binary="/home/u/.local/bin/codex-acp",
            provider="codex",
            full_access=True,
            model_id="gpt-6-astra[effort=high]",
        )
        self.assertIn("exec /home/u/.local/bin/codex-acp\n", script)
        self.assertNotIn("--model", script)
        self.assertNotIn(" acp", script)
        self.assertNotIn("CLAUDE_ACP_SKIP_PERMISSIONS", script)

    def test_cursor_keeps_startup_flags(self) -> None:
        script = _run_script(
            dir_path="/d",
            cwd="/proj",
            binary="/usr/bin/cursor-agent",
            provider="cursor",
            full_access=True,
            model_id="auto",
        )
        self.assertIn("--model auto --force --approve-mcps --trust acp", script)

    def test_claude_uses_env_for_permissions(self) -> None:
        script = _run_script(
            dir_path="/d",
            cwd="/proj",
            binary="/usr/bin/claude-code-acp",
            provider="claude",
            full_access=True,
        )
        self.assertIn("export CLAUDE_ACP_SKIP_PERMISSIONS=true", script)
        self.assertIn("exec /usr/bin/claude-code-acp\n", script)


class EnvFileTest(unittest.TestCase):
    def test_codex_exports_openai_key_only(self) -> None:
        body = _env_file("codex", "sk-test", "gpt-6-astra[effort=low]")
        assert body is not None
        self.assertIn("OPENAI_API_KEY=sk-test", body)
        self.assertIn("export OPENAI_API_KEY", body)
        self.assertNotIn("CLAUDE_ACP_MODEL", body)
        self.assertNotIn("CURSOR_API_KEY", body)

    def test_codex_without_key_writes_nothing(self) -> None:
        self.assertIsNone(_env_file("codex", None, "gpt-6-astra"))

    def test_other_providers_unchanged(self) -> None:
        self.assertIn("ANTHROPIC_API_KEY", _env_file("claude", "k") or "")
        self.assertIn("CURSOR_API_KEY", _env_file("cursor", "k") or "")


class CodexModelCatalogueTest(unittest.TestCase):
    def test_cross_product_of_model_and_effort(self) -> None:
        models = codex_models_from_config_options(CODEX_CONFIG_OPTIONS)
        ids = [m["modelId"] for m in models]
        self.assertEqual(
            ids,
            [
                "gpt-6-astra[effort=low]",
                "gpt-6-astra[effort=medium]",
                "gpt-6-astra[effort=high]",
                "gpt-5.6-sol[effort=low]",
                "gpt-5.6-sol[effort=medium]",
                "gpt-5.6-sol[effort=high]",
            ],
        )
        self.assertEqual(models[0]["name"], "6 Astra")

    def test_current_model_carries_effort(self) -> None:
        self.assertEqual(
            codex_current_model_from_config_options(CODEX_CONFIG_OPTIONS),
            "gpt-6-astra[effort=medium]",
        )

    def test_no_effort_option_falls_back_to_plain_list(self) -> None:
        opts = [o for o in CODEX_CONFIG_OPTIONS if o["id"] != "reasoning_effort"]
        ids = [m["modelId"] for m in codex_models_from_config_options(opts)]
        self.assertEqual(ids, ["gpt-6-astra", "gpt-5.6-sol"])
        self.assertEqual(codex_current_model_from_config_options(opts), "gpt-6-astra")

    def test_split_model_id(self) -> None:
        self.assertEqual(split_codex_model_id("gpt-6-astra[effort=high]"), ("gpt-6-astra", "high"))
        self.assertEqual(split_codex_model_id("gpt-6-astra"), ("gpt-6-astra", None))
        self.assertEqual(split_codex_model_id("gpt-6-astra[high]"), ("gpt-6-astra", None))

    def test_worker_applies_codex_catalogue_over_native_models(self) -> None:
        w = _worker("codex")
        # codex-acp also returns a legacy `models` block; configOptions win.
        w._apply_models(
            {
                "currentModelId": "gpt-6-astra[medium]",
                "availableModels": [{"modelId": "gpt-6-astra[medium]", "name": "6 Astra (medium)"}],
            }
        )
        w._apply_config_options(CODEX_CONFIG_OPTIONS)
        self.assertEqual(w.model_id, "gpt-6-astra[effort=medium]")
        self.assertEqual(len(w.available_models), 6)
        self.assertTrue(w._models_via_config_option)
        self.assertIn("collaboration_mode", w._config_option_ids)
        self.assertFalse(w._codex_plan)


class CodexModeMappingTest(unittest.TestCase):
    def test_agent_maps_to_full_access_when_allowed(self) -> None:
        w = _worker("codex", full_access=True)
        w._apply_modes(CODEX_MODES)
        self.assertEqual(w._resolve_mode_id("agent"), "agent-full-access")

    def test_agent_maps_to_agent_when_asking(self) -> None:
        w = _worker("codex", full_access=False)
        w._apply_modes(CODEX_MODES)
        self.assertEqual(w._resolve_mode_id("agent"), "agent")

    def test_ask_and_plan_map_to_read_only(self) -> None:
        w = _worker("codex")
        w._apply_modes(CODEX_MODES)
        self.assertEqual(w._resolve_mode_id("ask"), "read-only")
        self.assertEqual(w._resolve_mode_id("plan"), "read-only")

    def test_legacy_adapter_ids_still_resolve(self) -> None:
        w = _worker("codex", full_access=True)
        w._apply_modes(
            {
                "currentModeId": "read-only",
                "availableModes": [{"id": "read-only"}, {"id": "auto"}, {"id": "full-access"}],
            }
        )
        self.assertEqual(w._resolve_mode_id("agent"), "full-access")
        w.full_access = False
        self.assertEqual(w._resolve_mode_id("agent"), "auto")

    def test_native_ids_report_back_as_app_modes(self) -> None:
        w = _worker("codex")
        self.assertEqual(w._app_mode_id("read-only"), "ask")
        self.assertEqual(w._app_mode_id("agent-full-access"), "agent")
        self.assertEqual(w._app_mode_id("agent"), "agent")
        w._codex_plan = True
        self.assertEqual(w._app_mode_id("read-only"), "plan")

    def test_claude_native_ids_report_back(self) -> None:
        w = _worker("claude")
        self.assertEqual(w._app_mode_id("dontAsk"), "ask")
        self.assertEqual(w._app_mode_id("bypassPermissions"), "agent")
        self.assertEqual(w._app_mode_id("plan"), "plan")

    def test_cursor_ids_pass_through(self) -> None:
        w = _worker("cursor")
        w._apply_modes({"availableModes": [{"id": "ask"}, {"id": "agent"}, {"id": "plan"}]})
        self.assertEqual(w._resolve_mode_id("plan"), "plan")
        self.assertEqual(w._app_mode_id("plan"), "plan")

    def test_set_mode_plan_sets_collaboration_option(self) -> None:
        w = _worker("codex")
        w.acp_session_id = "s1"
        w._apply_modes(CODEX_MODES)
        w._apply_config_options(CODEX_CONFIG_OPTIONS)
        calls: list[tuple[str, dict]] = []

        async def fake_request(method: str, params: dict, timeout: float = 0) -> dict:
            calls.append((method, params))
            return {}

        w._request = fake_request  # type: ignore[method-assign]
        asyncio.run(w.set_mode("plan"))
        self.assertEqual(calls[0][0], "session/set_mode")
        self.assertEqual(calls[0][1]["modeId"], "read-only")
        self.assertEqual(calls[1][0], "session/set_config_option")
        self.assertEqual(calls[1][1]["configId"], "collaboration_mode")
        self.assertEqual(calls[1][1]["value"], "plan")
        self.assertEqual(w.mode, "plan")

        calls.clear()
        asyncio.run(w.set_mode("agent"))
        self.assertEqual(calls[0][1]["modeId"], "agent-full-access")
        self.assertEqual(calls[1][1]["value"], "default")
        self.assertEqual(w.mode, "agent")


class CodexSetModelTest(unittest.TestCase):
    def test_set_model_sends_model_then_effort(self) -> None:
        w = _worker("codex")
        w.acp_session_id = "s1"
        w._apply_config_options(CODEX_CONFIG_OPTIONS)
        calls: list[tuple[str, dict]] = []

        async def fake_request(method: str, params: dict, timeout: float = 0) -> dict:
            calls.append((method, params))
            opts = [dict(o) for o in CODEX_CONFIG_OPTIONS]
            for o in opts:
                if o["id"] == params.get("configId"):
                    o["currentValue"] = params["value"]
            if params.get("configId") == "reasoning_effort":
                for o in opts:
                    if o["id"] == "model":
                        o["currentValue"] = "gpt-5.6-sol"
            return {"configOptions": opts}

        w._request = fake_request  # type: ignore[method-assign]
        asyncio.run(w.set_model("gpt-5.6-sol[effort=high]"))
        self.assertEqual(
            [(m, p["configId"], p["value"]) for m, p in calls],
            [
                ("session/set_config_option", "model", "gpt-5.6-sol"),
                ("session/set_config_option", "reasoning_effort", "high"),
            ],
        )
        self.assertEqual(w.model_id, "gpt-5.6-sol[effort=high]")


class PermissionAutoAllowTest(unittest.TestCase):
    def test_picks_by_kind_for_codex_option_ids(self) -> None:
        w = _worker("codex")
        w._permission_policy_ask = False
        written: list[dict] = []

        async def fake_write(msg: dict) -> None:
            written.append(msg)

        w._write = fake_write  # type: ignore[method-assign]
        asyncio.run(
            w._handle_permission(
                "req-1",
                {
                    "toolCall": {"title": "Run command"},
                    "options": [
                        {"optionId": "allow_once", "name": "Yes", "kind": "allow_once"},
                        {"optionId": "allow_for_session", "name": "Always", "kind": "allow_always"},
                        {"optionId": "cancel", "name": "No", "kind": "reject_once"},
                    ],
                },
            )
        )
        self.assertEqual(written[0]["result"]["outcome"]["optionId"], "allow_for_session")

    def test_zed_style_ids_pick_allow_once(self) -> None:
        w = _worker("codex")
        w._permission_policy_ask = False
        written: list[dict] = []

        async def fake_write(msg: dict) -> None:
            written.append(msg)

        w._write = fake_write  # type: ignore[method-assign]
        asyncio.run(
            w._handle_permission(
                "req-2",
                {
                    "options": [
                        {"optionId": "abort", "name": "No", "kind": "reject_once"},
                        {"optionId": "approved", "name": "Yes", "kind": "allow_once"},
                    ]
                },
            )
        )
        self.assertEqual(written[0]["result"]["outcome"]["optionId"], "approved")


class AuthHintTest(unittest.TestCase):
    def test_auth_required_detection_and_hint(self) -> None:
        w = _worker("codex")
        self.assertTrue(w._is_auth_required(RuntimeError("-32000 Authentication required")))
        self.assertFalse(w._is_auth_required(RuntimeError("Session not found")))
        self.assertIn("codex login", w._auth_required_hint())


if __name__ == "__main__":
    unittest.main()


class CodexThreadErrorTest(unittest.TestCase):
    def test_system_error_after_retries_emits_error_event(self) -> None:
        emitted: list[dict] = []

        async def _emit(payload: dict) -> None:
            emitted.append(payload)

        async def _set_status(_cid: str, _st: str, _err: str | None) -> None:
            return None

        w = Worker("chat-codex-err", emit=_emit, set_status=_set_status)
        w.provider = "codex"

        async def run() -> None:
            for i in range(1, 3):
                await w._handle_update(
                    {
                        "update": {
                            "sessionUpdate": "session_info_update",
                            "_meta": {
                                "codex": {
                                    "error": {
                                        "message": f"Reconnecting... {i}/5",
                                        "additionalDetails": "unexpected status 401 Unauthorized: invalid_api_key",
                                        "willRetry": True,
                                    }
                                }
                            },
                        }
                    }
                )
            await w._handle_update(
                {
                    "update": {
                        "sessionUpdate": "session_info_update",
                        "_meta": {"codex": {"threadStatus": {"type": "systemError"}}},
                    }
                }
            )

        asyncio.run(run())
        errors = [e for e in emitted if e.get("kind") == "error"]
        self.assertEqual(len(errors), 1)
        self.assertIn("401", errors[0]["text"])
        self.assertIsNone(w._codex_last_error)
