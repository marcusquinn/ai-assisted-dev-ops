#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_LIB="$TEST_SCRIPT_DIR/../aidevops-cli/aidevops-status-lib.sh"
TEST_ROOT="$(mktemp -d -t aidevops-status-rtk.XXXXXX)"
ORIGINAL_PATH="$PATH"

cleanup() {
	export PATH="$ORIGINAL_PATH"
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_success() {
	local text="$1"
	printf 'SUCCESS: %s\n' "$text"
	return 0
}
print_warning() {
	local text="$1"
	printf 'WARNING: %s\n' "$text"
	return 0
}

# shellcheck source=../aidevops-cli/aidevops-status-lib.sh
source "$STATUS_LIB"

mkdir -p "$TEST_ROOT/bin"

write_mock_rtk() {
	local version_output="$1"
	printf '%s\n' "#!$BASH" "printf '%s\\n' '$version_output'" >"$TEST_ROOT/bin/rtk"
	chmod +x "$TEST_ROOT/bin/rtk"
	return 0
}

use_isolated_path() {
	export PATH="$TEST_ROOT/bin"
	hash -r
	return 0
}

use_original_path() {
	export PATH="$ORIGINAL_PATH"
	hash -r
	return 0
}

assert_status_contains() {
	local description="$1"
	local expected="$2"
	local output=""
	output=$(_status_rtk_readiness)
	if [[ "$output" != *"$expected"* ]]; then
		printf 'FAIL: %s -- output: %s\n' "$description" "$output" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$description"
	return 0
}

rm -f "$TEST_ROOT/bin/rtk"
use_isolated_path
assert_status_contains "missing RTK stays optional" "RTK - not installed (optional; run: aidevops setup)"

use_original_path
write_mock_rtk "rtk 0.41.0"
use_isolated_path
assert_status_contains "tested RTK is ready" "SUCCESS: RTK v0.41.0 (tested baseline)"

use_original_path
write_mock_rtk "rtk 0.40.0"
use_isolated_path
assert_status_contains "older RTK recommends setup" "RTK v0.40.0 - older than tested baseline v0.41.0; run: aidevops setup"

use_original_path
write_mock_rtk "rtk 0.46.0"
use_isolated_path
assert_status_contains "newer RTK is available but unverified" "RTK v0.46.0 - available, newer than tested baseline v0.41.0; compatibility unverified"

use_original_path
write_mock_rtk "rtk development build"
use_isolated_path
assert_status_contains "malformed RTK output is unknown" "RTK - available, version unknown (tested baseline v0.41.0)"

for padded_patch in 08 09; do
	use_original_path
	write_mock_rtk "rtk 0.41.${padded_patch}"
	use_isolated_path
	assert_status_contains "zero-padded RTK 0.41.${padded_patch} is unknown" "RTK - available, version unknown (tested baseline v0.41.0)"
done

use_original_path
unset -f aidevops_rtk_tested_version aidevops_rtk_installed_version aidevops_rtk_version_state
assert_status_contains "missing readiness helper is explicit" "RTK - readiness unavailable (optional tool)"

printf 'PASS: RTK status readiness states\n'
exit 0
