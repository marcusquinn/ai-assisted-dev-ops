#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../platform-fix-regression-evidence.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/platform-regression-evidence.XXXXXX")"

cleanup() {
	local test_root="$TEST_ROOT"
	rm -rf "$test_root"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

assert_contains() {
	local value="$1"
	local expected="$2"
	local label="$3"
	[[ "$value" == *"$expected"* ]] || fail "${label}: missing ${expected}"
	return 0
}

run_pass_case() {
	local label="$1"
	local title="$2"
	local body="$3"
	local files="$4"
	local output=""
	printf '%s\n' "$body" >"${TEST_ROOT}/body.md"
	printf '%s\n' "$files" >"${TEST_ROOT}/files.txt"
	if ! output=$("$HELPER" --title "$title" --body-file "${TEST_ROOT}/body.md" --files-file "${TEST_ROOT}/files.txt" 2>&1); then
		fail "${label}: expected pass, got ${output}"
	fi
	assert_contains "$output" 'platform regression evidence:' "$label"
	return 0
}

run_fail_case() {
	local label="$1"
	local title="$2"
	local body="$3"
	local files="$4"
	local output=""
	printf '%s\n' "$body" >"${TEST_ROOT}/body.md"
	printf '%s\n' "$files" >"${TEST_ROOT}/files.txt"
	if output=$("$HELPER" --title "$title" --body-file "${TEST_ROOT}/body.md" --files-file "${TEST_ROOT}/files.txt" 2>&1); then
		fail "${label}: expected failure, got ${output}"
	fi
	assert_contains "$output" 'must change a test under .agents/scripts/tests/' "$label"
	return 0
}

run_pass_case \
	'no trigger' \
	'Improve status statistics reporting' \
	'No platform-specific behavior changes.' \
	'.agents/scripts/stats-helper.sh'

run_pass_case \
	'trigger with test change' \
	'Fix Linux stat portability' \
	'Use the portable file timestamp wrapper.' \
	$'.agents/scripts/file-helper.sh\n.agents/scripts/tests/test-file-helper.sh'

run_pass_case \
	'trigger with evidence section' \
	'Handle getent fallback on macOS' \
	$'## Regression Evidence\nAutomated coverage is not possible because this branch requires a managed directory service.' \
	'.agents/scripts/account-helper.sh'

run_fail_case \
	'trigger without evidence' \
	'Fix systemd cron behavior on Ubuntu' \
	'Correct the generated service.' \
	'.agents/scripts/schedulers.sh'

run_fail_case \
	'placeholder evidence' \
	'Improve Bash 3.2 portability' \
	$'## Regression Evidence\nTBD' \
	'.agents/scripts/compat-helper.sh'

run_pass_case \
	'docs-only false positive' \
	'Document Linux portability guidance' \
	'Clarify the supported platforms.' \
	$'.agents/reference/bash-compat.md\ntodo/plans/shell-portability-hardening.md'

printf 'PASS platform-fix regression evidence policy cases\n'
