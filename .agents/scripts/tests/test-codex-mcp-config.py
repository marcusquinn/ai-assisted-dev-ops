#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Regression coverage for setup/update Codex MCP reconciliation."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "codex-mcp-config.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("codex_mcp_config", SCRIPT)
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


def migrate(text):
    original = migration.tomllib.loads(text)
    desired, _ = migration.reconcile(original)
    return migration.render(text, original, desired)


class CodexMCPTests(unittest.TestCase):
    def test_docker_help_false_positive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".codex").mkdir()
            config = root / ".codex/config.toml"
            original = "[mcp_servers.MCP_DOCKER]\ncommand = 'docker'\nargs = ['mcp', 'gateway', 'run']\n[other]\nkeep = true\n"
            config.write_text(original)
            module = SCRIPT.parent / "setup/modules/tool-install.sh"
            command = '''source "$1"
print_info() { printf '%s\\n' "$*"; }
docker() { [[ "$*" == "mcp --help" ]]; }
_fix_codex_docker_mcp
'''
            subprocess.run(  # nosec B603 -- fixed shell, repository module, and local fixtures
                ["/bin/bash", "-c", command, "test", str(module)],
                env={**os.environ, "HOME": directory}, check=True, capture_output=True)
            parsed = migration.tomllib.loads(config.read_text())
            self.assertNotIn("MCP_DOCKER", parsed.get("mcp_servers", {}))
            self.assertEqual(parsed["other"], {"keep": True})
            config.write_text(original)
            command = command.replace('[[ "$*" == "mcp --help" ]]', 'return 0')
            subprocess.run(  # nosec B603 -- fixed shell, repository module, and local fixtures
                ["/bin/bash", "-c", command, "test", str(module)],
                env={**os.environ, "HOME": directory}, check=True, capture_output=True)
            self.assertEqual(config.read_text(), original)

    def test_fresh_defaults_are_opt_in(self):
        servers = migration.tomllib.loads(migrate(""))["mcp_servers"]
        self.assertEqual(set(servers), set(migration.DEFAULTS))
        self.assertTrue(all(not server["enabled"] for server in servers.values()))
        self.assertNotIn("type", servers["cloudflare-api"])

    def test_legacy_multiline_package_and_nested_env(self):
        text = '''# User preferences
model = "custom-model"
[mcp_servers."playwright"] # keep this comment
command = "npx"
args = [
  "-y",
  "@anthropic-ai/mcp-server-playwright@latest",
  "--custom-option",
]
enabled = true
[mcp_servers.playwright.env]
CUSTOM = "retained"
[profiles.personal]
model = "another-model"
'''
        result = migrate(text)
        data = migration.tomllib.loads(result)
        server = data["mcp_servers"]["playwright"]
        self.assertEqual(server["args"], ["-y", "@playwright/mcp@0.0.79", "--custom-option"])
        self.assertTrue(server["enabled"])
        self.assertEqual(server["env"], {"CUSTOM": "retained"})
        self.assertIn("# keep this comment", result)
        self.assertEqual(data["profiles"], {"personal": {"model": "another-model"}})
        self.assertEqual(migrate(result), result)

    def test_preserve_custom_commands_and_explicit_settings(self):
        text = '''[mcp_servers.playwright]
command = "/custom/launcher"
args = ["custom"]
enabled = false
startup_timeout_sec = 300
[mcp_servers.cloudflare-api]
url = "https://mcp.cloudflare.com/mcp"
enabled = true
'''
        before = migration.tomllib.loads(text)["mcp_servers"]
        after = migration.tomllib.loads(migrate(text))["mcp_servers"]
        for name, value in before.items():
            self.assertEqual(after[name], value)

    def test_oauth_and_deprecated_migrations(self):
        text = '''[mcp_servers.cloudflare-api]
type = 'url'
url = 'https://mcp.cloudflare.com/mcp'
[mcp_servers.auggie-mcp]
command = '/custom/bin/auggie'
args = ['--mcp']
'''
        servers = migration.tomllib.loads(migrate(text))["mcp_servers"]
        self.assertFalse(servers["cloudflare-api"]["enabled"])
        self.assertNotIn("type", servers["cloudflare-api"])
        self.assertFalse(servers["auggie-mcp"]["enabled"])

    def test_missing_app_executable_only(self):
        data = {"mcp_servers": {"node_repl": {
            "command": "/Applications/Example.app/Contents/Resources/cua_node/bin/node_repl"
        }, "custom": {"command": "/missing/custom"}}}
        with patch.object(migration.os.path, "isfile", return_value=False):
            updated, _ = migration.reconcile(data)
        self.assertFalse(updated["mcp_servers"]["node_repl"]["enabled"])
        self.assertEqual(updated["mcp_servers"]["custom"], data["mcp_servers"]["custom"])
        with patch.object(migration.os.path, "isfile", return_value=True):
            updated, _ = migration.reconcile(data)
        self.assertNotIn("enabled", updated["mcp_servers"]["node_repl"])

    def test_backups_modes_and_idempotence(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            config.write_text("# retained\nmodel = 'example'\n")
            config.chmod(0o600)
            original = config.read_bytes()
            with patch("sys.argv", [str(SCRIPT), "--config", str(config)]):
                migration.main()
                updated = config.read_bytes()
                migration.main()
            backups = list(Path(directory).glob("config.toml.before-mcp-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), original)
            self.assertEqual(config.read_bytes(), updated)
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_invalid_input_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            config.write_text("[invalid")
            with patch("sys.argv", [str(SCRIPT), "--config", str(config)]):
                with self.assertRaises(ValueError):
                    migration.main()
            self.assertEqual(config.read_text(), "[invalid")
            self.assertEqual(list(Path(directory).glob("config.toml.before-mcp-*")), [])


if __name__ == "__main__":
    unittest.main()
