#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READINESS_LIB="${SCRIPT_DIR}/../file-discovery-readiness.sh"
TEST_ROOT="$(mktemp -d -t aidevops-fd-readiness.XXXXXX)"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

# shellcheck source=../file-discovery-readiness.sh
source "$READINESS_LIB"

assert_equal() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s (expected %s, got %s)\n' "$name" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$name"
	return 0
}

assert_contains() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	if [[ "$actual" != *"$expected"* ]]; then
		printf 'FAIL: %s (missing %s)\n' "$name" "$expected" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$name"
	return 0
}

missing_state=$(PATH="/usr/bin:/bin" aidevops_fd_state || true)
assert_equal "missing" "$missing_state" "missing fd is reported"

mkdir -p "$TEST_ROOT/fdfind-only" "$TEST_ROOT/fd-ready" "$TEST_ROOT/shims"
printf '#!/usr/bin/env bash\nprintf "fd 10.0.0\\n"\n' >"$TEST_ROOT/fdfind-only/fdfind"
printf '#!/usr/bin/env bash\nprintf "fd 10.0.0\\n"\n' >"$TEST_ROOT/fd-ready/fd"
chmod +x "$TEST_ROOT/fdfind-only/fdfind" "$TEST_ROOT/fd-ready/fd"

compatibility_state=$(PATH="$TEST_ROOT/fdfind-only:/usr/bin:/bin" aidevops_fd_state)
assert_equal "compatibility" "$compatibility_state" "fdfind-only state is distinguished"

ready_state=$(PATH="$TEST_ROOT/fd-ready:/usr/bin:/bin" aidevops_fd_state)
assert_equal "ready" "$ready_state" "fd command is ready"

PATH="$TEST_ROOT/fdfind-only:/usr/bin:/bin"
export PATH
AIDEVOPS_FD_SHIM_DIR="$TEST_ROOT/shims"
export AIDEVOPS_FD_SHIM_DIR
aidevops_ensure_fd_command
assert_equal "$TEST_ROOT/shims/fd" "$(command -v fd)" "fdfind compatibility command is executable"
assert_equal "fd 10.0.0" "$(fd --version)" "compatibility command delegates to fdfind"

mkdir -p "$TEST_ROOT/occupied"
printf 'preserve-user-file\n' >"$TEST_ROOT/occupied/fd"
PATH="$TEST_ROOT/fdfind-only:/usr/bin:/bin"
AIDEVOPS_FD_SHIM_DIR="$TEST_ROOT/occupied"
export PATH AIDEVOPS_FD_SHIM_DIR
if aidevops_ensure_fd_command; then
	printf 'FAIL: existing non-executable fd path was replaced or accepted\n' >&2
	exit 1
fi
assert_equal "preserve-user-file" "$(<"$TEST_ROOT/occupied/fd")" "existing fd path is preserved"

print_success() {
	local text="$1"
	printf 'SUCCESS: %s\n' "$text"
	return 0
}
print_error() {
	local text="$1"
	printf 'ERROR: %s\n' "$text"
	return 0
}
check_cmd() {
	local command_name="$1"
	command -v "$command_name" >/dev/null 2>&1 || return 1
	return 0
}

# shellcheck source=../aidevops-cli/aidevops-status-lib.sh
source "${SCRIPT_DIR}/../aidevops-cli/aidevops-status-lib.sh"
missing_output=$(PATH="/usr/bin:/bin" _status_file_discovery_readiness)
assert_contains "fd - not installed" "$missing_output" "status reports missing fd with remediation"
compatibility_output=$(PATH="$TEST_ROOT/fdfind-only:/usr/bin:/bin" _status_file_discovery_readiness)
assert_contains "fdfind is installed but the required fd command is unavailable" "$compatibility_output" "status reports fdfind compatibility gap"
ready_output=$(PATH="$TEST_ROOT/fd-ready:/usr/bin:/bin" _status_file_discovery_readiness)
assert_contains "SUCCESS: fd" "$ready_output" "status reports ready fd command"

printf 'PASS: file-discovery readiness contract\n'
exit 0
