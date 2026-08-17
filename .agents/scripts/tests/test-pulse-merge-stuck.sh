#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-stuck.sh — Structural tests for t3193 stuck-merge detector.
#
# Verifies (no live GitHub API calls):
#   1. pulse-merge-stuck.conf exists with the four canonical env-var defaults.
#   2. pulse-merge-stuck.sh sources cleanly and applies positive-integer defaults.
#   3. _pms_iso_to_epoch round-trips a valid ISO timestamp; returns 0 for garbage.
#   4. _pms_hash_fingerprint returns a 16-hex-char digest, deterministic
#      across calls with the same input, and survives empty input.
#   5. pulse_stats_set_gauge / pulse_stats_get_gauge round-trip integer values
#      against an isolated PULSE_STATS_FILE; non-numeric set is rejected.
#   6. pulse_merge_zero_progress_record:
#        merged>0 → gauge reset to 0
#        non-merge deterministic progress → gauge reset to 0
#        merged=0 + eligible=0 → gauge reset to 0 (streak broken)
#        merged=0 + eligible>0 → gauge incremented by 1
#   7. _pms_count_eligible_unmerged_for_repo excludes PRs blocked by
#      read-only merge gates (required checks, interactive PRs held for manual
#      merge, worker PR with no linked issue, external-contributor PR without
#      maintainer crypto-approval, non-collaborator author without maintainer
#      crypto-approval, stale merged PR-list entries, and unknown authors that
#      must not bypass the collaborator check) and keeps processing when GitHub
#      returns a null PR author for deleted users.
#   8. Effective preflight snapshots suppress superseded check-run failures.
#   9. Pattern-outage candidates include aged worker CHANGES_REQUESTED PRs
#      without changing individual escalation eligibility.
#  10. _detect_pattern_outage excludes per-PR review/policy gates, preserves
#      genuine shared CI failures, and de-duplicates repeated PR observations.
#      Open and closed outage markers both deterministically suppress re-filing.
#      Generated Markdown includes the final affected PR.
#  11. pulse-merge-stuck.sh and pulse-stats-helper.sh pass shellcheck.
#
# The test never makes real network calls; functions that require gh API
# (_classify_stuck_pr, _escalate_individual_stuck_pr, full pulse_merge_stuck_run_pass)
# are intentionally not exercised here —
# they're integration-level and would need a live fixture repo.

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

assert_gt() {
	local label="$1" lhs="$2" rhs="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$lhs" =~ ^[0-9]+$ && "$rhs" =~ ^[0-9]+$ && "$lhs" -gt "$rhs" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label ($lhs > $rhs ?)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate files, isolate runtime state, source the modules.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SCRIPT_DIR/pulse-merge-stuck.sh"
STATS_HELPER="$SCRIPT_DIR/pulse-stats-helper.sh"
MERGE_SCRIPT="$SCRIPT_DIR/pulse-merge.sh"
CONF_FILE="$SCRIPT_DIR/../configs/pulse-merge-stuck.conf"

for required in "$MODULE" "$STATS_HELPER" "$MERGE_SCRIPT"; do
	if [[ ! -f "$required" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $required not found"
		exit 1
	fi
done

# Isolate state and audit writes so tests cannot perturb live user logs. Recovery
# tests call the audited close wrapper with stub issue numbers, so the audit path
# must be redirected before sourcing the module and its shared wrappers.
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-pulse-merge-stuck-XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export PULSE_STATS_FILE="$TEST_TMPDIR/pulse-stats.json"
export LOGFILE="$TEST_TMPDIR/pulse.log"
export GH_AUDIT_LOG_FILE="$TEST_TMPDIR/gh-audit.log"

# Source the helpers. pulse-stats-helper.sh sets -euo pipefail; turn that off
# after source so a single failed assertion doesn't abort the whole suite.
# shellcheck source=/dev/null
source "$MODULE"
set +e
set +o pipefail

echo "${TEST_BLUE}=== t3193: pulse-merge-stuck detector tests ===${TEST_NC}"
echo ""

# ---------------------------------------------------------------------------
# Section 1: conf file integrity.
# ---------------------------------------------------------------------------
echo "--- Section 1: conf file integrity ---"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$CONF_FILE" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1a: pulse-merge-stuck.conf exists"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1a: pulse-merge-stuck.conf NOT found at $CONF_FILE"
fi

for entry in \
	AIDEVOPS_MERGE_STUCK_AGE_MINUTES \
	AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES \
	AIDEVOPS_MERGE_PATTERN_MIN_PRS \
	AIDEVOPS_MERGE_STUCK_ENABLED; do
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "^${entry}=" "$CONF_FILE" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 1: conf contains ${entry}"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 1: conf missing ${entry}"
	fi
done
echo ""

# ---------------------------------------------------------------------------
# Section 2: defaults applied as positive integers after sourcing.
# ---------------------------------------------------------------------------
echo "--- Section 2: post-source defaults ---"

assert_match "2a: AIDEVOPS_MERGE_STUCK_AGE_MINUTES is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:-x}"
assert_match "2b: AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:-x}"
assert_match "2c: AIDEVOPS_MERGE_PATTERN_MIN_PRS is positive int" \
	"^[0-9]+$" "${AIDEVOPS_MERGE_PATTERN_MIN_PRS:-x}"
assert_match "2d: AIDEVOPS_MERGE_STUCK_ENABLED is 0|1" \
	"^[01]$" "${AIDEVOPS_MERGE_STUCK_ENABLED:-x}"

assert_gt "2e: STUCK_AGE_MINUTES > 0" "$AIDEVOPS_MERGE_STUCK_AGE_MINUTES" "0"
assert_gt "2f: ZERO_PROGRESS_CYCLES > 0" "$AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES" "0"
assert_gt "2g: PATTERN_MIN_PRS > 1" "$AIDEVOPS_MERGE_PATTERN_MIN_PRS" "1"
echo ""

# ---------------------------------------------------------------------------
# Section 3: pure-logic helpers.
# ---------------------------------------------------------------------------
echo "--- Section 3: _pms_iso_to_epoch + _pms_hash_fingerprint ---"

# 3a: ISO timestamp → positive epoch
epoch=$(_pms_iso_to_epoch "2026-04-30T14:00:00Z")
assert_gt "3a: valid ISO 2026-04-30T14:00:00Z → epoch > 0" "$epoch" "0"

# 3b: garbage → 0
garbage_epoch=$(_pms_iso_to_epoch "not-a-date")
assert_eq "3b: garbage input → 0" "0" "$garbage_epoch"

# 3c: hash returns 16 hex chars
hash_out=$(_pms_hash_fingerprint "Format,Lint,Typecheck")
assert_match "3c: hash is 16 hex chars" "^[0-9a-f]{16}$" "$hash_out"

# 3d: hash deterministic
hash_a=$(_pms_hash_fingerprint "stable-input")
hash_b=$(_pms_hash_fingerprint "stable-input")
assert_eq "3d: hash deterministic for same input" "$hash_a" "$hash_b"

# 3e: hash differs for different input (collision check, not cryptographic)
hash_x=$(_pms_hash_fingerprint "input-one")
hash_y=$(_pms_hash_fingerprint "input-two")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$hash_x" != "$hash_y" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 3e: hash differs across distinct inputs"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 3e: hash collision on trivially distinct inputs ($hash_x)"
fi

# 3f: empty input still produces 16 hex chars
hash_empty=$(_pms_hash_fingerprint "")
assert_match "3f: hash of empty string is 16 hex chars" "^[0-9a-f]{16}$" "$hash_empty"
echo ""

# ---------------------------------------------------------------------------
# Section 4: pulse_stats_set_gauge / pulse_stats_get_gauge round-trip.
# ---------------------------------------------------------------------------
echo "--- Section 4: gauge round-trip ---"

# 4a: get on missing file returns "0"
rm -f "$PULSE_STATS_FILE"
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4a: get on missing file → 0" "0" "$got"

# 4b: set then get round-trip
pulse_stats_set_gauge "test_gauge_a" "7" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4b: set 7 → get 7" "7" "$got"

# 4c: overwrite
pulse_stats_set_gauge "test_gauge_a" "42" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4c: overwrite to 42 → get 42" "42" "$got"

# 4d: non-numeric is rejected (silently — gauge stays at prior value)
pulse_stats_set_gauge "test_gauge_a" "not-a-number" >/dev/null 2>&1
got=$(pulse_stats_get_gauge "test_gauge_a")
assert_eq "4d: non-numeric set ignored, prior value retained" "42" "$got"

# 4e: distinct gauges don't collide
pulse_stats_set_gauge "test_gauge_b" "99" >/dev/null 2>&1
got_a=$(pulse_stats_get_gauge "test_gauge_a")
got_b=$(pulse_stats_get_gauge "test_gauge_b")
assert_eq "4e: gauge_a unaffected by gauge_b write" "42" "$got_a"
assert_eq "4e: gauge_b reads back" "99" "$got_b"
echo ""

# ---------------------------------------------------------------------------
# Section 5: pulse_merge_zero_progress_record state transitions.
# ---------------------------------------------------------------------------
echo "--- Section 5: zero_progress_record transitions ---"

GH_CALLS="$TEST_TMPDIR/gh-calls.log"
: >"$GH_CALLS"
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE=""
export GH_CALLS PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE

gh() {
	local command_name="$1"
	local subcommand="$2"
	if [[ "$command_name" == "issue" && "$subcommand" == "list" ]]; then
		if [[ -n "${PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE:-}" ]]; then
			printf '%s\n' "$PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE"
		fi
		return 0
	fi
	if [[ "$command_name" == "issue" && ("$subcommand" == "comment" || "$subcommand" == "close") ]]; then
		printf '%s\n' "gh $*" >>"$GH_CALLS"
		return 0
	fi
	return 1
}

gh_create_issue() {
	printf '%s\n' "gh_create_issue $*" >>"$GH_CALLS"
	return 0
}

PMS_TEST_ALLOW_WRITE="1"
repo_allows_pulse_write_actions() {
	local repo_slug="$1"
	[[ "$repo_slug" == "marcusquinn/aidevops" && "${PMS_TEST_ALLOW_WRITE:-1}" == "1" ]]
	return $?
}

# Reset gauge for a clean state.
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1

# 5a: merged>0 + eligible=anything → gauge reset to 0
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "3" >/dev/null 2>&1
pulse_merge_zero_progress_record 5 1 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5a: merged>0 resets cycles to 0 (was 3)" "0" "$got"

# 5b: merged=0 + eligible=0 → gauge reset to 0 (idle cycle breaks streak)
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "2" >/dev/null 2>&1
pulse_merge_zero_progress_record 0 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5b: merged=0 + eligible=0 resets cycles to 0 (was 2)" "0" "$got"

# 5b.1: a healthy idle cycle also sweeps stale open zero-progress issues when
# pulse-stats.json has already lost the non-zero gauge (for example after log
# rotation/truncation). The sweep is throttled in production, so disable the
# interval here for deterministic coverage.
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE="23036"
AIDEVOPS_MERGE_ZERO_PROGRESS_RECOVERY_CHECK_SECONDS=0
: >"$GH_CALLS"
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1
pulse_merge_zero_progress_record 0 0 >/dev/null 2>&1
if grep -q 'gh issue close 23036 --repo marcusquinn/aidevops --reason completed' "$GH_CALLS"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 5b.1: stale zero-progress meta-issue is swept after recovered idle cycle"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5b.1: stale zero-progress meta-issue sweep is missing"
	echo "  gh calls: $(cat "$GH_CALLS")"
fi
TESTS_RUN=$((TESTS_RUN + 1))
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE=""
AIDEVOPS_MERGE_ZERO_PROGRESS_RECOVERY_CHECK_SECONDS=3600

# 5b.2: recovery writes are skipped when the authenticated runner is not a
# repo admin/maintainer/write collaborator.
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE="23037"
PMS_TEST_ALLOW_WRITE="0"
AIDEVOPS_MERGE_ZERO_PROGRESS_RECOVERY_CHECK_SECONDS=0
: >"$GH_CALLS"
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1
pulse_merge_zero_progress_record 0 0 >/dev/null 2>&1
if grep -q 'gh issue close 23037' "$GH_CALLS"; then
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5b.2: read-only runner must not close recovered zero-progress issue"
	echo "  gh calls: $(cat "$GH_CALLS")"
else
	echo "${TEST_GREEN}PASS${TEST_NC}: 5b.2: read-only runner skips recovered zero-progress issue write"
fi
TESTS_RUN=$((TESTS_RUN + 1))
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE=""
PMS_TEST_ALLOW_WRITE="1"
AIDEVOPS_MERGE_ZERO_PROGRESS_RECOVERY_CHECK_SECONDS=3600

# 5b.3: conflict close/remediation progress is not merge throughput, but it is
# deterministic queue-draining progress and must break a zero-progress streak.
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE="23038"
: >"$GH_CALLS"
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "3" >/dev/null 2>&1
pulse_merge_zero_progress_record 2 0 1 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5b.3: conflict progress resets cycles to 0 (was 3)" "0" "$got"
if grep -q 'gh issue close 23038 --repo marcusquinn/aidevops --reason completed' "$GH_CALLS"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 5b.3: conflict progress auto-closes zero-progress issue"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5b.3: conflict progress auto-closes zero-progress issue"
	echo "  gh calls: $(cat "$GH_CALLS")"
fi
TESTS_RUN=$((TESTS_RUN + 1))
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE=""

# 5b.4: recovery sweeps from an already-zero gauge must not compose a
# contradictory "after a 0-cycle streak while gauge was already 0" reason.
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE="23039"
AIDEVOPS_MERGE_ZERO_PROGRESS_RECOVERY_CHECK_SECONDS=0
: >"$LOGFILE"
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1
pulse_merge_zero_progress_record 2 0 1 >/dev/null 2>&1
if grep -q 'deterministic conflict/close progress action(s) while zero-progress gauge was already 0' "$LOGFILE" &&
	! grep -q 'after a 0-cycle zero-progress streak while zero-progress gauge was already 0' "$LOGFILE"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 5b.4: already-zero recovery reason is direct and non-contradictory"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5b.4: already-zero recovery reason is contradictory"
	echo "  log: $(cat "$LOGFILE")"
fi
TESTS_RUN=$((TESTS_RUN + 1))
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE=""
AIDEVOPS_MERGE_ZERO_PROGRESS_RECOVERY_CHECK_SECONDS=3600

# 5c: merged=0 + eligible>0 → gauge increments by 1
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "0" >/dev/null 2>&1
pulse_merge_zero_progress_record 4 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5c: merged=0 + eligible=4 → cycles 0→1" "1" "$got"

# 5d: a second consecutive zero-progress cycle increments again.
pulse_merge_zero_progress_record 4 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5d: second consecutive zero-progress → 1→2" "2" "$got"

# 5e: a successful merge then resets the streak to 0.
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE="23035"
pulse_merge_zero_progress_record 4 1 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
assert_eq "5e: merge during stuck-streak resets cycles to 0" "0" "$got"
if grep -q 'gh issue close 23035 --repo marcusquinn/aidevops --reason completed' "$GH_CALLS"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 5f: recovered zero-progress meta-issue is auto-closed"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5f: recovered zero-progress meta-issue is auto-closed"
	echo "  gh calls: $(cat "$GH_CALLS")"
fi
TESTS_RUN=$((TESTS_RUN + 1))
PMS_TEST_OPEN_ZERO_PROGRESS_ISSUE=""

# 5g: issue filing is edge-triggered at the configured threshold. Once the
# gauge is already above threshold, closing the open issue externally must not
# produce one fresh meta-issue per pulse cycle.
: >"$GH_CALLS"
AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=5
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "4" >/dev/null 2>&1
pulse_stats_set_gauge "pulse_merge_eligible_stuck_pr_count" "0" >/dev/null 2>&1
pulse_merge_zero_progress_record 1 0 >/dev/null 2>&1
pulse_merge_zero_progress_record 1 0 >/dev/null 2>&1
create_count=$(grep -c 'gh_create_issue --repo marcusquinn/aidevops' "$GH_CALLS")
assert_eq "5g: zero-progress meta-issue files once on threshold crossing" "1" "$create_count"

# 5h: an invalid threshold environment value falls back to the safe default
# instead of making Bash integer comparisons abort the pulse.
: >"$GH_CALLS"
AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES="not-a-number"
pulse_stats_set_gauge "pulse_merge_zero_progress_cycles" "4" >/dev/null 2>&1
pulse_stats_set_gauge "pulse_merge_eligible_stuck_pr_count" "0" >/dev/null 2>&1
pulse_merge_zero_progress_record 1 0 >/dev/null 2>&1
got=$(pulse_stats_get_gauge "pulse_merge_zero_progress_cycles")
create_count=$(grep -c 'gh_create_issue --repo marcusquinn/aidevops' "$GH_CALLS")
assert_eq "5h: invalid zero-progress threshold still increments gauge" "5" "$got"
assert_eq "5h: invalid zero-progress threshold falls back to default for filing" "1" "$create_count"
AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=5
echo ""

# ---------------------------------------------------------------------------
# Section 6: zero-progress eligible count gate parity.
# ---------------------------------------------------------------------------
echo "--- Section 6: zero-progress count gate parity ---"

export PULSE_PR_LIST_PROVIDER_CACHE_DIR="$TEST_TMPDIR/pr-list-cache"
export PULSE_PR_LIST_PROVIDER_CACHE_TTL=3600
unset PULSE_PR_LIST_PROVIDER_CACHE_DISABLE
PMS_TEST_PR_LIST_CALLS="$TEST_TMPDIR/pr-list-calls.log"
: >"$PMS_TEST_PR_LIST_CALLS"

gh_pr_list() {
	printf '%s\n' "$*" >>"$PMS_TEST_PR_LIST_CALLS"
	printf '%s\n' '[
{"number":101,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":102,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:worker"}],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":103,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:worker"}],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":104,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"hold-for-review"}],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":105,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"labels":[],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":106,"mergeable":"CONFLICTING","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":107,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"external"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":108,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":109,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":null,"updatedAt":"2026-01-01T00:00:00Z"},
{"number":110,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":null,"author":{"login":"external"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":111,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:interactive"}],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":112,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"origin:interactive"},{"name":"allow-auto-merge"}],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":113,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"external-contributor"}],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":114,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[{"name":"external-contributor"}],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"},
{"number":115,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":{"login":"trusted"},"updatedAt":"2026-01-01T00:00:00Z"}
]'
	return 0
}

PMS_TEST_PR_VIEW_CALLS="$TEST_TMPDIR/pr-view-calls.log"
: >"$PMS_TEST_PR_VIEW_CALLS"
gh_pr_view() {
	local pr_number="$1"
	local repo_flag="$2"
	local repo_slug="$3"
	shift 3
	[[ "$repo_flag" == "--repo" && -n "$repo_slug" ]] || return 1
	printf '%s:%s:%s:%s\n' "$pr_number" "$repo_slug" "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" "$*" >>"$PMS_TEST_PR_VIEW_CALLS"
	if [[ "$pr_number" == "108" ]]; then
		printf 'CLOSED'
	elif [[ "$pr_number" == "115" ]]; then
		return 1
	else
		printf 'OPEN'
	fi
	return 0
}

_check_required_checks_passing() {
	local repo_slug="$1"
	local pr_number="$2"
	[[ -n "$repo_slug" ]] || return 1
	case "$pr_number" in
	101) return 1 ;;
	*) return 0 ;;
	esac
}

_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	[[ -n "$repo_slug" ]] || return 1
	case "$pr_number" in
	102) return 0 ;;
	*)
		printf '77'
		return 0
		;;
	esac
}

_is_collaborator_author() {
	local pr_author="$1"
	local repo_slug="$2"
	[[ -n "$repo_slug" ]] || return 1
	if [[ "$pr_author" == "trusted" ]]; then
		return 0
	fi
	return 1
}

_has_maintainer_crypto_approval() {
	local pr_number="$1"
	local repo_slug="$2"
	[[ -n "$pr_number" && -n "$repo_slug" ]] || return 1
	if [[ "$pr_number" == "114" ]]; then
		return 0
	fi
	return 1
}

_interactive_pr_auto_merge_allowed() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"
	[[ -n "$pr_number" && -n "$repo_slug" ]] || return 1
	if [[ ",${labels_str}," == *",allow-auto-merge,"* ]]; then
		return 0
	fi
	return 1
}

got=$(_pms_count_eligible_unmerged_for_repo "example/repo")
assert_eq "6a: zero-progress count excludes read-only merge-gate blockers" "4" "$got"
closed_state_calls=$(grep -cF '108:example/repo:1:--json state --jq .state // ""' "$PMS_TEST_PR_VIEW_CALLS" 2>/dev/null || true)
assert_eq "6a.1: stale merged candidates receive an uncached current-state check" "1" "$closed_state_calls"
unavailable_state_calls=$(grep -cF '115:example/repo:1:--json state --jq .state // ""' "$PMS_TEST_PR_VIEW_CALLS" 2>/dev/null || true)
assert_eq "6a.2: unavailable current-state reads retain the cached candidate" "1" "$unavailable_state_calls"

_pms_compute_saturation_state() {
	printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\nprovider_incident=0\n'
	return 0
}

_pms_handle_classified_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local is_saturated="$3"
	[[ -n "$pr_number" && -n "$repo_slug" && -n "$is_saturated" ]] || return 1
	printf 'HANDLED'
	return 0
}

AIDEVOPS_MERGE_STUCK_AGE_MINUTES=1
AIDEVOPS_MERGE_PATTERN_MIN_PRS=99
pulse_merge_stuck_run_pass "example/repo" >/dev/null 2>&1
shape_calls=$(grep -cF -- '--json number,isDraft,labels,author,updatedAt,headRefOid --limit 50' "$PMS_TEST_PR_LIST_CALLS" 2>/dev/null || true)
assert_eq "6a.3: stuck scans share one provider-cache PR-list shape" "1" "$shape_calls"
AIDEVOPS_MERGE_PATTERN_MIN_PRS=3

PMS_TEST_COUNT_AUTHORS_FILE="$TEST_TMPDIR/count-authors.log"
: >"$PMS_TEST_COUNT_AUTHORS_FILE"
_pms_pr_counts_for_zero_progress() {
	local repo_slug="$1"
	local pr_number="$2"
	local labels_str="$3"
	local pr_author="$4"
	: "$labels_str"
	[[ -n "$repo_slug" && -n "$pr_number" ]] || return 1
	printf '%s:%s\n' "$pr_number" "$pr_author" >>"$PMS_TEST_COUNT_AUTHORS_FILE"
	return 0
}

export PULSE_PR_LIST_PROVIDER_CACHE_DIR="$TEST_TMPDIR/pr-list-cache-null-author"
gh_pr_list() {
	printf '%s\n' '[
{"number":109,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"author":null,"updatedAt":"2026-01-01T00:00:00Z"}
]'
	return 0
}

got=$(_pms_count_eligible_unmerged_for_repo "example/repo")
count_authors=$(<"$PMS_TEST_COUNT_AUTHORS_FILE")
assert_eq "6b: null author does not abort zero-progress candidate parsing" "1" "$got"
assert_eq "6c: null author falls back to unknown" "109:unknown" "$count_authors"
echo ""

# GH#24383: GitHub can return "Merge already in progress" for a PR that a
# previous pulse cycle has already submitted for server-side merge. That is
# progress, not a deterministic merge failure; otherwise the zero-progress
# detector can file false collapse issues while GitHub is completing the merge.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "Merge already in progress" "$MERGE_SCRIPT" &&
	grep -Fq "_handle_post_merge_actions \"\$pr_number\" \"\$repo_slug\" \"\$linked_issue\" \"\$merge_summary\" \"\$_ipr_labels\"" "$MERGE_SCRIPT" &&
	grep -Fq "return \$?" "$MERGE_SCRIPT"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 6d: merge-in-progress is counted as zero-progress-breaking progress"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 6d: merge-in-progress progress accounting is missing"
fi
echo ""

# ---------------------------------------------------------------------------
# Section 7: REST check-run classification helpers.
# ---------------------------------------------------------------------------
echo "--- Section 7: REST check-run classification helpers ---"

gh_pr_view() {
	local pr_number="$1"
	local repo_flag="$2"
	local repo_slug="$3"
	: "$repo_flag"
	[[ -n "$repo_slug" ]] || return 1
	case "$pr_number" in
	201) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-queued"}' ;;
	202) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-failing"}' ;;
	203) printf 'sha-failing' ;;
	204) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-legacy-failing"}' ;;
	205) printf 'sha-legacy-failing' ;;
	206) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-legacy-error"}' ;;
	207) printf 'sha-legacy-error' ;;
	208) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-clean-ruleset"}' ;;
	209) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-clean-ruleset-fail"}' ;;
	210) printf 'sha-superseded-failure' ;;
	*) printf '{"labels":[],"mergeable":"MERGEABLE","headRefOid":"sha-clean"}' ;;
	esac
	return 0
}

gh_pr_check_runs_rest() {
	local repo_slug="$1"
	local head_sha="$2"
	[[ -n "$repo_slug" ]] || return 1
	case "$head_sha" in
	sha-queued) printf '[{"name":"Build","conclusion":null,"status":"queued","app":{"slug":"github-actions"}}]' ;;
	sha-failing) printf '[{"name":"Format","conclusion":"failure","status":"completed"},{"name":"Lint","conclusion":"timed_out","status":"completed"}]' ;;
	sha-legacy-failing) printf '[{"context":"legacy-ci","state":"failure"}]' ;;
	sha-legacy-error) printf '[{"context":"legacy-error","state":"error"}]' ;;
	sha-superseded-failure) printf '[{"name":"gate / Maintainer Review & Assignee Gate","conclusion":"cancelled","status":"completed"}]' ;;
	*) printf '[]' ;;
	esac
	return 0
}

gh() {
	local command_name="${1:-}"
	local path_arg="${2:-}"
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/repo" ]]; then
		printf 'main'
		return 0
	fi
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/ruleset-repo" ]]; then
		printf 'main'
		return 0
	fi
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/ruleset-fail" ]]; then
		printf 'main'
		return 0
	fi
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/repo/branches/main/protection/required_status_checks" ]]; then
		printf '{}'
		return 0
	fi
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/ruleset-repo/branches/main/protection/required_status_checks" ]]; then
		printf '{"message":"Not Found"}' >&2
		return 1
	fi
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/ruleset-fail/branches/main/protection/required_status_checks" ]]; then
		printf '{"message":"Not Found"}' >&2
		return 1
	fi
	return 1
}

_required_contexts_from_rulesets_for_default_branch() {
	local repo_slug="$1"
	local default_branch="$2"
	[[ "$default_branch" == "main" ]] || return 1
	if [[ "$repo_slug" == "example/ruleset-repo" ]]; then
		printf 'CI / build\n'
		return 0
	fi
	if [[ "$repo_slug" == "example/ruleset-fail" ]]; then
		return 7
	fi
	return 0
}

got=$(_classify_stuck_pr "201" "example/repo" "1")
assert_eq "7a: saturated queued check classifies as runner saturation" \
	"STUCK_RUNNER_QUEUE_SATURATION" "$got"

issue_gate_rc=0
_pms_should_file_runner_saturation_issue 1 1 2 || issue_gate_rc=$?
assert_eq "7a.1: provider incidents do not file runner-pool repair issues" "1" "$issue_gate_rc"

issue_gate_rc=0
_pms_should_file_runner_saturation_issue 1 0 2 || issue_gate_rc=$?
assert_eq "7a.2: measured runner saturation still files repair issues" "0" "$issue_gate_rc"

got=$(_classify_stuck_pr "202" "example/repo" "0")
assert_eq "7b: REST check-run failure classifies as checks failing" \
	"STUCK_CHECKS_FAILING" "$got"

got=$(_pms_failure_fingerprint "203" "example/repo")
assert_eq "7c: failure fingerprint comes from REST check-runs" \
	"Format,Lint" "$got"

got=$(_classify_stuck_pr "204" "example/repo" "0")
assert_eq "7d: legacy status context state=failure classifies as checks failing" \
	"STUCK_CHECKS_FAILING" "$got"

got=$(_pms_failure_fingerprint "205" "example/repo")
assert_eq "7e: legacy status context fingerprint uses context name" \
	"legacy-ci" "$got"

got=$(_classify_stuck_pr "206" "example/repo" "0")
assert_eq "7f: legacy status context state=error classifies as checks failing" \
	"STUCK_CHECKS_FAILING" "$got"

got=$(_pms_failure_fingerprint "207" "example/repo")
assert_eq "7g: legacy error status context fingerprint uses context name" \
	"legacy-error" "$got"

got=$(_classify_stuck_pr "208" "example/ruleset-repo" "0")
assert_eq "7h: rulesets required checks prevent branch-protection 404 classification" \
	"STUCK_OTHER" "$got"

got=$(_classify_stuck_pr "209" "example/ruleset-fail" "0")
ruleset_fail_rc=$?
assert_eq "7i: ruleset helper failure reports branch-protection API error" \
	"STUCK_BRANCHPROTECT_API_ERROR" "$got"
assert_eq "7j: ruleset helper failure propagates helper exit code" \
	"7" "$ruleset_fail_rc"

_pmrc_snapshot_checks_json() {
	local repo_slug="$1"
	local head_sha="$2"
	[[ -n "$repo_slug" && -n "$head_sha" ]] || return 1
	printf '[{"name":"maintainer-gate","conclusion":"success","status":"completed"}]'
	return 0
}

got=$(_pms_failure_fingerprint "210" "example/repo")
assert_eq "7k: effective snapshot suppresses superseded check-run failure" "" "$got"
unset -f _pmrc_snapshot_checks_json
echo ""

# ---------------------------------------------------------------------------
# Section 8: pattern outage deduplication.
# ---------------------------------------------------------------------------
echo "--- Section 8: pattern outage deduplication ---"

pattern_candidate_fixture='[
  {"number":101,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"updatedAt":"2025-01-01T00:00:00Z"},
  {"number":102,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"labels":[{"name":"origin:worker"}],"updatedAt":"2025-01-01T00:00:00Z"},
  {"number":103,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"labels":[],"updatedAt":"2025-01-01T00:00:00Z"},
  {"number":104,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":true,"labels":[{"name":"origin:worker"}],"updatedAt":"2025-01-01T00:00:00Z"},
  {"number":105,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"labels":[{"name":"origin:worker"},{"name":"hold-for-review"}],"updatedAt":"2025-01-01T00:00:00Z"},
  {"number":106,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"labels":[{"name":"origin:worker-takeover"}],"updatedAt":"2026-01-01T00:00:00Z"},
  {"number":107,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","isDraft":false,"labels":[{"name":"origin:worker"}],"updatedAt":"not-a-timestamp"}
]'
pattern_now=$(_pms_iso_to_epoch "2026-01-01T00:00:00Z")
pattern_candidates=$(_pms_collect_pattern_outage_candidates \
	"$pattern_candidate_fixture" "7" "$pattern_now" "60")
assert_eq "8a: pattern candidates add only aged worker review-blocked PRs" \
	$'101\n102' "$pattern_candidates"
assert_eq "8b: CHANGES_REQUESTED worker remains ineligible for individual escalation" \
	"0" "$(_pms_is_eligible_stuck "$(printf '%s' "$pattern_candidate_fixture" | jq -c '.[1]')")"

_pms_failure_fingerprint() {
	local pr_number="$1"
	local repo_slug="$2"
	[[ -n "$repo_slug" ]] || return 1
	case "$pr_number" in
	11 | 12 | 13) printf 'E2E Shard 1/4,E2E Shard 2/4' ;;
	21 | 22 | 23) printf 'CodeRabbit' ;;
	31 | 32 | 33) printf 'gate / Maintainer Review & Assignee Gate' ;;
	*) printf '' ;;
	esac
	return 0
}

# Preserve the production filing function before replacing it with the
# lightweight detector spy below.
eval "$(declare -f _pms_file_outage_issue | sed '1s/_pms_file_outage_issue/_pms_file_outage_issue_production/')"

PMS_TEST_OUTAGE_ARGS=""
_pms_file_outage_issue() {
	local repo_slug="$1"
	local count="$2"
	local fingerprint="$3"
	local prs="$4"
	PMS_TEST_OUTAGE_ARGS="${repo_slug}|${count}|${fingerprint}|${prs}"
	return 0
}

AIDEVOPS_MERGE_PATTERN_MIN_PRS=3
_detect_pattern_outage "example/repo" $'11\n11\n12\n13\n'
assert_eq "8c: genuine shared CI failure files one outage despite duplicate observations" \
	"example/repo|3|E2E Shard 1/4,E2E Shard 2/4|11,12,13" \
	"$PMS_TEST_OUTAGE_ARGS"

PMS_TEST_OUTAGE_ARGS=""
_detect_pattern_outage "example/repo" $'21\n22\n23\n'
assert_eq "8d: CodeRabbit cluster does not file a broken-base outage" \
	"" "$PMS_TEST_OUTAGE_ARGS"

PMS_TEST_OUTAGE_ARGS=""
_detect_pattern_outage "example/repo" $'31\n32\n33\n'
assert_eq "8e: maintainer review and assignee gate cluster does not file an outage" \
	"" "$PMS_TEST_OUTAGE_ARGS"

assert_eq "8f: mixed policy and genuine CI fingerprint remains outage-eligible" \
	"1" "$(
		_pms_is_per_pr_gate_fingerprint 'CodeRabbit,CI / build'
		printf '%s' "$?"
	)"

got=$(_pms_format_pr_markdown_list "11,12,13")
assert_eq "8g: affected-PR Markdown retains the final entry" \
	$'- #11\n- #12\n- #13' "$got"

eval "$(declare -f _pms_diagnostic_budget_exhausted | sed '1s/_pms_diagnostic_budget_exhausted/_pms_diagnostic_budget_exhausted_production/')"
PMS_TEST_BUDGET_CALLS=0
_pms_diagnostic_budget_exhausted() {
	PMS_TEST_BUDGET_CALLS=$((PMS_TEST_BUDGET_CALLS + 1))
	if [[ "$PMS_TEST_BUDGET_CALLS" -gt 1 ]]; then
		return 0
	fi
	return 1
}
PMS_TEST_OUTAGE_ARGS=""
_detect_pattern_outage "example/repo" $'11\n12\n13\n'
assert_eq "8h: exhausted diagnostic budget defers partial outage aggregate" \
	"" "$PMS_TEST_OUTAGE_ARGS"
unset -f _pms_diagnostic_budget_exhausted
eval "$(declare -f _pms_diagnostic_budget_exhausted_production | sed '1s/_pms_diagnostic_budget_exhausted_production/_pms_diagnostic_budget_exhausted/')"
unset -f _pms_diagnostic_budget_exhausted_production

PMS_TEST_EXISTING_STATE="OPEN"
PMS_TEST_CLOSE_CALLS=0
PMS_TEST_CREATE_CALLS=0
gh() {
	local command_name="$1"
	local resource_name="${2:-}"
	if [[ "$command_name" == "api" && "$resource_name" == "repos/example/repo" ]]; then
		printf 'main'
		return 0
	fi
	if [[ "$command_name" == "issue" && "$resource_name" == "list" ]]; then
		printf '41\t%s' "$PMS_TEST_EXISTING_STATE"
		return 0
	fi
	return 1
}
_pms_maybe_close_resolved_outage_issue() {
	local repo_slug="$1" issue_number="$2" fingerprint="$3"
	[[ -n "$repo_slug" && -n "$issue_number" && -n "$fingerprint" ]] || return 1
	PMS_TEST_CLOSE_CALLS=$((PMS_TEST_CLOSE_CALLS + 1))
	return 0
}
gh_create_issue() {
	PMS_TEST_CREATE_CALLS=$((PMS_TEST_CREATE_CALLS + 1))
	return 0
}

_pms_file_outage_issue_production "example/repo" "3" "CI / build" "11,12,13"
assert_eq "7f: open marker suppresses filing and runs stale-resolution check" \
	"1|0" "${PMS_TEST_CLOSE_CALLS}|${PMS_TEST_CREATE_CALLS}"

PMS_TEST_EXISTING_STATE="CLOSED"
PMS_TEST_CLOSE_CALLS=0
PMS_TEST_CREATE_CALLS=0
_pms_file_outage_issue_production "example/repo" "3" "CI / build" "11,12,13"
assert_eq "7g: closed marker is a tombstone that suppresses re-filing" \
	"0|0" "${PMS_TEST_CLOSE_CALLS}|${PMS_TEST_CREATE_CALLS}"
echo ""

# ---------------------------------------------------------------------------
# Section 9: default branch guidance.
# ---------------------------------------------------------------------------
echo "--- Section 9: default branch guidance ---"

gh() {
	local command_name="${1:-}"
	local path_arg="${2:-}"
	if [[ "$command_name" == "api" && "$path_arg" == "repos/example/repo" ]]; then
		printf 'develop'
		return 0
	fi
	return 1
}

got=$(_pms_default_branch "example/repo")
assert_eq "8a: default branch resolves from repo API" "develop" "$got"
echo ""

# ---------------------------------------------------------------------------
# Section 10: shellcheck cleanliness.
# ---------------------------------------------------------------------------
echo "--- Section 10: shellcheck ---"

run_shellcheck() {
	local label="$1" file="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! command -v shellcheck >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label (shellcheck not installed — skipping)"
		return 0
	fi
	local sc_out sc_rc
	sc_out=$(shellcheck "$file" 2>&1)
	sc_rc=$?
	if [[ $sc_rc -eq 0 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "$sc_out"
	fi
	return 0
}

run_shellcheck "9a: pulse-merge-stuck.sh passes shellcheck" "$MODULE"
run_shellcheck "9b: pulse-stats-helper.sh passes shellcheck" "$STATS_HELPER"
echo ""

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failures ===${TEST_NC}"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
