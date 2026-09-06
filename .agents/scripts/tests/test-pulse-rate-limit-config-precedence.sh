#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="${TMP_DIR}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache"
TESTS_RUN=0

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

assert_value() {
	local actual="$1"
	local expected="$2"
	local label="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	[[ "$actual" == "$expected" ]] || fail "${label}: expected ${expected}, got ${actual}"
	return 0
}

clear_rate_limit_config() {
	unset AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD
	unset AIDEVOPS_PULSE_REST_CORE_RESERVE
	unset AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR
	unset AIDEVOPS_PULSE_REST_CORE_IN_FLIGHT_ALLOWANCE
	unset AIDEVOPS_PULSE_REST_CORE_ADAPTIVE_WINDOW_SECONDS
	unset AIDEVOPS_PULSE_REST_CORE_PROBE_TTL
	unset AIDEVOPS_PULSE_REST_CORE_GATE_PROBE_TTL
	unset AIDEVOPS_GH_READ_TIMEOUT
	unset AIDEVOPS_GH_WRITE_TIMEOUT
	unset NO_WORK_WINDOW_SECS
	unset NO_WORK_WINDOW_MAX
	unset PULSE_EVENTS_TICKLE_ENABLED
	unset PULSE_BATCH_SEARCH_LAST_RESORT
	unset AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN
	unset AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN
	return 0
}

assert_production_defaults() {
	local label="$1"
	assert_value "$AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD" "0.05" "${label} GraphQL threshold"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_RESERVE" "500" "${label} REST reserve"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR" "0" "${label} REST hard floor"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_IN_FLIGHT_ALLOWANCE" "0" "${label} in-flight allowance"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_ADAPTIVE_WINDOW_SECONDS" "3600" "${label} adaptive window"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_PROBE_TTL" "20" "${label} probe TTL"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_GATE_PROBE_TTL" "2" "${label} gate probe TTL"
	assert_value "$AIDEVOPS_GH_READ_TIMEOUT" "15" "${label} read timeout"
	assert_value "$AIDEVOPS_GH_WRITE_TIMEOUT" "45" "${label} write timeout"
	assert_value "$NO_WORK_WINDOW_SECS" "600" "${label} no-work window"
	assert_value "$NO_WORK_WINDOW_MAX" "10" "${label} no-work maximum"
	assert_value "$PULSE_EVENTS_TICKLE_ENABLED" "1" "${label} events tickle"
	assert_value "$PULSE_BATCH_SEARCH_LAST_RESORT" "1" "${label} batch search mode"
	assert_value "$AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN" "50" "${label} Actions queue minimum"
	assert_value "$AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN" "10" "${label} Actions queue ratio"
	return 0
}

set_explicit_overrides() {
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD=0
	export AIDEVOPS_PULSE_REST_CORE_RESERVE=5000
	export AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR=4999
	export AIDEVOPS_PULSE_REST_CORE_IN_FLIGHT_ALLOWANCE=1
	export AIDEVOPS_PULSE_REST_CORE_ADAPTIVE_WINDOW_SECONDS=17
	export AIDEVOPS_PULSE_REST_CORE_PROBE_TTL=19
	export AIDEVOPS_PULSE_REST_CORE_GATE_PROBE_TTL=1
	export AIDEVOPS_GH_READ_TIMEOUT=91
	export AIDEVOPS_GH_WRITE_TIMEOUT=92
	export NO_WORK_WINDOW_SECS=601
	export NO_WORK_WINDOW_MAX=11
	export PULSE_EVENTS_TICKLE_ENABLED=0
	export PULSE_BATCH_SEARCH_LAST_RESORT=0
	export AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN=51
	export AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN=12
	return 0
}

assert_explicit_overrides() {
	local label="$1"
	assert_value "$AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD" "0" "${label} GraphQL threshold"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_RESERVE" "5000" "${label} REST reserve"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR" "4999" "${label} REST hard floor"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_IN_FLIGHT_ALLOWANCE" "1" "${label} in-flight allowance"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_ADAPTIVE_WINDOW_SECONDS" "17" "${label} adaptive window"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_PROBE_TTL" "19" "${label} probe TTL"
	assert_value "$AIDEVOPS_PULSE_REST_CORE_GATE_PROBE_TTL" "1" "${label} gate probe TTL"
	assert_value "$AIDEVOPS_GH_READ_TIMEOUT" "91" "${label} read timeout"
	assert_value "$AIDEVOPS_GH_WRITE_TIMEOUT" "92" "${label} write timeout"
	assert_value "$NO_WORK_WINDOW_SECS" "601" "${label} no-work window"
	assert_value "$NO_WORK_WINDOW_MAX" "11" "${label} no-work maximum"
	assert_value "$PULSE_EVENTS_TICKLE_ENABLED" "0" "${label} events tickle"
	assert_value "$PULSE_BATCH_SEARCH_LAST_RESORT" "0" "${label} batch search mode"
	assert_value "$AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN" "51" "${label} Actions queue minimum"
	assert_value "$AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN" "12" "${label} Actions queue ratio"
	return 0
}

clear_rate_limit_config
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/shared-gh-wrappers.sh"
assert_production_defaults "shared GitHub wrapper first"

set_explicit_overrides
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/pulse-rate-limit-circuit-breaker.sh"
assert_explicit_overrides "circuit breaker after shared wrapper"

unset AIDEVOPS_GH_WRITE_TIMEOUT
config_get() {
	local key="$1"
	local fallback="$2"
	printf '%s\n' "$fallback"
	return 0
}
_validate_int() {
	local name="$1"
	local value="$2"
	printf '%s\n' "$value"
	return 0
}
unset _PULSE_WRAPPER_CONFIG_LOADED
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/pulse-wrapper-config.sh"
assert_value "$AIDEVOPS_GH_WRITE_TIMEOUT" "45" "Pulse wrapper fills missing write timeout"
assert_value "$AIDEVOPS_GH_READ_TIMEOUT" "91" "Pulse wrapper retains read timeout"
assert_value "$AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR" "4999" "Pulse wrapper retains hard floor"

printf 'PASS: %s Pulse rate-limit config precedence assertions\n' "$TESTS_RUN"
