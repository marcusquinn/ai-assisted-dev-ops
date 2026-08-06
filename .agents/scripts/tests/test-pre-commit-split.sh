#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pre-commit-split.sh — t2207 regression test.
#
# Validates the pre-commit/pre-push hook split:
#   1. HOOK_MODE=pre-commit runs only fast local checks (no secretlint/SonarCloud).
#   2. HOOK_MODE=pre-push runs only slow network checks (secretlint/SonarCloud/CodeRabbit).
#   3. HOOK_MODE=all runs both paths sequentially.
#   4. Default mode (no env var) falls back to pre-commit.
#   5. Unknown HOOK_MODE returns error.
#   6. install-hooks-helper.sh has the pre-push quality hook function.
#   7. Pre-commit dispatcher sets HOOK_MODE=pre-commit.
#   8. Pre-push dispatcher sets HOOK_MODE=pre-push.
#
# These tests validate the dispatcher logic and function existence without
# running actual git operations or network calls.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# --- Test 1: main_pre_commit function exists ---
test_main_pre_commit_exists() {
	if grep -q '^main_pre_commit()' "$TEST_SCRIPTS_DIR/pre-commit-hook.sh"; then
		print_result "main_pre_commit() function exists" 0
	else
		print_result "main_pre_commit() function exists" 1 "not found in pre-commit-hook.sh"
	fi
	return 0
}

# --- Test 2: main_pre_push function exists ---
test_main_pre_push_exists() {
	if grep -q '^main_pre_push()' "$TEST_SCRIPTS_DIR/pre-commit-hook.sh"; then
		print_result "main_pre_push() function exists" 0
	else
		print_result "main_pre_push() function exists" 1 "not found in pre-commit-hook.sh"
	fi
	return 0
}

# --- Test 3: main() dispatcher exists and handles modes ---
test_dispatcher_exists() {
	local hook_file="$TEST_SCRIPTS_DIR/pre-commit-hook.sh"
	local rc=0

	# Check dispatcher references all modes
	if ! grep -q 'HOOK_MODE' "$hook_file"; then
		print_result "dispatcher uses HOOK_MODE" 1 "HOOK_MODE not found"
		return 0
	fi

	if ! grep -q 'pre-commit) main_pre_commit' "$hook_file"; then
		print_result "dispatcher routes pre-commit mode" 1
		rc=1
	fi

	if ! grep -q 'pre-push) main_pre_push' "$hook_file"; then
		print_result "dispatcher routes pre-push mode" 1
		rc=1
	fi

	if ! grep -q 'all) main_pre_commit.*main_pre_push' "$hook_file"; then
		print_result "dispatcher routes all mode" 1
		rc=1
	fi

	if [[ "$rc" -eq 0 ]]; then
		print_result "dispatcher handles all modes (pre-commit, pre-push, all)" 0
	fi
	return 0
}

# --- Test 4: pre-commit path does NOT call slow checks ---
test_pre_commit_no_slow_checks() {
	local hook_file="$TEST_SCRIPTS_DIR/pre-commit-hook.sh"

	# Extract main_pre_commit body (from function start to closing brace)
	local body
	body=$(sed -n '/^main_pre_commit()/,/^}/p' "$hook_file")

	local rc=0
	if echo "$body" | grep -q 'check_secrets'; then
		print_result "pre-commit path excludes check_secrets" 1 "check_secrets found in main_pre_commit"
		rc=1
	fi
	if echo "$body" | grep -q 'check_quality_standards'; then
		print_result "pre-commit path excludes check_quality_standards" 1 "check_quality_standards found in main_pre_commit"
		rc=1
	fi
	if echo "$body" | grep -q 'coderabbit'; then
		print_result "pre-commit path excludes CodeRabbit" 1 "coderabbit found in main_pre_commit"
		rc=1
	fi

	if [[ "$rc" -eq 0 ]]; then
		print_result "pre-commit path excludes all slow checks (secretlint, SonarCloud, CodeRabbit)" 0
	fi
	return 0
}

# --- Test 5: pre-push path calls slow checks ---
test_pre_push_has_slow_checks() {
	local hook_file="$TEST_SCRIPTS_DIR/pre-commit-hook.sh"

	# Extract main_pre_push body
	local body
	body=$(sed -n '/^main_pre_push()/,/^}/p' "$hook_file")

	local rc=0
	if ! echo "$body" | grep -q 'check_secrets'; then
		print_result "pre-push path includes check_secrets" 1
		rc=1
	fi
	if ! echo "$body" | grep -q 'check_quality_standards'; then
		print_result "pre-push path includes check_quality_standards" 1
		rc=1
	fi

	if [[ "$rc" -eq 0 ]]; then
		print_result "pre-push path includes slow checks (secretlint, SonarCloud)" 0
	fi
	return 0
}

# --- Test 6: pre-commit path has fast checks ---
test_pre_commit_has_fast_checks() {
	local hook_file="$TEST_SCRIPTS_DIR/pre-commit-hook.sh"

	local body
	body=$(sed -n '/^main_pre_commit()/,/^}/p' "$hook_file")

	local rc=0
	if ! echo "$body" | grep -q 'validate_duplicate_task_ids'; then
		print_result "pre-commit has validate_duplicate_task_ids" 1
		rc=1
	fi
	if ! echo "$body" | grep -q 'validate_repo_root_files'; then
		print_result "pre-commit has validate_repo_root_files" 1
		rc=1
	fi
	if ! echo "$body" | grep -q 'run_shellcheck'; then
		print_result "pre-commit has run_shellcheck" 1
		rc=1
	fi
	if ! echo "$body" | grep -q 'validate_return_statements'; then
		print_result "pre-commit has validate_return_statements" 1
		rc=1
	fi

	if [[ "$rc" -eq 0 ]]; then
		print_result "pre-commit path includes all fast checks (TODO, root files, shellcheck, lint)" 0
	fi
	return 0
}

# --- Test 7: install-hooks-helper.sh has install_pre_push_quality_hook ---
test_installer_has_pre_push_function() {
	local installer="$TEST_SCRIPTS_DIR/install-hooks-helper.sh"
	if grep -q '^install_pre_push_quality_hook()' "$installer"; then
		print_result "install_pre_push_quality_hook() exists in installer" 0
	else
		print_result "install_pre_push_quality_hook() exists in installer" 1
	fi
	return 0
}

# --- Test 8: installer calls install_pre_push_quality_hook from install_hook ---
test_installer_calls_pre_push() {
	local installer="$TEST_SCRIPTS_DIR/install-hooks-helper.sh"
	# Count occurrences: function definition + at least one call site = 2+
	local count
	count=$(grep -c 'install_pre_push_quality_hook' "$installer")
	if [[ "$count" -ge 2 ]]; then
		print_result "install_hook() calls install_pre_push_quality_hook" 0
	else
		print_result "install_hook() calls install_pre_push_quality_hook" 1 "only $count occurrence(s) found, need definition + call"
	fi
	return 0
}

# --- Test 9: pre-push quality hook marker exists ---
test_pre_push_marker() {
	local installer="$TEST_SCRIPTS_DIR/install-hooks-helper.sh"
	if grep -q 'PRE_PUSH_QUALITY_MARKER' "$installer"; then
		print_result "PRE_PUSH_QUALITY_MARKER defined in installer" 0
	else
		print_result "PRE_PUSH_QUALITY_MARKER defined in installer" 1
	fi
	return 0
}

# --- Test 10: check_status reports pre-push quality hook ---
test_status_reports_pre_push() {
	local installer="$TEST_SCRIPTS_DIR/install-hooks-helper.sh"
	if grep -q 'pre-push-quality-hook' "$installer"; then
		print_result "check_status reports pre-push-quality-hook" 0
	else
		print_result "check_status reports pre-push-quality-hook" 1
	fi
	return 0
}

# --- Test 11: pre-commit dispatcher sets HOOK_MODE=pre-commit ---
test_pre_commit_dispatcher_sets_mode() {
	local installer="$TEST_SCRIPTS_DIR/install-hooks-helper.sh"
	if grep -q 'HOOK_MODE=pre-commit' "$installer"; then
		print_result "pre-commit dispatcher sets HOOK_MODE=pre-commit" 0
	else
		print_result "pre-commit dispatcher sets HOOK_MODE=pre-commit" 1
	fi
	return 0
}

# --- Test 12: pre-push dispatcher sets HOOK_MODE=pre-push ---
test_pre_push_dispatcher_sets_mode() {
	local installer="$TEST_SCRIPTS_DIR/install-hooks-helper.sh"
	if grep -q 'HOOK_MODE=pre-push' "$installer"; then
		print_result "pre-push dispatcher sets HOOK_MODE=pre-push" 0
	else
		print_result "pre-push dispatcher sets HOOK_MODE=pre-push" 1
	fi
	return 0
}

# --- Test 13: ESLint flat config root files are allowlisted ---
test_eslint_flat_config_root_allowlist() {
	local hook_file="$TEST_SCRIPTS_DIR/pre-commit-hook.sh"
	local rc=0
	local config_file

	for config_file in \
		"eslint.config.js" \
		"eslint.config.mjs" \
		"eslint.config.cjs" \
		"eslint.config.ts" \
		"eslint.config.mts" \
		"eslint.config.cts"; do
		if ! grep -q "\"${config_file}\"" "$hook_file"; then
			print_result "root allowlist permits ${config_file}" 1
			rc=1
		fi
	done

	if [[ "$rc" -eq 0 ]]; then
		print_result "root allowlist permits ESLint flat config variants" 0
	fi
	return 0
}

# --- Test 14: npm lockfiles pass staged root validation ---
test_npm_lockfile_root_validation() {
	local fixture_dir
	fixture_dir=$(mktemp -d)
	local hook_dir="${fixture_dir}/.agents/scripts"
	local hook_output=""
	local hook_rc=0

	mkdir -p "$hook_dir"
	cp "$TEST_SCRIPTS_DIR/pre-commit-hook.sh" "$hook_dir/pre-commit-hook.sh"
	cp "$TEST_SCRIPTS_DIR/shared-constants.sh" "$hook_dir/shared-constants.sh"
	git -C "$fixture_dir" init --quiet
	printf '%s\n' '{"name":"root-allowlist-fixture"}' >"${fixture_dir}/package.json"
	printf '%s\n' '{"name":"root-allowlist-fixture","lockfileVersion":3,"packages":{}}' >"${fixture_dir}/package-lock.json"
	git -C "$fixture_dir" add package.json package-lock.json

	hook_output=$(cd "$fixture_dir" && HOOK_MODE=pre-commit bash "$hook_dir/pre-commit-hook.sh" 2>&1) || hook_rc=$?
	if [[ "$hook_rc" -eq 0 ]]; then
		print_result "root validation permits package.json with package-lock.json" 0
	else
		print_result "root validation permits package.json with package-lock.json" 1 "$hook_output"
	fi

	printf '%s\n' 'fixture artifact' >"${fixture_dir}/VERIFY-ROOT-ARTIFACT.md"
	git -C "$fixture_dir" add VERIFY-ROOT-ARTIFACT.md
	hook_rc=0
	hook_output=$(cd "$fixture_dir" && HOOK_MODE=pre-commit bash "$hook_dir/pre-commit-hook.sh" 2>&1) || hook_rc=$?
	if [[ "$hook_rc" -ne 0 && "$hook_output" == *"VERIFY-ROOT-ARTIFACT.md"* ]]; then
		print_result "root validation still rejects arbitrary verification artifacts" 0
	else
		print_result "root validation still rejects arbitrary verification artifacts" 1 "$hook_output"
	fi

	rm -rf "$fixture_dir"
	return 0
}

# --- Test 15: arbitrary root artifacts remain absent from the allowlist ---
test_arbitrary_root_artifact_not_allowlisted() {
	local hook_file="$TEST_SCRIPTS_DIR/pre-commit-hook.sh"
	local artifact_file="VERIFY-ROOT-ARTIFACT.md"

	if grep -q "\"${artifact_file}\"" "$hook_file"; then
		print_result "root allowlist rejects arbitrary verification artifacts" 1
	else
		print_result "root allowlist rejects arbitrary verification artifacts" 0
	fi
	return 0
}

# --- Run all tests ---
echo "=== t2207: pre-commit/pre-push split regression test ==="
echo ""

test_main_pre_commit_exists
test_main_pre_push_exists
test_dispatcher_exists
test_pre_commit_no_slow_checks
test_pre_push_has_slow_checks
test_pre_commit_has_fast_checks
test_installer_has_pre_push_function
test_installer_calls_pre_push
test_pre_push_marker
test_status_reports_pre_push
test_pre_commit_dispatcher_sets_mode
test_pre_push_dispatcher_sets_mode
test_eslint_flat_config_root_allowlist
test_npm_lockfile_root_validation
test_arbitrary_root_artifact_not_allowlisted

echo ""
echo "=== Results: $TESTS_RUN tests, $TESTS_FAILED failed ==="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
