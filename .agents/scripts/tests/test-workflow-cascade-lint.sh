#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-workflow-cascade-lint.sh — test harness for workflow-cascade-lint.sh (t2229)
#
# Tests the cascade vulnerability linter against fixture YAML files covering:
# - Vulnerable workflows (labeled + cancel-in-progress + no mitigation)
# - Vulnerable workflows even with paths-ignore/event-action guards
# - Safe workflows (no labeled trigger, no cancel-in-progress)
# - Dry-run mode
#
# Run: bash .agents/scripts/tests/test-workflow-cascade-lint.sh

# See test-harness-template.sh PITFALL 1: set -e intentionally omitted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/../workflow-cascade-lint.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# ─── Test infrastructure ────────────────────────────────────────────────────

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

_create_fixture_vulnerable() {
	cat > "${TEST_ROOT}/fixtures/vulnerable.yml" << 'YAML'
name: Vulnerable Workflow
on:
  issues:
    types: [labeled]
permissions:
  issues: write
jobs:
  post-comment:
    if: github.event.label.name == 'needs-maintainer-review'
    runs-on: ubuntu-latest
    concurrency:
      group: nmr-hold-${{ github.event.issue.number }}
      cancel-in-progress: true
    steps:
      - name: Do work
        run: echo "Working"
YAML
	return 0
}

_create_fixture_vulnerable_pr() {
	cat > "${TEST_ROOT}/fixtures/vulnerable-pr.yml" << 'YAML'
name: Vulnerable PR Workflow
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Checking"
YAML
	return 0
}

_create_fixture_mitigated_paths_ignore() {
	cat > "${TEST_ROOT}/fixtures/mitigated-paths-ignore.yml" << 'YAML'
name: Mitigated With Paths Ignore
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled]
    paths-ignore:
      - '**/*.md'
      - 'todo/**'
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Scanning"
YAML
	return 0
}

_create_fixture_mitigated_action_guard() {
	cat > "${TEST_ROOT}/fixtures/mitigated-action-guard.yml" << 'YAML'
name: Mitigated With Action Guard
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  check:
    if: github.event.action != 'labeled' || contains(github.event.pull_request.labels.*.name, 'target-label')
    runs-on: ubuntu-latest
    steps:
      - run: echo "Checking"
YAML
	return 0
}

_create_fixture_safe_no_labeled() {
	cat > "${TEST_ROOT}/fixtures/safe-no-labeled.yml" << 'YAML'
name: Safe No Labeled
on:
  pull_request:
    types: [opened, synchronize, reopened]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Checking"
YAML
	return 0
}

_create_fixture_safe_no_cancel() {
	cat > "${TEST_ROOT}/fixtures/safe-no-cancel.yml" << 'YAML'
name: Safe No Cancel
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Checking"
YAML
	return 0
}

_create_fixture_vulnerable_multiline() {
	cat > "${TEST_ROOT}/fixtures/vulnerable-multiline.yml" << 'YAML'
name: Vulnerable Multiline Types
on:
  pull_request:
    types:
      - opened
      - synchronize
      - labeled
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Checking"
YAML
	return 0
}

_create_fixture_mitigated_step_guard() {
	cat > "${TEST_ROOT}/fixtures/mitigated-step-guard.yml" << 'YAML'
name: Mitigated Step Guard
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  detect:
    runs-on: ubuntu-latest
    steps:
      - name: Guard
        env:
          EVENT_ACTION: ${{ github.event.action }}
          LABEL_NAME: ${{ github.event.label.name }}
        run: |
          if { [ "${EVENT_ACTION}" = "labeled" ] || [ "${EVENT_ACTION}" = "unlabeled" ]; } && \
             [ "${LABEL_NAME}" != "target-label" ]; then
            echo "Skipping: unrelated label event."
            exit 0
          fi
YAML
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/fixtures"
	export TEST_ROOT

	_create_fixture_vulnerable
	_create_fixture_vulnerable_pr
	_create_fixture_mitigated_paths_ignore
	_create_fixture_mitigated_action_guard
	_create_fixture_safe_no_labeled
	_create_fixture_safe_no_cancel
	_create_fixture_vulnerable_multiline
	_create_fixture_mitigated_step_guard

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "${TEST_ROOT}"
	fi
	return 0
}

# ─── Test cases ─────────────────────────────────────────────────────────────

test_vulnerable_issue_workflow() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "${TEST_ROOT}/fixtures/vulnerable.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 1 ]]; then
		failed=1
	fi
	if ! echo "$output" | grep -q "VULN"; then
		failed=1
	fi
	print_result "vulnerable issue workflow (labeled + cancel-in-progress)" "$failed" "exit=$rc output=$output"
	return 0
}

test_vulnerable_pr_workflow() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "${TEST_ROOT}/fixtures/vulnerable-pr.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 1 ]]; then
		failed=1
	fi
	print_result "vulnerable PR workflow (labeled/unlabeled + cancel-in-progress)" "$failed" "exit=$rc"
	return 0
}

test_vulnerable_multiline_types() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "${TEST_ROOT}/fixtures/vulnerable-multiline.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 1 ]]; then
		failed=1
	fi
	print_result "vulnerable multiline types form" "$failed" "exit=$rc"
	return 0
}

test_paths_ignore_still_vulnerable() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "${TEST_ROOT}/fixtures/mitigated-paths-ignore.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 1 ]]; then
		failed=1
	fi
	print_result "vulnerable despite paths-ignore" "$failed" "exit=$rc output=$output"
	return 0
}

test_action_guard_still_vulnerable() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "${TEST_ROOT}/fixtures/mitigated-action-guard.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 1 ]]; then
		failed=1
	fi
	print_result "vulnerable despite job-level event-action guard" "$failed" "exit=$rc output=$output"
	return 0
}

test_step_guard_still_vulnerable() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "${TEST_ROOT}/fixtures/mitigated-step-guard.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 1 ]]; then
		failed=1
	fi
	print_result "vulnerable despite step-level EVENT_ACTION guard" "$failed" "exit=$rc output=$output"
	return 0
}

test_safe_no_labeled_trigger() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "${TEST_ROOT}/fixtures/safe-no-labeled.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 0 ]]; then
		failed=1
	fi
	print_result "safe: no labeled trigger type" "$failed" "exit=$rc"
	return 0
}

test_safe_no_cancel_in_progress() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "${TEST_ROOT}/fixtures/safe-no-cancel.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 0 ]]; then
		failed=1
	fi
	print_result "safe: no cancel-in-progress" "$failed" "exit=$rc"
	return 0
}

test_dry_run_exits_zero() {
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" --dry-run "${TEST_ROOT}/fixtures/vulnerable.yml" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 0 ]]; then
		failed=1
	fi
	if ! echo "$output" | grep -q "VULN"; then
		failed=1
	fi
	print_result "dry-run mode: lists VULN but exits 0" "$failed" "exit=$rc output=$output"
	return 0
}

test_output_md_report() {
	local output rc report_file
	report_file="${TEST_ROOT}/report.md"
	output=$(bash "$SCRIPT_UNDER_TEST" --output-md "$report_file" "${TEST_ROOT}/fixtures/vulnerable.yml" 2>&1)
	rc=$?
	local failed=0
	if [ ! -f "$report_file" ]; then
		failed=1
	elif ! grep -q "workflow-cascade-lint" "$report_file"; then
		failed=1
	elif ! grep -q "cascade-vulnerable" "$report_file"; then
		failed=1
	fi
	print_result "markdown report generation" "$failed" "exit=$rc report_exists=$([ -f "$report_file" ] && echo yes || echo no)"
	return 0
}

test_real_nmr_hold_workflow() {
	local nmr_file=".github/workflows/nmr-hold-comment.yml"
	if [ ! -f "$nmr_file" ]; then
		print_result "real: nmr-hold-comment.yml avoids cancellation cascade" 1 "file not found"
		return 0
	fi
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "$nmr_file" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 0 ]]; then
		failed=1
	fi
	if echo "$output" | grep -q "VULN"; then
		failed=1
	fi
	print_result "real: nmr-hold-comment.yml avoids cancellation cascade" "$failed" "exit=$rc"
	return 0
}

test_real_qlty_regression_mitigated() {
	local qlty_file=".github/workflows/qlty-regression.yml"
	if [ ! -f "$qlty_file" ]; then
		print_result "real: qlty-regression.yml NOT flagged (cancel disabled)" 1 "file not found"
		return 0
	fi
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "$qlty_file" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 0 ]]; then
		failed=1
	fi
	print_result "real: qlty-regression.yml NOT flagged (cancel disabled)" "$failed" "exit=$rc output=$output"
	return 0
}

test_real_qlty_new_file_gate_mitigated() {
	local gate_file=".github/workflows/qlty-new-file-gate.yml"
	if [ ! -f "$gate_file" ]; then
		print_result "real: qlty-new-file-gate.yml NOT flagged (cancel disabled)" 1 "file not found"
		return 0
	fi
	local output rc
	output=$(bash "$SCRIPT_UNDER_TEST" "$gate_file" 2>&1)
	rc=$?
	local failed=0
	if [[ $rc -ne 0 ]]; then
		failed=1
	fi
	print_result "real: qlty-new-file-gate.yml NOT flagged (cancel disabled)" "$failed" "exit=$rc output=$output"
	return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
	printf '=== test-workflow-cascade-lint.sh ===\n\n'

	if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
		printf '%bFAIL%b Script under test not found: %s\n' "$TEST_RED" "$TEST_RESET" "$SCRIPT_UNDER_TEST"
		exit 1
	fi

	setup_test_env

	# Fixture-based tests
	test_vulnerable_issue_workflow
	test_vulnerable_pr_workflow
	test_vulnerable_multiline_types
	test_paths_ignore_still_vulnerable
	test_action_guard_still_vulnerable
	test_step_guard_still_vulnerable
	test_safe_no_labeled_trigger
	test_safe_no_cancel_in_progress
	test_dry_run_exits_zero
	test_output_md_report

	# Real workflow tests (acceptance criteria)
	test_real_nmr_hold_workflow
	test_real_qlty_regression_mitigated
	test_real_qlty_new_file_gate_mitigated

	teardown_test_env

	printf '\n--- Results: %d/%d passed ---\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	if [[ $TESTS_FAILED -gt 0 ]]; then
		printf '%b%d test(s) FAILED%b\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_RESET"
		exit 1
	fi
	printf '%bAll tests passed%b\n' "$TEST_GREEN" "$TEST_RESET"
	exit 0
}

main "$@"
