#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for pulse-wrapper.sh --dry-run bootstrap hang (GH#22091).
#
# Purpose: Verify that --dry-run exits quickly without timing out due to
# repeated sourcing of pulse-stats-helper.sh during bootstrap.
#
# Root cause: pulse-stats-helper.sh lacked an include guard and was sourced
# by pulse-merge-stuck.sh, pulse-rate-limit-circuit-breaker.sh,
# pre-dispatch-eligibility-helper.sh, and pulse-dispatch-engine.sh. Each
# source re-ran the SCRIPT_DIR subprocess and shared-constants.sh include,
# stacking enough overhead to cause 120s-300s timeouts before reaching the
# dry-run short-circuit at pulse-wrapper.sh::_pulse_run_cycle.
#
# Fix: Added idempotent include guard to pulse-stats-helper.sh:27 following
# the pattern at pulse-cleanup.sh:47-49.
#
# What is exercised:
#   1. pulse-wrapper.sh --dry-run completes within TIMEOUT seconds
#   2. The dry-run output line confirms the expected short-circuit fired
#   3. Static check: include guard exists in pulse-stats-helper.sh
#   4. Static check: dry-run short-circuit exists in pulse-wrapper.sh
#   5. Static check: supervisor circuit-breaker refresh remains wired
#   6. Static check: idle backoff's available-work bypass remains wired
#
# What is NOT exercised:
#   - GitHub API calls (no network)
#   - Actual worker dispatch
#   - fix-the-fixer detector (AIDEVOPS_SKIP_FIX_THE_FIXER_DETECTOR=1)
#   - Cache priming (AIDEVOPS_SKIP_CACHE_PRIME=1)
#   - Runaway log check (AIDEVOPS_SKIP_RUNAWAY_LOG_CHECK=1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"
CYCLE_GATES_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper-cycle-gates.sh"
STATS_HELPER="${SCRIPT_DIR}/../pulse-stats-helper.sh"
DEFAULTS_SOURCE="${SCRIPT_DIR}/../../configs/aidevops.defaults.jsonc"

# Timeout for the --dry-run invocation. The pre-fix hang required >120s; the
# fix should complete in under 30s even on slow CI machines.
readonly DRY_RUN_TIMEOUT=30

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

# Seed a sandbox HOME with the canonical aidevops defaults config so
# pulse-wrapper-bootstrap.sh::_load_config succeeds.
# Mirrors the seed_sandbox_config() pattern in test-pulse-wrapper-canary.sh.
seed_sandbox_config() {
	local sandbox_home="$1"
	mkdir -p "${sandbox_home}/.aidevops/agents/configs"
	if [[ -f "$DEFAULTS_SOURCE" ]]; then
		cp "$DEFAULTS_SOURCE" \
			"${sandbox_home}/.aidevops/agents/configs/aidevops.defaults.jsonc"
	fi
	return 0
}

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Test 1: --dry-run exits 0 within DRY_RUN_TIMEOUT seconds.
#
# Pre-fix: timed out at 120s-300s due to repeated pulse-stats-helper.sh sourcing.
# Post-fix: exits in <5s because the include guard prevents repeated init.
#
# Uses env vars to skip optional slow paths that are not part of the
# bootstrap overhead being tested here.
test_dry_run_exits_zero_quickly() {
	local sandbox rc output elapsed start_ts
	sandbox=$(mktemp -d)
	mkdir -p "${sandbox}/home"
	seed_sandbox_config "${sandbox}/home"

	start_ts=$(date +%s 2>/dev/null) || start_ts=0
	output=$(
		HOME="${sandbox}/home" \
			FULL_LOOP_HEADLESS=1 \
			AIDEVOPS_SUPERVISOR_PULSE=true \
			AIDEVOPS_SKIP_FIX_THE_FIXER_DETECTOR=1 \
			AIDEVOPS_SKIP_CACHE_PRIME=1 \
			AIDEVOPS_SKIP_RUNAWAY_LOG_CHECK=1 \
			timeout "$DRY_RUN_TIMEOUT" bash "$WRAPPER_SCRIPT" --dry-run 2>&1
	)
	rc=$?
	local end_ts
	end_ts=$(date +%s 2>/dev/null) || end_ts=0
	elapsed=$(( end_ts - start_ts ))
	rm -rf "$sandbox"

	if [[ "$rc" -eq 0 ]]; then
		print_result "--dry-run exits 0 within ${DRY_RUN_TIMEOUT}s (took ${elapsed}s)" 0
		return 0
	fi
	# timeout exits 124; distinguish from other failures
	local reason="exit $rc"
	if [[ "$rc" -eq 124 ]]; then
		reason="timed out after ${DRY_RUN_TIMEOUT}s (bootstrap hang — include guard missing?)"
	fi
	print_result "--dry-run exits 0 within ${DRY_RUN_TIMEOUT}s (took ${elapsed}s)" 1 \
		"Expected exit 0, got ${reason}. Output: ${output}"
	return 0
}

# Test 2: --dry-run prints the expected short-circuit confirmation line.
#
# If the include guard accidentally breaks the dry-run path, this catches it.
test_dry_run_prints_ok_line() {
	local sandbox rc output
	sandbox=$(mktemp -d)
	mkdir -p "${sandbox}/home"
	seed_sandbox_config "${sandbox}/home"

	output=$(
		HOME="${sandbox}/home" \
			FULL_LOOP_HEADLESS=1 \
			AIDEVOPS_SUPERVISOR_PULSE=true \
			AIDEVOPS_SKIP_FIX_THE_FIXER_DETECTOR=1 \
			AIDEVOPS_SKIP_CACHE_PRIME=1 \
			AIDEVOPS_SKIP_RUNAWAY_LOG_CHECK=1 \
			timeout "$DRY_RUN_TIMEOUT" bash "$WRAPPER_SCRIPT" --dry-run 2>&1
	)
	rc=$?
	rm -rf "$sandbox"

	if printf '%s' "$output" | grep -q "^dry-run: ok"; then
		print_result "--dry-run prints 'dry-run: ok' confirmation line" 0
		return 0
	fi
	print_result "--dry-run prints 'dry-run: ok' confirmation line" 1 \
		"Expected line starting with 'dry-run: ok'. Exit $rc. Output: ${output}"
	return 0
}

# Test 3: Static check — include guard exists in pulse-stats-helper.sh.
#
# Ensures the fix that prevents the bootstrap hang is not accidentally removed
# during future refactoring.
test_include_guard_present() {
	if grep -q "_PULSE_STATS_HELPER_LOADED" "$STATS_HELPER"; then
		print_result "include guard _PULSE_STATS_HELPER_LOADED present in pulse-stats-helper.sh" 0
		return 0
	fi
	print_result "include guard _PULSE_STATS_HELPER_LOADED present in pulse-stats-helper.sh" 1 \
		"Include guard not found in $STATS_HELPER — bootstrap hang will recur"
	return 0
}

# Test 4: Static check — dry-run short-circuit exists in pulse-wrapper.sh.
#
# Guards against the short-circuit being accidentally removed, which would
# make the script run the full dispatch loop in dry-run mode.
test_dry_run_short_circuit_present() {
	if grep -q 'PULSE_DRY_RUN' "$WRAPPER_SCRIPT"; then
		print_result "PULSE_DRY_RUN short-circuit present in pulse-wrapper.sh" 0
		return 0
	fi
	print_result "PULSE_DRY_RUN short-circuit present in pulse-wrapper.sh" 1 \
		"PULSE_DRY_RUN not found in $WRAPPER_SCRIPT"
	return 0
}

# Test 5: Static check — pulse refreshes overdue supervisor circuit breaker.
#
# Guards GH#22631: a normal pulse cycle must invoke circuit-breaker-helper.sh
# check so overdue cooldowns reset without manual operator action.
test_supervisor_circuit_breaker_refresh_present() {
	if grep -q '_pulse_refresh_supervisor_circuit_breaker' "$WRAPPER_SCRIPT" && \
		grep -q 'circuit-breaker-helper.sh' "$WRAPPER_SCRIPT"; then
		print_result "supervisor circuit breaker refresh present in pulse-wrapper.sh" 0
		return 0
	fi
	print_result "supervisor circuit breaker refresh present in pulse-wrapper.sh" 1 \
		"Expected _pulse_refresh_supervisor_circuit_breaker and circuit-breaker-helper.sh reference in $WRAPPER_SCRIPT"
	return 0
}

# Test 6: A pending event-refill trigger remains inert during --dry-run.
test_dry_run_skips_event_refill() {
	local sandbox rc output trigger_file pulse_log
	sandbox=$(mktemp -d)
	mkdir -p "${sandbox}/home/.aidevops/cache" "${sandbox}/home/.aidevops/logs"
	seed_sandbox_config "${sandbox}/home"
	trigger_file="${sandbox}/home/.aidevops/cache/pulse-event-refill.trigger"
	pulse_log="${sandbox}/home/.aidevops/logs/pulse.log"
	printf 'issue=1 worker_pid=1 ts=test\n' >"$trigger_file"

	output=$(
		HOME="${sandbox}/home" \
			FULL_LOOP_HEADLESS=1 \
			AIDEVOPS_SUPERVISOR_PULSE=true \
			AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=0 \
			AIDEVOPS_SKIP_FIX_THE_FIXER_DETECTOR=1 \
			AIDEVOPS_SKIP_CACHE_PRIME=1 \
			AIDEVOPS_SKIP_RUNAWAY_LOG_CHECK=1 \
			timeout "$DRY_RUN_TIMEOUT" bash "$WRAPPER_SCRIPT" --dry-run 2>&1
	)
	rc=$?
	if [[ "$rc" -eq 0 && -f "$trigger_file" ]] && \
		! grep -q 'source=cycle-entry' "$pulse_log" 2>/dev/null; then
		print_result "--dry-run does not drain pending event-refill triggers" 0
	else
		print_result "--dry-run does not drain pending event-refill triggers" 1 \
			"Expected an inert retained trigger, got exit ${rc}. Output: ${output}"
	fi
	rm -rf "$sandbox"
	return 0
}

# Test 7: Static check — idle backoff observes eligible auto-dispatch work.
test_idle_backoff_available_work_bypass_present() {
	if grep -q 'pulse-wrapper-cycle-gates.sh' "$WRAPPER_SCRIPT" &&
		grep -q '_pulse_available_auto_dispatch_work_exists' "$CYCLE_GATES_SCRIPT" &&
		grep -q 'AIDEVOPS_PULSE_IDLE_AVAILABLE_WORK' "$CYCLE_GATES_SCRIPT"; then
		print_result "idle backoff available-work bypass present in pulse cycle gates" 0
		return 0
	fi
	print_result "idle backoff available-work bypass present in pulse cycle gates" 1 \
		"Expected wrapper source plus available-work check and env bridge in $CYCLE_GATES_SCRIPT"
	return 0
}

main_test() {
	test_dry_run_exits_zero_quickly
	test_dry_run_prints_ok_line
	test_include_guard_present
	test_dry_run_short_circuit_present
	test_supervisor_circuit_breaker_refresh_present
	test_dry_run_skips_event_refill
	test_idle_backoff_available_work_bypass_present

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
