#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Unit tests for t2016 triage failure escalation helpers in
# pulse-ancillary-dispatch.sh and its focused sub-libraries:
#   - _ensure_triage_failed_label (label provisioning)
#   - _post_triage_escalation_comment (maintainer-visible escalation)
#
# Uses the same harness style as test-pulse-wrapper-ever-nmr-cache.sh:
# mocked `gh`, isolated HOME, marker files to assert call behaviour.

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
GH_CALL_LOG=""
LOGFILE=""
# Mock behaviour knobs — tests set these before exercising helpers.
MOCK_COMMENTS_MARKER_COUNT=0
MOCK_COMMENT_EXIT=0
MOCK_LABEL_CREATE_EXIT=0

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/agents/scripts"
	LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	: >"$LOGFILE"
	GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_CALL_LOG"
	# Reset mock knobs.
	MOCK_COMMENTS_MARKER_COUNT=0
	MOCK_COMMENT_EXIT=0
	MOCK_LABEL_CREATE_EXIT=0
	return 0
}

teardown_test_env() {
	export HOME="${ORIGINAL_HOME}"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Stub the t2393 comment wrappers so _post_triage_escalation_comment's
# `gh_issue_comment` call reaches the test's gh mock. The real wrappers live
# in shared-constants.sh, which this test doesn't source — it loads only the
# focused ancillary orchestrator. Delegating
# to `gh issue comment` preserves the pre-t2393 test contract.
# shellcheck disable=SC2317
gh_issue_comment() { gh issue comment "$@" && return 0 || return 1; }
# shellcheck disable=SC2317
gh_pr_comment() { gh pr comment "$@" && return 0 || return 1; }
export -f gh_issue_comment gh_pr_comment

# Mock `gh` that records every call and serves canned responses
# based on the MOCK_* knobs.
gh() {
	printf '%s\n' "$*" >>"$GH_CALL_LOG"
	case "${1:-}" in
	api)
		# API call: comments listing. Return marker count as JSON int.
		printf '%d\n' "$MOCK_COMMENTS_MARKER_COUNT"
		return 0
		;;
	label)
		# `gh label create ...` — honour MOCK_LABEL_CREATE_EXIT.
		return "$MOCK_LABEL_CREATE_EXIT"
		;;
	issue)
		if [[ "${2:-}" == "comment" ]]; then
			return "$MOCK_COMMENT_EXIT"
		fi
		return 0
		;;
	esac
	return 0
}
export -f gh

# Load the focused production sub-library without booting the whole
# pulse-wrapper runtime.
load_helpers_under_test() {
	local src="${AIDEVOPS_SOURCE:-$HOME/Git/aidevops-bugfix-t2016-triage-cache-gate/.agents/scripts/pulse-ancillary-dispatch.sh}"
	if [[ ! -f "$src" ]]; then
		# Fallback: derive from this test file's location.
		local here
		here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
		src="${here}/../pulse-ancillary-dispatch.sh"
	fi
	if [[ ! -f "$src" ]]; then
		printf 'ERROR: cannot locate pulse-ancillary-dispatch.sh (tried %s)\n' "$src" >&2
		exit 2
	fi
	# shellcheck disable=SC1090  # production sub-library path is runtime-resolved
	source "$src"
	return 0
}

# ------------------------------ Tests ------------------------------

test_ensure_label_invokes_gh_label_create() {
	setup_test_env
	load_helpers_under_test
	_ensure_triage_failed_label "owner/repo"
	if grep -q 'label create triage-failed --repo owner/repo' "$GH_CALL_LOG"; then
		print_result "_ensure_triage_failed_label calls gh label create" 0
	else
		print_result "_ensure_triage_failed_label calls gh label create" 1 \
			"gh call log did not contain 'label create triage-failed'"
	fi
	teardown_test_env
}

test_ensure_label_uses_force_flag() {
	setup_test_env
	load_helpers_under_test
	_ensure_triage_failed_label "owner/repo"
	if grep -q -- '--force' "$GH_CALL_LOG"; then
		print_result "_ensure_triage_failed_label passes --force" 0
	else
		print_result "_ensure_triage_failed_label passes --force" 1 \
			"gh label create was called without --force"
	fi
	teardown_test_env
}

test_ensure_label_is_noop_on_empty_slug() {
	setup_test_env
	load_helpers_under_test
	_ensure_triage_failed_label ""
	if [[ ! -s "$GH_CALL_LOG" ]]; then
		print_result "_ensure_triage_failed_label is a no-op on empty slug" 0
	else
		print_result "_ensure_triage_failed_label is a no-op on empty slug" 1 \
			"gh was called when slug was empty"
	fi
	teardown_test_env
}

test_escalation_posts_comment_with_marker() {
	setup_test_env
	load_helpers_under_test
	MOCK_COMMENTS_MARKER_COUNT=0
	_post_triage_escalation_comment "18428" "owner/repo" "no-review-header" 1 72233
	# The mock records the full gh args; posting happens via `gh issue comment`.
	if grep -q '^issue comment 18428 --repo owner/repo --body-file' "$GH_CALL_LOG"; then
		print_result "_post_triage_escalation_comment invokes gh issue comment" 0
	else
		print_result "_post_triage_escalation_comment invokes gh issue comment" 1 \
			"gh call log did not contain expected 'issue comment' invocation"
	fi
	teardown_test_env
}

test_escalation_is_idempotent_when_marker_present() {
	setup_test_env
	load_helpers_under_test
	MOCK_COMMENTS_MARKER_COUNT=1
	_post_triage_escalation_comment "18428" "owner/repo" "no-review-header" 1 72233
	# Should have checked via gh api, but NOT called gh issue comment.
	if ! grep -q '^issue comment' "$GH_CALL_LOG"; then
		print_result "_post_triage_escalation_comment skips when marker present" 0
	else
		print_result "_post_triage_escalation_comment skips when marker present" 1 \
			"gh issue comment was called despite existing marker"
	fi
	# And the log should say "skipping (idempotent)".
	if grep -q 'idempotent' "$LOGFILE"; then
		print_result "_post_triage_escalation_comment logs idempotency skip" 0
	else
		print_result "_post_triage_escalation_comment logs idempotency skip" 1 \
			"LOGFILE missing 'idempotent' marker"
	fi
	teardown_test_env
}

test_escalation_is_noop_on_empty_args() {
	setup_test_env
	load_helpers_under_test
	_post_triage_escalation_comment "" "owner/repo" "no-review-header" 1 0
	_post_triage_escalation_comment "18428" "" "no-review-header" 1 0
	if [[ ! -s "$GH_CALL_LOG" ]]; then
		print_result "_post_triage_escalation_comment is a no-op on empty args" 0
	else
		print_result "_post_triage_escalation_comment is a no-op on empty args" 1 \
			"gh was called with empty issue/slug"
	fi
	teardown_test_env
}

test_escalation_body_contains_recovery_instructions() {
	setup_test_env
	load_helpers_under_test
	MOCK_COMMENTS_MARKER_COUNT=0
	# Capture the body-file path from the gh call and read its contents.
	# The mock doesn't actually write to disk, but _post_triage_escalation_comment
	# creates the temp file via mktemp and rm's it at the end. So we need to
	# hook gh to copy the body-file BEFORE it's removed. Easiest: redefine
	# gh for this one test to cp the body-file to a known location.
	local captured="${TEST_ROOT}/captured-body.md"
	gh() {
		printf '%s\n' "$*" >>"$GH_CALL_LOG"
		if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
			# Find --body-file <path> in the arg list.
			local i=0
			local args=("$@")
			while [[ $i -lt ${#args[@]} ]]; do
				if [[ "${args[$i]}" == "--body-file" ]]; then
					cp "${args[$((i + 1))]}" "$captured" 2>/dev/null || true
					break
				fi
				i=$((i + 1))
			done
			return "$MOCK_COMMENT_EXIT"
		fi
		case "${1:-}" in
		api)
			printf '%d\n' "$MOCK_COMMENTS_MARKER_COUNT"
			return 0
			;;
		label) return "$MOCK_LABEL_CREATE_EXIT" ;;
		esac
		return 0
	}
	export -f gh
	_post_triage_escalation_comment "18428" "owner/repo" "no-review-header" 1 72233
	if [[ ! -f "$captured" ]]; then
		print_result "escalation body is written to a temp file" 1 "no captured body"
		teardown_test_env
		return 0
	fi
	local ok=0
	grep -q '<!-- triage-escalation -->' "$captured" || ok=1
	grep -q 'no-review-header' "$captured" || ok=1
	grep -q 'rm -f' "$captured" || ok=1
	grep -q 'remove-label triage-failed' "$captured" || ok=1
	grep -q '72233' "$captured" || ok=1
	if [[ $ok -eq 0 ]]; then
		print_result "escalation body contains marker, reason, and recovery steps" 0
	else
		print_result "escalation body contains marker, reason, and recovery steps" 1 \
			"one of: marker, reason, recovery command, byte count was missing"
	fi
	teardown_test_env
}

main() {
	test_ensure_label_invokes_gh_label_create
	test_ensure_label_uses_force_flag
	test_ensure_label_is_noop_on_empty_slug
	test_escalation_posts_comment_with_marker
	test_escalation_is_idempotent_when_marker_present
	test_escalation_is_noop_on_empty_args
	test_escalation_body_contains_recovery_instructions

	echo ""
	echo "Results: ${TESTS_RUN} tests, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
