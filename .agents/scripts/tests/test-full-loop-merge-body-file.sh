#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 2
TEST_ROOT=""
TEST_MODE="normal"
TEST_ORIGINAL_BODY_FILE=""
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

capture_file() {
	local source_file="$1"
	local count=0
	[[ -f "${TEST_ROOT}/capture-count" ]] && count=$(<"${TEST_ROOT}/capture-count")
	count=$((count + 1))
	cp "$source_file" "${TEST_ROOT}/captured-body-${count}"
	printf '%s\n' "$count" >"${TEST_ROOT}/capture-count"
	printf '%s\n' "$source_file" >>"${TEST_ROOT}/snapshot-paths"
	return 0
}

capture_body_file_arg() {
	local previous=""
	local argument=""
	for argument in "$@"; do
		if [[ "$previous" == "--body-file" ]]; then
			capture_file "$argument"
			return 0
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
			capture_file "${argument#commit_message=@}"
			return 0
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
		admin | mutating-admin)
			if [[ "$*" != *"--admin"* ]]; then
				if [[ "$TEST_MODE" == "mutating-admin" ]]; then
					printf '%s\n' 'mutated after validation' >"$TEST_ORIGINAL_BODY_FILE"
				fi
				printf '%s\n' 'At least 1 approving review is required' >&2
				return 1
			fi
			;;
		auto-admin)
			if [[ "$*" != *"--admin"* ]]; then
				printf '%s\n' 'At least 1 approving review is required; cannot approve your own pull request' >&2
				return 1
			fi
			;;
		rest)
			printf '%s\n' 'GraphQL: API rate limit already exceeded (rateLimitExceeded)' >&2
			return 1
			;;
		stale-401)
			if [[ "$(<"${TEST_ROOT}/capture-count")" -eq 1 ]]; then
				printf '%s\n' 'HTTP/2.0 401 Unauthorized' >&2
				return 1
			fi
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
	_merge_pr_ready_for_interactive_admin_bypass() {
		return 0
	}
	gh_merge_remediate_stale_auth_cache() {
		local merge_output="$1"
		local context="$2"
		local cache_root="$3"
		: "$merge_output" "$context" "$cache_root"
		[[ "$TEST_MODE" == "stale-401" ]]
		return $?
	}
	_merge_fresh_worktree_cleanup_target() {
		return 1
	}
	_retarget_stacked_children_interactive() {
		return 0
	}
	_merge_verify_completed_state() {
		FULL_LOOP_MERGE_SHA="fixture-merge-sha"
		return 0
	}
	_merge_report_canonical_sync_state() {
		return 0
	}
	_merge_finalize_post_merge() {
		return 0
	}
	return 0
}

write_fixture_body() {
	local body_file="$1"
	printf '%s\n' \
		'Aidevops-Signature: fixture' \
		'' \
		'Aidevops-Release-Aggregator-PR: 42' \
		'Aidevops-Release-Aggregates: 29721@d53b458a6ee82e3dccd922c3791b9f9f088efa8f' >"$body_file"
	return 0
}

write_hidden_aggregation_body() {
	local body_file="$1"
	printf '%s\n' \
		'Release aggregation' \
		'' \
		'Aidevops-Release-Aggregator-PR: 42' \
		'Aidevops-Release-Aggregates: 29721@d53b458a6ee82e3dccd922c3791b9f9f088efa8f' \
		'' \
		'<!-- aidevops:sig -->' \
		'---' \
		'aidevops signature footer' >"$body_file"
	return 0
}

assert_transport_preserves_body() {
	local mode="$1"
	local label="$2"
	local expected_captures="$3"
	local has_auto="${4:-0}"
	local body_file="${TEST_ROOT}/merge-body"
	local expected_file="${TEST_ROOT}/expected-body"
	local rc=0
	TEST_MODE="$mode"
	TEST_ORIGINAL_BODY_FILE="$body_file"
	rm -f "${TEST_ROOT}/captured-body-"* "${TEST_ROOT}/capture-count" "${TEST_ROOT}/snapshot-paths"
	write_fixture_body "$body_file"
	cp "$body_file" "$expected_file"
	local merge_args=(42 testorg/testrepo --squash --body-file "$body_file")
	[[ "$has_auto" -eq 1 ]] && merge_args+=(--auto)
	if [[ "$has_auto" -eq 1 ]]; then
		FULL_LOOP_HEADLESS=false AIDEVOPS_HEADLESS=false Claude_HEADLESS=false GITHUB_ACTIONS=false \
			cmd_merge ${merge_args[@]+"${merge_args[@]}"} >/dev/null 2>&1 || rc=$?
	else
		cmd_merge ${merge_args[@]+"${merge_args[@]}"} >/dev/null 2>&1 || rc=$?
	fi
	local capture_count=0
	[[ -f "${TEST_ROOT}/capture-count" ]] && capture_count=$(<"${TEST_ROOT}/capture-count")
	local exact=1
	local index=1
	while [[ "$index" -le "$capture_count" ]]; do
		cmp -s "$expected_file" "${TEST_ROOT}/captured-body-${index}" || exact=0
		index=$((index + 1))
	done
	local snapshots_removed=1
	local snapshot_path=""
	if [[ -f "${TEST_ROOT}/snapshot-paths" ]]; then
		while IFS= read -r snapshot_path; do
			[[ ! -e "$snapshot_path" ]] || snapshots_removed=0
		done <"${TEST_ROOT}/snapshot-paths"
	fi
	if [[ "$rc" -eq 0 && "$capture_count" -eq "$expected_captures" && "$exact" -eq 1 && "$snapshots_removed" -eq 1 ]]; then
		print_result "$label preserves exact body bytes" 0
	else
		print_result "$label preserves exact body bytes" 1 "rc=${rc}; captures=${capture_count}; exact=${exact}; snapshots_removed=${snapshots_removed}"
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
	if [[ -r "$unreadable" ]]; then
		print_result "unreadable body file assertion skipped for elevated reader" 0
	else
		rc=0
		rm -f "$gate_marker"
		cmd_merge 42 testorg/testrepo --body-file "$unreadable" >/dev/null 2>&1 || rc=$?
		if [[ "$rc" -ne 0 && ! -e "$gate_marker" ]]; then
			print_result "unreadable body file fails before merge gate" 0
		else
			print_result "unreadable body file fails before merge gate" 1 "rc=${rc}"
		fi
	fi
	chmod 600 "$unreadable"

	rc=0
	rm -f "$gate_marker"
	cmd_merge 42 testorg/testrepo --body-file >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 && ! -e "$gate_marker" ]]; then
		print_result "body-file without a path fails before merge gate" 0
	else
		print_result "body-file without a path fails before merge gate" 1 "rc=${rc}"
	fi

	rc=0
	rm -f "$gate_marker"
	local option_output=""
	option_output=$(cmd_merge 42 testorg/testrepo --body-file --merge 2>&1) || rc=$?
	if [[ "$rc" -ne 0 && ! -e "$gate_marker" && "$option_output" == *"Use --body-file=PATH"* ]]; then
		print_result "body-file does not consume a following merge option" 0
	else
		print_result "body-file does not consume a following merge option" 1 "rc=${rc}; output=${option_output}"
	fi
	return 0
}

test_hidden_aggregation_trailers_fail_before_merge_write() {
	local body_file="${TEST_ROOT}/hidden-aggregation-body"
	local output=""
	local rc=0
	TEST_MODE="normal"
	cmd_pre_merge_gate() { return 0; }
	rm -f "${TEST_ROOT}/capture-count" "${TEST_ROOT}/snapshot-paths"
	write_hidden_aggregation_body "$body_file"
	output=$(cmd_merge 42 testorg/testrepo --body-file "$body_file" 2>&1) || rc=$?
	if [[ "$rc" -ne 0 && ! -e "${TEST_ROOT}/capture-count" &&
		"$output" == *"terminal parseable block"* ]]; then
		print_result "signature-hidden aggregation trailers fail before merge write" 0
	else
		print_result "signature-hidden aggregation trailers fail before merge write" 1 "rc=${rc}; output=${output}"
	fi
	return 0
}

main() {
	setup_subject
	assert_transport_preserves_body normal "normal gh merge" 1
	assert_transport_preserves_body admin "admin fallback" 2
	assert_transport_preserves_body mutating-admin "immutable snapshot after source mutation" 2
	assert_transport_preserves_body auto-admin "interactive auto-to-admin fallback" 2 1
	assert_transport_preserves_body stale-401 "stale-auth retry" 2
	assert_transport_preserves_body rest "REST fallback" 1
	test_invalid_body_files_fail_before_gate
	test_hidden_aggregation_trailers_fail_before_merge_write
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
