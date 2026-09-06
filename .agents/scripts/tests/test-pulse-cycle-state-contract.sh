#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d -t pulse-cycle-state.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
	printf 'FAIL %s %s\n' "$name" "$detail"
	return 0
}

assert_health() {
	local name="$1"
	local filter="$2"
	if jq -e "$filter" "$PULSE_HEALTH_FILE" >/dev/null; then
		pass "$name"
	else
		fail "$name" "health=$(jq -c . "$PULSE_HEALTH_FILE" 2>/dev/null || printf malformed)"
	fi
	return 0
}

export HOME="${TMP_DIR}/home"
export SCRIPT_DIR="$SOURCE_DIR"
export AIDEVOPS_DISPATCH_LEDGER_DIR="$TMP_DIR"
export AIDEVOPS_DISPATCH_LEDGER_FILE="${TMP_DIR}/dispatch-ledger.jsonl"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/tmp"

PULSE_HEALTH_FILE="${HOME}/.aidevops/logs/pulse-health.json"
PULSE_CYCLE_INDEX_FILE="${HOME}/.aidevops/logs/pulse-cycle-index.jsonl"
PULSE_CYCLE_INDEX_MAX_LINES=100
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
HEADLESS_RUNTIME_HELPER="${TMP_DIR}/missing-headless-runtime-helper"
_PULSE_HEALTH_PRS_MERGED=0
_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=0
_PULSE_HEALTH_STALLED_KILLED=0
_PULSE_HEALTH_PREFETCH_ERRORS=0
_PULSE_HEALTH_IDLE_REPO_SKIPS=0
_PULSE_HEALTH_BATCH_SEARCH_CALLS=0
_PULSE_HEALTH_BATCH_CACHE_HITS=0
_PULSE_HEALTH_EVENTS_TICKLE_FRESH=0
_PULSE_HEALTH_EVENTS_TICKLE_STALE=0
_PULSE_HEALTH_CONDITIONAL_304=0
_PULSE_HEALTH_CONDITIONAL_REFRESHES=0
_PULSE_HEALTH_CONDITIONAL_MISSES=0
_PULSE_HEALTH_PREFETCH_THROTTLED=0
_PULSE_HEALTH_IDLE_CYCLE_SKIPPED=0

count_active_workers() {
	printf '0\n'
	return 0
}

get_max_workers_target() {
	printf '4\n'
	return 0
}

# shellcheck source=../pulse-logging.sh
source "${SOURCE_DIR}/pulse-logging.sh"
# shellcheck source=../pulse-wrapper-cycle-gates.sh
source "${SOURCE_DIR}/pulse-wrapper-cycle-gates.sh"

_LOCK_OWNED=false
acquire_instance_lock() {
	_LOCK_OWNED=true
	return 0
}
release_instance_lock() {
	_LOCK_OWNED=false
	return 0
}

_pulse_cycle_state_start
write_pulse_health_file
assert_health "real health writer emits additive running lifecycle state" '
	.timestamp != null
	and .workers_active == 0
	and .workers_max == 4
	and .prs_merged_this_cycle == 0
	and .cycle_state.schema == "aidevops.pulse-cycle-state/v1"
	and .cycle_state.phase == "admitted"
	and .cycle_state.outcome == "running"
	and .cycle_state.progress.last_at == null
	and .cycle_state.progress.consecutive_no_progress_cycles == 0
	and .cycle_state.blocker.kind == "none"
'

initial_heartbeat=$(jq -r '.cycle_state.heartbeat_at' "$PULSE_HEALTH_FILE")
initial_progress=$(jq -c '.cycle_state.progress' "$PULSE_HEALTH_FILE")
sleep 1
_pulse_cycle_state_publish preflight
if [[ "$(jq -c '.cycle_state.progress' "$PULSE_HEALTH_FILE")" == "$initial_progress" \
	&& "$(jq -r '.cycle_state.heartbeat_at' "$PULSE_HEALTH_FILE")" > "$initial_heartbeat" ]]; then
	pass "heartbeat-only transition advances liveness without changing progress"
else
	fail "heartbeat-only transition advances liveness without changing progress"
fi

dispatch_before=$(_pulse_capture_dispatch_total)
printf '%s\n' '{"lease_phase":"prelaunch","dispatched_at":"2026-01-01T00:00:00Z"}' \
	>"$AIDEVOPS_DISPATCH_LEDGER_FILE"
_pulse_record_cycle_outcome "$dispatch_before"
_pulse_cycle_state_write_terminal_if_current
assert_health "actual dispatch registration produces typed progress" '
	.cycle_state.phase == "completed"
	and .cycle_state.outcome == "progressed"
	and .cycle_state.progress.kinds == ["worker-dispatched"]
	and .cycle_state.progress.last_at != null
	and .cycle_state.progress.consecutive_no_progress_cycles == 0
	and .cycle_state.blocker.kind == "none"
'
if [[ "${_PULSE_LEGACY_CYCLE_OUTCOME_PENDING:-1}" -eq 0 ]]; then
	pass "current terminal publication commits the legacy outcome once"
else
	fail "current terminal publication commits the legacy outcome once"
fi
last_progress_at=$(jq -r '.cycle_state.progress.last_at' "$PULSE_HEALTH_FILE")

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_note_blocker review-gate owner/repo 7
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "first typed blocker starts both no-progress streaks" '
	.cycle_state.outcome == "blocked"
	and .cycle_state.progress.consecutive_no_progress_cycles == 1
	and .cycle_state.blocker.kind == "review-gate"
	and .cycle_state.blocker.consecutive_same_cycles == 1
'
first_fingerprint=$(jq -r '.cycle_state.blocker.fingerprint' "$PULSE_HEALTH_FILE")
if [[ "$first_fingerprint" != *"owner/repo"* && "$first_fingerprint" != *"#7"* ]]; then
	pass "blocker fingerprint does not expose source coordinates"
else
	fail "blocker fingerprint does not expose source coordinates"
fi

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_note_blocker review-gate owner/repo 7
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "repeated blocker increments stable streak without moving progress" "
	.cycle_state.progress.last_at == \"${last_progress_at}\"
	and .cycle_state.progress.consecutive_no_progress_cycles == 2
	and .cycle_state.blocker.consecutive_same_cycles == 2
"

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_note_blocker head-changed owner/repo 7
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "changed blocker restarts only blocker streak" '
	.cycle_state.progress.consecutive_no_progress_cycles == 3
	and .cycle_state.blocker.kind == "head-changed"
	and .cycle_state.blocker.consecutive_same_cycles == 1
'

_pulse_cycle_state_start
write_pulse_health_file
_PULSE_HEALTH_PRS_MERGED=1
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "meaningful progress resets blocker and no-progress streaks" '
	.cycle_state.outcome == "progressed"
	and .cycle_state.progress.kinds == ["pr-merged"]
	and .cycle_state.progress.consecutive_no_progress_cycles == 0
	and .cycle_state.blocker.kind == "none"
	and .cycle_state.blocker.consecutive_same_cycles == 0
'

cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-failed-write.json"
mv() {
	return 1
}
write_pulse_health_file
unset -f mv
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-failed-write.json"; then
	pass "failed atomic rename preserves the last valid health record"
else
	fail "failed atomic rename preserves the last valid health record"
fi

consumer_output="${TMP_DIR}/consumer.json"
python3 "${SOURCE_DIR}/pulse-current-state.py" \
	"${HOME}/.aidevops/logs" "$PWD" 900 1 "$SOURCE_DIR" "${TMP_DIR}/review-state" \
	>"$consumer_output"
if jq -e '
	.cycle_state.availability == "available"
	and .cycle_state.schema == "aidevops.pulse-cycle-state/v1"
	and .cycle_state.outcome == "progressed"
	and .cycle_state.progress.kinds == ["pr-merged"]
' "$consumer_output" >/dev/null; then
	pass "production consumer accepts the real producer output"
else
	fail "production consumer accepts the real producer output"
fi

# Exercise the real budget producer through terminal publication and the reader.
# Statistics are intentionally absent: lifecycle evidence must not depend on them.
# shellcheck source=../pulse-budget-priority.sh
source "${SOURCE_DIR}/pulse-budget-priority.sh"
_PULSE_HEALTH_PRS_MERGED=0
_pulse_cycle_state_start
write_pulse_health_file
AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS=emergency
_pulse_defer_budget_priority_stage dispatch_max
_pulse_record_cycle_outcome 1
_pulse_cycle_state_write_terminal_if_current
assert_health "quota-deferred progress is blocked rather than idle" '
	.cycle_state.outcome == "blocked"
	and .cycle_state.blocker.kind == "rest-core-quota"
'
python3 "${SOURCE_DIR}/pulse-current-state.py" \
	"${HOME}/.aidevops/logs" "$PWD" 900 1 "$SOURCE_DIR" "${TMP_DIR}/review-state" \
	>"$consumer_output"
if jq -e '.cycle_state.availability == "available" and .cycle_state.blocker.kind == "rest-core-quota"' "$consumer_output" >/dev/null; then
	pass "production consumer accepts quota blocker"
else
	fail "production consumer accepts quota blocker"
fi

if [[ ! -e "${HOME}/.aidevops/logs/pulse-cycle-state.json" ]]; then
	pass "lifecycle state does not create a parallel runtime artifact"
else
	fail "lifecycle state does not create a parallel runtime artifact"
fi

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_finalize idle '[]'
_PULSE_LEGACY_CYCLE_OUTCOME_PENDING=1
cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-missing-lock-terminal.json"
unset -f acquire_instance_lock release_instance_lock
_pulse_cycle_state_write_terminal_if_current
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-missing-lock-terminal.json" \
	&& [[ "$_PULSE_LEGACY_CYCLE_OUTCOME_PENDING" -eq 1 ]]; then
	pass "terminal publication fails closed when lock functions are unavailable"
else
	fail "terminal publication fails closed when lock functions are unavailable"
fi

_pulse_cycle_state_start
write_pulse_health_file
_pulse_cycle_state_finalize idle '[]'
_PULSE_LEGACY_CYCLE_OUTCOME_PENDING=1
LOCK_ACQUIRE_CALLS=0
LOCK_RELEASE_CALLS=0
_LOCK_OWNED=false
acquire_instance_lock() {
	LOCK_ACQUIRE_CALLS=$((LOCK_ACQUIRE_CALLS + 1))
	_LOCK_OWNED=true
	return 0
}
release_instance_lock() {
	LOCK_RELEASE_CALLS=$((LOCK_RELEASE_CALLS + 1))
	_LOCK_OWNED=false
	return 0
}
jq '.cycle_state.cycle_id = "newer-cycle"' "$PULSE_HEALTH_FILE" >"${TMP_DIR}/newer-health.json"
mv "${TMP_DIR}/newer-health.json" "$PULSE_HEALTH_FILE"
cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-stale-terminal.json"
_pulse_cycle_state_write_terminal_if_current
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-stale-terminal.json" \
	&& [[ "$LOCK_ACQUIRE_CALLS" -eq 1 && "$LOCK_RELEASE_CALLS" -eq 1 \
		&& "$_LOCK_OWNED" == "false" \
		&& "$_PULSE_LEGACY_CYCLE_OUTCOME_PENDING" -eq 1 ]]; then
	pass "older terminal publication cannot overwrite newer cycle health"
else
	fail "older terminal publication cannot overwrite newer cycle health"
fi

: >"$AIDEVOPS_DISPATCH_LEDGER_FILE"
_PULSE_HEALTH_PRS_MERGED=0
_pulse_cycle_state_start
write_pulse_health_file
child_cleanup_cycle_id="$_PULSE_CYCLE_ID"
cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-child-cleanup.json"
_LOCK_OWNED=true
(
	trap '_pulse_cycle_state_finish_interrupted' EXIT
)
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-child-cleanup.json" \
	&& [[ "$_PULSE_CYCLE_STATE_TERMINAL" -eq 0 ]] \
	&& jq -e --arg cycle_id "$child_cleanup_cycle_id" '
		.cycle_state.cycle_id == $cycle_id
		and .cycle_state.phase == "admitted"
		and .cycle_state.outcome == "running"
	' "$PULSE_HEALTH_FILE" >/dev/null; then
	pass "child EXIT cleanup cannot publish terminal state for the live owner"
else
	fail "child EXIT cleanup cannot publish terminal state for the live owner"
fi

cp "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-child-terminal-write.json"
(
	_PULSE_CYCLE_STATE_TERMINAL=1
	_PULSE_CYCLE_PHASE="completed"
	_PULSE_CYCLE_OUTCOME="interrupted"
	write_pulse_health_file
)
if cmp -s "$PULSE_HEALTH_FILE" "${TMP_DIR}/health-before-child-terminal-write.json"; then
	pass "child executor cannot directly publish inherited terminal health"
else
	fail "child executor cannot directly publish inherited terminal health"
fi

post_label_dispatch_before=$(_pulse_capture_dispatch_total)
printf '{"session_key":"post-label-test","status":"in-flight","pid":%s,"lease_phase":"prelaunch","dispatched_at":"2026-01-01T00:00:00Z"}\n' \
	"$$" >"$AIDEVOPS_DISPATCH_LEDGER_FILE"
_pulse_record_cycle_outcome "$post_label_dispatch_before"
_pulse_cycle_state_write_terminal_if_current
assert_health "owner finalization records successful post-label dispatch" '
	.issues_dispatched == 1
	and .cycle_state.phase == "completed"
	and .cycle_state.outcome == "progressed"
	and .cycle_state.progress.kinds == ["worker-dispatched"]
'

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
