#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-fast-fail-age-out.sh — t2397 regression guard.
#
# Asserts that fast_fail_age_out() auto-resets the counter for HARD STOP'd
# issues whose last failure timestamp is older than FAST_FAIL_AGE_OUT_SECONDS,
# and does NOT reset for issues below the threshold, too recent, or in-progress.
#
# Production context (GH#19958, t2397):
#   Issues #19864 and #19740 accumulated count=6 (HARD STOP) and would never
#   dispatch again. Many failures were transient (model-availability pre-t2392,
#   CI flakes). Manual recovery required touching the counter file — operators
#   rarely do this, leaving issues permanently stuck.
#
# Assertions (13):
#   1. HARD STOP + age > 24h → counter reset to 0
#   2. HARD STOP + age < 24h → NOT reset (quiet-period guard)
#   3. count < HARD STOP (below threshold) → NOT affected
#   4. After reset, fast_fail_is_skipped returns 1 (safe to dispatch)
#   5. reset_count increments on each age-out
#   6. After FAST_FAIL_AGE_OUT_MAX_RESETS, the counter is not reset
#   7. After FAST_FAIL_AGE_OUT_MAX_RESETS, status:blocked is applied
#   8. Exhausted age-out retries route to consolidation
#   9. Issue comment posted once per age-out event
#  10. Infra/no_work hard stops use FAST_FAIL_INFRA_AGE_OUT_SECONDS
#  11. Non-rate-limit threshold crossing routes consolidation exactly once
#  12. Hard-stop checks reuse the persisted consolidation handoff marker
#  13. Rate-limit hard stops do not consolidate issue scope
#
# Stub strategy:
#   - Set FAST_FAIL_STATE_FILE to a tmpdir path so tests are hermetic.
#   - Override FAST_FAIL_AGE_OUT_SECONDS to a small value (10s) so we can
#     set ts=now-20 and satisfy the quiet-period condition without sleeping.
#   - Stub gh() to capture label/comment calls without hitting the API.
#   - Set LOGFILE to a tmp path to capture log output.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
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
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2397.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
LOGFILE="${TMP}/pulse.log"
export LOGFILE

# Speed up tests: use 10s quiet period so ts=(now-20) satisfies the condition.
export FAST_FAIL_AGE_OUT_SECONDS=10
export FAST_FAIL_AGE_OUT_MIN_COUNT=5
export FAST_FAIL_AGE_OUT_MAX_RESETS=3
# Keep SKIP_THRESHOLD consistent with MIN_COUNT
export FAST_FAIL_SKIP_THRESHOLD=5
export FAST_FAIL_EXPIRY_SECS=604800
export FAST_FAIL_INITIAL_BACKOFF_SECS=600
export FAST_FAIL_MAX_BACKOFF_SECS=604800

FAST_FAIL_STATE_FILE="${TMP}/fast-fail-counter.json"
export FAST_FAIL_STATE_FILE

# =============================================================================
# Stubs — defined before sourcing so the include guard doesn't prevent override
# =============================================================================

# Stub print_* to silence noise
print_info() { :; return 0; }
print_warning() { :; return 0; }
print_error() { :; return 0; }
print_success() { :; return 0; }
log_verbose() { :; return 0; }
export -f print_info print_warning print_error print_success log_verbose

# Source shared-constants.sh to get jq helpers, then source pulse-fast-fail.sh
# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# gh stub: record all calls; return success
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	return 0
}
export -f gh

# escalate_issue_tier stub (called by _fast_fail_record_locked)
escalate_issue_tier() {
	return 0
}
export -f escalate_issue_tier

CONSOLIDATION_CALLS=0
LAST_CONSOLIDATION=""
_route_terminal_breaker_to_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local breaker_source="$3"
	local breaker_detail="${4:-}"
	CONSOLIDATION_CALLS=$((CONSOLIDATION_CALLS + 1))
	LAST_CONSOLIDATION="${issue_number}|${repo_slug}|${breaker_source}|${breaker_detail}"
	return 0
}

# Source fast-fail module (include guard prevents double-source)
# shellcheck source=../pulse-fast-fail.sh
source "${SCRIPTS_DIR}/pulse-fast-fail.sh" >/dev/null 2>&1 || {
	printf '%sFATAL%s Could not source pulse-fast-fail.sh\n' "$TEST_RED" "$TEST_NC"
	exit 1
}

# Capture lifecycle transitions after the production module has sourced the
# shared wrapper implementation.
set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status="$3"
	shift 3
	printf 'set_issue_status %s %s %s %s\n' "$issue_number" "$repo_slug" "$status" "$*" >>"${GH_CALLS}"
	return 0
}

printf '%sRunning fast_fail_age_out tests (t2397)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Helper: write a fast-fail entry directly to the state file
# Arguments: issue count ts_offset(seconds_ago) [reset_count]
# =============================================================================
_write_ff_entry() {
	local issue="$1"
	local count="$2"
	local ts_offset="$3"
	local rcount="${4:-0}"
	local reason="${5:-crash}"
	local crash_type="${6:-}"
	local slug="test/repo"
	local now
	now=$(date +%s)
	local ts=$((now - ts_offset))
	printf '{"test/repo/%s":{"count":%s,"ts":%s,"reason":"%s","retry_after":0,"backoff_secs":600,"crash_type":"%s","reset_count":%s}}\n' \
		"$issue" "$count" "$ts" "$reason" "$crash_type" "$rcount" >"$FAST_FAIL_STATE_FILE"
	return 0
}

# =============================================================================
# Test 1 — HARD STOP + last failure > AGE_OUT threshold → reset to 0
# =============================================================================
: >"$GH_CALLS"
_write_ff_entry "100" "6" "20"  # count=6, ts=20s ago (>10s threshold)

fast_fail_age_out "100" "test/repo" 2>/dev/null || true

result_count=$(jq -r '."test/repo/100".count // -1' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || result_count="-1"
if [[ "$result_count" == "0" ]]; then
	pass "HARD STOP + age > threshold → counter reset to 0"
else
	fail "HARD STOP + age > threshold → counter reset to 0" \
		"expected count=0, got count=${result_count}"
fi

# =============================================================================
# Test 2 — HARD STOP + last failure < AGE_OUT threshold → NOT reset
# =============================================================================
_write_ff_entry "101" "6" "5"   # count=6, ts=5s ago (<10s threshold)

fast_fail_age_out "101" "test/repo" 2>/dev/null || true

result_count=$(jq -r '."test/repo/101".count // -1' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || result_count="-1"
if [[ "$result_count" == "6" ]]; then
	pass "HARD STOP + age < threshold → NOT reset (quiet-period guard)"
else
	fail "HARD STOP + age < threshold → NOT reset (quiet-period guard)" \
		"expected count=6 (unchanged), got count=${result_count}"
fi

# =============================================================================
# Test 3 — count below HARD STOP → NOT affected
# =============================================================================
_write_ff_entry "102" "3" "20"  # count=3 (below threshold=5), ts=20s ago

fast_fail_age_out "102" "test/repo" 2>/dev/null || true

result_count=$(jq -r '."test/repo/102".count // -1' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || result_count="-1"
if [[ "$result_count" == "3" ]]; then
	pass "count < HARD STOP threshold → NOT affected by age-out"
else
	fail "count < HARD STOP threshold → NOT affected by age-out" \
		"expected count=3 (unchanged), got count=${result_count}"
fi

# =============================================================================
# Test 4 — after reset, fast_fail_is_skipped returns 1 (safe to dispatch)
# =============================================================================
_write_ff_entry "103" "6" "20"  # HARD STOP'd, old enough

fast_fail_age_out "103" "test/repo" 2>/dev/null || true

skip_rc=0
fast_fail_is_skipped "103" "test/repo" 2>/dev/null || skip_rc=$?
if [[ "$skip_rc" -eq 1 ]]; then
	pass "after age-out reset, fast_fail_is_skipped returns 1 (safe to dispatch)"
else
	fail "after age-out reset, fast_fail_is_skipped returns 1 (safe to dispatch)" \
		"expected rc=1 (not skipped), got rc=${skip_rc}"
fi

# =============================================================================
# Test 5 — reset_count increments on each age-out
# =============================================================================
_write_ff_entry "104" "6" "20" "1"  # already had 1 prior reset

fast_fail_age_out "104" "test/repo" 2>/dev/null || true

result_reset=$(jq -r '."test/repo/104".reset_count // -1' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || result_reset="-1"
if [[ "$result_reset" == "2" ]]; then
	pass "reset_count increments from 1 to 2 on second age-out"
else
	fail "reset_count increments from 1 to 2 on second age-out" \
		"expected reset_count=2, got reset_count=${result_reset}"
fi

# =============================================================================
# Test 6 — after MAX_RESETS, structural block applied (not another reset)
# =============================================================================
: >"$GH_CALLS"
# reset_count=3 means this would be the 4th reset (> max=3), so the block fires.
_write_ff_entry "105" "6" "20" "3"
CONSOLIDATION_CALLS=0
LAST_CONSOLIDATION=""

fast_fail_age_out "105" "test/repo" 2>/dev/null || true

# count should NOT have been reset to 0 (ceiling triggered a structural block instead)
result_count=$(jq -r '."test/repo/105".count // -1' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || result_count="-1"
gh_calls_content=$(cat "$GH_CALLS" 2>/dev/null || true)

if [[ "$result_count" == "6" ]]; then
	pass "after MAX_RESETS exceeded → counter NOT reset (ceiling guard active)"
else
	fail "after MAX_RESETS exceeded → counter NOT reset (ceiling guard active)" \
		"expected count=6 (unchanged), got count=${result_count}"
fi

if printf '%s' "$gh_calls_content" | grep -q "set_issue_status 105 test/repo blocked" \
	&& ! printf '%s' "$gh_calls_content" | grep -q -- "--add-label needs-maintainer-review"; then
	pass "after MAX_RESETS exceeded → status:blocked applied without NMR"
else
	fail "after MAX_RESETS exceeded → status:blocked applied without NMR" \
		"expected blocked lifecycle transition without NMR addition: ${gh_calls_content}"
fi

if [[ "$CONSOLIDATION_CALLS" -eq 1 && "$LAST_CONSOLIDATION" == "105|test/repo|fast-fail-age-out-ceiling|maximum automatic resets exhausted" ]]; then
	pass "after MAX_RESETS exceeded → terminal outcome routes to consolidation"
else
	fail "after MAX_RESETS exceeded → terminal outcome routes to consolidation" \
		"calls=${CONSOLIDATION_CALLS} payload=${LAST_CONSOLIDATION}"
fi

# =============================================================================
# Test 7 — issue comment posted once per age-out event
# =============================================================================
: >"$GH_CALLS"
_write_ff_entry "106" "6" "20"  # fresh HARD STOP, old enough

fast_fail_age_out "106" "test/repo" 2>/dev/null || true

gh_calls_content=$(cat "$GH_CALLS" 2>/dev/null || true)
if printf '%s' "$gh_calls_content" | grep -q "issue comment"; then
	pass "age-out fires → issue comment posted"
else
	fail "age-out fires → issue comment posted" \
		"expected 'issue comment' in gh calls: ${gh_calls_content}"
fi

# =============================================================================
# Test 8 — infra/no_work hard stops use shorter recovery age
# =============================================================================
export FAST_FAIL_INFRA_AGE_OUT_SECONDS=5
export FAST_FAIL_AGE_OUT_SECONDS=100
_write_ff_entry "107" "6" "20" "0" "stale_timeout" "no_work"

fast_fail_age_out "107" "test/repo" 2>/dev/null || true

result_count=$(jq -r '."test/repo/107".count // -1' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || result_count="-1"
if [[ "$result_count" == "0" ]]; then
	pass "infra/no_work HARD STOP uses shorter age-out threshold"
else
	fail "infra/no_work HARD STOP uses shorter age-out threshold" \
		"expected count=0, got count=${result_count}"
fi

# =============================================================================
# Assertions 11-13 — terminal fast-fail consolidation routing and dedup
# =============================================================================
export FAST_FAIL_SKIP_THRESHOLD=2
export FAST_FAIL_AGE_OUT_MIN_COUNT=2
CONSOLIDATION_CALLS=0
LAST_CONSOLIDATION=""
printf '{}\n' >"$FAST_FAIL_STATE_FILE"

fast_fail_record "108" "test/repo" "runtime" 2>/dev/null || true
fast_fail_record "108" "test/repo" "runtime" 2>/dev/null || true

route_marker=$(jq -r '."test/repo/108".terminal_consolidation_routed // false' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || route_marker=false
if [[ "$CONSOLIDATION_CALLS" -eq 1 && "$LAST_CONSOLIDATION" == "108|test/repo|fast-fail-hard-stop|reason=runtime" && "$route_marker" == "true" ]]; then
	pass "non-rate-limit threshold crossing routes consolidation exactly once"
else
	fail "non-rate-limit threshold crossing routes consolidation exactly once" \
		"calls=${CONSOLIDATION_CALLS} payload=${LAST_CONSOLIDATION} marker=${route_marker}"
fi

skip_rc=0
fast_fail_is_skipped "108" "test/repo" 2>/dev/null || skip_rc=$?
if [[ "$skip_rc" -eq 0 && "$CONSOLIDATION_CALLS" -eq 1 ]]; then
	pass "hard-stop check reuses persisted consolidation handoff marker"
else
	fail "hard-stop check reuses persisted consolidation handoff marker" \
		"skip_rc=${skip_rc} calls=${CONSOLIDATION_CALLS}"
fi

CONSOLIDATION_CALLS=0
LAST_CONSOLIDATION=""
printf '{}\n' >"$FAST_FAIL_STATE_FILE"
_ff_query_pool_retry_seconds() {
	local provider="$1"
	: "$provider"
	printf '%s' '-1'
	return 0
}
fast_fail_record "109" "test/repo" "rate_limit" 2>/dev/null || true
fast_fail_record "109" "test/repo" "rate_limit" 2>/dev/null || true
fast_fail_is_skipped "109" "test/repo" 2>/dev/null || true
if [[ "$CONSOLIDATION_CALLS" -eq 0 ]]; then
	pass "rate-limit hard stop does not consolidate issue scope"
else
	fail "rate-limit hard stop does not consolidate issue scope" \
		"calls=${CONSOLIDATION_CALLS} payload=${LAST_CONSOLIDATION}"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
