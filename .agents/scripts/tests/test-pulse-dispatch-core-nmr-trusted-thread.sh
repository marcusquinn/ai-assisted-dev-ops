#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for the ever-NMR trusted maintainer-only thread exemption.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"
AUTHORITY_SCRIPT="${SCRIPT_DIR}/../shared-gh-collaborator-permission.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ISSUE_ASSOC="OWNER"
ISSUE_LOGIN="maintainer"
COMMENTS_JSON="[]"
APPROVAL_KNOWN_STATUS=""
COLLAB_PERMISSION="write"
_AIDEVOPS_GH_PERMISSION_UNKNOWN_VALUE="unknown"

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

define_helpers_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION=/ { print }
		/^_issue_thread_is_trusted_maintainer_only\(\) \{/,/^}$/ { print }
		/^_issue_actor_has_repo_write_permission\(\) \{/,/^}$/ { print }
		/^_check_nmr_approval_gate\(\) \{/,/^}$/ { print }
		/^_gh_actor_has_repo_write_authority\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT" "$AUTHORITY_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

setup_case() {
	local issue_association="$1"
	local comments_json="$2"

	TEST_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-nmr-trusted-thread)
	LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	ISSUE_ASSOC="$issue_association"
	COMMENTS_JSON="$comments_json"
	ISSUE_LOGIN="maintainer"
	APPROVAL_KNOWN_STATUS=""
	COLLAB_PERMISSION="write"
	export LOGFILE ISSUE_ASSOC ISSUE_LOGIN COMMENTS_JSON APPROVAL_KNOWN_STATUS COLLAB_PERMISSION
	return 0
}

cleanup_case() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh() {
	local command="$1"
	local endpoint="$2"
	shift 2

	if [[ "$command" != "api" ]]; then
		return 1
	fi

	case "$endpoint" in
		*/comments)
			printf '%s\n' "$COMMENTS_JSON"
			return 0
			;;
		*)
			printf '{"author_association":"%s","user":{"login":"%s"}}\n' "$ISSUE_ASSOC" "$ISSUE_LOGIN"
			return 0
			;;
	esac
}

_gh_collaborator_permission_lookup() {
	local repo_slug="$1"
	local login="$2"
	local out_var="${3:-}"
	[[ -n "$repo_slug" && -n "$login" ]] || return 2
	if [[ "$COLLAB_PERMISSION" == "fail" ]]; then
		return 2
	fi
	if [[ -n "$out_var" ]]; then
		printf -v "$out_var" '%s' "$COLLAB_PERMISSION"
	else
		printf '%s\n' "$COLLAB_PERMISSION"
	fi
	return 0
}

stderr_contains_jq_error() {
	local stderr_output="$1"
	case "$stderr_output" in
	*"parse error:"* | *"jq:"*error*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

_is_bot_generated_cleanup_issue() {
	return 1
}

issue_has_required_approval() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"
	APPROVAL_KNOWN_STATUS="$known_status"
	export APPROVAL_KNOWN_STATUS

	[[ -n "$issue_num" && -n "$slug" ]] || return 1
	if [[ "$known_status" == "false" ]]; then
		return 0
	fi
	return 1
}

notify_ever_nmr_without_approval() {
	return 0
}

test_owner_author_owner_member_comments_bypasses_historical_nmr() {
	setup_case "OWNER" '[{"author_association":"OWNER"},{"author_association":"MEMBER"}]'
	if _check_nmr_approval_gate 101 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		print_result "OWNER/MEMBER-only thread bypasses historical NMR" 1 "gate blocked; known_status=${APPROVAL_KNOWN_STATUS}"
		cleanup_case
		return 0
	fi
	if [[ "$APPROVAL_KNOWN_STATUS" == "false" ]]; then
		print_result "OWNER/MEMBER-only thread bypasses historical NMR" 0
	else
		print_result "OWNER/MEMBER-only thread bypasses historical NMR" 1 "expected known_status=false, got ${APPROVAL_KNOWN_STATUS}"
	fi
	cleanup_case
	return 0
}

test_member_author_no_comments_bypasses_historical_nmr() {
	setup_case "MEMBER" '[]'
	if _check_nmr_approval_gate 102 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		print_result "MEMBER-authored empty thread bypasses historical NMR" 1 "gate blocked; known_status=${APPROVAL_KNOWN_STATUS}"
		cleanup_case
		return 0
	fi
	if [[ "$APPROVAL_KNOWN_STATUS" == "false" ]]; then
		print_result "MEMBER-authored empty thread bypasses historical NMR" 0
	else
		print_result "MEMBER-authored empty thread bypasses historical NMR" 1 "expected known_status=false, got ${APPROVAL_KNOWN_STATUS}"
	fi
	cleanup_case
	return 0
}

test_external_comment_preserves_ever_nmr_gate() {
	setup_case "OWNER" '[{"author_association":"OWNER"},{"author_association":"CONTRIBUTOR"}]'
	if _check_nmr_approval_gate 103 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "unknown" ]]; then
			print_result "external comment preserves ever-NMR gate" 0
		else
			print_result "external comment preserves ever-NMR gate" 1 "expected known_status=unknown, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "external comment preserves ever-NMR gate" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

test_framework_actions_guidance_comment_bypasses_historical_nmr() {
	setup_case "OWNER" '[{"author_association":"CONTRIBUTOR","user":{"login":"github-actions[bot]"},"body":"<!-- nmr-hold-guidance -->\nGenerated hold guidance."}]'
	if _check_nmr_approval_gate 106 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		print_result "framework Actions hold guidance bypasses historical NMR" 1 "gate blocked; known_status=${APPROVAL_KNOWN_STATUS}"
		cleanup_case
		return 0
	fi
	if [[ "$APPROVAL_KNOWN_STATUS" == "false" ]]; then
		print_result "framework Actions hold guidance bypasses historical NMR" 0
	else
		print_result "framework Actions hold guidance bypasses historical NMR" 1 "expected known_status=false, got ${APPROVAL_KNOWN_STATUS}"
	fi
	cleanup_case
	return 0
}

test_unmarked_actions_comment_preserves_ever_nmr_gate() {
	setup_case "OWNER" '[{"author_association":"CONTRIBUTOR","user":{"login":"github-actions[bot]"},"body":"unmarked comment"}]'
	if _check_nmr_approval_gate 107 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "unknown" ]]; then
			print_result "unmarked Actions comment preserves ever-NMR gate" 0
		else
			print_result "unmarked Actions comment preserves ever-NMR gate" 1 "expected known_status=unknown, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "unmarked Actions comment preserves ever-NMR gate" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

test_active_nmr_label_preserves_gate() {
	setup_case "OWNER" '[{"author_association":"OWNER"}]'
	if _check_nmr_approval_gate 104 "owner/repo" '{"labels":[{"name":"needs-maintainer-review"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "true" ]]; then
			print_result "active NMR label preserves gate" 0
		else
			print_result "active NMR label preserves gate" 1 "expected known_status=true, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "active NMR label preserves gate" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

test_collaborator_author_does_not_bypass_historical_nmr() {
	setup_case "COLLABORATOR" '[{"author_association":"OWNER"}]'
	ISSUE_LOGIN="collaborator"
	COLLAB_PERMISSION="read"
	if _check_nmr_approval_gate 105 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "unknown" ]]; then
			print_result "COLLABORATOR author does not bypass historical NMR" 0
		else
			print_result "COLLABORATOR author does not bypass historical NMR" 1 "expected known_status=unknown, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "COLLABORATOR author does not bypass historical NMR" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

test_write_collaborator_comments_bypass_historical_nmr() {
	setup_case "OWNER" '[{"author_association":"COLLABORATOR","user":{"login":"coadmin"},"body":"<!-- ops:start — workers: skip this comment -->"}]'
	COLLAB_PERMISSION="write"
	if _check_nmr_approval_gate 108 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		print_result "write collaborator comment bypasses historical NMR" 1 "gate blocked; known_status=${APPROVAL_KNOWN_STATUS}"
		cleanup_case
		return 0
	fi
	if [[ "$APPROVAL_KNOWN_STATUS" == "false" ]]; then
		print_result "write collaborator comment bypasses historical NMR" 0
	else
		print_result "write collaborator comment bypasses historical NMR" 1 "expected known_status=false, got ${APPROVAL_KNOWN_STATUS}"
	fi
	cleanup_case
	return 0
}

test_collaborator_comment_without_login_preserves_historical_nmr() {
	setup_case "OWNER" '[{"author_association":"COLLABORATOR","body":"missing identity"}]'
	if _check_nmr_approval_gate 110 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "unknown" ]]; then
			print_result "COLLABORATOR comment without login preserves historical NMR" 0
		else
			print_result "COLLABORATOR comment without login preserves historical NMR" 1 "expected known_status=unknown, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "COLLABORATOR comment without login preserves historical NMR" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

test_collaborator_permission_failure_preserves_historical_nmr() {
	setup_case "OWNER" '[{"author_association":"COLLABORATOR","user":{"login":"coadmin"},"body":"lookup fails"}]'
	COLLAB_PERMISSION="fail"
	if _check_nmr_approval_gate 111 "owner/repo" '{"labels":[{"name":"auto-dispatch"}]}'; then
		if [[ "$APPROVAL_KNOWN_STATUS" == "unknown" ]]; then
			print_result "COLLABORATOR permission failure preserves historical NMR" 0
		else
			print_result "COLLABORATOR permission failure preserves historical NMR" 1 "expected known_status=unknown, got ${APPROVAL_KNOWN_STATUS}"
		fi
		cleanup_case
		return 0
	fi
	print_result "COLLABORATOR permission failure preserves historical NMR" 1 "gate unexpectedly allowed dispatch"
	cleanup_case
	return 0
}

test_comment_jq_parse_errors_remain_visible() {
	setup_case "OWNER" '{not-json'
	local stderr_file="${TEST_ROOT}/jq-stderr.log"

	if _issue_thread_is_trusted_maintainer_only 109 "owner/repo" 2>"$stderr_file"; then
		print_result "comment jq parse errors remain visible" 1 "trusted-thread helper unexpectedly accepted malformed comments JSON"
		cleanup_case
		return 0
	fi

	local stderr_output
	stderr_output=$(<"$stderr_file")
	if stderr_contains_jq_error "$stderr_output"; then
		print_result "comment jq parse errors remain visible" 0
	else
		print_result "comment jq parse errors remain visible" 1 "expected jq error on stderr, got: ${stderr_output:-<empty>}"
	fi
	cleanup_case
	return 0
}

test_comment_jq_error_matcher_handles_jq_versions() {
	if ! stderr_contains_jq_error 'parse error: Invalid numeric literal at line 1, column 5'; then
		print_result "comment jq error matcher handles jq versions" 1 "did not match jq 1.6 parse error output"
		return 0
	fi
	if ! stderr_contains_jq_error 'jq: error (at <stdin>:1): Invalid numeric literal at line 1, column 5'; then
		print_result "comment jq error matcher handles jq versions" 1 "did not match jq 1.7 error output"
		return 0
	fi
	if ! stderr_contains_jq_error 'jq: 1 compile error'; then
		print_result "comment jq error matcher handles jq versions" 1 "did not match jq compile error output"
		return 0
	fi
	if stderr_contains_jq_error 'bash: unrelated system error'; then
		print_result "comment jq error matcher handles jq versions" 1 "matched unrelated stderr error output"
		return 0
	fi
	print_result "comment jq error matcher handles jq versions" 0
	return 0
}

main() {
	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_owner_author_owner_member_comments_bypasses_historical_nmr
	test_member_author_no_comments_bypasses_historical_nmr
	test_external_comment_preserves_ever_nmr_gate
	test_framework_actions_guidance_comment_bypasses_historical_nmr
	test_unmarked_actions_comment_preserves_ever_nmr_gate
	test_active_nmr_label_preserves_gate
	test_collaborator_author_does_not_bypass_historical_nmr
	test_write_collaborator_comments_bypass_historical_nmr
	test_collaborator_comment_without_login_preserves_historical_nmr
	test_collaborator_permission_failure_preserves_historical_nmr
	test_comment_jq_parse_errors_remain_visible
	test_comment_jq_error_matcher_handles_jq_versions

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
