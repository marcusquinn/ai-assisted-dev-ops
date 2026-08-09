#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the AIDEVOPS_HEADLESS=true export at the top of stats-wrapper.sh
# main() (GH#19913 / t2390).
#
# Background: stats-wrapper.sh is the second entry point (after
# pulse-wrapper.sh) that reaches gh_create_issue through a separate
# scheduler (15-min aidevops-stats-wrapper.timer / launchd plist). PR
# #18676 (GH#18670) added the headless export to pulse-wrapper.sh only;
# stats-wrapper.sh was missed, and every quality-debt issue the stats
# sweep created landed with origin:interactive + runner-assigned, which
# trips GH#18352's dispatch-dedup guard and strands the issues.
#
# Behaviors under test (mirror of test-pulse-wrapper-headless-export.sh):
#   1. The export line exists at the top of stats-wrapper.sh main(),
#      before the --self-check flag dispatch.
#   2. detect_session_origin() returns "worker" when the env var is set.
#   3. The export is inside main(), not top-level (scoping guarantee
#      for callers sourcing stats-wrapper.sh for testing).
#   4. The export precedes the --self-check dispatch so CI self-checks
#      also run under the headless env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
WRAPPER_SCRIPT="${SCRIPT_DIR}/../stats-wrapper.sh"
SHARED_CONSTANTS="${SCRIPT_DIR}/../shared-constants.sh"
HEALTH_DASHBOARD_SCRIPT="${SCRIPT_DIR}/../stats-health-dashboard.sh"

# shellcheck source=../shared-constants.sh
source "$SHARED_CONSTANTS"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

# Test 1: Static source inspection — the export line exists at the
# top of main() ABOVE the --self-check flag dispatch. This is a spec
# check rather than a runtime check, because running
# `stats-wrapper.sh --self-check` in a subprocess doesn't reveal the
# child's env to the parent.
test_export_line_present_at_top_of_main() {
	local snippet
	snippet=$(awk '
		/^main\(\) \{/ { in_main=1; next }
		in_main && /^[[:space:]]*if \[\[ "\$\{1:-\}" == "--self-check" \]\]; then/ { exit }
		in_main { print }
	' "$WRAPPER_SCRIPT")
	if printf '%s' "$snippet" | grep -qE '^[[:space:]]*export AIDEVOPS_HEADLESS=true[[:space:]]*$'; then
		print_result "export AIDEVOPS_HEADLESS=true present at top of main()" 0
		return 0
	fi
	print_result "export AIDEVOPS_HEADLESS=true present at top of main()" 1 \
		"Expected 'export AIDEVOPS_HEADLESS=true' line between 'main() {' and the '--self-check' dispatch. Got snippet:${snippet}"
	return 0
}

# Test 2: detect_session_origin() reports "worker" when AIDEVOPS_HEADLESS=true.
# Sources shared-constants.sh in a subshell, sets the env var, and invokes
# the function. This is the behavioural half of the contract — Test 1
# guarantees the export is present, Test 2 guarantees the export has the
# intended effect on detect_session_origin().
test_detect_session_origin_returns_worker_when_headless() {
	local result
	result=$(
		# shellcheck source=/dev/null
		AIDEVOPS_SESSION_ORIGIN="" \
			AIDEVOPS_HEADLESS="true" \
			FULL_LOOP_HEADLESS="" \
			OPENCODE_HEADLESS="" \
			GITHUB_ACTIONS="" \
			bash -c "source '$SHARED_CONSTANTS' 2>/dev/null; detect_session_origin"
	)
	if [[ "$result" == "worker" ]]; then
		print_result "detect_session_origin returns 'worker' when AIDEVOPS_HEADLESS=true" 0
		return 0
	fi
	print_result "detect_session_origin returns 'worker' when AIDEVOPS_HEADLESS=true" 1 \
		"Expected 'worker', got '$result'"
	return 0
}

# Test 3: The export must be INSIDE main() (indented), not at top-level.
# This is the scoping guarantee — callers sourcing stats-wrapper.sh for
# testing must not have AIDEVOPS_HEADLESS set on their behalf.
test_export_is_inside_main_not_top_level() {
	local count line_num
	count=$(safe_grep_count -E '^[[:space:]]*export AIDEVOPS_HEADLESS=true[[:space:]]*$' "$WRAPPER_SCRIPT")
	if [[ "$count" -ne 1 ]]; then
		print_result "export is inside main(), not top-level" 1 \
			"Expected exactly 1 export line, found $count"
		return 0
	fi
	line_num=$(grep -nE '^[[:space:]]*export AIDEVOPS_HEADLESS=true[[:space:]]*$' "$WRAPPER_SCRIPT" | head -1 | cut -d: -f1)
	local main_line
	main_line=$(grep -nE '^main\(\) \{' "$WRAPPER_SCRIPT" | head -1 | cut -d: -f1)
	if [[ -z "$main_line" || "$line_num" -le "$main_line" ]]; then
		print_result "export is inside main(), not top-level" 1 \
			"Export at line $line_num, main() at line ${main_line:-<not found>}. Export must be after main() {."
		return 0
	fi
	if ! sed -n "${line_num}p" "$WRAPPER_SCRIPT" | grep -qE '^[[:space:]]+export'; then
		print_result "export is inside main(), not top-level" 1 \
			"Export line is not indented — appears to be top-level code"
		return 0
	fi
	print_result "export is inside main(), not top-level" 0
	return 0
}

# Test 4: the export comes BEFORE the --self-check flag dispatch, so that
# --self-check also runs under the headless env. This matters because
# the self-check is used by CI and installation smoke tests, and those
# contexts should be treated as headless.
test_export_before_self_check() {
	local export_line sc_line
	export_line=$(grep -nE '^[[:space:]]*export AIDEVOPS_HEADLESS=true[[:space:]]*$' "$WRAPPER_SCRIPT" | head -1 | cut -d: -f1)
	sc_line=$(awk '/^main\(\) \{/{inmain=1; next} inmain && /^[[:space:]]*if \[\[ "\$\{1:-\}" == "--self-check" \]\]; then/{print NR; exit}' "$WRAPPER_SCRIPT")
	if [[ -z "$export_line" || -z "$sc_line" ]]; then
		print_result "export precedes --self-check dispatch" 1 \
			"Missing export_line=$export_line or sc_line=$sc_line"
		return 0
	fi
	if [[ "$export_line" -lt "$sc_line" ]]; then
		print_result "export precedes --self-check dispatch" 0
		return 0
	fi
	print_result "export precedes --self-check dispatch" 1 \
		"Export at line $export_line is AFTER --self-check dispatch at line $sc_line"
	return 0
}

# Test 5: dashboard refresh failures must not be blindly swallowed by the wrapper.
# The wrapper may intentionally defer EX_TEMPFAIL/rate-limit exits, but ordinary
# dashboard failures must still flow through _stats_wrapper_run_health_update so
# the EXIT trap can emit HEALTH-DASHBOARD-FAIL.
test_dashboard_update_failure_not_swallowed() {
	local production_snippet
	production_snippet=$(awk '
		# The scheduler now invokes the work via _stats_wrapper_run_with_timeout,
		# so inspect the actual work body rather than relying on its former
		# placement inline in main().
		/^[[:space:]]*run_daily_quality_sweep \|\| \{/ { in_production=1 }
		in_production { print }
		in_production && /^[[:space:]]*_stats_wrapper_run_health_update[[:space:]]*$/ { exit }
	' "$WRAPPER_SCRIPT")
	if printf '%s' "$production_snippet" | grep -qE '^[[:space:]]*update_health_issues[[:space:]]*\|\|[[:space:]]*true'; then
		print_result "dashboard update failures propagate to stats-wrapper trap" 1 \
			"stats-wrapper.sh still swallows update_health_issues failures with '|| true'"
		return 0
	fi
	if printf '%s' "$production_snippet" | grep -qE '^[[:space:]]*_stats_wrapper_run_health_update[[:space:]]*$'; then
		print_result "dashboard update failures propagate to stats-wrapper trap" 0
		return 0
	fi
	print_result "dashboard update failures propagate to stats-wrapper trap" 1 \
		"Expected _stats_wrapper_run_health_update call in stats-wrapper.sh"
	return 0
}

test_transient_dashboard_tempfail_is_deferred() {
	local helper_snippet
	helper_snippet=$(awk '
		/^_stats_wrapper_run_health_update\(\) \{/ { in_helper=1 }
		in_helper { print }
		in_helper && /^[[:space:]]*}$/ { exit }
	' "$WRAPPER_SCRIPT")
	if printf '%s' "$helper_snippet" | grep -qE '^[[:space:]]*75\)' &&
		printf '%s' "$helper_snippet" | grep -qF 'HEALTH-DASHBOARD-DEFERRED' &&
		printf '%s' "$helper_snippet" | grep -qE "^[[:space:]]*return \"\\\$update_ec\""; then
		print_result "stats-wrapper defers EX_TEMPFAIL but propagates other dashboard failures" 0
		return 0
	fi
	print_result "stats-wrapper defers EX_TEMPFAIL but propagates other dashboard failures" 1 \
		"Expected rc=75 defer path plus default return update_ec in _stats_wrapper_run_health_update"
	return 0
}

# Test 6: the dashboard updater itself must return non-zero when the body edit
# fails, otherwise the wrapper's direct update_health_issues call still exits 0
# and the HEALTH-DASHBOARD-FAIL trap never fires.
test_dashboard_body_edit_failure_returns_nonzero() {
	local failure_snippet
	failure_snippet=$(awk '
		/failed to update body for/ { in_failure=1 }
		in_failure { print }
		in_failure && /^[[:space:]]*}/ { exit }
	' "$HEALTH_DASHBOARD_SCRIPT")
	if printf '%s' "$failure_snippet" | grep -qE '^[[:space:]]*return 1[[:space:]]*$'; then
		print_result "dashboard body edit failures return non-zero" 0
		return 0
	fi
	print_result "dashboard body edit failures return non-zero" 1 \
		"Expected _update_health_issue_for_repo body-edit failure block to return 1"
	return 0
}

main_test() {
	test_export_line_present_at_top_of_main
	test_detect_session_origin_returns_worker_when_headless
	test_export_is_inside_main_not_top_level
	test_export_before_self_check
	test_dashboard_update_failure_not_swallowed
	test_transient_dashboard_tempfail_is_deferred
	test_dashboard_body_edit_failure_returns_nonzero

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
