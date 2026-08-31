#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_LIB="$SCRIPT_DIR/../aidevops-cli/aidevops-status-lib.sh"
TEST_ROOT="$(mktemp -d -t aidevops-status-rtk.XXXXXX)"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_success() { printf 'SUCCESS: %s\n' "$1"; return 0; }
print_warning() { printf 'WARNING: %s\n' "$1"; return 0; }
print_info() { printf 'INFO: %s\n' "$1"; return 0; }
check_cmd() { command -v "$1" >/dev/null 2>&1; }

# shellcheck source=../aidevops-cli/aidevops-status-lib.sh
source "$STATUS_LIB"
mkdir -p "$TEST_ROOT/bin"

set_rtk_version() {
	local version="$1"
	printf '%s\n' '#!/usr/bin/env bash' "[[ \"\${1:-}\" == \"--version\" ]] && printf '%s\\n' 'rtk ${version}'" >"$TEST_ROOT/bin/rtk"
	chmod +x "$TEST_ROOT/bin/rtk"
	return 0
}

missing_output=$(PATH="/usr/bin:/bin" _status_rtk_readiness)
if [[ "$missing_output" != *"rtk - not installed (optional token optimization proxy)"* ]]; then
	printf 'FAIL: missing rtk status was not reported: %s\n' "$missing_output" >&2
	exit 1
fi

set_rtk_version "0.41.0"
tested_output=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" _status_rtk_readiness)
if [[ "$tested_output" != *"aidevops-tested token optimization proxy"* ]]; then
	printf 'FAIL: tested rtk status was not reported: %s\n' "$tested_output" >&2
	exit 1
fi

set_rtk_version "0.40.0"
older_output=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" _status_rtk_readiness)
if [[ "$older_output" != *"is older than aidevops-tested v0.41.0"* ]]; then
	printf 'FAIL: older rtk status was not actionable: %s\n' "$older_output" >&2
	exit 1
fi

set_rtk_version "0.46.0"
newer_output=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" _status_rtk_readiness)
if [[ "$newer_output" != *"available without an automatic downgrade"* ]]; then
	printf 'FAIL: newer rtk status was not reported: %s\n' "$newer_output" >&2
	exit 1
fi

set_rtk_version "development"
unknown_output=$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" _status_rtk_readiness)
if [[ "$unknown_output" != *"compatibility with v0.41.0 is unknown"* ]]; then
	printf 'FAIL: unknown rtk status was not reported: %s\n' "$unknown_output" >&2
	exit 1
fi

printf '%s\n' 'PASS: status reports RTK availability and compatibility states'
exit 0
