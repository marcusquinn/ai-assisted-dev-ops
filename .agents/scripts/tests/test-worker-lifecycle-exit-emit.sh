#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-worker-lifecycle-exit-emit.sh — Regression test for t3055 / GH#21870
# =============================================================================
# Validates that `_dlw_spawn_lifecycle_observer` (in pulse-dispatch-worker-launch.sh)
# emits a `[lifecycle] worker_exited pid=N wait_status=...` line to the
# pulse log within a bounded window after the worker PID terminates —
# regardless of how the worker exits (normal, signal, immediate, vanish).
#
# Acceptance criteria from the issue:
#   - Every worker PID dispatched by dispatch_worker_launch has a
#     corresponding `worker_exited pid=N` line in pulse.log within 60s of
#     worker termination, independent of the worker's own emit path.
#
# What this test does:
#   1. Source pulse-dispatch-worker-launch.sh and stub out the heavy
#      dependencies that aren't relevant to the observer.
#   2. Launch a synthetic detached worker that immediately `exit 7`.
#   3. Call `_dlw_spawn_lifecycle_observer` against that PID with a
#      tight poll interval and short max-lifetime.
#   4. Wait up to 30s for the line to appear in the test logfile.
#   5. Assert the line shape carries pid=<numeric> and the kill_reason
#      sentinel `observer=parent`.
#
# Independence: this test does NOT spawn an LLM session, hit network,
# or exercise dispatch_with_dedup. It isolates the observer mechanic.
#
# Usage: bash tests/test-worker-lifecycle-exit-emit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TMPDIR_TEST=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TMPDIR_TEST=$(mktemp -d)
	unset AIDEVOPS_PULSE_EVENT_REFILL_ENABLED PULSE_EVENT_REFILL_HELPER \
		PULSE_EVENT_REFILL_TRIGGER_FILE PULSE_EVENT_REFILL_WRAPPER 2>/dev/null || true
	# We only need _dlw_spawn_lifecycle_observer; source the file selectively
	# by extracting the function. Sourcing the whole file pulls in the load
	# guard and all the helpers — which is fine for our purposes since
	# observer is a leaf helper with no internal dependencies on the rest.
	# We DO need to sidestep the load guard so multiple test invocations
	# in the same process don't see stale state.
	unset _PULSE_DISPATCH_WORKER_LAUNCH_LOADED 2>/dev/null || true
	# shellcheck source=../pulse-dispatch-worker-launch.sh
	# shellcheck disable=SC1091
	source "${AGENTS_SCRIPTS}/pulse-dispatch-worker-launch.sh"
	return 0
}

teardown() {
	[[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST" || true
	return 0
}

# Wait up to $1 seconds for $2 (regex) to appear in $3 (file).
# Returns 0 on match, 1 on timeout.
_wait_for_line() {
	local timeout_s="$1"
	local pattern="$2"
	local file="$3"
	local elapsed=0
	while [[ "$elapsed" -lt "$timeout_s" ]]; do
		if [[ -f "$file" ]] && grep -qE "$pattern" "$file" 2>/dev/null; then
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	return 1
}

# ---------------------------------------------------------------------------
# Tests

test_observer_emits_on_immediate_exit() {
	local logfile="${TMPDIR_TEST}/pulse-immediate.log"
	: >"$logfile"

	# Synthetic worker: launch a subshell that exits immediately with 7.
	# Use setsid so it mirrors the real detach behaviour. Capture the PID.
	local synth_pid
	if command -v setsid >/dev/null 2>&1; then
		setsid bash -c 'exit 7' </dev/null >/dev/null 2>&1 &
	else
		bash -c 'exit 7' </dev/null >/dev/null 2>&1 &
	fi
	synth_pid="$!"

	# Spawn the observer with a tight poll interval. Use the public env
	# vars so the observer's internal subshell sees them.
	export DLW_LIFECYCLE_OBSERVER_POLL_SECONDS=1
	export DLW_LIFECYCLE_OBSERVER_MAX_SECONDS=30

	_dlw_spawn_lifecycle_observer "$synth_pid" "99999" "$logfile"

	# Wait up to 30s for the line to appear.
	if _wait_for_line 30 "\\[lifecycle\\] worker_exited pid=${synth_pid}" "$logfile"; then
		print_result "observer emits worker_exited line for immediate-exit worker" 0
	else
		print_result "observer emits worker_exited line for immediate-exit worker" 1 \
			"no matching line in ${logfile} after 30s; tail:
$(tail -20 "$logfile" 2>/dev/null || echo '(empty)')"
	fi
	return 0
}

test_observer_line_carries_observer_marker() {
	# Same scenario; assert the kill_reason marker so consumers can
	# distinguish parent-side observer emits from the worker's own emit.
	local logfile="${TMPDIR_TEST}/pulse-marker.log"
	: >"$logfile"

	local synth_pid
	if command -v setsid >/dev/null 2>&1; then
		setsid bash -c 'exit 0' </dev/null >/dev/null 2>&1 &
	else
		bash -c 'exit 0' </dev/null >/dev/null 2>&1 &
	fi
	synth_pid="$!"

	export DLW_LIFECYCLE_OBSERVER_POLL_SECONDS=1
	export DLW_LIFECYCLE_OBSERVER_MAX_SECONDS=30

	_dlw_spawn_lifecycle_observer "$synth_pid" "12345" "$logfile" "attempt-observer-12345"

	if _wait_for_line 30 "worker_exited pid=${synth_pid}.*observer=parent.*issue=12345.*attempt_id=attempt-observer-12345" "$logfile"; then
		print_result "observer line carries parent, issue, and attempt identity fields" 0
	else
		print_result "observer line carries parent, issue, and attempt identity fields" 1 \
			"line shape mismatch in ${logfile}; tail:
$(tail -20 "$logfile" 2>/dev/null || echo '(empty)')"
	fi
	return 0
}

test_observer_skips_invalid_pid() {
	# Defensive: caller bug or test fixture passes a non-numeric PID.
	# Observer must early-return without writing to the log.
	local logfile="${TMPDIR_TEST}/pulse-invalid.log"
	: >"$logfile"

	_dlw_spawn_lifecycle_observer "not-a-pid" "1" "$logfile"
	# Give any rogue subshell a moment to misbehave.
	sleep 2

	if [[ ! -s "$logfile" ]]; then
		print_result "observer skips non-numeric PID without writing" 0
	else
		print_result "observer skips non-numeric PID without writing" 1 \
			"unexpected log content:
$(cat "$logfile")"
	fi
	return 0
}

test_observer_skips_empty_logfile_arg() {
	# Defensive: missing logfile path. Observer must early-return.
	# We cannot easily assert "nothing was written" because there is no
	# logfile to inspect — but we CAN assert the call returns 0 cleanly
	# without throwing.
	local rc=0
	_dlw_spawn_lifecycle_observer "12345" "1" "" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "observer skips empty logfile arg cleanly" 0
	else
		print_result "observer skips empty logfile arg cleanly" 1 \
			"non-zero return: $rc"
	fi
	return 0
}

test_observer_signals_event_refill() {
	local logfile="${TMPDIR_TEST}/pulse-refill.log"
	local capture_file="${TMPDIR_TEST}/refill-signal.log"
	local fake_helper="${TMPDIR_TEST}/pulse-event-refill.sh"
	: >"$logfile"
	cat >"$fake_helper" <<'HELPER'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${AIDEVOPS_PULSE_EVENT_REFILL_ENABLED:-}" >>"${REFILL_CAPTURE_FILE}"
HELPER
	chmod +x "$fake_helper"
	export REFILL_CAPTURE_FILE="$capture_file"
	export AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=1
	PULSE_EVENT_REFILL_HELPER="$fake_helper"
	PULSE_EVENT_REFILL_TRIGGER_FILE="${TMPDIR_TEST}/refill.trigger"
	PULSE_EVENT_REFILL_WRAPPER="${TMPDIR_TEST}/pulse-wrapper.sh"

	local synth_pid
	bash -c 'exit 0' </dev/null >/dev/null 2>&1 &
	synth_pid="$!"
	export DLW_LIFECYCLE_OBSERVER_POLL_SECONDS=1
	export DLW_LIFECYCLE_OBSERVER_MAX_SECONDS=30
	_dlw_spawn_lifecycle_observer "$synth_pid" "54321" "$logfile"

	if _wait_for_line 30 "signal\\|54321\\|${synth_pid}\\|1" "$capture_file"; then
		print_result "observer requests event refill after worker termination" 0
	else
		print_result "observer requests event refill after worker termination" 1 \
			"no refill signal captured for worker ${synth_pid}"
	fi
	unset AIDEVOPS_PULSE_EVENT_REFILL_ENABLED PULSE_EVENT_REFILL_HELPER \
		PULSE_EVENT_REFILL_TRIGGER_FILE PULSE_EVENT_REFILL_WRAPPER REFILL_CAPTURE_FILE
	return 0
}

test_prelaunch_lifecycle_formatter_carries_attempt_identity() {
	local logfile="${TMPDIR_TEST}/prelaunch-lifecycle.log"
	local output=""
	: >"$logfile"
	_dlw_append_lifecycle_log "$logfile" "attempt-prelaunch-123" \
		"dispatcher_prelaunch_lease_renew_start session=issue-123 pid=456"
	output=$(<"$logfile")
	if [[ "$output" == *"[lifecycle] dispatcher_prelaunch_lease_renew_start"* &&
		"$output" == *" ts="* && "$output" == *" attempt_id=attempt-prelaunch-123"* ]]; then
		print_result "prelaunch lifecycle formatter carries timestamp and attempt identity" 0
	else
		print_result "prelaunch lifecycle formatter carries timestamp and attempt identity" 1 \
			"output=${output:-<empty>}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main

main() {
	setup
	trap teardown EXIT

	test_observer_emits_on_immediate_exit
	test_observer_line_carries_observer_marker
	test_observer_skips_invalid_pid
	test_observer_skips_empty_logfile_arg
	test_observer_signals_event_refill
	test_prelaunch_lifecycle_formatter_carries_attempt_identity

	echo
	echo "Tests run: ${TESTS_RUN}, passed: ${TESTS_PASSED}, failed: ${TESTS_FAILED}"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
