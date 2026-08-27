#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Characterization tests for stats-functions.sh (t2044 -- Phase 0 of t2010).
#
# Purpose: lock in the *observable* surface of stats-functions.sh so that the
# phased decomposition (todo/plans/stats-functions-decomposition.md) can extract
# functions into sibling stats-<cluster>.sh modules without regressing
# behaviour.
#
# Strategy:
#   1. Source stats-functions.sh in a sandboxed $HOME. The include guard
#      ([[ -n "${_STATS_FUNCTIONS_LOADED:-}" ]] && return 0) is cleared by
#      the sandbox so the file can be re-sourced.
#   2. Assert every currently-defined function (51 entries) is present
#      via `declare -F`. Any extraction PR that drops a function name
#      without re-sourcing it from a new module fails this check.
#   3. Exercise a focused set of PURE / deterministic functions with
#      known inputs and lock their outputs. These catch semantic drift
#      that `declare -F` cannot detect.
#
# Hotspots chosen (from plan section 3.2):
#   _validate_repo_slug  -- pure regex validation
#   _persist_role_cache   -- pure file write (verified via sandbox)
#
# Non-goal: testing behaviour under real gh/git calls. This harness is
# a fast safety net for the extraction refactor.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[0;33m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
# NOTE: deliberately NOT named SCRIPT_DIR. stats-functions.sh and its
# dependencies set SCRIPT_DIR from their own BASH_SOURCE. Use
# STATS_SCRIPTS_DIR to point to the tests-adjacent scripts directory
# without shadowing the sourced files' own variable.
STATS_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly STATS_SCRIPTS_DIR

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

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p \
		"${HOME}/.aidevops/logs" \
		"${HOME}/.aidevops/logs/quality-sweep-state" \
		"${HOME}/.config/aidevops"

	echo '{"initialized_repos": []}' >"${HOME}/.config/aidevops/repos.json"
	export LOGFILE="${HOME}/.aidevops/logs/stats.log"

	# Clear include guard so stats-functions.sh can be sourced fresh
	unset _STATS_FUNCTIONS_LOADED
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

#######################################
# The authoritative 51-function list for stats-functions.sh as of the
# Phase 0 safety net. Regenerate with:
#   awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ {gsub(/\(\)/,""); print "\t\"" $1 "\""}' \
#       .agents/scripts/stats-functions.sh
# Any extraction PR that moves a function into stats-<cluster>.sh must ensure
# the new module is sourced by stats-functions.sh BEFORE this test is run, so
# `declare -F` still finds the function.
#
# When a function is legitimately removed (not just moved), this list must be
# updated in the same PR. Reviewers: verify the removal is intentional.
#######################################
readonly -a EXPECTED_FUNCTIONS=(
	# Cluster A: stats-shared.sh (4 fns)
	"_validate_repo_slug"
	"_sanitize_runner_identity_for_cache"
	"_get_runner_role"
	"_persist_role_cache"
	# Cluster B: stats-health-dashboard.sh (23 fns)
	"update_health_issues"
	"_refresh_person_stats_cache"
	"_resolve_current_gh_login_or_fallback"
	"_update_health_issue_for_repo"
	"_resolve_health_issue_number"
	"_find_health_issue"
	"_create_health_issue"
	"_unpin_health_issue"
	"_ensure_health_issue_pinned"
	"_cleanup_stale_pinned_issues"
	"_update_health_issue_title"
	"_scan_active_workers"
	"_assemble_health_issue_body"
	"_gather_health_stats"
	"_gather_system_resources"
	"_build_health_issue_body"
	"_gather_activity_stats_for_repo"
	"_gather_session_time_for_repo"
	"_read_person_stats_cache"
	"_resolve_runner_role_config"
	"_extract_body_counts"
	# Cluster C: stats-quality-sweep.sh (24 fns)
	"run_daily_quality_sweep"
	"_upsert_quality_sweep_comment"
	"_quality_sweep_for_repo"
	"_ensure_quality_issue"
	"_load_sweep_state"
	"_save_sweep_state"
	"_run_sweep_tools"
	"_sweep_shellcheck"
	"_sweep_qlty"
	"_sweep_sonarcloud"
	"_sweep_sonarcloud_issues"
	"_sweep_sonarcloud_diagnostics"
	"_sweep_codacy"
	"_sweep_coderabbit"
	"_sweep_review_scanner"
	"_build_sweep_comment"
	"_build_simplification_issue_body"
	"_create_simplification_issues"
	"_update_quality_issue_body"
	"_gather_quality_issue_stats"
	"_compute_debt_stats"
	"_compute_bot_coverage"
	"_check_pr_bot_coverage"
	"_compute_badge_indicator"
	"_build_quality_issue_body"
	"_update_quality_issue_title"
)

#######################################
# Assertion helpers
#######################################

assert_equals() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "expected='${expected}' actual='${actual}'"
	return 0
}

assert_function_defined() {
	local fn_name="$1"
	declare -F "$fn_name" >/dev/null
}

#######################################
# Test 1: source stats-functions.sh in sandbox, assert every expected
# function is defined via `declare -F`. This is the core safety net for
# extraction.
#######################################
test_source_and_function_existence() {
	setup_sandbox

	# Source dependencies in the same order stats-wrapper.sh does
	# shellcheck source=/dev/null
	source "${STATS_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null
	# shellcheck source=/dev/null
	source "${STATS_SCRIPTS_DIR}/worker-lifecycle-common.sh" 2>/dev/null

	# shellcheck source=/dev/null
	source "${STATS_SCRIPTS_DIR}/stats-functions.sh" 2>/dev/null

	local missing=()
	local fn
	for fn in "${EXPECTED_FUNCTIONS[@]}"; do
		if ! assert_function_defined "$fn"; then
			missing+=("$fn")
		fi
	done

	if [[ ${#missing[@]} -eq 0 ]]; then
		print_result "all ${#EXPECTED_FUNCTIONS[@]} stats-functions defined after sourcing" 0
	else
		local msg="${#missing[@]} missing: ${missing[*]:0:5}"
		if [[ ${#missing[@]} -gt 5 ]]; then
			msg="${msg} ..."
		fi
		print_result "all ${#EXPECTED_FUNCTIONS[@]} stats-functions defined after sourcing" 1 "$msg"
	fi

	return 0
}

#######################################
# Test 2: _validate_repo_slug -- pure regex validation.
# Lock in accepted and rejected slug patterns so extraction cannot
# accidentally widen or narrow the validation.
#######################################
test_validate_repo_slug() {
	# Valid slugs
	local rc=0
	_validate_repo_slug "owner/repo" 2>/dev/null && rc=0 || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "_validate_repo_slug accepts owner/repo" 0
	else
		print_result "_validate_repo_slug accepts owner/repo" 1 "rc=$rc"
	fi

	_validate_repo_slug "my-org/my.repo_name" 2>/dev/null && rc=0 || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "_validate_repo_slug accepts hyphen/dot/underscore" 0
	else
		print_result "_validate_repo_slug accepts hyphen/dot/underscore" 1 "rc=$rc"
	fi

	# Invalid slugs
	_validate_repo_slug "../etc/passwd" 2>/dev/null && rc=0 || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "_validate_repo_slug rejects path traversal" 0
	else
		print_result "_validate_repo_slug rejects path traversal" 1 "rc=$rc"
	fi

	_validate_repo_slug "noslash" 2>/dev/null && rc=0 || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "_validate_repo_slug rejects missing slash" 0
	else
		print_result "_validate_repo_slug rejects missing slash" 1 "rc=$rc"
	fi

	_validate_repo_slug "" 2>/dev/null && rc=0 || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "_validate_repo_slug rejects empty string" 0
	else
		print_result "_validate_repo_slug rejects empty string" 1 "rc=$rc"
	fi

	_validate_repo_slug "owner/repo;rm -rf /" 2>/dev/null && rc=0 || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "_validate_repo_slug rejects injection" 0
	else
		print_result "_validate_repo_slug rejects injection" 1 "rc=$rc"
	fi
	return 0
}

#######################################
# Test 2b: _resolve_current_gh_login_or_fallback rejects fallback identities
# that could be parsed as flags when reused in CLI arguments.
#######################################
test_resolve_current_gh_login_rejects_leading_hyphen_fallback() {
	gh() {
		return 1
	}

	whoami() {
		printf '%s' "-runner"
		return 0
	}

	local output
	output=$(_resolve_current_gh_login_or_fallback 2>/dev/null)
	assert_equals "_resolve_current_gh_login_or_fallback rejects leading hyphen fallback" "unknown-runner" "$output"

	unset -f gh whoami
	return 0
}

#######################################
# Test 2c: idle dashboards must refresh within one bounded interval and leave
# an operator/actionable diagnostic when the activity guard defers a write.
#######################################
test_idle_dashboard_freshness_contract() {
	local dashboard_script diagnostic_pattern
	dashboard_script="${STATS_SCRIPTS_DIR}/stats-health-dashboard.sh"
	diagnostic_pattern="operator=\${runner_user} issue=#\${dashboard_issue} reason=idle-refresh-interval"

	if grep -Fq 'readonly _HEALTH_IDLE_REFRESH_INTERVAL_DEFAULT=3600' "$dashboard_script" \
		&& grep -Fq "$diagnostic_pattern" "$dashboard_script"; then
		print_result "idle dashboard refreshes hourly with an actionable defer diagnostic" 0
		return 0
	fi

	print_result "idle dashboard refreshes hourly with an actionable defer diagnostic" 1 \
		"expected one-hour default plus repo/operator/issue defer reason"
	return 0
}

#######################################
# Test 3: _persist_role_cache -- writes role to a deterministic file path.
# Signature: _persist_role_cache runner_user repo_slug role
# Verify the file is created with expected content in the sandbox.
#######################################
test_persist_role_cache() {
	local runner="testuser"
	local slug="test-owner/test-repo"
	local role="supervisor"

	# _persist_role_cache(runner_user, repo_slug, role) writes to $HOME/.aidevops/logs/
	_persist_role_cache "$runner" "$slug" "$role" 2>/dev/null || true

	local cache_file="${HOME}/.aidevops/logs/runner-role-testuser-test-owner-test-repo"
	if [[ -f "$cache_file" ]]; then
		local content
		content=$(cat "$cache_file")
		# The cache file contains "ROLE|EPOCH" format
		local cached_role
		cached_role=$(echo "$content" | cut -d'|' -f1)
		assert_equals "_persist_role_cache writes correct role" "$role" "$cached_role"
	else
		print_result "_persist_role_cache creates cache file" 1 "file not found: $cache_file"
	fi
	return 0
}

#######################################
# Test 4: sourcing is idempotent -- after extraction, stats-functions.sh
# will source sibling modules. Each has an include guard. Verify a
# second source doesn't error or change function count.
#######################################
test_sourcing_idempotency() {
	local before_count
	before_count=$(declare -F | wc -l | tr -d ' ')

	local rc=0
	# Clear include guard to allow re-entry
	unset _STATS_FUNCTIONS_LOADED
	# shellcheck source=/dev/null
	source "${STATS_SCRIPTS_DIR}/stats-functions.sh" 2>/dev/null || rc=$?

	local after_count
	after_count=$(declare -F | wc -l | tr -d ' ')

	if [[ "$rc" -eq 0 ]]; then
		print_result "sourcing stats-functions.sh is idempotent (exit 0)" 0
	else
		print_result "sourcing stats-functions.sh is idempotent (exit 0)" 1 "rc=$rc"
	fi

	assert_equals "function count unchanged after re-source" "$before_count" "$after_count"
	return 0
}

#######################################
# Test 5: _load_sweep_state / _save_sweep_state round-trip.
# _save_sweep_state(slug, gate_status, total_issues, high_critical_count)
# _load_sweep_state(slug) -> "gate_status|total_issues|high_critical_count"
# These are pure file-based state ops. Verify write-then-read integrity.
#######################################
test_sweep_state_round_trip() {
	local slug="test-owner/test-repo"

	# Save state: slug, gate_status, total_issues, high_critical_count
	_save_sweep_state "$slug" "OK" "42" "3" 2>/dev/null || true

	# Load state
	local output
	output=$(_load_sweep_state "$slug" 2>/dev/null)

	# Expected format: "gate_status|total_issues|high_critical_count"
	local gate_status total_issues
	gate_status=$(echo "$output" | cut -d'|' -f1)
	total_issues=$(echo "$output" | cut -d'|' -f2)

	assert_equals "_save/_load_sweep_state gate_status" "OK" "$gate_status"
	assert_equals "_save/_load_sweep_state total_issues" "42" "$total_issues"
	return 0
}

#######################################
# Main
#######################################
main() {
	printf '%b==> stats-functions.sh characterization tests%b\n' "$TEST_YELLOW" "$TEST_RESET"
	printf '    STATS_SCRIPTS_DIR=%s\n' "$STATS_SCRIPTS_DIR"

	test_source_and_function_existence
	test_validate_repo_slug
	test_resolve_current_gh_login_rejects_leading_hyphen_fallback
	test_idle_dashboard_freshness_contract
	test_persist_role_cache
	test_sourcing_idempotency
	test_sweep_state_round_trip

	teardown_sandbox

	printf '\n'
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	fi
	printf '%b%d of %d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	return 1
}

main "$@"
