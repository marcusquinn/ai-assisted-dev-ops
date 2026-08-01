#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#23601.
#
# Tier policy helpers can mutate labels on GitHub after dispatch_with_dedup has
# captured the t2996 issue_meta_json bundle. These tests exercise marker-gated
# refresh so downstream gates receive normalized labels without an API call on
# unchanged issues.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

# shellcheck source=../shared-constants.sh
source "${REPO_SCRIPTS_DIR}/shared-constants.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
GH_ISSUE_VIEW_CALLS_FILE=""

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

define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_refresh_issue_meta_after_tier_policy_checks\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _refresh_issue_meta_after_tier_policy_checks from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

gh_issue_view() {
	local issue_number="$1"
	shift
	if [[ -n "$GH_ISSUE_VIEW_CALLS_FILE" ]]; then
		printf 'call\n' >>"$GH_ISSUE_VIEW_CALLS_FILE"
	fi
	if [[ "$issue_number" != "23601" ]]; then
		return 1
	fi
	printf '%s' '{"number":23601,"title":"normalized tier","state":"OPEN","labels":[{"name":"tier:thinking"},{"name":"auto-dispatch"}],"assignees":[],"body":"brief","author":{"login":"worker"}}'
	return 0
}

reset_gh_issue_view_calls() {
	: >"$GH_ISSUE_VIEW_CALLS_FILE"
	return 0
}

count_gh_issue_view_calls() {
	local calls
	calls=$(wc -l <"$GH_ISSUE_VIEW_CALLS_FILE") || calls=0
	printf '%s' "$calls"
	return 0
}

test_refreshes_after_policy_mutation() {
	local initial_meta='{"number":23601,"title":"stale tier","state":"OPEN","labels":[{"name":"tier:standard"},{"name":"auto-dispatch"}],"assignees":[],"body":"brief","author":{"login":"worker"}}'
	local refreshed_meta
	reset_gh_issue_view_calls
	refreshed_meta=$(_refresh_issue_meta_after_tier_policy_checks "23601" "marcusquinn/aidevops" "$initial_meta" "1")

	local resolved_tier
	local calls
	resolved_tier=$(printf '%s' "$refreshed_meta" | jq -r '.labels | map(.name) | join(",")')
	calls=$(count_gh_issue_view_calls)
	if [[ "$resolved_tier" == "tier:thinking,auto-dispatch" && "$calls" -eq 1 ]]; then
		print_result "refreshes bundled metadata after a tier policy mutation" 0
		return 0
	fi
	print_result "refreshes bundled metadata after a tier policy mutation" 1 \
		"Expected refreshed tier:thinking labels and one gh_issue_view call; got labels='${resolved_tier}' calls=${calls}"
	return 0
}

test_skips_refresh_without_mutation_marker() {
	local initial_meta='{"number":23601,"title":"simple tier","state":"OPEN","labels":[{"name":"tier:simple"},{"name":"auto-dispatch"}],"assignees":[],"body":"brief"}'
	local refreshed_meta
	reset_gh_issue_view_calls
	refreshed_meta=$(_refresh_issue_meta_after_tier_policy_checks "23601" "marcusquinn/aidevops" "$initial_meta" "0")

	local calls
	calls=$(count_gh_issue_view_calls)
	if [[ "$refreshed_meta" == "$initial_meta" && "$calls" -eq 0 ]]; then
		print_result "skips gh refresh when no tier helper mutated labels" 0
		return 0
	fi
	print_result "skips gh refresh when no tier helper mutated labels" 1 \
		"Expected original metadata and zero gh_issue_view calls; calls=${calls}"
	return 0
}

test_preserves_original_when_refresh_fails() {
	local initial_meta='{"number":999,"title":"refresh failure","state":"OPEN","labels":[{"name":"tier:standard"}],"assignees":[],"body":"brief"}'
	local refreshed_meta
	reset_gh_issue_view_calls
	refreshed_meta=$(_refresh_issue_meta_after_tier_policy_checks "999" "marcusquinn/aidevops" "$initial_meta" "1")

	local calls
	calls=$(count_gh_issue_view_calls)
	if [[ "$refreshed_meta" == "$initial_meta" && "$calls" -eq 1 ]]; then
		print_result "preserves original metadata when marker-gated refresh fails" 0
		return 0
	fi
	print_result "preserves original metadata when marker-gated refresh fails" 1 \
		"Expected original metadata and one failed gh_issue_view call; calls=${calls}"
	return 0
}

main() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	local LOGFILE
	LOGFILE="$(mktemp)"
	push_cleanup "rm -f '${LOGFILE}'"
	local GH_ISSUE_VIEW_CALLS_FILE
	GH_ISSUE_VIEW_CALLS_FILE="$(mktemp)"
	push_cleanup "rm -f '${GH_ISSUE_VIEW_CALLS_FILE}'"
	export LOGFILE
	export GH_ISSUE_VIEW_CALLS_FILE

	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_refreshes_after_policy_mutation
	test_skips_refresh_without_mutation_marker
	test_preserves_original_when_refresh_fails

	rm -f "$GH_ISSUE_VIEW_CALLS_FILE" "$LOGFILE"
	GH_ISSUE_VIEW_CALLS_FILE=""
	LOGFILE=""

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
