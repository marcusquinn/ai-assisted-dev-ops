#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for TODO.md completion validators (GH#29243).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK_PATH="${SCRIPT_DIR}/../pre-commit-hook.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=$(mktemp -d)
CASE_REPO=""
VALIDATOR_OUTPUT=""
VALIDATOR_RC=0

trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace"

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s: %s\n' "$name" "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

init_repo() {
	local name="$1"
	local todo_content="$2"
	CASE_REPO="${TEST_ROOT}/${name}"
	mkdir -p "$CASE_REPO"
	(
		cd "$CASE_REPO" || exit 1
		git init -q
		git config user.email 'test@aidevops.local'
		git config user.name 'Test Runner'
		git config commit.gpgsign false
		printf 'fixture\n' >README.md
		printf '%s\n' "$todo_content" >TODO.md
		git add README.md TODO.md
		git commit -q -m 'seed fixture'
	)
	return 0
}

run_validator() {
	local validator="$1"
	local staged_content="$2"
	printf '%s\n' "$staged_content" >"${CASE_REPO}/TODO.md"
	git -C "$CASE_REPO" add TODO.md

	VALIDATOR_OUTPUT=$(
		cd "$CASE_REPO" || exit 1
		# shellcheck source=/dev/null
		source "${SCRIPT_DIR}/../shared-constants.sh" >/dev/null 2>&1
		# Source the hook without its trailing main invocation. Pre-sourcing
		# shared constants keeps the validator functions available even though
		# SCRIPT_DIR resolves against the process-substitution descriptor.
		# shellcheck source=/dev/null
		source <(sed '/^main "\$@"$/d' "$HOOK_PATH") >/dev/null 2>&1
		set +e
		"$validator" 2>&1
		local validator_rc=$?
		printf '\n__VALIDATOR_RC__=%s\n' "$validator_rc"
	)
	VALIDATOR_RC=$(printf '%s\n' "$VALIDATOR_OUTPUT" | sed -n 's/^__VALIDATOR_RC__=//p')
	return 0
}

test_staged_todo_deletion() {
	init_repo "todo-deletion" '- [ ] t100 Keep this task open'
	rm "${CASE_REPO}/TODO.md"
	git -C "$CASE_REPO" add -u -- TODO.md

	local output
	local rc=0
	output=$(cd "$CASE_REPO" && HOOK_MODE=pre-commit bash "$HOOK_PATH" 2>&1) || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_result "staged TODO.md deletion passes" 1 "hook exited ${rc}: ${output}"
		return 0
	fi
	if printf '%s\n' "$output" | grep -Eq 'fatal:|ambiguous argument|unknown revision or path'; then
		print_result "staged TODO.md deletion has no Git path diagnostic" 1 "$output"
		return 0
	fi
	print_result "staged TODO.md deletion has no Git path diagnostic" 0
	return 0
}

test_completion_without_evidence() {
	init_repo "completion-no-evidence" '- [ ] t101 Complete this task'
	run_validator validate_todo_completions '- [x] t101 Complete this task'
	if [[ "$VALIDATOR_RC" -eq 1 ]]; then
		print_result "completion without evidence fails" 0
	else
		print_result "completion without evidence fails" 1 "expected rc=1, got ${VALIDATOR_RC}: ${VALIDATOR_OUTPUT}"
	fi
	return 0
}

test_completion_with_evidence() {
	init_repo "completion-with-evidence" '- [ ] t102 Complete this task'
	run_validator validate_todo_completions '- [x] t102 Complete this task verified:2026-08-02'
	if [[ "$VALIDATOR_RC" -eq 0 ]]; then
		print_result "completion with evidence passes" 0
	else
		print_result "completion with evidence passes" 1 "expected rc=0, got ${VALIDATOR_RC}: ${VALIDATOR_OUTPUT}"
	fi
	return 0
}

test_parent_with_open_subtask() {
	init_repo "parent-open-subtask" $'- [ ] t103 Parent task\n  - [ ] t103.1 Open subtask'
	run_validator validate_parent_subtask_blocking $'- [x] t103 Parent task verified:2026-08-02\n  - [ ] t103.1 Open subtask'
	if [[ "$VALIDATOR_RC" -eq 1 ]]; then
		print_result "parent completion with open subtask fails" 0
	else
		print_result "parent completion with open subtask fails" 1 "expected rc=1, got ${VALIDATOR_RC}: ${VALIDATOR_OUTPUT}"
	fi
	return 0
}

test_staged_todo_deletion
test_completion_without_evidence
test_completion_with_evidence
test_parent_with_open_subtask

printf '\nTests: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
