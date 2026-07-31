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

printf 'PASS dispatch candidate snapshots reuse enumeration, preserve modes, and invalidate on state mutation\n'
