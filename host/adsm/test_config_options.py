"""Tests for Claude ACP configOptions → model catalogue parsing."""

from __future__ import annotations

import unittest

from host.adsm.worker import (
    current_model_from_config_options,
    models_from_config_options,
)


SAMPLE_CLAUDE_SESSION = [
    {
        "id": "mode",
        "name": "Mode",
        "category": "mode",
        "type": "select",
        "currentValue": "default",
        "options": [{"value": "default", "name": "Default"}],
    },
    {
        "id": "model",
        "name": "Model",
        "description": "AI model to use",
        "category": "model",
        "type": "select",
        "currentValue": "default",
        "options": [
            {"value": "default", "name": "Default", "description": "claude-opus-4-6"},
            {"value": "opus", "name": "Opus", "description": "Most capable"},
            {"value": "sonnet", "name": "Sonnet", "description": "Balanced"},
        ],
    },
]


class ConfigOptionsModelsTest(unittest.TestCase):
    def test_extracts_models_from_config_options(self) -> None:
        models = models_from_config_options(SAMPLE_CLAUDE_SESSION)
        self.assertEqual(len(models), 3)
        self.assertEqual(models[0]["modelId"], "default")
        self.assertEqual(models[0]["name"], "Default")
        self.assertEqual(models[1]["modelId"], "opus")

    def test_reads_current_model(self) -> None:
        self.assertEqual(
            current_model_from_config_options(SAMPLE_CLAUDE_SESSION),
            "default",
        )

    def test_empty_when_no_model_option(self) -> None:
        self.assertEqual(models_from_config_options([]), [])
        self.assertEqual(models_from_config_options(None), [])


if __name__ == "__main__":
    unittest.main()
