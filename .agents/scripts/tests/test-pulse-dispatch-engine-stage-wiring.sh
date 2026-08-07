#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-pulse-dispatch-engine-stage-wiring.sh — regression guard for t2443/GH#28880
#
# Verifies that post-dispatch housekeeping stages remain independently timed
# and are wired through the async housekeeping launcher, not wrapped in a
# shared-budget group that blocks worker refill.
#
# Background: _preflight_daily_scans() wrapped 4+ children under a single
# 600s timeout. A slow complexity_scan (200-340s) would exhaust the budget
# before auto_decomposer_scanner could run. t2443 promoted each scanner to
# an independent stage so each gets its own timeout budget; t3055 then moved
# those independent stages behind an async post-dispatch lock so housekeeping
# cannot hold the dispatch cycle open while worker slots drain. GH#28880 also
# keeps cross-repository label maintenance and trusted NMR reconciliation
# between two unwrapped fill passes so already-eligible work launches first and
# newly unblocked work remains eligible for the same-cycle refill.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected pattern: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_not_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  pattern should NOT match: $pattern"
		echo "  in file:                  $file"
	fi
	return 0
}

assert_order() {
	local label="$1" first_pattern="$2" second_pattern="$3" file="$4"
	local first_line="" second_line=""
	TESTS_RUN=$((TESTS_RUN + 1))
	first_line=$(grep -nEm1 "$first_pattern" "$file" 2>/dev/null | cut -d: -f1 || true)
	second_line=$(grep -nEm1 "$second_pattern" "$file" 2>/dev/null | cut -d: -f1 || true)
	if [[ "$first_line" =~ ^[0-9]+$ && "$second_line" =~ ^[0-9]+$ && "$first_line" -lt "$second_line" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  first pattern/line:  $first_pattern / ${first_line:-missing}"
		echo "  second pattern/line: $second_pattern / ${second_line:-missing}"
	fi
	return 0
}

assert_match_count() {
	local label="$1" pattern="$2" expected_count="$3" file="$4"
	local actual_count=0
	TESTS_RUN=$((TESTS_RUN + 1))
	actual_count=$(grep -cE "$pattern" "$file" 2>/dev/null || true)
	[[ "$actual_count" =~ ^[0-9]+$ ]] || actual_count=0
	if [[ "$actual_count" -eq "$expected_count" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected/actual count: $expected_count / $actual_count"
		echo "  pattern:               $pattern"
	fi
	return 0
}

assert_refill_runtime_contract() {
	local label="$1"
	local actual_events="" expected_events="dispatch:skip;routine;stage:auto_approve_maintainer_issues:7;nmr;invalidate:label_maintenance_complete;dispatch:normalize;"
	TESTS_RUN=$((TESTS_RUN + 1))
	actual_events=$(
		(
			unset _PULSE_DISPATCH_PREFLIGHT_LIB_LOADED
			# shellcheck source=../pulse-dispatch-preflight-lib.sh
			source "$PREFLIGHT_LIB"
			REFILL_EVENTS=""
			STOP_FLAG=""
			LOGFILE="/dev/null"
			PRE_RUN_STAGE_TIMEOUT=7

			_dispatch_invalidate_candidate_snapshot() {
				local reason="$1"
				REFILL_EVENTS="${REFILL_EVENTS}invalidate:${reason};"
				return 0
			}

			apply_dispatch_max() {
				local dependency_normalization_mode="${1:-normalize}"
				REFILL_EVENTS="${REFILL_EVENTS}dispatch:${dependency_normalization_mode};"
				return 0
			}

			dispatch_routine_comment_responses() {
				REFILL_EVENTS="${REFILL_EVENTS}routine;"
				return 0
			}

			run_stage_with_timeout() {
				local stage_name="$1"
				local stage_timeout="$2"
				local stage_fn="$3"
				REFILL_EVENTS="${REFILL_EVENTS}stage:${stage_name}:${stage_timeout};"
				if "$stage_fn"; then
					return 0
				fi
				return 1
			}

			auto_approve_maintainer_issues() {
				REFILL_EVENTS="${REFILL_EVENTS}nmr;"
				return 0
			}

			_preflight_early_dispatch
			_preflight_trusted_nmr_reconcile
			_preflight_post_label_refill
			STOP_FLAG="$PREFLIGHT_LIB"
			_preflight_post_label_refill
			printf '%s\n' "$REFILL_EVENTS"
		)
	)
	if [[ "$actual_events" == "$expected_events" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected events: $expected_events"
		echo "  actual events:   ${actual_events:-none}"
	fi
	return 0
}

# Resolve paths relative to this test file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$SCRIPT_DIR/pulse-dispatch-engine.sh"
CORE="$SCRIPT_DIR/pulse-dispatch-core.sh"
DISPATCH_LIB="$SCRIPT_DIR/pulse-dispatch-lib.sh"
PREFLIGHT_LIB="$SCRIPT_DIR/pulse-dispatch-preflight-lib.sh"

echo "=== t2443 + t2903: pulse-dispatch-engine stage wiring regression tests ==="
echo "Engine: $ENGINE"
echo ""

# --- Each daily scanner is still independently timed inside housekeeping ---
#
# t2903 (#21049): complexity_scan was REMOVED from the dispatch engine and
# moved to its own launchd plist (sh.aidevops.complexity-scan) backed by
# complexity-scan-runner.sh. The function still exists in pulse-simplification.sh
# but is no longer invoked from the preflight stages. Slot #1 below is the
# negative assertion that pins the removal.

assert_not_grep \
	"1: complexity_scan extracted to standalone launchd plist (t2903) — must NOT be in dispatch engine" \
	'run_stage_with_timeout "complexity_scan"' \
	"$ENGINE"

# Assertions 2-6: each stage uses two separate greps (2a/2b pattern) because the
# dispatch engine wires stages with a backslash line-continuation:
#   _pulse_run_optional_stage_with_timeout "coderabbit_review" "$stage_timeout" run_daily_codebase_review || true
# Single-line grep -E cannot span the newline, so split into stage-name + function-name.

assert_grep \
	"2a: coderabbit_review stage call present" \
	'_pulse_run_optional_stage_with_timeout "coderabbit_review"' \
	"$ENGINE"
assert_grep \
	"2b: coderabbit_review function name present" \
	'run_daily_codebase_review' \
	"$ENGINE"

assert_grep \
	"3a: post_merge_scanner stage call present" \
	'_pulse_run_optional_stage_with_timeout "post_merge_scanner"' \
	"$ENGINE"
assert_grep \
	"3b: post_merge_scanner function name present" \
	'_run_post_merge_review_scanner' \
	"$ENGINE"

assert_grep \
	"3c: pr_review_thread_response stage call present" \
	'_pulse_run_optional_stage_with_timeout "pr_review_thread_response"' \
	"$ENGINE"
assert_grep \
	"3d: pr_review_thread_response function name present" \
	'_run_pr_review_thread_response_scanner' \
	"$ENGINE"

assert_grep \
	"4a: auto_decomposer_scanner stage call present" \
	'_pulse_run_optional_stage_with_timeout "auto_decomposer_scanner"' \
	"$ENGINE"
assert_grep \
	"4b: auto_decomposer_scanner function name present" \
	'_run_auto_decomposer_scanner' \
	"$ENGINE"

assert_grep \
	"5a: dedup_cleanup stage call present" \
	'_pulse_run_optional_stage_with_timeout "dedup_cleanup"' \
	"$ENGINE"
assert_grep \
	"5b: dedup_cleanup function name present" \
	'run_simplification_dedup_cleanup' \
	"$ENGINE"

assert_grep \
	"6a: fast_fail_prune_expired stage call present" \
	'_pulse_run_optional_stage_with_timeout "fast_fail_prune_expired"' \
	"$ENGINE"
assert_grep \
	"6b: fast_fail_prune_expired function name present" \
	'fast_fail_prune_expired' \
	"$ENGINE"

# --- The shared-budget wrapper must NOT exist ---

assert_not_grep \
	"7: _preflight_daily_scans() function wrapper removed (no shared budget)" \
	'^_preflight_daily_scans\(\)' \
	"$ENGINE"

assert_not_grep \
	"8: no run_stage_with_timeout wrapping preflight_daily_scans as a group" \
	'run_stage_with_timeout "preflight_daily_scans"' \
	"$ENGINE"

# --- The async launcher receives the same timeout variable as peer preflight groups ---
# (complexity_scan removed in t2903 — moved to standalone launchd plist;
# kept the launcher call as the canary for _pflt_timeout wiring.)

assert_grep \
	"9: async post-dispatch housekeeping uses _pflt_timeout" \
	'_pulse_start_post_dispatch_housekeeping "\$_pflt_timeout"' \
	"$ENGINE"

# --- Already-eligible work launches before cross-repository label maintenance ---

assert_grep \
	"9a: capacity calculation is an independently timed preflight stage" \
	'run_stage_with_timeout "preflight_capacity"' \
	"$ENGINE"
assert_grep \
	"9b: label maintenance is an independently timed preflight stage" \
	'_pulse_run_budget_priority_stage_with_timeout "preflight_label_maintenance"' \
	"$ENGINE"
assert_grep \
	"9c: capacity and label maintenance use separate helper functions" \
	'^_preflight_label_maintenance\(\)' \
	"$PREFLIGHT_LIB"
assert_grep \
	"9d: post-label refill has a dedicated helper" \
	'^_preflight_post_label_refill\(\)' \
	"$PREFLIGHT_LIB"
assert_grep \
	"9d2: trusted NMR reconciliation has a dedicated helper" \
	'^_preflight_trusted_nmr_reconcile\(\)' \
	"$PREFLIGHT_LIB"
assert_order \
	"9e: capacity completes before the initial fill" \
	'^[[:space:]]*run_stage_with_timeout "preflight_capacity"' \
	'^[[:space:]]*_pulse_run_budget_priority_stage "preflight_early_dispatch"' \
	"$ENGINE"
assert_order \
	"9f: initial fill precedes label maintenance" \
	'^[[:space:]]*_pulse_run_budget_priority_stage "preflight_early_dispatch"' \
	'^[[:space:]]*_pulse_run_budget_priority_stage_with_timeout "preflight_label_maintenance"' \
	"$ENGINE"
assert_order \
	"9g: label maintenance precedes trusted NMR reconciliation" \
	'^[[:space:]]*_pulse_run_budget_priority_stage_with_timeout "preflight_label_maintenance"' \
	'^[[:space:]]*_pulse_run_budget_priority_stage "preflight_trusted_nmr_reconcile"' \
	"$ENGINE"
assert_order \
	"9g2: trusted NMR reconciliation precedes the same-cycle refill" \
	'^[[:space:]]*_pulse_run_budget_priority_stage "preflight_trusted_nmr_reconcile"' \
	'^[[:space:]]*_pulse_run_budget_priority_stage "preflight_post_label_refill"' \
	"$ENGINE"
assert_order \
	"9h: post-label refill precedes async housekeeping" \
	'^[[:space:]]*_pulse_run_budget_priority_stage "preflight_post_label_refill"' \
	'^[[:space:]]*_pulse_start_post_dispatch_housekeeping([[:space:]]|$)' \
	"$ENGINE"
assert_not_grep \
	"9i: initial fill is not wrapped by the group timeout" \
	'run_stage_with_timeout "preflight_early_dispatch"' \
	"$ENGINE"
assert_not_grep \
	"9j: post-label refill is not wrapped by the group timeout" \
	'run_stage_with_timeout "preflight_post_label_refill"' \
	"$ENGINE"
assert_match_count \
	"9k: routine comment responses run only during the initial fill" \
	'^[[:space:]]*dispatch_routine_comment_responses[[:space:]]*\|\|[[:space:]]*true' \
	1 \
	"$PREFLIGHT_LIB"
assert_match_count \
	"9k2: trusted NMR reconciliation runs exactly once per preflight" \
	'^[[:space:]]*run_stage_with_timeout "auto_approve_maintainer_issues"' \
	1 \
	"$PREFLIGHT_LIB"
assert_refill_runtime_contract \
	"9l: trusted NMR reconciliation completes before the normalized refill"

# --- Benign expected dispatch blocks must not be surfaced as generic stage failures ---

assert_grep \
	"10a: dispatch stage adapter preserves benign block rc" \
	'_dispatch_stage_rc_adapter' \
	"$DISPATCH_LIB"
assert_grep \
	"10b: interactive review hold is recognized as a benign block" \
	'interactive_review_hold' \
	"$DISPATCH_LIB"
assert_grep \
	"10b1: PR targets are recognized as benign dispatch blocks" \
	'pr_target_not_dispatchable' \
	"$DISPATCH_LIB"
assert_grep \
	"10b1b: Renovate Dependency Dashboard is recognized as a benign dispatch block" \
	'renovate_dependency_dashboard' \
	"$DISPATCH_LIB"
assert_grep \
	"10b2: benign blocks are logged distinctly, not as pre-launch failures" \
	'blocked:\$\{failure_reason\} benign dispatch block' \
	"$DISPATCH_LIB"
assert_grep \
	"10b3: active claim dedup returns benign rc=3 to suppress Stage failed" \
	'_dedup_layer6_assignee_and_stale.*&& return 3' \
	"$CORE"
assert_grep \
	"10b4: refill skips candidates blocked by active claim in current cycle" \
	'skip:already_assigned blocked:' \
	"$DISPATCH_LIB"

assert_grep \
	"10c: dispatch stage adapter reports rc-file write failures" \
	'Failed to write dispatch rc to' \
	"$DISPATCH_LIB"
assert_grep \
	"10d: dispatch stage adapter propagates raw rc after rc-file write failure" \
	'return "\$raw_rc"' \
	"$DISPATCH_LIB"
assert_not_grep \
	"10e: benign block reasons are not counted as candidate failure reasons" \
	'dedup_active_claim \| cost_budget_exceeded' \
	"$DISPATCH_LIB"

# --- Summary ---

echo ""
echo "=== Results: $TESTS_RUN tests, $TESTS_FAILED failures ==="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
