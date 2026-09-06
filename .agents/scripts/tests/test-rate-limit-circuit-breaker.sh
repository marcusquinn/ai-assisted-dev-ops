#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-rate-limit-circuit-breaker.sh — t2690 / GH#20310 regression guard.
#
# Asserts the pulse-level GraphQL rate-limit circuit breaker:
#   1. Trips when remaining <= threshold (e.g. 4/5000 at 5% threshold)
#   2. Does NOT trip when remaining > threshold (e.g. 1000/5000)
#   3. GraphQL API errors fail open only after authoritative REST evidence allows
#   4. Emergency bypass via AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1
#   5. GraphQL floor disabled when threshold=0 while REST safety remains active
#   6. Status output includes correct state
#   7. Custom threshold works (e.g. 10% = 500/5000)
#   8. Stats counter increments on trip
#
# Stub strategy: define `gh` as a shell function. Shell functions take
# precedence over PATH binaries, so the stub captures all `gh` invocations
# without PATH mutation. STUB_GH_REMAINING controls the remaining value;
# STUB_GH_FAIL=1 simulates API failure.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2690.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export LOGFILE="${TMP}/test-pulse.log"
export HOME="${TMP}/home"
export AIDEVOPS_GH_REQUEST_STATE_DIR="${TMP}/request-state"
mkdir -p "${HOME}/.aidevops/logs"

# Stub pulse-stats-helper.sh — track counter increments.
STATS_COUNTER_FILE="${TMP}/stats-counter.log"
GH_RATE_CALLS="${TMP}/rate-calls.log"
GH_REST_CALLS="${TMP}/rest-calls.log"
export GH_RATE_CALLS GH_REST_CALLS
pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}
pulse_stats_get_24h() {
	local counter_name="$1"
	if [[ -f "$STATS_COUNTER_FILE" ]]; then
		grep -c "^${counter_name}$" "$STATS_COUNTER_FILE" 2>/dev/null || printf '0\n'
	else
		printf '0\n'
	fi
	return 0
}
export -f pulse_stats_increment pulse_stats_get_24h

# Configurable stub behaviour per test via env vars:
#   STUB_GH_REMAINING — GraphQL remaining value (default 5000)
#   STUB_GH_LIMIT     — GraphQL limit value (default 5000)
#   STUB_GH_CORE_REMAINING — REST core remaining value (unset omits core budget)
#   STUB_GH_CORE_RESET — REST core reset epoch (default: now+3600)
#   STUB_GH_RESET     — GraphQL reset epoch (default: now+3600)
#   STUB_GH_FAIL      — 1 to make all gh API probes fail
#   STUB_GH_RATE_FAIL — 1 to make only gh api rate_limit fail
#   STUB_GH_RATE_JSON — raw gh api rate_limit response override
gh() {
	if [[ "$1" == "api" && "$2" == "-i" && "$3" == "user" ]]; then
		printf 'rest-core\n' >>"$GH_REST_CALLS"
		if [[ "${STUB_GH_FAIL:-0}" == "1" ]]; then
			return 1
		fi
		# Omitted core state simulates an unavailable authoritative probe so the
		# legacy GraphQL-only breaker cases remain independent of REST fallback.
		[[ -n "${STUB_GH_CORE_REMAINING:-}" ]] || return 0
		local core_remaining="$STUB_GH_CORE_REMAINING"
		local core_limit="${STUB_GH_CORE_LIMIT:-5000}"
		local core_reset="${STUB_GH_CORE_RESET:-$(($(date +%s) + 3600))}"
		printf 'HTTP/2 200\nx-ratelimit-resource: core\nx-ratelimit-remaining: %s\nx-ratelimit-limit: %s\nx-ratelimit-reset: %s\n\n{}\n' \
			"$core_remaining" "$core_limit" "$core_reset"
		return 0
	fi
	if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
		printf 'rate-limit\n' >>"$GH_RATE_CALLS"
		[[ "${STUB_GH_DELAY:-0}" == "0" ]] || sleep "$STUB_GH_DELAY"
		if [[ "${STUB_GH_FAIL:-0}" == "1" || "${STUB_GH_RATE_FAIL:-0}" == "1" ]]; then
			return 1
		fi
		if [[ -n "${STUB_GH_RATE_JSON:-}" ]]; then
			printf '%s\n' "$STUB_GH_RATE_JSON"
			return 0
		fi
		local remaining="${STUB_GH_REMAINING:-5000}"
		local limit="${STUB_GH_LIMIT:-5000}"
		local core_json=""
		if [[ -n "${STUB_GH_CORE_REMAINING:-}" ]]; then
			core_json=",\"core\":{\"remaining\":${STUB_GH_CORE_REMAINING},\"limit\":${STUB_GH_CORE_LIMIT:-5000}}"
		fi
		local reset="${STUB_GH_RESET:-$(($(date +%s) + 3600))}"
		# Handle --jq flag for direct extraction
		if [[ "${3:-}" == "--jq" ]]; then
			local jq_expr="${4:-}"
			if [[ "$jq_expr" == ".resources.graphql.remaining" ]]; then
				printf '%s\n' "$remaining"
				return 0
			fi
		fi
		# Full JSON response
		printf '{"resources":{"graphql":{"remaining":%s,"limit":%s,"reset":%s}%s}}\n' \
			"$remaining" "$limit" "$reset" "$core_json"
		return 0
	fi
	# Default: succeed silently for unknown calls
	return 0
}
export -f gh

# Source the circuit breaker helper.
# shellcheck source=../pulse-rate-limit-circuit-breaker.sh
source "${SCRIPTS_DIR}/pulse-rate-limit-circuit-breaker.sh"
# shellcheck source=../shared-gh-wrappers-rest-fallback.sh
source "${SCRIPTS_DIR}/shared-gh-wrappers-rest-fallback.sh"

# Re-override pulse_stats_* AFTER sourcing — the circuit breaker sources
# the real pulse-stats-helper.sh which replaces our capturing stubs.
# shellcheck disable=SC2317
pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}
# shellcheck disable=SC2317
pulse_stats_get_24h() {
	local counter_name="$1"
	if [[ -f "$STATS_COUNTER_FILE" ]]; then
		grep -c "^${counter_name}$" "$STATS_COUNTER_FILE" 2>/dev/null || printf '0\n'
	else
		printf '0\n'
	fi
	return 0
}

# =============================================================================
# Reset test state between tests
# =============================================================================
reset_test_state() {
	: >"$LOGFILE"
	: >"$STATS_COUNTER_FILE"
	: >"$GH_RATE_CALLS"
	: >"$GH_REST_CALLS"
	rm -f "${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state"
	rm -f "${HOME}/.aidevops/cache/pulse-graphql-rate-limit.json"
	rm -f "${HOME}/.aidevops/cache/pulse-rest-core.json"
	rm -f "${HOME}/.aidevops/cache/pulse-rest-core-unknown.state"
	unset AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER 2>/dev/null || true
	unset AIDEVOPS_PULSE_RATE_LIMIT_CACHE_TTL 2>/dev/null || true
	unset AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK 2>/dev/null || true
	unset AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK_ACTIVE 2>/dev/null || true
	unset AIDEVOPS_GH_FORCE_REST_READS 2>/dev/null || true
	unset STUB_GH_CORE_REMAINING 2>/dev/null || true
	unset STUB_GH_CORE_LIMIT 2>/dev/null || true
	unset STUB_GH_CORE_RESET 2>/dev/null || true
	unset STUB_GH_FAIL 2>/dev/null || true
	unset STUB_GH_RATE_FAIL 2>/dev/null || true
	unset STUB_GH_RATE_JSON 2>/dev/null || true
	unset STUB_GH_DELAY 2>/dev/null || true
	STUB_GH_REMAINING=5000
	STUB_GH_LIMIT=5000
	export STUB_GH_CORE_REMAINING=5000
	export STUB_GH_CORE_LIMIT=5000
	# Keep full-window boundary assertions inside the clamped window even when
	# subprocess work crosses a second. Decay tests set their own reset epochs.
	export STUB_GH_CORE_RESET="$(($(date +%s) + 7200))"
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="0.05"
	export AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK=0
	export AIDEVOPS_PULSE_REST_CORE_RESERVE=500
	export AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR=100
	export AIDEVOPS_PULSE_REST_CORE_IN_FLIGHT_ALLOWANCE=250
	export AIDEVOPS_PULSE_REST_CORE_ADAPTIVE_WINDOW_SECONDS=3600
	export AIDEVOPS_PULSE_REST_CORE_GATE_PROBE_TTL=2
	export AIDEVOPS_PULSE_REST_CORE_UNKNOWN_PROGRESS_LIMIT=3
	return 0
}

# =============================================================================
# Test cases
# =============================================================================
printf 'test-rate-limit-circuit-breaker.sh (t2690)\n'
printf '============================================\n'

# --- Test 1: Breaker trips at 4/5000 (below 5% = 250 threshold) ---
test_breaker_trips_below_threshold() {
	reset_test_state
	STUB_GH_REMAINING=4
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "breaker trips when remaining=4 (below threshold=250)"
	else
		fail "breaker should trip when remaining=4 (rc=$rc, expected 1)"
	fi
	return 0
}

# --- Test 2: Breaker trips at exactly threshold (250/5000) ---
test_breaker_trips_at_threshold() {
	reset_test_state
	STUB_GH_REMAINING=250
	# Keep this early-window boundary deterministic across wall-clock seconds.
	STUB_GH_RESET=$(($(date +%s) + 3660))
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	unset STUB_GH_RESET
	if [[ "$rc" -eq 1 ]]; then
		pass "breaker trips when remaining=250 (at threshold=250)"
	else
		fail "breaker should trip when remaining=250 (rc=$rc, expected 1)"
	fi
	return 0
}

# --- Test 3: Breaker does NOT trip at 1000/5000 ---
test_breaker_passes_above_threshold() {
	reset_test_state
	STUB_GH_REMAINING=1000
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "breaker passes when remaining=1000 (above threshold=250)"
	else
		fail "breaker should pass when remaining=1000 (rc=$rc, expected 0)"
	fi
	return 0
}

# --- Test 4: Breaker does NOT trip at 251/5000 (one above threshold) ---
test_breaker_passes_just_above_threshold() {
	reset_test_state
	STUB_GH_REMAINING=251
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "breaker passes when remaining=251 (just above threshold=250)"
	else
		fail "breaker should pass when remaining=251 (rc=$rc, expected 0)"
	fi
	return 0
}

# --- Test 5: A total API outage leaves REST evidence unknown and fails closed ---
test_api_error_with_unknown_rest_fails_closed() {
	reset_test_state
	STUB_GH_FAIL=1
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]] && grep -qF 'authoritative REST-core quota evidence unavailable' "$LOGFILE"; then
		pass "GraphQL API error fails closed when REST evidence is unavailable"
	else
		fail "GraphQL API error should not bypass unknown REST evidence" "rc=$rc"
	fi
	return 0
}

# --- Test 5b: GraphQL API failure keeps fail-open only with healthy REST ---
test_graphql_api_error_with_healthy_rest_fails_open() {
	reset_test_state
	STUB_GH_RATE_FAIL=1
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 2 ]] && grep -qF 'authoritative REST-core evidence permits progress' "$LOGFILE"; then
		pass "GraphQL API error fails open only after healthy REST authorization"
	else
		fail "healthy REST should authorize GraphQL fail-open" "rc=$rc"
	fi
	return 0
}

# --- Test 5c: GraphQL API failure cannot bypass the REST hard floor ---
test_graphql_api_error_respects_rest_hard_floor() {
	reset_test_state
	STUB_GH_RATE_FAIL=1
	STUB_GH_CORE_REMAINING=10
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]] && grep -qF 'known REST-core progress launch floor reached' "$LOGFILE"; then
		pass "GraphQL API error respects the REST hard floor"
	else
		fail "GraphQL API error should not bypass the REST hard floor" "rc=$rc"
	fi
	return 0
}

# --- Test 5d: Malformed GraphQL projection cannot bypass the REST hard floor ---
test_malformed_graphql_projection_respects_rest_hard_floor() {
	reset_test_state
	STUB_GH_RATE_JSON='{"resources":{"graphql":{"remaining":"bad","limit":5000}}}'
	STUB_GH_CORE_REMAINING=10
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]] && grep -qF 'known REST-core progress launch floor reached' "$LOGFILE"; then
		pass "malformed GraphQL projection respects the REST hard floor"
	else
		fail "malformed GraphQL projection should not bypass the REST hard floor" "rc=$rc"
	fi
	return 0
}

# --- Test 5e: Zero GraphQL limit cannot bypass the REST hard floor ---
test_zero_graphql_limit_respects_rest_hard_floor() {
	reset_test_state
	STUB_GH_LIMIT=0
	STUB_GH_CORE_REMAINING=10
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]] && grep -qF 'GraphQL limit is 0' "$LOGFILE"; then
		pass "zero GraphQL limit respects the REST hard floor"
	else
		fail "zero GraphQL limit should not bypass the REST hard floor" "rc=$rc"
	fi
	return 0
}

# --- Test 6: Emergency bypass ---
test_emergency_bypass() {
	reset_test_state
	STUB_GH_REMAINING=0
	export AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "emergency bypass allows dispatch when remaining=0"
	else
		fail "emergency bypass should allow dispatch (rc=$rc, expected 0)"
	fi
	return 0
}

# --- Test 7: GraphQL floor is disabled when threshold=0 and REST is healthy ---
test_disabled_at_zero_threshold() {
	reset_test_state
	STUB_GH_REMAINING=0
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="0"
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "GraphQL floor disabled at threshold=0 while healthy REST still passes"
	else
		fail "GraphQL floor should be disabled at threshold=0 with healthy REST" "rc=$rc, expected 0"
	fi
	return 0
}

# --- Test 7b: GraphQL threshold=0 does not bypass unknown REST evidence ---
test_zero_graphql_threshold_keeps_rest_safety() {
	reset_test_state
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD=0
	unset STUB_GH_CORE_REMAINING
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]] && grep -qF 'authoritative REST-core quota evidence unavailable' "$LOGFILE"; then
		pass "GraphQL threshold=0 retains fail-closed unknown REST safety"
	else
		fail "GraphQL threshold=0 should not bypass unknown REST evidence" "rc=${rc}"
	fi
	return 0
}

# --- Test 8: Custom threshold 10% = 500/5000 ---
test_custom_threshold_10_percent() {
	reset_test_state
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="0.10"
	STUB_GH_REMAINING=499
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "trips at custom threshold 10% when remaining=499 (threshold=500)"
	else
		fail "should trip at 10% threshold when remaining=499 (rc=$rc, expected 1)"
	fi
	return 0
}

# --- Test 9: Stats counter increments on trip ---
test_stats_counter_increments() {
	reset_test_state
	STUB_GH_REMAINING=4
	is_graphql_budget_sufficient || true
	local count
	count=$(grep -c "^pulse_dispatch_circuit_broken$" "$STATS_COUNTER_FILE" 2>/dev/null) || count=0
	if [[ "$count" -eq 1 ]]; then
		pass "pulse_dispatch_circuit_broken counter incremented on trip"
	else
		fail "counter should increment once (got $count)"
	fi
	return 0
}

# --- Test 10: Stats counter does NOT increment when passing ---
test_stats_counter_no_increment_on_pass() {
	reset_test_state
	STUB_GH_REMAINING=1000
	is_graphql_budget_sufficient || true
	local count
	count=$(grep -c "^pulse_dispatch_circuit_broken$" "$STATS_COUNTER_FILE" 2>/dev/null) || count=0
	if [[ "$count" -eq 0 ]]; then
		pass "counter not incremented when budget is sufficient"
	else
		fail "counter should not increment on pass (got $count)"
	fi
	return 0
}

# --- Test 11: State file created on trip, cleared on recovery ---
test_state_file_lifecycle() {
	reset_test_state
	local state_file="${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state"

	# Trip the breaker.
	STUB_GH_REMAINING=4
	is_graphql_budget_sufficient || true
	if [[ -f "$state_file" ]]; then
		pass "state file created on trip"
	else
		fail "state file should be created on trip"
		return 0
	fi

	# Recover.
	STUB_GH_REMAINING=1000
	rm -f "${HOME}/.aidevops/cache/pulse-graphql-rate-limit.json"
	is_graphql_budget_sufficient || true
	if [[ ! -f "$state_file" ]]; then
		pass "state file cleared on recovery"
	else
		fail "state file should be cleared on recovery"
	fi
	return 0
}

# --- Test 12: Status output when OK ---
test_status_output_ok() {
	reset_test_state
	STUB_GH_REMAINING=4500
	local output
	output=$(_circuit_breaker_status 2>/dev/null)
	if printf '%s' "$output" | grep -q "^OK:"; then
		pass "status output shows OK when budget sufficient"
	else
		fail "status should show OK (got: $output)"
	fi
	return 0
}

# --- Test 13: Status output when TRIPPED ---
test_status_output_tripped() {
	reset_test_state
	STUB_GH_REMAINING=4
	# Trip the breaker first to create the state file.
	is_graphql_budget_sufficient || true
	local output
	output=$(_circuit_breaker_status 2>/dev/null)
	if printf '%s' "$output" | grep -q "^TRIPPED:"; then
		pass "status output shows TRIPPED when budget exhausted"
	else
		fail "status should show TRIPPED (got: $output)"
	fi
	return 0
}

# --- Test 14: Cached-only status does not call gh on cache hit ---
test_status_cached_only_uses_cache() {
	reset_test_state
	STUB_GH_REMAINING=4321
	local output
	output=$(_circuit_breaker_status 2>/dev/null)
	STUB_GH_REMAINING=1
	output=$(_circuit_breaker_status cached-only 2>/dev/null)
	if [[ "$output" == OK:*remaining=4321/5000* ]]; then
		pass "cached-only status reuses cached rate_limit response"
	else
		fail "cached-only status should reuse cached response (got: $output)"
	fi
	return 0
}

# --- Test 14: Log message on trip ---
test_log_message_on_trip() {
	reset_test_state
	STUB_GH_REMAINING=4
	is_graphql_budget_sufficient || true
	if grep -q "Local GraphQL scheduling deferred" "$LOGFILE" 2>/dev/null; then
		pass "log message emitted on trip"
	else
		fail "should distinguish local GraphQL scheduling from server exhaustion"
	fi
	return 0
}

# --- Test 15: GraphQL exhausted proceeds with REST fallback when core is healthy ---
test_graphql_exhausted_rest_core_healthy_allows_dispatch() {
	reset_test_state
	export AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK=1
	STUB_GH_REMAINING=0
	STUB_GH_CORE_REMAINING=4994
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	local fallback_count
	fallback_count=$(grep -c "^pulse_dispatch_rest_fallback$" "$STATS_COUNTER_FILE" 2>/dev/null) || fallback_count=0
	if [[ "$rc" -eq 0 && "${AIDEVOPS_GH_FORCE_REST_READS:-0}" == "1" && "${AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK_ACTIVE:-0}" == "1" && "$fallback_count" -eq 1 ]]; then
		pass "GraphQL exhausted with healthy REST core enables dispatch_rest_fallback"
	else
		fail "REST fallback should allow dispatch" "rc=$rc force_rest=${AIDEVOPS_GH_FORCE_REST_READS:-unset} active=${AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK_ACTIVE:-unset} fallback_count=$fallback_count"
	fi
	return 0
}

# --- Test 16: GraphQL exhausted still blocks when REST core is low ---
test_graphql_exhausted_rest_core_low_blocks_dispatch() {
	reset_test_state
	export AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK=1
	STUB_GH_REMAINING=0
	STUB_GH_CORE_REMAINING=10
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 && "${AIDEVOPS_GH_FORCE_REST_READS:-0}" != "1" ]] &&
		grep -qF 'known REST-core progress launch floor reached' "$LOGFILE"; then
		pass "GraphQL exhausted with low REST core still blocks dispatch"
	else
		fail "low REST core should not allow fallback" "rc=$rc force_rest=${AIDEVOPS_GH_FORCE_REST_READS:-unset}"
	fi
	return 0
}

# --- Test 17: REST fallback can be explicitly disabled ---
test_graphql_exhausted_rest_fallback_disabled_blocks_dispatch() {
	reset_test_state
	STUB_GH_REMAINING=0
	STUB_GH_CORE_REMAINING=4994
	export AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK=0
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 && "${AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK_ACTIVE:-0}" != "1" && "${AIDEVOPS_GH_FORCE_REST_READS:-0}" != "1" ]]; then
		pass "GraphQL exhausted blocks dispatch when REST fallback is disabled"
	else
		fail "disabled REST fallback should not allow dispatch" "rc=$rc active=${AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK_ACTIVE:-unset} force_rest=${AIDEVOPS_GH_FORCE_REST_READS:-unset}"
	fi
	return 0
}

# --- Test 18: Cached response-header probe avoids a second REST request ---
test_rest_core_probe_cache_reuse() {
	reset_test_state
	export AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK=1
	STUB_GH_REMAINING=0
	STUB_GH_CORE_REMAINING=900
	is_graphql_budget_sufficient || true
	STUB_GH_CORE_REMAINING=1
	is_graphql_budget_sufficient || true
	if [[ "${AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK_ACTIVE:-0}" == "1" ]]; then
		pass "REST core reserve reuses fresh response-header probe"
	else
		fail "REST core reserve should reuse fresh response-header probe"
	fi
	return 0
}

# --- Test 19: Expired response-header observation cannot authorize fallback ---
test_rest_core_probe_reset_forces_recheck() {
	reset_test_state
	export AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK=1
	STUB_GH_REMAINING=0
	STUB_GH_CORE_REMAINING=900
	STUB_GH_CORE_RESET=$(($(date +%s) - 1))
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "expired REST core header observation blocks fallback"
	else
		fail "expired REST core header observation should block fallback" "rc=$rc"
	fi
	return 0
}

# --- Test 20: Adaptive threshold decays monotonically toward the hard floor ---
test_rest_core_adaptive_threshold_math() {
	reset_test_state
	local now early mid near
	now=$(date +%s)
	early=$(_cb_rest_core_thresholds "$((now + 3600))" "$now")
	mid=$(_cb_rest_core_thresholds "$((now + 1800))" "$now")
	near=$(_cb_rest_core_thresholds "$((now + 1))" "$now")
	if [[ "$early" == "500 500 100" && "$mid" == "300 500 100" && "$near" == "100 500 100" ]]; then
		pass "REST adaptive threshold decays from soft cap toward hard floor"
	else
		fail "REST adaptive threshold should be monotonic and clamped" "early=${early} mid=${mid} near=${near}"
	fi
	return 0
}

# --- Test 21: REST priority classes split at adaptive and hard boundaries ---
test_rest_core_priority_boundaries() {
	reset_test_state
	local mode_normal mode_reserve mode_emergency
	export STUB_GH_CORE_REMAINING=501
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	mode_normal=$(pulse_rest_core_priority_snapshot)
	export STUB_GH_CORE_REMAINING=500
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	mode_reserve=$(pulse_rest_core_priority_snapshot)
	export STUB_GH_CORE_REMAINING=100
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	mode_emergency=$(pulse_rest_core_priority_snapshot)
	if [[ "$mode_normal" == normal\ 501\ 5000\ 500\ 500\ 100\ * &&
		"$mode_reserve" == reserve\ 500\ 5000\ 500\ 500\ 100\ * &&
		"$mode_emergency" == emergency\ 100\ 5000\ 500\ 500\ 100\ * ]]; then
		pass "REST priority modes honor adaptive soft and hard-floor boundaries"
	else
		fail "REST priority boundary classification mismatch" "normal=${mode_normal}; reserve=${mode_reserve}; emergency=${mode_emergency}"
	fi
	return 0
}

# --- Test 22: Reserve mode allows progress but not deferrable work ---
test_rest_core_priority_class_eligibility() {
	reset_test_state
	export STUB_GH_CORE_REMAINING=400
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	local progress_rc=0 deferrable_rc=0
	pulse_rest_core_priority_allows progress || progress_rc=$?
	pulse_rest_core_priority_allows deferrable || deferrable_rc=$?
	if [[ "$progress_rc" -eq 0 && "$deferrable_rc" -eq 1 ]]; then
		pass "REST reserve mode preserves progress while deferring optional work"
	else
		fail "REST reserve class eligibility mismatch" "progress_rc=${progress_rc} deferrable_rc=${deferrable_rc}"
	fi
	return 0
}

# --- Test 22b: In-flight allowance raises the progress launch boundary ---
test_rest_core_in_flight_allowance_boundary() {
	reset_test_state
	export STUB_GH_CORE_RESET="$(($(date +%s) + 60))"
	export STUB_GH_CORE_REMAINING=350
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	local blocked_snapshot blocked_rc=0 allowed_rc=0 critical_rc=0 start_floor=""
	blocked_snapshot=$(pulse_rest_core_priority_snapshot)
	pulse_rest_core_priority_allows progress || blocked_rc=$?
	pulse_rest_core_priority_allows critical || critical_rc=$?
	start_floor=$(_cb_rest_core_progress_start_floor 100 500)

	export STUB_GH_CORE_REMAINING=351
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	pulse_rest_core_priority_allows progress || allowed_rc=$?
	if [[ "$blocked_snapshot" == normal\ 350\ 5000\ * && "$start_floor" == "350" && "$blocked_rc" -eq 1 && "$allowed_rc" -eq 0 && "$critical_rc" -eq 0 ]]; then
		pass "REST in-flight allowance blocks progress at 350 and permits it at 351"
	else
		fail "REST in-flight allowance launch boundary mismatch" "snapshot=${blocked_snapshot} start_floor=${start_floor} blocked_rc=${blocked_rc} allowed_rc=${allowed_rc} critical_rc=${critical_rc}"
	fi
	return 0
}

# --- Test 22c: Unit gates reject a stale high cache after a fresh low probe ---
test_rest_core_unit_gate_refreshes_stale_observation() {
	reset_test_state
	local now rc=0 rest_calls=0
	now=$(date +%s)
	mkdir -p "$(dirname "$_CB_REST_CORE_CACHE_FILE")"
	jq -cn --argjson observed "$((now - 3))" --argjson remaining 500 --argjson limit 5000 \
		--argjson reset "$((now + 3600))" \
		'{observed:$observed,remaining:$remaining,limit:$limit,reset:$reset,resource:"core"}' >"$_CB_REST_CORE_CACHE_FILE"
	export STUB_GH_CORE_REMAINING=350
	pulse_rest_core_priority_allows_next progress "test_stale_unit_gate" || rc=$?
	rest_calls=$(grep -c '^rest-core$' "$GH_REST_CALLS" 2>/dev/null) || rest_calls=0
	if [[ "$rc" -eq 1 && "$rest_calls" -eq 1 ]] && grep -qF 'context=test_stale_unit_gate' "$LOGFILE"; then
		pass "REST unit gate refreshes stale observations before launching work"
	else
		fail "REST unit gate should refresh stale launch evidence" "rc=${rc} rest_calls=${rest_calls}"
	fi
	return 0
}

# --- Test 23: Hard floor blocks progress while critical work remains eligible ---
test_rest_core_hard_floor_eligibility() {
	reset_test_state
	export STUB_GH_CORE_REMAINING=100
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	local critical_rc=0 progress_rc=0
	pulse_rest_core_priority_allows critical || critical_rc=$?
	pulse_rest_core_priority_allows progress || progress_rc=$?
	if [[ "$critical_rc" -eq 0 && "$progress_rc" -eq 1 ]]; then
		pass "REST hard floor blocks new progress without globally blocking critical work"
	else
		fail "REST hard-floor class eligibility mismatch" "critical_rc=${critical_rc} progress_rc=${progress_rc}"
	fi
	return 0
}

# --- Test 24: Unknown REST evidence conservatively blocks non-critical work ---
test_rest_core_unknown_evidence() {
	reset_test_state
	unset STUB_GH_CORE_REMAINING
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	local progress_rc=0 deferrable_rc=0 critical_rc=0
	pulse_rest_core_priority_allows progress || progress_rc=$?
	pulse_rest_core_priority_allows deferrable || deferrable_rc=$?
	pulse_rest_core_priority_allows critical || critical_rc=$?
	if [[ "$progress_rc" -eq 2 && "$deferrable_rc" -eq 2 && "$critical_rc" -eq 0 ]]; then
		pass "unknown REST evidence defers progress and optional stages only"
	else
		fail "unknown REST evidence eligibility mismatch" "critical_rc=${critical_rc} progress_rc=${progress_rc} deferrable_rc=${deferrable_rc}"
	fi
	return 0
}

# --- Test 24b: Bounded unknown evidence resumes progress but not deferrable work ---
test_rest_core_unknown_progress_bound() {
	reset_test_state
	export AIDEVOPS_PULSE_REST_CORE_UNKNOWN_PROGRESS_LIMIT=1
	unset STUB_GH_CORE_REMAINING
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	local progress_rc=0 deferrable_rc=0
	pulse_rest_core_priority_allows progress || progress_rc=$?
	pulse_rest_core_priority_allows deferrable || deferrable_rc=$?
	if [[ "$progress_rc" -eq 0 && "$deferrable_rc" -eq 2 ]]; then
		pass "bounded unknown REST evidence resumes progress only"
	else
		fail "unknown REST progress bound eligibility mismatch" "progress_rc=${progress_rc} deferrable_rc=${deferrable_rc}"
	fi
	return 0
}

# --- Test 25: Legacy soft-cap override and zero-disable remain compatible ---
test_rest_core_legacy_override_compatibility() {
	reset_test_state
	export AIDEVOPS_PULSE_REST_CORE_RESERVE=300
	export STUB_GH_CORE_REMAINING=300
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	local overridden disabled_rc=0
	overridden=$(pulse_rest_core_priority_snapshot)
	export AIDEVOPS_PULSE_REST_CORE_RESERVE=0
	unset STUB_GH_CORE_REMAINING
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	pulse_rest_core_reserve_allows || disabled_rc=$?
	if [[ "$overridden" == reserve\ 300\ 5000\ 300\ 300\ 100\ * && "$disabled_rc" -eq 0 ]]; then
		pass "legacy REST reserve override remains the soft cap and zero disables gating"
	else
		fail "legacy REST reserve compatibility mismatch" "snapshot=${overridden} disabled_rc=${disabled_rc}"
	fi
	return 0
}

# --- Test 25b: Hard floor above the soft cap is clamped to the soft cap ---
test_rest_core_hard_floor_clamped_to_soft_cap() {
	reset_test_state
	export AIDEVOPS_PULSE_REST_CORE_RESERVE=200
	export AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR=1000
	export STUB_GH_CORE_REMAINING=200
	rm -f "$_CB_REST_CORE_CACHE_FILE"
	local snapshot
	snapshot=$(pulse_rest_core_priority_snapshot)
	if [[ "$snapshot" == emergency\ 200\ 5000\ 200\ 200\ 200\ * ]]; then
		pass "REST hard floor above the soft cap is clamped to the soft cap"
	else
		fail "REST hard-floor clamp mismatch" "snapshot=${snapshot}"
	fi
	return 0
}

# --- Test 26: Malformed cache metadata is ignored without set -u crashes ---
test_rest_core_malformed_cache_recovers() {
	reset_test_state
	mkdir -p "$(dirname "$_CB_REST_CORE_CACHE_FILE")"
	printf '{"observed":"malformed","remaining":"bad","limit":5000,"reset":0,"resource":"core"}\n' >"$_CB_REST_CORE_CACHE_FILE"
	local snapshot
	snapshot=$(pulse_rest_core_priority_snapshot)
	if [[ "$snapshot" == normal\ 5000\ 5000\ 500\ 500\ 100\ * ]]; then
		pass "malformed REST cache is ignored and refreshed from authoritative headers"
	else
		fail "malformed REST cache should recover without crashing" "snapshot=${snapshot}"
	fi
	return 0
}

# --- Test 27: Unknown REST evidence is classified and logged from one probe ---
test_rest_core_unknown_dispatch_uses_single_probe() {
	reset_test_state
	unset STUB_GH_CORE_REMAINING
	local rc=0 rest_calls=0
	is_graphql_budget_sufficient || rc=$?
	rest_calls=$(grep -c '^rest-core$' "$GH_REST_CALLS" 2>/dev/null) || rest_calls=0
	if [[ "$rc" -eq 1 && "$rest_calls" -eq 1 ]] &&
		grep -qF 'authoritative REST-core quota evidence unavailable' "$LOGFILE"; then
		pass "unknown REST dispatch evidence uses one authoritative probe"
	else
		fail "unknown REST dispatch evidence should not trigger a duplicate probe" "rc=${rc} rest_calls=${rest_calls}"
	fi
	return 0
}

# =============================================================================
# Part 2: no_work rate circuit breaker (t2770, GH#20640)
#
# Tests is_no_work_rate_acceptable() from pulse-wrapper.sh.
# The function is extracted via awk to avoid sourcing the entire
# pulse-wrapper.sh (which triggers jitter, module sources, etc.).
# Stub strategy: write fake pulse.log lines containing "crash_type=no_work"
# to control the observed event count.
# =============================================================================

# Extract is_no_work_rate_acceptable from pulse-wrapper.sh using brace-counting awk.
_NW_FUNC_DEF="$(awk '
    /^is_no_work_rate_acceptable\(\) \{/ { depth=1; print; next }
    depth > 0 {
        for (i=1; i<=length($0); i++) {
            c = substr($0,i,1)
            if (c=="{") depth++
            else if (c=="}") depth--
        }
        print
        if (depth==0) exit
    }
' "${SCRIPTS_DIR}/pulse-wrapper.sh")"

if [[ -z "$_NW_FUNC_DEF" ]]; then
	printf '  %sSKIP%s no_work breaker tests: could not extract is_no_work_rate_acceptable from pulse-wrapper.sh\n' \
		"$TEST_RED" "$TEST_NC"
else
	# shellcheck disable=SC2317
	eval "$_NW_FUNC_DEF"

	# Separate sandbox for no_work tests.
	NW_TMP=$(mktemp -d -t t2770.XXXXXX)
	trap 'rm -rf "$NW_TMP"' EXIT

	NW_HOME="${NW_TMP}/home"
	NW_LOGFILE="${NW_TMP}/pulse.log"
	mkdir -p "${NW_HOME}/.aidevops/logs"

	NW_STATE_FILE="${NW_HOME}/.aidevops/logs/pulse-no-work-breaker.state"

	# Stub pulse_stats_increment for no_work counter tracking.
	NW_STATS_FILE="${NW_TMP}/nw-stats.log"
	# shellcheck disable=SC2317
	pulse_stats_increment() {
		local counter_name="$1"
		printf '%s\n' "$counter_name" >>"$NW_STATS_FILE"
		return 0
	}

	# Write N no_work lines to the fake pulse.log.
	write_nw_log_lines() {
		local count="$1"
		local i=0
		while [[ "$i" -lt "$count" ]]; do
			printf '[pulse-wrapper] fast_fail_record: #%s (repo/repo) failure_backoff reason=stale_timeout crash_type=no_work\n' "$i" >>"$NW_LOGFILE"
			i=$((i + 1))
		done
		return 0
	}

	reset_nw_state() {
		: >"$NW_LOGFILE"
		rm -f "$NW_STATE_FILE"
		: >"$NW_STATS_FILE"
		unset AIDEVOPS_SKIP_NO_WORK_BREAKER 2>/dev/null || true
		export HOME="$NW_HOME"
		export LOGFILE="$NW_LOGFILE"
		export NO_WORK_WINDOW_SECS=600
		export NO_WORK_WINDOW_MAX=10
		unset AIDEVOPS_NO_WORK_WINDOW_SECS 2>/dev/null || true
		unset AIDEVOPS_NO_WORK_WINDOW_MAX 2>/dev/null || true
		return 0
	}

	printf '\ntest-rate-limit-circuit-breaker.sh (t2770 — no_work rate breaker)\n'
	printf '====================================================================\n'

	# --- NW Test 1: Passes when no no_work events present ---
	test_nw_passes_with_no_events() {
		reset_nw_state
		local rc=0
		is_no_work_rate_acceptable || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			pass "no_work breaker: passes when log has zero no_work events"
		else
			fail "no_work breaker: should pass with zero events (rc=$rc)"
		fi
		return 0
	}

	# --- NW Test 2: Passes when below threshold ---
	test_nw_passes_below_threshold() {
		reset_nw_state
		write_nw_log_lines 5  # 5 events, max=10 → should pass
		# First call to establish state baseline.
		local rc=0
		is_no_work_rate_acceptable || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			pass "no_work breaker: passes when 5 events below max=10"
		else
			fail "no_work breaker: should pass with 5 events, max=10 (rc=$rc)"
		fi
		return 0
	}

	# --- NW Test 3: Trips when threshold reached (exactly max events) ---
	test_nw_trips_at_threshold() {
		reset_nw_state
		write_nw_log_lines 10  # 10 events, max=10 → should trip
		local rc=0
		is_no_work_rate_acceptable || rc=$?
		if [[ "$rc" -eq 1 ]]; then
			pass "no_work breaker: trips when exactly max=10 events in window"
		else
			fail "no_work breaker: should trip at max=10 events (rc=$rc)"
		fi
		return 0
	}

	# --- NW Test 4: Trips when above threshold (11 events) ---
	test_nw_trips_above_threshold() {
		reset_nw_state
		write_nw_log_lines 11  # 11 events, max=10 → should trip
		local rc=0
		is_no_work_rate_acceptable || rc=$?
		if [[ "$rc" -eq 1 ]]; then
			pass "no_work breaker: trips when 11 events exceed max=10"
		else
			fail "no_work breaker: should trip with 11 events, max=10 (rc=$rc)"
		fi
		return 0
	}

	# --- NW Test 5: Emergency bypass ---
	test_nw_emergency_bypass() {
		reset_nw_state
		write_nw_log_lines 50  # Far above threshold
		export AIDEVOPS_SKIP_NO_WORK_BREAKER=1
		local rc=0
		is_no_work_rate_acceptable || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			pass "no_work breaker: emergency bypass allows dispatch (rc=0)"
		else
			fail "no_work breaker: emergency bypass should allow dispatch (rc=$rc)"
		fi
		return 0
	}

	# --- NW Test 6: Disabled when max=0 ---
	test_nw_disabled_at_zero_max() {
		reset_nw_state
		export NO_WORK_WINDOW_MAX=0
		write_nw_log_lines 100  # Far above disabled threshold
		local rc=0
		is_no_work_rate_acceptable || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			pass "no_work breaker: disabled when NO_WORK_WINDOW_MAX=0"
		else
			fail "no_work breaker: should be disabled when max=0 (rc=$rc)"
		fi
		return 0
	}

	# --- NW Test 7: Counter increments on trip ---
	test_nw_counter_increments_on_trip() {
		reset_nw_state
		write_nw_log_lines 11
		is_no_work_rate_acceptable || true
		local count
		count=$(grep -c "^pulse_dispatch_no_work_breaker_tripped$" "$NW_STATS_FILE" 2>/dev/null) || count=0
		if [[ "$count" -eq 1 ]]; then
			pass "no_work breaker: pulse_dispatch_no_work_breaker_tripped counter incremented"
		else
			fail "no_work breaker: counter should increment once on trip (got $count)"
		fi
		return 0
	}

	# --- NW Test 8: Counter does NOT increment when passing ---
	test_nw_counter_no_increment_on_pass() {
		reset_nw_state
		write_nw_log_lines 3
		is_no_work_rate_acceptable || true
		local count
		count=$(grep -c "^pulse_dispatch_no_work_breaker_tripped$" "$NW_STATS_FILE" 2>/dev/null) || count=0
		if [[ "$count" -eq 0 ]]; then
			pass "no_work breaker: counter not incremented when passing"
		else
			fail "no_work breaker: counter should not increment on pass (got $count)"
		fi
		return 0
	}

	# --- NW Test 9: State file written on check ---
	test_nw_state_file_written() {
		reset_nw_state
		write_nw_log_lines 3
		is_no_work_rate_acceptable || true
		if [[ -f "$NW_STATE_FILE" ]]; then
			pass "no_work breaker: state file written after check"
		else
			fail "no_work breaker: state file should be written after check"
		fi
		return 0
	}

	# --- NW Test 10: Log message on trip ---
	test_nw_log_message_on_trip() {
		reset_nw_state
		write_nw_log_lines 11
		is_no_work_rate_acceptable || true
		if grep -q "no_work rate circuit breaker TRIPPED" "$NW_LOGFILE" 2>/dev/null; then
			pass "no_work breaker: TRIPPED log message emitted"
		else
			fail "no_work breaker: should emit 'no_work rate circuit breaker TRIPPED' log message"
		fi
		return 0
	}

	# --- NW Test 11: Custom threshold via env var ---
	test_nw_custom_max_env_var() {
		reset_nw_state
		export AIDEVOPS_NO_WORK_WINDOW_MAX=5
		write_nw_log_lines 5
		local rc=0
		is_no_work_rate_acceptable || rc=$?
		if [[ "$rc" -eq 1 ]]; then
			pass "no_work breaker: AIDEVOPS_NO_WORK_WINDOW_MAX=5 trips at 5 events"
		else
			fail "no_work breaker: should trip at AIDEVOPS_NO_WORK_WINDOW_MAX=5 (rc=$rc)"
		fi
		return 0
	}

	# --- NW Test 12: Window pruning — old events don't count ---
	test_nw_window_pruning() {
		reset_nw_state
		export NO_WORK_WINDOW_SECS=1  # 1 second window
		write_nw_log_lines 11  # 11 events — enough to trip at max=10
		# First call: establish state with 11 events in window.
		is_no_work_rate_acceptable || true
		# Wait for window to expire.
		sleep 2
		# Second call: all events should be pruned (outside the 1s window).
		# No new events since last check → should pass.
		local rc=0
		is_no_work_rate_acceptable || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			pass "no_work breaker: old events pruned after window expires"
		else
			fail "no_work breaker: should pass after window expires (rc=$rc)"
		fi
		return 0
	}

	# Save outer sandbox state before no_work tests modify HOME/LOGFILE.
	_NW_SAVE_HOME="$HOME"
	_NW_SAVE_LOGFILE="$LOGFILE"
	_NW_SAVE_STATS_FILE="$STATS_COUNTER_FILE"

	test_nw_passes_with_no_events
	test_nw_passes_below_threshold
	test_nw_trips_at_threshold
	test_nw_trips_above_threshold
	test_nw_emergency_bypass
	test_nw_disabled_at_zero_max
	test_nw_counter_increments_on_trip
	test_nw_counter_no_increment_on_pass
	test_nw_state_file_written
	test_nw_log_message_on_trip
	test_nw_custom_max_env_var
	test_nw_window_pruning

	# Restore outer sandbox state for GraphQL breaker tests that follow.
	export HOME="$_NW_SAVE_HOME"
	export LOGFILE="$_NW_SAVE_LOGFILE"
	# Restore the original pulse_stats_increment (reads from $STATS_COUNTER_FILE).
	# shellcheck disable=SC2317
	pulse_stats_increment() {
		local counter_name="$1"
		printf '%s\n' "$counter_name" >>"$_NW_SAVE_STATS_FILE"
		return 0
	}
	# Restore the circuit-breaker state file path (in outer HOME).
	rm -f "${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state" 2>/dev/null || true
	# Restore GraphQL threshold to test default (0.05).
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="0.05"
	unset AIDEVOPS_SKIP_NO_WORK_BREAKER NO_WORK_WINDOW_SECS NO_WORK_WINDOW_MAX 2>/dev/null || true
fi  # end: no_work breaker tests

test_shared_rate_probe_coalesces_consumers() {
	reset_test_state
	export STUB_GH_REMAINING=1000
	export STUB_GH_DELAY=0.25
	local pid=0 count=0 output=""
	local -a pids=()
	(_cb_rate_limit_json normal >"${TMP}/shared-rate-circuit.json") &
	pids+=("$!")
	(_rest_should_fallback >/dev/null || true) &
	pids+=("$!")
	(_cb_rate_limit_json normal >"${TMP}/shared-rate-circuit-2.json") &
	pids+=("$!")
	(_rest_should_fallback >/dev/null || true) &
	pids+=("$!")
	for pid in "${pids[@]}"; do
		wait "$pid"
	done
	count=$(wc -l <"$GH_RATE_CALLS")
	count="${count//[!0-9]/}"
	output=$(jq -r '.resources.graphql.remaining' "${TMP}/shared-rate-circuit.json" 2>/dev/null) || output=""
	if [[ "$count" == "1" && "$output" == "1000" ]]; then
		pass "REST fallback and circuit breaker share one concurrent rate probe"
	else
		fail "REST fallback and circuit breaker share one concurrent rate probe" "calls=${count:-0} remaining=${output:-missing}"
	fi
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
test_breaker_trips_below_threshold
test_breaker_trips_at_threshold
test_breaker_passes_above_threshold
test_breaker_passes_just_above_threshold
test_api_error_with_unknown_rest_fails_closed
test_graphql_api_error_with_healthy_rest_fails_open
test_graphql_api_error_respects_rest_hard_floor
test_malformed_graphql_projection_respects_rest_hard_floor
test_zero_graphql_limit_respects_rest_hard_floor
test_emergency_bypass
test_disabled_at_zero_threshold
test_zero_graphql_threshold_keeps_rest_safety
test_custom_threshold_10_percent
test_stats_counter_increments
test_stats_counter_no_increment_on_pass
test_state_file_lifecycle
test_status_output_ok
test_status_output_tripped
test_status_cached_only_uses_cache
test_log_message_on_trip
test_graphql_exhausted_rest_core_healthy_allows_dispatch
test_graphql_exhausted_rest_core_low_blocks_dispatch
test_graphql_exhausted_rest_fallback_disabled_blocks_dispatch
test_rest_core_probe_cache_reuse
test_rest_core_probe_reset_forces_recheck
test_rest_core_adaptive_threshold_math
test_rest_core_priority_boundaries
test_rest_core_priority_class_eligibility
test_rest_core_in_flight_allowance_boundary
test_rest_core_unit_gate_refreshes_stale_observation
test_rest_core_hard_floor_eligibility
test_rest_core_unknown_evidence
test_rest_core_unknown_progress_bound
test_rest_core_legacy_override_compatibility
test_rest_core_hard_floor_clamped_to_soft_cap
test_rest_core_malformed_cache_recovers
test_rest_core_unknown_dispatch_uses_single_probe
test_shared_rate_probe_coalesces_consumers

# =============================================================================
# Summary
# =============================================================================
printf '\n%s/%s tests passed' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf ' (%s%s FAILED%s)\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_NC"
	exit 1
else
	printf ' %s(all passed)%s\n' "$TEST_GREEN" "$TEST_NC"
	exit 0
fi
