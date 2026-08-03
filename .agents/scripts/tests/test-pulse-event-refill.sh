#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for coalesced, lock-safe Pulse event refill (GH#29448).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
APPLY_CALLS=0
APPLY_SLOT_TARGET=0
APPLY_RC=0
WRITE_TRIGGER_DURING_APPLY=0
GITHUB_AVAILABLE=1
GRAPHQL_AVAILABLE=1
NO_WORK_ACCEPTABLE=1

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

pass() {
	local test_name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$test_name"
	return 0
}

fail() {
	local test_name="$1"
	local message="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n  %s\n' "$test_name" "$message"
	return 0
}

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "expected=${expected}, actual=${actual}"
	fi
	return 0
}

assert_file_exists() {
	local test_name="$1"
	local file="$2"
	if [[ -f "$file" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "expected file to exist: ${file}"
	fi
	return 0
}

assert_file_absent() {
	local test_name="$1"
	local file="$2"
	if [[ ! -e "$file" ]]; then
		pass "$test_name"
	else
		fail "$test_name" "expected file to be absent: ${file}"
	fi
	return 0
}

reset_state() {
	rm -rf "${TEST_ROOT:?}/home"
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/cache" "${HOME}/.aidevops/logs"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	STOP_FLAG="${HOME}/.aidevops/logs/pulse-session.stop"
	PULSE_EVENT_REFILL_TRIGGER_FILE="${HOME}/.aidevops/cache/pulse-event-refill.trigger"
	PULSE_EVENT_REFILL_MAX_PASSES=2
	PULSE_EVENT_REFILL_WAKE_PASSES=2
	PULSE_EVENT_REFILL_WAIT_SECONDS=0
	PULSE_EVENT_REFILL_POLL_SECONDS=1
	export AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=1
	APPLY_CALLS=0
	APPLY_SLOT_TARGET=0
	APPLY_RC=0
	WRITE_TRIGGER_DURING_APPLY=0
	GITHUB_AVAILABLE=1
	GRAPHQL_AVAILABLE=1
	NO_WORK_ACCEPTABLE=1
	return 0
}

# shellcheck source=../pulse-event-refill.sh
source "${SCRIPTS_DIR}/pulse-event-refill.sh"

pulse_event_refill_github_available() {
	[[ "$GITHUB_AVAILABLE" -eq 1 ]]
	return $?
}

is_graphql_budget_sufficient() {
	[[ "$GRAPHQL_AVAILABLE" -eq 1 ]]
	return $?
}

is_no_work_rate_acceptable() {
	[[ "$NO_WORK_ACCEPTABLE" -eq 1 ]]
	return $?
}

pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"${HOME}/.aidevops/logs/counters.log"
	return 0
}

apply_dispatch_max() {
	APPLY_CALLS=$((APPLY_CALLS + 1))
	printf 'call=%s slots=%s\n' "$APPLY_CALLS" "$APPLY_SLOT_TARGET" >>"${HOME}/.aidevops/logs/apply.log"
	if [[ "$WRITE_TRIGGER_DURING_APPLY" -eq 1 && "$APPLY_CALLS" -eq 1 ]]; then
		pulse_event_refill_write_trigger 202 2202
	fi
	return "$APPLY_RC"
}

test_mode_parser() {
	reset_state
	unset PULSE_REFILL_ONLY PULSE_REFILL_SOURCE 2>/dev/null || true
	_pulse_setup_refill_only_mode --unrelated --refill-only --refill-source=worker-exit
	assert_eq "refill-only parser enables lightweight mode" "1" "${PULSE_REFILL_ONLY:-0}"
	assert_eq "refill-only parser records a safe source" "worker-exit" "${PULSE_REFILL_SOURCE:-}"
	return 0
}

test_coalesced_trigger_fills_full_target() {
	reset_state
	APPLY_SLOT_TARGET=7
	pulse_event_refill_write_trigger 101 1101
	pulse_event_refill_write_trigger 102 1102
	pulse_event_refill_drain "test"
	assert_eq "coalesced exits invoke one full-capacity dispatch pass" "1" "$APPLY_CALLS"
	assert_file_absent "successful refill consumes the presence trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	if grep -q 'slots=7' "${HOME}/.aidevops/logs/apply.log"; then
		pass "event refill delegates the complete slot target to apply_dispatch_max"
	else
		fail "event refill delegates the complete slot target to apply_dispatch_max" "slot target was not observed"
	fi
	return 0
}

test_event_during_drain_gets_second_pass() {
	reset_state
	WRITE_TRIGGER_DURING_APPLY=1
	pulse_event_refill_write_trigger 201 2201
	pulse_event_refill_drain "test-race"
	assert_eq "an exit arriving during refill gets a bounded second pass" "2" "$APPLY_CALLS"
	assert_file_absent "second-pass refill leaves no consumed trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_stop_and_circuits_retain_trigger() {
	reset_state
	pulse_event_refill_write_trigger 301 3301
	: >"$STOP_FLAG"
	pulse_event_refill_drain "test-stop"
	assert_eq "stop flag prevents event dispatch" "0" "$APPLY_CALLS"
	assert_file_exists "stop flag retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"

	reset_state
	GITHUB_AVAILABLE=0
	pulse_event_refill_write_trigger 302 3302
	pulse_event_refill_drain "test-github"
	assert_file_exists "GitHub outage retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"

	reset_state
	GRAPHQL_AVAILABLE=0
	pulse_event_refill_write_trigger 303 3303
	pulse_event_refill_drain "test-graphql"
	assert_file_exists "GraphQL circuit breaker retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"

	reset_state
	NO_WORK_ACCEPTABLE=0
	pulse_event_refill_write_trigger 304 3304
	pulse_event_refill_drain "test-no-work"
	assert_file_exists "no-work circuit breaker retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_disabled_and_missing_dispatch_retain_trigger() {
	reset_state
	export AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=0
	pulse_event_refill_write_trigger 401 4401
	pulse_event_refill_drain "test-disabled"
	assert_eq "disabled event refill does not dispatch" "0" "$APPLY_CALLS"
	assert_file_exists "disabled event refill retains its trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"

	reset_state
	pulse_event_refill_write_trigger 402 4402
	(
		unset -f apply_dispatch_max
		pulse_event_refill_drain "test-missing-dispatch"
	)
	assert_file_exists "missing dispatch function retains its trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_processing_recovery_and_busy_lock() {
	reset_state
	local processing_file="${PULSE_EVENT_REFILL_TRIGGER_FILE}.processing.99999"
	printf 'stale\n' >"$processing_file"
	pulse_event_refill_recover_processing
	assert_file_exists "stale processing state is restored to the trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	assert_file_absent "stale processing file is consumed during recovery" "$processing_file"

	(
		acquire_instance_lock() {
			return 1
		}
		_pulse_run_refill_only
	)
	assert_file_exists "busy instance lock retains refill evidence" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_wrapper_refill_only_cli_short_circuit() {
	reset_state
	export AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=0
	pulse_event_refill_write_trigger 450 4450
	local cli_log="${TEST_ROOT}/refill-cli.log"
	local cli_rc=0
	HOME="$HOME" \
		AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=0 \
		AIDEVOPS_PULSE_RUNTIME_PIN_FILE="${TEST_ROOT}/missing-runtime-pin.conf" \
		PULSE_EVENT_REFILL_TRIGGER_FILE="$PULSE_EVENT_REFILL_TRIGGER_FILE" \
		PULSE_JITTER_MAX=30 \
		PULSE_MODEL="test/model" \
		bash "${SCRIPTS_DIR}/pulse-wrapper.sh" --refill-only --refill-source=integration \
		>"$cli_log" 2>&1 || cli_rc=$?
	assert_eq "wrapper accepts refill-only without entering the full cycle" "0" "$cli_rc"
	assert_file_exists "disabled refill-only CLI retains the pending trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	assert_file_absent "refill-only disabled path does not acquire the Pulse lock" "${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
	return 0
}

test_signal_wake_coalesces_parallel_exits() {
	reset_state
	local fake_wrapper="${TEST_ROOT}/fake-pulse-wrapper.sh"
	local wake_log="${TEST_ROOT}/wake.log"
	cat >"$fake_wrapper" <<'WRAPPER'
#!/usr/bin/env bash
# Supports --refill-only for the mixed-version compatibility probe.
printf '%s\n' "$*" >>"$PULSE_EVENT_TEST_WAKE_LOG"
sleep 1
rm -f "$PULSE_EVENT_REFILL_TRIGGER_FILE"
WRAPPER
	chmod +x "$fake_wrapper"
	export PULSE_EVENT_TEST_WAKE_LOG="$wake_log"
	PULSE_EVENT_REFILL_WRAPPER="$fake_wrapper"
	PULSE_EVENT_REFILL_WAKE_PASSES=1
	(pulse_event_refill_signal 501 5501) &
	local first_signal_pid=$!
	sleep 0.2
	(pulse_event_refill_signal 502 5502) &
	local second_signal_pid=$!
	wait "$first_signal_pid"
	wait "$second_signal_pid"
	local wake_count=0
	wake_count=$(wc -l <"$wake_log" 2>/dev/null | tr -d ' ') || wake_count=0
	assert_eq "parallel worker exits coalesce to one wrapper wake" "1" "$wake_count"
	assert_file_absent "coalesced wake consumes the shared trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

test_stale_wake_lock_is_reclaimed() {
	reset_state
	local fake_wrapper="${TEST_ROOT}/fake-stale-wake-wrapper.sh"
	local wake_log="${TEST_ROOT}/stale-wake.log"
	local wake_lock="${PULSE_EVENT_REFILL_TRIGGER_FILE}.wake.lock"
	cat >"$fake_wrapper" <<'WRAPPER'
#!/usr/bin/env bash
# Supports --refill-only for the mixed-version compatibility probe.
printf '%s\n' "$*" >>"$PULSE_EVENT_TEST_WAKE_LOG"
rm -f "$PULSE_EVENT_REFILL_TRIGGER_FILE"
WRAPPER
	chmod +x "$fake_wrapper"
	export PULSE_EVENT_TEST_WAKE_LOG="$wake_log"
	PULSE_EVENT_REFILL_WRAPPER="$fake_wrapper"
	PULSE_EVENT_REFILL_WAKE_PASSES=1
	mkdir "$wake_lock"
	printf '99999999:stale\n' >"${wake_lock}/pid"
	pulse_event_refill_write_trigger 601 6601
	pulse_event_refill_signal 602 6602
	local wake_count=0
	wake_count=$(wc -l <"$wake_log" 2>/dev/null | tr -d ' ') || wake_count=0
	assert_eq "stale wake ownership does not suppress the next refill" "1" "$wake_count"
	assert_file_absent "stale wake lock is reclaimed and released" "$wake_lock"
	assert_file_absent "reclaimed wake consumes the pending trigger" "$PULSE_EVENT_REFILL_TRIGGER_FILE"
	return 0
}

main() {
	test_mode_parser
	test_coalesced_trigger_fills_full_target
	test_event_during_drain_gets_second_pass
	test_stop_and_circuits_retain_trigger
	test_disabled_and_missing_dispatch_retain_trigger
	test_processing_recovery_and_busy_lock
	test_wrapper_refill_only_cli_short_circuit
	test_signal_wake_coalesces_parallel_exits
	test_stale_wake_lock_is_reclaimed
	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
