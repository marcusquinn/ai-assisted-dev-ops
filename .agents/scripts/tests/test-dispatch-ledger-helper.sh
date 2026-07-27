#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-ledger-helper.sh — Tests for dispatch-ledger-helper.sh (GH#6696)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
LEDGER_HELPER="${SCRIPT_DIR}/../dispatch-ledger-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""

#######################################
# Run a helper command without triggering set -e on failure.
# Captures exit status so test bodies can check it explicitly.
# Usage: run_helper [args...]; LAST_EXIT=$?
#######################################
run_helper() {
	set +e
	"$@"
	LAST_EXIT=$?
	set -e
	return 0
}

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/ledger"
	mkdir -p "${TEST_ROOT}/ledger"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

#######################################
# Test: register creates a ledger entry
#######################################
test_register_creates_entry() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$ --worktree "/tmp/aidevops-issue-42"

	local entry_count
	entry_count=$(wc -l <"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" | tr -d ' ')

	local result=0
	if [[ "$entry_count" -ne 1 ]]; then
		result=1
	fi

	# Verify fields
	local status
	status=$(jq -r '.status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status" != "in-flight" ]]; then
		result=1
	fi

	local session_key
	session_key=$(jq -r '.session_key' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$session_key" != "issue-42" ]]; then
		result=1
	fi

	local worktree_path
	worktree_path=$(jq -r '.worktree_path' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$worktree_path" != "/tmp/aidevops-issue-42" ]]; then
		result=1
	fi

	local owner_process_start
	owner_process_start=$(jq -r '.owner_process_start' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ -z "$owner_process_start" ]]; then
		result=1
	fi

	print_result "register creates a ledger entry with correct fields" "$result" "count=${entry_count}, status=${status}, key=${session_key}, worktree=${worktree_path}, owner_start=${owner_process_start}"
	teardown_test_env
	return 0
}

test_register_separates_attempt_identity_from_lease() {
	setup_test_env
	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 \
		--repo "owner/repo" --pid $$ --lease-token "private-lease-token" \
		--attempt-id "attempt-public-id"

	local result=0 attempt_id="" lease_token=""
	attempt_id=$(jq -r '.attempt_id' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl")
	lease_token=$(jq -r '.lease_token' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl")
	[[ "$attempt_id" == "attempt-public-id" ]] || result=1
	[[ "$lease_token" == "private-lease-token" && "$attempt_id" != "$lease_token" ]] || result=1
	print_result "register keeps public attempt identity separate from the dispatch lease" "$result" \
		"attempt=${attempt_id}, lease=${lease_token}"
	teardown_test_env
	return 0
}

test_terminal_updates_target_exact_attempt() {
	setup_test_env
	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 \
		--repo "owner/repo" --pid $$ --attempt-id "attempt-a"
	run_helper "$LEDGER_HELPER" fail --session-key "issue-42" --attempt-id "attempt-a"
	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 \
		--repo "owner/repo" --pid $$ --attempt-id "attempt-b"
	# A late completion from attempt A must not close active attempt B.
	run_helper "$LEDGER_HELPER" complete --session-key "issue-42" --attempt-id "attempt-a"

	local result=0 first_status="" second_status=""
	first_status=$(jq -rs 'map(select(.attempt_id == "attempt-a")) | last | .status' \
		"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl")
	second_status=$(jq -rs 'map(select(.attempt_id == "attempt-b")) | last | .status' \
		"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl")
	[[ "$first_status" == "failed" && "$second_status" == "in-flight" ]] || result=1
	print_result "terminal updates target one dispatch attempt instead of every session generation" "$result" \
		"attempt-a=${first_status}, attempt-b=${second_status}"
	teardown_test_env
	return 0
}

test_record_recovery_is_idempotent() {
	setup_test_env
	run_helper "$LEDGER_HELPER" register --session-key "issue-27138" --issue 27138 --repo "owner/repo" --pid $$ --worktree "/private/worker/path"
	run_helper "$LEDGER_HELPER" record-recovery --session-key "issue-27138" --runner-key "runner-test" --worktree "/private/worker/path" --branch "feature/gh27138" --changed-paths $'M  staged.txt\n M unstaged.txt\n?? new.txt' --recoverability "same-runner"
	run_helper "$LEDGER_HELPER" record-recovery --session-key "issue-27138" --runner-key "runner-test" --worktree "/private/worker/path" --branch "feature/gh27138" --changed-paths $'M  staged.txt\n M unstaged.txt\n?? new.txt' --recoverability "same-runner"

	local result=0
	local entry_count=""
	local attempts=""
	local changed_count=""
	entry_count=$(wc -l <"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" | tr -d ' ')
	attempts=$(jq -r '.recovery_attempts' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl")
	changed_count=$(jq -r '.changed_paths | length' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl")
	[[ "$entry_count" == "1" && "$attempts" == "2" && "$changed_count" == "3" ]] || result=1
	print_result "dirty recovery metadata updates one durable ledger entry" "$result" "entries=${entry_count}, attempts=${attempts}, changed=${changed_count}"
	teardown_test_env
	return 0
}

test_record_recovery_rejects_missing_option_values() {
	setup_test_env
	local result=0
	local option=""
	local error_file="${TEST_ROOT}/error.log"
	for option in --session-key --runner-key --worktree --branch --changed-paths --recoverability; do
		run_helper "$LEDGER_HELPER" record-recovery "$option" 2>"$error_file"
		if [[ "$LAST_EXIT" -eq 0 ]] || ! grep -Fq "Error: $option requires an argument" "$error_file"; then
			result=1
			break
		fi
	done
	print_result "record-recovery rejects missing option values cleanly" "$result" "option=${option} exit=${LAST_EXIT}"
	teardown_test_env
	return 0
}

test_tier_telemetry_correlates_terminal_outcomes() {
	setup_test_env
	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 \
		--repo "owner/repo" --pid $$ --tier simple --model model-a \
		--attempt-id attempt-42 --lease-token private-lease-42
	run_helper "$LEDGER_HELPER" register --session-key "issue-43" --issue 43 \
		--repo "owner/repo" --pid $$ --tier standard --model model-b \
		--attempt-id attempt-43 --lease-token private-lease-43
	run_helper "$LEDGER_HELPER" record-outcome --session-key "issue-42" \
		--lease-token private-lease-42 --issue 42 --repo "owner/repo" --outcome success
	# Aggregate the streamed records so a later unrelated row cannot hide an
	# existing terminal outcome for this attempt.
	run_helper "$LEDGER_HELPER" register --session-key "issue-44" --issue 44 \
		--repo "owner/repo" --pid $$ --tier standard --model model-c \
		--attempt-id attempt-44 --lease-token private-lease-44
	# Repeated cleanup and a conflicting late event must not create or replace the
	# first terminal result for this attempt.
	run_helper "$LEDGER_HELPER" record-outcome --session-key "issue-42" \
		--lease-token private-lease-42 --issue 42 --repo "owner/repo" --outcome success
	run_helper "$LEDGER_HELPER" record-outcome --session-key "issue-42" \
		--lease-token private-lease-42 --issue 42 --repo "owner/repo" --outcome failed
	# Raw duplicate and unmatched rows model pre-v2 data or manual corruption.
	# The report must normalize the known attempt and keep unmatched data separate.
	printf '%s\n' '{"schema":2,"attempt_id":"attempt-42","issue":"42","repo":"owner/repo","tier":"simple","outcome":"success","completed_at":"2026-01-01T00:00:00Z"}' >>"${AIDEVOPS_DISPATCH_LEDGER_DIR}/tier-telemetry.jsonl"
	printf '%s\n' '{"issue":"999","repo":"owner/repo","tier":"simple","outcome":"success","completed_at":"2026-01-01T00:00:00Z"}' >>"${AIDEVOPS_DISPATCH_LEDGER_DIR}/tier-telemetry.jsonl"

	local telemetry_file="${AIDEVOPS_DISPATCH_LEDGER_DIR}/tier-telemetry.jsonl"
	local result=0
	local pending_count="" success_count="" terminal_count="" terminal_tier="" report=""
	pending_count=$(jq -s '[.[] | select(.outcome == "pending")] | length' "$telemetry_file")
	success_count=$(jq -s '[.[] | select(.outcome == "success")] | length' "$telemetry_file")
	terminal_count=$(jq -s '[.[] | select(.outcome != "pending")] | length' "$telemetry_file")
	terminal_tier=$(jq -rs 'first(.[] | select(.attempt_id == "attempt-42" and .outcome == "success") | .tier)' "$telemetry_file")
	report=$("$LEDGER_HELPER" tier-report)
	[[ "$pending_count" == "3" && "$success_count" == "3" && "$terminal_count" == "3" ]] || result=1
	[[ "$terminal_tier" == "simple" ]] || result=1
	[[ "$report" == *"Total dispatches: 3"* && "$report" == *"Pending/unknown: 2"* ]] || result=1
	[[ "$report" == *"Success: 1"* && "$report" == *"Legacy/unmatched terminal events: 1"* ]] || result=1
	[[ "$report" == *"tier:simple — 1/1 (100.0%)"* && "$report" != *"tier:standard"* ]] || result=1
	print_result "tier telemetry correlates and idempotently reports terminal outcomes" "$result" \
		"pending=${pending_count}, success=${success_count}, terminal=${terminal_count}, tier=${terminal_tier}"
	teardown_test_env
	return 0
}

test_tier_telemetry_handles_retries_and_legacy_pending() {
	setup_test_env
	local telemetry_file="${AIDEVOPS_DISPATCH_LEDGER_DIR}/tier-telemetry.jsonl"
	printf '%s\n' '{"issue":"7","repo":"owner/repo","tier":"simple","model":"legacy-model","dispatched_at":"2026-01-01T00:00:00Z","outcome":"pending"}' >"$telemetry_file"
	printf '%s\n' '{"issue":"7","repo":"owner/repo","tier":"simple","outcome":"failed","reason":"legacy_failure","completed_at":"2026-01-01T01:00:00Z"}' >>"$telemetry_file"
	run_helper "$LEDGER_HELPER" register --session-key "issue-7" --issue 7 \
		--repo "owner/repo" --pid $$ --tier thinking --model model-new --lease-token retry-7
	run_helper "$LEDGER_HELPER" record-outcome --issue 7 --repo "owner/repo" --outcome success
	run_helper "$LEDGER_HELPER" record-outcome --issue 7 --repo "owner/repo" --outcome failed

	local result=0
	local success_tier="" failed_tier="" legacy_pending="" terminal_count="" report=""
	success_tier=$(jq -r 'select(.outcome == "success") | .tier' "$telemetry_file")
	failed_tier=$(jq -r 'select(.outcome == "failed") | .tier' "$telemetry_file")
	legacy_pending=$(jq -s '[.[] | select(.outcome == "pending" and .model == "legacy-model")] | length' "$telemetry_file")
	terminal_count=$(jq -s '[.[] | select(.outcome != "pending")] | length' "$telemetry_file")
	report=$("$LEDGER_HELPER" tier-report)
	[[ "$success_tier" == "thinking" && "$failed_tier" == "simple" && "$legacy_pending" == "1" && "$terminal_count" == "2" ]] || result=1
	[[ "$report" == *"Success: 1"* && "$report" == *"Failed: 1"* && "$report" == *"Pending/unknown: 0"* ]] || result=1
	[[ "$report" == *"Legacy/unmatched terminal events: 0"* ]] || result=1
	print_result "tier telemetry pairs retries newest-first and supports legacy pending rows" "$result" \
		"success_tier=${success_tier}, failed_tier=${failed_tier}, legacy=${legacy_pending}"
	teardown_test_env
	return 0
}

#######################################
# Test: check detects in-flight entry
#######################################
test_check_detects_inflight() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-99" --issue 99 --repo "owner/repo" --pid $$

	local result=1
	if "$LEDGER_HELPER" check --session-key "issue-99" >/dev/null 2>&1; then
		result=0
	fi

	print_result "check detects in-flight entry" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: check returns 1 for unknown session key
#######################################
test_check_returns_1_for_unknown() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$

	local result=0
	if "$LEDGER_HELPER" check --session-key "issue-999" >/dev/null 2>&1; then
		result=1
	fi

	print_result "check returns 1 for unknown session key" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: check-issue detects in-flight by issue number
#######################################
test_check_issue_detects_inflight() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-55" --issue 55 --repo "owner/repo" --pid $$

	local result=1
	if "$LEDGER_HELPER" check-issue --issue 55 --repo "owner/repo" >/dev/null 2>&1; then
		result=0
	fi

	print_result "check-issue detects in-flight by issue number" "$result"
	teardown_test_env
	return 0
}


#######################################
# Test: check-issue accepts positional ISSUE REPO syntax
#######################################
test_check_issue_positional_syntax() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-56" --issue 56 --repo "owner/repo" --pid $$

	local result=1
	if "$LEDGER_HELPER" check-issue 56 "owner/repo" >/dev/null 2>&1; then
		result=0
	fi

	print_result "check-issue accepts positional issue and repo" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: check-issue returns 1 for different repo
#######################################
test_check_issue_different_repo() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-55" --issue 55 --repo "owner/repo-a" --pid $$

	local result=0
	if "$LEDGER_HELPER" check-issue --issue 55 --repo "owner/repo-b" >/dev/null 2>&1; then
		result=1
	fi

	print_result "check-issue returns 1 for different repo" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: complete marks entry as completed
#######################################
test_complete_marks_entry() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" complete --session-key "issue-42"

	# A late fail (e.g., from dead-PID cleanup) must NOT overwrite completed status
	run_helper "$LEDGER_HELPER" fail --session-key "issue-42"

	# check should still return 1 (no in-flight entry)
	local result=0
	if "$LEDGER_HELPER" check --session-key "issue-42" >/dev/null 2>&1; then
		result=1
	fi

	# Verify status is still "completed" — not downgraded to "failed"
	local status
	status=$(jq -r '.status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status" != "completed" ]]; then
		result=1
	fi

	print_result "complete marks entry as completed (terminal state immutable)" "$result" "status=${status}"
	teardown_test_env
	return 0
}

test_typed_terminal_reason_is_lease_bound() {
	setup_test_env
	run_helper "$LEDGER_HELPER" register --session-key "issue-27854" --issue 27854 --repo "owner/repo" \
		--pid $$ --lease-token "lease-current"
	run_helper "$LEDGER_HELPER" complete --session-key "issue-27854" --lease-token "lease-current" \
		--reason merged_pr_reap

	local result=0 reason=""
	reason=$("$LEDGER_HELPER" terminal-reason --session-key "issue-27854" --lease-token "lease-current") || result=1
	[[ "$reason" == "merged_pr_reap" ]] || result=1
	if "$LEDGER_HELPER" terminal-reason --session-key "issue-27854" --lease-token "lease-stale" >/dev/null 2>&1; then
		result=1
	fi
	print_result "typed terminal reason is bound to the exact dispatch lease" "$result" "reason=${reason}"
	teardown_test_env
	return 0
}

#######################################
# Test: fail marks entry as failed
#######################################
test_fail_marks_entry() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" fail --session-key "issue-42"

	local status
	status=$(jq -r '.status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)

	local result=0
	if [[ "$status" != "failed" ]]; then
		result=1
	fi

	print_result "fail marks entry as failed" "$result" "status=${status}"
	teardown_test_env
	return 0
}

#######################################
# Test: terminal status immutability — fail cannot overwrite completed,
# complete cannot overwrite failed (regression for CodeRabbit review)
#######################################
test_terminal_state_immutability() {
	setup_test_env

	local result=0

	# Case 1: fail must not overwrite completed
	run_helper "$LEDGER_HELPER" register --session-key "issue-77" --issue 77 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" complete --session-key "issue-77"
	run_helper "$LEDGER_HELPER" fail --session-key "issue-77"

	local status1
	status1=$(jq -r 'select(.session_key == "issue-77") | .status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status1" != "completed" ]]; then
		result=1
	fi

	# Case 2: complete must not overwrite failed
	run_helper "$LEDGER_HELPER" register --session-key "issue-78" --issue 78 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" fail --session-key "issue-78"
	run_helper "$LEDGER_HELPER" complete --session-key "issue-78"

	local status2
	status2=$(jq -r 'select(.session_key == "issue-78") | .status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status2" != "failed" ]]; then
		result=1
	fi

	print_result "terminal status immutability (completed/failed are final)" "$result" "completed_after_fail=${status1}, failed_after_complete=${status2}"
	teardown_test_env
	return 0
}

#######################################
# Test: legacy tokenless register retries remain idempotent.
#######################################
test_register_idempotent() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$

	local entry_count active_count
	entry_count=$(wc -l <"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" | tr -d ' ')
	active_count=$("$LEDGER_HELPER" count)

	local result=0
	if [[ "$entry_count" -ne 1 || "$active_count" -ne 1 ]]; then
		result=1
	fi

	print_result "tokenless register retry does not duplicate active entry" "$result" "entries=${entry_count}, active=${active_count}"
	teardown_test_env
	return 0
}

#######################################
# Test: count returns correct number of in-flight entries
#######################################
test_count_inflight() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-1" --issue 1 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" register --session-key "issue-2" --issue 2 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" register --session-key "issue-3" --issue 3 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" complete --session-key "issue-2"

	local count
	count=$("$LEDGER_HELPER" count)

	local result=0
	if [[ "$count" -ne 2 ]]; then
		result=1
	fi

	print_result "count returns correct number of in-flight entries" "$result" "count=${count} (expected 2)"
	teardown_test_env
	return 0
}

#######################################
# Test: expire removes stale entries by TTL
#######################################
test_expire_by_ttl() {
	setup_test_env

	# Create an entry with a timestamp 2 hours ago
	local old_ts
	old_ts=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "2020-01-01T00:00:00Z")

	printf '{"session_key":"issue-old","issue_number":"100","repo_slug":"owner/repo","pid":99999999,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$old_ts" "$old_ts" >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"

	local expired_count
	expired_count=$("$LEDGER_HELPER" expire --ttl 60)

	local result=0
	if [[ "$expired_count" -ne 1 ]]; then
		result=1
	fi

	# Verify status changed to failed
	local status
	status=$(jq -r '.status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status" != "failed" ]]; then
		result=1
	fi

	print_result "expire removes stale entries by TTL" "$result" "expired=${expired_count}, status=${status}"
	teardown_test_env
	return 0
}

#######################################
# Test: expire detects dead PIDs
#######################################
test_expire_dead_pid() {
	setup_test_env

	local now_ts
	now_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# Use a PID that definitely doesn't exist (99999999)
	printf '{"session_key":"issue-dead","issue_number":"200","repo_slug":"owner/repo","pid":99999999,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$now_ts" "$now_ts" >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"

	local expired_count
	expired_count=$("$LEDGER_HELPER" expire --ttl 99999)

	local result=0
	if [[ "$expired_count" -ne 1 ]]; then
		result=1
	fi

	print_result "expire detects dead PIDs" "$result" "expired=${expired_count}"
	teardown_test_env
	return 0
}

#######################################
# Test: expire rejects --ttl without a value
#######################################
test_expire_missing_ttl_value() {
	setup_test_env

	run_helper "$LEDGER_HELPER" expire --ttl

	local result=0
	if [[ "$LAST_EXIT" -eq 0 ]]; then
		result=1
	fi

	print_result "expire rejects --ttl without a value" "$result" "exit=${LAST_EXIT}"
	teardown_test_env
	return 0
}

#######################################
# Test: check detects dead PID and marks as failed
#######################################
test_check_dead_pid_marks_failed() {
	setup_test_env

	local now_ts
	now_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# Register with a dead PID
	printf '{"session_key":"issue-dead","issue_number":"300","repo_slug":"owner/repo","pid":99999999,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$now_ts" "$now_ts" >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"

	# check should return 1 (safe to dispatch) because PID is dead
	local result=0
	if "$LEDGER_HELPER" check --session-key "issue-dead" >/dev/null 2>&1; then
		result=1
	fi

	print_result "check detects dead PID and returns safe-to-dispatch" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: prune removes old completed/failed entries
#######################################
test_prune_old_entries() {
	setup_test_env

	local old_ts
	old_ts=$(date -u -d '48 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-48H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "2020-01-01T00:00:00Z")
	local now_ts
	now_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# One old completed entry, one recent in-flight entry
	{
		printf '{"session_key":"issue-old","issue_number":"100","repo_slug":"owner/repo","pid":1,"dispatched_at":"%s","status":"completed","updated_at":"%s"}\n' "$old_ts" "$old_ts"
		printf '{"session_key":"issue-new","issue_number":"200","repo_slug":"owner/repo","pid":%d,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$$" "$now_ts" "$now_ts"
	} >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"

	local pruned_count
	pruned_count=$("$LEDGER_HELPER" prune)

	local remaining
	remaining=$(wc -l <"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" | tr -d ' ')

	local result=0
	if [[ "$pruned_count" -ne 1 ]]; then
		result=1
	fi
	if [[ "$remaining" -ne 1 ]]; then
		result=1
	fi

	print_result "prune removes old completed/failed entries" "$result" "pruned=${pruned_count}, remaining=${remaining}"
	teardown_test_env
	return 0
}

#######################################
# Test: status command runs without error
#######################################
test_status_runs() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$

	local output
	output=$("$LEDGER_HELPER" status 2>&1)
	local exit_code=$?

	local result=0
	if [[ "$exit_code" -ne 0 ]]; then
		result=1
	fi

	print_result "status command runs without error" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: empty ledger operations don't fail
#######################################
test_empty_ledger_operations() {
	setup_test_env

	local result=0

	# All operations should succeed on empty ledger
	if "$LEDGER_HELPER" check --session-key "nonexistent" >/dev/null 2>&1; then
		result=1 # Should return 1 (not found)
	fi

	local count
	count=$("$LEDGER_HELPER" count)
	if [[ "$count" -ne 0 ]]; then
		result=1
	fi

	local expired
	expired=$("$LEDGER_HELPER" expire)
	if [[ "$expired" -ne 0 ]]; then
		result=1
	fi

	"$LEDGER_HELPER" status >/dev/null 2>&1 || result=1

	print_result "empty ledger operations don't fail" "$result" "count=${count}"
	teardown_test_env
	return 0
}

#######################################
# t2999: stale-lock recovery — dead-PID stale lock
#
# Place a fake pid file with a PID known to be dead inside the lockdir.
# The next register call should detect the stale lock, clear it, and
# succeed.
#######################################
test_stale_lock_recovered_dead_pid() {
	setup_test_env

	# Skip when flock is available — flock path doesn't use mkdir lockdir.
	if command -v flock &>/dev/null; then
		print_result "stale-lock recovered (dead PID)" 0 "skipped: flock present, mkdir path not exercised"
		teardown_test_env
		return 0
	fi

	local ledger_dir="${AIDEVOPS_DISPATCH_LEDGER_DIR}"
	local lock_dir="${ledger_dir}/dispatch-ledger.lock.d"
	mkdir -p "$lock_dir"
	# A PID very unlikely to be in use. ps returns non-zero on absent PID.
	echo "999999" >"${lock_dir}/pid"

	run_helper "$LEDGER_HELPER" register --session-key "stale-test-1" --issue 1 --repo "owner/repo" --pid $$
	local register_exit="$LAST_EXIT"

	local result=0
	if [[ "$register_exit" -ne 0 ]]; then
		result=1
	fi
	# Lock should be released after register completes.
	if [[ -d "$lock_dir" ]]; then
		result=1
	fi
	# Entry should have been written.
	if [[ ! -s "${ledger_dir}/dispatch-ledger.jsonl" ]]; then
		result=1
	fi

	print_result "stale-lock recovered (dead PID 999999)" "$result" \
		"register_exit=${register_exit}, lock_dir_present=$([[ -d $lock_dir ]] && echo yes || echo no)"
	teardown_test_env
	return 0
}

#######################################
# t2999: stale-lock recovery — no PID file, old mtime (legacy/corrupt)
#
# Simulates the actual production bug: a lockdir from an old client
# (no PID file written), abandoned 24 days ago. mtime-based staleness
# detection should reclaim it.
#######################################
test_stale_lock_recovered_no_pid_old_mtime() {
	setup_test_env

	if command -v flock &>/dev/null; then
		print_result "stale-lock recovered (no PID, old mtime)" 0 "skipped: flock present, mkdir path not exercised"
		teardown_test_env
		return 0
	fi

	local ledger_dir="${AIDEVOPS_DISPATCH_LEDGER_DIR}"
	local lock_dir="${ledger_dir}/dispatch-ledger.lock.d"
	mkdir -p "$lock_dir"
	# Backdate the directory mtime well beyond the 60s default ceiling.
	# touch -t YYYYMMDDhhmm — set to 1 hour in the past.
	local backdate
	backdate=$(date -u -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -u -d '1 hour ago' '+%Y%m%d%H%M' 2>/dev/null || echo "")
	if [[ -n "$backdate" ]]; then
		touch -t "$backdate" "$lock_dir" 2>/dev/null || true
	fi

	run_helper "$LEDGER_HELPER" register --session-key "stale-test-2" --issue 2 --repo "owner/repo" --pid $$
	local register_exit="$LAST_EXIT"

	local result=0
	if [[ "$register_exit" -ne 0 ]]; then
		result=1
	fi
	if [[ -d "$lock_dir" ]]; then
		result=1
	fi
	if [[ ! -s "${ledger_dir}/dispatch-ledger.jsonl" ]]; then
		result=1
	fi

	print_result "stale-lock recovered (no PID file, old mtime)" "$result" \
		"register_exit=${register_exit}, lock_dir_present=$([[ -d $lock_dir ]] && echo yes || echo no)"
	teardown_test_env
	return 0
}

#######################################
# t2999: live owner within max_age must NOT be reclaimed
#
# A lockdir owned by a live PID with fresh mtime must survive — stealing
# it would corrupt concurrent registrations. Verify by setting a very
# high max_age (1 hour) and confirming register fails to acquire within
# the 5s mkdir timeout.
#######################################
test_stale_lock_blocks_on_live_owner_within_max_age() {
	setup_test_env

	if command -v flock &>/dev/null; then
		print_result "live owner blocks within max_age" 0 "skipped: flock present, mkdir path not exercised"
		teardown_test_env
		return 0
	fi

	local ledger_dir="${AIDEVOPS_DISPATCH_LEDGER_DIR}"
	local lock_dir="${ledger_dir}/dispatch-ledger.lock.d"
	mkdir -p "$lock_dir"
	# Use this test process's own PID — guaranteed alive.
	echo "$$" >"${lock_dir}/pid"

	# Set a generous max_age so age-based reclaim cannot fire.
	export AIDEVOPS_LEDGER_LOCK_MAX_AGE_S=3600

	run_helper "$LEDGER_HELPER" register --session-key "live-owner-test" --issue 3 --repo "owner/repo" --pid $$
	local register_exit="$LAST_EXIT"

	unset AIDEVOPS_LEDGER_LOCK_MAX_AGE_S

	local result=0
	# Expect register to fail (lock contention) — the live lock must hold.
	if [[ "$register_exit" -eq 0 ]]; then
		result=1
	fi
	# Live lock must still be present.
	if [[ ! -d "$lock_dir" ]]; then
		result=1
	fi
	# Our PID must still be in the lock file (not overwritten).
	local recorded_pid
	recorded_pid=$(cat "${lock_dir}/pid" 2>/dev/null || echo "")
	if [[ "$recorded_pid" != "$$" ]]; then
		result=1
	fi

	# Cleanup the live lock manually since release_lock didn't run.
	rm -rf "$lock_dir" 2>/dev/null || true

	print_result "live owner blocks within max_age" "$result" \
		"register_exit=${register_exit}, recorded_pid=${recorded_pid}, expected=${$}"
	teardown_test_env
	return 0
}

#######################################
# t2999: backward-compat — legacy lockdir without PID file
#
# Older clients did not write a PID file. A fresh legacy lockdir
# (mtime <= max_age, no PID file) must NOT be reclaimed (would steal
# from a live old-client). After max_age expires, mtime-based recovery
# fires (covered by test_stale_lock_recovered_no_pid_old_mtime).
#######################################
test_stale_lock_recovered_legacy_no_pid_lockdir() {
	setup_test_env

	if command -v flock &>/dev/null; then
		print_result "legacy no-PID lockdir respected within max_age" 0 "skipped: flock present, mkdir path not exercised"
		teardown_test_env
		return 0
	fi

	local ledger_dir="${AIDEVOPS_DISPATCH_LEDGER_DIR}"
	local lock_dir="${ledger_dir}/dispatch-ledger.lock.d"
	mkdir -p "$lock_dir"
	# No PID file — fresh legacy lockdir.

	# Default max_age=60s; a freshly-created lockdir is age 0.
	run_helper "$LEDGER_HELPER" register --session-key "legacy-fresh" --issue 4 --repo "owner/repo" --pid $$
	local register_exit="$LAST_EXIT"

	local result=0
	# Expect register to fail (lock contention) — the fresh legacy lock holds.
	if [[ "$register_exit" -eq 0 ]]; then
		result=1
	fi

	# Cleanup
	rm -rf "$lock_dir" 2>/dev/null || true

	print_result "legacy no-PID lockdir respected within max_age" "$result" \
		"register_exit=${register_exit} (expected non-zero)"
	teardown_test_env
	return 0
}

#######################################
# t2999: _release_lock must clear lockdir even when it contains a PID file
#
# After register, the lockdir should be gone. Catches regression where
# a switch back to rmdir would fail silently on a non-empty dir.
#######################################
test_release_clears_lockdir_with_pid_file() {
	setup_test_env

	if command -v flock &>/dev/null; then
		print_result "release clears lockdir with PID file" 0 "skipped: flock present, mkdir path not exercised"
		teardown_test_env
		return 0
	fi

	local ledger_dir="${AIDEVOPS_DISPATCH_LEDGER_DIR}"
	local lock_dir="${ledger_dir}/dispatch-ledger.lock.d"

	run_helper "$LEDGER_HELPER" register --session-key "release-test" --issue 5 --repo "owner/repo" --pid $$
	local register_exit="$LAST_EXIT"

	local result=0
	if [[ "$register_exit" -ne 0 ]]; then
		result=1
	fi
	# Lockdir must be gone after register completes.
	if [[ -d "$lock_dir" ]]; then
		result=1
	fi

	print_result "release clears lockdir with PID file" "$result" \
		"register_exit=${register_exit}, lock_dir_present=$([[ -d $lock_dir ]] && echo yes || echo no)"
	teardown_test_env
	return 0
}

#######################################
# Run all tests
#######################################
main() {
	echo "=== dispatch-ledger-helper.sh tests (GH#6696) ==="
	echo ""

	# Verify helper exists
	if [[ ! -x "$LEDGER_HELPER" ]]; then
		echo "ERROR: dispatch-ledger-helper.sh not found at $LEDGER_HELPER"
		exit 1
	fi

	# Verify jq is available
	if ! command -v jq &>/dev/null; then
		echo "ERROR: jq is required for tests"
		exit 1
	fi

	test_register_creates_entry
	test_register_separates_attempt_identity_from_lease
	test_terminal_updates_target_exact_attempt
	test_record_recovery_is_idempotent
	test_record_recovery_rejects_missing_option_values
	test_tier_telemetry_correlates_terminal_outcomes
	test_tier_telemetry_handles_retries_and_legacy_pending
	test_check_detects_inflight
	test_check_returns_1_for_unknown
	test_check_issue_detects_inflight
	test_check_issue_positional_syntax
	test_check_issue_different_repo
	test_complete_marks_entry
	test_typed_terminal_reason_is_lease_bound
	test_terminal_state_immutability
	test_fail_marks_entry
	test_register_idempotent
	test_count_inflight
	test_expire_by_ttl
	test_expire_dead_pid
	test_expire_missing_ttl_value
	test_check_dead_pid_marks_failed
	test_prune_old_entries
	test_status_runs
	test_empty_ledger_operations
	# t2999: stale-lock recovery
	test_stale_lock_recovered_dead_pid
	test_stale_lock_recovered_no_pid_old_mtime
	test_stale_lock_blocks_on_live_owner_within_max_age
	test_stale_lock_recovered_legacy_no_pid_lockdir
	test_release_clears_lockdir_with_pid_file

	echo ""
	echo "=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
