#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for pulse-diagnose-helper.sh cycle-health subcommand (t2752)
#
# Uses fixture log files — no live network or real pulse logs required.
# Log format: timestamp \t stage_name \t duration_secs \t exit_code
#             \t cycle_owner_pid [\t executor_pid]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../pulse-diagnose-helper.sh"
CYCLE_HEALTH_LIB="${SCRIPT_DIR}/../pulse-diagnose-cycle-health.sh"
WATCHDOG_LIB="${SCRIPT_DIR}/../pulse-watchdog.sh"
PASS=0
FAIL=0
TOTAL=0

# =============================================================================
# Test framework (mirrors test-pulse-diagnose-helper.sh)
# =============================================================================

assert_contains() {
	local desc="$1" needle="$2" haystack="$3"
	TOTAL=$((TOTAL + 1))
	if printf '%s' "$haystack" | grep -qF "$needle" 2>/dev/null; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s\n    expected to contain: %s\n    actual: %s\n' \
			"$desc" "$needle" "$haystack"
	fi
	return 0
}

assert_not_contains() {
	local desc="$1" needle="$2" haystack="$3"
	TOTAL=$((TOTAL + 1))
	if ! printf '%s' "$haystack" | grep -qF "$needle" 2>/dev/null; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s\n    expected NOT to contain: %s\n' "$desc" "$needle"
	fi
	return 0
}

assert_exit_code() {
	local desc="$1" expected="$2" actual="$3"
	TOTAL=$((TOTAL + 1))
	if [[ "$expected" -eq "$actual" ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s (expected exit %d, got %d)\n' "$desc" "$expected" "$actual"
	fi
	return 0
}

# =============================================================================
# Fixture setup
# =============================================================================

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FIXTURE_TIMINGS="${TMPDIR_TEST}/pulse-stage-timings.log"
FIXTURE_WRAPPER="${TMPDIR_TEST}/pulse-wrapper.log"
TEST_NOW_EPOCH=1782262800 # 2026-06-24T01:00:00Z
export PULSE_DIAGNOSE_NOW_EPOCH="$TEST_NOW_EPOCH"

# Build a fixture with two complete and two incomplete cycles.
#
# Cycle 1 (owner PID 11111, executor PIDs 51111/51112) — complete
# Cycle 2 (PID 22222) — degraded: cleanup_worktrees exits 124 (timeout), stops early
# Cycle 3 (PID 33333) — complete: reaches preflight_early_dispatch exit 0
# Cycle 4 (PID 44444) — incomplete: cleanup_worktrees exits 124, stops (after last dispatch)
#
# The test-only clock override makes the fixed fixture recent in the 24h window.

cat > "$FIXTURE_TIMINGS" <<'TIMINGS'
2026-06-24T00:00:01Z	cleanup_orphans	2	0	11111	51111
2026-06-24T00:00:03Z	cleanup_stale_opencode	2	0	11111	51112
2026-06-24T00:00:05Z	cleanup_stalled_workers	2	0	11111
2026-06-24T00:01:10Z	cleanup_worktrees	5	0	11111
2026-06-24T00:01:20Z	cleanup_stashes	3	0	11111
2026-06-24T00:02:00Z	preflight_cleanup_and_ledger	60	0	11111
2026-06-24T00:03:00Z	preflight_capacity_and_labels	60	0	11111
2026-06-24T00:05:00Z	preflight_early_dispatch	120	0	11111
2026-06-24T00:06:00Z	deterministic_merge_pass	30	0	11111
2026-06-24T00:10:01Z	cleanup_orphans	2	0	22222
2026-06-24T00:10:03Z	cleanup_stale_opencode	2	0	22222
2026-06-24T00:10:05Z	cleanup_stalled_workers	2	0	22222
2026-06-24T00:11:10Z	cleanup_worktrees	61	124	22222
2026-06-24T00:11:20Z	cleanup_stashes	5	0	22222
2026-06-24T00:20:01Z	cleanup_orphans	2	0	33333
2026-06-24T00:20:03Z	cleanup_stale_opencode	2	0	33333
2026-06-24T00:20:05Z	cleanup_stalled_workers	2	0	33333
2026-06-24T00:21:10Z	cleanup_worktrees	61	124	33333
2026-06-24T00:21:20Z	cleanup_stashes	3	0	33333
2026-06-24T00:22:00Z	preflight_cleanup_and_ledger	55	0	33333
2026-06-24T00:23:00Z	preflight_capacity_and_labels	58	0	33333
2026-06-24T00:26:00Z	preflight_early_dispatch	180	0	33333
2026-06-24T00:27:00Z	deterministic_merge_pass	35	0	33333
2026-06-24T00:30:01Z	cleanup_orphans	2	0	44444
2026-06-24T00:30:03Z	cleanup_stale_opencode	2	0	44444
2026-06-24T00:30:05Z	cleanup_stalled_workers	2	0	44444
2026-06-24T00:31:10Z	cleanup_worktrees	62	124	44444
2026-06-24T00:31:20Z	cleanup_stashes	4	0	44444
2026-06-24T00:32:00Z	post_merge_scanner	602	124	44444
2026-06-24T00:33:00Z	post_merge_scanner	602	124	44444
TIMINGS

# Wrapper log: 3 acquired, 2 exited early = 40% churn
cat > "$FIXTURE_WRAPPER" <<'WRAPPER'
[pulse-wrapper] Instance lock acquired via mkdir (PID 11111)
[pulse-wrapper] Instance lock acquired via mkdir (PID 22222)
[pulse-wrapper] Another pulse instance holds the mkdir lock (PID 22222, age 30s, LOCKDIR=...) — exiting immediately (GH#4513)
[pulse-wrapper] Instance lock acquired via mkdir (PID 33333)
[pulse-wrapper] Another pulse instance holds the mkdir lock (PID 33333, age 25s, LOCKDIR=...) — exiting immediately (GH#4513)
[pulse-wrapper] Instance lock acquired via mkdir (PID 44444)
WRAPPER

# =============================================================================
# Tests
# =============================================================================

printf '\n=== pulse-diagnose-helper.sh cycle-health tests ===\n\n'

# --- Test 1: cycle-health runs without errors on healthy data ---
printf 'Test 1: cycle-health runs without error\n'
rc=0
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
	PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health --window 24h 2>&1) || rc=$?
assert_exit_code "exits 0 on valid data" 0 "$rc"
assert_contains "output shows 'Cycle Health'" "Cycle Health" "$output"
assert_contains "output shows cycle summary" "Cycle summary" "$output"
assert_contains "output shows wrapper churn" "Wrapper churn" "$output"

# --- Test 2: stage table shows correct counts ---
printf '\nTest 2: stage stats computed correctly\n'
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
	PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health --window 24h 2>&1) || true
assert_contains "shows cleanup_orphans stage" "cleanup_orphans" "$output"
assert_contains "shows preflight_early_dispatch stage" "preflight_early_dispatch" "$output"
assert_contains "shows deterministic_merge_pass stage" "deterministic_merge_pass" "$output"

# --- Test 3: [DEGRADED] marker for cleanup_worktrees (3/4 = 75% timeout) ---
printf '\nTest 3: DEGRADED marker when timeout rate > 50%%\n'
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
	PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health --window 24h 2>&1) || true
assert_contains "flags cleanup_worktrees as DEGRADED" "[DEGRADED]" "$output"
# cleanup_stashes has 0% timeout — should not be DEGRADED
assert_not_contains "does not flag cleanup_stashes DEGRADED (0% timeout)" \
	"cleanup_stashes" "$(printf '%s' "$output" | grep '\[DEGRADED\]')"

# --- Test 4: cycle stats (4 started, 2 reached dispatch) ---
printf '\nTest 4: cycle-level counters\n'
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
	PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health --window 24h 2>&1) || true
assert_contains "cycles started = 4" "4" "$(printf '%s' "$output" | grep 'Cycles started')"
assert_contains "fill-floor cycles = 2" "2" "$(printf '%s' "$output" | grep 'reached dispatch')"
# cycles_since_ff: PID 44444 started after last fill-floor (PID 33333) → 1
assert_contains "cycles since last dispatch present" "Cycles since last dispatch" "$output"

# --- Test 5: wrapper churn stats ---
printf '\nTest 5: wrapper churn (40%%)\n'
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
	PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health --window 24h 2>&1) || true
assert_contains "shows acquired count 4" "Acquired lock: 4" "$output"
assert_contains "shows exited early count 2" "Exited early: 2" "$output"
assert_contains "shows churn pct 33" "33%" "$output"

# --- Test 6: --json emits parseable JSON via jq ---
printf '\nTest 6: --json output is valid JSON\n'
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
	PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health --window 24h --json 2>&1) || true
if command -v jq >/dev/null 2>&1; then
	rc=0
	parsed=$(printf '%s' "$output" | jq '.' 2>/dev/null) || rc=$?
	assert_exit_code "--json parses via jq" 0 "$rc"
	cycles=$(printf '%s' "$output" | jq '.cycles_started' 2>/dev/null || echo "-1")
	assert_contains "--json cycles_started = 4" "4" "$cycles"
	ff=$(printf '%s' "$output" | jq '.fill_floor_cycles' 2>/dev/null || echo "-1")
	assert_contains "--json fill_floor_cycles = 2" "2" "$ff"
	stage_count=$(printf '%s' "$output" | jq '.stages | length' 2>/dev/null || echo "0")
	TOTAL=$((TOTAL + 1))
	if [[ "$stage_count" -ge 5 ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ --json stages array has >=5 entries (got %s)\n' "$stage_count"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ --json stages array has >=5 entries (got %s)\n' "$stage_count"
	fi
	# Verify degraded field present
	has_degraded=$(printf '%s' "$output" | jq '.stages[0].degraded != null' 2>/dev/null || echo "false")
	assert_contains "--json stages have degraded field" "true" "$has_degraded"
else
	printf '  (skipping jq validation — jq not installed)\n'
fi

# --- Test 7: --window flag is respected (narrow window excludes old entries) ---
printf '\nTest 7: --window 1m excludes all fixture data (all entries are old)\n'
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
	PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health --window 1m 2>&1) || true
assert_contains "no data in 1m window" "No stage timing data" "$output"

# --- Test 8: missing pulse-stage-timings.log handled gracefully (exit 0) ---
printf '\nTest 8: missing timings log is handled gracefully\n'
rc=0
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="/nonexistent/pulse-stage-timings.log" \
	PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health 2>&1) || rc=$?
assert_exit_code "exits 0 when timings log missing" 0 "$rc"
assert_contains "reports no stage data" "No stage timing data" "$output"
assert_contains "still shows cycle summary" "Cycle summary" "$output"

# --- Test 9: missing wrapper log handled gracefully ---
printf '\nTest 9: missing wrapper log is handled gracefully\n'
rc=0
output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
	PULSE_DIAGNOSE_WRAPPER_LOG="/nonexistent/pulse-wrapper.log" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	"$HELPER" cycle-health --window 24h 2>&1) || rc=$?
assert_exit_code "exits 0 when wrapper log missing" 0 "$rc"
assert_contains "shows 0 acquired" "Acquired lock: 0" "$output"

# --- Test 10: --json emits degraded=true for cleanup_worktrees ---
printf '\nTest 10: --json degraded flag correct for DEGRADED stage\n'
if command -v jq >/dev/null 2>&1; then
	output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
		PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
		PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
		"$HELPER" cycle-health --window 24h --json 2>&1) || true
	degraded_stages=$(printf '%s' "$output" | \
		jq -r '[.stages[] | select(.degraded==true) | .stage] | join(",")' 2>/dev/null || echo "")
	assert_contains "--json marks cleanup_worktrees as degraded" "cleanup_worktrees" "$degraded_stages"
else
	printf '  (skipping jq validation — jq not installed)\n'
fi

# --- Test 11: cycle-health shows in help text ---
printf '\nTest 11: --json keeps degraded marker out of empty last_ok_ts\n'
if command -v jq >/dev/null 2>&1; then
	output=$(PULSE_DIAGNOSE_TIMINGS_FILE="$FIXTURE_TIMINGS" \
		PULSE_DIAGNOSE_WRAPPER_LOG="$FIXTURE_WRAPPER" \
		PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
		"$HELPER" cycle-health --window 24h --json 2>&1) || true
	post_merge_last_ok=$(printf '%s' "$output" | \
		jq -r '.stages[] | select(.stage=="post_merge_scanner") | .last_ok_ts' 2>/dev/null || echo "missing")
	post_merge_degraded=$(printf '%s' "$output" | \
		jq -r '.stages[] | select(.stage=="post_merge_scanner") | .degraded' 2>/dev/null || echo "false")
	TOTAL=$((TOTAL + 1))
	if [[ -z "$post_merge_last_ok" ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ post_merge_scanner has empty last_ok_ts\n'
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ post_merge_scanner last_ok_ts should be empty, got: %s\n' "$post_merge_last_ok"
	fi
	assert_contains "post_merge_scanner remains degraded" "true" "$post_merge_degraded"
else
	printf '  (skipping jq validation — jq not installed)\n'
fi

# --- Test 12: cycle-health shows in help text ---
printf '\nTest 12: cycle-health appears in help output\n'
output=$("$HELPER" help 2>&1) || true
assert_contains "help shows cycle-health command" "cycle-health" "$output"
assert_contains "help shows window option" "window <W>" "$output"

# --- Test 13: unknown option returns error ---
printf '\nTest 13: unknown option returns non-zero exit\n'
rc=0
"$HELPER" cycle-health --invalid-flag 2>/dev/null || rc=$?
assert_exit_code "unknown option exits non-zero" 1 "$rc"

# --- Test 14: cutoff helper defaults a missing window safely ---
printf '\nTest 14: cutoff helper defaults a missing window\n'
rc=0
output=$(
	unset SCRIPT_DIR
	# shellcheck source=../pulse-diagnose-cycle-health.sh
	source "$CYCLE_HEALTH_LIB"
	_ch_cutoff_ts
) || rc=$?
assert_exit_code "missing cutoff window exits 0" 0 "$rc"
assert_contains "missing cutoff window defaults to one hour" "2026-06-24T00:00:00Z" "$output"

# --- Test 15: wrapper churn accepts a leading-dash filename ---
printf '\nTest 15: wrapper churn accepts a leading-dash filename\n'
cp "$FIXTURE_WRAPPER" "${TMPDIR_TEST}/-wrapper.log"
rc=0
output=$(
	cd "$TMPDIR_TEST"
	unset SCRIPT_DIR
	# shellcheck source=../pulse-diagnose-cycle-health.sh
	source "$CYCLE_HEALTH_LIB"
	_ch_wrapper_churn "-wrapper.log"
) || rc=$?
assert_exit_code "leading-dash wrapper filename exits 0" 0 "$rc"
assert_contains "leading-dash wrapper filename is counted" "acquired=4" "$output"

# --- Test 16: extended rows preserve owner aggregation across executors ---
printf '\nTest 16: multiple executors remain one owner cycle\n'
rc=0
output=$(
	unset SCRIPT_DIR
	# shellcheck source=../pulse-diagnose-cycle-health.sh
	source "$CYCLE_HEALTH_LIB"
	_ch_cycle_stats "$FIXTURE_TIMINGS" "2026-06-24T00:00:00Z"
) || rc=$?
assert_exit_code "mixed legacy and extended timing rows exit 0" 0 "$rc"
assert_contains "multiple executors under one owner still produce four cycles" "cycles_started=4" "$output"

# --- Test 17: substage timing records the background executor ---
printf '\nTest 17: substage timing records its background executor\n'
EXECUTOR_TIMINGS="${TMPDIR_TEST}/executor-timings.log"
(
	# shellcheck source=../pulse-watchdog.sh
	source "$WATCHDOG_LIB"
	LOGFILE="${TMPDIR_TEST}/executor-wrapper.log"
	PULSE_STAGE_TIMINGS_LOG="$EXECUTOR_TIMINGS"
	_log_substage_timing "substage:test/executor" "$SECONDS" 0
) &
executor_pid=$!
wait "$executor_pid"
output=$(<"$EXECUTOR_TIMINGS")
assert_contains "sixth field identifies the background executor" $'\t'"${executor_pid}" "$output"

# --- Test 18: Bash 3.2 fallback resolves the calling background process ---
printf '\nTest 18: executor fallback resolves its background caller\n'
FALLBACK_EXECUTOR="${TMPDIR_TEST}/fallback-executor-pid"
(
	# shellcheck source=../pulse-watchdog.sh
	source "$WATCHDOG_LIB"
	_pulse_resolve_executor_pid ""
	printf '%s' "$_PULSE_EXECUTOR_PID" >"$FALLBACK_EXECUTOR"
) &
executor_pid=$!
wait "$executor_pid"
output=$(<"$FALLBACK_EXECUTOR")
assert_contains "PPID fallback identifies the background caller" "$executor_pid" "$output"

# --- Test 19: executor lookup failure does not suppress a timing row ---
printf '\nTest 19: executor lookup failure remains non-blocking\n'
FAILURE_TIMINGS="${TMPDIR_TEST}/executor-failure-timings.log"
rc=0
(
	# shellcheck source=../pulse-watchdog.sh
	source "$WATCHDOG_LIB"
	_pulse_resolve_executor_pid() { return 1; }
	LOGFILE="${TMPDIR_TEST}/executor-failure-wrapper.log"
	PULSE_STAGE_TIMINGS_LOG="$FAILURE_TIMINGS"
	_log_substage_timing "substage:test/fallback" "$SECONDS" 0
) || rc=$?
assert_exit_code "failed executor lookup does not fail the caller" 0 "$rc"
output=$(<"$FAILURE_TIMINGS")
assert_contains "failed executor lookup writes explicit unavailable identity" $'\tunavailable' "$output"

# =============================================================================
# Summary
# =============================================================================

printf '\n=== Results: %d passed, %d failed, %d total ===\n\n' "$PASS" "$FAIL" "$TOTAL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
