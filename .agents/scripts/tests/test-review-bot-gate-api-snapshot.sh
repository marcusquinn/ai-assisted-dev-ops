#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Regression coverage for per-decision review evidence snapshot reuse.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
HELPER_SCRIPT="${SCRIPT_DIR}/../review-bot-gate-helper.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
RUN_STATUS=0
RUN_OUTPUT=""
CALL_LOG="${TEST_ROOT}/gh-calls.log"
SCENARIO_FILE="${TEST_ROOT}/scenario"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

print_result() {
	local test_name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

load_helper_functions() {
	local source_copy="${TEST_ROOT}/review-bot-gate-helper.sh"
	grep -v '^main "\$@"' "$HELPER_SCRIPT" >"$source_copy"
	# shellcheck disable=SC1090
	source "$source_copy"
	return 0
}

install_gh_stub() {
	local bin_dir="${TEST_ROOT}/bin"
	mkdir -p "$bin_dir" "${TEST_ROOT}/home/.config/aidevops"
	cat >"${bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

call_log="${REVIEW_GATE_SNAPSHOT_CALL_LOG:?}"
scenario_file="${REVIEW_GATE_SNAPSHOT_SCENARIO_FILE:?}"
failure_marker="${REVIEW_GATE_SNAPSHOT_FAILURE_MARKER:?}"
scenario=""
IFS= read -r scenario <"$scenario_file"

if [[ "${1:-}" != "api" ]]; then
	printf 'command:%s\n' "$*" >>"$call_log"
	exit 2
fi
endpoint="${2:-}"
jq_filter=""
shift 2
while [[ "$#" -gt 0 ]]; do
	case "${1:-}" in
	--jq)
		jq_filter="${2:-}"
		shift 2
		;;
	*) shift ;;
	esac
done

mode="snapshot"
if [[ -n "$jq_filter" ]]; then
	mode="direct"
elif [[ "$endpoint" == "repos/testorg/testrepo/pulls/123" ]]; then
	mode="metadata"
fi
printf '%s:%s\n' "$mode" "$endpoint" >>"$call_log"

if [[ "$scenario" == "fail-once" && "$mode" == "snapshot" &&
	"$endpoint" == "repos/testorg/testrepo/pulls/123/reviews?per_page=100" && ! -e "$failure_marker" ]]; then
	: >"$failure_marker"
	exit 42
fi
if [[ "$scenario" == "metadata-failure" && "$endpoint" == "repos/testorg/testrepo/pulls/123" ]]; then
	exit 42
fi

emit_pages() {
	local target_endpoint="$1"
	local current_scenario="$2"
	case "$target_endpoint" in
	repos/testorg/testrepo/pulls/123/reviews | repos/testorg/testrepo/pulls/123/reviews?per_page=100)
		if [[ "$current_scenario" == "empty" || "$current_scenario" == "metadata-failure" ]]; then
			printf '%s\n' '[]'
		else
			# Two pages prove that the snapshot collector preserves pagination.
			printf '%s\n' '[]'
			printf '%s\n' '[{"user":{"login":"gemini-code-assist[bot]"},"commit_id":"head-123","submitted_at":"2020-01-01T00:00:00Z","body":"Substantive review of the current change."}]'
		fi
		;;
	repos/testorg/testrepo/issues/123/comments | repos/testorg/testrepo/issues/123/comments?per_page=100 | \
		repos/testorg/testrepo/pulls/123/comments | repos/testorg/testrepo/pulls/123/comments?per_page=100)
		printf '%s\n' '[]'
		;;
	repos/testorg/testrepo/commits/head-123/status?per_page=100)
		printf '%s\n' '{"statuses":[]}'
		;;
	repos/testorg/testrepo/commits/head-123/check-runs?per_page=100)
		printf '%s\n' '{"check_runs":[]}'
		;;
	repos/testorg/testrepo/pulls/123)
		printf '%s\n' '{"head":{"sha":"head-123"},"author_association":"MEMBER","labels":[]}'
		;;
	*) return 2 ;;
	esac
	return 0
}

if [[ -n "$jq_filter" ]]; then
	emit_pages "$endpoint" "$scenario" | jq -r "$jq_filter"
	exit $?
fi
emit_pages "$endpoint" "$scenario"
exit $?
EOF
	chmod +x "${bin_dir}/gh"
	export PATH="${bin_dir}:${PATH}"
	export HOME="${TEST_ROOT}/home"
	export REVIEW_GATE_SNAPSHOT_CALL_LOG="$CALL_LOG"
	export REVIEW_GATE_SNAPSHOT_SCENARIO_FILE="$SCENARIO_FILE"
	export REVIEW_GATE_SNAPSHOT_FAILURE_MARKER="${TEST_ROOT}/failed-once"
	return 0
}

run_check() {
	local scenario="$1"
	local snapshot_disabled="$2"
	local output_file="${TEST_ROOT}/check-output"
	local error_file="${TEST_ROOT}/check-error"
	printf '%s\n' "$scenario" >"$SCENARIO_FILE"
	: >"$output_file"
	: >"$error_file"
	RUN_STATUS=0
	if REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER \
		REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE="$snapshot_disabled" \
		do_check 123 'testorg/testrepo' >"$output_file" 2>"$error_file"; then
		RUN_STATUS=0
	else
		RUN_STATUS=$?
	fi
	RUN_OUTPUT=""
	IFS= read -r RUN_OUTPUT <"$output_file" || true
	return 0
}

run_check_without_association() {
	local scenario="$1"
	local output_file="${TEST_ROOT}/check-output"
	local error_file="${TEST_ROOT}/check-error"
	printf '%s\n' "$scenario" >"$SCENARIO_FILE"
	: >"$output_file"
	: >"$error_file"
	RUN_STATUS=0
	if REVIEW_GATE_AUTHOR_ASSOCIATION='' REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE=0 \
		do_check 123 'testorg/testrepo' >"$output_file" 2>"$error_file"; then
		RUN_STATUS=0
	else
		RUN_STATUS=$?
	fi
	RUN_OUTPUT=""
	IFS= read -r RUN_OUTPUT <"$output_file" || true
	return 0
}

call_count() {
	local count="0"
	count=$(wc -l <"$CALL_LOG" | tr -d '[:space:]')
	printf '%s\n' "$count"
	return 0
}

matching_call_count() {
	local pattern="$1"
	local count="0"
	count=$(grep -cF -- "$pattern" "$CALL_LOG" 2>/dev/null || true)
	printf '%s\n' "$count"
	return 0
}

exact_call_count() {
	local pattern="$1"
	local count="0"
	count=$(grep -cFx -- "$pattern" "$CALL_LOG" 2>/dev/null || true)
	printf '%s\n' "$count"
	return 0
}

test_preloaded_metadata_avoids_duplicate_lookups() {
	local pr_metadata='{"head":{"sha":"head-123"},"author_association":"MEMBER","labels":[]}'
	local output_file="${TEST_ROOT}/metadata-output"
	local status=0 output="" calls command_calls pull_metadata_calls status_calls check_calls
	printf '%s\n' real >"$SCENARIO_FILE"
	: >"$CALL_LOG"
	if REVIEW_GATE_EXPECTED_HEAD_SHA=head-123 REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE=0 \
		do_check 123 'testorg/testrepo' "$pr_metadata" >"$output_file"; then
		status=0
	else
		status=$?
	fi
	IFS= read -r output <"$output_file" || true
	calls=$(call_count)
	command_calls=$(matching_call_count 'command:')
	pull_metadata_calls=$(exact_call_count 'metadata:repos/testorg/testrepo/pulls/123')
	status_calls=$(exact_call_count 'direct:repos/testorg/testrepo/commits/head-123/status?per_page=100')
	check_calls=$(exact_call_count 'direct:repos/testorg/testrepo/commits/head-123/check-runs?per_page=100')
	if [[ "$status" -eq 0 && "$output" == "PASS" && "$calls" == "5" &&
		"$command_calls" == "0" && "$pull_metadata_calls" == "0" &&
		"$status_calls" == "1" && "$check_calls" == "1" ]]; then
		print_result "preloaded PR metadata and head avoid duplicate metadata lookups" 0
	else
		print_result "preloaded PR metadata and head avoid duplicate metadata lookups" 1 \
			"status=${status} output=${output} calls=${calls} command=${command_calls} pull=${pull_metadata_calls} statuses=${status_calls}/${check_calls}"
	fi
	return 0
}

test_snapshot_reuses_three_paginated_collections() {
	: >"$CALL_LOG"
	run_check real 0
	local calls reviews issue_comments review_comments
	calls=$(call_count)
	reviews=$(matching_call_count 'snapshot:repos/testorg/testrepo/pulls/123/reviews?per_page=100')
	issue_comments=$(matching_call_count 'snapshot:repos/testorg/testrepo/issues/123/comments?per_page=100')
	review_comments=$(matching_call_count 'snapshot:repos/testorg/testrepo/pulls/123/comments?per_page=100')
	if [[ "$RUN_STATUS" -eq 0 && "$RUN_OUTPUT" == "PASS" && "$calls" == "3" &&
		"$reviews" == "1" && "$issue_comments" == "1" && "$review_comments" == "1" &&
		"$_RBG_EVIDENCE_SNAPSHOT_READY" -eq 0 ]]; then
		print_result "one check reuses exactly three paginated evidence collections" 0
	else
		print_result "one check reuses exactly three paginated evidence collections" 1 \
			"status=${RUN_STATUS} output=${RUN_OUTPUT} calls=${calls} endpoint_counts=${reviews}/${issue_comments}/${review_comments} ready=${_RBG_EVIDENCE_SNAPSHOT_READY}"
	fi
	return 0
}

test_snapshot_refreshes_between_decisions() {
	: >"$CALL_LOG"
	run_check real 0
	local first_status="$RUN_STATUS"
	local first_output="$RUN_OUTPUT"
	run_check empty 0
	local calls
	calls=$(call_count)
	if [[ "$first_status" -eq 0 && "$first_output" == "PASS" &&
		"$RUN_STATUS" -eq 0 && "$RUN_OUTPUT" == "PASS_ADVISORY" && "$calls" == "6" ]]; then
		print_result "a later decision fetches fresh evidence instead of reusing stale state" 0
	else
		print_result "a later decision fetches fresh evidence instead of reusing stale state" 1 \
			"first=${first_status}/${first_output} second=${RUN_STATUS}/${RUN_OUTPUT} calls=${calls}"
	fi
	return 0
}

test_disable_toggle_restores_direct_queries() {
	: >"$CALL_LOG"
	run_check real 1
	local calls snapshot_calls direct_calls
	calls=$(call_count)
	snapshot_calls=$(matching_call_count 'snapshot:')
	direct_calls=$(matching_call_count 'direct:')
	if [[ "$RUN_STATUS" -eq 0 && "$RUN_OUTPUT" == "PASS" && "$calls" == "4" &&
		"$snapshot_calls" == "0" && "$direct_calls" == "4" ]]; then
		print_result "rollback toggle restores the direct-query path" 0
	else
		print_result "rollback toggle restores the direct-query path" 1 \
			"status=${RUN_STATUS} output=${RUN_OUTPUT} calls=${calls} snapshot=${snapshot_calls} direct=${direct_calls}"
	fi
	return 0
}

test_snapshot_failure_falls_back_without_losing_capability() {
	: >"$CALL_LOG"
	rm -f "${TEST_ROOT}/failed-once"
	run_check fail-once 0
	local calls snapshot_calls direct_calls
	calls=$(call_count)
	snapshot_calls=$(matching_call_count 'snapshot:')
	direct_calls=$(matching_call_count 'direct:')
	if [[ "$RUN_STATUS" -eq 0 && "$RUN_OUTPUT" == "PASS" && "$calls" == "5" &&
		"$snapshot_calls" == "1" && "$direct_calls" == "4" &&
		$(grep -cF 'falling back to direct endpoint queries' "${TEST_ROOT}/check-error" || true) -eq 1 ]]; then
		print_result "snapshot failure preserves the direct-query fallback" 0
	else
		print_result "snapshot failure preserves the direct-query fallback" 1 \
			"status=${RUN_STATUS} output=${RUN_OUTPUT} calls=${calls} snapshot=${snapshot_calls} direct=${direct_calls}"
	fi
	return 0
}

test_missing_metadata_uses_rest_association_without_graphql_projection() {
	: >"$CALL_LOG"
	run_check_without_association real
	local calls command_calls pull_metadata_calls
	calls=$(call_count)
	command_calls=$(matching_call_count 'command:')
	pull_metadata_calls=$(exact_call_count 'metadata:repos/testorg/testrepo/pulls/123')
	if [[ "$RUN_STATUS" -eq 0 && "$RUN_OUTPUT" == "PASS" && "$calls" == "4" &&
		"$command_calls" == "0" && "$pull_metadata_calls" == "1" ]]; then
		print_result "missing association uses one REST pull lookup without gh pr projection" 0
	else
		print_result "missing association uses one REST pull lookup without gh pr projection" 1 \
			"status=${RUN_STATUS} output=${RUN_OUTPUT} calls=${calls} command=${command_calls} pull=${pull_metadata_calls}"
	fi
	return 0
}

test_rest_association_failure_remains_blocked() {
	: >"$CALL_LOG"
	run_check_without_association metadata-failure
	local calls command_calls pull_metadata_calls
	calls=$(call_count)
	command_calls=$(matching_call_count 'command:')
	pull_metadata_calls=$(exact_call_count 'metadata:repos/testorg/testrepo/pulls/123')
	if [[ "$RUN_STATUS" -eq 1 && "$RUN_OUTPUT" == "WAITING" && "$calls" == "4" &&
		"$command_calls" == "0" && "$pull_metadata_calls" == "1" ]]; then
		print_result "REST association failure keeps unknown authors blocked" 0
	else
		print_result "REST association failure keeps unknown authors blocked" 1 \
			"status=${RUN_STATUS} output=${RUN_OUTPUT} calls=${calls} command=${command_calls} pull=${pull_metadata_calls}"
	fi
	return 0
}

test_finalized_external_association_avoids_metadata_retry() {
	local output_file="${TEST_ROOT}/resolved-external-output"
	local status=0 output="" calls pull_metadata_calls
	printf '%s\n' empty >"$SCENARIO_FILE"
	: >"$CALL_LOG"
	if REVIEW_GATE_AUTHOR_ASSOCIATION=CONTRIBUTOR \
		REVIEW_GATE_AUTHOR_ASSOCIATION_RESOLVED=true \
		REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE=0 \
		do_check 123 'testorg/testrepo' >"$output_file" 2>/dev/null; then
		status=0
	else
		status=$?
	fi
	IFS= read -r output <"$output_file" || true
	calls=$(call_count)
	pull_metadata_calls=$(exact_call_count 'metadata:repos/testorg/testrepo/pulls/123')
	if [[ "$status" -eq 1 && "$output" == "WAITING" && "$calls" == "3" &&
		"$pull_metadata_calls" == "0" ]]; then
		print_result "finalized external association avoids a duplicate REST metadata lookup" 0
	else
		print_result "finalized external association avoids a duplicate REST metadata lookup" 1 \
			"status=${status} output=${output} calls=${calls} pull=${pull_metadata_calls}"
	fi
	return 0
}

install_gh_stub
load_helper_functions
test_preloaded_metadata_avoids_duplicate_lookups

# Install narrow test doubles after sourcing so they replace the helper's API
# metadata lookups without replacing the evidence collection under test.
check_for_skip_label() {
	local pr_number="$1"
	local repo="$2"
	: "$pr_number" "$repo"
	return 1
}

_get_success_status_contexts() {
	local pr_number="$1"
	local repo="$2"
	: "$pr_number" "$repo"
	return 1
}

test_snapshot_reuses_three_paginated_collections
test_snapshot_refreshes_between_decisions
test_disable_toggle_restores_direct_queries
test_snapshot_failure_falls_back_without_losing_capability
test_missing_metadata_uses_rest_association_without_graphql_projection
test_rest_association_failure_remains_blocked
test_finalized_external_association_avoids_metadata_retry

printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
