#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify canonical tiers and truthful comprehension benchmark outcomes.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TEST_REPO_ROOT="$(cd "$TEST_SCRIPT_DIR/../../.." && pwd)" || exit 1
HELPER="$TEST_REPO_ROOT/.agents/scripts/comprehension-benchmark-helper.sh"
UPDATE_STATE="$TEST_REPO_ROOT/.agents/scripts/comprehension-lib/update_state.py"

tests_run=0
tests_passed=0

pass() {
	local name="$1"
	tests_run=$((tests_run + 1))
	tests_passed=$((tests_passed + 1))
	printf 'PASS: %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	tests_run=$((tests_run + 1))
	printf 'FAIL: %s\n  %s\n' "$name" "$detail" >&2
	return 0
}

assert_equals() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$name"
		return 0
	fi
	fail "$name" "expected '$expected', got '$actual'"
	return 0
}

assert_nonzero() {
	local actual="$1"
	local name="$2"
	if [[ "$actual" -ne 0 ]]; then
		pass "$name"
		return 0
	fi
	fail "$name" "expected a non-zero exit status"
	return 0
}

assert_file_exists() {
	local path="$1"
	local name="$2"
	if [[ -f "$path" ]]; then
		pass "$name"
		return 0
	fi
	fail "$name" "missing file: $path"
	return 0
}

write_scenario() {
	local path="$1"
	local expected_tier="$2"
	printf '%s\n' \
		'file: .agents/AGENTS.md' \
		"tier_minimum: $expected_tier" \
		'scenarios:' \
		'  - name: stub scenario' \
		'    prompt: follow the canonical tier contract' \
		'    expected:' \
		'      contains:' \
		'        - pass' >"$path"
	return 0
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# Sourcing exposes pure orchestration functions; the helper's executable entry
# point must not terminate or mutate the caller.
# shellcheck source=/dev/null
source "$HELPER" >/dev/null

negative_check=$(deterministic_check "Do not proceed with the unsafe edit." '{"not_contains":["proceed"]}')
assert_equals "false" "$(printf '%s' "$negative_check" | jq -r '.pass')" "forbidden substring still prevents deterministic pass"
assert_equals "true" "$(printf '%s' "$negative_check" | jq -r '.ambiguous')" "forbidden substring is adjudicated for negation and quotation context"

missing_check=$(deterministic_check "Use the safe linked workspace." '{"contains":["worktree"]}')
assert_equals "true" "$(printf '%s' "$missing_check" | jq -r '.ambiguous')" "missing expected wording is adjudicated for semantic equivalents"

length_check=$(deterministic_check "short" '{"min_length":100}')
assert_equals "true" "$(printf '%s' "$length_check" | jq -r '.hard_fail // false')" "objective length violation remains a deterministic hard failure"

rc=0
fast_fail=$(detect_fast_fail "Read .agents/example.md" '["confabulation"]' "Context includes .agents/example.md" '{}' 2>/dev/null) || rc=$?
assert_equals "0" "$rc" "paths supplied by full agent context are not confabulation"
assert_equals "" "$fast_fail" "known contextual paths produce no fast-fail trigger"

rc=0
detect_fast_fail "I will review it later" '["structural_violation"]' "context" '{"action":["stop"]}' >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "missing explicit action can trigger structural fast-fail"

rc=0
detect_fast_fail "brief" '["disengagement"]' "context" '{"min_length":100}' >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "disengagement threshold derives from scenario min_length"

COMPREHENSION_STUB_MODE="standard-pass"
run_scenario() {
	local agent_file="$1"
	local scenario_json="$2"
	local tier="$3"
	local scenario_name=""
	scenario_name=$(printf '%s' "$scenario_json" | jq -r '.name // "stub"')
	case "$COMPREHENSION_STUB_MODE" in
	all-fail)
		format_result "$scenario_name" "$tier" "fail" "stub"
		return 1
		;;
	standard-pass)
		if [[ "$tier" == "standard" ]]; then
			format_result "$scenario_name" "$tier" "pass" "stub"
			return 0
		fi
		format_result "$scenario_name" "$tier" "fail" "stub"
		return 1
		;;
	simple-pass)
		if [[ "$tier" == "simple" ]]; then
			format_result "$scenario_name" "$tier" "pass" "stub"
			return 0
		fi
		format_result "$scenario_name" "$tier" "fail" "stub"
		return 1
		;;
	*)
		printf 'unknown stub mode: %s\n' "$COMPREHENSION_STUB_MODE" >&2
		return 1
		;;
	esac
}

rc=0
escalation=$(COMPREHENSION_STUB_MODE="all-fail" escalate_scenario ".agents/AGENTS.md" '{"name":"all fail"}') || rc=$?
assert_nonzero "$rc" "all-tier failure returns non-zero"
assert_equals "unresolved" "${escalation%%:*}" "all-tier failure reports no compatible tier"

mkdir -p "$sandbox/scenarios" "$sandbox/results"
write_scenario "$sandbox/scenarios/match.yaml" "standard"
write_scenario "$sandbox/scenarios/mismatch.yaml" "simple"
write_scenario "$sandbox/scenarios/legacy.yaml" "sonnet"

rc=0
match_result=$(COMPREHENSION_STUB_MODE="standard-pass" cmd_test "$sandbox/scenarios/match.yaml" 2>/dev/null) || rc=$?
assert_equals "0" "$rc" "matching expected tier succeeds"
assert_equals "standard" "$(printf '%s' "$match_result" | jq -r '.actual_tier')" "matching result records canonical tier"

rc=0
mismatch_result=$(COMPREHENSION_STUB_MODE="standard-pass" cmd_test "$sandbox/scenarios/mismatch.yaml" 2>/dev/null) || rc=$?
assert_nonzero "$rc" "expected-tier mismatch returns non-zero"
assert_equals "false" "$(printf '%s' "$mismatch_result" | jq -r '.matched')" "expected-tier mismatch is explicit in JSON"

rc=0
unresolved_result=$(COMPREHENSION_STUB_MODE="all-fail" cmd_test "$sandbox/scenarios/match.yaml" 2>/dev/null) || rc=$?
assert_nonzero "$rc" "unresolved scenario returns non-zero"
assert_equals "unresolved" "$(printf '%s' "$unresolved_result" | jq -r '.actual_tier')" "unresolved scenario is not downgraded to simple"

rc=0
COMPREHENSION_STUB_MODE="simple-pass" cmd_test "$sandbox/scenarios/legacy.yaml" >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "legacy provider-family tier is rejected"

TESTS_DIR="$sandbox/scenarios"
RESULTS_DIR="$sandbox/results"
rm -f "$sandbox/scenarios/legacy.yaml"
rc=0
COMPREHENSION_STUB_MODE="standard-pass" cmd_sweep >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "sweep fails when any expected tier mismatches"
assert_file_exists "$sandbox/results/latest-sweep.json" "sweep persists the result consumed by report and update-state"

rc=0
python3 - "$TEST_REPO_ROOT/.agents/tests/comprehension" "$TEST_REPO_ROOT" <<'PY' || rc=$?
import sys
from pathlib import Path

import yaml

allowed = {"simple", "standard", "thinking"}
required = {
    "tools--build-agent--agent-review.yaml",
    "tools--build-agent--build-agent.yaml",
    "workflows--define.yaml",
}
test_dir = Path(sys.argv[1])
repo_root = Path(sys.argv[2])
bad = []
missing_coverage = sorted(required - {path.name for path in test_dir.glob("*.yaml")})
if missing_coverage:
    bad.append("missing focused coverage: " + ", ".join(missing_coverage))
for path in sorted(test_dir.glob("*.yaml")):
    data = yaml.safe_load(path.read_text())
    tier = data.get("tier_minimum")
    if tier not in allowed:
        bad.append(f"{path.name}:{tier}")
    target = repo_root / data.get("file", "")
    if not target.is_file():
        bad.append(f"{path.name}:missing target {target}")
if bad:
    raise SystemExit("invalid comprehension fixtures: " + "; ".join(bad))
PY
assert_equals "0" "$rc" "comprehension fixtures use canonical tiers and cover current targets"

printf '%s\n' '{"files":{".agents/one.md":{},".agents/two.md":{}}}' >"$sandbox/state.json"
printf '%s\n' '{"summary":{"total":2,"matched":2,"mismatched":0,"errors":0},"results":[{"file":".agents/one.md","actual_tier":"simple","matched":true,"unresolved_scenarios":0},{"file":".agents/two.md","actual_tier":"opus","matched":true,"unresolved_scenarios":0}]}' >"$sandbox/invalid-results.json"
cp "$sandbox/state.json" "$sandbox/state-before-invalid.json"
rc=0
python3 "$UPDATE_STATE" "$sandbox/invalid-results.json" "$sandbox/state.json" >/dev/null 2>&1 || rc=$?
assert_nonzero "$rc" "state update rejects non-canonical measured tiers"
assert_equals "$(<"$sandbox/state-before-invalid.json")" "$(<"$sandbox/state.json")" "rejected state update is non-mutating"

printf '%s\n' '{"summary":{"total":1,"matched":1,"mismatched":0,"errors":0},"results":[{"file":".agents/one.md","actual_tier":"thinking","matched":true,"unresolved_scenarios":0}]}' >"$sandbox/valid-results.json"
rc=0
python3 "$UPDATE_STATE" "$sandbox/valid-results.json" "$sandbox/state.json" >/dev/null 2>&1 || rc=$?
assert_equals "0" "$rc" "state update accepts a reviewed canonical sweep"
assert_equals "thinking" "$(jq -r '.files[".agents/one.md"].tier_minimum' "$sandbox/state.json")" "state update records the canonical measured tier"

printf '\nTests passed: %s / %s\n' "$tests_passed" "$tests_run"
[[ "$tests_passed" -eq "$tests_run" ]]
