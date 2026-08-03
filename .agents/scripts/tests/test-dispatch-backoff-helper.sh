#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-backoff-helper.sh — t2781 / GH#20680 regression guard.
#
# Asserts the per-issue rate_limit backoff gate:
#   1. Returns clear (exit 0) when no rate_limit events for the issue
#   2. Returns clear (exit 0) after the cooldown window elapses
#   3. 1st failure: 5min cooldown (300s) — blocks dispatch during window
#   4. 2nd failure: 30min cooldown (1800s)
#   5. 3rd failure: 2h cooldown (7200s)
#   6. 4th+ failure: 24h cooldown + BACKOFF_NOTICE_REQUIRED flag in stderr
#   7. Fails open on JSONL read error (missing file)
#   8. Emergency bypass via AIDEVOPS_SKIP_DISPATCH_BACKOFF=1
#   9. Stats counter increments on backoff block
#  10. AC3 from GH#20680: simulate 2 rate_limit exits, confirm 3rd dispatch blocked at 30min
#  11. rate_limit_fast and provider metadata-only rate-limit signals count toward per-issue backoff
#
# Stub strategy: write a fixture JSONL file with controlled timestamps.
# No gh stubs needed for the check subcommand (notice-posting tests use gh stubs).

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
TMP=$(mktemp -d -t t2781.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export LOGFILE="${TMP}/test-pulse.log"
export HOME="${TMP}/home"
mkdir -p "${HOME}/.aidevops/logs"

FIXTURE_METRICS="${TMP}/headless-runtime-metrics.jsonl"
export DISPATCH_BACKOFF_METRICS_FILE="$FIXTURE_METRICS"

# Stub pulse-stats-helper.sh — track counter increments.
STATS_COUNTER_FILE="${TMP}/stats-counter.log"
pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}
export -f pulse_stats_increment

# Stub gh for notice tests — captures calls without network.
gh() {
	printf '[gh-stub] %s\n' "$*" >>"${TMP}/gh-calls.log"
	return 0
}
export -f gh

# Source the helper under test.
# shellcheck source=../dispatch-backoff-helper.sh
source "${SCRIPTS_DIR}/dispatch-backoff-helper.sh"

# Re-override pulse_stats_increment AFTER sourcing (helper sources pulse-stats-helper.sh
# which replaces our capturing stub — same pattern as test-rate-limit-circuit-breaker.sh).
# shellcheck disable=SC2317
pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}

# =============================================================================
# Helpers
# =============================================================================

# Write N rate_limit entries for a given issue into the fixture file.
# $1 = issue_number, $2 = N entries, $3 = base_epoch (ts will be base+idx*60)
write_rate_limit_entries() {
	local issue_num="$1"
	local count="$2"
	local base_epoch="$3"
	local i
	for i in $(seq 1 "$count"); do
		local ts=$(( base_epoch + (i - 1) * 60 ))
		printf '{"ts":%s,"role":"worker","session_key":"issue-%s","model":"anthropic/claude-sonnet-4-6","provider":"anthropic","result":"rate_limit","exit_code":143,"failure_reason":"rate_limit","activity":false,"duration_ms":90000}\n' \
			"$ts" "$issue_num" >>"$FIXTURE_METRICS"
	done
	return 0
}

# Write N rate_limit_fast entries for a given issue into the fixture file.
# $1 = issue_number, $2 = N entries, $3 = base_epoch (ts will be base+idx*60)
write_rate_limit_fast_entries() {
	local issue_num="$1"
	local count="$2"
	local base_epoch="$3"
	local i
	for i in $(seq 1 "$count"); do
		local ts=$(( base_epoch + (i - 1) * 60 ))
		printf '{"ts":%s,"role":"worker","session_key":"issue-%s","model":"openai/gpt-5.5","provider":"openai","result":"rate_limit_fast","exit_code":143,"failure_reason":"rate_limit_fast","provider_error_type":"rate_limit","provider_status":429,"activity":false,"duration_ms":1000}\n' \
			"$ts" "$issue_num" >>"$FIXTURE_METRICS"
	done
	return 0
}

# Write N non-rate_limit result entries that carry provider rate-limit metadata.
# $1 = issue_number, $2 = N entries, $3 = base_epoch (ts will be base+idx*60)
write_provider_metadata_rate_limit_entries() {
	local issue_num="$1"
	local count="$2"
	local base_epoch="$3"
	local i
	for i in $(seq 1 "$count"); do
		local ts=$(( base_epoch + (i - 1) * 60 ))
		printf '{"ts":%s,"role":"worker","session_key":"issue-%s","model":"openai/gpt-5.5","provider":"openai","result":"error","exit_code":1,"failure_reason":"provider_error","provider_error_type":"rate_limit","provider_status":429,"activity":false,"duration_ms":1000}\n' \
			"$ts" "$issue_num" >>"$FIXTURE_METRICS"
	done
	return 0
}

# Reset fixture and counters between tests.
reset_test_state() {
	: >"$FIXTURE_METRICS"
	: >"$LOGFILE"
	: >"$STATS_COUNTER_FILE"
	: >"${TMP}/gh-calls.log"
	unset AIDEVOPS_SKIP_DISPATCH_BACKOFF 2>/dev/null || true
	export DISPATCH_BACKOFF_LOOKBACK_SECS=604800   # 7 days
	export DISPATCH_BACKOFF_NMR_THRESHOLD=4
	export DISPATCH_PROVIDER_BACKOFF_WINDOW_SECS=900
	export DISPATCH_PROVIDER_BACKOFF_THRESHOLD=6
	export DISPATCH_PROVIDER_BACKOFF_COOLDOWN_SECS=300
	return 0
}

# =============================================================================
# Test cases
# =============================================================================
printf 'test-dispatch-backoff-helper.sh (t2781)\n'
printf '=========================================\n'

# --- Test 1: No events → clear ---
test_no_events_clear() {
	reset_test_state
	local rc=0
	check_dispatch_backoff "99999" "owner/repo" 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "no rate_limit events → clear (exit 0)"
	else
		fail "no rate_limit events → clear (exit 0)" "got exit ${rc}"
	fi
	return 0
}

# --- Test 2: 1 failure, cooldown elapsed → clear ---
test_one_failure_elapsed_clear() {
	reset_test_state
	local now
	now=$(date +%s)
	# Rate-limit event was 10 minutes ago; 5-min cooldown has elapsed.
	local past=$(( now - 600 ))
	write_rate_limit_entries "88888" 1 "$past"
	local rc=0
	check_dispatch_backoff "88888" "owner/repo" 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "1 failure, cooldown elapsed → clear (exit 0)"
	else
		fail "1 failure, cooldown elapsed → clear (exit 0)" "got exit ${rc}"
	fi
	return 0
}

# --- Test 3: 1 failure, within 5-min cooldown → blocked ---
test_one_failure_within_cooldown_blocked() {
	reset_test_state
	local now
	now=$(date +%s)
	# Rate-limit event was 2 minutes ago; 5-min cooldown still active.
	local past=$(( now - 120 ))
	write_rate_limit_entries "77777" 1 "$past"
	local rc=0
	local output=""
	output=$(check_dispatch_backoff "77777" "owner/repo" 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "1 failure, within 5-min cooldown → blocked (exit 1)"
	else
		fail "1 failure, within 5-min cooldown → blocked (exit 1)" "got exit ${rc}"
	fi
	if printf '%s' "$output" | grep -q 'BACKOFF_ACTIVE'; then
		pass "blocked output contains BACKOFF_ACTIVE"
	else
		fail "blocked output contains BACKOFF_ACTIVE" "output: ${output}"
	fi
	return 0
}

# --- Test 4: 2 failures, within 30-min cooldown → blocked ---
test_two_failures_blocked() {
	reset_test_state
	local now
	now=$(date +%s)
	# Two rate-limit events, most recent 5 minutes ago; 30-min cooldown active.
	local past=$(( now - 300 ))
	write_rate_limit_entries "66666" 2 "$past"
	local rc=0
	local output=""
	output=$(check_dispatch_backoff "66666" "owner/repo" 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "2 failures, within 30-min cooldown → blocked (exit 1)"
	else
		fail "2 failures, within 30-min cooldown → blocked (exit 1)" "got exit ${rc}"
	fi
	if printf '%s' "$output" | grep -q 'cooldown=1800s'; then
		pass "2-failure output shows 1800s cooldown"
	else
		fail "2-failure output shows 1800s cooldown" "output: ${output}"
	fi
	return 0
}

# --- Test 5: 3 failures, within 2-hour cooldown → blocked ---
test_three_failures_blocked() {
	reset_test_state
	local now
	now=$(date +%s)
	# Three rate-limit events, most recent 10 minutes ago; 2h cooldown active.
	local past=$(( now - 600 ))
	write_rate_limit_entries "55555" 3 "$past"
	local rc=0
	local output=""
	output=$(check_dispatch_backoff "55555" "owner/repo" 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "3 failures, within 2h cooldown → blocked (exit 1)"
	else
		fail "3 failures, within 2h cooldown → blocked (exit 1)" "got exit ${rc}"
	fi
	if printf '%s' "$output" | grep -q 'cooldown=7200s'; then
		pass "3-failure output shows 7200s cooldown"
	else
		fail "3-failure output shows 7200s cooldown" "output: ${output}"
	fi
	return 0
}

# --- Test 6: 4+ failures → 24h cooldown + BACKOFF_NOTICE_REQUIRED ---
test_four_failures_notice() {
	reset_test_state
	local now
	now=$(date +%s)
	# Four rate-limit events, most recent 1 minute ago; 24h cooldown active.
	local past=$(( now - 60 ))
	write_rate_limit_entries "44444" 4 "$past"
	local rc=0
	local output=""
	output=$(check_dispatch_backoff "44444" "owner/repo" 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "4 failures → blocked (exit 1)"
	else
		fail "4 failures → blocked (exit 1)" "got exit ${rc}"
	fi
	if printf '%s' "$output" | grep -q 'cooldown=86400s'; then
		pass "4-failure output shows 86400s cooldown"
	else
		fail "4-failure output shows 86400s cooldown" "output: ${output}"
	fi
	if printf '%s' "$output" | grep -q 'BACKOFF_NOTICE_REQUIRED'; then
		pass "4-failure output contains BACKOFF_NOTICE_REQUIRED"
	else
		fail "4-failure output contains BACKOFF_NOTICE_REQUIRED" "output: ${output}"
	fi
	return 0
}

# --- Test 7: Missing JSONL → fail-open (exit 0 or exit 2) ---
test_missing_jsonl_fail_open() {
	reset_test_state
	export DISPATCH_BACKOFF_METRICS_FILE="/nonexistent/path/headless-runtime-metrics.jsonl"
	local rc=0
	check_dispatch_backoff "33333" "owner/repo" 2>/dev/null || rc=$?
	export DISPATCH_BACKOFF_METRICS_FILE="$FIXTURE_METRICS"
	if [[ "$rc" -eq 0 ]]; then
		pass "missing JSONL → fail-open (exit 0)"
	else
		fail "missing JSONL → fail-open (exit 0)" "got exit ${rc}"
	fi
	return 0
}

# --- Test 8: Emergency bypass ---
test_bypass() {
	reset_test_state
	local now
	now=$(date +%s)
	local past=$(( now - 60 ))
	write_rate_limit_entries "22222" 4 "$past"
	export AIDEVOPS_SKIP_DISPATCH_BACKOFF=1
	local rc=0
	check_dispatch_backoff "22222" "owner/repo" 2>/dev/null || rc=$?
	unset AIDEVOPS_SKIP_DISPATCH_BACKOFF
	if [[ "$rc" -eq 0 ]]; then
		pass "AIDEVOPS_SKIP_DISPATCH_BACKOFF=1 → bypass (exit 0)"
	else
		fail "AIDEVOPS_SKIP_DISPATCH_BACKOFF=1 → bypass (exit 0)" "got exit ${rc}"
	fi
	return 0
}

# --- Test 9: Stats counter incremented on block ---
test_stats_counter_incremented() {
	reset_test_state
	local now
	now=$(date +%s)
	local past=$(( now - 60 ))
	write_rate_limit_entries "11111" 1 "$past"
	check_dispatch_backoff "11111" "owner/repo" 2>/dev/null || true
	local count
	count=$(grep -c "^dispatch_backoff_skipped$" "$STATS_COUNTER_FILE" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	if [[ "$count" -ge 1 ]]; then
		pass "stats counter dispatch_backoff_skipped incremented on block"
	else
		fail "stats counter dispatch_backoff_skipped incremented on block" "count=${count}"
	fi
	return 0
}

# --- Test 10 (AC3 from GH#20680): Simulate 2 rate_limit exits, confirm 3rd blocked at 30min ---
test_ac3_two_failures_blocks_third() {
	reset_test_state
	local now
	now=$(date +%s)
	# Two rate_limit exits within last 5 minutes.
	local past=$(( now - 300 ))
	write_rate_limit_entries "99001" 2 "$past"

	# 3rd dispatch attempt: should be blocked (2 failures → 30min cooldown).
	local rc=0
	local output=""
	output=$(check_dispatch_backoff "99001" "owner/repo" 2>&1 >/dev/null) || rc=$?

	if [[ "$rc" -eq 1 ]]; then
		pass "AC3: 3rd dispatch blocked after 2 rate_limit exits (exit 1)"
	else
		fail "AC3: 3rd dispatch blocked after 2 rate_limit exits (exit 1)" "got exit ${rc}"
	fi
	if printf '%s' "$output" | grep -q 'cooldown=1800s'; then
		pass "AC3: blocked for 30min (1800s) as specified"
	else
		fail "AC3: blocked for 30min (1800s) as specified" "output: ${output}"
	fi
	return 0
}

# --- Test 11: Events outside lookback window are ignored ---
test_old_events_ignored() {
	reset_test_state
	local now
	now=$(date +%s)
	# Two events from 8 days ago (outside 7-day lookback).
	local old_ts=$(( now - 691200 ))  # 8 days ago
	write_rate_limit_entries "80001" 2 "$old_ts"
	local rc=0
	check_dispatch_backoff "80001" "owner/repo" 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "events outside lookback window are ignored → clear (exit 0)"
	else
		fail "events outside lookback window are ignored → clear (exit 0)" "got exit ${rc}"
	fi
	return 0
}

# --- Test 12: Different issue number not affected ---
test_different_issue_not_affected() {
	reset_test_state
	local now
	now=$(date +%s)
	local past=$(( now - 60 ))
	write_rate_limit_entries "12345" 4 "$past"  # issue 12345 has 4 failures
	local rc=0
	check_dispatch_backoff "67890" "owner/repo" 2>/dev/null || rc=$?  # issue 67890 is different
	if [[ "$rc" -eq 0 ]]; then
		pass "different issue not affected by other issue's backoff"
	else
		fail "different issue not affected by other issue's backoff" "got exit ${rc}"
	fi
	return 0
}

# --- Test 13: Provider/model pressure blocks different issues during a rate-limit storm ---
test_provider_pressure_blocks_pool() {
	reset_test_state
	local now
	now=$(date +%s)
	local past=$(( now - 60 ))
	write_rate_limit_entries "12001" 3 "$past"
	write_rate_limit_entries "12002" 3 "$past"

	local rc=0
	local output=""
	output=$(check_dispatch_backoff "12003" "owner/repo" 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "provider pressure blocks unrelated issue during rate-limit storm"
	else
		fail "provider pressure blocks unrelated issue during rate-limit storm" "got exit ${rc} output=${output}"
	fi
	if printf '%s' "$output" | grep -q 'reason=provider_rate_limit_pressure'; then
		pass "provider pressure output names pressure reason"
	else
		fail "provider pressure output names pressure reason" "output: ${output}"
	fi
	return 0
}

# --- Test 14: rate_limit_fast entries trigger per-issue 24h cooldown + notice ---
test_rate_limit_fast_entries_trigger_notice() {
	reset_test_state
	local now
	now=$(date +%s)
	local past=$(( now - 60 ))
	write_rate_limit_fast_entries "23063" 4 "$past"

	local rc=0
	local output=""
	output=$(check_dispatch_backoff "23063" "owner/repo" 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "rate_limit_fast entries trigger per-issue backoff"
	else
		fail "rate_limit_fast entries trigger per-issue backoff" "got exit ${rc} output=${output}"
	fi
	if printf '%s' "$output" | grep -q 'BACKOFF_NOTICE_REQUIRED'; then
		pass "rate_limit_fast 4+ entries emit BACKOFF_NOTICE_REQUIRED"
	else
		fail "rate_limit_fast 4+ entries emit BACKOFF_NOTICE_REQUIRED" "output: ${output}"
	fi
	return 0
}

# --- Test 15: Mixed rate_limit + rate_limit_fast entries aggregate for thresholding ---
test_mixed_rate_limit_entries_aggregate() {
	reset_test_state
	local now
	now=$(date +%s)
	local past=$(( now - 60 ))
	write_rate_limit_entries "23064" 2 "$past"
	write_rate_limit_fast_entries "23064" 2 "$(( past + 120 ))"

	local rc=0
	local output=""
	output=$(check_dispatch_backoff "23064" "owner/repo" 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "mixed rate_limit labels aggregate for per-issue backoff"
	else
		fail "mixed rate_limit labels aggregate for per-issue backoff" "got exit ${rc} output=${output}"
	fi
	if printf '%s' "$output" | grep -q 'count=4'; then
		pass "mixed rate_limit output reports aggregate count=4"
	else
		fail "mixed rate_limit output reports aggregate count=4" "output: ${output}"
	fi
	return 0
}

# --- Test 16: Provider metadata-only rate limits count for per-issue thresholding ---
test_provider_metadata_rate_limit_entries_count() {
	reset_test_state
	local now
	now=$(date +%s)
	local past=$(( now - 60 ))
	write_provider_metadata_rate_limit_entries "23065" 4 "$past"

	local rc=0
	local output=""
	output=$(check_dispatch_backoff "23065" "owner/repo" 2>&1 >/dev/null) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "provider metadata-only rate limits trigger per-issue backoff"
	else
		fail "provider metadata-only rate limits trigger per-issue backoff" "got exit ${rc} output=${output}"
	fi
	if printf '%s' "$output" | grep -q 'BACKOFF_NOTICE_REQUIRED'; then
		pass "provider metadata-only 4+ entries emit BACKOFF_NOTICE_REQUIRED"
	else
		fail "provider metadata-only 4+ entries emit BACKOFF_NOTICE_REQUIRED" "output: ${output}"
	fi
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
test_no_events_clear
test_one_failure_elapsed_clear
test_one_failure_within_cooldown_blocked
test_two_failures_blocked
test_three_failures_blocked
test_four_failures_notice
test_missing_jsonl_fail_open
test_bypass
test_stats_counter_incremented
test_ac3_two_failures_blocks_third
test_old_events_ignored
test_different_issue_not_affected
test_provider_pressure_blocks_pool
test_rate_limit_fast_entries_trigger_notice
test_mixed_rate_limit_entries_aggregate
test_provider_metadata_rate_limit_entries_count

printf '\n'
printf '%s/%s tests passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%sFAILED: %s test(s)%s\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_NC"
	exit 1
fi
printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
