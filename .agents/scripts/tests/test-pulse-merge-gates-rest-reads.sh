#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for operation-owned REST comment/file reads in PR gates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
GATES_SCRIPT="${SCRIPT_DIR}/../pulse-merge-gates.sh"

TEST_ROOT=""
GH_CALL_LOG=""
TESTS_RUN=0
TESTS_FAILED=0

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export HOME="${TEST_ROOT}/home"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	mkdir -p "${HOME}/.aidevops/logs"
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

print_result() {
	local description="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s%s\n' "$description" "${detail:+: ${detail}}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

gh() {
	local args="$*"
	printf '%s|%s\n' "${AIDEVOPS_GH_ROUTE_DECISION:-}" "$args" >>"$GH_CALL_LOG"
	case "$args" in
	"api --paginate repos/owner/repo/issues/123/comments?per_page=100 --jq .[].body")
		printf 'first comment\nsecond comment\n'
		return 0
		;;
	"api --paginate repos/owner/repo/pulls/123/files?per_page=100 --jq .[].filename")
		printf 'README.md\n.github/workflows/ci.yml\n'
		return 0
		;;
	esac
	return 1
}

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		print_result "$description" 0
		return 0
	fi
	print_result "$description" 1 "expected=${expected}; actual=${actual}"
	return 0
}

assert_call() {
	local description="$1"
	local expected="$2"
	if grep -Fqx "$expected" "$GH_CALL_LOG"; then
		print_result "$description" 0
		return 0
	fi
	print_result "$description" 1 "calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	# shellcheck source=../pulse-merge-gates.sh
	source "$GATES_SCRIPT"

	local comments=""
	comments=$(_pulse_merge_pr_comment_bodies_rest "123" "owner/repo")
	assert_eq "PR comment bodies are projected from REST" \
		$'first comment\nsecond comment' "$comments"
	assert_call "PR comment reads carry their REST route decision" \
		"pulse-pr-comments-rest|api --paginate repos/owner/repo/issues/123/comments?per_page=100 --jq .[].body"

	local files=""
	files=$(_pulse_merge_pr_file_paths_rest "123" "owner/repo")
	assert_eq "PR file paths are projected from REST" \
		$'README.md\n.github/workflows/ci.yml' "$files"
	assert_call "PR file reads carry their REST route decision" \
		"pulse-pr-files-rest|api --paginate repos/owner/repo/pulls/123/files?per_page=100 --jq .[].filename"

	if grep -Eq '^[[:space:]]*[^#[:space:]].*gh pr view.*--json (comments|files)([,[:space:]]|$)' "$GATES_SCRIPT"; then
		print_result "PR gate comments/files avoid native GraphQL views" 1
	else
		print_result "PR gate comments/files avoid native GraphQL views" 0
	fi

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
