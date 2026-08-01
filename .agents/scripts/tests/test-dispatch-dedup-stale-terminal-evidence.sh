#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard: stale-recovery escalation uses GitHub comments as the
# multi-runner source of truth and treats a completed stale timeout as terminal
# no-progress evidence even when a crashed launcher omitted its terminal marker.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

TMP_HOME="$(mktemp -d -t stale-terminal.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export LOGFILE="${TMP_HOME}/test.log"
SCRIPT_DIR="$SCRIPTS_DIR"
STALE_RECOVERY_THRESHOLD=2
STALE_ASSIGNMENT_THRESHOLD_SECONDS=600

# shellcheck source=../dispatch-dedup-stale.sh
source "${SCRIPTS_DIR}/dispatch-dedup-stale.sh"

COMMENTS_JSON='[]'
ESCALATED=0
RECOVERED=0
OPEN_PR_STATE=""
OPEN_PR_LOOKUP_FAIL=0
ESCALATION_REASON=""
COMMENT_BODIES="${TMP_HOME}/comments.log"
: >"$COMMENT_BODIES"

gh() {
	local cmd="$1"
	shift || true
	if [[ "$cmd" == "api" ]]; then
		printf '%s\n' "$COMMENTS_JSON"
		return 0
	fi
	printf '[]\n'
	return 0
}

gh_issue_comment() {
	local _issue_number="$1"
	shift || true
	: "$_issue_number"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body)
			printf '%s\n' "${2:-}" >>"$COMMENT_BODIES"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	return 0
}

set_issue_status() {
	return 0
}

_stale_recovery_find_open_pr() {
	if [[ "$OPEN_PR_LOOKUP_FAIL" -eq 1 ]]; then
		return 1
	fi
	printf '%s' "$OPEN_PR_STATE"
	return 0
}

_stale_recovery_escalate() {
	local _issue_number="$1"
	local _repo_slug="$2"
	local _stale_assignees="$3"
	local _reason="$4"
	local _threshold="$5"
	local _prior_ticks="$6"
	: "$_issue_number" "$_repo_slug" "$_stale_assignees" "$_reason" "$_threshold" "$_prior_ticks"
	ESCALATED=1
	ESCALATION_REASON="$_reason"
	return 0
}

_stale_recovery_escalate_pr_checkpoint() {
	local _issue_number="$1"
	local _repo_slug="$2"
	local _stale_assignees="$3"
	local _reason="$4"
	local _pr_number="$5"
	local _dispatch_ts="$6"
	local _kind="$7"
	: "$_issue_number" "$_repo_slug" "$_stale_assignees" "$_dispatch_ts"
	ESCALATED=1
	ESCALATION_REASON="${_kind}:${_pr_number}:${_reason}"
	return 0
}

_stale_recovery_apply() {
	local _issue_number="$1"
	local _repo_slug="$2"
	local _stale_assignees="$3"
	local _reason="$4"
	: "$_issue_number" "$_repo_slug" "$_stale_assignees" "$_reason"
	RECOVERED=1
	return 0
}

COMMENTS_JSON='[[
  {"created_at":"2026-05-04T10:00:00Z","body":"<!-- stale-recovery-tick:1 -->\nStale recovery tick 1/2"},
  {"created_at":"2026-05-04T11:00:00Z","body":"<!-- stale-recovery-tick:2 -->\nStale recovery tick 2/2"},
  {"created_at":"2026-05-04T12:43:16Z","body":"DISPATCH_CLAIM nonce=fresh runner=runner ts=2026-05-04T12:43:16Z"},
  {"created_at":"2026-05-04T12:43:51Z","body":"Dispatching worker (deterministic).\n- **Worker PID**: 90285"}
]]'

_recover_stale_assignment 3978 owner/repo runner "dispatch claim 620s old, last activity 620s old (threshold=600s, interactive=false)"

if [[ "$ESCALATED" -eq 1 && "$RECOVERED" -eq 0 ]]; then
	pass "threshold escalation does not require a launcher terminal marker"
else
	fail "threshold escalation does not require a launcher terminal marker" "ESCALATED=${ESCALATED} RECOVERED=${RECOVERED}"
fi

ESCALATED=0
RECOVERED=0
ESCALATION_REASON=""
OPEN_PR_STATE="456|draft_checkpoint"
COMMENTS_JSON='[[
  {"created_at":"2026-05-04T12:43:16Z","body":"DISPATCH_CLAIM nonce=fresh runner=runner ts=2026-05-04T12:43:16Z"}
]]'

draft_output=""
draft_output=$(_recover_stale_assignment 3978 owner/repo runner "worker lease expired")

if [[ "$ESCALATED" -eq 0 && "$RECOVERED" -eq 0 && "$draft_output" == *"STALE_PR_CONTINUATION"* ]]; then
	pass "stale draft checkpoint requests exact-head continuation without competing redispatch"
else
	fail "stale draft checkpoint requests exact-head continuation without competing redispatch" \
		"ESCALATED=${ESCALATED} RECOVERED=${RECOVERED} output=${draft_output}"
fi

ESCALATED=0
RECOVERED=0
OPEN_PR_STATE=""
OPEN_PR_LOOKUP_FAIL=1

lookup_output=""
lookup_rc=0
lookup_output=$(_recover_stale_assignment 3978 owner/repo runner "worker lease expired") || lookup_rc=$?

if [[ "$lookup_rc" -ne 0 && "$ESCALATED" -eq 0 && "$RECOVERED" -eq 0 && "$lookup_output" == *"STALE_RECOVERY_UNCERTAIN"* ]]; then
	pass "open PR lookup uncertainty retains stale checkpoint ownership"
else
	fail "open PR lookup uncertainty retains stale checkpoint ownership" \
		"rc=${lookup_rc} ESCALATED=${ESCALATED} RECOVERED=${RECOVERED} output=${lookup_output}"
fi

OPEN_PR_LOOKUP_FAIL=0

ESCALATED=0
RECOVERED=0
OPEN_PR_STATE=""
COMMENTS_JSON='[[
  {"created_at":"2026-05-04T10:00:00Z","body":"<!-- stale-recovery-tick:1 -->\nStale recovery tick 1/2"},
  {"created_at":"2026-05-04T11:00:00Z","body":"<!-- stale-recovery-tick:2 -->\nStale recovery tick 2/2"},
  {"created_at":"2026-05-04T12:43:16Z","body":"DISPATCH_CLAIM nonce=fresh runner=runner ts=2026-05-04T12:43:16Z"},
  {"created_at":"2026-05-04T12:50:05Z","body":"## Worker Watchdog Kill\n\n**Reason:** Worker process became idle"}
]]'

_recover_stale_assignment 3978 owner/repo runner "dispatch claim 620s old, last activity 620s old (threshold=600s, interactive=false)"

if [[ "$ESCALATED" -eq 1 && "$RECOVERED" -eq 0 ]]; then
	pass "terminal evidence remains compatible with threshold escalation"
else
	fail "terminal evidence remains compatible with threshold escalation" "ESCALATED=${ESCALATED} RECOVERED=${RECOVERED}"
fi

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
