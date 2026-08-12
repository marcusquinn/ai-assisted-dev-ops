#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

python3 - "$SCRIPT_DIR" <<'PY'
import os
import socket
import subprocess
import sys

scripts_dir = os.path.dirname(sys.argv[1])
left, right = socket.socketpair()
command = f'''
source "{scripts_dir}/pulse-merge-required-checks.sh"
unset LOGFILE
_pmrc_gh_read() {{ return 1; }}
_required_contexts_for_default_branch_uncached owner/repo
'''
process = subprocess.run(
    ["bash", "-c", command],
    stdout=subprocess.PIPE,
    stderr=left.fileno(),
    pass_fds=(left.fileno(),),
    check=False,
)
left.close()
payload = right.recv(65536).decode()
right.close()
if process.returncode != 1:
    raise SystemExit(f"expected fail-closed status 1, got {process.returncode}")
expected = "failed to resolve default branch for owner/repo"
if payload.count(expected) != 1:
    raise SystemExit(f"expected one descriptor-safe diagnostic, got: {payload!r}")
if "/dev/stderr" in payload or "No such device or address" in payload:
    raise SystemExit(f"stderr was reopened by pathname: {payload!r}")
PY

LOGFILE="${TEST_ROOT}/configured.log"
export LOGFILE
# shellcheck source=../lib/descriptor-safe-log.sh
source "${SCRIPT_DIR}/../lib/descriptor-safe-log.sh"
aidevops_log_line "first configured line"
aidevops_log_line "second configured line"

[[ "$(wc -l <"$LOGFILE" | tr -d ' ')" == "2" ]]
grep -Fq "first configured line" "$LOGFILE"
grep -Fq "second configured line" "$LOGFILE"

printf 'PASS descriptor-safe logging preserves socket stderr and configured files\n'
