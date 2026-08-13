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
AIDEVOPS_AUTO_DISPATCH_LOCK_DIR="${TMP}/locks"
export LOGFILE GH_CALLS AIDEVOPS_AUTO_DISPATCH_LOCK_DIR

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

GH_LOCKED=true
GH_LOCK_RC=0
gh() {
	printf '%s\n' "$*" >>"$GH_CALLS"
	if [[ "$1" == "issue" && "$2" == "lock" ]]; then
		return "$GH_LOCK_RC"
	fi
	if [[ "$1" == "api" ]]; then
		printf '%s\n' "$GH_LOCKED"
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

: >"$GH_CALLS"
if lock_issue_for_worker 41 owner/repo &&
	grep -q -- 'issue lock 41 --repo owner/repo --reason resolved' "$GH_CALLS" &&
	grep -q -- 'api repos/owner/repo/issues/41 --jq .locked == true' "$GH_CALLS" &&
	[[ -f "${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR}/owner--repo-41" ]]; then
	pass "strict lock succeeds only after independent verification"
else
	fail "strict lock succeeds only after independent verification"
fi

: >"$GH_CALLS"
GH_LOCKED=false
if ! lock_issue_for_worker 42 owner/repo &&
	grep -q -- 'dispatch remains blocked' "$LOGFILE"; then
	pass "unverified issue lock fails closed"
else
	fail "unverified issue lock fails closed"
fi

: >"$GH_CALLS"
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

: >"$GH_CALLS"
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
