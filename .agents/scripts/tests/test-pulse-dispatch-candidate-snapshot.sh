#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pulse-candidate-snapshot-XXXXXX")"

cleanup() {
	rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export LOGFILE="${TEST_ROOT}/pulse.log"
mkdir -p "$AIDEVOPS_TEMP_DIR" "${HOME}/.aidevops/logs"
: >"$LOGFILE"

# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"

BUILD_COUNT_FILE="${TEST_ROOT}/build-count"
BUILD_MODE_FILE="${TEST_ROOT}/build-mode"
: >"$BUILD_COUNT_FILE"
: >"$BUILD_MODE_FILE"
_PULSE_CYCLE_ID="test-cycle-candidate-snapshot"

build_ranked_dispatch_candidates_json() {
	local per_repo_limit="$1"
	local dependency_normalization_mode="${2:-normalize}"
	local call_count=0
	: "$per_repo_limit"
	call_count=$(wc -l <"$BUILD_COUNT_FILE" 2>/dev/null || printf '0')
	printf 'call\n' >>"$BUILD_COUNT_FILE"
	printf '%s\n' "$dependency_normalization_mode" >>"$BUILD_MODE_FILE"
	printf '[{"number":%s}]\n' "$((call_count + 1))"
	return 0
}

first=$(_dispatch_ranked_candidates_json 50 "skip")
second=$(_dispatch_ranked_candidates_json 50 "skip")
[[ "$first" == '[{"number":1}]' && "$second" == "$first" ]] || {
	printf 'FAIL candidate snapshot was not reused: first=%s second=%s\n' "$first" "$second" >&2
	exit 1
}
normalized_before_invalidation=$(_dispatch_ranked_candidates_json 50)
skip_after_normalize=$(_dispatch_ranked_candidates_json 50 "skip")
[[ "$normalized_before_invalidation" == '[{"number":2}]' && "$skip_after_normalize" == "$first" ]] || {
	printf 'FAIL candidate snapshots collided across normalization modes\n' >&2
	exit 1
}
[[ "$(wc -l <"$BUILD_COUNT_FILE" | tr -d ' ')" == "2" ]] || {
	printf 'FAIL candidate builder did not build once per normalization mode\n' >&2
	exit 1
}
normalize_snapshot_file=$(_dispatch_candidate_snapshot_path 50)
skip_snapshot_file=$(_dispatch_candidate_snapshot_path 50 "skip")
[[ "$normalize_snapshot_file" != "$skip_snapshot_file" && -f "$normalize_snapshot_file" && -f "$skip_snapshot_file" ]] || {
	printf 'FAIL candidate snapshot paths are not mode-specific\n' >&2
	exit 1
}

_dispatch_invalidate_candidate_snapshot "test_state_mutation" 50
third=$(_dispatch_ranked_candidates_json 50)
[[ "$third" == '[{"number":3}]' ]] || {
	printf 'FAIL candidate snapshot did not rebuild after invalidation: %s\n' "$third" >&2
	exit 1
}

PULSE_RUNNABLE_ISSUE_LIMIT=50
triage_marker=$(_dispatch_cycle_cache_path "pulse-triage-prepass" ".done")
printf 'done\n' >"$triage_marker"
_dispatch_cleanup_cycle_cache
[[ ! -e "$normalize_snapshot_file" && ! -e "$skip_snapshot_file" && ! -e "$triage_marker" ]] || {
	printf 'FAIL cycle cache cleanup left candidate or triage artifacts behind\n' >&2
	exit 1
}

export PULSE_DISPATCH_CANDIDATE_SNAPSHOT_ENABLED=0
fourth=$(_dispatch_ranked_candidates_json 50 "skip")
fifth=$(_dispatch_ranked_candidates_json 50)
[[ "$fourth" == '[{"number":4}]' && "$fifth" == '[{"number":5}]' ]] || {
	printf 'FAIL candidate snapshot escape hatch did not bypass cache\n' >&2
	exit 1
}
[[ "$(<"$BUILD_MODE_FILE")" == $'skip\nnormalize\nnormalize\nskip\nnormalize' ]] || {
	printf 'FAIL candidate builder did not receive normalization modes: %s\n' "$(<"$BUILD_MODE_FILE")" >&2
	exit 1
}

# A small runnable-count diagnostic sample must not limit dispatch scanning.
# Three benignly blocked candidates must not hide a later eligible candidate.
unset PULSE_DISPATCH_CANDIDATE_SNAPSHOT_ENABLED
_PULSE_CYCLE_ID="test-cycle-stale-candidate-snapshot"
fresh=$(_dispatch_ranked_candidates_json 50)
snapshot=$(_dispatch_candidate_snapshot_path 50)
jq '.captured_at = 0' "$snapshot" >"${snapshot}.test"
mv "${snapshot}.test" "$snapshot"
refreshed=$(_dispatch_ranked_candidates_json 50)
[[ "$fresh" != "$refreshed" ]] || { printf 'FAIL expired snapshot hides new work\n' >&2; exit 1; }
jq '.captured_at = 9999999999' "$snapshot" >"${snapshot}.test"
mv "${snapshot}.test" "$snapshot"
future_refreshed=$(_dispatch_ranked_candidates_json 50)
[[ "$refreshed" != "$future_refreshed" ]] || { printf 'FAIL future snapshot accepted\n' >&2; exit 1; }
_dispatch_invalidate_candidate_snapshot "test_failure" 50
build_ranked_dispatch_candidates_json() { return 1; }
if _dispatch_ranked_candidates_json 50; then
	printf 'FAIL failed enumeration became successful empty queue\n' >&2
	exit 1
fi
[[ ! -f "$snapshot" ]] || { printf 'FAIL failed enumeration cached\n' >&2; exit 1; }

dispatch_log="${TEST_ROOT}/dispatch-scan.log"
: >"$dispatch_log"
_dispatch_compute_capacity() { printf '2 0 2\n'; return 0; }
_dispatch_ranked_candidates_json() {
	printf 'scan_limit=%s\n' "$1" >>"$dispatch_log"
	printf '%s\n' '[
		{"number":9101}, {"number":9102}, {"number":9103}, {"number":9104}
	]'
	return 0
}
_dispatch_run_prepasses() { printf '%s 0 0\n' "$1"; return 0; }
_dispatch_order_idle_borrowing_candidates() { printf '%s\n' "$1"; return 0; }
_dispatch_max_compute_parallel() { printf '1\n'; return 0; }
_dispatch_graphql_budget_allows_next() { return 0; }
_dispatch_rest_core_progress_allows_next() { return 0; }
_dispatch_maybe_engage_throttle() { return 0; }
_dispatch_process_candidate() {
	printf '%s\n' "$1" >>"$dispatch_log"
	case "$1" in
	*'"number":9101'* | *'"number":9102'* | *'"number":9103'*) return 3 ;;
	esac
	return 0
}
gh() {
	if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
		printf 'testuser\n'
	fi
	return 0
}
PULSE_RUNNABLE_ISSUE_LIMIT=3
dispatch_count=$(dispatch_max)
scan_limit=$(grep -o 'scan_limit=[0-9]*' "$dispatch_log" | cut -d= -f2)
grep -q '"number":9104' "$dispatch_log" && [[ "$dispatch_count" == "1" && "$scan_limit" == "1000" ]] || {
	printf 'FAIL dispatch did not scan past benign head blocks: count=%s scan_limit=%s log=%s\n' "$dispatch_count" "$scan_limit" "$(tr '\n' ',' <"$dispatch_log")" >&2
	exit 1
}

_dispatch_ranked_candidates_json() { return 1; }
LOGFILE="${TEST_ROOT}/enumeration-failure.log"
if dispatch_max; then
	printf 'FAIL dispatch_max swallowed enumeration failure\n' >&2
	exit 1
fi
grep -q 'candidate enumeration unavailable' "$LOGFILE" || exit 1
if grep -q 'skipped: no ranked candidates' "$LOGFILE"; then
	printf 'FAIL unavailable queue was reported empty\n' >&2
	exit 1
fi

printf 'PASS dispatch candidate snapshots reuse enumeration, preserve modes, and invalidate on state mutation\n'
