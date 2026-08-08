#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-actions-queue-saturation.sh — Tests for the Actions runner queue
# saturation detector (t3211 / GH#21942).
#
# Verifies:
#   1. _check_actions_queue_saturation correctly classifies saturation states
#      against the canonical 2026-04-30 incident shape (110 queued / 3
#      in_progress) and the threshold boundary cases.
#   2. The function fail-opens cleanly on gh-api errors (saturated=0, rc=2).
#   3. Bypass env var (AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION=1) and disable
#      via QUEUED_MIN=0 both short-circuit to saturated=0 without touching
#      the network.
#   4. Custom thresholds via env vars (QUEUED_MIN, RATIO_MIN) take precedence
#      over conf-file defaults.
#   5. _classify_stuck_pr returns STUCK_RUNNER_QUEUE_SATURATION when the
#      caller passes is_saturated=1 AND the PR's rollup contains a QUEUED
#      check; falls through to STUCK_CHECKS_FAILING when is_saturated=0.
#   6. shellcheck cleanliness on pulse-rate-limit-circuit-breaker.sh.
#
# All tests use a `gh` PATH shim so no real network calls are made.

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
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $(printf '%q' "$expected")"
		echo "  actual:   $(printf '%q' "$actual")"
	fi
	return 0
}

assert_match() {
	local label="$1" regex="$2" value="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$value" =~ $regex ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  regex: $regex"
		echo "  value: $(printf '%q' "$value")"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate files, isolate env, install gh shim, source the module.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RATE_LIMIT_HELPER="$SCRIPT_DIR/pulse-rate-limit-circuit-breaker.sh"
MERGE_STUCK_HELPER="$SCRIPT_DIR/pulse-merge-stuck.sh"

for required in "$RATE_LIMIT_HELPER" "$MERGE_STUCK_HELPER"; do
	if [[ ! -f "$required" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $required not found"
		exit 1
	fi
done

# Isolate state — avoid touching the live pulse logs/stats.
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-actions-queue-saturation-XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export PULSE_STATS_FILE="$TEST_TMPDIR/pulse-stats.json"
export LOGFILE="$TEST_TMPDIR/pulse.log"

# Install a `gh` PATH shim. The shim reads env vars to choose its response,
# emulating gh api repos/{slug}/actions/runs?status={queued,in_progress}.
SHIM_DIR="$TEST_TMPDIR/bin"
mkdir -p "$SHIM_DIR"
cat >"$SHIM_DIR/gh-actions-status" <<'SHIM_EOF'
#!/usr/bin/env bash
exit "${GH_STATUS_SHIM_RC:-0}"
SHIM_EOF
chmod +x "$SHIM_DIR/gh-actions-status"
cat >"$SHIM_DIR/gh" <<'SHIM_EOF'
#!/usr/bin/env bash
# Minimal gh shim for test-actions-queue-saturation.sh.
# Honours these env vars set by individual test cases:
#   GH_SHIM_QUEUED_TOTAL      total_count for status=queued response (integer)
#   GH_SHIM_IN_PROGRESS_TOTAL total_count for status=in_progress response (integer)
#   GH_SHIM_FAIL              if "1", emit empty stdout + exit 1 (API error)
#   GH_SHIM_PR_VIEW_JSON      raw JSON to return for `gh pr view` calls
#   GH_SHIM_CHECK_RUNS_JSON   check_runs array for the current head

# NOTE: `local` is invalid at script top-level in bash and aborts the
# script before printf runs — that's why this shim must use plain vars.
# The bug bit us once during test development; do not "tidy" this back.

# Pick out a --jq EXPR from the remaining args (real gh runs jq locally
# on the response body when --jq is passed). Returns the expression on
# stdout, or empty if not found.
extract_jq_expr() {
	local prev=""
	local arg
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			printf '%s' "$arg"
			return 0
		fi
		prev="$arg"
	done
	return 0
}

# Apply jq filter to body (or pass through if no expr given).
apply_jq() {
	local body="$1"
	local expr="$2"
	if [[ -z "$expr" ]]; then
		printf '%s' "$body"
		return 0
	fi
	printf '%s' "$body" | jq -r "$expr" 2>/dev/null
	return 0
}

# Emit a body that matches the response shape the helper expects, then
# apply --jq filter (if any) so the helper's --jq path returns the same
# scalar/object that real `gh api --jq` would return.
emit_body() {
	local body="$1"
	shift
	local expr
	expr=$(extract_jq_expr "$@")
	apply_jq "$body" "$expr"
	echo
	return 0
}

case "$1" in
	api)
		shift
		# First positional after `api` is the endpoint URL. The remaining
		# args may include --jq '<expr>' which we replicate locally so the
		# shim behaves like real gh.
		endpoint="$1"
		shift || true
		if [[ "${GH_SHIM_FAIL:-0}" == "1" ]]; then
			# Empty stdout + nonzero rc → mimics gh-api transport failure.
			exit 1
		fi
		case "$endpoint" in
			*"actions/runs?status=queued"*)
				body=$(printf '{"total_count":%s,"workflow_runs":[]}' "${GH_SHIM_QUEUED_TOTAL:-0}")
				emit_body "$body" "$@"
				exit 0
				;;
			*"actions/runs?status=in_progress"*)
				body=$(printf '{"total_count":%s,"workflow_runs":[]}' "${GH_SHIM_IN_PROGRESS_TOTAL:-0}")
				emit_body "$body" "$@"
				exit 0
				;;
		repos/*/commits/*/check-runs*)
				body=$(printf '{"check_runs":%s}' "${GH_SHIM_CHECK_RUNS_JSON:-[]}")
				emit_body "$body" "$@"
				exit 0
				;;
			repos/*/commits/*/status)
				emit_body '{"statuses":[]}' "$@"
				exit 0
				;;
			*"/branches/"*"/protection"*)
				# Pretend the branch has no protection rules. Returning
				# success with `{}` makes the classifier fall through to
				# the FAILURE check (the protection-error branches are
				# tested separately by test-pulse-merge-stuck.sh).
				emit_body "{}" "$@"
				exit 0
				;;
			repos/*/*)
				# Bare repo metadata. Emit a minimal valid response so
				# `--jq '.default_branch'` filters to "main", letting the
				# helper enter the protection probe (which we satisfy
				# above with a 200/empty so it falls through to FAILURE).
				emit_body '{"default_branch":"main"}' "$@"
				exit 0
				;;
		esac
		# Default for any other api call.
		emit_body "{}" "$@"
		exit 0
		;;
	pr)
		shift
		if [[ "$1" == "view" ]]; then
			# Return the rollup fixture; respect --jq when caller filters.
			# NOTE: cannot inline a default with `${VAR:-{}}` — bash
			# closes the parameter expansion at the first `}`, leaving a
			# literal trailing `}` that corrupts the JSON output. Use an
			# intermediate variable for the default instead.
			pr_view_default='{}'
			body="${GH_SHIM_PR_VIEW_JSON:-$pr_view_default}"
			emit_body "$body" "$@"
			exit 0
		fi
		;;
esac

# Default: pretend success with empty output for any other gh subcommand.
echo '{}'
exit 0
SHIM_EOF
chmod +x "$SHIM_DIR/gh"
PATH="$SHIM_DIR:$PATH"
export PATH

# Reset all relevant env vars before each test class.
#
# IMPORTANT: GH_SHIM_* must be EXPORTED, not just assigned, because they
# are read by the `gh` shim subprocess. The pattern `GH_SHIM_X=v out=$(fn)`
# does NOT export GH_SHIM_X — the prefix-form export only applies when the
# subsequent token is a command, not when it is itself a variable
# assignment. Use `set_shim` below to set + export them in one step.
_reset_env() {
	unset AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD
	unset AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN
	unset AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN
	unset AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION
	unset AIDEVOPS_GH_STATUS_HELPER
	unset GH_STATUS_SHIM_RC
	export AIDEVOPS_SKIP_GITHUB_ACTIONS_STATUS=1
	unset AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER
	unset GH_SHIM_QUEUED_TOTAL
	unset GH_SHIM_IN_PROGRESS_TOTAL
	unset GH_SHIM_FAIL
	unset GH_SHIM_PR_VIEW_JSON
	unset GH_SHIM_CHECK_RUNS_JSON
	unset GH_SHIM_SAME_PASS_CHECK_RUNS_JSON
	return 0
}

# Set + export shim env vars in one call. Accepts KEY=VALUE pairs.
#
# Implementation note: NEVER use `eval "export $kv"` — bash subjects the
# expanded `$kv` to brace expansion, glob expansion, and word splitting,
# which mangles JSON values like `{"a":"b","c":"d"}` (the commas inside
# trigger brace-list expansion → only the first list element gets
# assigned). The split-and-export form below treats the value as a single
# literal string regardless of what it contains.
set_shim() {
	local kv key val
	for kv in "$@"; do
		key="${kv%%=*}"
		val="${kv#*=}"
		export "$key"="$val"
	done
	return 0
}

# Source the helper. Defines _check_actions_queue_saturation. The helper
# uses `set -euo pipefail` which is inherited by our shell. Disable -e
# afterwards because several tests deliberately trigger non-zero return
# codes (the API-error path returns rc=2 by design); without `set +e` the
# test process aborts at the first such case before reaching subsequent
# assertions. We keep `set -u` for the assert helpers.
# shellcheck disable=SC1090
source "$RATE_LIMIT_HELPER"
set +e

if ! declare -F _check_actions_queue_saturation >/dev/null 2>&1; then
	echo "${TEST_RED}FATAL${TEST_NC}: _check_actions_queue_saturation not defined after sourcing $RATE_LIMIT_HELPER"
	exit 1
fi

echo "${TEST_BLUE}━━━ test-actions-queue-saturation.sh ━━━${TEST_NC}"

# Helper: extract a KEY=value field from the helper's stdout.
_field() {
	local key="$1"
	local out="$2"
	printf '%s\n' "$out" | grep -E "^${key}=" | head -1 | cut -d= -f2
}

# ---------------------------------------------------------------------------
# Test class 1: saturation detection at threshold boundaries
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}── 1. Saturation detection ──${TEST_NC}"

# 1a: Canonical 2026-04-30 incident shape (110 queued / 3 in_progress).
_reset_env
set_shim GH_SHIM_QUEUED_TOTAL=110 GH_SHIM_IN_PROGRESS_TOTAL=3
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "incident shape: queued=110" "110" "$(_field queued "$out")"
assert_eq "incident shape: in_progress=3" "3" "$(_field in_progress "$out")"
assert_eq "incident shape: ratio=36" "36" "$(_field ratio "$out")"
assert_eq "incident shape: saturated=1" "1" "$(_field saturated "$out")"

# 1b: Light load — neither absolute nor ratio threshold met.
_reset_env
set_shim GH_SHIM_QUEUED_TOTAL=10 GH_SHIM_IN_PROGRESS_TOTAL=10
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "light load: queued=10" "10" "$(_field queued "$out")"
assert_eq "light load: ratio=1" "1" "$(_field ratio "$out")"
assert_eq "light load: saturated=0" "0" "$(_field saturated "$out")"

# 1c: High absolute, healthy ratio (busy but draining) — NOT saturated.
_reset_env
set_shim GH_SHIM_QUEUED_TOTAL=51 GH_SHIM_IN_PROGRESS_TOTAL=10
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "busy/healthy: queued=51" "51" "$(_field queued "$out")"
assert_eq "busy/healthy: ratio=5" "5" "$(_field ratio "$out")"
assert_eq "busy/healthy: saturated=0" "0" "$(_field saturated "$out")"

# 1d: Just above ratio threshold — IS saturated.
_reset_env
set_shim GH_SHIM_QUEUED_TOTAL=51 GH_SHIM_IN_PROGRESS_TOTAL=4
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "above ratio: queued=51" "51" "$(_field queued "$out")"
assert_eq "above ratio: ratio=12" "12" "$(_field ratio "$out")"
assert_eq "above ratio: saturated=1" "1" "$(_field saturated "$out")"

# 1e: Just below queued threshold — NOT saturated regardless of ratio.
_reset_env
set_shim GH_SHIM_QUEUED_TOTAL=49 GH_SHIM_IN_PROGRESS_TOTAL=1
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "below abs: queued=49" "49" "$(_field queued "$out")"
assert_eq "below abs: ratio=49" "49" "$(_field ratio "$out")"
assert_eq "below abs: saturated=0" "0" "$(_field saturated "$out")"

# 1f: Zero in_progress — denominator clamps to 1, ratio = queued.
_reset_env
set_shim GH_SHIM_QUEUED_TOTAL=200 GH_SHIM_IN_PROGRESS_TOTAL=0
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "zero in_progress: queued=200" "200" "$(_field queued "$out")"
assert_eq "zero in_progress: ratio=200" "200" "$(_field ratio "$out")"
assert_eq "zero in_progress: saturated=1" "1" "$(_field saturated "$out")"

# ---------------------------------------------------------------------------
# Test class 2: fail-open semantics
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}── 2. Fail-open semantics ──${TEST_NC}"

# 2a: gh-api error → return rc=2, saturated=0.
_reset_env
set_shim GH_SHIM_FAIL=1
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
rc=$?
assert_eq "api error: rc=2" "2" "$rc"
assert_eq "api error: saturated=0" "0" "$(_field saturated "$out")"
assert_eq "api error: queued=0" "0" "$(_field queued "$out")"

# 2b: a public Actions incident overrides low/unknown repo queue counts.
_reset_env
export AIDEVOPS_SKIP_GITHUB_ACTIONS_STATUS=0
export AIDEVOPS_GH_STATUS_HELPER="$SHIM_DIR/gh-actions-status"
export GH_STATUS_SHIM_RC=1
set_shim GH_SHIM_QUEUED_TOTAL=2 GH_SHIM_IN_PROGRESS_TOTAL=2
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
rc=$?
assert_eq "provider incident: rc=0" "0" "$rc"
assert_eq "provider incident: saturated=1" "1" "$(_field saturated "$out")"
assert_eq "provider incident: signal exported" "1" "$(_field provider_incident "$out")"

# 2c: Empty repo_slug → return rc=0, saturated=0 (defensive default).
_reset_env
out=$(_check_actions_queue_saturation "")
rc=$?
assert_eq "empty slug: rc=0" "0" "$rc"
assert_eq "empty slug: saturated=0" "0" "$(_field saturated "$out")"

# ---------------------------------------------------------------------------
# Test class 3: bypass + disable controls
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}── 3. Bypass / disable controls ──${TEST_NC}"

# 3a: AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION=1 short-circuits to saturated=0
# even with API responses indicating clear saturation.
_reset_env
set_shim AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION=1 \
	GH_SHIM_QUEUED_TOTAL=110 GH_SHIM_IN_PROGRESS_TOTAL=3
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "bypass env: saturated=0 despite real saturation" "0" "$(_field saturated "$out")"
assert_eq "bypass env: queued=0 (network not consulted)" "0" "$(_field queued "$out")"

# 3b: QUEUED_MIN=0 disables detection entirely.
_reset_env
set_shim AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN=0 \
	GH_SHIM_QUEUED_TOTAL=110 GH_SHIM_IN_PROGRESS_TOTAL=3
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "queued_min=0: saturated=0 (disabled)" "0" "$(_field saturated "$out")"

# ---------------------------------------------------------------------------
# Test class 4: env-var threshold overrides
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}── 4. Threshold env-var overrides ──${TEST_NC}"

# 4a: Lower QUEUED_MIN to 5 — light load now classifies as saturated.
_reset_env
set_shim AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN=5 \
	AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN=2 \
	GH_SHIM_QUEUED_TOTAL=10 GH_SHIM_IN_PROGRESS_TOTAL=2
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "lowered thresholds: ratio=5" "5" "$(_field ratio "$out")"
assert_eq "lowered thresholds: saturated=1" "1" "$(_field saturated "$out")"

# 4b: Raise QUEUED_MIN above incident shape — even canonical incident is OK.
_reset_env
set_shim AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN=200 \
	GH_SHIM_QUEUED_TOTAL=110 GH_SHIM_IN_PROGRESS_TOTAL=3
out=$(_check_actions_queue_saturation "marcusquinn/aidevops")
assert_eq "raised threshold: saturated=0" "0" "$(_field saturated "$out")"

# ---------------------------------------------------------------------------
# Test class 5: integration with _classify_stuck_pr
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}── 5. _classify_stuck_pr integration ──${TEST_NC}"

# Source the merge-stuck module — pulls in _classify_stuck_pr.
# shellcheck disable=SC1090
source "$MERGE_STUCK_HELPER"

if ! declare -F _classify_stuck_pr >/dev/null 2>&1; then
	echo "${TEST_RED}FATAL${TEST_NC}: _classify_stuck_pr not defined after sourcing $MERGE_STUCK_HELPER"
	exit 1
fi

_pmrc_snapshot_checks_json() {
	local repo_slug="$1"
	local head_sha="$2"
	[[ -n "$repo_slug" && -n "$head_sha" ]] || return 1
	printf '%s\n' "${GH_SHIM_CHECK_RUNS_JSON:-[]}"
	return 0
}

_pmp_same_pass_check_evidence_get() {
	local repo_slug="$1"
	local head_sha="$2"
	[[ -n "$repo_slug" && -n "$head_sha" ]] || return 1
	[[ -n "${GH_SHIM_SAME_PASS_CHECK_RUNS_JSON+x}" ]] || return 1
	printf '%s\n' "$GH_SHIM_SAME_PASS_CHECK_RUNS_JSON"
	return 0
}

# 5a: is_saturated=1 + first-priority same-pass checks include QUEUED →
# saturation. The conflicting fallback fixture proves same-pass precedence.
_reset_env
set_shim 'GH_SHIM_PR_VIEW_JSON={"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha123"}' \
	'GH_SHIM_SAME_PASS_CHECK_RUNS_JSON=[{"name":"Maintainer Gate","status":"queued","conclusion":null,"app":{"slug":"github-actions"}}]' \
	'GH_SHIM_CHECK_RUNS_JSON=[{"name":"Lint","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}}]'
classification=$(_classify_stuck_pr "12345" "marcusquinn/aidevops" "1")
assert_eq "saturated+same-pass queued check: classification" "STUCK_RUNNER_QUEUE_SATURATION" "$classification"

# 5b: reset removes same-pass evidence, so an external app queued in the
# fallback fixture during an Actions incident is not runner saturation.
_reset_env
set_shim 'GH_SHIM_PR_VIEW_JSON={"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha123"}' \
	'GH_SHIM_CHECK_RUNS_JSON=[{"name":"Codacy","status":"queued","conclusion":null,"app":{"slug":"codacy-production"}}]'
classification=$(_classify_stuck_pr "12345" "marcusquinn/aidevops" "1")
assert_eq "saturated+external queued check: classification" "STUCK_OTHER" "$classification"

# 5c: is_saturated=0 + rollup has QUEUED check → falls through to STUCK_OTHER.
# The shim's bare repo metadata returns default_branch="main", and the
# protection probe returns "{}" (success path) — neither STUCK_BRANCHPROTECT_*
# branch fires. No FAILURE entries in the rollup → STUCK_OTHER.
_reset_env
set_shim 'GH_SHIM_PR_VIEW_JSON={"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha123"}' \
	'GH_SHIM_CHECK_RUNS_JSON=[{"name":"Maintainer Gate","status":"queued","conclusion":null,"app":{"slug":"github-actions"}}]'
classification=$(_classify_stuck_pr "12345" "marcusquinn/aidevops" "0")
assert_eq "unsaturated+queued check: classification" "STUCK_OTHER" "$classification"

# 5d: is_saturated=1 + rollup has both QUEUED and FAILURE checks → priority
# is QUEUED (the running outage masks per-PR failures).
_reset_env
set_shim 'GH_SHIM_PR_VIEW_JSON={"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha123"}' \
	'GH_SHIM_CHECK_RUNS_JSON=[{"name":"Maintainer Gate","status":"queued","conclusion":null,"app":{"slug":"github-actions"}},{"name":"Lint","status":"completed","conclusion":"failure","app":{"slug":"github-actions"}}]'
classification=$(_classify_stuck_pr "12345" "marcusquinn/aidevops" "1")
assert_eq "saturated+queued+failure: priority QUEUED" "STUCK_RUNNER_QUEUE_SATURATION" "$classification"

# 5e: is_saturated=0 + rollup has FAILURE only → STUCK_CHECKS_FAILING.
_reset_env
set_shim 'GH_SHIM_PR_VIEW_JSON={"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha123"}' \
	'GH_SHIM_CHECK_RUNS_JSON=[{"name":"Lint","status":"completed","conclusion":"failure"}]'
classification=$(_classify_stuck_pr "12345" "marcusquinn/aidevops" "0")
assert_eq "unsaturated+failure only: classification" "STUCK_CHECKS_FAILING" "$classification"

# 5f: Default is_saturated parameter (omitted) → treated as 0.
_reset_env
set_shim 'GH_SHIM_PR_VIEW_JSON={"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha123"}' \
	'GH_SHIM_CHECK_RUNS_JSON=[{"name":"Maintainer Gate","status":"queued","conclusion":null,"app":{"slug":"github-actions"}}]'
classification=$(_classify_stuck_pr "12345" "marcusquinn/aidevops")
assert_eq "default param: treated as is_saturated=0" "STUCK_OTHER" "$classification"

# ---------------------------------------------------------------------------
# Test class 6: shellcheck cleanliness
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}── 6. Shellcheck ──${TEST_NC}"

if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck "$RATE_LIMIT_HELPER" >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: shellcheck pulse-rate-limit-circuit-breaker.sh"
		TESTS_RUN=$((TESTS_RUN + 1))
	else
		echo "${TEST_RED}FAIL${TEST_NC}: shellcheck pulse-rate-limit-circuit-breaker.sh"
		shellcheck "$RATE_LIMIT_HELPER" || true
		TESTS_RUN=$((TESTS_RUN + 1))
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
else
	echo "  shellcheck not installed — skipping"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}━━━ Summary ━━━${TEST_NC}"
echo "Tests run:    ${TESTS_RUN}"
echo "Tests failed: ${TESTS_FAILED}"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}All tests passed.${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}${TESTS_FAILED} test(s) failed.${TEST_NC}"
	exit 1
fi
