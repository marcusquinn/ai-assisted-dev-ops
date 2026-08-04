#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#29507: the t2091 closed-issue guard has one
# explicit, audited, interactive-maintainer completion-bookkeeping exception.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
TMP_ROOT=$(mktemp -d -t gh29507.XXXXXX) || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

CALL_LOG="${TMP_ROOT}/calls.log"
MESSAGE_LOG="${TMP_ROOT}/messages.log"
CREATED_BODY_FILE="${TMP_ROOT}/created-body.md"
FIXTURE_ROOT="${TMP_ROOT}/repo"
mkdir -p "$FIXTURE_ROOT" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

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

extract_function() {
	local source_file="$1"
	local function_name="$2"
	sed -n "/^${function_name}() {/,/^}/p" "$source_file"
	return 0
}

COMMIT_HELPER="${SCRIPTS_DIR}/full-loop-helper-commit.sh"
MAIN_HELPER="${SCRIPTS_DIR}/full-loop-helper.sh"

eval "$(extract_function "$COMMIT_HELPER" _parse_commit_and_pr_args)"
eval "$(extract_function "$COMMIT_HELPER" _validate_completion_bookkeeping_request)"
eval "$(extract_function "$COMMIT_HELPER" _completion_bookkeeping_body_has_reference)"
eval "$(extract_function "$COMMIT_HELPER" _completion_bookkeeping_body_has_closing_reference)"
eval "$(extract_function "$COMMIT_HELPER" _verify_completion_bookkeeping_proof)"
eval "$(extract_function "$COMMIT_HELPER" _validate_completion_bookkeeping_paths)"
eval "$(extract_function "$COMMIT_HELPER" _validate_completion_bookkeeping_todo)"
eval "$(extract_function "$COMMIT_HELPER" _validate_completion_bookkeeping_pr_body)"
eval "$(extract_function "$COMMIT_HELPER" _validate_closed_issue_completion_bookkeeping)"
eval "$(extract_function "$MAIN_HELPER" cmd_commit_and_pr)"

_FULL_LOOP_TRUE="true"
FULL_LOOP_COMPLETION_BOOKKEEPING_AUDIT=""
FULL_LOOP_COMPLETION_BOOKKEEPING_FILES=""
HEADLESS=false
SCRIPT_DIR="${TMP_ROOT}/no-helper-binaries"

record_call() {
	local name="$1"
	printf '%s\n' "$name" >>"$CALL_LOG"
	return 0
}

call_count() {
	local name="$1"
	local count=""
	count=$(grep -cFx "$name" "$CALL_LOG" 2>/dev/null || true)
	printf '%s\n' "${count:-0}"
	return 0
}

print_info() {
	local message="$*"
	printf 'INFO %s\n' "$message" >>"$MESSAGE_LOG"
	return 0
}

print_error() {
	local message="$*"
	printf 'ERROR %s\n' "$message" >>"$MESSAGE_LOG"
	return 0
}

print_warning() {
	local message="$*"
	printf 'WARN %s\n' "$message" >>"$MESSAGE_LOG"
	return 0
}

print_success() {
	local message="$*"
	printf 'OK %s\n' "$message" >>"$MESSAGE_LOG"
	return 0
}

detect_session_origin() {
	printf '%s\n' "${TEST_SESSION_ORIGIN}"
	return 0
}

session_origin_label() {
	printf 'origin:%s\n' "${TEST_SESSION_ORIGIN}"
	return 0
}

_gh_current_user_allows_repo_write() {
	local repo_slug="$1"
	[[ -n "$repo_slug" && "$TEST_PERMISSION" == "allowed" ]]
	return $?
}

gh() {
	local area="${1:-}"
	shift || true
	local action="${1:-}"
	if [[ "$area" == "issue" && "$action" == "view" ]]; then
		printf '%s\t%s\n' "$TEST_ISSUE_STATE" "$TEST_ISSUE_REASON"
		return 0
	fi
	if [[ "$area" == "api" ]]; then
		if [[ "$TEST_PROOF_LOOKUP" == "fail" ]]; then
			return 1
		fi
		jq -cn \
			--argjson number "$TEST_PROOF_NUMBER" \
			--arg state "$TEST_PROOF_STATE" \
			--arg merged_at "$TEST_PROOF_MERGED_AT" \
			--arg title "$TEST_PROOF_TITLE" \
			--arg body "$TEST_PROOF_BODY" \
			'{number:$number,state:$state,merged_at:$merged_at,title:$title,body:$body}'
		return $?
	fi
	return 1
}

git() {
	local command_name="${1:-}"
	shift || true
	local first_arg="${1:-}"
	local arguments=" $* "
	case "$command_name" in
	diff)
		case "$arguments" in
		*" --diff-filter=D "*) printf '%s' "$TEST_DELETED_FILES" ;;
		*" --unified=0 "*) printf '%s\n' "$TEST_TODO_PATCH" ;;
		*" --name-only "*) printf '%s\n' "$TEST_CHANGED_FILES" ;;
		*) return 1 ;;
		esac
		return 0
		;;
	rev-parse)
		if [[ "$first_arg" == "--show-toplevel" ]]; then
			printf '%s\n' "$FIXTURE_ROOT"
			return 0
		fi
		return 1
		;;
	esac
	return 0
}

_validate_commit_and_pr_inputs() {
	local issue_number_arg="$1"
	local commit_message_arg="$2"
	[[ -n "$issue_number_arg" && -n "$commit_message_arg" ]] || return 1
	repo="example/repo"
	branch="feature/gh29507-test"
	return 0
}

_validate_explicit_pr_metadata() {
	local runtime_risk_arg="$1"
	local testing_level_arg="$2"
	[[ -n "$runtime_risk_arg" && -n "$testing_level_arg" ]] || return 1
	return 0
}

_stage_and_commit() {
	local commit_message="$1"
	[[ -n "$commit_message" ]] || return 1
	record_call "stage"
	return 0
}

_finalize_wip_history() {
	local commit_message="$1"
	[[ -n "$commit_message" ]] || return 1
	return 0
}

_run_project_validators() {
	local skip_hooks="$1"
	[[ "$skip_hooks" -ge 0 ]] || return 1
	return 0
}

_rebase_for_push() {
	local branch_name="$1"
	local skip_rebase="$2"
	[[ -n "$branch_name" && "$skip_rebase" -ge 0 ]] || return 1
	return 0
}

_resolve_remote_default_branch() {
	local remote_name="$1"
	[[ "$remote_name" == "origin" ]] || return 1
	printf 'main\n'
	return 0
}

_build_pr_body() {
	local issue_number="$1"
	local summary_what="$2"
	local summary_testing="$3"
	local files_changed="$4"
	local sig_footer="$5"
	local closing_keyword="${6:-Resolves}"
	[[ -n "$summary_what" && -n "$summary_testing" && -n "$files_changed" ]] || return 1
	[[ -n "$sig_footer" ]] || true
	if [[ -n "$TEST_FORCE_KEYWORD" ]]; then
		closing_keyword="$TEST_FORCE_KEYWORD"
	fi
	printf '## Summary\n\n%s\n\n%s #%s\n' "$summary_what" "$closing_keyword" "$issue_number"
	return 0
}

_compose_pr_title() {
	local issue_number="$1"
	local commit_message="$2"
	printf 'GH#%s: %s\n' "$issue_number" "$commit_message"
	return 0
}

_issue_has_parent_task_label() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 1
	return 1
}

_validate_worker_claim() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 1
	return 0
}

gh_issue_comment() {
	local issue_number="$1"
	[[ -n "$issue_number" ]] || return 1
	record_call "issue-comment"
	return 0
}

_push_branch() {
	local branch_name="$1"
	local skip_hooks="$2"
	[[ -n "$branch_name" && "$skip_hooks" -ge 0 ]] || return 1
	record_call "push"
	return 0
}

_create_pr() {
	local repo_slug="$1"
	local pr_title="$2"
	local pr_body="$3"
	local origin_label="$4"
	[[ -n "$repo_slug" && -n "$pr_title" && "$origin_label" == "origin:interactive" ]] || return 1
	printf '%s\n' "$pr_body" >"$CREATED_BODY_FILE"
	record_call "create-pr"
	printf '77\n'
	return 0
}

_post_merge_summary() {
	local pr_number="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local summary_what="$4"
	local files_changed="$5"
	local summary_testing="$6"
	local summary_decisions="$7"
	[[ -n "$pr_number" && -n "$repo_slug" && -n "$issue_number" && -n "$summary_what" && -n "$files_changed" && -n "$summary_testing" ]] || return 1
	printf '%s\n' "$summary_decisions" >>"$MESSAGE_LOG"
	record_call "merge-summary"
	return 0
}

_label_issue_in_review() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 1
	return 0
}

_label_pr_in_review() {
	local pr_number="$1"
	local repo_slug="$2"
	[[ -n "$pr_number" && -n "$repo_slug" ]] || return 1
	return 0
}

is_loop_active() {
	return 1
}

_full_loop_record_phase() {
	local phase="$1"
	local pr_number="$2"
	[[ -n "$phase" && -n "$pr_number" ]] || return 1
	return 0
}

reset_case() {
	: >"$CALL_LOG"
	: >"$MESSAGE_LOG"
	: >"$CREATED_BODY_FILE"
	unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS CLAUDE_HEADLESS GITHUB_ACTIONS
	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG AIDEVOPS_SESSION_ORIGIN
	HEADLESS=false
	TEST_SESSION_ORIGIN="interactive"
	TEST_PERMISSION="allowed"
	TEST_ISSUE_STATE="CLOSED"
	TEST_ISSUE_REASON="COMPLETED"
	TEST_PROOF_LOOKUP="ok"
	TEST_PROOF_NUMBER=900
	TEST_PROOF_STATE="closed"
	TEST_PROOF_MERGED_AT="2026-08-04T12:00:00Z"
	TEST_PROOF_TITLE="t4242: Deliver substantive work"
	TEST_PROOF_BODY="Resolves #42"
	TEST_CHANGED_FILES=$'TODO.md\ntodo/tasks/t4242-brief.md'
	TEST_DELETED_FILES=""
	TEST_FORCE_KEYWORD=""
	TEST_TODO_PATCH=$'diff --git a/TODO.md b/TODO.md\nindex 111..222 100644\n--- a/TODO.md\n+++ b/TODO.md\n@@ -1 +1 @@\n-- [ ] t4242 Terminal task ref:GH#42\n+- [x] t4242 Terminal task ref:GH#42 pr:#900 testing:self-assessed completed:2026-08-04'
	printf '%s\n' '- [x] t4242 Terminal task ref:GH#42 pr:#900 testing:self-assessed completed:2026-08-04' >"${FIXTURE_ROOT}/TODO.md"
	FULL_LOOP_COMPLETION_BOOKKEEPING_AUDIT=""
	FULL_LOOP_COMPLETION_BOOKKEEPING_FILES=""
	return 0
}

invoke_bookkeeping() {
	cmd_commit_and_pr \
		--issue 42 \
		--message "chore: reconcile terminal completion metadata" \
		--summary "Record terminal completion proof" \
		--testing "focused fixture passed" \
		--risk-level low \
		--testing-level self-assessed \
		--completion-bookkeeping \
		--proof-pr 900 \
		--task-id t4242
	return $?
}

invoke_default() {
	cmd_commit_and_pr \
		--issue 42 \
		--message "fix: late duplicate implementation" \
		--summary "Late implementation" \
		--testing "fixture" \
		--risk-level low \
		--testing-level self-assessed
	return $?
}

test_completed_success() {
	reset_case
	local output=""
	local rc=0
	output=$(invoke_bookkeeping) || rc=$?
	if [[ "$rc" -eq 0 && "$output" == "77" && "$(call_count push)" -eq 1 &&
	"$(call_count create-pr)" -eq 1 && "$(call_count merge-summary)" -eq 1 ]] &&
		grep -qF 'terminal issue #42 (COMPLETED)' "$MESSAGE_LOG" &&
		grep -qF 'merged proof PR #900' "$MESSAGE_LOG" &&
		grep -qF 'allowed files: TODO.md, todo/tasks/t4242-brief.md' "$MESSAGE_LOG" &&
		grep -qF 'non-closing reference: For #42' "$MESSAGE_LOG" &&
		grep -qF 'For #42' "$CREATED_BODY_FILE"; then
		pass "COMPLETED bookkeeping creates exactly one non-closing PR with audit evidence"
	else
		fail "COMPLETED bookkeeping creates exactly one non-closing PR with audit evidence" "rc=${rc} output=${output} calls=$(<"$CALL_LOG")"
	fi
	return 0
}

test_not_planned_success() {
	reset_case
	TEST_ISSUE_REASON="NOT_PLANNED"
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	if [[ "$rc" -eq 0 && "$(call_count create-pr)" -eq 1 ]] && grep -qF 'terminal issue #42 (NOT_PLANNED)' "$MESSAGE_LOG"; then
		pass "NOT_PLANNED bookkeeping is accepted with the same narrow guard"
	else
		fail "NOT_PLANNED bookkeeping is accepted with the same narrow guard" "rc=${rc}"
	fi
	return 0
}

test_default_closed_refusal() {
	reset_case
	local rc=0
	invoke_default >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 && "$(call_count issue-comment)" -eq 1 ]]; then
		pass "default t2091 path still rejects closed-issue implementation before push"
	else
		fail "default t2091 path still rejects closed-issue implementation before push" "rc=${rc} calls=$(<"$CALL_LOG")"
	fi
	return 0
}

test_open_issue_refusal() {
	reset_case
	TEST_ISSUE_STATE="OPEN"
	TEST_ISSUE_REASON=""
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode requires a verified terminal issue"
	else
		fail "bookkeeping mode requires a verified terminal issue" "rc=${rc}"
	fi
	return 0
}

test_missing_proof_refusal() {
	reset_case
	local rc=0
	cmd_commit_and_pr --issue 42 --message "chore: metadata" --risk-level low --testing-level self-assessed \
		--completion-bookkeeping --task-id t4242 >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects an absent proof PR"
	else
		fail "bookkeeping mode rejects an absent proof PR" "rc=${rc}"
	fi
	return 0
}

test_unmerged_proof_refusal() {
	reset_case
	TEST_PROOF_STATE="open"
	TEST_PROOF_MERGED_AT=""
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects an unmerged proof PR"
	else
		fail "bookkeeping mode rejects an unmerged proof PR" "rc=${rc}"
	fi
	return 0
}

test_worker_refusal() {
	reset_case
	AIDEVOPS_HEADLESS=true
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	unset AIDEVOPS_HEADLESS
	if [[ "$rc" -ne 0 && "$(call_count stage)" -eq 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects headless workers before local or remote mutation"
	else
		fail "bookkeeping mode rejects headless workers before local or remote mutation" "rc=${rc}"
	fi
	return 0
}

test_non_maintainer_refusal() {
	reset_case
	TEST_PERMISSION="read"
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count stage)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects sessions without maintainer-equivalent permission"
	else
		fail "bookkeeping mode rejects sessions without maintainer-equivalent permission" "rc=${rc}"
	fi
	return 0
}

test_source_change_refusal() {
	reset_case
	TEST_CHANGED_FILES=$'TODO.md\nsrc/implementation.sh'
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects source-code changes before push"
	else
		fail "bookkeeping mode rejects source-code changes before push" "rc=${rc}"
	fi
	return 0
}

test_mismatched_task_refusal() {
	reset_case
	TEST_PROOF_TITLE="t9999: Unrelated merged work"
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects mismatched task and proof identity"
	else
		fail "bookkeeping mode rejects mismatched task and proof identity" "rc=${rc}"
	fi
	return 0
}

test_closing_keyword_refusal() {
	reset_case
	TEST_FORCE_KEYWORD="Resolves"
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects a closing keyword before push"
	else
		fail "bookkeeping mode rejects a closing keyword before push" "rc=${rc}"
	fi
	return 0
}

test_dual_origin_refusal() {
	reset_case
	local rc=0
	cmd_commit_and_pr --issue 42 --message "chore: metadata" --risk-level low --testing-level self-assessed \
		--completion-bookkeeping --proof-pr 900 --task-id t4242 --label origin:worker >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count stage)" -eq 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects caller-supplied dual-origin labels"
	else
		fail "bookkeeping mode rejects caller-supplied dual-origin labels" "rc=${rc}"
	fi
	return 0
}

test_unrelated_todo_change_refusal() {
	reset_case
	TEST_TODO_PATCH=$'diff --git a/TODO.md b/TODO.md\n--- a/TODO.md\n+++ b/TODO.md\n@@ -2 +2 @@\n-- [ ] t9999 Unrelated task ref:GH#99\n+- [x] t9999 Unrelated task ref:GH#99 completed:2026-08-04'
	local rc=0
	invoke_bookkeeping >/dev/null || rc=$?
	if [[ "$rc" -ne 0 && "$(call_count push)" -eq 0 && "$(call_count create-pr)" -eq 0 ]]; then
		pass "bookkeeping mode rejects unrelated TODO.md edits"
	else
		fail "bookkeeping mode rejects unrelated TODO.md edits" "rc=${rc}"
	fi
	return 0
}

test_completed_success
test_not_planned_success
test_default_closed_refusal
test_open_issue_refusal
test_missing_proof_refusal
test_unmerged_proof_refusal
test_worker_refusal
test_non_maintainer_refusal
test_source_change_refusal
test_mismatched_task_refusal
test_closing_keyword_refusal
test_dual_origin_refusal
test_unrelated_todo_change_refusal

if [[ "$TESTS_FAILED" -ne 0 ]]; then
	printf '%s/%s closed-issue bookkeeping tests failed\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
	exit 1
fi

printf 'All %s closed-issue bookkeeping tests passed\n' "$TESTS_RUN"
