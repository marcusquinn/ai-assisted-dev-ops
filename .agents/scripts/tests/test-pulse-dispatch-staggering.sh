#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-dispatch-staggering.sh — t3482 adaptive launch staggering tests.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/headless-runtime"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export STOP_FLAG="${HOME}/.aidevops/logs/stop"
: >"$LOGFILE"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"

reset_stagger_env() {
	export PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING=5000
	export PULSE_DISPATCH_STAGGER_RECENT_FAILURES=0
	export PULSE_DISPATCH_STAGGER_RECENT_RATE_LIMITS=0
	export PULSE_DISPATCH_STAGGER_LOAD_PER_CPU=0.5
	export PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE=0
	export PULSE_DISPATCH_STAGGER_JITTER_MAX_SECONDS=0
	export PULSE_DISPATCH_STAGGER_MAX_SECONDS=20
	unset AIDEVOPS_PULSE_DISPATCH_RAMP_ENABLED AIDEVOPS_PULSE_DISPATCH_RAMP_NOW AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH AIDEVOPS_PULSE_DISPATCH_RAMP_PHASE AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS AIDEVOPS_PULSE_DISPATCH_RAMP_BOOT_SECS AIDEVOPS_PULSE_DISPATCH_RAMP_RECOVERY_SECS AIDEVOPS_GH_READ_RAMP_BOOT_SECS AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS
	return 0
}

delay_for_candidate() {
	local issue_number="$1"
	_dispatch_inter_launch_delay 1 2 "{\"number\":${issue_number}}" 8
	return 0
}

test_clean_cycle_no_delay() {
	reset_stagger_env
	local delay
	delay=$(delay_for_candidate 100)
	if [[ "$delay" == "0" ]]; then
		print_result "staggering: clean cycle has no delay" 0
	else
		print_result "staggering: clean cycle has no delay" 1 "delay=${delay}"
	fi
	return 0
}

test_high_load_is_advisory_only() {
	reset_stagger_env
	export PULSE_DISPATCH_STAGGER_LOAD_PER_CPU=9.0
	local delay
	delay=$(delay_for_candidate 101)
	if [[ "$delay" == "0" ]]; then
		print_result "staggering: high load alone adds no delay" 0
	else
		print_result "staggering: high load alone adds no delay" 1 "delay=${delay}"
	fi
	return 0
}

test_provider_backoff_delay() {
	reset_stagger_env
	export PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE=1
	local delay
	delay=$(delay_for_candidate 102)
	if [[ "$delay" -gt 0 ]]; then
		print_result "staggering: provider backoff increases delay" 0
	else
		print_result "staggering: provider backoff increases delay" 1 "delay=${delay}"
	fi
	return 0
}

test_recent_failure_cluster_delay() {
	reset_stagger_env
	export PULSE_DISPATCH_STAGGER_RECENT_FAILURES=3
	local delay
	delay=$(delay_for_candidate 103)
	if [[ "$delay" -gt 0 ]]; then
		print_result "staggering: recent failure cluster increases delay" 0
	else
		print_result "staggering: recent failure cluster increases delay" 1 "delay=${delay}"
	fi
	return 0
}

test_graphql_low_budget_delay() {
	reset_stagger_env
	export PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING=900
	local delay
	delay=$(delay_for_candidate 104)
	if [[ "$delay" -gt 0 ]]; then
		print_result "staggering: low GraphQL budget increases delay" 0
	else
		print_result "staggering: low GraphQL budget increases delay" 1 "delay=${delay}"
	fi
	return 0
}

test_first_launch_never_delayed() {
	reset_stagger_env
	export PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE=1
	local delay
	delay=$(_dispatch_inter_launch_delay 0 1 '{"number":105}' 8)
	if [[ "$delay" == "0" ]]; then
		print_result "staggering: first launch remains immediate" 0
	else
		print_result "staggering: first launch remains immediate" 1 "delay=${delay}"
	fi
	return 0
}

test_dispatch_ramp_limits_initial_capacity() {
	reset_stagger_env
	export AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH=1000
	export AIDEVOPS_PULSE_DISPATCH_RAMP_NOW=1000
	export AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS=120
	local capped
	capped=$(_dispatch_apply_startup_capacity_ramp 8 0)
	if [[ "$capped" == "1" ]]; then
		print_result "dispatch ramp: initial startup capacity is one worker" 0
	else
		print_result "dispatch ramp: initial startup capacity is one worker" 1 "cap=${capped}"
	fi
	return 0
}

test_dispatch_ramp_adds_one_slot_per_pulse_interval() {
	reset_stagger_env
	export AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH=1000
	export AIDEVOPS_PULSE_DISPATCH_RAMP_NOW=1240
	export AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS=120
	local capped
	capped=$(_dispatch_apply_startup_capacity_ramp 8 0)
	if [[ "$capped" == "3" ]]; then
		print_result "dispatch ramp: adds one slot per two-minute pulse" 0
	else
		print_result "dispatch ramp: adds one slot per two-minute pulse" 1 "cap=${capped}"
	fi
	return 0
}

test_dispatch_ramp_never_exceeds_max_capacity() {
	reset_stagger_env
	export AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH=1000
	export AIDEVOPS_PULSE_DISPATCH_RAMP_NOW=4000
	export AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS=120
	local capped
	capped=$(_dispatch_apply_startup_capacity_ramp 6 0)
	if [[ "$capped" == "6" ]]; then
		print_result "dispatch ramp: stops at max concurrency" 0
	else
		print_result "dispatch ramp: stops at max concurrency" 1 "cap=${capped}"
	fi
	return 0
}

test_dispatch_ramp_can_be_disabled() {
	reset_stagger_env
	export AIDEVOPS_PULSE_DISPATCH_RAMP_ENABLED=0
	export AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH=1000
	export AIDEVOPS_PULSE_DISPATCH_RAMP_NOW=1000
	local capped
	capped=$(_dispatch_apply_startup_capacity_ramp 8 0)
	if [[ "$capped" == "8" ]]; then
		print_result "dispatch ramp: feature flag disables capacity cap" 0
	else
		print_result "dispatch ramp: feature flag disables capacity cap" 1 "cap=${capped}"
	fi
	return 0
}

test_dispatch_ramp_uses_precomputed_boot_timestamp() {
	reset_stagger_env
	export AIDEVOPS_PULSE_DISPATCH_RAMP_NOW=1100
	export AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS=120
	local capped
	capped=$(_dispatch_apply_startup_capacity_ramp 8 0 1000)
	if [[ "$capped" == "1" ]]; then
		print_result "dispatch ramp: accepts precomputed boot timestamp" 0
	else
		print_result "dispatch ramp: accepts precomputed boot timestamp" 1 "cap=${capped}"
	fi
	return 0
}

test_dispatch_ramp_uses_precomputed_cooldown_expiry() {
	reset_stagger_env
	export AIDEVOPS_PULSE_DISPATCH_RAMP_BOOT_SECS=0
	export AIDEVOPS_PULSE_DISPATCH_RAMP_NOW=1120
	export AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS=120
	local capped
	capped=$(_dispatch_apply_startup_capacity_ramp 8 0 "" 1000)
	if [[ "$capped" == "2" ]]; then
		print_result "dispatch ramp: accepts precomputed cooldown expiry" 0
	else
		print_result "dispatch ramp: accepts precomputed cooldown expiry" 1 "cap=${capped}"
	fi
	return 0
}

test_dispatch_ramp_handles_unset_logfile() {
	reset_stagger_env
	export AIDEVOPS_PULSE_DISPATCH_RAMP_NOW=1000
	export AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS=120
	local old_logfile="${LOGFILE:-}"
	local capped
	unset LOGFILE
	capped=$(_dispatch_apply_startup_capacity_ramp 8 0 1000)
	export LOGFILE="$old_logfile"
	if [[ "$capped" == "1" ]]; then
		print_result "dispatch ramp: unset LOGFILE falls back to dev null" 0
	else
		print_result "dispatch ramp: unset LOGFILE falls back to dev null" 1 "cap=${capped}"
	fi
	return 0
}

test_clean_cycle_no_delay
test_high_load_is_advisory_only
test_provider_backoff_delay
test_recent_failure_cluster_delay
test_graphql_low_budget_delay
test_first_launch_never_delayed
test_dispatch_ramp_limits_initial_capacity
test_dispatch_ramp_adds_one_slot_per_pulse_interval
test_dispatch_ramp_never_exceeds_max_capacity
test_dispatch_ramp_can_be_disabled
test_dispatch_ramp_uses_precomputed_boot_timestamp
test_dispatch_ramp_uses_precomputed_cooldown_expiry
test_dispatch_ramp_handles_unset_logfile

echo ""
echo "===================="
echo "Tests run: $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"
echo "===================="
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
else
	exit 1
fi
