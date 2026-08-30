#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for scoped ripgrep search paths (GH#27121).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		printf '  [PASS] %s\n' "$label"
		PASS=$((PASS + 1))
	else
		printf '  [FAIL] %s — expected %q got %q\n' "$label" "$expected" "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

mkdir -p "$TEST_ROOT/project/todo/tasks"
printf '%s\n' '- [ ] t1[2] literal task' >"$TEST_ROOT/project/TODO.md"
printf '%s\n' 'Task t1[2] is referenced here.' >"$TEST_ROOT/project/todo/tasks/literal.md"
printf '%s\n' 'Task t12 must not match a fixed-string search.' >"$TEST_ROOT/project/todo/tasks/regex-lookalike.md"

related_files=$(
	SCRIPT_DIR="$REPO_ROOT/.agents/scripts"
	# shellcheck source=../issue-sync-lib-parse.sh
	source "$REPO_ROOT/.agents/scripts/issue-sync-lib-parse.sh"
	find_related_files 't1[2]' "$TEST_ROOT/project"
)
assert_eq "issue sync treats task IDs as fixed strings" \
	"$TEST_ROOT/project/todo/tasks/literal.md" "$related_files"

printf '%s\n' '- [ ] t9000 multi-source task ref:todo/tasks/explicit.md' >>"$TEST_ROOT/project/TODO.md"
printf '%s\n' 'Task t9000 explicit context.' >"$TEST_ROOT/project/todo/tasks/explicit.md"
printf '%s\n' 'Task t9000 state context.' >"$TEST_ROOT/project/todo/tasks/state.md"
related_files=$(
	SCRIPT_DIR="$REPO_ROOT/.agents/scripts"
	# shellcheck source=../issue-sync-lib-parse.sh
	source "$REPO_ROOT/.agents/scripts/issue-sync-lib-parse.sh"
	find_related_files 't9000' "$TEST_ROOT/project"
)
expected_related_files=$(printf '%s\n' \
	"$TEST_ROOT/project/todo/tasks/explicit.md" \
	"$TEST_ROOT/project/todo/tasks/state.md")
assert_eq "issue sync emits one clean line per explicit and discovered reference" \
	"$expected_related_files" "$related_files"

mkdir -p "$TEST_ROOT/home/.aidevops/logs" "$TEST_ROOT/mission"
artifact="$TEST_ROOT/mission/helper[1].sh"
printf '%s\n' '# helper[1].sh' >"$artifact"
printf '%s\n' 'uses helper[1].sh' >"$TEST_ROOT/mission/one.md"
printf '%s\n' 'uses helper[1].sh' >"$TEST_ROOT/mission/two.md"
printf '%s\n' 'uses helper[1].sh' >"$TEST_ROOT/mission/three.md"
mission_score=$(HOME="$TEST_ROOT/home" \
	JSONC_DEFAULTS="$REPO_ROOT/.agents/configs/aidevops.defaults.jsonc" bash -c \
	'source "$1"; _score_multi_feature_usage "$2" "$3"' _ \
	"$REPO_ROOT/.agents/scripts/mission-skill-learner.sh" "$artifact" "$TEST_ROOT/mission")
assert_eq "mission scoring uses fixed-string artifact references" "20" "$mission_score"

unused_artifact="$TEST_ROOT/mission/unused[1].sh"
printf '%s\n' '# no references' >"$unused_artifact"
unused_score=$(HOME="$TEST_ROOT/home" \
	JSONC_DEFAULTS="$REPO_ROOT/.agents/configs/aidevops.defaults.jsonc" bash -c \
	'source "$1"; _score_multi_feature_usage "$2" "$3"' _ \
	"$REPO_ROOT/.agents/scripts/mission-skill-learner.sh" "$unused_artifact" "$TEST_ROOT/mission")
assert_eq "mission scoring handles a no-match rg result" "0" "$unused_score"

mkdir -p "$TEST_ROOT/project/.github/workflows"
printf '%s\n' 'steps:' '  - run: pnpm test' >"$TEST_ROOT/project/.github/workflows/test.yml"
ci_result=$(bash -c 'source "$1"; discover_ci "$2"' _ \
	"$REPO_ROOT/.agents/scripts/testing-setup-helper.sh" "$TEST_ROOT/project")
has_test_step=$(printf '%s' "$ci_result" | jq -r '.[0].has_test_step')
assert_eq "CI discovery detects test commands with bounded search" "true" "$has_test_step"

if rg -q 'rg -l -F --' "$REPO_ROOT/.agents/scripts/issue-sync-lib-parse.sh" &&
	rg -q 'grep -rlF --' "$REPO_ROOT/.agents/scripts/issue-sync-lib-parse.sh"; then
	assert_eq "issue sync retains portable grep fallback" "true" "true"
else
	assert_eq "issue sync retains portable grep fallback" "true" "false"
fi

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
