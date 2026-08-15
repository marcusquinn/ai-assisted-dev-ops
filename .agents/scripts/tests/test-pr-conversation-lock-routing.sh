#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test: worker dispatch locks only the authoritative issue
# conversation, leaving linked PR conversations available to CI review bots.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
CALL_LOG="${TEST_ROOT}/gh-calls.log"
export HOME="${TEST_ROOT}/home"
export LOGFILE="${TEST_ROOT}/pulse.log"
mkdir -p "$HOME"
: >"$CALL_LOG"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

reset_calls() {
	: >"$CALL_LOG"
	return 0
}

assert_call() {
	local expected="$1"
	grep -Fxq "$expected" "$CALL_LOG"
	return $?
}

assert_no_call() {
	local rejected="$1"
	if grep -Fxq "$rejected" "$CALL_LOG"; then
		return 1
	fi
	return 0
}

# Source production functions before installing command stubs.
SCRIPT_DIR="$SCRIPTS_DIR"
# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=../worker-lifecycle-common.sh
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=../pulse-dispatch-core.sh
source "${SCRIPTS_DIR}/pulse-dispatch-core.sh"
# shellcheck source=../full-loop-helper-merge.sh
source "${SCRIPTS_DIR}/full-loop-helper-merge.sh"
# shellcheck source=../worker-watchdog-kill.sh
source "${SCRIPTS_DIR}/worker-watchdog-kill.sh"

gh_pr_list() {
	printf '77\n'
	return 0
}

gh() {
	local group="${1:-}"
	local action="${2:-}"
	shift 2 || true
	printf '%s %s' "$group" "$action" >>"$CALL_LOG"
	if [[ $# -gt 0 ]]; then
		printf ' %s' "$*" >>"$CALL_LOG"
	fi
	printf '\n' >>"$CALL_LOG"

	if [[ "$group" == "pr" && "$action" == "list" ]]; then
		printf '77\n'
		return 0
	fi
	if [[ "$group" == "pr" && "$action" == "view" ]]; then
		printf 'Resolves #42\n'
		return 0
	fi
	if [[ "$group" == "api" ]]; then
		if [[ "$*" == *'.locked == true'* ]]; then
			printf 'true\n'
			return 0
		fi
		printf 'bug\n'
		return 0
	fi
	return 0
}

log_msg() {
	local message="$1"
	printf '%s\n' "$message" >>"$LOGFILE"
	return 0
}

reset_calls
if ! lock_issue_for_worker "42" "owner/repo" "resolved" ||
	! assert_call "issue lock 42 --repo owner/repo --reason resolved" ||
	! assert_no_call "pr lock 77 --repo owner/repo --reason resolved"; then
	fail "pulse dispatch did not preserve linked PR conversations for CI" || true
	exit 1
fi
pass "pulse dispatch leaves linked PR conversations unlocked"

reset_calls
_merge_unlock_resources "88" "owner/repo"
if ! assert_call "pr unlock 88 --repo owner/repo" ||
	! assert_call "issue unlock 42 --repo owner/repo" ||
	! assert_no_call "issue unlock 88 --repo owner/repo"; then
	fail "full-loop merge cleanup did not preserve PR/issue command routing" || true
	exit 1
fi
pass "full-loop merge cleanup routes PR and issue unlocks separately"

reset_calls
_watchdog_unlock_issue_and_prs "42" "owner/repo"
if ! assert_call "issue unlock 42 --repo owner/repo" ||
	! assert_call "pr unlock 77 --repo owner/repo" ||
	! assert_no_call "issue unlock 77 --repo owner/repo"; then
	fail "watchdog cleanup did not preserve PR/issue command routing" || true
	exit 1
fi
pass "watchdog cleanup routes PR and issue unlocks separately"

printf 'Tests run: 3\nTests failed: 0\n'
