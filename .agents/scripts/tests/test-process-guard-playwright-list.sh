#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/process-guard-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

run_matcher() {
	local age_seconds="$1"
	local tty="$2"
	local cwd_path="$3"
	shift 3
	STALE_PLAYWRIGHT_LIST_AGE_LIMIT=900 bash "$HELPER" match-playwright-list "$age_seconds" "$tty" "$cwd_path" "$@"
	return $?
}

test_matches_stale_aidevops_playwright_list() {
	local output
	if output=$(run_matcher 1200 '?' "$HOME/Git/aidevops-feature-auto-123" pnpm --filter web exec playwright test --list --grep @flaky --reporter=list 2>&1); then
		if [[ "$output" == MATCH* ]]; then
			print_result "matches stale aidevops Playwright list process" 0
		else
			print_result "matches stale aidevops Playwright list process" 1 "Unexpected output: $output"
		fi
	else
		print_result "matches stale aidevops Playwright list process" 1 "Matcher rejected: $output"
	fi
	return 0
}

test_matches_stale_aidevops_playwright_list_with_flexible_spacing() {
	local output
	if output=$(run_matcher 1200 '?' "$HOME/Git/aidevops-feature-auto-123" pnpm --filter web exec 'playwright   test   --list' --grep=@flaky --reporter=list 2>&1); then
		if [[ "$output" == MATCH* ]]; then
			print_result "matches stale aidevops Playwright list with flexible spacing" 0
		else
			print_result "matches stale aidevops Playwright list with flexible spacing" 1 "Unexpected output: $output"
		fi
	else
		print_result "matches stale aidevops Playwright list with flexible spacing" 1 "Matcher rejected: $output"
	fi
	return 0
}

test_rejects_unrelated_playwright_list() {
	local output
	if output=$(run_matcher 1200 '?' "$HOME/projects/app" pnpm --filter web exec playwright test --list --grep @flaky --reporter=list 2>&1); then
		print_result "rejects unrelated Playwright list process" 1 "Unexpected match: $output"
	else
		if [[ "$output" == NO_MATCH*"no aidevops"* ]]; then
			print_result "rejects unrelated Playwright list process" 0
		else
			print_result "rejects unrelated Playwright list process" 1 "Unexpected output: $output"
		fi
	fi
	return 0
}

test_rejects_interactive_playwright_list() {
	local output
	if output=$(run_matcher 1200 ttys001 "$HOME/Git/aidevops-feature-auto-123" playwright test --list --grep @flaky 2>&1); then
		print_result "rejects interactive Playwright list process" 1 "Unexpected match: $output"
	else
		if [[ "$output" == NO_MATCH*"interactive"* ]]; then
			print_result "rejects interactive Playwright list process" 0
		else
			print_result "rejects interactive Playwright list process" 1 "Unexpected output: $output"
		fi
	fi
	return 0
}

test_rejects_fresh_aidevops_playwright_list() {
	local output
	if output=$(run_matcher 300 '?' "$HOME/Git/aidevops-feature-auto-123" playwright test --list --grep @flaky 2>&1); then
		print_result "rejects fresh aidevops Playwright list process" 1 "Unexpected match: $output"
	else
		if [[ "$output" == NO_MATCH*"<= 900s"* ]]; then
			print_result "rejects fresh aidevops Playwright list process" 0
		else
			print_result "rejects fresh aidevops Playwright list process" 1 "Unexpected output: $output"
		fi
	fi
	return 0
}

test_rejects_substring_grep_option() {
	local output
	if output=$(run_matcher 1200 '?' "$HOME/Git/aidevops-feature-auto-123" playwright test --list --no-grep @flaky 2>&1); then
		print_result "rejects substring grep option" 1 "Unexpected match: $output"
	else
		if [[ "$output" == NO_MATCH*"missing grep selector"* ]]; then
			print_result "rejects substring grep option" 0
		else
			print_result "rejects substring grep option" 1 "Unexpected output: $output"
		fi
	fi
	return 0
}

test_kill_log_format_carries_timestamp_and_process_class() {
	local helper_text
	helper_text=$(<"$HELPER")
	if [[ "$helper_text" == *"action=kill pid=%s ppid=%s class=%s cmd=%s rss_mb=%s age_seconds=%s runtime_limit_seconds=%s cgroup=%s reason=%s"* && \
		"$helper_text" == *"_process_guard_timestamp"* && \
		"$helper_text" == *"process_class='playwright-list'"* ]]; then
		print_result "kill log format carries timestamp, process class, and cgroup" 0
		return 0
	fi

	print_result "kill log format carries timestamp, process class, and cgroup" 1
	return 0
}

main() {
	test_matches_stale_aidevops_playwright_list
	test_matches_stale_aidevops_playwright_list_with_flexible_spacing
	test_rejects_unrelated_playwright_list
	test_rejects_interactive_playwright_list
	test_rejects_fresh_aidevops_playwright_list
	test_rejects_substring_grep_option
	test_kill_log_format_carries_timestamp_and_process_class

	printf '\n%s/%s tests passed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
