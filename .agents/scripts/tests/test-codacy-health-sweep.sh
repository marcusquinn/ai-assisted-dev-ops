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
GRADE="B"
BRANCH="trunk"

gopass() {
	[[ "$MODE" == "missing-token" ]] && return 1
	printf 'test-token'
	return 0
}

git() {
	[[ "$MODE" == "remote-failure" ]] && return 1
	printf '%s\tHEAD\n' "$REMOTE_SHA"
	return 0
}

curl() {
	local arguments="$*"
	printf '%s\n' "$arguments" >>"${TMP_HOME}/requests"
	if [[ "$MODE" == "api-failure" ]]; then
		return 1
	fi
	if [[ "$arguments" == *"issues/overview"* ]]; then
		[[ "$arguments" == *"-X POST"* && "$arguments" == *"\"branchName\":\"${BRANCH}\""* ]] || return 2
		case "$MODE" in
		policy-drift)
			printf '%s' '{"data":{"counts":{"patterns":[{"id":"Bandit_B404","title":"Import subprocess","total":76},{"id":"ESLint8_es-x_no-modules","total":84},{"id":"ESLint8_es-x_no-block-scoped-variables","total":56},{"id":"ESLint8_es-x_no-trailing-commas","total":40}]}}}'
			;;
		overview-failure) return 1 ;;
		overview-missing) printf '%s' '{"data":{"counts":{}}}' ;;
		overview-invalid) printf '%s' '{"data":{"counts":{"patterns":[{"id":"Bandit_B404","total":"76"}]}}}' ;;
		search-page) printf '%s' '{"data":[],"pagination":{"total":2468,"cursor":"2"}}' ;;
		*) printf '%s' '{"data":{"counts":{"patterns":[]}}}' ;;
		esac
		return 0
	fi
	if [[ "$MODE" == "malformed" ]]; then
		printf '%s' '{"grade":"B"}'
	else
		# Redacted shape from the public API v3.1.0 summary, 2026-09-05.
		jq -cn --arg grade "$GRADE" --arg sha "$SUMMARY_SHA" --arg branch "$BRANCH" --argjson loc "$LOC" \
			'{data:{grade:88,gradeLetter:$grade,issuesCount:2468,loc:$loc,complexFilesCount:54,
			lastAnalysedCommit:{sha:$sha},branch:{name:$branch,isDefault:true}}}'
	fi
	return 0
}

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/stats-quality-sweep-tools.sh"

MODE="policy-drift"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
STATE_FILE="${QUALITY_SWEEP_STATE_DIR}/owner-repo.codacy-health.json"
assert_contains "first observation detects policy drift" "$RESULT" "**Analysis health**: POLICY_DRIFT"
if [[ -e "$STATE_FILE" ]]; then
	printf 'FAIL first drift observation must not seed a baseline\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
fi

MODE="healthy"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "first valid sample is baseline unknown" "$RESULT" "**Analysis health**: BASELINE_UNKNOWN"
assert_json_value "first valid sample stores healthy LOC" "$STATE_FILE" '.healthy_loc' "1000"
assert_contains "live grade letter parsed rather than numeric score" "$RESULT" "**Grade**: B"
assert_contains "issue count comes from summary" "$RESULT" "**Open issues**: 2468"
assert_contains "live LOC field parsed" "$RESULT" "**Analysed LOC**: 1000"
assert_contains "live complex files field parsed" "$RESULT" "**Complex files**: 54"
assert_contains "nested analysed SHA parsed" "$RESULT" "**Analysed SHA**: $SUMMARY_SHA"
assert_contains "B grade is explicitly below target" "$RESULT" "**Grade target**: A / BELOW_TARGET"

if command grep -qE 'branch=main|issues/search' "${TMP_HOME}/requests"; then
	printf 'FAIL requests must use default-branch summary and aggregate overview\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
fi

RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "matching baseline is healthy" "$RESULT" "**Analysis health**: HEALTHY"

GRADE="A"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "current healthy A is at target" "$RESULT" "**Grade target**: A / AT_TARGET"

REMOTE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "stale SHA never renders healthy" "$RESULT" "**Analysis health**: STALE_ANALYSIS"
assert_json_value "stale SHA retains baseline" "$STATE_FILE" '.healthy_loc' "1000"
assert_contains "stale A is not verified at target" "$RESULT" "**Grade target**: A / UNVERIFIED"

REMOTE_SHA="$SUMMARY_SHA"
GRADE="B"
LOC=900
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "small LOC change remains comparable" "$RESULT" "**Analysis health**: HEALTHY"
assert_json_value "small LOC drop cannot ratchet denominator down" "$STATE_FILE" '.healthy_loc' "1000"
assert_json_value "retained baseline metrics remain one coherent sample" "$STATE_FILE" '.grade' "A"
GRADE="A"
LOC=800
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "exactly 80 percent is not degraded" "$RESULT" "**Analysis health**: HEALTHY"
assert_json_value "successive small drops retain high-water baseline" "$STATE_FILE" '.healthy_loc' "1000"
LOC=799
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "LOC below 80 percent is degraded" "$RESULT" "**Analysis health**: INDEX_DEGRADED"
assert_json_value "degraded LOC retains baseline" "$STATE_FILE" '.healthy_loc' "1000"
assert_contains "degraded A is not verified at target" "$RESULT" "**Grade target**: A / UNVERIFIED"

LOC=1000
MODE="policy-drift"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "documented rule renders policy drift" "$RESULT" "**Analysis health**: POLICY_DRIFT"
assert_contains "documented rule includes exact aggregate count" "$RESULT" "\`Bandit_B404\`: 76"
assert_contains "ES modules policy drift includes exact count" "$RESULT" "\`ESLint8_es-x_no-modules\`: 84"
assert_contains "block-scoped variables drift includes exact count" "$RESULT" "\`ESLint8_es-x_no-block-scoped-variables\`: 56"
assert_contains "trailing commas drift includes exact count" "$RESULT" "\`ESLint8_es-x_no-trailing-commas\`: 40"
assert_contains "drifting A is not verified at target" "$RESULT" "**Grade target**: A / UNVERIFIED"

for MODE in overview-failure overview-missing overview-invalid search-page; do
	RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
	assert_contains "$MODE is unknown, not healthy or zero findings" "$RESULT" "**Analysis health**: UNKNOWN"
	assert_contains "$MODE preserves available summary evidence" "$RESULT" "**Open issues**: 2468"
	assert_json_value "$MODE retains baseline" "$STATE_FILE" '.healthy_loc' "1000"
done

MODE="healthy"
GRADE="unexpected-grade"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "invalid grade fails closed" "$RESULT" "**Grade**: UNKNOWN"
GRADE="A"
LOC=0
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "zero LOC fails closed" "$RESULT" "**Analysis health**: UNKNOWN"
LOC=1000
REMOTE_SHA=""
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "missing remote SHA fails closed" "$RESULT" "**Analysis health**: UNKNOWN"
REMOTE_SHA="$SUMMARY_SHA"

MODE="remote-failure"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "failed Git transport renders UNKNOWN under strict mode" "$RESULT" "**Analysis health**: UNKNOWN"
assert_json_value "failed Git transport retains baseline" "$STATE_FILE" '.healthy_loc' "1000"

MODE="malformed"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "malformed response is unknown" "$RESULT" "**Analysis health**: UNKNOWN"
assert_json_value "malformed response retains baseline" "$STATE_FILE" '.healthy_loc' "1000"

MODE="api-failure"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "API failure is unknown" "$RESULT" "**Analysis health**: UNKNOWN"
assert_json_value "API failure retains baseline" "$STATE_FILE" '.healthy_loc' "1000"

MODE="missing-token"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo")
assert_contains "missing credentials are visible, not an omitted report" "$RESULT" "**Analysis health**: UNKNOWN"
assert_contains "missing credentials cannot verify A" "$RESULT" "**Grade target**: A / UNVERIFIED"
assert_json_value "missing credentials retain baseline" "$STATE_FILE" '.healthy_loc' "1000"

MODE="healthy"
QUALITY_SWEEP_STATE_DIR="${TMP_HOME}/not-a-directory"
printf 'unwritable state parent\n' >"$QUALITY_SWEEP_STATE_DIR"
RESULT=$(_sweep_codacy "owner/repo" "/fake/repo" 2>/dev/null)
assert_contains "state write failure is unknown" "$RESULT" "**Analysis health**: UNKNOWN"
assert_contains "state write failure cannot verify A" "$RESULT" "**Grade target**: A / UNVERIFIED"

if bash "${SCRIPTS_DIR}/stats-quality-sweep-tools.sh" >"${TMP_HOME}/usage" 2>&1; then
	printf 'FAIL direct CLI must reject missing arguments\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
fi

rm -rf "$TMP_HOME"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
printf 'All Codacy health sweep tests passed\n'
exit 0
