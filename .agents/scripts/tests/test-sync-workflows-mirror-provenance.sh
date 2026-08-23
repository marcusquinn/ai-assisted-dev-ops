#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Focused mirror helper-provenance capability tests (GH#30581).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../sync-workflows-helper.sh"
TEMPLATES="$SCRIPT_DIR/../../templates/workflows"
PASS=0
FAIL=0

assert_case() {
	local description="$1"
	local expected_rc="$2"
	local actual_rc="$3"
	local output="$4"
	local expected_text="$5"
	if [[ "$actual_rc" -eq "$expected_rc" && "$output" == *"$expected_text"* ]]; then
		printf 'PASS %s\n' "$description"
		PASS=$((PASS + 1))
	else
		printf 'FAIL %s: rc=%s expected=%s output=%s\n' \
			"$description" "$actual_rc" "$expected_rc" "$output" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

init_mirror() {
	local root="$1"
	local workflow_name="$2"
	local content="$3"
	local mirror="$root/mirror"
	mkdir -p "$mirror/.github/workflows"
	git -C "$mirror" init -q
	git -C "$mirror" config user.email test@example.com
	git -C "$mirror" config user.name Test
	git -C "$mirror" config commit.gpgsign false
	git -C "$mirror" symbolic-ref HEAD refs/heads/main
	printf '%s\n' "$content" >"$mirror/.github/workflows/${workflow_name}-reusable.yml"
	git -C "$mirror" add -A
	git -C "$mirror" commit -q -m "mirror fixture"
	return 0
}

write_repos_json() {
	local root="$1"
	local target_slug="$2"
	local target_path="$3"
	mkdir -p "$root/.config/aidevops"
	printf '%s\n' \
		"{\"workflow_reusable_repo\":\"ORG/.github\",\"initialized_repos\":[{\"path\":\"$target_path\",\"slug\":\"$target_slug\"},{\"path\":\"$root/mirror\",\"slug\":\"ORG/.github\"}]}" > \
		"$root/.config/aidevops/repos.json"
	return 0
}

TEST_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

HELPER_ROOT="$TEST_ROOT/helper"
HELPER_TARGET="$HELPER_ROOT/target"
mkdir -p "$HELPER_TARGET/.github/workflows"
printf '%s\n' 'name: legacy issue sync' >"$HELPER_TARGET/.github/workflows/issue-sync.yml"
init_mirror "$HELPER_ROOT" "issue-sync" "name: stale helper-bearing reusable"
write_repos_json "$HELPER_ROOT" "owner/helper-target" "$HELPER_TARGET"
helper_output=$(HOME="$HELPER_ROOT" bash "$HELPER" \
	--repo owner/helper-target --workflow issue-sync 2>&1)
helper_rc=$?
assert_case "helper-bearing mirror remains fail-closed" 1 "$helper_rc" "$helper_output" \
	"configured mirror must be registered and updated"

SELF_ROOT="$TEST_ROOT/self-contained"
SELF_TARGET="$SELF_ROOT/target"
mkdir -p "$SELF_TARGET/.github/workflows" \
	"$SELF_ROOT/.aidevops/agents/templates/workflows"
printf '%s\n' 'name: legacy maintainer gate' > \
	"$SELF_TARGET/.github/workflows/maintainer-gate.yml"
# Presence of an aidevops_ref input must not imply a helper checkout.
sed '/^    secrets: inherit$/i\
    with:\
      aidevops_ref: main' "$TEMPLATES/maintainer-gate-caller.yml" > \
	"$SELF_ROOT/.aidevops/agents/templates/workflows/maintainer-gate-caller.yml"
init_mirror "$SELF_ROOT" "maintainer-gate" \
	"name: self-contained reusable without helper provenance"
write_repos_json "$SELF_ROOT" "owner/self-contained-target" "$SELF_TARGET"
self_output=$(HOME="$SELF_ROOT" bash "$HELPER" \
	--repo owner/self-contained-target --workflow maintainer-gate 2>&1)
self_rc=$?
assert_case "self-contained mirror remains syncable" 0 "$self_rc" "$self_output" "PLANNED"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
