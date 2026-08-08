#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#28449: primary merge work must precede bounded
# stuck diagnostics, and zero-progress accounting must reuse same-pass evidence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
STUCK_SCRIPT="${SCRIPT_DIR}/../pulse-merge-stuck.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pulse-primary-first-test-XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export LOGFILE="${TEST_ROOT}/pulse.log"
export STOP_FLAG="${TEST_ROOT}/pulse.stop"
export REPOS_JSON="${TEST_ROOT}/repos.json"
export PULSE_MERGE_CHECKPOINT_FILE="${TEST_ROOT}/merge.checkpoint"
export PULSE_MERGE_PR_CURSOR_FILE="${TEST_ROOT}/merge.cursor"
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=0
export PULSE_MERGE_DIAGNOSTIC_BUDGET_SECONDS=30
mkdir -p "$HOME/.aidevops/logs" "$HOME/.config/aidevops"

cat >"$REPOS_JSON" <<'JSON'
{"initialized_repos":[
  {"slug":"org/seven","path":"/tmp/seven","pulse":true,"local_only":false},
  {"slug":"org/empty","path":"/tmp/empty","pulse":true,"local_only":false}
]}
JSON

# shellcheck source=/dev/null
source "$PROCESS_SCRIPT"
# shellcheck source=/dev/null
source "$STUCK_SCRIPT"
REAL_STUCK_RUN_PASS_DEF=$(declare -f pulse_merge_stuck_run_pass)

TESTS_RUN=0
TESTS_FAILED=0
EVENTS_FILE="${TEST_ROOT}/events.log"
NETWORK_FILE="${TEST_ROOT}/network.log"
ZERO_PROGRESS_CALLS=""
: >"$EVENTS_FILE"
: >"$NETWORK_FILE"
: >"$LOGFILE"

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	return 0
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected=[${expected}] actual=[${actual}]"
	fi
	return 0
}

record_event() {
	local event="$1"
	printf '%s\n' "$event" >>"$EVENTS_FILE"
	return 0
}

repo_allows_pulse_write_actions() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	return 0
}

_pmp_rest_core_priority_allows_next() {
	local priority="$1"
	local context="$2"
	[[ -n "$priority" && -n "$context" ]] || return 1
	return 0
}

_merge_ready_prs_for_repo() {
	local repo_slug="$1"
	local merged_var="$2"
	local closed_var="$3"
	local failed_var="$4"
	local pr_count_var="${5:-}"
	local count=0 pr_number=0

	if [[ "$repo_slug" == "org/seven" ]]; then
		count=7
		pr_number=1
		while [[ "$pr_number" -le "$count" ]]; do
			record_event "primary:${repo_slug}:${pr_number}"
			_pmp_record_same_pass_pr_outcome "$repo_slug" "$pr_number" "sha-${pr_number}" "eligible-unmerged"
			pr_number=$((pr_number + 1))
		done
	fi
	_pmp_mark_same_pass_repo_complete "$repo_slug"
	printf -v "$merged_var" '%s' '0'
	printf -v "$closed_var" '%s' '0'
	printf -v "$failed_var" '%s' "$count"
	if [[ -n "$pr_count_var" ]]; then
		printf -v "$pr_count_var" '%s' "$count"
	fi
	return 0
}

pulse_merge_stuck_run_pass() {
	local repo_slug="$1"
	local completion_var="${2:-}"
	record_event "diagnostic:${repo_slug}"
	if [[ -n "$completion_var" ]]; then
		printf -v "$completion_var" '%s' '1'
	fi
	return 0
}

pulse_merge_zero_progress_record() {
	local eligible="$1"
	local merged="$2"
	local progress="$3"
	ZERO_PROGRESS_CALLS="${ZERO_PROGRESS_CALLS}${eligible}:${merged}:${progress} "
	return 0
}

pulse_pr_list_get() {
	printf 'pulse_pr_list_get\n' >>"$NETWORK_FILE"
	printf '[]'
	return 0
}

gh_pr_view() {
	printf 'gh_pr_view\n' >>"$NETWORK_FILE"
	return 1
}

gh_pr_check_runs_rest() {
	printf 'gh_pr_check_runs_rest\n' >>"$NETWORK_FILE"
	printf '[]'
	return 0
}

merge_ready_prs_all_repos

line_number=0
last_primary=0
first_diagnostic=0
while IFS= read -r event; do
	line_number=$((line_number + 1))
	case "$event" in
	primary:*) last_primary="$line_number" ;;
	diagnostic:*) [[ "$first_diagnostic" -gt 0 ]] || first_diagnostic="$line_number" ;;
	esac
done <"$EVENTS_FILE"

if [[ "$last_primary" -gt 0 && "$first_diagnostic" -gt "$last_primary" ]]; then
	pass "all primary merge attempts finish before stuck diagnostics"
else
	fail "all primary merge attempts finish before stuck diagnostics" "last_primary=${last_primary} first_diagnostic=${first_diagnostic}"
fi
assert_eq "seven same-pass merge failures form the zero-progress denominator" "7:0:0 " "$ZERO_PROGRESS_CALLS"
assert_eq "same-pass zero-progress accounting performs no fallback network reads" "0" "$(wc -l <"$NETWORK_FILE" | tr -d ' ')"

: >"$EVENTS_FILE"
ZERO_PROGRESS_CALLS=""
export PULSE_MERGE_DIAGNOSTIC_BUDGET_SECONDS=0
merge_ready_prs_all_repos
diagnostic_count=0
while IFS= read -r event; do
	case "$event" in diagnostic:*) diagnostic_count=$((diagnostic_count + 1)) ;; esac
done <"$EVENTS_FILE"
assert_eq "zero diagnostic budget defers every stuck scan" "0" "$diagnostic_count"
assert_eq "bounded diagnostics do not suppress authoritative zero-progress accounting" "7:0:0 " "$ZERO_PROGRESS_CALLS"
eval "$REAL_STUCK_RUN_PASS_DEF"

export AIDEVOPS_PULSE_MERGE_OUTCOME_DIR
AIDEVOPS_PULSE_MERGE_OUTCOME_DIR=$(mktemp -d "${TEST_ROOT}/evidence-XXXXXX")
COLLISION_REPO="org/collision"
_pmp_record_same_pass_pr_outcome "$COLLISION_REPO" 101 sha-shared eligible-unmerged
_pmp_record_same_pass_pr_outcome "$COLLISION_REPO" 102 sha-shared eligible-unmerged
_pmp_mark_same_pass_repo_complete "$COLLISION_REPO"
same_sha_count=$(_pmp_count_same_pass_eligible_unmerged "$COLLISION_REPO")
assert_eq "same-head PR outcomes remain distinct" "2" "$same_sha_count"

CHECK_FETCH_FILE="${TEST_ROOT}/check-fetch.log"
: >"$CHECK_FETCH_FILE"
_pmrc_snapshot_checks_json() {
	local repo_slug="$1"
	local head_sha="$2"
	[[ -n "$repo_slug" && -n "$head_sha" ]] || return 1
	printf 'fetch\n' >>"$CHECK_FETCH_FILE"
	printf '[{"name":"Build","status":"completed","conclusion":"success"}]'
	return 0
}

first_checks=$(_pms_check_runs_for_head "org/seven" "sha-evidence")
second_checks=$(_pms_check_runs_for_head "org/seven" "sha-evidence")
assert_eq "repeated detector consumers share one current-head check fetch" "1" "$(wc -l <"$CHECK_FETCH_FILE" | tr -d ' ')"
assert_eq "same-pass check evidence remains exact" "$first_checks" "$second_checks"

: >"$CHECK_FETCH_FILE"
_pmrc_snapshot_checks_json() {
	local repo_slug="$1"
	local head_sha="$2"
	[[ -n "$repo_slug" && -n "$head_sha" ]] || return 1
	printf 'fetch\n' >>"$CHECK_FETCH_FILE"
	printf '[]'
	return 0
}
first_empty_checks=$(_pms_check_runs_for_head "org/seven" "sha-empty-evidence")
second_empty_checks=$(_pms_check_runs_for_head "org/seven" "sha-empty-evidence")
assert_eq "valid empty check evidence is fetched once" "1" "$(wc -l <"$CHECK_FETCH_FILE" | tr -d ' ')"
assert_eq "valid empty check evidence remains exact" "[]" "${first_empty_checks}${second_empty_checks:2}"

: >"$NETWORK_FILE"
_required_contexts_for_default_branch() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	printf 'Build\n'
	return 0
}
gh_pr_check_runs_rest() {
	local repo_slug="$1"
	local head_sha="$2"
	printf 'check-runs:%s:%s\n' "$repo_slug" "$head_sha" >>"$NETWORK_FILE"
	printf '[{"name":"Build","status":"completed","conclusion":"success"}]'
	return 0
}
gh_pr_view() {
	printf 'redundant-head-read\n' >>"$NETWORK_FILE"
	return 1
}
if _check_required_checks_passing "org/seven" "1" "sha-direct"; then
	pass "provided head SHA preserves name-aware required-check validation"
else
	fail "provided head SHA preserves name-aware required-check validation"
fi
assert_eq "provided head SHA removes the redundant PR head read" "check-runs:org/seven:sha-direct" "$(<"$NETWORK_FILE")"

MID_PASS_EVENTS="${TEST_ROOT}/mid-pass-events.log"
: >"$MID_PASS_EVENTS"
MID_PASS_BUDGET_CHECKS=0
pulse_pr_list_get() {
	printf '%s' '[{"number":1,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"updatedAt":"2020-01-01T00:00:00Z","headRefOid":"sha-1"},{"number":2,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"updatedAt":"2020-01-01T00:00:00Z","headRefOid":"sha-2"}]'
	return 0
}
_pms_compute_saturation_state() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\n'
	return 0
}
_pms_diagnostic_budget_exhausted() {
	MID_PASS_BUDGET_CHECKS=$((MID_PASS_BUDGET_CHECKS + 1))
	[[ "$MID_PASS_BUDGET_CHECKS" -ge 4 ]] && return 0
	return 1
}
_pms_handle_classified_pr() {
	local pr_num="$1"
	local repo_slug="$2"
	local is_saturated="$3"
	local pr_meta="${4:-}"
	[[ -n "$repo_slug" && -n "$is_saturated" && -n "$pr_meta" ]] || return 1
	printf '%s\n' "$pr_num" >>"$MID_PASS_EVENTS"
	printf 'HANDLED'
	return 0
}
AIDEVOPS_MERGE_STUCK_AGE_MINUTES=1
AIDEVOPS_MERGE_PATTERN_MIN_PRS=99
mid_pass_complete=1
pulse_merge_stuck_run_pass "org/budget" mid_pass_complete >/dev/null 2>&1
assert_eq "mid-repository budget exhaustion marks diagnostics incomplete" "0" "$mid_pass_complete"
assert_eq "mid-repository budget exhaustion stops before the second PR" "1" "$(<"$MID_PASS_EVENTS")"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\nAll %s primary-first diagnostic tests passed.\n' "$TESTS_RUN"
	exit 0
fi

printf '\n%s/%s primary-first diagnostic tests failed.\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
