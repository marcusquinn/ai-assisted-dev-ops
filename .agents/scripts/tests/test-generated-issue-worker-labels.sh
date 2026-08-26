#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25921: automation-created issues must carry worker
# dispatch labels at creation time so gh_create_issue skips interactive
# self-assignment and pulse can dispatch them without manual label hygiene.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
CREATE_LOG=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name" >&2
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message" >&2
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

reset_create_log() {
	: >"$CREATE_LOG"
	return 0
}

create_log_text() {
	if [[ -f "$CREATE_LOG" ]]; then
		tr '\n' ' ' <"$CREATE_LOG"
	fi
	return 0
}

assert_create_contains() {
	local test_name="$1"
	local expected="$2"
	local text
	text=$(create_log_text)
	if [[ "$text" == *"$expected"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "expected ${expected}; got ${text}"
	return 0
}

assert_create_not_contains() {
	local test_name="$1"
	local unexpected="$2"
	local text
	text=$(create_log_text)
	if [[ "$text" != *"$unexpected"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "unexpected ${unexpected}; got ${text}"
	return 0
}

assert_text_contains() {
	local test_name="$1"
	local expected="$2"
	local text="$3"
	if [[ "$text" == *"$expected"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "expected ${expected}; got ${text}"
	return 0
}

assert_text_not_contains() {
	local test_name="$1"
	local unexpected="$2"
	local text="$3"
	if [[ "$text" != *"$unexpected"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "unexpected ${unexpected}; got ${text}"
	return 0
}

count_create_occurrences() {
	local needle="$1"
	local text count=0
	text=$(create_log_text)
	while [[ "$text" == *"$needle"* ]]; do
		count=$((count + 1))
		text="${text#*"$needle"}"
	done
	printf '%s\n' "$count"
	return 0
}

setup_test() {
	TEST_ROOT=$(mktemp -d)
	CREATE_LOG="${TEST_ROOT}/create.log"
	: >"$CREATE_LOG"
	LOGFILE="${TEST_ROOT}/pulse.log"
	export LOGFILE
	COMPLEXITY_FUNC_LINE_THRESHOLD=100
	PULSE_START_EPOCH=$(date +%s)
	export COMPLEXITY_FUNC_LINE_THRESHOLD PULSE_START_EPOCH
	return 0
}

teardown_test() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

install_test_stubs() {
	gh_create_issue() {
		printf '%s\n' "$*" >>"$CREATE_LOG"
		printf 'https://github.com/marcusquinn/aidevops/issues/99999\n'
		return 0
	}

	_complexity_scan_md_file_status() {
		printf 'new'
		return 0
	}

	_complexity_scan_extract_md_topic_label() {
		return 1
	}

	_complexity_scan_md_build_full_body() {
		printf 'body'
		return 0
	}

	_complexity_scan_close_duplicate_issues_by_title() {
		return 0
	}
	return 0
}

test_simplification_md_labels() {
	reset_create_log
	_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=true _complexity_scan_process_single_md_file \
		".agents/reference/example.md" "501" "marcusquinn/aidevops" "$PWD" "" "marcusquinn" >/dev/null
	assert_create_contains "md simplification has auto-dispatch" "--label auto-dispatch"
	assert_create_contains "md simplification has status available" "--label status:available"
	assert_create_contains "md simplification has worker origin" "--label origin:worker"
	assert_create_contains "md simplification has standard tier" "--label tier:standard"
	reset_create_log
	_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=false _complexity_scan_process_single_md_file \
		".agents/reference/example-held.md" "501" "marcusquinn/aidevops" "$PWD" "" "marcusquinn" >/dev/null
	assert_create_contains "md simplification review gate uses hold-for-review" "--label hold-for-review"
	assert_create_not_contains "md simplification review gate never uses NMR" "needs-maintainer-review"
	return 0
}

test_simplification_shell_labels() {
	local repos_json="${TEST_ROOT}/repos.json"
	printf '{"initialized_repos":[{"slug":"marcusquinn/aidevops","path":"%s"}]}\n' "$PWD" >"$repos_json"
	reset_create_log
	_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=true _complexity_scan_sh_create_issue \
		".agents/scripts/example.sh" "1" "$repos_json" "marcusquinn/aidevops" >/dev/null
	assert_create_contains "shell simplification has auto-dispatch" "--label auto-dispatch"
	assert_create_contains "shell simplification has status available" "--label status:available"
	assert_create_contains "shell simplification has worker origin" "--label origin:worker"
	assert_create_contains "shell simplification has standard tier" "--label tier:standard"
	return 0
}

test_simplification_body_authority() {
	local trusted_body=""
	local held_body=""

	_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=true
	trusted_body=$(_complexity_scan_build_md_issue_body ".agents/reference/example.md" "501" "Example")
	assert_text_contains "trusted simplification body records dispatch authority" \
		"No additional approval comment is required" "$trusted_body"
	assert_text_not_contains "trusted simplification body omits approval wait" \
		"To approve or decline" "$trusted_body"

	_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=false
	held_body=$(_complexity_scan_sh_build_issue_body_with_sig \
		".agents/scripts/example.sh" "1" "big_function() 101 lines")
	assert_text_contains "held simplification body retains approval instructions" \
		"To approve or decline" "$held_body"
	unset _COMPLEXITY_SCAN_SKIP_REVIEW_GATE
	return 0
}

test_quality_feedback_labels() {
	local maintainer_labels external_labels
	maintainer_labels=$(_build_quality_debt_labels "high" "true" "")
	external_labels=$(_build_quality_debt_labels "medium" "false" "")
	[[ "$maintainer_labels" == *"auto-dispatch"* ]] && print_result "quality labels include auto-dispatch" 0 || print_result "quality labels include auto-dispatch" 1 "$maintainer_labels"
	[[ "$maintainer_labels" == *"origin:worker"* ]] && print_result "quality labels include worker origin" 0 || print_result "quality labels include worker origin" 1 "$maintainer_labels"
	[[ "$maintainer_labels" == *"tier:standard"* ]] && print_result "quality labels include tier" 0 || print_result "quality labels include tier" 1 "$maintainer_labels"
	[[ "$external_labels" == *"needs-maintainer-review"* && "$external_labels" == *"auto-dispatch"* ]] && print_result "external quality labels keep NMR with dispatch label" 0 || print_result "external quality labels keep NMR with dispatch label" 1 "$external_labels"
	[[ "$external_labels" == *"external-contributor"* ]] && print_result "external quality labels preserve source authority provenance" 0 || print_result "external quality labels preserve source authority provenance" 1 "$external_labels"
	return 0
}

test_failure_miner_labels() {
	local cluster_json legacy_infra_cluster_json legacy_infra_body
	cluster_json='{"repo":"marcusquinn/aidevops","check_name":"ShellCheck","check_names":["ShellCheck"],"signature":"failure:shellcheck","count":2,"sources":["pr:#1"],"examples":[{"source_ref":"pr:#1"}]}'
	legacy_infra_cluster_json='{"repo":"marcusquinn/aidevops","check_name":"ShellCheck","signature":"failure:shellcheck","count":2,"sources":["pr:#1"],"examples":[{"source_ref":"pr:#1"}]}'
	legacy_infra_body=$(build_issue_body "$legacy_infra_cluster_json" "abc123" "2" "true")
	[[ "$legacy_infra_body" == *"Affected checks: ShellCheck"* ]] && print_result "infra miner falls back to check_name when check_names is absent" 0 || print_result "infra miner falls back to check_name when check_names is absent" 1 "$legacy_infra_body"
	reset_create_log
	create_or_preview_issue "$cluster_json" "abc123" "2" "false" "false" >/dev/null
	assert_create_contains "failure miner has auto-dispatch" "--label auto-dispatch"
	assert_create_contains "failure miner has status available" "--label status:available"
	assert_create_contains "failure miner has worker origin" "--label origin:worker"
	assert_create_contains "failure miner has standard tier" "--label tier:standard"

	reset_create_log
	create_or_preview_issue "$cluster_json" "abc123" "2" "false" "false" "auto-dispatch" >/dev/null
	[[ "$(count_create_occurrences "--label auto-dispatch")" == "1" ]] && print_result "failure miner dedupes scheduler auto-dispatch label" 0 || print_result "failure miner dedupes scheduler auto-dispatch label" 1 "$(create_log_text)"

	reset_create_log
	create_or_preview_issue "$cluster_json" "abc123" "2" "false" "false" "custom:one, custom:two, auto-dispatch" >/dev/null
	assert_create_contains "failure miner trims comma-separated labels" "--label custom:two"
	assert_create_not_contains "failure miner omits whitespace-padded labels" "--label  custom:two"
	[[ "$(count_create_occurrences "--label auto-dispatch")" == "1" ]] && print_result "failure miner dedupes trimmed scheduler label" 0 || print_result "failure miner dedupes trimmed scheduler label" 1 "$(create_log_text)"

	reset_create_log
	create_or_preview_issue "$cluster_json" "abc123" "2" "false" "true" >/dev/null
	assert_create_contains "infra miner has worker origin" "--label origin:worker"
	assert_create_contains "infra miner has status available" "--label status:available"
	assert_create_not_contains "infra miner omits auto-dispatch" "--label auto-dispatch"
	return 0
}

setup_test
trap teardown_test EXIT

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/pulse-simplification-issues.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/quality-feedback-issues-lib.sh"
set -- help
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/gh-failure-miner-helper.sh" >/dev/null
install_test_stubs

test_simplification_md_labels
test_simplification_shell_labels
test_simplification_body_authority
test_quality_feedback_labels
test_failure_miner_labels

printf '\nTests run: %s\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	printf 'Tests failed: %s\n' "$TESTS_FAILED" >&2
	exit 1
fi

printf 'All generated issue worker label tests passed.\n'
exit 0
