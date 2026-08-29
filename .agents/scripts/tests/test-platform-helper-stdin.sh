#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
HOME="${TEST_ROOT}/home"
mkdir -p "$HOME"

# shellcheck source=../platform-helper.sh
source "${SCRIPTS_DIR}/platform-helper.sh"

PASS_COUNT=0
FAIL_COUNT=0
GH_CALLS_FILE="${TEST_ROOT}/gh-calls"
GH_BODY_FILE="${TEST_ROOT}/gh-body"
printf '0\n' >"$GH_CALLS_FILE"

pass() {
	local message="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf 'FAIL: %s\n' "$message" >&2
	return 0
}

assert_success() {
	local message="$1"
	shift
	if "$@"; then
		pass "$message"
	else
		fail "$message"
	fi
	return 0
}

assert_failure() {
	local message="$1"
	shift
	if "$@"; then
		fail "$message"
	else
		pass "$message"
	fi
	return 0
}

platform_detect() {
	printf '%s\n' "${TEST_PLATFORM:-github}"
	return 0
}

gh() {
	local call_count=0
	local arg=""
	local previous=""
	local stdin_body=""
	call_count=$(<"$GH_CALLS_FILE")
	call_count=$((call_count + 1))
	printf '%s\n' "$call_count" >"$GH_CALLS_FILE"
	printf '%s\n' "$*" >"${TEST_ROOT}/gh-args-${call_count}"
	for arg in "$@"; do
		if [[ "$previous" == "--body-file" && "$arg" == "-" ]]; then
			command cat >"$GH_BODY_FILE"
			stdin_body=$(<"$GH_BODY_FILE")
			if [[ -z "$stdin_body" || "$stdin_body" == "<!-- aidevops:sig -->" ]]; then
				return 1
			fi
		fi
		previous="$arg"
	done
	return 0
}

run_stdin_create_issue() {
	printf '%s' 'issue body line one
issue body line two' | platform_create_issue owner/repo "Issue title" - bug
	return $?
}

run_stdin_comment_issue() {
	printf '%s' 'comment body' | platform_comment_issue owner/repo 123 -
	return $?
}

run_stdin_create_pr() {
	printf '%s' 'pull request body' | platform_create_pr owner/repo "PR title" - main feature
	return $?
}

run_empty_stdin_comment() {
	printf '' | platform_comment_issue owner/repo 123 -
	return $?
}

run_signature_only_stdin_comment() {
	printf '%s\n' '<!-- aidevops:sig -->' | platform_comment_issue owner/repo 123 -
	return $?
}

run_local_stdin_comment() {
	printf '%s' "$LOCAL_SENTINEL" | platform_comment_issue owner/repo 123 -
	return $?
}

assert_success "create-issue accepts exact stdin sentinel" run_stdin_create_issue
[[ "$(<"$GH_BODY_FILE")" == $'issue body line one\nissue body line two' ]] &&
	pass "create-issue forwards multiline stdin once" ||
	fail "create-issue did not forward multiline stdin"
[[ "$(<"${TEST_ROOT}/gh-args-1")" == *"--body-file -"* ]] &&
	pass "create-issue forwards literal body sentinel" ||
	fail "create-issue changed the body sentinel"

assert_success "comment-issue accepts exact stdin sentinel" run_stdin_comment_issue
[[ "$(<"$GH_BODY_FILE")" == "comment body" ]] &&
	pass "comment-issue forwards stdin once" ||
	fail "comment-issue did not forward stdin"

assert_success "create-pr accepts exact stdin sentinel" run_stdin_create_pr
[[ "$(<"$GH_BODY_FILE")" == "pull request body" ]] &&
	pass "create-pr forwards stdin once" ||
	fail "create-pr did not forward stdin"

REGULAR_BODY="${TEST_ROOT}/regular-body.md"
printf '%s\n' 'regular body' >"$REGULAR_BODY"
assert_success "regular body files remain supported" \
	platform_create_issue owner/repo "Regular title" "$REGULAR_BODY" ""
[[ "$(<"${TEST_ROOT}/gh-args-4")" == *"--body-file ${REGULAR_BODY}"* ]] &&
	pass "regular body path is forwarded unchanged" ||
	fail "regular body path changed"

calls_before=$(<"$GH_CALLS_FILE")
assert_failure "missing non-stdin body path remains rejected" \
	platform_comment_issue owner/repo 123 "${TEST_ROOT}/missing-body.md"
[[ "$(<"$GH_CALLS_FILE")" == "$calls_before" ]] &&
	pass "missing body path fails before GitHub transport" ||
	fail "missing body path reached GitHub transport"

assert_failure "empty stdin rejection from managed transport is preserved" run_empty_stdin_comment
assert_failure "signature-only stdin rejection from managed transport is preserved" \
	run_signature_only_stdin_comment

TEST_PLATFORM=local
LOCAL_SENTINEL='private local body that must not be logged'
assert_success "local platform consumes and discards stdin body" \
	run_local_stdin_comment
if [[ -f "$PLATFORM_LOCAL_LOG" ]] && ! grep -Fq "$LOCAL_SENTINEL" "$PLATFORM_LOCAL_LOG"; then
	pass "local platform log excludes discarded body content"
else
	fail "local platform persisted discarded body content"
fi

printf '\nTests: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
