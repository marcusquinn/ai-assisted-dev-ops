#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pre-push-dup-todo-guard.sh — Unit tests for pre-push-dup-todo-guard.sh (t2745).
#
# Tests 12 fixtures:
#   1. Clean TODO.md (no duplicates)               → exit 0
#   2. Single duplicate (t2743 twice)              → exit 1, cites lines
#   3. Multiple duplicates (t2743 AND t2742)       → exit 1, cites both IDs
#   4. Completed + open pair (- [x] + - [ ] same) → exit 1
#   5. Pseudo-duplicate (task ID in description)   → exit 0
#   6. DUP_TODO_GUARD_DISABLE=1                    → exit 0, warning to stderr
#   7. --no-verify bypass documentation            → informational (git-level bypass)
#   8. Hierarchical ID duplicate (t1271.1 twice)   → exit 1, cites lines
#   9. Indented subtask duplicate                  → exit 1, cites lines
#  10. Unchanged pre-existing duplicate            → exit 0
#  11. Increased pre-existing duplicate count      → exit 1
#  12. Duplicate issue mapping on distinct tasks    → exit 1
#
# Usage: bash .agents/scripts/tests/test-pre-push-dup-todo-guard.sh
# Exit 0 = all tests passed. Exit 1 = one or more tests failed.

set -u

# ---------------------------------------------------------------------------
# Locate the hook under test (resolve relative to this script's directory).
# ---------------------------------------------------------------------------
_script_dir() {
	local _src="${BASH_SOURCE[0]}"
	while [[ -L "$_src" ]]; do
		local _dir
		_dir=$(cd -P "$(dirname "$_src")" && pwd)
		_src=$(readlink "$_src")
		[[ "$_src" != /* ]] && _src="${_dir}/${_src}"
	done
	cd -P "$(dirname "$_src")" && pwd
	return 0
}

TESTS_DIR=$(_script_dir)
REPO_ROOT=$(cd "${TESTS_DIR}/../../.." && pwd)
HOOK="${REPO_ROOT}/.agents/hooks/pre-push-dup-todo-guard.sh"

if [[ ! -f "$HOOK" ]]; then
	printf '[FATAL] Hook not found: %s\n' "$HOOK" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------
_TESTS_PASSED=0
_TESTS_FAILED=0
_TEST_TMPDIR=""
_BASE_SHA=""

_setup_git_repo() {
	_TEST_TMPDIR=$(mktemp -d)
	cd "$_TEST_TMPDIR" || return 1
	git init -q
	git config user.email "test@test.local"
	git config user.name "Test"
	# Disable commit signing for the test repo — global config may have
	# commit.gpgsign=true which requires a key passphrase that won't be
	# available in headless test runs.
	git config commit.gpgsign false
	git config tag.gpgsign false
	# Initial commit required before git show works
	touch TODO.md
	git add TODO.md
	git commit -q -m "init"
	_BASE_SHA=$(git rev-parse HEAD)
	return 0
}

_teardown_git_repo() {
	cd / 2>/dev/null || true
	[[ -n "${_TEST_TMPDIR:-}" && -d "$_TEST_TMPDIR" ]] && rm -rf "$_TEST_TMPDIR"
	_TEST_TMPDIR=""
	_BASE_SHA=""
	return 0
}

# Commit TODO.md with given content; prints the resulting SHA on stdout.
_commit_todo() {
	local _content="$1"
	printf '%s\n' "$_content" >"$_TEST_TMPDIR/TODO.md"
	git add TODO.md
	git commit -q -m "test commit"
	git rev-parse HEAD
	return 0
}

# Run the hook with a given SHA as the pushed commit.
# Synthesises git pre-push stdin: local_ref local_sha remote_ref remote_sha
# Returns the hook's exit code.
_run_hook() {
	local _sha="$1"
	local _extra_env="${2:-}"
	local _remote_sha="${3:-$_BASE_SHA}"
	local _stdin
	_stdin="refs/heads/test ${_sha} refs/heads/main ${_remote_sha}"
	if [[ -n "$_extra_env" ]]; then
		env "$_extra_env" bash "$HOOK" origin "https://github.com/test/repo" <<<"$_stdin"
	else
		bash "$HOOK" origin "https://github.com/test/repo" <<<"$_stdin"
	fi
	return $?
}

_commit_unrelated() {
	printf 'unrelated\n' >"$_TEST_TMPDIR/unrelated.txt"
	git add unrelated.txt
	git commit -q -m "unrelated change"
	git rev-parse HEAD
	return 0
}

_pass() {
	local _name="$1"
	printf '[PASS] %s\n' "$_name"
	_TESTS_PASSED=$((_TESTS_PASSED + 1))
	return 0
}

_fail() {
	local _name="$1"
	local _reason="$2"
	printf '[FAIL] %s: %s\n' "$_name" "$_reason" >&2
	_TESTS_FAILED=$((_TESTS_FAILED + 1))
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: Clean TODO.md (no duplicates) → exit 0
# ---------------------------------------------------------------------------
test_clean_no_duplicates() {
	local _name="test_1_clean_no_duplicates"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Ready
- [ ] t2740 Some task #auto-dispatch ref:GH#20470
- [ ] t2741 Another task #auto-dispatch ref:GH#20471
- [ ] t2742 Third task #auto-dispatch ref:GH#20472"

	local _sha
	_sha=$(_commit_todo "$_content")
	_run_hook "$_sha" 2>/dev/null
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -eq 0 ]]; then
		_pass "$_name"
	else
		_fail "$_name" "expected exit 0, got exit $_rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Single duplicate (t2743 appears twice) → exit 1, error cites lines
# ---------------------------------------------------------------------------
test_single_duplicate() {
	local _name="test_2_single_duplicate"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Ready
- [ ] t2743 Fix REST fallback in zsh context #auto-dispatch ref:GH#20480
- [ ] t2744 Unrelated task ref:GH#20481

## Backlog
- [ ] t2743 Fix shared-gh-wrappers REST fallback to work in zsh #auto-dispatch #framework ref:GH#20480"

	local _sha
	_sha=$(_commit_todo "$_content")
	local _stderr
	_stderr=$(_run_hook "$_sha" 2>&1 1>/dev/null)
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -ne 1 ]]; then
		_fail "$_name" "expected exit 1 (duplicate found), got exit $_rc"
		return 0
	fi
	if printf '%s\n' "$_stderr" | grep -q "t2743"; then
		_pass "$_name"
	else
		_fail "$_name" "error message did not mention 't2743'; stderr: $_stderr"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Multiple duplicates (t2743 AND t2742 both duplicated) → exit 1, cites both
# ---------------------------------------------------------------------------
test_multiple_duplicates() {
	local _name="test_3_multiple_duplicates"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Ready
- [ ] t2742 First task ref:GH#20478
- [ ] t2743 Second task ref:GH#20480

## Backlog
- [ ] t2742 First task seeded by issue-sync ref:GH#20478
- [ ] t2743 Second task seeded by issue-sync ref:GH#20480"

	local _sha
	_sha=$(_commit_todo "$_content")
	local _stderr
	_stderr=$(_run_hook "$_sha" 2>&1 1>/dev/null)
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -ne 1 ]]; then
		_fail "$_name" "expected exit 1 (duplicates found), got exit $_rc"
		return 0
	fi
	local _mentions_t2742 _mentions_t2743
	_mentions_t2742=$(printf '%s\n' "$_stderr" | grep -c "t2742" || true)
	_mentions_t2743=$(printf '%s\n' "$_stderr" | grep -c "t2743" || true)
	if [[ "$_mentions_t2742" -ge 1 && "$_mentions_t2743" -ge 1 ]]; then
		_pass "$_name"
	else
		_fail "$_name" "error message missing t2742 or t2743; stderr: $_stderr"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: Completed + open pair (- [x] t2743 + - [ ] t2743) → exit 1
# Must not silently allow mixed completed/open duplicates.
# ---------------------------------------------------------------------------
test_completed_and_open_pair() {
	local _name="test_4_completed_and_open_pair"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Done
- [x] t2743 Fix REST fallback pr:#20482 ref:GH#20480

## Backlog
- [ ] t2743 Fix shared-gh-wrappers REST fallback #auto-dispatch ref:GH#20480"

	local _sha
	_sha=$(_commit_todo "$_content")
	_run_hook "$_sha" 2>/dev/null
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -eq 1 ]]; then
		_pass "$_name"
	else
		_fail "$_name" "expected exit 1 (completed+open pair is still a duplicate), got exit $_rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Pseudo-duplicate (t2743 in description, not checkbox anchor) → exit 0
# Line: "- [ ] t2744 Tests for t2743 ref:GH#..." should NOT be flagged.
# ---------------------------------------------------------------------------
test_pseudo_duplicate_in_description() {
	local _name="test_5_pseudo_duplicate_in_description"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Ready
- [ ] t2743 Fix REST fallback ref:GH#20480
- [ ] t2744 Tests for t2743 coverage ref:GH#20481"

	local _sha
	_sha=$(_commit_todo "$_content")
	_run_hook "$_sha" 2>/dev/null
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -eq 0 ]]; then
		_pass "$_name"
	else
		_fail "$_name" "expected exit 0 (t2743 in description only), got exit $_rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: DUP_TODO_GUARD_DISABLE=1 → exit 0 even with duplicates; warning to stderr
# ---------------------------------------------------------------------------
test_bypass_env_var() {
	local _name="test_6_bypass_env_var"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Ready
- [ ] t2743 First entry ref:GH#20480

## Backlog
- [ ] t2743 Second entry ref:GH#20480"

	local _sha
	_sha=$(_commit_todo "$_content")

	# Capture both stdout and stderr; run with bypass env var
	local _stderr
	_stderr=$(DUP_TODO_GUARD_DISABLE=1 bash "$HOOK" origin "https://github.com/test/repo" \
		<<<"refs/heads/test ${_sha} refs/heads/main 0000000000000000000000000000000000000000" \
		2>&1 1>/dev/null)
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -ne 0 ]]; then
		_fail "$_name" "expected exit 0 with bypass env var, got exit $_rc"
		return 0
	fi
	# Warning should appear in stderr
	if printf '%s\n' "$_stderr" | grep -qi "bypass\|skip\|override"; then
		_pass "$_name"
	else
		_fail "$_name" "expected bypass warning in stderr; stderr: $_stderr"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: --no-verify bypass (documentation / informational)
# git push --no-verify does not invoke the hook at all — this is git's own
# bypass mechanism and not testable at the hook script level. This test
# documents the expected behaviour and verifies the hook has no special
# handling that would interfere with --no-verify.
# ---------------------------------------------------------------------------
test_no_verify_documentation() {
	local _name="test_7_no_verify_bypass_documented"
	# The hook does not need to do anything special for --no-verify;
	# git itself skips all pre-push hooks. Verify that the hook exits 0
	# with empty stdin (simulating a no-op invocation), which is the
	# closest unit-testable analogue.
	local _rc
	bash "$HOOK" origin "https://github.com/test/repo" </dev/null 2>/dev/null
	_rc=$?
	if [[ "$_rc" -eq 0 ]]; then
		_pass "$_name"
	else
		_fail "$_name" "expected exit 0 with empty stdin (no refs to check), got exit $_rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: hierarchical task ID duplicate (t1271.1 twice) → exit 1, cites lines
# ---------------------------------------------------------------------------
test_hierarchical_id_duplicate() {
	local _name="test_8_hierarchical_id_duplicate"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Tasks
- [ ] t1271 Parent task ref:GH#2001
  - [x] t1271.1 First sub-entry ref:GH#2005

## Backlog
  - [ ] t1271.1 Second sub-entry ref:GH#2005"

	local _sha
	_sha=$(_commit_todo "$_content")

	local _stdout _stderr
	_stdout=$(bash "$HOOK" origin "https://github.com/test/repo" \
		<<<"refs/heads/test ${_sha} refs/heads/main 0000000000000000000000000000000000000000" \
		2>/dev/null)
	_stderr=$(bash "$HOOK" origin "https://github.com/test/repo" \
		<<<"refs/heads/test ${_sha} refs/heads/main 0000000000000000000000000000000000000000" \
		2>&1 1>/dev/null)
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -ne 1 ]]; then
		_fail "$_name" "expected exit 1 (hierarchical duplicate t1271.1), got exit $_rc"
		return 0
	fi
	if ! printf '%s\n' "$_stderr" | grep -q "t1271.1"; then
		_fail "$_name" "expected t1271.1 cited in stderr; stderr: $_stderr"
		return 0
	fi
	_pass "$_name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: indented subtask duplicate → exit 1, cites lines
# ---------------------------------------------------------------------------
test_indented_subtask_duplicate() {
	local _name="test_9_indented_subtask_duplicate"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Tasks
- [ ] t1678 Parent task ref:GH#6821
  - [ ] t1678.1 First occurrence ref:GH#6821

## Backlog
  - [ ] t1678.1 Second occurrence ref:GH#6821"

	local _sha
	_sha=$(_commit_todo "$_content")

	local _stderr
	_stderr=$(bash "$HOOK" origin "https://github.com/test/repo" \
		<<<"refs/heads/test ${_sha} refs/heads/main 0000000000000000000000000000000000000000" \
		2>&1 1>/dev/null)
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -ne 1 ]]; then
		_fail "$_name" "expected exit 1 (indented duplicate t1678.1), got exit $_rc"
		return 0
	fi
	if ! printf '%s\n' "$_stderr" | grep -q "t1678.1"; then
		_fail "$_name" "expected t1678.1 cited in stderr; stderr: $_stderr"
		return 0
	fi
	_pass "$_name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: an unchanged duplicate already present in the baseline → exit 0
# ---------------------------------------------------------------------------
test_unchanged_preexisting_duplicate() {
	local _name="test_10_unchanged_preexisting_duplicate"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _content
	_content="## Ready
- [ ] t2743 First entry ref:GH#20480

## Backlog
- [ ] t2743 Existing duplicate ref:GH#20480"

	local _duplicate_base _sha
	_duplicate_base=$(_commit_todo "$_content")
	_sha=$(_commit_unrelated)
	_run_hook "$_sha" "" "$_duplicate_base" 2>/dev/null
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -eq 0 ]]; then
		_pass "$_name"
	else
		_fail "$_name" "expected exit 0 for unchanged baseline duplicate, got exit $_rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 11: increasing a duplicate count relative to the baseline → exit 1
# ---------------------------------------------------------------------------
test_increased_preexisting_duplicate() {
	local _name="test_11_increased_preexisting_duplicate"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _base_content _head_content
	_base_content="## Ready
- [ ] t2743 First entry ref:GH#20480

## Backlog
- [ ] t2743 Existing duplicate ref:GH#20480"
	_head_content="${_base_content}
- [ ] t2743 Newly added third entry ref:GH#20480"

	local _duplicate_base _sha
	_duplicate_base=$(_commit_todo "$_base_content")
	_sha=$(_commit_todo "$_head_content")
	local _stderr
	_stderr=$(_run_hook "$_sha" "" "$_duplicate_base" 2>&1 1>/dev/null)
	local _rc=$?

	_teardown_git_repo

	if [[ "$_rc" -ne 1 ]]; then
		_fail "$_name" "expected exit 1 for increased duplicate count, got exit $_rc"
		return 0
	fi
	if printf '%s\n' "$_stderr" | grep -q "t2743"; then
		_pass "$_name"
	else
		_fail "$_name" "error message did not mention t2743; stderr: $_stderr"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 12: one issue mapped by two distinct task IDs is also a duplicate.
# ---------------------------------------------------------------------------
test_duplicate_issue_mapping() {
	local _name="test_12_duplicate_issue_mapping"
	_setup_git_repo || { _fail "$_name" "git repo setup failed"; return 0; }

	local _base_content _head_content
	_base_content="## Ready
- [ ] t2743 First task ref:GH#20480"
	_head_content="${_base_content}
- [ ] t2744 Different task, same issue ref:GH#20480"
	local _base_sha _head_sha _stderr _rc
	_base_sha=$(_commit_todo "$_base_content")
	_head_sha=$(_commit_todo "$_head_content")
	_stderr=$(_run_hook "$_head_sha" "" "$_base_sha" 2>&1 1>/dev/null)
	_rc=$?

	_teardown_git_repo
	if [[ "$_rc" -eq 1 && "$_stderr" == *"Duplicate issue mapping: ref:GH#20480"* ]]; then
		_pass "$_name"
	else
		_fail "$_name" "expected duplicate issue mapping diagnostic; rc=${_rc}, stderr=${_stderr}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	printf 'Running pre-push-dup-todo-guard tests...\n\n'

	test_clean_no_duplicates
	test_single_duplicate
	test_multiple_duplicates
	test_completed_and_open_pair
	test_pseudo_duplicate_in_description
	test_bypass_env_var
	test_no_verify_documentation
	test_hierarchical_id_duplicate
	test_indented_subtask_duplicate
	test_unchanged_preexisting_duplicate
	test_increased_preexisting_duplicate
	test_duplicate_issue_mapping

	printf '\n'
	printf 'Results: %d passed, %d failed\n' "$_TESTS_PASSED" "$_TESTS_FAILED"

	if [[ "$_TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
