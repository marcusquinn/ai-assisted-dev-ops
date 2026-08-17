#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-session-miner-error-classification.sh — Unit tests for session-miner error categories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_MINER_DIR="${SCRIPT_DIR}/../session-miner"

python3 - "$SESSION_MINER_DIR" <<'PY'
import sys
from collections import Counter, defaultdict

sys.path.insert(0, sys.argv[1])

from compress import _build_error_patterns
from extract_errors import classify_error


cases = {
    "BLOCKED by shared command policy (forbid, command.parse-error): unsupported": "command_policy",
    "NotFound: FileSystem.access ([local-worktree])": "workdir_not_found",
    "ENOENT: no such file or directory, open 'missing.txt'": "file_not_found",
    "Error: must Read before Edit": "not_read_first",
}

for raw_error, expected in cases.items():
    actual = classify_error(raw_error)
    if actual != expected:
        raise SystemExit(f"expected {expected!r} for {raw_error!r}, got {actual!r}")

patterns = _build_error_patterns(
    Counter({"bash:command_policy": 1}),
    defaultdict(list),
    defaultdict(list),
    defaultdict(set, {"bash:command_policy": {"model-a"}}),
)
if patterns[0]["severity"] != "high":
    raise SystemExit(f"expected command_policy severity 'high', got {patterns[0]['severity']!r}")

print("session-miner error classification tests passed")
PY
