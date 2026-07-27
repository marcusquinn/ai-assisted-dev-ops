#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for approval-helper.sh issue lock REST fallback handling.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0
LAST_OUTPUT=""
LAST_RC=0

pass() {
	local name="$1"
	printf '  PASS: %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf '  FAIL: %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '    %s\n' "$detail"
	fi
	FAIL=$((FAIL + 1))
	return 0
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$name"
	else
		fail "$name" "expected '${expected}', got '${actual}'"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing '${needle}'"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected '${needle}'"
	fi
	return 0
}

run_case() {
	local name="$1"
	local script="$2"
	local expected_rc="$3"
	local output=""
	local rc=0

	output=$(APPROVAL_HELPER_UNDER_TEST="$PARENT_DIR/approval-helper.sh" bash -c "$script" 2>&1) || rc=$?
	LAST_OUTPUT="$output"
	LAST_RC=$rc
	assert_eq "$name rc" "$expected_rc" "$rc"
	return 0
}

printf 'Test: approval-helper REST issue-lock fallback\n'
printf '==============================================\n\n'

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "lock helper treats REST 204 as success" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_rest_should_fallback() { return 0; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local arg3="${3:-}"
		local arg4="${4:-}"
		if [[ "$arg1" == "issue" && "$arg2" == "lock" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "-X" && "$arg3" == "PUT" && "$arg4" == "/repos/marcusquinn/aidevops/issues/123/lock" ]]; then return 0; fi
		return 1
	}
	_approval_lock_issue 123 marcusquinn/aidevops
' 0
assert_contains "lock helper logs REST fallback" "$LAST_OUTPUT" "falling back to REST for issue lock"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "REST 204 lock fallback succeeds" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_rest_should_fallback() { return 0; }
	gh_issue_edit_safe() { return 0; }
	gh_issue_view() { printf "bug,auto-dispatch"; return 0; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local arg3="${3:-}"
		local arg4="${4:-}"
		if [[ "$arg1" == "api" && "$arg2" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "$arg1" == "issue" && "$arg2" == "lock" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "-X" && "$arg3" == "PUT" && "$arg4" == "/repos/marcusquinn/aidevops/issues/123/lock" ]]; then return 0; fi
		if [[ "$arg1" == "api" && "$arg2" == "/repos/marcusquinn/aidevops/issues/123" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"auto-dispatch\"}],\"assignees\":[{\"login\":\"marcusquinn\"}],\"locked\":true}"
			return 0
		fi
		return 1
	}
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops
' 0
assert_contains "successful fallback reports locked state" "$LAST_OUTPUT" "Issue #123 locked"
assert_not_contains "successful fallback does not print false lock error" "$LAST_OUTPUT" "Failed to lock issue"
assert_not_contains "successful fallback does not print advisory lock failure" "$LAST_OUTPUT" "Approval advisory lock failure"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "PR-backed issue lock falls back to REST without GraphQL fallback" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_rest_should_fallback() { return 1; }
	gh_issue_edit_safe() { return 0; }
	gh_issue_view() { printf "bug,auto-dispatch"; return 0; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local arg3="${3:-}"
		local arg4="${4:-}"
		if [[ "$arg1" == "api" && "$arg2" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "$arg1" == "issue" && "$arg2" == "lock" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "-X" && "$arg3" == "PUT" && "$arg4" == "/repos/marcusquinn/aidevops/issues/2417/lock" ]]; then return 0; fi
		if [[ "$arg1" == "api" && "$arg2" == "/repos/marcusquinn/aidevops/issues/2417" ]]; then
			printf "%s" "{\"labels\":[{\"name\":\"auto-dispatch\"}],\"assignees\":[{\"login\":\"marcusquinn\"}],\"locked\":true}"
			return 0
		fi
		return 1
	}
	_approval_apply_issue_lifecycle_updates 2417 marcusquinn/aidevops
' 0
assert_contains "PR-backed issue fallback reports locked state" "$LAST_OUTPUT" "Issue #2417 locked"
assert_not_contains "PR-backed issue fallback avoids advisory failure" "$LAST_OUTPUT" "Approval advisory lock failure"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "PR approval locks conversation with gh pr lock" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_rest_should_fallback() { return 1; }
	gh_pr_comment() { return 0; }
	pr_edit_trace=$(mktemp)
	gh_pr_edit_safe() { printf "PR_EDIT %s\n" "$*" >"$pr_edit_trace"; return 0; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		if [[ "$arg1" == "pr" && "$arg2" == "lock" ]]; then return 0; fi
		if [[ "$arg1" == "api" && "$arg2" == "/repos/marcusquinn/aidevops/issues/456" ]]; then
			printf "%s" "{\"locked\":true}"
			return 0
		fi
		return 1
	}
	_post_issue_approval_updates pr 456 marcusquinn/aidevops || exit 1
	cat "$pr_edit_trace"
	rm -f "$pr_edit_trace"
' 0
assert_contains "PR approval clears live NMR label" "$LAST_OUTPUT" "PR_EDIT 456 --repo marcusquinn/aidevops --remove-label needs-maintainer-review"
assert_contains "PR approval reports real conversation lock" "$LAST_OUTPUT" "PR #456 NMR hold cleared and conversation locked"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "conversation lock verification reuses provided issue JSON" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	gh() {
		return 1
	}
	_approval_verify_conversation_locked pr 456 marcusquinn/aidevops "{\"locked\":true}"
' 0

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "PR approval REST fallback locks conversation" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_rest_should_fallback() { return 1; }
	gh_pr_comment() { return 0; }
	pr_edit_trace=$(mktemp)
	gh_pr_edit_safe() { printf "PR_EDIT %s\n" "$*" >"$pr_edit_trace"; return 0; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local arg3="${3:-}"
		local arg4="${4:-}"
		if [[ "$arg1" == "pr" && "$arg2" == "lock" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "-X" && "$arg3" == "PUT" && "$arg4" == "/repos/marcusquinn/aidevops/issues/456/lock" ]]; then return 0; fi
		if [[ "$arg1" == "api" && "$arg2" == "/repos/marcusquinn/aidevops/issues/456" ]]; then
			printf "%s" "{\"locked\":true}"
			return 0
		fi
		return 1
	}
	_post_issue_approval_updates pr 456 marcusquinn/aidevops || exit 1
	cat "$pr_edit_trace"
	rm -f "$pr_edit_trace"
' 0
assert_contains "PR approval fallback clears live NMR label" "$LAST_OUTPUT" "PR_EDIT 456 --repo marcusquinn/aidevops --remove-label needs-maintainer-review"
assert_contains "PR approval fallback reports real lock" "$LAST_OUTPUT" "PR #456 NMR hold cleared and conversation locked"
assert_not_contains "PR approval fallback avoids advisory failure" "$LAST_OUTPUT" "Approval advisory lock failure"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "PR label-clear failure blocks approval completion" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_lock_pr() { return 0; }
	gh_pr_edit_safe() { return 1; }
	_post_issue_approval_updates pr 456 marcusquinn/aidevops
' 1
assert_contains "PR label-clear failure is explicit" "$LAST_OUTPUT" "Failed to clear needs-maintainer-review on PR #456 after approval"
assert_not_contains "PR label-clear failure suppresses success" "$LAST_OUTPUT" "NMR hold cleared and conversation locked"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "genuine lock failure is distinguished" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_rest_should_fallback() { return 0; }
	gh_issue_edit_safe() { return 0; }
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local arg3="${3:-}"
		if [[ "$arg1" == "api" && "$arg2" == "user" ]]; then printf "marcusquinn"; return 0; fi
		if [[ "$arg1" == "issue" && "$arg2" == "lock" ]]; then return 1; fi
		if [[ "$arg1" == "api" && "$arg2" == "-X" && "$arg3" == "PUT" ]]; then return 22; fi
		return 1
	}
	_approval_apply_issue_lifecycle_updates 123 marcusquinn/aidevops
' 1
assert_contains "genuine lock failure names advisory lock path" "$LAST_OUTPUT" "Approval advisory lock failure"
assert_not_contains "genuine lock failure is not mislabeled as label failure" "$LAST_OUTPUT" "Failed to update approval labels/assignee"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "post-approval protection failure blocks final success" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_number_arg() { return 0; }
	_require_interactive_root() { return 0; }
	_approval_private_key_path() { printf "mock-key"; return 0; }
	_require_approval_key() { return 0; }
	_require_gh_auth() { return 0; }
	_resolve_slug_or_fail() { local slug="${1:-}"; printf "%s" "$slug"; return 0; }
	_validate_approval_target_kind() { return 0; }
	_fetch_target_title() { printf "Mock issue"; return 0; }
	_confirm_approval() { return 0; }
	approval_snapshot_v2_payload() { printf "%s" "{\"schema\":\"aidevops-approval/v2\"}"; return 0; }
	_sign_approval_payload() { local payload="$1"; local actual_key="$2"; local sig_file="$3"; : "$payload" "$actual_key"; printf "mock-signature" >"$sig_file"; return 0; }
	gh_issue_comment() { return 0; }
	cmd_verify() { printf "VERIFIED"; return 0; }
	_post_issue_approval_updates() { return 1; }
	_kick_pulse_after_approval() { printf "SHOULD_NOT_KICK"; return 0; }
	_approve_target issue 123 marcusquinn/aidevops
' 1
assert_contains "post-approval failure suppresses final success" "$LAST_OUTPUT" "post-approval protection updates did not reach the required state"
assert_not_contains "post-approval failure does not print success" "$LAST_OUTPUT" "Issue #123 approved and signed"
assert_not_contains "post-approval failure does not kick pulse" "$LAST_OUTPUT" "SHOULD_NOT_KICK"

# GH#28717: target reconciliation accepts only the current authenticated actor's
# signed comment when that actor has maintainer-equivalent authority.
# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "current OWNER approval author is trusted" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_comment_has_required_authority marcusquinn/aidevops marcusquinn marcusquinn User OWNER
' 0

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "different approval author is rejected" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_comment_has_required_authority marcusquinn/aidevops marcusquinn another-maintainer User OWNER
' 1

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "bot approval author is rejected" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_approval_comment_has_required_authority marcusquinn/aidevops github-actions github-actions Bot OWNER
' 1

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "write collaborator approval author is trusted" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	gh() {
		local command="${1:-}"
		local endpoint="${2:-}"
		if [[ "$command" == "api" && "$endpoint" == "repos/marcusquinn/aidevops/collaborators/trusted-collab/permission" ]]; then
			printf "write\n"
			return 0
		fi
		return 1
	}
	_approval_comment_has_required_authority marcusquinn/aidevops trusted-collab trusted-collab User COLLABORATOR
' 0

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "unverifiable collaborator approval author fails closed" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	gh() { return 1; }
	_approval_comment_has_required_authority marcusquinn/aidevops trusted-collab trusted-collab User COLLABORATOR
' 2

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "issue recovery reasserts NMR through the issue lifecycle writer" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	gh_issue_edit_safe() { printf "%s\n" "$*"; return 0; }
	_approval_restore_nmr_hold issue 123 marcusquinn/aidevops
' 0
assert_contains "issue recovery reasserts the conservative label" "$LAST_OUTPUT" "--add-label needs-maintainer-review"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "PR recovery reasserts NMR through the PR lifecycle writer" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	gh_pr_edit_safe() { printf "%s\n" "$*"; return 0; }
	_approval_restore_nmr_hold pr 456 marcusquinn/aidevops
' 0
assert_contains "PR recovery reasserts the conservative label" "$LAST_OUTPUT" "--add-label needs-maintainer-review"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "reconcile re-verifies authority immediately before issue lifecycle restore" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	trace=$(mktemp)
	_require_number_arg() { return 0; }
	_resolve_slug_or_fail() { local slug="${1:-}"; printf "%s" "$slug"; return 0; }
	_approval_fetch_issue_json() {
		local target_number="${1:-}"
		local slug="${2:-}"
		: "$target_number" "$slug"
		printf "%s" "{\"state\":\"open\",\"labels\":[{\"name\":\"needs-maintainer-review\"}]}"
		return 0
	}
	cmd_verify() {
		local target_type="${1:-}"
		local target_number="${2:-}"
		local slug="${3:-}"
		local authority_flag="${4:-}"
		printf "VERIFY %s %s %s %s\n" "$target_type" "$target_number" "$slug" "$authority_flag" >>"$trace"
		printf "VERIFIED\n"
		return 0
	}
	_post_issue_approval_updates() {
		local target_type="${1:-}"
		local target_number="${2:-}"
		local slug="${3:-}"
		printf "APPLY %s %s %s\n" "$target_type" "$target_number" "$slug" >>"$trace"
		return 0
	}
	rc=0
	cmd_reconcile issue 123 marcusquinn/aidevops || rc=$?
	cat "$trace"
	rm -f "$trace"
	exit "$rc"
' 0
assert_contains "reconcile requires authenticated approval authority" "$LAST_OUTPUT" "VERIFY issue 123 marcusquinn/aidevops --require-authority"
assert_contains "reconcile restores the issue-specific lifecycle" "$LAST_OUTPUT" "APPLY issue 123 marcusquinn/aidevops"
assert_contains "reconcile reports success" "$LAST_OUTPUT" "RECONCILED"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "partial reconciliation failure reasserts NMR before returning" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	trace=$(mktemp)
	_require_number_arg() { return 0; }
	_resolve_slug_or_fail() { local slug="${1:-}"; printf "%s" "$slug"; return 0; }
	_approval_fetch_issue_json() {
		local target_number="${1:-}"
		local slug="${2:-}"
		: "$target_number" "$slug"
		printf "%s" "{\"state\":\"open\",\"labels\":[{\"name\":\"needs-maintainer-review\"}]}"
		return 0
	}
	cmd_verify() { printf "VERIFIED\n"; return 0; }
	_post_issue_approval_updates() { return 1; }
	_approval_restore_nmr_hold() {
		local target_type="${1:-}"
		local target_number="${2:-}"
		local slug="${3:-}"
		printf "RESTORE %s %s %s\n" "$target_type" "$target_number" "$slug" >>"$trace"
		return 0
	}
	rc=0
	cmd_reconcile issue 123 marcusquinn/aidevops || rc=$?
	cat "$trace"
	rm -f "$trace"
	exit "$rc"
' 8
assert_contains "partial reconciliation failure reasserts the exact issue hold" "$LAST_OUTPUT" "RESTORE issue 123 marcusquinn/aidevops"
assert_contains "partial reconciliation failure remains explicit" "$LAST_OUTPUT" "UPDATE_FAILED"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "reconcile leaves an unchanged approved target as a no-op" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_number_arg() { return 0; }
	_resolve_slug_or_fail() { local slug="${1:-}"; printf "%s" "$slug"; return 0; }
	_approval_fetch_issue_json() {
		local target_number="${1:-}"
		local slug="${2:-}"
		: "$target_number" "$slug"
		printf "%s" "{\"state\":\"open\",\"labels\":[{\"name\":\"auto-dispatch\"}]}"
		return 0
	}
	cmd_verify() { printf "SHOULD_NOT_VERIFY\n"; return 1; }
	_post_issue_approval_updates() { printf "SHOULD_NOT_APPLY\n"; return 1; }
	cmd_reconcile issue 123 marcusquinn/aidevops
' 3
assert_contains "no-op reconciliation reports absent restored hold" "$LAST_OUTPUT" "NO_NMR"
assert_not_contains "no-op reconciliation skips signature work" "$LAST_OUTPUT" "SHOULD_NOT_VERIFY"
assert_not_contains "no-op reconciliation skips lifecycle mutation" "$LAST_OUTPUT" "SHOULD_NOT_APPLY"

# shellcheck disable=SC2016  # literal script is evaluated in the child bash.
run_case "reconcile preserves NMR when authority verification fails" '
	set -uo pipefail
	# shellcheck disable=SC1090
	source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
	_require_number_arg() { return 0; }
	_resolve_slug_or_fail() { local slug="${1:-}"; printf "%s" "$slug"; return 0; }
	_approval_fetch_issue_json() {
		local target_number="${1:-}"
		local slug="${2:-}"
		: "$target_number" "$slug"
		printf "%s" "{\"state\":\"open\",\"pull_request\":{},\"labels\":[{\"name\":\"needs-maintainer-review\"}]}"
		return 0
	}
	cmd_verify() { printf "UNTRUSTED_APPROVAL\n"; return 7; }
	_post_issue_approval_updates() { printf "SHOULD_NOT_APPLY\n"; return 1; }
	cmd_reconcile pr 456 marcusquinn/aidevops
' 7
assert_contains "failed authority remains explicit" "$LAST_OUTPUT" "UNTRUSTED_APPROVAL"
assert_not_contains "failed authority never mutates PR lifecycle" "$LAST_OUTPUT" "SHOULD_NOT_APPLY"

printf '\n==============================================\n'
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
