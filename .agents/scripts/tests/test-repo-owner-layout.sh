#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

failures=0
pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}
fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	failures=$((failures + 1))
	return 0
}
assert_contains_line() {
	local haystack="$1"
	local expected="$2"
	local message="$3"
	if printf '%s\n' "$haystack" | grep -Fxq "$expected"; then
		pass "$message"
	else
		fail "$message (missing $expected)"
	fi
	return 0
}
assert_not_contains_line() {
	local haystack="$1"
	local unexpected="$2"
	local message="$3"
	if printf '%s\n' "$haystack" | grep -Fxq "$unexpected"; then
		fail "$message (unexpected $unexpected)"
	else
		pass "$message"
	fi
	return 0
}

export HOME="$TEST_ROOT/home"
workspace="$HOME/Git"
mkdir -p "$workspace/direct/.git" "$workspace/owner/nested/.git"
mkdir -p "$workspace/direct/child/.git" "$workspace/_worktrees/wt/.git"
mkdir -p "$workspace/_archive/old/.git" "$workspace/owner/submodule"
printf 'gitdir: elsewhere\n' >"$workspace/owner/submodule/.git"

# shellcheck source=../aidevops-cli/repo-discovery-lib.sh
source "$SCRIPTS_DIR/aidevops-cli/repo-discovery-lib.sh"
discovered=""
while IFS= read -r -d '' repo; do
	discovered+="${repo}"$'\n'
done < <(aidevops_discover_canonical_repos "$workspace")

assert_contains_line "$discovered" "$workspace/direct" "discovers direct repositories"
assert_contains_line "$discovered" "$workspace/owner/nested" "discovers owner/repo repositories"
assert_not_contains_line "$discovered" "$workspace/direct/child" "excludes repositories nested in repositories"
assert_not_contains_line "$discovered" "$workspace/_worktrees/wt" "excludes centralized worktrees"
assert_not_contains_line "$discovered" "$workspace/_archive/old" "excludes archived repositories"
assert_not_contains_line "$discovered" "$workspace/owner/submodule" "excludes submodules and linked worktrees"

mkdir -p "$HOME/.config/aidevops"
printf '%s\n' '{"git_parent_dirs":["~/Git"],"personal_owners":{"github.com":["Alice"],"gitlab.example":["alice-work"]}}' >"$HOME/.config/aidevops/repos.json"
export AIDEVOPS_REPOS_JSON="$HOME/.config/aidevops/repos.json"
# shellcheck source=../worktree-paths.sh
source "$SCRIPTS_DIR/worktree-paths.sh"

direct_path=$(aidevops_generate_worktree_path "$workspace/direct" "feature/Test")
owner_path=$(aidevops_generate_worktree_path "$workspace/owner/nested" "feature/Test")
[[ "$direct_path" == "$workspace/_worktrees/direct-feature-test" ]] \
	&& pass "root repository keeps basename worktree prefix" \
	|| fail "root repository worktree prefix is incorrect: $direct_path"
[[ "$owner_path" == "$workspace/_worktrees/owner-nested-feature-test" ]] \
	&& pass "owner repository gets collision-safe worktree prefix" \
	|| fail "owner repository worktree prefix is incorrect: $owner_path"

if aidevops_owner_is_personal "github.com" "alice"; then
	pass "personal owner aliases are host-specific and case-insensitive"
else
	fail "configured personal owner alias was not recognized"
fi
if aidevops_owner_is_personal "gitlab.example" "alice"; then
	fail "owner alias leaked across hosts"
else
	pass "personal owner aliases do not leak across hosts"
fi
personal_path=$(aidevops_recommended_repo_path "$workspace" "github.com" "Alice" "project")
third_party_path=$(aidevops_recommended_repo_path "$workspace" "github.com" "OtherOrg" "project")
[[ "$personal_path" == "$workspace/project" ]] \
	&& pass "personal repositories use the workspace root" \
	|| fail "personal repository path is incorrect: $personal_path"
[[ "$third_party_path" == "$workspace/otherorg/project" ]] \
	&& pass "non-personal owner directories normalize to lowercase" \
	|| fail "third-party repository path is incorrect: $third_party_path"

if [[ "$failures" -gt 0 ]]; then
	printf '%d owner-layout test(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'All owner-layout tests passed\n'
exit 0
