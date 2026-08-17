#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for approval lifecycle GitHub login validation.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../approval-helper.sh"

PASS=0
FAIL=0
GH_LOGIN_PAYLOAD=""
GH_LOGIN_RC=0
MUTATION_LOG=""
STATUS_LOG=""

pass() {
	local name="$1"
	printf '  PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf '  FAIL: %s\n' "$name"
	[[ -n "$detail" ]] && printf '    %s\n' "$detail"
	FAIL=$((FAIL + 1))
	return 0
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$name"
	else
		fail "$name" "expected '${expected}', got '${actual}'"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing '${needle}'"
	fi
	return 0
}

reset_lifecycle_stubs() {
	MUTATION_LOG=$(mktemp) || return 1
	STATUS_LOG=$(mktemp) || {
		rm -f "$MUTATION_LOG"
		return 1
	}
	return 0
}

cleanup_lifecycle_stubs() {
	rm -f "$MUTATION_LOG" "$STATUS_LOG"
	MUTATION_LOG=""
	STATUS_LOG=""
	return 0
}

# shellcheck disable=SC1090
source "$HELPER_SCRIPT" >/dev/null 2>&1

gh() {
	local command="${1:-}"
	local endpoint="${2:-}"
	if [[ "$command" == "api" && "$endpoint" == "user" ]]; then
		printf '%b' "$GH_LOGIN_PAYLOAD"
		return "$GH_LOGIN_RC"
	fi
	return 1
}

set_issue_status() {
	printf '%s\n' "$*" >>"$STATUS_LOG"
	return 0
}

gh_issue_edit_safe() {
	printf '%s\n' "$*" >>"$MUTATION_LOG"
	return 0
}

gh_issue_view() {
	printf 'bug'
	return 0
}

_approval_lock_issue() {
	return 0
}

_approval_verify_issue_state() {
	return 0
}

run_invalid_lifecycle_case() {
	local name="$1"
	local payload="$2"
	local gh_rc="$3"
	local rc=0
	local mutations=""
	local statuses=""

	GH_LOGIN_PAYLOAD="$payload"
	GH_LOGIN_RC="$gh_rc"
	reset_lifecycle_stubs || return 1
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || rc=$?
	mutations=$(<"$MUTATION_LOG")
	statuses=$(<"$STATUS_LOG")
	assert_eq "${name} returns failure" "1" "$rc"
	assert_eq "${name} skips assignee mutation" "" "$mutations"
	assert_eq "${name} preserves lifecycle ordering" "" "$statuses"
	cleanup_lifecycle_stubs
	return 0
}

printf 'Test: approval-helper GitHub login validation\n'
printf '================================================\n\n'

GH_LOGIN_PAYLOAD='valid-user\n'
GH_LOGIN_RC=0
reset_lifecycle_stubs || exit 1
valid_rc=0
_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops || valid_rc=$?
valid_mutations=$(<"$MUTATION_LOG")
valid_statuses=$(<"$STATUS_LOG")
assert_eq "valid login succeeds" "0" "$valid_rc"
assert_contains "valid login is forwarded exactly once" "$valid_mutations" "--add-assignee valid-user"
assert_contains "valid login preserves lifecycle mutation" "$valid_statuses" "123 marcusquinn/aidevops available"
cleanup_lifecycle_stubs

run_invalid_lifecycle_case "HTTP 503 JSON output" '{"message":"Service Unavailable","status":"503"}\n' 1
run_invalid_lifecycle_case "empty output" '' 0
run_invalid_lifecycle_case "multiline output" 'valid-user\nother-user\n' 0
run_invalid_lifecycle_case "whitespace-bearing output" 'valid user\n' 0
run_invalid_lifecycle_case "JSON output" '{"login":"valid-user"}\n' 0
run_invalid_lifecycle_case "option-like output" '--add-assignee\n' 0
run_invalid_lifecycle_case "punctuation output" 'valid_user\n' 0
run_invalid_lifecycle_case "control-character output" 'valid-user\x01\n' 0

printf '\n================================================\n'
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
