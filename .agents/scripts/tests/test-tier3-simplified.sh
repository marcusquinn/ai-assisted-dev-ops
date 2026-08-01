#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Integration Tests for Tier 3 Simplified Scripts (t1337.3)
# =============================================================================
# Verifies the 5 simplified Tier 3 scripts:
#   1. full-loop-helper.sh       (534 lines, was 1169)
#   2. fallback-chain-helper.sh  (261 lines, was 1367)
#   3. budget-tracker-helper.sh  (309 lines, was 1671)
#   4. issue-sync-helper.sh      (903 lines, was 2398)
#   5. observability-helper.sh   (640 lines, was 1741)
#
# Tests: sourcing, help output, state management, record/query, backward compat.
# Does NOT require GitHub API, network, or real Claude sessions.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCRIPTS_DIR="${SCRIPT_DIR}/.."

# Colors
readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Temp dir for test isolation
TEST_DIR=""

# =============================================================================
# Test Framework
# =============================================================================

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${TEST_GREEN}PASS${TEST_RESET} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${TEST_RED}FAIL${TEST_RESET} $test_name"
		[[ -n "$message" ]] && echo "       $message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	export HOME="$TEST_DIR"
	mkdir -p "$TEST_DIR/.aidevops/.agent-workspace"
	mkdir -p "$TEST_DIR/.config/aidevops"
	mkdir -p "$TEST_DIR/.claude/projects"
	return 0
}

teardown() {
	[[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
	return 0
}

# =============================================================================
# 1. Syntax & Sourcing Tests
# =============================================================================

test_syntax_check() {
	echo ""
	echo "=== Syntax & Sourcing ==="

	local scripts=(
		"full-loop-helper.sh"
		"fallback-chain-helper.sh"
		"budget-tracker-helper.sh"
		"issue-sync-helper.sh"
		"observability-helper.sh"
	)

	for script in "${scripts[@]}"; do
		local path="${SCRIPTS_DIR}/${script}"
		if bash -n "$path"; then
			print_result "syntax: $script" 0
		else
			print_result "syntax: $script" 1 "Syntax error in $script"
		fi
	done
	return 0
}

# =============================================================================
# 2. Help Output Tests
# =============================================================================

_check_help_keywords() {
	local script="$1"
	local keywords="$2"
	local path="${SCRIPTS_DIR}/${script}"
	local output
	output=$("$path" help 2>&1) || true

	local all_found=true
	local saved_ifs="$IFS"
	IFS='|'
	for keyword in $keywords; do
		if ! echo "$output" | grep -qi "$keyword"; then
			print_result "help: $script contains '$keyword'" 1 "Missing keyword '$keyword' in help output"
			all_found=false
		fi
	done
	IFS="$saved_ifs"

	if [[ "$all_found" == "true" ]]; then
		print_result "help: $script" 0
	fi
	return 0
}

test_help_output() {
	echo ""
	echo "=== Help Output ==="

	_check_help_keywords "full-loop-helper.sh" "start|resume|status|cancel|headless"
	_check_help_keywords "fallback-chain-helper.sh" "resolve|table|tier"
	_check_help_keywords "budget-tracker-helper.sh" "record|status|burn-rate|tail"
	_check_help_keywords "issue-sync-helper.sh" "push|pull|close|enrich|reconcile"
	_check_help_keywords "observability-helper.sh" "ingest|record|rate-limits"
	return 0
}

# =============================================================================
# 3. Full-Loop-Helper Tests
# =============================================================================

test_full_loop_helper() {
	echo ""
	echo "=== Full-Loop-Helper ==="

	local helper="${SCRIPTS_DIR}/full-loop-helper.sh"

	# Test: status with no active loop
	local output
	output=$("$helper" status 2>&1) || true
	if echo "$output" | grep -q "No active full loop"; then
		print_result "full-loop: status (no active loop)" 0
	else
		print_result "full-loop: status (no active loop)" 1 "Expected 'No active full loop'"
	fi

	# Test: cancel with no active loop
	output=$("$helper" cancel 2>&1) || true
	if echo "$output" | grep -qi "no active loop"; then
		print_result "full-loop: cancel (no active loop)" 0
	else
		print_result "full-loop: cancel (no active loop)" 1 "Expected 'No active loop' message"
	fi

	# Test: start requires feature branch (we're on feature/t1337.3 so this should work)
	# But we need a git repo context — test dry-run instead
	local git_root
	git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	if [[ -n "$git_root" ]]; then
		output=$("$helper" start "test prompt" --dry-run 2>&1) || true
		if echo "$output" | grep -qi "dry run"; then
			print_result "full-loop: start --dry-run" 0
		else
			print_result "full-loop: start --dry-run" 1 "Expected dry run output"
		fi
	else
		print_result "full-loop: start --dry-run" 0 "(skipped: no git repo)"
	fi

	# Test: start with no prompt — must fail AND produce an error message
	local rc=0
	output=$("$helper" start "" 2>&1) || rc=$?
	if [[ $rc -ne 0 ]] && echo "$output" | grep -qiE "no prompt|usage|required|missing|empty"; then
		print_result "full-loop: start (no prompt) fails" 0
	else
		print_result "full-loop: start (no prompt) fails" 1 "Expected non-zero exit AND error pattern. rc=$rc, output: $output"
	fi

	# Test: unknown command
	output=$("$helper" nonexistent 2>&1) || true
	if echo "$output" | grep -qi "unknown command"; then
		print_result "full-loop: unknown command" 0
	else
		print_result "full-loop: unknown command" 1 "Expected 'Unknown command'"
	fi

	return 0
}

# =============================================================================
# 4. Fallback-Chain-Helper Tests
# =============================================================================

test_fallback_chain_helper() {
	echo ""
	echo "=== Fallback-Chain-Helper ==="

	local helper="${SCRIPTS_DIR}/fallback-chain-helper.sh"
	local avail_helper="${SCRIPTS_DIR}/model-availability-helper.sh"

	# Temporarily hide model-availability-helper.sh so fallback-chain uses its
	# lightweight API key check instead of HTTP probes (which fail with fake keys)
	local avail_hidden=false
	local avail_backup="${avail_helper}.bak.$$"

	# Trap ensures restoration even if set -e triggers an early exit
	# shellcheck disable=SC2317
	_restore_avail_helper() {
		if [[ "${avail_hidden:-false}" == "true" && -f "${avail_backup:-}" ]]; then
			mv -- "$avail_backup" "$avail_helper"
			avail_hidden=false
		fi
	}
	trap '_restore_avail_helper' RETURN

	if [[ -x "$avail_helper" ]]; then
		mv -- "$avail_helper" "$avail_backup"
		avail_hidden=true
	fi

	# Test: resolve with no tier
	local output
	output=$("$helper" resolve 2>&1) || true
	if echo "$output" | grep -qiE "usage|tier"; then
		print_result "fallback: resolve (no tier) shows usage" 0
	else
		print_result "fallback: resolve (no tier) shows usage" 1 "Expected usage message"
	fi

	# Test: resolve simple tier (hardcoded fallback — no config file needed)
	# Set a fake API key so the lightweight availability check passes
	export OPENAI_API_KEY="test-key-for-testing"
	output=$("$helper" resolve simple --quiet 2>&1) || true
	if echo "$output" | grep -q "gpt-5.6-luna"; then
		print_result "fallback: resolve simple -> gpt-5.6-luna" 0
	else
		print_result "fallback: resolve simple -> gpt-5.6-luna" 1 "Got: $output"
	fi

	# Test: resolve standard tier
	output=$("$helper" resolve standard --quiet 2>&1) || true
	if echo "$output" | grep -q "gpt-5.6-sol"; then
		print_result "fallback: resolve standard -> gpt-5.6-sol" 0
	else
		print_result "fallback: resolve standard -> gpt-5.6-sol" 1 "Got: $output"
	fi

	# Test: resolve thinking tier
	output=$("$helper" resolve thinking --quiet 2>&1) || true
	if echo "$output" | grep -q "gpt-5.6-sol"; then
		print_result "fallback: resolve thinking -> gpt-5.6-sol" 0
	else
		print_result "fallback: resolve thinking -> gpt-5.6-sol" 1 "Got: $output"
	fi

	# Test: resolve with --json flag
	output=$("$helper" resolve simple --quiet --json 2>&1) || true
	if echo "$output" | grep -q '"status":"resolved"'; then
		print_result "fallback: resolve --json output" 0
	else
		print_result "fallback: resolve --json output" 1 "Got: $output"
	fi

	# Test: unknown tier — must fail AND produce an error message
	unset OPENAI_API_KEY
	local rc=0
	output=$("$helper" resolve nonexistent --quiet 2>&1) || rc=$?
	if [[ $rc -ne 0 ]] && echo "$output" | grep -qiE "unknown|unsupported|invalid|error|fail|no.*tier|not found"; then
		print_result "fallback: unknown tier fails" 0
	else
		print_result "fallback: unknown tier fails" 1 "Expected non-zero exit AND error pattern. rc=$rc, output: $output"
	fi

	# Test: unknown command
	output=$("$helper" nonexistent 2>&1) || true
	if echo "$output" | grep -qiE "unknown command"; then
		print_result "fallback: unknown command" 0
	else
		print_result "fallback: unknown command" 1 "Expected 'Unknown command'"
	fi

	# Restore model-availability-helper.sh (also handled by RETURN trap as safety net)
	if [[ "$avail_hidden" == "true" && -f "$avail_backup" ]]; then
		mv -- "$avail_backup" "$avail_helper"
		avail_hidden=false
	fi

	return 0
}

# =============================================================================
# 5. Budget-Tracker-Helper Tests
# =============================================================================

test_budget_tracker_helper() {
	echo ""
	echo "=== Budget-Tracker-Helper ==="

	local helper="${SCRIPTS_DIR}/budget-tracker-helper.sh"

	# Test: record a spend event
	local output
	if output=$("$helper" record --provider anthropic --model anthropic/claude-sonnet-4-6 \
		--input-tokens 1000 --output-tokens 500 --task t1337.3 2>&1); then
		print_result "budget: record spend event" 0
	else
		print_result "budget: record spend event" 1 "Exit code: $?, output: $output"
	fi

	# Verify the log file was created and has content
	local cost_log="${TEST_DIR}/.aidevops/.agent-workspace/cost-log.tsv"
	if [[ -f "$cost_log" ]] && [[ $(wc -l <"$cost_log") -ge 2 ]]; then
		print_result "budget: cost log created with data" 0
	else
		print_result "budget: cost log created with data" 1 "Log file missing or empty"
	fi

	# Test: record with --cost override
	if output=$("$helper" record --provider openai --model openai/gpt-4.1 \
		--input-tokens 500 --output-tokens 200 --cost 0.05 2>&1); then
		print_result "budget: record with --cost override" 0
	else
		print_result "budget: record with --cost override" 1
	fi

	# Test: status command
	output=$("$helper" status 2>&1) || true
	if echo "$output" | grep -qiE 'cost|events|spend'; then
		print_result "budget: status shows summary" 0
	else
		print_result "budget: status shows summary" 1 "Got: $output"
	fi

	# Test: status --json
	output=$("$helper" status --json 2>&1) || true
	if echo "$output" | grep -q '"total_cost_usd"'; then
		print_result "budget: status --json" 0
	else
		print_result "budget: status --json" 1 "Got: $output"
	fi

	# Test: burn-rate
	output=$("$helper" burn-rate 2>&1) || true
	if echo "$output" | grep -qiE 'burn rate|spend|hourly'; then
		print_result "budget: burn-rate" 0
	else
		print_result "budget: burn-rate" 1 "Got: $output"
	fi

	# Test: tail
	output=$("$helper" tail 5 2>&1) || true
	if echo "$output" | grep -q "timestamp"; then
		print_result "budget: tail shows header" 0
	else
		print_result "budget: tail shows header" 1 "Got: $output"
	fi

	# Test: record with missing required args — must fail AND produce an error message
	local rc_record=0
	output=$("$helper" record 2>&1) || rc_record=$?
	if [[ $rc_record -ne 0 ]] && echo "$output" | grep -qiE "missing|required|usage|error|provider"; then
		print_result "budget: record (missing args) fails" 0
	else
		print_result "budget: record (missing args) fails" 1 "Expected non-zero exit AND error pattern. rc=$rc_record, output: $output"
	fi

	# Test: backward compat — removed commands return gracefully
	local removed_cmds=("check" "recommend" "configure" "reset" "tier-drift" "prune")
	local all_compat=true
	for cmd in "${removed_cmds[@]}"; do
		local cmd_rc=0
		output=$("$helper" "$cmd" 2>&1) || cmd_rc=$?
		if [[ $cmd_rc -ne 0 ]]; then
			print_result "budget: backward compat '$cmd'" 1 "Exit code: $cmd_rc"
			all_compat=false
		fi
	done
	if [[ "$all_compat" == "true" ]]; then
		print_result "budget: backward compat (removed commands)" 0
	fi

	# Test: budget-check-tier returns tier unchanged
	output=$("$helper" budget-check-tier standard 2>&1) || true
	if [[ "$output" == *"sonnet"* ]]; then
		print_result "budget: budget-check-tier passthrough" 0
	else
		print_result "budget: budget-check-tier passthrough" 1 "Got: $output"
	fi

	return 0
}

# =============================================================================
# 6. Issue-Sync-Helper Tests
# =============================================================================

test_issue_sync_helper() {
	echo ""
	echo "=== Issue-Sync-Helper ==="

	local helper="${SCRIPTS_DIR}/issue-sync-helper.sh"

	# Test: help output
	local output
	output=$("$helper" help 2>&1) || true
	if echo "$output" | grep -q "push" && echo "$output" | grep -q "pull"; then
		print_result "issue-sync: help output" 0
	else
		print_result "issue-sync: help output" 1 "Missing expected commands in help"
	fi

	# Test: unknown command
	output=$("$helper" nonexistent 2>&1) || true
	if echo "$output" | grep -qi "unknown command"; then
		print_result "issue-sync: unknown command" 0
	else
		print_result "issue-sync: unknown command" 1 "Expected 'Unknown command'"
	fi

	# Test: parse with no task ID — must fail AND produce an error message
	local rc_parse=0
	output=$("$helper" parse 2>&1) || rc_parse=$?
	if [[ $rc_parse -ne 0 ]] && echo "$output" | grep -qiE "missing|required|usage|error|task"; then
		print_result "issue-sync: parse (no task) fails" 0
	else
		print_result "issue-sync: parse (no task) fails" 1 "Expected non-zero exit AND error pattern. rc=$rc_parse, output: $output"
	fi

	# Note: push/pull/close/enrich/reconcile/status require gh CLI auth and a real repo.
	# We test those interfaces exist via help output above.
	# The parse command tests the library functions (parse_task_line, etc.)

	# GH#5212: Test that push skips completed [x] tasks.
	# Uses DRY_RUN=true and a fake GH_TOKEN to bypass gh auth, then verifies
	# the skip message appears before any API call is attempted.
	local tmp_dir
	tmp_dir=$(mktemp -d)
	local tmp_todo="$tmp_dir/TODO.md"
	printf '# Tasks\n\n- [x] t999 Already completed task pr:#1 verified:2026-01-01\n' >"$tmp_todo"
	# Initialize a minimal git repo so find_project_root and detect_repo_slug work
	git -C "$tmp_dir" init -q 2>/dev/null || true
	git -C "$tmp_dir" remote add origin "https://github.com/example/test.git" 2>/dev/null || true
	local push_output
	push_output=$(cd "$tmp_dir" && GH_TOKEN=fake-token-for-test DRY_RUN=true "$helper" push t999 2>&1) || true
	rm -rf "$tmp_dir"
	if echo "$push_output" | grep -qiE "already completed|skip.*t999|t999.*skip"; then
		print_result "issue-sync: push skips completed [x] task (GH#5212)" 0
	else
		print_result "issue-sync: push skips completed [x] task (GH#5212)" 1 "Expected skip message for completed task. output: $push_output"
	fi

	return 0
}

# =============================================================================
# 7. Observability-Helper Tests
# =============================================================================

test_observability_helper() {
	echo ""
	echo "=== Observability-Helper ==="

	local helper="${SCRIPTS_DIR}/observability-helper.sh"

	# Test: record a metric
	local output
	if output=$("$helper" record --model anthropic/claude-sonnet-4-6 \
		--input-tokens 5000 --output-tokens 2000 \
		--cache-read 1000 --cache-write 500 \
		--session test-session --project test-project 2>&1); then
		print_result "observability: record metric" 0
	else
		print_result "observability: record metric" 1 "Exit code: $?, output: $output"
	fi

	# Verify metrics file exists and has content
	local metrics="${TEST_DIR}/.aidevops/.agent-workspace/observability/metrics.jsonl"
	if [[ -f "$metrics" ]] && [[ $(wc -l <"$metrics") -ge 1 ]]; then
		print_result "observability: metrics file created" 0
	else
		print_result "observability: metrics file created" 1 "Metrics file missing or empty"
	fi

	# Verify the recorded metric has expected fields
	if command -v jq &>/dev/null && [[ -f "$metrics" ]]; then
		local model_val
		model_val=$(jq -r '.model' "$metrics" | head -1)
		if [[ "$model_val" == *"claude-sonnet"* ]]; then
			print_result "observability: metric has correct model" 0
		else
			print_result "observability: metric has correct model" 1 "Got model: $model_val"
		fi

		local cost_val
		cost_val=$(jq -r '.cost_total' "$metrics" | head -1)
		if [[ "$cost_val" != "0" && "$cost_val" != "null" ]]; then
			print_result "observability: metric has non-zero cost" 0
		else
			print_result "observability: metric has non-zero cost" 1 "Got cost: $cost_val"
		fi
	fi

	# Test: record with missing model — must fail AND produce an error message
	local rc_obs_record=0
	output=$("$helper" record 2>&1) || rc_obs_record=$?
	if [[ $rc_obs_record -ne 0 ]] && echo "$output" | grep -qiE "missing|required|usage|error|model"; then
		print_result "observability: record (no model) fails" 0
	else
		print_result "observability: record (no model) fails" 1 "Expected non-zero exit AND error pattern. rc=$rc_obs_record, output: $output"
	fi

	# Test: ingest with no Claude logs (should succeed gracefully)
	if output=$("$helper" ingest --quiet 2>&1); then
		print_result "observability: ingest (no logs) succeeds" 0
	else
		print_result "observability: ingest (no logs) succeeds" 1 "Exit code: $?"
	fi

	# Test: backward compat — removed commands return gracefully
	local removed_cmds=("summary" "models" "projects" "costs" "trend" "sync-budget" "prune")
	local all_compat=true
	for cmd in "${removed_cmds[@]}"; do
		local cmd_rc=0
		output=$("$helper" "$cmd" 2>&1) || cmd_rc=$?
		if [[ $cmd_rc -ne 0 ]]; then
			print_result "observability: backward compat '$cmd'" 1 "Exit code: $cmd_rc"
			all_compat=false
		fi
	done
	if [[ "$all_compat" == "true" ]]; then
		print_result "observability: backward compat (removed commands)" 0
	fi

	# Test: unknown command
	output=$("$helper" nonexistent 2>&1) || true
	if echo "$output" | grep -qi "unknown command"; then
		print_result "observability: unknown command" 0
	else
		print_result "observability: unknown command" 1 "Expected 'Unknown command'"
	fi

	return 0
}

_check_line_count() {
	local script="$1"
	local max="$2"
	local path="${SCRIPTS_DIR}/${script}"
	local lines
	lines=$(wc -l <"$path" | tr -d ' ')
	if [[ "$lines" -le "$max" ]]; then
		print_result "regression: $script <= $max lines ($lines)" 0
	else
		print_result "regression: $script <= $max lines ($lines)" 1 "Got $lines lines, max $max"
	fi
	return 0
}

# =============================================================================
# 8. Cross-Script Regression Tests
# =============================================================================

test_regressions() {
	echo ""
	echo "=== Regression Checks ==="

	# Verify line counts are within expected range (simplified)
	_check_line_count "full-loop-helper.sh" 600
	_check_line_count "fallback-chain-helper.sh" 300
	_check_line_count "budget-tracker-helper.sh" 350
	_check_line_count "issue-sync-helper.sh" 1000
	_check_line_count "observability-helper.sh" 700

	# Verify all scripts have set -euo pipefail
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local path="${SCRIPTS_DIR}/${script}"
		if grep -q 'set -euo pipefail' "$path"; then
			print_result "regression: $script has strict mode" 0
		else
			print_result "regression: $script has strict mode" 1 "Missing set -euo pipefail"
		fi
	done

	# Verify all scripts source shared-constants.sh
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local path="${SCRIPTS_DIR}/${script}"
		if grep -q 'shared-constants.sh' "$path"; then
			print_result "regression: $script sources shared-constants" 0
		else
			print_result "regression: $script sources shared-constants" 1 "Missing shared-constants.sh source"
		fi
	done

	# Verify all scripts have a main() function and call it
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local path="${SCRIPTS_DIR}/${script}"
		if grep -q '^main()' "$path" && grep -q 'main "$@"' "$path"; then
			print_result "regression: $script has main() entry point" 0
		else
			print_result "regression: $script has main() entry point" 1 "Missing main() or main \"\$@\""
		fi
	done

	# Verify total line count is under target (~2,647 actual vs ~8,346 original)
	local total=0
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh; do
		local lines
		lines=$(wc -l <"${SCRIPTS_DIR}/${script}" | tr -d ' ')
		total=$((total + lines))
	done
	if [[ "$total" -le 3000 ]]; then
		print_result "regression: total lines <= 3000 ($total)" 0
	else
		print_result "regression: total lines <= 3000 ($total)" 1 "Got $total lines"
	fi

	return 0
}

# =============================================================================
# 9. ShellCheck Verification
# =============================================================================

test_shellcheck() {
	echo ""
	echo "=== ShellCheck ==="

	if ! command -v shellcheck &>/dev/null; then
		print_result "shellcheck: available" 1 "shellcheck not installed"
		return 0
	fi

	local all_clean=true
	for script in full-loop-helper.sh fallback-chain-helper.sh budget-tracker-helper.sh issue-sync-helper.sh observability-helper.sh tests/test-tier3-simplified.sh; do
		local path="${SCRIPTS_DIR}/${script}"
		if shellcheck -x -S warning "$path" 2>&1; then
			print_result "shellcheck: $script" 0
		else
			print_result "shellcheck: $script" 1 "ShellCheck violations found"
			all_clean=false
		fi
	done

	if [[ "$all_clean" == "true" ]]; then
		print_result "shellcheck: all Tier 3 scripts clean" 0
	fi

	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	echo "================================================================"
	echo "  Tier 3 Simplified Scripts — Integration Tests (t1337.3)"
	echo "================================================================"

	setup
	trap teardown EXIT INT TERM

	test_syntax_check
	test_help_output
	test_full_loop_helper
	test_fallback_chain_helper
	test_budget_tracker_helper
	test_issue_sync_helper
	test_observability_helper
	test_regressions
	test_shellcheck

	trap - EXIT INT TERM
	teardown

	echo ""
	echo "================================================================"
	echo -e "  Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	echo "================================================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		echo -e "${TEST_RED}FAILED${TEST_RESET}"
		return 1
	else
		echo -e "${TEST_GREEN}ALL TESTS PASSED${TEST_RESET}"
		return 0
	fi
}

main "$@"
