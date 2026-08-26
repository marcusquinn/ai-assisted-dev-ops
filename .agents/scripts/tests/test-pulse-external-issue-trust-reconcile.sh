#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
ACTIONS="${TEST_DIR}/../pulse-issue-reconcile-actions.sh"
ORCHESTRATOR="${TEST_DIR}/../pulse-issue-reconcile.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="$TEST_ROOT/pulse.log"
_PIR_SCRIPT_DIR="$TEST_ROOT"
_PIR_NMR_LABEL="needs-maintainer-review"
_PIR_ADD_LABEL_FLAG="--add-label"
_PIR_REMOVE_LABEL_FLAG="--remove-label"
_PIR_AUTO_DISPATCH_LABEL="auto-dispatch"
_PIR_STATUS_AVAILABLE="status:available"
_PIR_PERSISTENT_LABEL="persistent"
_PIR_TRIAGE_FAILED_LABEL="triage-failed"
AUTHORITY_RC=1
GH_EDIT_LOG="$TEST_ROOT/edit.log"
LIVE_ISSUE_JSON=""
LIVE_FALLBACK_LOG="$TEST_ROOT/live-fallback.log"
TESTS_RUN=0
TESTS_FAILED=0
: >"$LOGFILE"
: >"$GH_EDIT_LOG"
: >"$LIVE_FALLBACK_LOG"

# shellcheck source=../pulse-issue-reconcile-actions.sh
source "$ACTIONS"

_gh_actor_has_repo_write_authority() {
	local slug="$1"
	local login="$2"
	local association="$3"
	[[ -n "$slug" && -n "$association" ]] || return 2
	: "$login"
	return "$AUTHORITY_RC"
}

gh_issue_edit_safe() {
	printf '%s\n' "$*" >>"$GH_EDIT_LOG"
	return 0
}

gh() {
	local command="$1"
	shift
	if [[ "$command" == "api" ]]; then
		printf '%s\n' "api" >>"$LIVE_FALLBACK_LOG"
		printf '%s\n' "$LIVE_ISSUE_JSON"
		return 0
	fi
	return 127
}

write_approval() {
	local result="$1"
	printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '${result}'" >"$_PIR_SCRIPT_DIR/approval-helper.sh"
	chmod +x "$_PIR_SCRIPT_DIR/approval-helper.sh"
	return 0
}

record() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_live_author_metadata_fallback() {
	local rc=0

	write_approval NO_APPROVAL
	: >"$GH_EDIT_LOG"
	LIVE_ISSUE_JSON='{"author_association":"CONTRIBUTOR","user":{"login":"reporter","type":"User"}}'
	: >"$LIVE_FALLBACK_LOG"
	_action_reconcile_external_issue_gate owner/repo 28699 \
		"auto-dispatch,status:available" "" "" || rc=$?
	if [[ "$rc" -eq 0 && "$_PIR_EXTERNAL_GATE_MUTATED" -eq 1 \
		&& "$(grep -c '^api$' "$LIVE_FALLBACK_LOG")" -eq 1 ]] \
		&& grep -q -- '--add-label needs-maintainer-review' "$GH_EDIT_LOG"; then
		record "missing cached metadata falls back to live external author" 0
	else
		record "missing cached metadata falls back to live external author" 1
	fi

	LIVE_ISSUE_JSON='{}'
	: >"$LIVE_FALLBACK_LOG"
	PULSE_EXTERNAL_TRUST_FALLBACK_MAX=1
	_PIR_EXTERNAL_TRUST_FALLBACKS_USED=0
	_PIR_EXTERNAL_TRUST_FALLBACK_DIAGNOSTIC_SLUGS=""
	: >"$LOGFILE"
	_action_reconcile_external_issue_gate owner/repo 28698 "status:available" "" "" || rc=$?
	_action_reconcile_external_issue_gate owner/repo 28697 "status:available" "" "" || rc=$?
	if [[ "$(grep -c '^api$' "$LIVE_FALLBACK_LOG")" -eq 1 ]] \
		&& [[ "$(grep -c 'cache author metadata missing' "$LOGFILE")" -eq 1 ]] \
		&& grep -q 'response lacked author association' "$LOGFILE"; then
		record "missing live metadata is bounded and aggregated fail-closed" 0
	else
		record "missing live metadata is bounded and aggregated fail-closed" 1
	fi
	unset PULSE_EXTERNAL_TRUST_FALLBACK_MAX
	return 0
}

main() {
	local rc=0
	_should_reconcile_persistent_issue "persistent,source:health-dashboard" || rc=$?
	record "persistent issue is a non-task reconciliation candidate" "$rc"
	rc=0
	_should_reconcile_persistent_issue "status:available,origin:worker" || rc=$?
	[[ "$rc" -eq 1 ]] && record "ordinary task is not a persistent candidate" 0 \
		|| record "ordinary task is not a persistent candidate" 1

	: >"$GH_EDIT_LOG"
	rc=0
	_action_reconcile_persistent_issue_labels owner/repo 26416 \
		"persistent,needs-maintainer-review,triage-failed" || rc=$?
	if [[ "$rc" -eq 0 ]] \
		&& grep -q -- '--remove-label triage-failed' "$GH_EDIT_LOG" \
		&& ! grep -q -- '--remove-label needs-maintainer-review' "$GH_EDIT_LOG" \
		&& ! grep -q -- '--add-label' "$GH_EDIT_LOG"; then
		record "persistent issue drops triage residue without bypassing NMR" 0
	else
		record "persistent issue drops triage residue without bypassing NMR" 1
	fi

	rc=0
	_should_reconcile_external_issue_gate CONTRIBUTOR User false || rc=$?
	record "ordinary external issue is a trust candidate regardless of title" "$rc"
	rc=0
	_should_reconcile_external_issue_gate "" User false || rc=$?
	[[ "$rc" -eq 0 ]] && record "legacy metadata blocks lifecycle reconciliation" 0 \
		|| record "legacy metadata blocks lifecycle reconciliation" 1
	rc=0
	_should_reconcile_external_issue_gate MEMBER User false || rc=$?
	[[ "$rc" -eq 1 ]] && record "member metadata is skipped" 0 || record "member metadata is skipped" 1
	rc=0
	_should_reconcile_external_issue_gate NONE Bot true || rc=$?
	[[ "$rc" -eq 1 ]] && record "bot metadata is skipped" 0 || record "bot metadata is skipped" 1

	test_live_author_metadata_fallback

	AUTHORITY_RC=1
	: >"$GH_EDIT_LOG"
	rc=0
	_action_reconcile_external_issue_gate owner/repo 28700 \
		"auto-dispatch,status:available" CONTRIBUTOR reporter || rc=$?
	if [[ "$rc" -eq 0 && "$_PIR_EXTERNAL_GATE_MUTATED" -eq 1 ]] \
		&& grep -q -- '--add-label needs-maintainer-review' "$GH_EDIT_LOG" \
		&& grep -q -- '--remove-label auto-dispatch' "$GH_EDIT_LOG" \
		&& grep -q -- '--remove-label status:available' "$GH_EDIT_LOG"; then
		record "unapproved external issue is gated and dispatch labels are stripped" 0
	else
		record "unapproved external issue is gated and dispatch labels are stripped" 1
	fi

	write_approval VERIFIED
	: >"$GH_EDIT_LOG"
	rc=0
	_action_reconcile_external_issue_gate owner/repo 28700 "" CONTRIBUTOR reporter || rc=$?
	[[ "$rc" -eq 1 && ! -s "$GH_EDIT_LOG" ]] \
		&& record "verified external issue continues without mutation" 0 \
		|| record "verified external issue continues without mutation" 1

	write_approval NO_APPROVAL
	AUTHORITY_RC=0
	rc=0
	_action_reconcile_external_issue_gate owner/repo 28700 "" COLLABORATOR writer || rc=$?
	[[ "$rc" -eq 1 ]] && record "write-authorized collaborator continues" 0 \
		|| record "write-authorized collaborator continues" 1

	AUTHORITY_RC=2
	: >"$GH_EDIT_LOG"
	rc=0
	_action_reconcile_external_issue_gate owner/repo 29090 \
		"auto-dispatch,status:available" COLLABORATOR writer || rc=$?
	if [[ "$rc" -eq 0 && "$_PIR_EXTERNAL_GATE_MUTATED" -eq 0 && ! -s "$GH_EDIT_LOG" ]]; then
		record "unavailable collaborator lookup blocks without permanent NMR mutation" 0
	else
		record "unavailable collaborator lookup blocks without permanent NMR mutation" 1
	fi

	local stage_zero_line="" stage_one_line=""
	stage_zero_line=$(grep -n '# Stage 0a:' "$ORCHESTRATOR" | tail -1 | cut -d: -f1)
	stage_one_line=$(grep -n '# Stage 1:' "$ORCHESTRATOR" | tail -1 | cut -d: -f1)
	if [[ "$stage_zero_line" =~ ^[0-9]+$ && "$stage_one_line" =~ ^[0-9]+$ && "$stage_zero_line" -lt "$stage_one_line" ]]; then
		record "trust reconciliation runs before lifecycle actions" 0
	else
		record "trust reconciliation runs before lifecycle actions" 1
	fi

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
