#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#30435: workers must repair a missing generated PR
# body before the in-review transition, while refusing ambiguous references.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COMMIT_HELPER="${SCRIPT_DIR}/../full-loop-helper-commit.sh"
TEST_ROOT="$(mktemp -d -t gh30435.XXXXXX)" || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

TESTS_RUN=0
TESTS_FAILED=0
REMOTE_BODY=""
EDIT_CALLS=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail" >&2
	return 0
}

print_error() { return 0; }
print_success() { return 0; }

_gh_with_timeout() {
	local operation="$1"
	shift || return 1
	"$@"
	return $?
}

gh() {
	if [[ "${1:-}" == "api" ]]; then
		printf '%s\n' "$REMOTE_BODY"
		return 0
	fi
	return 1
}

gh_pr_edit_safe() {
	local pr_number="$1"
	local body_file=""
	shift || return 1
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body-file)
			body_file="${2:-}"
			shift 2 || return 1
			;;
		*) shift ;;
		esac
	done
	[[ "$pr_number" == "77" && -r "$body_file" ]] || return 1
	REMOTE_BODY=$(<"$body_file")
	EDIT_CALLS=$((EDIT_CALLS + 1))
	return 0
}

eval "$(sed -n '/^_ensure_worker_pr_linkage() {/,/^}/p' "$COMMIT_HELPER")"

test_empty_body_is_repaired() {
	REMOTE_BODY=""
	EDIT_CALLS=0
	if _ensure_worker_pr_linkage 77 owner/repo 42 $'## Summary\n\nImplementation\n\nResolves #42' &&
		[[ "$REMOTE_BODY" == *"Resolves #42"* && "$EDIT_CALLS" -eq 1 ]]; then
		pass "empty worker PR body is repaired with generated closing reference"
	else
		fail "empty worker PR body is repaired with generated closing reference" "edits=${EDIT_CALLS}; body=${REMOTE_BODY}"
	fi
	return 0
}

test_nonclosing_body_is_preserved_and_repaired() {
	REMOTE_BODY="## Summary\n\nWorker context survived"
	EDIT_CALLS=0
	if _ensure_worker_pr_linkage 77 owner/repo 42 'unused generated body' &&
		[[ "$REMOTE_BODY" == *"Worker context survived"* && "$REMOTE_BODY" == *"Resolves #42"* && "$EDIT_CALLS" -eq 1 ]]; then
		pass "nonclosing worker body is preserved while adding local linkage"
	else
		fail "nonclosing worker body is preserved while adding local linkage" "edits=${EDIT_CALLS}; body=${REMOTE_BODY}"
	fi
	return 0
}

test_existing_local_reference_is_accepted() {
	REMOTE_BODY="## Summary\n\nResolves #42"
	EDIT_CALLS=0
	if _ensure_worker_pr_linkage 77 owner/repo 42 'unused generated body' && [[ "$EDIT_CALLS" -eq 0 ]]; then
		pass "existing same-repository closing reference needs no repair"
	else
		fail "existing same-repository closing reference needs no repair" "edits=${EDIT_CALLS}"
	fi
	return 0
}

test_ambiguous_reference_fails_closed() {
	REMOTE_BODY="Resolves #42 and closes #99"
	EDIT_CALLS=0
	local rc=0
	_ensure_worker_pr_linkage 77 owner/repo 42 'unused generated body' || rc=$?
	if [[ "$rc" -ne 0 && "$EDIT_CALLS" -eq 0 ]]; then
		pass "multiple closing references fail closed without overwriting body"
	else
		fail "multiple closing references fail closed without overwriting body" "rc=${rc}; edits=${EDIT_CALLS}"
	fi
	return 0
}

test_empty_body_is_repaired
test_nonclosing_body_is_preserved_and_repaired
test_existing_local_reference_is_accepted
test_ambiguous_reference_fails_closed

if [[ "$TESTS_FAILED" -ne 0 ]]; then
	printf '%s/%s worker PR linkage tests failed\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
	exit 1
fi
printf 'All %s worker PR linkage tests passed\n' "$TESTS_RUN"
