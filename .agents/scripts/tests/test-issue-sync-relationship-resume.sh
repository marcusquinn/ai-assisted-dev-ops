#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
TMP_DIR=$(mktemp -d)

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

export AIDEVOPS_RELATIONSHIP_STATE_DIR="${TMP_DIR}/state"
TODO_FILE="${TMP_DIR}/TODO.md"
ATTEMPT_LOG="${TMP_DIR}/attempts.log"
DEADLINE_FLAG="${TMP_DIR}/deadline"
BATCH_LIMIT=40
BLOCKED_MODE="success"

# shellcheck source=../issue-sync-helper.sh
source "${SCRIPTS_DIR}/issue-sync-helper.sh"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

_init_cmd() {
	_CMD_REPO="${TEST_REPO:-example/repo}"
	_CMD_TODO="$TODO_FILE"
	return 0
}

_relationship_deadline_expired() {
	[[ -f "$DEADLINE_FLAG" ]]
	return $?
}

_sync_blocked_by_for_task() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	: "$todo_file" "$repo"
	printf '%s\n' "$task_id" >>"$ATTEMPT_LOG"
	case "$BLOCKED_MODE" in
	success)
		_gh_with_timeout read true >/dev/null
		printf 'RELS:0 RETRYABLE:0\n'
		;;
	retry) printf 'RELS:0 RETRYABLE:1\n' ;;
	error) return 1 ;;
	*) return 1 ;;
	esac
	return 0
}

_sync_subtask_hierarchy_for_task() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	local attempt_count=0
	: "$task_id" "$todo_file" "$repo"
	attempt_count=$(wc -l <"$ATTEMPT_LOG" | tr -d '[:space:]')
	if [[ "$attempt_count" -ge "$BATCH_LIMIT" ]]; then
		: >"$DEADLINE_FLAG"
	fi
	printf 'RELS:0 RETRYABLE:0\n'
	return 0
}

: >"$TODO_FILE"
for ((task_number = 1; task_number <= 800; task_number++)); do
	printf -- '- [ ] t%d Task %d blocked-by:t900 ref:GH#%d\n' \
		"$task_number" "$task_number" "$task_number" >>"$TODO_FILE"
done
: >"$ATTEMPT_LOG"

first_rc=0
first_output=$(run_relationship_scoped_command cmd_relationships 2>/dev/null) || first_rc=$?
state_file=$(_relationship_resume_state_file "example/repo")
first_pending=$(grep -c '^pending=' "$state_file" || true)
[[ "$first_rc" -eq 1 ]] || fail "bounded first pass did not remain retryable"
[[ "$(wc -l <"$ATTEMPT_LOG" | tr -d '[:space:]')" -eq 40 ]] || fail "first pass exceeded its task budget"
[[ "$first_pending" -eq 760 ]] || fail "first pass did not persist 760 remaining tasks"
[[ "$first_output" == *"attempted=40 complete=40/800"* ]] || fail "first pass omitted completion telemetry"
[[ "$first_output" == *"resume=fresh"* && "$first_output" == *"Backend calls: 40"* ]] || fail "first pass omitted resume or backend-call telemetry"
if [[ "${AIDEVOPS_BENCHMARK_OUTPUT:-0}" == "1" ]]; then
	printf '%s\n' "$first_output"
fi
pass "800-task reconciliation persists bounded first-pass progress"

: >"$ATTEMPT_LOG"
rm -f "$DEADLINE_FLAG"
BATCH_LIMIT=25
second_rc=0
second_output=$(run_relationship_scoped_command cmd_relationships 2>/dev/null) || second_rc=$?
second_pending=$(grep -c '^pending=' "$state_file" || true)
first_resumed_task=""
IFS= read -r first_resumed_task <"$ATTEMPT_LOG"
[[ "$second_rc" -eq 1 ]] || fail "bounded resumed pass did not remain retryable"
[[ "$first_resumed_task" == "t41" ]] || fail "second pass restarted instead of resuming at t41"
[[ "$second_pending" -eq 735 ]] || fail "second pass did not advance durable progress"
[[ "$second_output" == *"candidates=800 resume=resumed pending_before=760 remaining=735"* ]] || fail "second pass omitted resumed progress telemetry"
pass "unchanged inputs resume only the persisted remaining workset"

printf -- '- [ ] t801 Added task blocked-by:t900 ref:GH#801\n' >>"$TODO_FILE"
: >"$ATTEMPT_LOG"
rm -f "$DEADLINE_FLAG"
BATCH_LIMIT=1
changed_rc=0
changed_output=$(run_relationship_scoped_command cmd_relationships 2>/dev/null) || changed_rc=$?
IFS= read -r first_changed_task <"$ATTEMPT_LOG"
[[ "$changed_rc" -eq 1 ]] || fail "changed-input pass did not remain retryable"
[[ "$first_changed_task" == "t1" ]] || fail "changed TODO input did not invalidate stale progress"
[[ "$changed_output" == *"candidates=801 resume=invalidated"* ]] || fail "changed-input pass omitted invalidation telemetry"
pass "relationship input changes invalidate stale persisted progress"

TEST_REPO="example/small"
: >"$TODO_FILE"
for task_number in 1 2 3; do
	printf -- '- [ ] t%d Small task blocked-by:t9 ref:GH#%d\n' \
		"$task_number" "$task_number" >>"$TODO_FILE"
done
: >"$ATTEMPT_LOG"
rm -f "$DEADLINE_FLAG"
BATCH_LIMIT=100
small_output=$(run_relationship_scoped_command cmd_relationships 2>/dev/null) || fail "small workset did not complete"
small_state=$(_relationship_resume_state_file "example/small")
[[ "$(wc -l <"$ATTEMPT_LOG" | tr -d '[:space:]')" -eq 3 ]] || fail "small workset did not process each task exactly once"
[[ ! -e "$small_state" ]] || fail "completed small workset retained stale progress"
[[ "$small_output" == *"attempted=3 complete=3/3"* && "$small_output" == *"remaining=0"* ]] || fail "small workset summary regressed"
pass "small relationship worksets retain single-pass correctness"

# A declared dependency that cannot resolve stays pending even with zero
# backend calls. A helper error uses the same canonical retry classification.
for BLOCKED_MODE in retry error; do
	TEST_REPO="example/${BLOCKED_MODE}"
	printf -- '- [ ] t1 Unresolved task blocked-by:t9 ref:GH#1\n' >"$TODO_FILE"
	: >"$ATTEMPT_LOG"
	rm -f "$DEADLINE_FLAG"
	BATCH_LIMIT=100
	unresolved_rc=0
	unresolved_output=$(run_relationship_scoped_command cmd_relationships 2>/dev/null) || unresolved_rc=$?
	unresolved_state=$(_relationship_resume_state_file "$TEST_REPO")
	[[ "$unresolved_rc" -eq 1 ]] || fail "${BLOCKED_MODE} relationship result was counted complete"
	[[ "$(grep -c '^pending=' "$unresolved_state" || true)" -eq 1 ]] || fail "${BLOCKED_MODE} relationship result was not retained in pending state"
	[[ "$unresolved_output" == *"attempted=1 complete=0/1"* ]] || fail "${BLOCKED_MODE} summary omitted incomplete task telemetry"
	[[ "$unresolved_output" == *"Backend calls: 0"* ]] || fail "${BLOCKED_MODE} retry unexpectedly made a backend call"
done
pass "unresolved and errored relationship work remain pending without backend calls"

printf 'PASS: resumable relationship reconciliation regressions\n'
