#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Hermetic Codacy health-state coverage for the quality sweep.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)" || exit 1
TMP_HOME=$(mktemp -d)
export HOME="$TMP_HOME"
export QUALITY_SWEEP_STATE_DIR="${TMP_HOME}/state"
mkdir -p "$QUALITY_SWEEP_STATE_DIR"

TESTS_FAILED=0

assert_contains() {
	local label="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == *"$expected"* ]]; then
		printf 'PASS %s\n' "$label"
	else
		printf 'FAIL %s: expected %s\n' "$label" "$expected"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_json_value() {
	local label="$1"
	local file="$2"
	local query="$3"
	local expected="$4"
	local actual
	actual=$(jq -r "$query" "$file")
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS %s\n' "$label"
	else
		printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

SUMMARY_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REMOTE_SHA="$SUMMARY_SHA"
MODE="healthy"
LOC=1000

gopass() {
	printf 'test-token'
	return 0
}

git() {
	printf '%s\tHEAD\n' "$REMOTE_SHA"
	return 0
}

curl() {
	local arguments="$*"
	if [[ "$MODE" == "api-failure" ]]; then
		return 1
	fi
	if [[ "$arguments" == *"issues/search"* ]]; then
		if [[ "$MODE" == "policy-drift" ]]; then
			printf '%s' '{"pagination":{"total":17},"patternTotals":{"Bandit_B404":69}}'
		else
			printf '%s' '{"pagination":{"total":17},"patternTotals":{}}'
		fi
		return 0
	fi
	if [[ "$MODE" == "malformed" ]]; then
		printf '%s' '{"grade":"B"}'
	else
		printf '{"grade":"B","totalLinesOfCode":%s,"complexFiles":4,"lastAnalyzedCommit":"%s"}' "$LOC" "$SUMMARY_SHA"
	fi
	return 0
}

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/stats-quality-sweep-tools.sh"

RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
STATE_FILE="${QUALITY_SWEEP_STATE_DIR}/owner-repo.codacy-health.json"
assert_contains "first valid sample is baseline unknown" "$RESULT" "**Analysis health**: BASELINE_UNKNOWN"
assert_json_value "first valid sample stores healthy LOC" "$STATE_FILE" '.healthy_loc' "1000"

RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "matching baseline is healthy" "$RESULT" "**Analysis health**: HEALTHY"

REMOTE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "stale SHA never renders healthy" "$RESULT" "**Analysis health**: STALE_ANALYSIS"
assert_json_value "stale SHA retains baseline" "$STATE_FILE" '.healthy_loc' "1000"

REMOTE_SHA="$SUMMARY_SHA"
LOC=799
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "LOC below 80 percent is degraded" "$RESULT" "**Analysis health**: INDEX_DEGRADED"
assert_json_value "degraded LOC retains baseline" "$STATE_FILE" '.healthy_loc' "1000"

LOC=1000
MODE="policy-drift"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "documented rule renders policy drift" "$RESULT" "**Analysis health**: POLICY_DRIFT"
assert_contains "documented rule includes exact count" "$RESULT" "\`Bandit_B404\`: 69"

MODE="malformed"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "malformed response is unknown" "$RESULT" "**Analysis health**: UNKNOWN"
assert_json_value "malformed response retains baseline" "$STATE_FILE" '.healthy_loc' "1000"

MODE="api-failure"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "API failure is unknown" "$RESULT" "**Analysis health**: UNKNOWN"
assert_json_value "API failure retains baseline" "$STATE_FILE" '.healthy_loc' "1000"

rm -rf "$TMP_HOME"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
printf 'All Codacy health sweep tests passed\n'
exit 0
