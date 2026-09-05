#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Native Codex installation and lifecycle contract regression tests."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS.parent / "hooks"))
import codex_lifecycle as lifecycle

spec = importlib.util.spec_from_file_location("codex_setup", SCRIPTS / "codex-setup.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class CodexSetupTests(unittest.TestCase):
    def test_guidance_preserves_personal_and_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "AGENTS.md").write_text("Personal instructions\n")
            (root / "AGENTS.override.md").write_text("Override\n")
            setup.guidance(root, root / "agents")
            first = (root / "AGENTS.md").read_text()
            setup.guidance(root, root / "agents")
            self.assertEqual(first, (root / "AGENTS.md").read_text())
            self.assertIn("Personal instructions\n", first)
            self.assertIn("build-plus.md", first)
            self.assertEqual((root / "AGENTS.override.md").read_text(), "Override\n")

    def test_malformed_markers_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "AGENTS.md").write_text(setup.START)
            with self.assertRaises(ValueError):
                setup.guidance(root, root)
            self.assertEqual((root / "AGENTS.md").read_text(), setup.START)

    def test_skills_update_and_personal_collision(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            agents = root / "agents"
            commands = agents / "scripts/commands"
            commands.mkdir(parents=True)
            (commands / "full-loop.md").write_text("First version")
            (agents / "build-plus.md").write_text("Build")
            skills = root / "skills"
            personal = skills / "aidevops-build-plus/SKILL.md"
            personal.parent.mkdir(parents=True)
            personal.write_text("Personal skill")
            setup.skills(skills, agents)
            target = skills / "aidevops-full-loop/SKILL.md"
            self.assertIn(str(commands / "full-loop.md"), target.read_text())
            self.assertNotIn("First version", target.read_text())
            self.assertIn("allow_implicit_invocation: false", (target.parent / "agents/openai.yaml").read_text())
            self.assertEqual(personal.read_text(), "Personal skill")
            first = target.read_bytes()
            setup.skills(skills, agents)
            self.assertEqual(first, target.read_bytes())

    def test_hooks_merge_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            custom = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "custom"}]}]}}
            path = root / "hooks.json"
            path.write_text(json.dumps(custom))
            setup.hooks(root, root / "agents")
            first = path.read_bytes()
            setup.hooks(root, root / "agents")
            self.assertEqual(first, path.read_bytes())
            data = json.loads(first)
            self.assertEqual(data["hooks"]["Stop"], custom["hooks"]["Stop"])
            self.assertEqual(len(data["hooks"]["PreToolUse"]), 1)

    def test_custom_home_and_feature_flag(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.dict(os.environ, {"CODEX_HOME": str(root / "codex"), "AIDEVOPS_FEATURE_COMMANDS_CODEX": "no"}):
                with patch("sys.argv", ["codex-setup", "all", "--agents", str(root / "agents"), "--skills-home", str(root / "skills")]):
                    setup.main()
            self.assertTrue((root / "codex/AGENTS.md").exists())
            self.assertFalse((root / "skills").exists())
            result = subprocess.run(  # nosec B603 -- fixed shell and repository registry
                ["/bin/bash", "-c", 'source "$1"; rt_config_path codex; rt_config_format codex; rt_command_dir codex', "test", str(SCRIPTS / "runtime-registry.sh")],
                env={**os.environ, "CODEX_HOME": str(root / "codex")}, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), [str(root / "codex/config.toml"), "toml", str(root / "codex/prompts")])

    def test_real_setup_update_twice(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            agents = root / ".aidevops/agents"
            agents.parent.mkdir(parents=True)
            agents.symlink_to(SCRIPTS.parent, target_is_directory=True)
            codex = root / "custom-codex"
            codex.mkdir()
            command = 'source "$1"; print_info() { :; }; print_success() { :; }; update_codex_config; update_codex_config'
            subprocess.run(  # nosec B603 -- real setup module with isolated HOME
                ["/bin/bash", "-c", command, "test", str(SCRIPTS / "setup/modules/config.sh")],
                env={**os.environ, "HOME": str(root), "CODEX_HOME": str(codex),
                     "AIDEVOPS_FEATURE_COMMANDS_CODEX": "yes"},
                capture_output=True, text=True, check=True)
            self.assertTrue((codex / "AGENTS.md").is_file())
            self.assertTrue((codex / "config.toml").is_file())
            data = json.loads((codex / "hooks.json").read_text())
            self.assertEqual(len(data["hooks"]["PreToolUse"]), 1)
            self.assertTrue((root / ".agents/skills/aidevops-full-loop/SKILL.md").is_file())

    def test_codex_patch_and_command_contract(self):
        event = {"hook_event_name": "PreToolUse", "tool_name": "apply_patch", "tool_input": {"command": "*** Begin Patch\n*** End Patch"}}
        with patch.object(lifecycle.guard, "_check_canonical_write", return_value={"denied": True}) as check:
            self.assertEqual(lifecycle.handle(event), {"denied": True})
            check.assert_called_once_with("", event["tool_input"]["command"])
        event["tool_name"] = "Bash"
        with patch.object(lifecycle.guard, "_check_command_policy", return_value=None) as check:
            self.assertIsNone(lifecycle.handle(event))
            check.assert_called_once_with(event["tool_input"]["command"])
        event["tool_input"] = {}
        self.assertEqual(lifecycle.handle(event)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_resume_context(self):
        output = lifecycle.handle({"hook_event_name": "SessionStart", "source": "compact"})
        self.assertIn("Resume the current task", output["hookSpecificOutput"]["additionalContext"])


if __name__ == "__main__":
    unittest.main()
