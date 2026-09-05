#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-pr-backlog-priority.sh — GH#22303 regression guard.
#
# Verifies the deterministic merge pass classifies open PR backlog states and
# sorts near-merge/fix-needed PRs before lower-value backlog buckets. No live
# GitHub API calls are made.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected: %s\n' "$expected"
		printf '  actual:   %s\n' "$actual"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPT_DIR/pulse-merge-process.sh"
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-pulse-merge-pr-backlog-XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export LOGFILE="$TEST_TMPDIR/pulse.log"
export STOP_FLAG="$TEST_TMPDIR/stop.flag"

# shellcheck source=/dev/null
source "$MODULE"
set +e
set +o pipefail 2>/dev/null || true

REFRESHED_REVIEW_DECISION="CHANGES_REQUESTED"
REFRESH_SHOULD_FAIL=0
: >"${TEST_TMPDIR}/review-refresh.log"
_pmp_rest_review_decision_from_reviews() {
	local pr_number="$1" repo_slug="$2"
	[[ -n "$pr_number$repo_slug" ]]
	printf '%s|%s\n' "$pr_number" "$repo_slug" >>"${TEST_TMPDIR}/review-refresh.log"
	[[ "$REFRESH_SHOULD_FAIL" -eq 0 ]] || return 1
	printf '%s\n' "$REFRESHED_REVIEW_DECISION"
	return 0
}

gh() {
	local subcommand="$1"
	[[ -n "$subcommand" ]]
	return 1
}

printf '%s=== GH#22303: PR backlog priority tests ===%s\n' "$TEST_BLUE" "$TEST_NC"

merge_ready_pr='{"number":1,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
legacy_success_pr='{"number":6,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"state":"SUCCESS"}]}'
checks_in_progress_pr='{"number":2,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]}'
small_fix_pr='{"number":3,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}'
unknown_review_failed_pr='{"number":7,"mergeable":"MERGEABLE","reviewDecision":null,"isDraft":false,"labels":[{"name":"origin:worker"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}'
unknown_review_passing_pr='{"number":8,"mergeable":"MERGEABLE","reviewDecision":null,"isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
missing_number_pr='{"mergeable":"MERGEABLE","reviewDecision":"9","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'
dirty_pr='{"number":4,"mergeable":"CONFLICTING","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[]}'
human_pr='{"number":5,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}'

assert_eq "1a: mergeable green PR classifies as merge-ready" \
	"merge-ready" "$(_pmp_classify_pr_backlog_state "$merge_ready_pr")"
assert_eq "1a.1: legacy success status context classifies as merge-ready" \
	"merge-ready" "$(_pmp_classify_pr_backlog_state "$legacy_success_pr")"
assert_eq "1b: pending checks classify as checks-in-progress" \
	"checks-in-progress" "$(_pmp_classify_pr_backlog_state "$checks_in_progress_pr")"
assert_eq "1c: failed checks classify as small-fix-needed" \
	"small-fix-needed" "$(_pmp_classify_pr_backlog_state "$small_fix_pr")"
: >"${TEST_TMPDIR}/review-refresh.log"
REFRESHED_REVIEW_DECISION="CHANGES_REQUESTED"
REFRESH_SHOULD_FAIL=0
enriched_review_json=$(_pmp_enrich_prs_with_review_decisions "owner/repo" "[$unknown_review_passing_pr]")
enriched_review_pr=$(printf '%s' "$enriched_review_json" | jq -c '.[0]')
assert_eq "1c.1: passing checks with refreshed CHANGES_REQUESTED classify as human-approval-needed" \
	"human-approval-needed" "$(_pmp_classify_pr_backlog_state "$enriched_review_pr")"
assert_eq "1c.2: passing unknown reviewDecision performs one authoritative enrichment refresh" \
	"1" "$(wc -l <"${TEST_TMPDIR}/review-refresh.log" | tr -d '[:space:]')"
: >"${TEST_TMPDIR}/review-refresh.log"
enriched_review_json=$(_pmp_enrich_prs_with_review_decisions "owner/repo" "[$missing_number_pr]")
assert_eq "1c.2.1: missing PR number does not shift reviewDecision into the number field" \
	"0" "$(wc -l <"${TEST_TMPDIR}/review-refresh.log" | tr -d '[:space:]')"
assert_eq "1c.2.2: missing PR number preserves the original review decision" \
	"9" "$(printf '%s' "$enriched_review_json" | jq -r '.[0].reviewDecision')"
: >"${TEST_TMPDIR}/review-refresh.log"
REFRESHED_REVIEW_DECISION="NONE"
enriched_review_json=$(_pmp_enrich_prs_with_review_decisions "owner/repo" "[$unknown_review_passing_pr]")
enriched_review_pr=$(printf '%s' "$enriched_review_json" | jq -c '.[0]')
assert_eq "1c.3: passing checks with refreshed NONE classify as merge-ready" \
	"merge-ready" "$(_pmp_classify_pr_backlog_state "$enriched_review_pr")"
REFRESH_SHOULD_FAIL=1
enriched_review_json=$(_pmp_enrich_prs_with_review_decisions "owner/repo" "[$unknown_review_passing_pr]")
enriched_review_pr=$(printf '%s' "$enriched_review_json" | jq -c '.[0]')
assert_eq "1c.4: failed review refresh preserves conservative human-approval classification" \
	"human-approval-needed" "$(_pmp_classify_pr_backlog_state "$enriched_review_pr")"
assert_eq "1c.5: failed review refresh preserves UNKNOWN state" \
	"UNKNOWN" "$(printf '%s' "$enriched_review_pr" | jq -r '.reviewDecision')"
REFRESH_SHOULD_FAIL=0
: >"${TEST_TMPDIR}/review-refresh.log"
enriched_review_json=$(_pmp_enrich_prs_with_review_decisions "owner/repo" "[$merge_ready_pr,$unknown_review_failed_pr,$unknown_review_passing_pr]")
_pmp_log_pr_backlog_counts "owner/repo" "$enriched_review_json"
_pmp_sort_prs_by_backlog_priority "$enriched_review_json" "owner/repo" >/dev/null
assert_eq "1c.6: log plus sort do not repeat per-pass authoritative refreshes" \
	"2" "$(wc -l <"${TEST_TMPDIR}/review-refresh.log" | tr -d '[:space:]')"
assert_eq "1c.7: enrichment preserves an existing known review decision" \
	"APPROVED" "$(printf '%s' "$enriched_review_json" | jq -r '.[0].reviewDecision')"
assert_eq "1d: conflicting PR classifies as dirty-conflicted" \
	"dirty-conflicted" "$(_pmp_classify_pr_backlog_state "$dirty_pr")"
assert_eq "1e: changes requested classifies as human-approval-needed" \
	"human-approval-needed" "$(_pmp_classify_pr_backlog_state "$human_pr")"

unsorted_json="[$human_pr,$dirty_pr,$checks_in_progress_pr,$small_fix_pr,$merge_ready_pr]"
sorted_numbers=$(_pmp_sort_prs_by_backlog_priority "$unsorted_json" | jq -r '[.[].number] | join(",")')
assert_eq "2: backlog sort processes merge-ready then fix-needed before lower-value buckets" \
	"1,3,2,4,5" "$sorted_numbers"

second_ready=$(printf '%s' "$merge_ready_pr" | jq -c '.number = 6')
_pulse_merge_queue_priority_keys() { printf '|6|5|'; return 0; }
sorted_numbers=$(_pmp_sort_prs_by_backlog_priority "[$human_pr,$dirty_pr,$checks_in_progress_pr,$small_fix_pr,$merge_ready_pr,$second_ready]" owner/repo | jq -r '[.[].number] | join(",")')
assert_eq "2b: dirty hints break ties without overriding readiness priorities" \
	"6,1,3,2,4,5" "$sorted_numbers"
unset -f _pulse_merge_queue_priority_keys

: >"$LOGFILE"
_pmp_log_pr_backlog_counts "owner/repo" "$unsorted_json"
log_line=$(grep 'PR backlog owner/repo:' "$LOGFILE" 2>/dev/null || true)
assert_eq "3: backlog log exposes all category counts" \
	"[pulse-wrapper] PR backlog owner/repo: total=5, merge-ready=1, checks-in-progress=1, small-fix-needed=1, dirty-conflicted=1, human-approval-needed=1, other=0" \
	"$log_line"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\n%sAll %d PR backlog priority tests passed.%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
fi

printf '\n%s%d/%d PR backlog priority tests failed.%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
exit 1
