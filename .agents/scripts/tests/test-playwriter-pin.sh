#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#30851: generated Playwriter commands stay pinned
# while custom relay commands remain user-owned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

python3 - "$REPO_ROOT" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
module_path = repo_root / ".agents/scripts/lib/mcp_config.py"
spec = importlib.util.spec_from_file_location("mcp_config", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

legacy_commands = [
    ["npx", "playwriter@latest"],
    ["/opt/aidevops/bin/npx", "playwriter@latest"],
    ["npx", "-y", "playwriter@latest"],
    ["bun", "x", "playwriter@latest"],
]
for command in legacy_commands:
    playwriter = {
        "type": "local",
        "command": command.copy(),
        "enabled": True,
        "environment": {"PLAYWRITER_RELAY": "local"},
        "timeout": 5000,
        "custom_metadata": {"owner": "user"},
    }
    legacy_config = {
        "mcp": {"playwriter": playwriter},
        "tools": {},
    }
    module.register_standard_mcps(legacy_config, None, "npx")
    assert legacy_config["mcp"]["playwriter"] is playwriter
    assert playwriter["command"][-1] == "playwriter@0.5.0"
    assert "playwriter@latest" not in playwriter["command"]
    assert playwriter["enabled"] is False
    assert playwriter["environment"] == {"PLAYWRITER_RELAY": "local"}
    assert playwriter["timeout"] == 5000
    assert playwriter["custom_metadata"] == {"owner": "user"}
    assert legacy_config["tools"]["playwriter_*"] is False

custom_config = {
    "mcp": {
        "playwriter": {
            "type": "local",
            "command": ["playwriter", "serve", "--port", "19988"],
            "enabled": True,
        },
    },
    "tools": {},
}
module.register_standard_mcps(custom_config, None, "npx")
assert custom_config["mcp"]["playwriter"]["command"] == [
    "playwriter", "serve", "--port", "19988",
]
assert custom_config["mcp"]["playwriter"]["enabled"] is False
assert custom_config["tools"]["playwriter_*"] is False

custom_latest_config = {
    "mcp": {
        "playwriter": {
            "type": "local",
            "command": ["npx", "playwriter@latest", "serve", "--port", "19988"],
            "enabled": True,
        },
    },
    "tools": {},
}
module.register_standard_mcps(custom_latest_config, None, "npx")
assert custom_latest_config["mcp"]["playwriter"]["command"] == [
    "npx", "playwriter@latest", "serve", "--port", "19988",
]
assert custom_latest_config["mcp"]["playwriter"]["enabled"] is False
assert custom_latest_config["tools"]["playwriter_*"] is False

custom_latest_with_yes_config = {
    "mcp": {
        "playwriter": {
            "type": "local",
            "command": ["npx", "-y", "playwriter@latest", "serve", "--port", "19988"],
            "enabled": True,
        },
    },
    "tools": {},
}
module.register_standard_mcps(custom_latest_with_yes_config, None, "npx")
assert custom_latest_with_yes_config["mcp"]["playwriter"]["command"] == [
    "npx", "-y", "playwriter@latest", "serve", "--port", "19988",
]
assert custom_latest_with_yes_config["mcp"]["playwriter"]["enabled"] is False
assert custom_latest_with_yes_config["tools"]["playwriter_*"] is False

generated_config = {"mcp": {}, "tools": {}}
module.register_standard_mcps(generated_config, None, "npx")
assert generated_config["mcp"]["playwriter"]["command"] == ["npx", "playwriter@0.5.0"]
assert generated_config["mcp"]["playwriter"]["enabled"] is False
print("PASS Playwriter Python generator pins legacy and generated commands")
PY

if grep -Fq 'npm install -g playwriter@0.5.0' "${REPO_ROOT}/.agents/scripts/tool-version-check.sh" &&
	! grep -Fq 'npm install -g playwriter@latest' "${REPO_ROOT}/.agents/scripts/tool-version-check.sh"; then
	printf 'PASS Playwriter updater preserves the reviewed pin\n'
else
	printf 'FAIL Playwriter updater can restore an unreviewed version\n' >&2
	exit 1
fi

python3 - "$REPO_ROOT" <<'PY'
import pathlib
import sys

playwriter_doc = (pathlib.Path(sys.argv[1]) / ".agents/tools/browser/playwriter.md").read_text()
required_contract = (
    "verify\nthe author of **each newly observed message**",
    "do not infer its author from timing, bubble order,\nalignment, colour, or a generic chat header",
    "Treat a message verified as operator-authored as local context",
    "Treat a message verified as support-authored as eligible",
    "Ambiguous attribution must never\n   trigger an external reply",
)
for requirement in required_contract:
    assert requirement in playwriter_doc, requirement


def reply_disposition(message):
    """Bounded fixture model for the documented attribution contract."""
    if message["accessible_sender"] == "Support":
        return "reply-eligible"
    if message["accessible_sender"] == "Operator":
        return "local-context"
    return "pause"


fixture = (
    {"accessible_sender": "Support", "text": "How can I help?"},
    {"accessible_sender": "Operator", "text": "I have replied."},
    {"accessible_sender": None, "text": "Please confirm."},
)
assert [reply_disposition(message) for message in fixture] == [
    "reply-eligible", "local-context", "pause",
]
print("PASS Playwriter chat attribution contract recognizes support, operator, and ambiguous messages")
PY

python3 - "$REPO_ROOT" <<'PY'
import pathlib
import sys

docs_root = pathlib.Path(sys.argv[1]) / ".agents/tools/browser"
playwriter_doc = (docs_root / "playwriter.md").read_text()
automation_doc = (docs_root / "browser-automation.md").read_text()
extension_testing_doc = (docs_root / "extension-dev/testing.md").read_text()

required_playwriter_contract = (
    "Classify an extension UI target before activating Playwriter",
    "`chrome://extensions` and arbitrary installed user-extension pages are not\n   supported Playwriter QA targets",
    "do not activate Playwriter, enumerate tabs, or navigate",
    "project-owned unpacked extension with an existing runner",
    "Do not create test infrastructure or launch a replacement browser/profile",
)
for requirement in required_playwriter_contract:
    assert requirement in playwriter_doc, requirement

assert "EXTENSION UI QA?" in automation_doc
assert "use manual verification" in automation_doc
assert "Project-owned unpacked extension with existing runner" in extension_testing_doc
assert "have no supported automated bridge route" in extension_testing_doc
print("PASS extension QA docs refuse unsupported pages and retain the existing-runner route")
PY
