#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for the final recurring native PR file/comment reads.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
ANCILLARY_SCRIPT="${TEST_SCRIPT_DIR}/../pulse-ancillary-dispatch.sh"
DIRTY_SWEEP_SCRIPT="${TEST_SCRIPT_DIR}/../pulse-dirty-pr-sweep.sh"

TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
GH_CALL_LOG=""
TESTS_RUN=0
TESTS_FAILED=0

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.config/aidevops"
	printf '%s\n' '{"initialized_repos":[]}' >"${HOME}/.config/aidevops/repos.json"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
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
	"api -H Accept: application/vnd.github.v3.diff repos/owner/repo/compare/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
		printf '%s\n' 'diff --git a/README.md b/README.md'
		return 0
		;;
	"api repos/owner/repo/compare/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --jq if ((.files | type) == \"array\" and (.files | length) < 300) then [.files[].filename] else error(\"incomplete compare files\") end")
		printf '%s\n' '["README.md",".github/workflows/ci.yml"]'
		return 0
		;;
	"api --paginate repos/owner/repo/issues/123/comments?per_page=100 --jq .[].body")
		printf 'first comment\nsecond comment\n'
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

assert_source_contains() {
	local description="$1"
	local source_file="$2"
	local expected="$3"
	if grep -Fq "$expected" "$source_file"; then
		print_result "$description" 0
		return 0
	fi
	print_result "$description" 1 "missing=${expected}"
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	unset SCRIPT_DIR || true
	# shellcheck source=../pulse-ancillary-dispatch.sh
	source "$ANCILLARY_SCRIPT"
	# shellcheck source=../pulse-dirty-pr-sweep.sh
	source "$DIRTY_SWEEP_SCRIPT"

	local base_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	local head_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	local diff=""
	diff=$(_triage_pr_diff_for_revision_rest "owner/repo" "$base_sha" "$head_sha")
	assert_eq "triage PR diff preserves its bounded text contract" \
		'diff --git a/README.md b/README.md' "$diff"
	assert_call "triage PR diff uses the immutable compare REST endpoint" \
		"pulse-triage-pr-diff-rest|api -H Accept: application/vnd.github.v3.diff repos/owner/repo/compare/${base_sha}...${head_sha}"

	local files=""
	files=$(_triage_pr_file_paths_json_rest "owner/repo" "$base_sha" "$head_sha")
	assert_eq "triage PR file paths preserve their JSON-array contract" \
		'["README.md",".github/workflows/ci.yml"]' "$files"
	assert_call "triage PR files use the immutable compare REST endpoint" \
		"pulse-triage-pr-files-rest|api repos/owner/repo/compare/${base_sha}...${head_sha} --jq if ((.files | type) == \"array\" and (.files | length) < 300) then [.files[].filename] else error(\"incomplete compare files\") end"

	local comments=""
	comments=$(_dps_pr_comment_bodies_rest "123" "owner/repo")
	assert_eq "dirty-PR marker checks project REST comment bodies" \
		$'first comment\nsecond comment' "$comments"
	assert_call "dirty-PR comment reads use bounded REST pages" \
		"pulse-dirty-pr-comments-rest|api --paginate repos/owner/repo/issues/123/comments?per_page=100 --jq .[].body"

	assert_source_contains "triage prompt binds REST file evidence to captured revisions" \
		"$ANCILLARY_SCRIPT" \
		"\"\$repo_slug\" \"\$_ps_base_sha\" \"\$_ps_head_sha\""
	assert_source_contains "dirty-PR idempotency calls the exact REST comment helper" \
		"$DIRTY_SWEEP_SCRIPT" \
		"existing=\$(_dps_pr_comment_bodies_rest \"\$pr_number\" \"\$repo_slug\""

	if grep -Eq '^[[:space:]]*[^#[:space:]].*gh pr view.*--json files' "$ANCILLARY_SCRIPT"; then
		print_result "ancillary dispatch avoids native GraphQL PR-file views" 1
	else
		print_result "ancillary dispatch avoids native GraphQL PR-file views" 0
	fi
	if grep -Eq '^[[:space:]]*[^#[:space:]].*gh pr diff' "$ANCILLARY_SCRIPT"; then
		print_result "triage evidence avoids mutable native PR diff reads" 1
	else
		print_result "triage evidence avoids mutable native PR diff reads" 0
	fi
	if grep -Eq '^[[:space:]]*[^#[:space:]].*gh pr view.*--json comments' "$DIRTY_SWEEP_SCRIPT"; then
		print_result "dirty-PR sweep avoids native GraphQL comment views" 1
	else
		print_result "dirty-PR sweep avoids native GraphQL comment views" 0
	fi

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
