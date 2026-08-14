#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
TMP=$(mktemp -d -t gh30180.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
GH_CALLS="${TMP}/gh-calls.log"
GH_API_COUNT_FILE="${TMP}/gh-api-count"
AIDEVOPS_AUTO_DISPATCH_LOCK_DIR="${TMP}/locks"
AIDEVOPS_CONVERSATION_LOCK_VERIFY_DELAY=0
export LOGFILE GH_CALLS GH_API_COUNT_FILE AIDEVOPS_AUTO_DISPATCH_LOCK_DIR AIDEVOPS_CONVERSATION_LOCK_VERIFY_DELAY

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL: %s\n' "$message"
	return 0
}

reset_gh_calls() {
	: >"$GH_CALLS"
	printf '0\n' >"$GH_API_COUNT_FILE"
	return 0
}

GH_LOCKED=true
GH_LOCK_RC=0
GH_API_RC=0
gh() {
	printf '%s\n' "$*" >>"$GH_CALLS"
	if [[ "$1" == "issue" && "$2" == "lock" ]]; then
		return "$GH_LOCK_RC"
	fi
	if [[ "$1" == "api" ]]; then
		local api_count
		api_count=$(<"$GH_API_COUNT_FILE")
		api_count=$((api_count + 1))
		printf '%s\n' "$api_count" >"$GH_API_COUNT_FILE"
		if [[ "$GH_API_RC" -ne 0 ]]; then
			return "$GH_API_RC"
		fi
		if [[ "$GH_LOCKED" == *,* ]]; then
			printf '%s\n' "$GH_LOCKED" | cut -d, -f"$api_count"
		else
			printf '%s\n' "$GH_LOCKED"
		fi
		return 0
	fi
	return 0
}

gh_pr_list() {
	return 0
}

export -f gh gh_pr_list

# shellcheck source=../pulse-dispatch-core.sh
source "${SCRIPTS_DIR}/pulse-dispatch-core.sh"

reset_gh_calls
if lock_issue_for_worker 41 owner/repo &&
	grep -q -- 'issue lock 41 --repo owner/repo --reason resolved' "$GH_CALLS" &&
	grep -q -- 'api repos/owner/repo/issues/41 --jq .locked == true' "$GH_CALLS" &&
	[[ -f "${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR}/owner--repo-41" ]]; then
	pass "strict lock succeeds only after independent verification"
else
	fail "strict lock succeeds only after independent verification"
fi

reset_gh_calls
GH_LOCKED=false,false,false
if ! lock_issue_for_worker 42 owner/repo &&
	[[ "$(grep -c -- '^api ' "$GH_CALLS")" -eq 3 ]] &&
	grep -q -- 'dispatch remains blocked' "$LOGFILE"; then
	pass "unverified issue lock fails closed"
else
	fail "unverified issue lock fails closed"
fi

reset_gh_calls
GH_LOCKED=false,true
if lock_issue_for_worker 43 owner/repo &&
	[[ "$(grep -c -- '^api ' "$GH_CALLS")" -eq 2 ]] &&
	[[ -f "${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR}/owner--repo-43" ]]; then
	pass "stale lock read retries and then succeeds"
else
	fail "stale lock read retries and then succeeds"
fi

reset_gh_calls
GH_LOCK_RC=1
GH_LOCKED=true
if lock_issue_for_worker 46 owner/repo &&
	grep -q -- 'issue lock 46 --repo owner/repo --reason resolved' "$GH_CALLS" &&
	grep -q -- 'api repos/owner/repo/issues/46 --jq .locked == true' "$GH_CALLS" &&
	grep -q -- 'Reused existing verified conversation lock' "$LOGFILE" &&
	[[ -f "${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR}/owner--repo-46" ]]; then
	pass "already locked issue is accepted after independent verification"
else
	fail "already locked issue is accepted after independent verification"
fi
GH_LOCK_RC=0

reset_gh_calls
GH_LOCKED=false
GH_API_RC=1
if ! lock_issue_for_worker 44 owner/repo &&
	[[ "$(grep -c -- '^api ' "$GH_CALLS")" -eq 3 ]] &&
	[[ ! -f "${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR}/owner--repo-44" ]]; then
	pass "lock verification API errors exhaust retries and fail closed"
else
	fail "lock verification API errors exhaust retries and fail closed"
fi

reset_gh_calls
GH_LOCKED=false,false,false
AIDEVOPS_CONVERSATION_LOCK_VERIFY_ATTEMPTS=999
AIDEVOPS_CONVERSATION_LOCK_VERIFY_DELAY=999
if ! lock_issue_for_worker 45 owner/repo &&
	[[ "$(grep -c -- '^api ' "$GH_CALLS")" -eq 3 ]]; then
	pass "oversized verification controls remain capped"
else
	fail "oversized verification controls remain capped"
fi
unset AIDEVOPS_CONVERSATION_LOCK_VERIFY_ATTEMPTS
AIDEVOPS_CONVERSATION_LOCK_VERIFY_DELAY=0

reset_gh_calls
GH_API_RC=0
GH_LOCKED=true
snapshot='[
  {"number":51,"labels":[{"name":"auto-dispatch"},{"name":"status:blocked"}]},
  {"number":52,"labels":[{"name":"auto-dispatch"},{"name":"status:queued"}]},
  {"number":53,"labels":[]},
  {"number":55,"labels":[{"name":"no-auto-dispatch"}]}
]'
mkdir -p "$AIDEVOPS_AUTO_DISPATCH_LOCK_DIR"
: >"${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR}/owner--repo-53"
: >"${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR}/owner--repo-55"
if reconcile_auto_dispatch_issue_locks owner/repo "$snapshot" &&
	grep -q -- 'issue lock 51 --repo owner/repo' "$GH_CALLS" &&
	grep -q -- 'issue lock 52 --repo owner/repo' "$GH_CALLS" &&
	grep -q -- 'issue unlock 53 --repo owner/repo' "$GH_CALLS" &&
	[[ ! -f "${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR}/owner--repo-53" ]] &&
	! grep -q -- 'issue unlock 55 --repo owner/repo' "$GH_CALLS"; then
	pass "reconciliation covers blocked and queued issues without undoing lockdowns"
else
	fail "reconciliation covers blocked and queued issues without undoing lockdowns"
fi

reset_gh_calls
gh() {
	printf '%s\n' "$*" >>"$GH_CALLS"
	if [[ "$1" == "api" ]]; then
		printf 'auto-dispatch,status:queued\n'
	fi
	return 0
}
export -f gh
if unlock_issue_after_worker 54 owner/repo &&
	! grep -q -- 'issue unlock 54' "$GH_CALLS" &&
	grep -q -- 'Retained conversation lock' "$LOGFILE"; then
	pass "worker handoff retains lock while auto-dispatch remains active"
else
	fail "worker handoff retains lock while auto-dispatch remains active"
fi

printf '\n%d tests, %d failures\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
