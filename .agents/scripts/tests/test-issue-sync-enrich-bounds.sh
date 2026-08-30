#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/issue-sync-helper.sh"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/issue-sync-reusable.yml"

TESTS_RUN=0
TESTS_FAILED=0
ENRICH_TEST_FAIL_TASK=""
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:-}"' EXIT

print_result() {
	local name="$1" passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

write_todo_fixture() {
	cat >"$TMP/TODO.md" <<'EOF'
## Ready

- [ ] t9001 first task tier:simple ref:GH#9001
- [ ] t9002 second task tier:simple ref:GH#9002
- [ ] t9003 third task tier:simple ref:GH#9003
EOF
	return 0
}

# shellcheck source=../issue-sync-helper.sh
# shellcheck disable=SC1090
source "$HELPER"

_init_cmd() {
	_CMD_ROOT="$TMP"
	_CMD_REPO="example/repo"
	_CMD_TODO="$TMP/TODO.md"
	return 0
}

_enrich_process_task() {
	local task_id="$1" repo="$2" todo_file="$3" project_root="$4"
	: "$repo" "$todo_file" "$project_root"
	if [[ -n "$ENRICH_TEST_FAIL_TASK" && "$task_id" == "$ENRICH_TEST_FAIL_TASK" ]]; then
		return 1
	fi
	printf '%s\n' "$task_id" >>"$TMP/processed.log"
	printf 'ENRICHED\n'
	return 0
}

_enrich_check_rate_limit() {
	return 1
}

_enrich_prefetch_issues_map() {
	local repo="$1"
	: "$repo"
	return 1
}

test_workflow_push_sets_bounded_enrich() {
	if grep -q 'AIDEVOPS_ENRICH_MAX_ISSUES' "$WORKFLOW_FILE" &&
		grep -q 'AIDEVOPS_ENRICH_MAX_SECONDS' "$WORKFLOW_FILE" &&
		grep -q 'manual dispatch still' "$WORKFLOW_FILE"; then
		print_result "push workflow configures bounded enrich while documenting manual full enrich" 0
	else
		print_result "push workflow configures bounded enrich while documenting manual full enrich" 1
	fi
	return 0
}

test_workflow_manual_enrich_has_full_pass_headroom() {
	local manual_job
	manual_job=$(awk '
		/^  manual-sync:/ { capture = 1 }
		capture && /^  [[:alnum:]_-]+:/ && $0 !~ /^  manual-sync:/ { exit }
		capture { print }
	' "$WORKFLOW_FILE")
	if grep -q '^    timeout-minutes: 30$' <<<"$manual_job" &&
		[[ "$manual_job" != *"AIDEVOPS_ENRICH_MAX_ISSUES"* ]] &&
		[[ "$manual_job" != *"AIDEVOPS_ENRICH_MAX_SECONDS"* ]]; then
		print_result "manual full enrich has 30-minute headroom without routine bounds" 0
	else
		printf '%s\n' "$manual_job"
		print_result "manual full enrich has 30-minute headroom without routine bounds" 1
	fi
	return 0
}

test_max_issues_bounds_enrich_loop() {
	write_todo_fixture
	: >"$TMP/processed.log"
	local output
	output=$(AIDEVOPS_ENRICH_MAX_ISSUES=2 AIDEVOPS_ENRICH_MAX_SECONDS=0 cmd_enrich 2>&1)
	local processed_count
	processed_count=$(wc -l <"$TMP/processed.log" | tr -d ' ')
	if [[ "$processed_count" == "2" && "$output" == *"Stopping bounded enrich after 2 issue(s)"* ]]; then
		print_result "max issue bound stops enrich before full backlog" 0
	else
		printf '%s\n' "$output"
		print_result "max issue bound stops enrich before full backlog" 1
	fi
	return 0
}

test_target_task_ignores_routine_bounds() {
	write_todo_fixture
	: >"$TMP/processed.log"
	local output
	output=$(AIDEVOPS_ENRICH_MAX_ISSUES=0 AIDEVOPS_ENRICH_MAX_SECONDS=0 cmd_enrich t9002 2>&1)
	local processed
	processed=$(tr -d '\n' <"$TMP/processed.log")
	if [[ "$processed" == "t9002" && "$output" != *"Bounded enrich active"* ]]; then
		print_result "single target enrich remains unbounded" 0
	else
		printf '%s\n' "$output"
		print_result "single target enrich remains unbounded" 1
	fi
	return 0
}

test_invalid_bounds_are_ignored() {
	write_todo_fixture
	: >"$TMP/processed.log"
	local output
	output=$(AIDEVOPS_ENRICH_MAX_ISSUES=bad AIDEVOPS_ENRICH_MAX_SECONDS=bad cmd_enrich 2>&1)
	local processed_count
	processed_count=$(wc -l <"$TMP/processed.log" | tr -d ' ')
	if [[ "$processed_count" == "3" && "$output" == *"Ignoring invalid enrich issue bound"* && "$output" == *"Ignoring invalid enrich seconds bound"* ]]; then
		print_result "invalid bounds warn and fall back to full enrich" 0
	else
		printf '%s\n' "$output"
		print_result "invalid bounds warn and fall back to full enrich" 1
	fi
	return 0
}

test_bounds_helpers_tolerate_missing_values() {
	local output
	output=$(_enrich_log_bounds_if_active 2>&1)
	if _enrich_should_stop_for_bounds 2>/dev/null; then
		printf '%s\n' "$output"
		print_result "bounds helpers default missing values safely" 1
		return 0
	fi
	if [[ -z "$output" ]]; then
		print_result "bounds helpers default missing values safely" 0
	else
		printf '%s\n' "$output"
		print_result "bounds helpers default missing values safely" 1
	fi
	return 0
}

test_elapsed_bound_tolerates_date_failure() {
	date() {
		return 1
	}
	local output
	set +e
	output=$(_enrich_should_stop_for_bounds 0 1 0 1 "" 2>&1)
	local status=$?
	set -e
	unset -f date
	if [[ "$status" -eq 1 && -z "$output" ]]; then
		print_result "elapsed bound uses safe date and started_at defaults" 0
	else
		printf '%s\n' "$output"
		print_result "elapsed bound uses safe date and started_at defaults" 1
	fi
	return 0
}

test_task_failure_propagates() {
	write_todo_fixture
	: >"$TMP/processed.log"
	ENRICH_TEST_FAIL_TASK="t9002"
	local output status=0
	set +e
	output=$(AIDEVOPS_ENRICH_MAX_ISSUES=0 AIDEVOPS_ENRICH_MAX_SECONDS=0 cmd_enrich t9002 2>&1)
	status=$?
	set -e
	ENRICH_TEST_FAIL_TASK=""
	if [[ "$status" -eq 1 && "$output" == *"Enrich failed: 1 task(s)"* && ! -s "$TMP/processed.log" ]]; then
		print_result "task composition failure makes enrich fail closed" 0
	else
		printf '%s\n' "$output"
		print_result "task composition failure makes enrich fail closed" 1
	fi
	return 0
}

main() {
	test_workflow_push_sets_bounded_enrich
	test_workflow_manual_enrich_has_full_pass_headroom
	test_max_issues_bounds_enrich_loop
	test_target_task_ignores_routine_bounds
	test_invalid_bounds_are_ignored
	test_bounds_helpers_tolerate_missing_values
	test_elapsed_bound_tolerates_date_failure
	test_task_failure_propagates
	printf 'Tests run: %s\n' "$TESTS_RUN"
	printf 'Tests failed: %s\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
