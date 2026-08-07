#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 2
TEST_ROOT=""
TEST_MODE="normal"
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local status="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$detail" ]] && printf '  %s\n' "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

capture_body_file_arg() {
	local previous=""
	local argument=""
	for argument in "$@"; do
		if [[ "$previous" == "--body-file" ]]; then
			cp "$argument" "${TEST_ROOT}/captured-body"
			return $?
		fi
		previous="$argument"
	done
	return 1
}

capture_rest_body_field() {
	local argument=""
	for argument in "$@"; do
		case "$argument" in
		commit_message=@*)
			cp "${argument#commit_message=@}" "${TEST_ROOT}/captured-body"
			return $?
			;;
		esac
	done
	return 1
}

gh() {
	local command="${1:-}"
	local subcommand="${2:-}"
	if [[ "$command" == "pr" && "$subcommand" == "view" && "$*" == *"--json title,commits"* ]]; then
		printf '%s\n' '{"title":"GH#29733: fix: preserve explicit merge bodies","commits":[{"messageHeadline":"fix: preserve explicit merge bodies"}]}'
		return 0
	fi
	if [[ "$command" == "pr" && "$subcommand" == "merge" ]]; then
		if [[ "$TEST_MODE" != "rest" ]]; then
			capture_body_file_arg "$@" || true
		fi
		case "$TEST_MODE" in
		admin)
			if [[ "$*" != *"--admin"* ]]; then
				printf '%s\n' 'At least 1 approving review is required' >&2
				return 1
			fi
			;;
		rest)
			printf '%s\n' 'GraphQL: API rate limit already exceeded (rateLimitExceeded)' >&2
			return 1
			;;
		esac
		return 0
	fi
	if [[ "$command" == "api" && "$*" == *"pulls/42/merge"* ]]; then
		capture_rest_body_field "$@" || return 1
		printf '%s\n' '{"merged":true}'
		return 0
	fi
	return 0
}

cmd_pre_merge_gate() {
	return 0
}

setup_subject() {
	TEST_ROOT=$(mktemp -d)
	trap teardown EXIT
	SCRIPT_DIR="$AGENTS_SCRIPTS_DIR"
	# shellcheck source=../shared-constants.sh
	source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh"
	# shellcheck source=../full-loop-helper-merge.sh
	source "${AGENTS_SCRIPTS_DIR}/full-loop-helper-merge.sh"
	_merge_resolve_match_head() {
		printf '%s\n' 'fixture-head-sha'
		return 0
	}
	_merge_review_state_still_clear() {
		return 0
	}
	_merge_guard_admin_merge_maintainer_review() {
		return 0
	}
	_merge_guard_prospective_todo() {
		return 0
	}
	return 0
}

write_fixture_body() {
	local body_file="$1"
	printf '%s\n' \
		'Aidevops-Signature: fixture' \
		'Aidevops-Release-Aggregator-PR: 42' \
		'Aidevops-Release-Aggregates: 29721@d53b458a6ee82e3dccd922c3791b9f9f088efa8f' >"$body_file"
	return 0
}

assert_transport_preserves_body() {
	local mode="$1"
	local label="$2"
	local body_file="${TEST_ROOT}/merge-body"
	local rc=0
	TEST_MODE="$mode"
	rm -f "${TEST_ROOT}/captured-body"
	write_fixture_body "$body_file"
	_merge_execute 42 testorg/testrepo --squash 0 0 "$body_file" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 && -f "${TEST_ROOT}/captured-body" ]] && cmp -s "$body_file" "${TEST_ROOT}/captured-body"; then
		print_result "$label preserves exact body bytes" 0
	else
		print_result "$label preserves exact body bytes" 1 "rc=${rc}"
	fi
	return 0
}

test_invalid_body_files_fail_before_gate() {
	local missing="${TEST_ROOT}/missing-body"
	local unreadable="${TEST_ROOT}/unreadable-body"
	local gate_marker="${TEST_ROOT}/gate-called"
	local rc=0
	cmd_pre_merge_gate() {
		: >"$gate_marker"
		return 0
	}

	rm -f "$gate_marker"
	cmd_merge 42 testorg/testrepo --body-file "$missing" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 && ! -e "$gate_marker" ]]; then
		print_result "missing body file fails before merge gate" 0
	else
		print_result "missing body file fails before merge gate" 1 "rc=${rc}"
	fi

	printf '%s\n' 'unreadable' >"$unreadable"
	chmod 000 "$unreadable"
	rc=0
	rm -f "$gate_marker"
	cmd_merge 42 testorg/testrepo --body-file "$unreadable" >/dev/null 2>&1 || rc=$?
	chmod 600 "$unreadable"
	if [[ "$rc" -ne 0 && ! -e "$gate_marker" ]]; then
		print_result "unreadable body file fails before merge gate" 0
	else
		print_result "unreadable body file fails before merge gate" 1 "rc=${rc}"
	fi

	rc=0
	rm -f "$gate_marker"
	cmd_merge 42 testorg/testrepo --body-file >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 && ! -e "$gate_marker" ]]; then
		print_result "body-file without a path fails before merge gate" 0
	else
		print_result "body-file without a path fails before merge gate" 1 "rc=${rc}"
	fi
	return 0
}

main() {
	setup_subject
	assert_transport_preserves_body normal "normal gh merge"
	assert_transport_preserves_body admin "admin fallback"
	assert_transport_preserves_body rest "REST fallback"
	test_invalid_body_files_fail_before_gate
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
