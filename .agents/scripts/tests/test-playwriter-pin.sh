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

legacy_config = {
    "mcp": {
        "playwriter": {
            "type": "local",
            "command": ["npx", "playwriter@latest"],
            "enabled": True,
        },
    },
    "tools": {},
}
module.register_standard_mcps(legacy_config, None, "npx")
assert legacy_config["mcp"]["playwriter"]["command"] == ["npx", "playwriter@0.5.0"]
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
assert custom_latest_config["tools"]["playwriter_*"] is False

generated_config = {"mcp": {}, "tools": {}}
module.register_standard_mcps(generated_config, None, "npx")
assert generated_config["mcp"]["playwriter"]["command"] == ["npx", "playwriter@0.5.0"]
assert generated_config["mcp"]["playwriter"]["enabled"] is False
print("PASS Playwriter Python generator pins legacy and generated commands")
PY
