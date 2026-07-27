#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for dispatch-single-issue-helper.sh — focused on the t3000
# `_dsi_apply_dispatch_ceremony` function which mirrors the canonical pulse
# `_dlw_assign_and_label` ownership-claim sequence.
#
# Background: the manual single-issue dispatch CLI was previously launching
# workers without applying the pre-launch ceremony (status:queued +
# assignee normalize) that the pulse always applies. This
# created a race window where the next pulse cycle could see the issue in
# its prior state and dispatch a duplicate worker on top of the running one.
#
# The tests exercise the helper in isolation by sourcing the script (the
# `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard prevents main() from
# running) and overriding `set_issue_status` with a mock that captures
# every flag for assertion.

# Generated child scripts intentionally defer these expressions until runtime.
# shellcheck disable=SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_PATH="${SCRIPT_DIR}/../dispatch-single-issue-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
SET_ISSUE_STATUS_LOG=""
SET_ORIGIN_LABEL_LOG=""
REGISTER_WORKTREE_LOG=""
MOCK_WORKTREE_HELPER_LOG=""
MOCK_GH_ISSUE_STATE="OPEN"
MOCK_GH_LABELS_JSON="[]"
MOCK_GH_FAIL="0"
MOCK_GH_TARGET_IS_PR="0"
MOCK_GH_AUTHOR_ASSOCIATION="OWNER"
MOCK_GH_AUTHOR_LOGIN="fixture-owner"
MOCK_GH_AUTHOR_TYPE="User"
MOCK_GH_PERMISSION_EVENTS_JSON='[[]]'
MOCK_GH_REST_LOGIN_MODE="success"
MOCK_GH_GRAPHQL_LOGIN_MODE="success"
MOCK_GH_CALL_LOG=""
MOCK_PS_LINES=""
MOCK_LIVE_PIDS=""
MOCK_LEDGER_RECORD=""
MOCK_GIT_WORKTREE_LIST="0"
MOCK_REPO_PATH=""
MOCK_WORKTREE_PATH=""
MOCK_WORKTREE_BRANCH=""
MOCK_DATE_UTC=""

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

# Source the helper so its functions become available in this shell.
# The main() guard means executing the test does NOT re-enter the dispatch
# CLI — only the function definitions land in scope.
# shellcheck source=../dispatch-single-issue-helper.sh
# shellcheck disable=SC1091
source "$HELPER_PATH"

# Override set_issue_status (defined by shared-gh-wrappers.sh which the
# helper sourced) with a mock that logs every flag to SET_ISSUE_STATUS_LOG.
# This is what the ceremony function calls; we never actually touch GitHub.
#
# Mode comes from the global $MOCK_SET_ISSUE_STATUS_MODE — NOT a local of
# the installer function. A nested function definition does not capture the
# enclosing function's locals (bash has no closures); after the installer
# returns, those locals are gone and `set -u` would tank the mock body.
MOCK_SET_ISSUE_STATUS_MODE="success"

# shellcheck disable=SC2317
set_issue_status() {
	printf 'set_issue_status %s\n' "$*" >>"$SET_ISSUE_STATUS_LOG"
	case "$MOCK_SET_ISSUE_STATUS_MODE" in
	success) return 0 ;;
	failure) return 1 ;;
	*) return 0 ;;
	esac
}

_install_mock_set_issue_status() {
	MOCK_SET_ISSUE_STATUS_MODE="${1:-success}"
	return 0
}

# Override set_origin_label (also from shared-gh-wrappers.sh) with a mock that
# logs every call to SET_ORIGIN_LABEL_LOG. Dispatch ceremony should not call it:
# origin:* labels are immutable creation provenance, not worker-claim state.
MOCK_SET_ORIGIN_LABEL_MODE="success"

# shellcheck disable=SC2317
set_origin_label() {
	printf 'set_origin_label %s\n' "$*" >>"$SET_ORIGIN_LABEL_LOG"
	case "$MOCK_SET_ORIGIN_LABEL_MODE" in
	success) return 0 ;;
	failure) return 1 ;;
	*) return 0 ;;
	esac
}

_install_mock_set_origin_label() {
	MOCK_SET_ORIGIN_LABEL_MODE="${1:-success}"
	return 0
}

# shellcheck disable=SC2317
register_worktree() {
	if [[ -z "${REGISTER_WORKTREE_LOG:-}" ]]; then
		return 0
	fi
	printf 'register_worktree %s\n' "$*" >>"$REGISTER_WORKTREE_LOG"
	return $?
}

# shellcheck disable=SC2317
date() {
	local date_first="${1:-}"
	local date_format="${2:-}"
	if [[ -n "$MOCK_DATE_UTC" && "$date_first" == "-u" && "$date_format" == "+%Y%m%d-%H%M%S" ]]; then
		printf '%s\n' "$MOCK_DATE_UTC"
		return 0
	fi
	command date "$@"
	return $?
}

# shellcheck disable=SC2317
git() {
	local git_first="${1:-}"
	local git_repo="${2:-}"
	local git_command="${3:-}"
	local git_subcommand="${4:-}"
	local git_format="${5:-}"
	if [[ "$MOCK_GIT_WORKTREE_LIST" == "1" && "$git_first" == "-C" && "$git_repo" == "$MOCK_REPO_PATH" &&
		"$git_command" == "worktree" && "$git_subcommand" == "list" && "$git_format" == "--porcelain" ]]; then
		printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/%s\n\n' \
			"$MOCK_WORKTREE_PATH" "$MOCK_WORKTREE_BRANCH"
		return 0
	fi
	command git "$@"
	return $?
}

# shellcheck disable=SC2317
gh() {
	local gh_subcommand="${1:-}"
	local gh_resource="${2:-}"
	if [[ -n "$MOCK_GH_CALL_LOG" ]]; then
		printf '%s\n' "$*" >>"$MOCK_GH_CALL_LOG"
	fi
	if [[ "$MOCK_GH_FAIL" == "1" ]]; then
		return 1
	fi

	if [[ "$gh_subcommand" == "issue" && "$gh_resource" == "view" ]]; then
		printf '{"number":%s,"title":"Mock issue","state":"%s","labels":%s,"assignees":[],"url":"https://example.invalid/issues/%s"}\n' \
			"$3" "$MOCK_GH_ISSUE_STATE" "$MOCK_GH_LABELS_JSON" "$3"
		return 0
	fi

	if [[ "$gh_subcommand" == "api" && "$gh_resource" == "user" ]]; then
		case "$MOCK_GH_REST_LOGIN_MODE" in
		success)
			printf '%s\n' 'runner-self'
			return 0
			;;
		invalid)
			printf '%s\n' 'invalid login!'
			return 0
			;;
		*) return 1 ;;
		esac
	fi

	if [[ "$gh_subcommand" == "api" && "$gh_resource" == "graphql" ]]; then
		case "$MOCK_GH_GRAPHQL_LOGIN_MODE" in
		success)
			printf '%s\n' 'fallback-runner'
			return 0
			;;
		invalid)
			printf '%s\n' 'fallback;injection'
			return 0
			;;
		*) return 1 ;;
		esac
	fi
	if [[ "$gh_subcommand" == "api" && "$gh_resource" == */events\?* ]]; then
		printf '%s\n' "$MOCK_GH_PERMISSION_EVENTS_JSON"
		return 0
	fi

	if [[ "$gh_subcommand" == "api" && "$gh_resource" == repos/*/issues/* ]]; then
		case "$MOCK_GH_TARGET_IS_PR" in
		1) printf '{"number":123,"author_association":"%s","user":{"login":"%s","type":"%s"},"pull_request":{"url":"https://api.example.invalid/pulls/123"}}\n' "$MOCK_GH_AUTHOR_ASSOCIATION" "$MOCK_GH_AUTHOR_LOGIN" "$MOCK_GH_AUTHOR_TYPE" ;;
		api_fail) return 1 ;;
		*) printf '{"number":123,"author_association":"%s","user":{"login":"%s","type":"%s"}}\n' "$MOCK_GH_AUTHOR_ASSOCIATION" "$MOCK_GH_AUTHOR_LOGIN" "$MOCK_GH_AUTHOR_TYPE" ;;
		esac
		return 0
	fi

	printf 'unexpected gh call: %s\n' "$*" >&2
	return 1
}


# shellcheck disable=SC2317
_dsi_ps_worker_lines() {
	printf '%s\n' "$MOCK_PS_LINES"
	return 0
}

# shellcheck disable=SC2317
_dsi_pid_is_live() {
	local pid="$1"
	local live_pid=""
	for live_pid in $MOCK_LIVE_PIDS; do
		[[ "$pid" == "$live_pid" ]] && return 0
	done
	return 1
}

# shellcheck disable=SC2317
_dsi_repo_slug_for_worktree() {
	local worktree_path="$1"
	case "$worktree_path" in
	/tmp/aidevops-existing | /tmp/aidevops-recovery) printf '%s\n' "owner/repo" ;;
	*) printf '\n' ;;
	esac
	return 0
}

# shellcheck disable=SC2317
_dsi_repo_path_for_slug() {
	local repo_slug="$1"
	if [[ "$repo_slug" == "owner/repo" && -n "$MOCK_REPO_PATH" ]]; then
		printf '%s\n' "$MOCK_REPO_PATH"
		return 0
	fi
	return 1
}

# shellcheck disable=SC2317
_dsi_find_ledger_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	if [[ -n "$MOCK_LEDGER_RECORD" && "$issue_number" == "12345" && "$repo_slug" == "owner/repo" ]]; then
		printf '%s\n' "$MOCK_LEDGER_RECORD"
		return 0
	fi
	return 1
}

reset_test_state() {
	: >"$SET_ISSUE_STATUS_LOG"
	: >"$SET_ORIGIN_LABEL_LOG"
	return 0
}

# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------

test_ceremony_applies_default() {
	reset_test_state
	_install_mock_set_issue_status success
	_install_mock_set_origin_label success

	# Issue meta with one prior assignee that ceremony should remove.
	local issue_meta='{"assignees":[{"login":"prior-author"}]}'
	local rc=0
	_dsi_apply_dispatch_ceremony 12345 owner/repo runner-self "$issue_meta" >/dev/null 2>&1 || rc=$?

	local status_logged
	status_logged=$(cat "$SET_ISSUE_STATUS_LOG")

	# Assert ceremony returned success
	if [[ "$rc" -ne 0 ]]; then
		print_result "ceremony returns 0 on success" 1 "got rc=$rc"
		return 0
	fi
	print_result "ceremony returns 0 on success" 0

	# Assert exactly one set_issue_status call recorded.
	# t2763: the unsafe grep-c-then-fallback idiom stacks two zeros on the
	# zero-match path. Use the inline guard pattern instead (see counter-stack-check).
	local call_count
	call_count=$(grep -c '^set_issue_status' "$SET_ISSUE_STATUS_LOG" 2>/dev/null || true)
	[[ "$call_count" =~ ^[0-9]+$ ]] || call_count=0
	if [[ "$call_count" -ne 1 ]]; then
		print_result "ceremony emits exactly one set_issue_status call" 1 "got $call_count calls"
		return 0
	fi
	print_result "ceremony emits exactly one set_issue_status call" 0

	# Assert status:queued positional
	local status_check=1
	[[ "$status_logged" == *"set_issue_status 12345 owner/repo queued"* ]] && status_check=0
	print_result "ceremony passes status:queued (not in-progress)" "$status_check" \
		"expected 'set_issue_status 12345 owner/repo queued' in: $status_logged"

	# Origin labels are creation provenance and must not be rewritten by worker
	# claim ceremony.
	local origin_call_count
	origin_call_count=$(grep -c '^set_origin_label' "$SET_ORIGIN_LABEL_LOG" 2>/dev/null || true)
	[[ "$origin_call_count" =~ ^[0-9]+$ ]] || origin_call_count=0
	if [[ "$origin_call_count" -ne 0 ]]; then
		print_result "ceremony preserves origin provenance" 1 "got $origin_call_count set_origin_label calls"
		return 0
	fi
	print_result "ceremony preserves origin provenance" 0

	# Assert origin:worker NOT embedded in set_issue_status flags (t3007 regression guard)
	local no_bare_add=0 no_bare_rm_int=0 no_bare_rm_take=0
	[[ "$status_logged" == *"--add-label origin:worker"* ]] && no_bare_add=1
	[[ "$status_logged" == *"--remove-label origin:interactive"* ]] && no_bare_rm_int=1
	[[ "$status_logged" == *"--remove-label origin:worker-takeover"* ]] && no_bare_rm_take=1
	print_result "origin:worker not embedded in set_issue_status" "$no_bare_add" \
		"bare --add-label origin:worker found in set_issue_status call"
	print_result "origin:interactive removal not in set_issue_status (t3007)" "$no_bare_rm_int" \
		"bare --remove-label origin:interactive found"
	print_result "origin:worker-takeover removal not in set_issue_status (t3007)" "$no_bare_rm_take" \
		"bare --remove-label origin:worker-takeover found"

	# Assert assignee normalization still in set_issue_status
	local add_assignee=1 rm_prior=1
	[[ "$status_logged" == *"--add-assignee runner-self"* ]] && add_assignee=0
	[[ "$status_logged" == *"--remove-assignee prior-author"* ]] && rm_prior=0
	print_result "ceremony adds runner-self as assignee" "$add_assignee"
	print_result "ceremony removes prior assignee" "$rm_prior"

	return 0
}

test_ceremony_skip_when_self_assigned() {
	reset_test_state
	_install_mock_set_issue_status success
	_install_mock_set_origin_label success

	# When the only existing assignee IS runner-self, no --remove-assignee
	# should be emitted (don't unassign yourself).
	local issue_meta='{"assignees":[{"login":"runner-self"}]}'
	_dsi_apply_dispatch_ceremony 99 owner/repo runner-self "$issue_meta" >/dev/null 2>&1

	local logged
	logged=$(cat "$SET_ISSUE_STATUS_LOG")

	local no_self_remove=0
	if [[ "$logged" == *"--remove-assignee runner-self"* ]]; then
		no_self_remove=1
	fi
	print_result "ceremony does not remove runner-self from assignees" "$no_self_remove"

	# But still adds runner-self via --add-assignee (idempotent in gh).
	local still_adds=1
	[[ "$logged" == *"--add-assignee runner-self"* ]] && still_adds=0
	print_result "ceremony still adds runner-self (idempotent re-assert)" "$still_adds"

	return 0
}

test_ceremony_handles_empty_assignees() {
	reset_test_state
	_install_mock_set_issue_status success
	_install_mock_set_origin_label success

	# Empty assignees array — no --remove-assignee flags should appear.
	local issue_meta='{"assignees":[]}'
	local rc=0
	_dsi_apply_dispatch_ceremony 7 owner/repo runner-self "$issue_meta" >/dev/null 2>&1 || rc=$?

	local logged
	logged=$(cat "$SET_ISSUE_STATUS_LOG")

	local rc_check=1
	[[ "$rc" -eq 0 ]] && rc_check=0
	print_result "ceremony returns 0 with empty assignees" "$rc_check"

	local no_extra_remove=0
	if [[ "$logged" == *"--remove-assignee"* ]]; then
		no_extra_remove=1
	fi
	print_result "ceremony emits no --remove-assignee for empty assignees" "$no_extra_remove"

	return 0
}

test_ceremony_handles_empty_self_login() {
	reset_test_state
	_install_mock_set_issue_status success
	_install_mock_set_origin_label success

	local issue_meta='{"assignees":[]}'
	local rc=0
	# Empty self_login → ceremony refuses + emits warning, returns 1.
	# Capture stderr to /dev/null since the warning is operator-facing.
	_dsi_apply_dispatch_ceremony 1 owner/repo "" "$issue_meta" >/dev/null 2>&1 || rc=$?

	local rc_check=1
	[[ "$rc" -eq 1 ]] && rc_check=0
	print_result "ceremony returns 1 when self_login is empty" "$rc_check" \
		"expected rc=1, got $rc"

	# Assert NO set_issue_status call was made (refuse before the gh edit).
	local call_count
	call_count=$(grep -c '^set_issue_status' "$SET_ISSUE_STATUS_LOG" 2>/dev/null || true)
	[[ "$call_count" =~ ^[0-9]+$ ]] || call_count=0
	if [[ "$call_count" -ne 0 ]]; then
		print_result "ceremony skips gh edit when self_login empty" 1 "got $call_count calls"
		return 0
	fi
	print_result "ceremony skips gh edit when self_login empty" 0

	return 0
}

test_ceremony_handles_set_issue_status_failure() {
	reset_test_state
	_install_mock_set_issue_status failure
	_install_mock_set_origin_label success

	local issue_meta='{"assignees":[]}'
	local rc=0
	_dsi_apply_dispatch_ceremony 1 owner/repo runner-self "$issue_meta" >/dev/null 2>&1 || rc=$?

	# When set_issue_status fails (e.g. gh API error), ceremony returns 1
	# but does NOT propagate set -e — caller treats it as best-effort.
	local rc_check=1
	[[ "$rc" -eq 1 ]] && rc_check=0
	print_result "ceremony returns 1 when set_issue_status fails" "$rc_check"

	return 0
}

test_no_ceremony_flag_parses_correctly() {
	reset_test_state

	# Test that the parser correctly sets _DSI_ARG_NO_CEREMONY=1 when
	# --no-ceremony is in the args, and 0 otherwise.
	local rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --no-ceremony >/dev/null 2>&1 || rc=$?
	local no_cer_flag="$_DSI_ARG_NO_CEREMONY"

	local check1=1
	[[ "$rc" -eq 0 && "$no_cer_flag" == "1" ]] && check1=0
	print_result "--no-ceremony sets _DSI_ARG_NO_CEREMONY=1" "$check1" \
		"rc=$rc no_cer=$no_cer_flag"

	# Reset and verify default is 0
	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo >/dev/null 2>&1 || rc=$?
	no_cer_flag="$_DSI_ARG_NO_CEREMONY"

	local check2=1
	[[ "$rc" -eq 0 && "$no_cer_flag" == "0" ]] && check2=0
	print_result "default _DSI_ARG_NO_CEREMONY=0 (ceremony ON)" "$check2" \
		"rc=$rc no_cer=$no_cer_flag"

	# Composes with --dry-run
	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --dry-run --no-ceremony >/dev/null 2>&1 || rc=$?
	local dry="$_DSI_ARG_DRYRUN" no_cer="$_DSI_ARG_NO_CEREMONY"

	local check3=1
	[[ "$rc" -eq 0 && "$dry" == "1" && "$no_cer" == "1" ]] && check3=0
	print_result "--dry-run and --no-ceremony compose" "$check3" \
		"rc=$rc dry=$dry no_cer=$no_cer"

	return 0
}

test_model_override_guidance_is_provider_neutral() {
	reset_test_state

	local rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --model compatibility/model-id >/dev/null 2>&1 || rc=$?
	local override_check=1
	[[ "$rc" -eq 0 && "$_DSI_ARG_MODEL" == "compatibility/model-id" ]] && override_check=0
	print_result "advanced --model compatibility override still parses" "$override_check" \
		"rc=$rc model=$_DSI_ARG_MODEL"

	local help_out
	help_out=$(_dispatch_usage)
	local help_check=1
	if [[ "$help_out" == *"Advanced compatibility override"* &&
		"$help_out" == *"tier:simple"* &&
		"$help_out" == *"tier:standard"* &&
		"$help_out" == *"tier:thinking"* &&
		"$help_out" != *"anthropic/"* &&
		"$help_out" != *"openai/"* &&
		"$help_out" != *"google/"* ]]; then
		help_check=0
	fi
	print_result "dispatch help recommends tiers without a provider pin" "$help_check" "$help_out"

	rc=0
	local error_out
	error_out=$(_dsi_parse_dispatch_args 12345 owner/repo --model --dry-run 2>&1) || rc=$?
	local error_check=1
	if [[ "$rc" -eq 2 &&
		"$error_out" == *"tier:simple"* &&
		"$error_out" == *"tier:standard"* &&
		"$error_out" == *"tier:thinking"* &&
		"$error_out" != *"anthropic/"* &&
		"$error_out" != *"openai/"* &&
		"$error_out" != *"google/"* ]]; then
		error_check=0
	fi
	print_result "missing --model error recommends tiers without a provider pin" "$error_check" \
		"rc=$rc output=$error_out"

	return 0
}

test_load_issue_meta_accepts_lowercase_open() {
	MOCK_GH_FAIL="0"
	MOCK_GH_ISSUE_STATE="open"

	local rc=0
	_dsi_load_issue_meta 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 && "$_DSI_ISSUE_TITLE" == "Mock issue" ]] && check=0
	print_result "load issue meta accepts lowercase open" "$check" \
		"expected rc=0 with title populated, got rc=$rc title=$_DSI_ISSUE_TITLE"

	return 0
}

test_agent_flag_parses_with_default() {
	reset_test_state

	local rc=0
	_dsi_parse_dispatch_args 12345 owner/repo >/dev/null 2>&1 || rc=$?
	local default_agent="$_DSI_ARG_AGENT"
	local check1=1
	[[ "$rc" -eq 0 && "$default_agent" == "Build+" ]] && check1=0
	print_result "default worker agent is Build+" "$check1" \
		"rc=$rc agent=$default_agent"

	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --agent CustomAgent >/dev/null 2>&1 || rc=$?
	local custom_agent="$_DSI_ARG_AGENT"
	local check2=1
	[[ "$rc" -eq 0 && "$custom_agent" == "CustomAgent" ]] && check2=0
	print_result "--agent overrides worker agent" "$check2" \
		"rc=$rc agent=$custom_agent"

	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --agent --dry-run >/dev/null 2>&1 || rc=$?
	local check3=1
	[[ "$rc" -eq 2 ]] && check3=0
	print_result "--agent requires a value" "$check3" "rc=$rc"

	return 0
}

test_load_issue_meta_blocks_lowercase_closed() {
	MOCK_GH_FAIL="0"
	MOCK_GH_ISSUE_STATE="closed"

	local rc=0
	_dsi_load_issue_meta 124 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "load issue meta blocks lowercase closed" "$check" \
		"expected rc=1 for closed state, got rc=$rc"

	return 0
}

test_pr_target_guard_detects_pull_request() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="1"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "PR target guard detects pull_request marker" "$check" \
		"expected rc=0 for PR-shaped issue, got rc=$rc"
	return 0
}

test_pr_target_guard_allows_plain_issue() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="0"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "PR target guard allows plain issue" "$check" \
		"expected rc=1 for plain issue, got rc=$rc"
	return 0
}

test_pr_target_guard_fails_closed_on_api_error() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="api_fail"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 2 ]] && check=0
	print_result "PR target guard reports verification errors" "$check" \
		"expected rc=2 for API failure, got rc=$rc"
	return 0
}

test_interactive_hold_guard_blocks_review_label_without_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,status:in-review" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "interactive hold guard blocks status:in-review without handoff" "$check" "rc=$rc"
	return 0
}

test_interactive_hold_guard_blocks_origin_interactive_without_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,origin:interactive" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "interactive hold guard blocks origin:interactive without handoff" "$check" "rc=$rc"
	return 0
}

test_interactive_hold_guard_allows_auto_dispatch_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,origin:interactive,auto-dispatch" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "interactive hold guard allows auto-dispatch handoff" "$check" "rc=$rc"
	return 0
}

test_interactive_hold_guard_allows_auto_dispatch_review_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,status:in-review,auto-dispatch" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "interactive hold guard allows auto-dispatch review handoff" "$check" "rc=$rc"
	return 0
}

test_maintainer_review_guard_blocks_manual_dispatch() {
	local rc=0
	local out=""
	out=$(_dsi_guard_no_maintainer_review_required "bug,needs-maintainer-review" 24354 owner/repo 2>&1) || rc=$?

	local check=1
	[[ "$rc" -eq 1 && "$out" == *"requires maintainer review"* && "$out" == *"sudo aidevops approve issue 24354 owner/repo"* ]] && check=0
	print_result "maintainer-review guard blocks manual dispatch" "$check" "rc=$rc output=$out"
	return 0
}

test_issue_author_guard_blocks_missing_label_bypass() {
	local helper_dir="" helper="" original_helper="$_DSI_APPROVAL_HELPER"
	helper_dir=$(mktemp -d)
	helper="${helper_dir}/approval-helper.sh"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "NO_APPROVAL\n"' >"$helper"
	chmod +x "$helper"
	_DSI_APPROVAL_HELPER="$helper"
	_DSI_TARGET_JSON='{"author_association":"CONTRIBUTOR","user":{"login":"reporter","type":"User"}}'
	local out="" rc=0
	out=$(_dsi_guard_issue_author_trust 28700 owner/repo 2>&1) || rc=$?
	local check=1
	[[ "$rc" -eq 1 && "$out" == *"no verified approval"* ]] && check=0
	print_result "issue-author guard blocks missing-label bypass" "$check" "rc=$rc output=$out"

	printf '%s\n' '#!/usr/bin/env bash' 'printf "VERIFIED\n"' >"$helper"
	rc=0
	_dsi_guard_issue_author_trust 28700 owner/repo >/dev/null 2>&1 || rc=$?
	check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "issue-author guard accepts verified approval" "$check" "rc=$rc"

	_DSI_TARGET_JSON='{"author_association":"OWNER","user":{"login":"owner","type":"User"}}'
	_DSI_APPROVAL_HELPER="/path/that/does/not/exist"
	rc=0
	_dsi_guard_issue_author_trust 28700 owner/repo >/dev/null 2>&1 || rc=$?
	check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "issue-author guard accepts owner without approval helper" "$check" "rc=$rc"

	_DSI_APPROVAL_HELPER="$original_helper"
	_DSI_TARGET_JSON=""
	rm -rf "$helper_dir"
	return 0
}

test_maintainer_permission_guard_blocks_manual_dispatch() {
	local rc=0
	local out=""
	out=$(_dsi_guard_no_maintainer_permission_required "bug,needs-maintainer-permissions" 24354 owner/repo 2>&1) || rc=$?

	local check=1
	[[ "$rc" -eq 1 && "$out" == *"scoped maintainer permission grant"* && "$out" == *"--request perm-"* ]] && check=0
	print_result "maintainer-permission guard blocks manual dispatch" "$check" "rc=$rc output=$out"
	return 0
}

test_permission_history_guard_requires_current_grant() {
	local helper_dir helper original_helper out rc=0
	helper_dir=$(mktemp -d)
	helper="${helper_dir}/approval-helper.sh"
	printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "${MOCK_PERMISSION_VERIFICATION:-NO_APPROVAL}"' >"$helper"
	chmod +x "$helper"
	original_helper="$_DSI_APPROVAL_HELPER"
	_DSI_APPROVAL_HELPER="$helper"
	MOCK_GH_PERMISSION_EVENTS_JSON='[[{"event":"labeled","label":{"name":"needs-maintainer-permissions"}}]]'
	export MOCK_PERMISSION_VERIFICATION="STALE_APPROVAL"
	out=$(_dsi_guard_permission_history_verified 24354 owner/repo 2>&1) || rc=$?

	local check=1
	[[ "$rc" -eq 1 && "$out" == *"without a current matching signed grant (STALE_APPROVAL)"* ]] && check=0
	print_result "permission history guard blocks stale grant" "$check" "rc=$rc output=$out"

	rc=0
	export MOCK_PERMISSION_VERIFICATION="VERIFIED"
	out=$(_dsi_guard_permission_history_verified 24354 owner/repo 2>&1) || rc=$?
	check=1
	[[ "$rc" -eq 1 && "$out" == *"bound to its original worker session and worktree"* ]] && check=0
	print_result "permission history guard rejects new worker for bound grant" "$check" "rc=$rc output=$out"

	_DSI_APPROVAL_HELPER="$original_helper"
	MOCK_GH_PERMISSION_EVENTS_JSON='[[]]'
	unset MOCK_PERMISSION_VERIFICATION
	rm -rf "$helper_dir"
	return 0
}

test_cmd_dispatch_blocks_needs_maintainer_review_before_dedup() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="0"
	MOCK_GH_ISSUE_STATE="OPEN"
	MOCK_GH_LABELS_JSON='[{"name":"needs-maintainer-review"}]'

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="/path/that/must/not/be/called"
	local out="" rc=0
	out=$(cmd_dispatch 123 owner/repo --dry-run 2>&1) || rc=$?

	local check=1
	[[ "$rc" -eq 1 && "$out" == *"requires maintainer review"* && "$out" != *"must/not/be/called"* ]] && check=0
	print_result "dispatch command blocks needs-maintainer-review before dedup" "$check" "rc=$rc output=$out"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	MOCK_GH_LABELS_JSON="[]"
	return 0
}

test_runner_login_transport_security() {
	local test_dir=""
	test_dir=$(mktemp -d)
	MOCK_GH_CALL_LOG="${test_dir}/gh-calls"
	MOCK_GH_REST_LOGIN_MODE="success"
	MOCK_GH_GRAPHQL_LOGIN_MODE="fail"

	local login="" rc=0 check=1
	login=$(_dsi_resolve_runner_login) || rc=$?
	if [[ "$rc" -eq 0 && "$login" == "runner-self" ]] &&
		! grep -Fq 'api graphql' "$MOCK_GH_CALL_LOG"; then
		check=0
	fi
	print_result "runner identity prefers authenticated REST" "$check" "rc=$rc login=$login"

	: >"$MOCK_GH_CALL_LOG"
	MOCK_GH_REST_LOGIN_MODE="fail"
	MOCK_GH_GRAPHQL_LOGIN_MODE="success"
	login=""
	rc=0
	login=$(_dsi_resolve_runner_login) || rc=$?
	check=1
	[[ "$rc" -eq 0 && "$login" == "fallback-runner" ]] && check=0
	print_result "runner identity falls back to authenticated GraphQL" "$check" "rc=$rc login=$login"

	MOCK_GH_REST_LOGIN_MODE="invalid"
	MOCK_GH_GRAPHQL_LOGIN_MODE="invalid"
	login=""
	rc=0
	login=$(_dsi_resolve_runner_login) || rc=$?
	check=1
	[[ "$rc" -eq 1 && -z "$login" ]] && check=0
	print_result "runner identity rejects malformed transport output" "$check" "rc=$rc login=$login"

	MOCK_GH_REST_LOGIN_MODE="fail"
	MOCK_GH_GRAPHQL_LOGIN_MODE="fail"
	login=""
	rc=0
	login=$(_dsi_resolve_runner_login) || rc=$?
	check=1
	[[ "$rc" -eq 1 && -z "$login" ]] && check=0
	print_result "runner identity fails closed when both transports fail" "$check" "rc=$rc login=$login"

	MOCK_GH_REST_LOGIN_MODE="success"
	MOCK_GH_GRAPHQL_LOGIN_MODE="success"
	MOCK_GH_CALL_LOG=""
	rm -rf "$test_dir"
	return 0
}

test_dedup_receives_prefetched_issue_metadata() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local metadata_log="${test_dir}/metadata.json"
	local helper="${test_dir}/dedup-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'printf "%s" "${ISSUE_META_JSON:-}" >"$MOCK_DEDUP_META_LOG"'
		printf '%s\n' 'exit 1'
	} >"$helper"
	chmod +x "$helper"

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"
	_DSI_ISSUE_META_JSON='{"number":123,"labels":[],"assignees":[],"state":"OPEN"}'
	export MOCK_DEDUP_META_LOG="$metadata_log"
	_dsi_run_dedup_check 123 owner/repo runner-self >/dev/null 2>&1

	local forwarded=""
	forwarded=$(<"$metadata_log")
	local check=1
	[[ "$_DSI_DEDUP_STATE" == "clear" && "$forwarded" == "$_DSI_ISSUE_META_JSON" ]] && check=0
	print_result "dedup child receives prefetched issue metadata" "$check" "state=$_DSI_DEDUP_STATE metadata=$forwarded"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	unset MOCK_DEDUP_META_LOG
	rm -rf "$test_dir"
	return 0
}

test_transient_dedup_retries_are_bounded() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local count_log="${test_dir}/count"
	local helper="${test_dir}/dedup-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'count=0'
		printf '%s\n' '[[ -f "$MOCK_DEDUP_COUNT_LOG" ]] && count=$(<"$MOCK_DEDUP_COUNT_LOG")'
		printf '%s\n' 'count=$((count + 1))'
		printf '%s\n' 'printf "%s\n" "$count" >"$MOCK_DEDUP_COUNT_LOG"'
		printf '%s\n' 'if ((count < 3)); then'
		printf '%s\n' '  printf "%s\n" "GUARD_UNCERTAIN (reason=gh-api-failure detail=timeout Retry-After:1)"'
		printf '%s\n' '  exit 0'
		printf '%s\n' 'fi'
		printf '%s\n' 'exit 1'
	} >"$helper"
	chmod +x "$helper"

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"
	_DSI_ISSUE_META_JSON='{"number":123,"labels":[],"assignees":[],"state":"OPEN"}'
	export MOCK_DEDUP_COUNT_LOG="$count_log"
	_dsi_run_dedup_check 123 owner/repo runner-self >/dev/null 2>&1

	local attempts=""
	attempts=$(<"$count_log")
	local check=1
	[[ "$_DSI_DEDUP_STATE" == "clear" && "$_DSI_DEDUP_ATTEMPTS" -eq 3 && "$attempts" == "3" ]] && check=0
	print_result "transient dedup retries stop after two retries" "$check" \
		"state=$_DSI_DEDUP_STATE attempts=$_DSI_DEDUP_ATTEMPTS calls=$attempts"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	unset MOCK_DEDUP_COUNT_LOG
	rm -rf "$test_dir"
	return 0
}

test_persistent_uncertainty_does_not_retry_and_checkpoints_dryrun() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local count_log="${test_dir}/count"
	local helper="${test_dir}/dedup-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'count=0'
		printf '%s\n' '[[ -f "$MOCK_DEDUP_COUNT_LOG" ]] && count=$(<"$MOCK_DEDUP_COUNT_LOG")'
		printf '%s\n' 'printf "%s\n" "$((count + 1))" >"$MOCK_DEDUP_COUNT_LOG"'
		printf '%s\n' 'printf "%s\n" "GUARD_UNCERTAIN (reason=jq-failure call=assignees-extract)"'
		printf '%s\n' 'exit 0'
	} >"$helper"
	chmod +x "$helper"

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"
	export MOCK_DEDUP_COUNT_LOG="$count_log"
	local -x AIDEVOPS_DSI_CHECKPOINT_DIR="${test_dir}/checkpoints"
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="0"
	MOCK_GH_ISSUE_STATE="OPEN"
	MOCK_GH_LABELS_JSON="[]"

	local out="" rc=0
	out=$(cmd_dispatch 123 owner/repo --dry-run 2>&1) || rc=$?
	local checkpoint_file="${AIDEVOPS_DSI_CHECKPOINT_DIR}/owner-repo-123.json"
	local checkpoint_ok=1
	if [[ -f "$checkpoint_file" ]] && jq -e \
		'.status == "recovering" and .issue == "123" and .repo == "owner/repo" and
		 .dedup_attempts == 1 and (.resume_command | contains("--dry-run")) and
		 (.resume_condition | contains("definitive clear or blocked"))' \
		"$checkpoint_file" >/dev/null; then
		checkpoint_ok=0
	fi
	local calls=""
	calls=$(<"$count_log")
	local check=1
	[[ "$rc" -eq 75 && "$calls" == "1" && "$checkpoint_ok" -eq 0 && "$out" == *"RECOVERY_CHECKPOINT_JSON="* ]] && check=0
	print_result "persistent uncertain dry-run returns 75 and persists checkpoint" "$check" \
		"rc=$rc calls=$calls checkpoint_ok=$checkpoint_ok output=$out"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	unset MOCK_DEDUP_COUNT_LOG
	rm -rf "$test_dir"
	return 0
}

test_unexpected_dedup_exit_remains_error() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local helper="${test_dir}/dedup-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'printf "%s\n" "unexpected helper failure"'
		printf '%s\n' 'exit 2'
	} >"$helper"
	chmod +x "$helper"

	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"
	_DSI_ISSUE_META_JSON='{"number":123,"labels":[],"assignees":[],"state":"OPEN"}'
	_dsi_run_dedup_check 123 owner/repo runner-self >/dev/null 2>&1

	local check=1
	[[ "$_DSI_DEDUP_STATE" == "error" && "$_DSI_DEDUP_RC" -eq 2 && "$_DSI_DEDUP_ATTEMPTS" -eq 1 ]] && check=0
	print_result "unexpected dedup exit remains an error" "$check" \
		"state=$_DSI_DEDUP_STATE rc=$_DSI_DEDUP_RC attempts=$_DSI_DEDUP_ATTEMPTS"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	rm -rf "$test_dir"
	return 0
}

test_manual_consensus_claim_outcomes() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local helper="${test_dir}/dedup-helper.sh"
	cat >"$helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "claim" ]]; then
	exit 1
fi
case "${MOCK_CLAIM_RESULT:-win}" in
win) printf '%s\n' 'CLAIM_WON: comment_id=123'; exit 0 ;;
loss) printf '%s\n' 'CLAIM_LOST'; exit 1 ;;
error) printf '%s\n' 'CLAIM_ERROR'; exit 2 ;;
esac
exit 2
EOF
	chmod +x "$helper"
	local original_dedup_helper="$_DSI_DEDUP_HELPER"
	_DSI_DEDUP_HELPER="$helper"

	local rc=0
	MOCK_CLAIM_RESULT=loss _dsi_acquire_consensus_claim 123 owner/repo runner-self >/dev/null 2>&1 || rc=$?
	local loss_ok=1
	[[ "$rc" -eq 1 && "$_DSI_CLAIM_WON" -eq 0 ]] && loss_ok=0
	print_result "manual dispatch blocks a lost consensus claim" "$loss_ok" "rc=$rc won=$_DSI_CLAIM_WON"

	rc=0
	MOCK_CLAIM_RESULT=error _dsi_acquire_consensus_claim 123 owner/repo runner-self >/dev/null 2>&1 || rc=$?
	local error_ok=1
	[[ "$rc" -eq 1 && "$_DSI_CLAIM_WON" -eq 0 ]] && error_ok=0
	print_result "manual dispatch fails closed on consensus claim error" "$error_ok" "rc=$rc won=$_DSI_CLAIM_WON"

	rc=0
	MOCK_CLAIM_RESULT=win _dsi_acquire_consensus_claim 123 owner/repo runner-self >/dev/null 2>&1 || rc=$?
	local win_ok=1
	[[ "$rc" -eq 0 && "$_DSI_CLAIM_WON" -eq 1 ]] && win_ok=0
	print_result "manual dispatch proceeds only after consensus claim win" "$win_ok" "rc=$rc won=$_DSI_CLAIM_WON"

	_DSI_CLAIM_WON=1
	_DSI_CLAIM_COMMENT_ID=123
	_dsi_release_consensus_claim 123 owner/repo runner-self test_failure >/dev/null 2>&1 || true
	local release_ok=1
	[[ "$_DSI_CLAIM_WON" -eq 0 && -z "$_DSI_CLAIM_COMMENT_ID" ]] && release_ok=0
	print_result "manual prelaunch failure clears its claim without retaining local state" "$release_ok"

	_DSI_DEDUP_HELPER="$original_dedup_helper"
	rm -rf "$test_dir"
	return 0
}

test_review_followup_validator_uncertainty_blocks_manual_dispatch() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local validator="${test_dir}/validator.sh"
	cat >"$validator" <<'EOF'
#!/usr/bin/env bash
exit 20
EOF
	chmod +x "$validator"
	local original_validator="$_DSI_VALIDATOR_HELPER"
	_DSI_VALIDATOR_HELPER="$validator"
	_DSI_ISSUE_LABELS="review-followup,source:review-scanner"
	local rc=0
	_dsi_run_required_predispatch_validator 123 owner/repo >/dev/null 2>&1 || rc=$?
	local blocked=1
	[[ "$rc" -eq 1 ]] && blocked=0
	print_result "manual review-followup dispatch fails closed on validator uncertainty" "$blocked" "rc=$rc"
	_DSI_VALIDATOR_HELPER="$original_validator"
	rm -rf "$test_dir"
	return 0
}

test_launch_worker_forwards_agent() {
	local failed=1
	if grep -Fq "cmd+=(--agent \"\$agent_name\")" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards --agent to headless runtime" "$failed"
	return 0
}

test_launch_worker_forwards_repo_contract() {
	local failed=1
	if grep -Fq "WORKER_REPO_SLUG=\"\$repo_slug\"" "$HELPER_PATH" &&
		grep -Fq "GITHUB_REPOSITORY=\"\$repo_slug\"" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards target repo contract" "$failed"
	return 0
}

test_launch_worker_forwards_github_login() {
	local failed=1
	if grep -Fq "WORKER_GITHUB_LOGIN=\"\$self_login\"" "$HELPER_PATH" &&
		grep -Fq "_dsi_launch_and_report \"\$issue_number\" \"\$repo_slug\" \"\$self_login\" \"\$session_key\"" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards dispatching GitHub login" "$failed"
	return 0
}

test_create_worktree_uses_target_repo_path() {
	local failed=1
	if grep -Fq "repo_path=\$(_dsi_repo_path_for_slug \"\$repo_slug\")" "$HELPER_PATH" &&
		grep -Fq "cd \"\$repo_path\" && AIDEVOPS_SKIP_AUTO_CLAIM=1" "$HELPER_PATH" &&
		grep -Fq "git -C \"\$repo_path\" worktree list --porcelain" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worktree creation uses target repo path" "$failed"
	return 0
}

test_create_worktree_registers_dispatch_owner() {
	local test_dir=""
	test_dir=$(mktemp -d)
	MOCK_REPO_PATH="${test_dir}/repo"
	MOCK_WORKTREE_PATH="${test_dir}/worktree"
	MOCK_DATE_UTC="20260515-123456"
	MOCK_WORKTREE_BRANCH="feature/auto-${MOCK_DATE_UTC}-gh12345"
	MOCK_GIT_WORKTREE_LIST="1"
	mkdir -p "$MOCK_REPO_PATH" "$MOCK_WORKTREE_PATH"
	REGISTER_WORKTREE_LOG="${test_dir}/register-worktree.log"
	MOCK_WORKTREE_HELPER_LOG="${test_dir}/worktree-helper.log"
	local repos_file="${test_dir}/repos.json"
	printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","default_branch":"main","pr_base_branch":"develop"}]}' >"$repos_file"
	local -x AIDEVOPS_REPOS_FILE="$repos_file"
	export MOCK_WORKTREE_HELPER_LOG
	: >"$REGISTER_WORKTREE_LOG"
	: >"$MOCK_WORKTREE_HELPER_LOG"

	local original_worktree_helper="$_DSI_WORKTREE_HELPER"
	local positional_args_ref='$*'
	_DSI_WORKTREE_HELPER="${test_dir}/worktree-helper.sh"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf "printf 'worktree-helper %%s\\n' \"%s\" >>%q\n" "$positional_args_ref" "$MOCK_WORKTREE_HELPER_LOG"
		printf '%s\n' 'exit 0'
	} >"$_DSI_WORKTREE_HELPER"
	chmod +x "$_DSI_WORKTREE_HELPER"

	local rc=0
	_dsi_create_worktree 12345 owner/repo >/dev/null 2>&1 || rc=$?

	local registered=""
	registered=$(<"$REGISTER_WORKTREE_LOG")
	local helper_call=""
	helper_call=$(<"$MOCK_WORKTREE_HELPER_LOG")
	rm -f "$REGISTER_WORKTREE_LOG" "$MOCK_WORKTREE_HELPER_LOG"
	local passed=1
	if [[ "$rc" -eq 0 && "$registered" == *"register_worktree ${MOCK_WORKTREE_PATH} ${MOCK_WORKTREE_BRANCH}"* &&
		"$registered" == *"--task 12345"* && "$registered" == *"--session dispatch-precreate-12345"* &&
		"$helper_call" == *"--base origin/develop"* && "$helper_call" == *"--issue 12345"* ]]; then
		passed=0
	fi

	_DSI_WORKTREE_HELPER="$original_worktree_helper"
	MOCK_GIT_WORKTREE_LIST="0"
	MOCK_REPO_PATH=""
	MOCK_WORKTREE_PATH=""
	MOCK_WORKTREE_BRANCH=""
	MOCK_DATE_UTC=""
	REGISTER_WORKTREE_LOG=""
	unset MOCK_WORKTREE_HELPER_LOG
	MOCK_WORKTREE_HELPER_LOG=""
	rm -rf "$test_dir"
	print_result "worktree creation registers dispatch owner metadata" "$passed" "rc=$rc registered=$registered helper=$helper_call"
	return 0
}

test_dispatch_base_ref_prefers_repo_configured_pr_base() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local repos_file="${test_dir}/repos.json"
	local repo_path="${test_dir}/repo"
	mkdir -p "$repo_path"
	printf '%s\n' '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","default_branch":"main","pr_base_branch":"develop"}]}' >"$repos_file"

	local -x AIDEVOPS_REPOS_FILE="$repos_file"
	unset AIDEVOPS_DISPATCH_BASE_REF AIDEVOPS_WORKTREE_BASE AIDEVOPS_DISPATCH_BASE_BRANCH DISPATCH_REPO_PR_BASE_BRANCH AIDEVOPS_PR_BASE_BRANCH

	local base_ref=""
	base_ref=$(_dsi_dispatch_base_ref owner/repo "$repo_path")
	local passed=1
	[[ "$base_ref" == "origin/develop" ]] && passed=0

	rm -rf "$test_dir"
	print_result "dispatch base ref uses configured PR base over default branch" "$passed" "base_ref=$base_ref"
	return 0
}

test_dispatch_base_ref_prefers_explicit_env_ref() {
	local test_dir=""
	test_dir=$(mktemp -d)
	local repo_path="${test_dir}/repo"
	mkdir -p "$repo_path"
	export AIDEVOPS_DISPATCH_BASE_REF="upstream/integration"

	local base_ref=""
	base_ref=$(_dsi_dispatch_base_ref owner/repo "$repo_path")
	local base_branch=""
	base_branch=$(_dsi_branch_from_ref "$base_ref")
	local passed=1
	[[ "$base_ref" == "upstream/integration" && "$base_branch" == "upstream/integration" ]] && passed=0

	unset AIDEVOPS_DISPATCH_BASE_REF
	rm -rf "$test_dir"
	print_result "dispatch base ref honors explicit env override" "$passed" "base_ref=$base_ref branch=$base_branch"
	return 0
}

test_create_worktree_registration_warns_on_failure() {
	local failed=1
	if grep -Fq "register_worktree \"\$_DSI_WORKTREE_PATH\" \"\$_DSI_WORKTREE_BRANCH\"" "$HELPER_PATH" &&
		grep -Fq "|| _dsi_warn \"Worktree registration failed (non-fatal)\"" "$HELPER_PATH" &&
		! grep -Fq -- "--session \"dispatch-precreate-\${issue_number}\" 2>/dev/null || true" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worktree registration failure stays visible" "$failed"
	return 0
}


test_readiness_accepts_worker_started_marker() {
	MOCK_LEDGER_RECORD=""
	local session_key="manual-cli-ready-$$"
	local runtime_log=""
	runtime_log=$(_dsi_detached_runtime_log "$session_key")
	printf '%s\n' "[lifecycle] worker_started session=${session_key}" >"$runtime_log"

	local out="" rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" /tmp/manual-ready.log 2>&1) || rc=$?
	rm -f "$runtime_log"

	local passed=1
	[[ "$rc" -eq 0 && -z "$out" ]] && passed=0
	print_result "readiness gate accepts worker_started marker" "$passed" "rc=$rc output=$out"
	return 0
}

test_readiness_rejects_live_child_without_ready_signal() {
	MOCK_LEDGER_RECORD=""
	local session_key="manual-cli-not-ready-$$"
	local runtime_log=""
	runtime_log=$(_dsi_detached_runtime_log "$session_key")
	rm -f "$runtime_log"

	local out="" rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" /tmp/manual-not-ready.log 2>&1) || rc=$?
	rm -f "$runtime_log"

	local passed=1
	[[ "$rc" -eq 1 && "$out" == *"did not reach readiness"* && "$out" == *"Runtime log:"* ]] && passed=0
	print_result "readiness gate rejects live child without ready signal" "$passed" "rc=$rc output=$out"
	return 0
}

test_readiness_rejects_ledger_without_worker_started() {
	MOCK_LEDGER_RECORD=$'ledger\t888\t/tmp/manual.log\t/tmp/aidevops-existing\tmanual-cli-12345-ledger'
	local session_key="manual-cli-ledger-only-$$"
	local runtime_log=""
	runtime_log=$(_dsi_detached_runtime_log "$session_key")
	rm -f "$runtime_log"

	local out="" rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" /tmp/manual-ledger-only.log 2>&1) || rc=$?
	rm -f "$runtime_log"
	MOCK_LEDGER_RECORD=""

	local passed=1
	[[ "$rc" -eq 1 && "$out" == *"did not reach readiness"* ]] && passed=0
	print_result "readiness gate rejects ledger without worker_started" "$passed" "rc=$rc output=$out"
	return 0
}

test_launch_report_waits_before_success_message() {
	local wait_line="" ok_line=""
	wait_line=$(grep -n '_dsi_wait_for_worker_readiness' "$HELPER_PATH" | tail -1 | cut -d: -f1)
	ok_line=$(grep -n '_dsi_ok "Worker launched"' "$HELPER_PATH" | tail -1 | cut -d: -f1)

	local passed=1
	if [[ -n "$wait_line" && -n "$ok_line" && "$wait_line" -lt "$ok_line" ]]; then
		passed=0
	fi
	print_result "launch report waits for readiness before Worker launched" "$passed" "wait_line=$wait_line ok_line=$ok_line"
	return 0
}



test_live_dispatch_detects_issue_repo() {
	MOCK_LEDGER_RECORD=""
	MOCK_PS_LINES='700 S bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key manual-cli-12345-999 --dir /tmp/aidevops-existing --title Issue #12345 --prompt-file /tmp/prompt'

	local record="" rc=0
	record=$(_dsi_find_live_dispatch 12345 owner/repo "") || rc=$?

	local found=1
	[[ "$rc" -eq 0 && "$record" == process$'\t'700$'\t'*$'\t'/tmp/aidevops-existing$'\t'manual-cli-12345-999 ]] && found=0
	print_result "live process evidence detects active issue/repo worker" "$found" "rc=$rc record=$record"
	return 0
}

test_guard_blocks_ledger_duplicate() {
	MOCK_PS_LINES=""
	MOCK_LEDGER_RECORD=$'ledger\t888\t/tmp/manual.log\t/tmp/aidevops-existing\tmanual-cli-12345-1'

	local out="" rc=0
	out=$(_dsi_guard_no_existing_dispatch 12345 owner/repo 2>&1) || rc=$?

	local blocked=1
	[[ "$rc" -eq 1 && "$out" == *"Existing PID:"* && "$out" == *"888"* && "$out" == *"Existing worktree:"* ]] && blocked=0
	print_result "duplicate guard blocks active ledger dispatch" "$blocked" "rc=$rc output=$out"
	return 0
}

test_guard_blocks_live_worktree_duplicate() {
	MOCK_LEDGER_RECORD=""
	MOCK_PS_LINES='701 S opencode run --dir /tmp/aidevops-recovery --title Issue #9999 "/full-loop Implement issue #9999"'

	local out="" rc=0
	out=$(_dsi_guard_no_existing_dispatch 12345 owner/repo /tmp/aidevops-recovery 2>&1) || rc=$?

	local blocked=1
	[[ "$rc" -eq 1 && "$out" == *"701"* && "$out" == *"/tmp/aidevops-recovery"* ]] && blocked=0
	print_result "duplicate guard blocks active worktree owner" "$blocked" "rc=$rc output=$out"
	return 0
}



test_status_reports_live_process_without_ledger() {
	MOCK_LEDGER_RECORD=""
	MOCK_PS_LINES='702 S bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key manual-cli-12345-777 --dir /tmp/aidevops-existing --title Issue #12345 --prompt-file /tmp/prompt'

	local out="" rc=0
	out=$(cmd_status 12345 owner/repo 2>&1) || rc=$?

	local active=1
	[[ "$rc" -eq 0 && "$out" == *"Active dispatch"* && "$out" == *"live process evidence"* && "$out" == *"702"* ]] && active=0
	print_result "status reports live process when ledger is missing" "$active" "rc=$rc output=$out"
	return 0
}

test_status_rejects_dead_or_reused_ledger_pid() {
	MOCK_LEDGER_RECORD=$'ledger\t888\t/tmp/manual.log\t/tmp/aidevops-existing\tmanual-cli-12345-1'
	MOCK_LIVE_PIDS=""
	MOCK_PS_LINES=""

	local out="" rc=0
	out=$(cmd_status 12345 owner/repo 2>&1) || rc=$?
	local dead_rejected=1
	[[ "$rc" -eq 0 && "$out" == *"No active dispatch"* && "$out" != *"Active dispatch"* ]] && dead_rejected=0
	print_result "status rejects a dead ledger PID despite active lease evidence" "$dead_rejected" "rc=$rc output=$out"

	MOCK_LIVE_PIDS="888"
	MOCK_PS_LINES='888 S bash /tmp/unrelated-process --session-key unrelated --dir /tmp/aidevops-existing'
	rc=0
	out=$(cmd_status 12345 owner/repo 2>&1) || rc=$?
	local reused_rejected=1
	[[ "$rc" -eq 0 && "$out" == *"No active dispatch"* && "$out" != *"Active dispatch"* ]] && reused_rejected=0
	print_result "status rejects a reused PID with mismatched worker identity" "$reused_rejected" "rc=$rc output=$out"

	MOCK_LEDGER_RECORD=""
	MOCK_LIVE_PIDS=""
	MOCK_PS_LINES=""
	return 0
}

test_status_accepts_live_identity_matched_ledger_pid() {
	MOCK_LEDGER_RECORD=$'ledger\t888\t/tmp/manual.log\t/tmp/aidevops-existing\tmanual-cli-12345-1'
	MOCK_LIVE_PIDS="888"
	MOCK_PS_LINES='888 S bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key manual-cli-12345-1 --dir /tmp/aidevops-existing --title Issue #12345'

	local out="" rc=0
	out=$(cmd_status 12345 owner/repo 2>&1) || rc=$?
	local active=1
	[[ "$rc" -eq 0 && "$out" == *"Active dispatch"* && "$out" == *"Existing session: manual-cli-12345-1"* ]] && active=0
	print_result "status accepts a live identity-matched ledger PID" "$active" "rc=$rc output=$out"

	MOCK_LEDGER_RECORD=""
	MOCK_LIVE_PIDS=""
	MOCK_PS_LINES=""
	return 0
}

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------
# IMPORTANT: the helper script we source defines `main()` for its CLI entry.
# We renamed our runner to `_run_tests` to avoid shadowing the helper's main
# (which is itself sourced but guarded behind BASH_SOURCE check). Sourcing
# re-defines main() in this shell, so a test runner named main would simply
# silently replace the helper's main and may collide with future helpers.

_run_tests() {
	SET_ISSUE_STATUS_LOG=$(mktemp)
	SET_ORIGIN_LABEL_LOG=$(mktemp)
	trap 'rm -f "$SET_ISSUE_STATUS_LOG" "$SET_ORIGIN_LABEL_LOG"' EXIT

	test_ceremony_applies_default
	test_ceremony_skip_when_self_assigned
	test_ceremony_handles_empty_assignees
	test_ceremony_handles_empty_self_login
	test_ceremony_handles_set_issue_status_failure
	test_no_ceremony_flag_parses_correctly
	test_model_override_guidance_is_provider_neutral
	test_load_issue_meta_accepts_lowercase_open
	test_load_issue_meta_blocks_lowercase_closed
	test_pr_target_guard_detects_pull_request
	test_pr_target_guard_allows_plain_issue
	test_pr_target_guard_fails_closed_on_api_error
	test_interactive_hold_guard_blocks_review_label_without_handoff
	test_interactive_hold_guard_blocks_origin_interactive_without_handoff
	test_interactive_hold_guard_allows_auto_dispatch_handoff
	test_interactive_hold_guard_allows_auto_dispatch_review_handoff
	test_maintainer_review_guard_blocks_manual_dispatch
	test_issue_author_guard_blocks_missing_label_bypass
	test_maintainer_permission_guard_blocks_manual_dispatch
	test_permission_history_guard_requires_current_grant
	test_cmd_dispatch_blocks_needs_maintainer_review_before_dedup
	test_runner_login_transport_security
	test_dedup_receives_prefetched_issue_metadata
	test_transient_dedup_retries_are_bounded
	test_persistent_uncertainty_does_not_retry_and_checkpoints_dryrun
	test_unexpected_dedup_exit_remains_error
	test_manual_consensus_claim_outcomes
	test_review_followup_validator_uncertainty_blocks_manual_dispatch
	test_agent_flag_parses_with_default
	test_launch_worker_forwards_agent
	test_launch_worker_forwards_repo_contract
	test_launch_worker_forwards_github_login
	test_create_worktree_uses_target_repo_path
	test_create_worktree_registers_dispatch_owner
	test_dispatch_base_ref_prefers_repo_configured_pr_base
	test_dispatch_base_ref_prefers_explicit_env_ref
	test_create_worktree_registration_warns_on_failure
	test_readiness_accepts_worker_started_marker
	test_readiness_rejects_live_child_without_ready_signal
	test_readiness_rejects_ledger_without_worker_started
	test_launch_report_waits_before_success_message
	test_live_dispatch_detects_issue_repo
	test_guard_blocks_ledger_duplicate
	test_guard_blocks_live_worktree_duplicate
	test_status_reports_live_process_without_ledger
	test_status_rejects_dead_or_reused_ledger_pid
	test_status_accepts_live_identity_matched_ledger_pid

	echo
	echo "======================================"
	echo "Tests run:    $TESTS_RUN"
	echo "Tests passed: $((TESTS_RUN - TESTS_FAILED))"
	echo "Tests failed: $TESTS_FAILED"
	echo "======================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

_run_tests "$@"
