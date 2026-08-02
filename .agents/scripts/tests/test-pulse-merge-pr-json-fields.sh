#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
MERGE_PROCESS="${SCRIPT_DIR}/../pulse-merge-process.sh"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

file_contains() {
	local file_path="$1"
	local needle="$2"
	grep -Fq -- "$needle" "$file_path"
	return $?
}

PROCESS_PR_TEST_CALL_LOG=""
PROCESS_PR_TEST_PAYLOAD_LOG=""
PROCESS_PR_TEST_STATE="OPEN"

# shellcheck disable=SC2317 # Called by the dynamically extracted process_pr.
gh_pr_view() {
	local pr_number="$1"
	[[ -n "$PROCESS_PR_TEST_CALL_LOG" ]] || return 1
	printf '%s|%s\n' "$pr_number" "${AIDEVOPS_GH_REST_FIRST_READS:-0}" >>"$PROCESS_PR_TEST_CALL_LOG"
	printf '{"number":%s,"state":"%s"}\n' "$pr_number" "$PROCESS_PR_TEST_STATE"
	return 0
}

# shellcheck disable=SC2317 # Called by the dynamically extracted process_pr.
_process_single_ready_pr() {
	local repo_slug="$1"
	local pr_obj="$2"
	[[ -n "$PROCESS_PR_TEST_PAYLOAD_LOG" ]] || return 1
	printf '%s|%s\n' "$repo_slug" "$pr_obj" >>"$PROCESS_PR_TEST_PAYLOAD_LOG"
	return 0
}

test_ready_pr_fields_include_process_metadata() {
	local helper_src fields
	helper_src=$(awk '
		/^_pulse_merge_ready_pr_json_fields\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		print_result "ready PR field helper exists" 1 "missing _pulse_merge_ready_pr_json_fields"
		return 0
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	fields="$(_pulse_merge_ready_pr_json_fields)"

	local required missing=""
	for required in number state author title isDraft labels updatedAt headRefOid headRefName baseRefName createdAt; do
		if [[ ",${fields}," != *",${required},"* ]]; then
			missing="${missing:+${missing},}${required}"
		fi
	done
	if [[ -n "$missing" ]]; then
		print_result "ready PR REST fields include process metadata" 1 "missing=${missing}; fields=${fields}"
		return 0
	fi
	if [[ ",${fields}," == *",mergeable,"* || ",${fields}," == *",reviewDecision,"* || ",${fields}," == *",statusCheckRollup,"* ]]; then
		print_result "ready PR REST fields exclude enriched GraphQL metadata" 1 "fields=${fields}"
		return 0
	fi
	print_result "ready PR REST fields include process metadata" 0
	print_result "ready PR REST fields exclude enriched GraphQL metadata" 0
	return 0
}

test_callers_use_shared_field_helper() {
	local shared_field_arg="--json \"\$(_pulse_merge_ready_pr_json_fields)\""
	if ! file_contains "$MERGE_SCRIPT" "$shared_field_arg"; then
		print_result "process_pr uses shared PR field helper" 1 "process_pr still has an inline --json field list"
		return 0
	fi
	if ! file_contains "$MERGE_PROCESS" "$shared_field_arg"; then
		print_result "merge-ready list uses shared PR field helper" 1 "_merge_ready_prs_for_repo still has an inline --json field list"
		return 0
	fi
	print_result "PR JSON callers use shared field helper" 0
	return 0
}

test_process_pr_runtime_reuses_one_view() {
	local helper_src normalize_src process_src call_log payload_log log_file call_count call_line payload failure=""
	helper_src=$(awk '
		/^_pulse_merge_ready_pr_json_fields\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	normalize_src=$(awk '
		/^_pmp_normalize_pr_lifecycle_state_into\(\) \{/,/^}$/ { print }
	' "$MERGE_PROCESS")
	process_src=$(awk '
		/^process_pr\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$helper_src" || -z "$normalize_src" || -z "$process_src" ]]; then
		print_result "process_pr runtime source exists" 1 "could not extract helper functions"
		return 0
	fi
	# shellcheck disable=SC1090 # Test intentionally evaluates extracted functions.
	eval "$helper_src"
	eval "$normalize_src"
	eval "$process_src"

	call_log=$(mktemp)
	payload_log=$(mktemp)
	log_file=$(mktemp)
	PROCESS_PR_TEST_CALL_LOG="$call_log"
	PROCESS_PR_TEST_PAYLOAD_LOG="$payload_log"
	PROCESS_PR_TEST_STATE="open"
	LOGFILE="$log_file"

	if ! process_pr "owner/repo" "42"; then
		failure="process_pr rejected a lowercase open prefetched state"
	else
		call_count=$(wc -l <"$call_log" | tr -d ' ')
		call_line=$(<"$call_log")
		payload=$(<"$payload_log")
		[[ "$call_count" == "1" ]] || failure="gh_pr_view calls=${call_count}"
		[[ "$call_line" == "42|1" ]] || failure="webhook PR view did not force REST-first routing: ${call_line}"
		[[ "$payload" == *'"state":"open"'* ]] || failure="prefetched state was not forwarded"
	fi
	if [[ -z "$failure" ]]; then
		: >"$call_log"
		: >"$payload_log"
		PROCESS_PR_TEST_STATE="MERGED"
		if process_pr "owner/repo" "42"; then
			failure="process_pr accepted a MERGED prefetched state"
		else
			call_count=$(wc -l <"$call_log" | tr -d ' ')
			call_line=$(<"$call_log")
			payload=$(<"$payload_log")
			[[ "$call_count" == "1" ]] || failure="closed-state gh_pr_view calls=${call_count}"
			[[ "$call_line" == "42|1" ]] || failure="closed-state PR view did not force REST-first routing: ${call_line}"
			[[ -z "$payload" ]] || failure="closed-state PR reached merge processing"
		fi
	fi
	rm -f "$call_log" "$payload_log" "$log_file"

	if [[ -n "$failure" ]]; then
		print_result "process_pr runtime reuses one PR view and state gate" 1 "$failure"
		return 0
	fi
	print_result "process_pr runtime uses one REST-first PR view and state gate" 0
	return 0
}

test_merge_ready_pr_list_failure_logs_error() {
	if ! file_contains "$MERGE_PROCESS" '|| pr_json=""'; then
		print_result "merge-ready list failure leaves empty output for error guard" 1 "gh_pr_list failure fallback must be empty so the existing -z guard logs the error"
		return 0
	fi
	if file_contains "$MERGE_PROCESS" '|| pr_json="[]"'; then
		print_result "merge-ready list failure avoids silent empty array fallback" 1 "gh_pr_list failure fallback still masks errors as []"
		return 0
	fi
	print_result "merge-ready list failure reaches error logging guard" 0
	return 0
}

test_merge_ready_pr_list_uses_provider_cache() {
	# shellcheck disable=SC2016 # The assertion checks literal shell source.
	if ! file_contains "$MERGE_PROCESS" 'pulse_pr_list_get --repo "$repo_slug" --state open'; then
		print_result "merge-ready PR list uses provider cache" 1 "_merge_ready_prs_for_repo must route through pulse_pr_list_get for per-cycle coalescing"
		return 0
	fi
	print_result "merge-ready PR list uses provider cache" 0
	return 0
}

main() {
	test_ready_pr_fields_include_process_metadata
	test_callers_use_shared_field_helper
	test_process_pr_runtime_reuses_one_view
	test_merge_ready_pr_list_failure_logs_error
	test_merge_ready_pr_list_uses_provider_cache

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
