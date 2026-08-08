#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-resolve-canonical-repo-path.sh — Regression tests for t2250.
#
# Background: auto-discovery via `find ~/Git -name .aidevops.json` picks up
# .aidevops.json files that exist inside linked git worktrees because worktrees
# inherit the working tree contents. Without a worktree guard, each worktree
# gets registered as a separate repo in repos.json and downstream consumers
# (tabby-profile-sync, pulse, etc.) treat it as a standalone project.
#
# resolve_canonical_repo_path() in aidevops-repos-lib.sh uses `git rev-parse --git-dir`
# vs `git rev-parse --git-common-dir` to detect linked worktrees
# deterministically, then resolves them to the main worktree path via
# `git worktree list --porcelain`. This is heuristic-free and handles repos
# with any naming convention, including TLD-style names (wpallstars.com).
#
# This test:
#   1. Creates a temporary git repo and a linked worktree.
#   2. Sources aidevops.sh in a stubbed environment (suppresses print_* calls).
#   3. Asserts that resolve_canonical_repo_path returns the main-worktree path
#      for the linked worktree, and returns the input unchanged for the main
#      worktree and non-git paths.
#   4. Covers the original-bug case: a repo name containing a dot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
REPOS_LIB="${REPO_ROOT}/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[1;33m'
readonly TEST_NC='\033[0m'

pass_count=0
fail_count=0

_pass() {
	local msg="$1"
	printf '%b  PASS:%b %s\n' "${TEST_GREEN}" "${TEST_NC}" "${msg}"
	pass_count=$((pass_count + 1))
	return 0
}

_fail() {
	local msg="$1"
	printf '%b  FAIL:%b %s\n' "${TEST_RED}" "${TEST_NC}" "${msg}" >&2
	fail_count=$((fail_count + 1))
	return 0
}

_info() {
	local msg="$1"
	printf '%b[INFO]%b %s\n' "${TEST_YELLOW}" "${TEST_NC}" "${msg}"
	return 0
}

# Source resolve_canonical_repo_path by extracting and evaluating just the
# function definition. Sourcing aidevops.sh whole would run side-effectful
# init code; the function is self-contained and can be isolated.
extract_and_source_function() {
	local fn_name="$1"
	local source_file="$2"
	awk -v fn="$fn_name" '
		$0 ~ ("^" fn "\\(\\) \\{") { in_fn = 1 }
		in_fn { print }
		in_fn && /^\}$/ { in_fn = 0 }
	' "$source_file"
	return 0
}

# Stub the framework print helpers — the production function calls them on
# the worktree-resolution path and we don't want chatter in test output.
print_info() { :; return 0; }
print_warning() { :; return 0; }

# shellcheck disable=SC1090
eval "$(extract_and_source_function resolve_canonical_repo_path "${REPOS_LIB}")"

if ! declare -f resolve_canonical_repo_path >/dev/null; then
	_fail "could not source resolve_canonical_repo_path from aidevops-repos-lib.sh"
	exit 1
fi

# -----------------------------------------------------------------------------
# Fixture: temporary repo + linked worktree (with a TLD-style name).
# -----------------------------------------------------------------------------
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

main_repo="${tmp_root}/example.com"
worktree="${tmp_root}/example.com-chore-init"

git init -q -b main "$main_repo"
(cd "$main_repo" && git commit --allow-empty -q -m "init")
(cd "$main_repo" && git worktree add -q "$worktree" -b "chore/init")

# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------
assert_resolves_to() {
	local label="$1"
	local input="$2"
	local expected="$3"
	local actual
	# pwd -P to match the production function's path normalisation; the macOS
	# /tmp symlink to /private/tmp otherwise causes spurious string mismatches.
	expected="$(cd "$expected" 2>/dev/null && pwd -P || printf '%s' "$expected")"
	actual="$(resolve_canonical_repo_path "$input")"
	if [[ -d "$actual" ]]; then
		actual="$(cd "$actual" 2>/dev/null && pwd -P || printf '%s' "$actual")"
	fi
	if [[ "$actual" == "$expected" ]]; then
		_pass "${label} (${input} → ${actual})"
	else
		_fail "${label}: expected ${expected}, got ${actual}"
	fi
	return 0
}

_info "Test 1: linked worktree of dotted-name repo resolves to main"
assert_resolves_to "worktree → main" "$worktree" "$main_repo"

_info "Test 2: main worktree returns itself"
assert_resolves_to "main → main" "$main_repo" "$main_repo"

_info "Test 3: non-git path passes through unchanged"
plain="${tmp_root}/not-a-repo"
mkdir -p "$plain"
assert_resolves_to "non-git → non-git" "$plain" "$plain"

_info "Test 4: current canonical aidevops repo self-resolves"
if [[ -d "$REPO_ROOT/.git" || -f "$REPO_ROOT/.git" ]]; then
	# The aidevops checkout running this test may itself be a linked worktree
	# (when executed from a development worktree), so don't assert on that case.
	# Just assert the function returns a real, existing path.
	actual="$(resolve_canonical_repo_path "$REPO_ROOT")"
	if [[ -d "$actual" ]]; then
		_pass "aidevops repo resolves to existing path ($actual)"
	else
		_fail "aidevops repo resolved to non-existent path: $actual"
	fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
if ((fail_count == 0)); then
	printf '%bAll %d tests passed.%b\n' "${TEST_GREEN}" "${pass_count}" "${TEST_NC}"
	exit 0
else
	printf '%b%d test(s) failed, %d passed.%b\n' \
		"${TEST_RED}" "${fail_count}" "${pass_count}" "${TEST_NC}" >&2
	exit 1
fi
