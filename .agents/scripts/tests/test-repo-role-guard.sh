#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-repo-role-guard.sh — Unit tests for get_repo_role_by_slug (t2145)
#
# Validates that the role field in repos.json correctly gates scanner
# functions for maintainer vs contributor instances.
#
# Usage: bash .agents/scripts/tests/test-repo-role-guard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="${SCRIPT_DIR}/.."

# --- Test harness ---
_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	_TESTS_RUN=$((_TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		_TESTS_PASSED=$((_TESTS_PASSED + 1))
		printf '  PASS: %s\n' "$description"
	else
		_TESTS_FAILED=$((_TESTS_FAILED + 1))
		printf '  FAIL: %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	fi
	return 0
}

# --- Setup ---
# Create a temp repos.json for testing
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
TEST_REPOS_JSON="${TMPDIR_TEST}/repos.json"

cat >"$TEST_REPOS_JSON" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "alice/owned-repo",
      "pulse": true,
      "role": "maintainer"
    },
    {
      "slug": "bob/external-repo",
      "pulse": true,
      "role": "contributor"
    },
    {
      "slug": "bob/write-capable-contributor",
      "pulse": true,
      "role": "contributor"
    },
    {
      "slug": "alice/auto-detect-repo",
      "pulse": true
    },
    {
      "slug": "charlie/auto-detect-other",
      "pulse": true
    },
    {
      "slug": "org/maintained-repo",
      "pulse": true,
      "maintainer": "alice"
    },
    {
      "slug": "org/not-maintained-repo",
      "pulse": true,
      "maintainer": "charlie"
    }
  ],
  "git_parent_dirs": []
}
JSON

# Source shared-constants (provides REPOS_JSON variable path)
# shellcheck source=../shared-constants.sh
[[ -f "${PARENT_DIR}/shared-constants.sh" ]] && source "${PARENT_DIR}/shared-constants.sh"

# Override REPOS_JSON to point at our test fixture
REPOS_JSON="$TEST_REPOS_JSON"

# Source the module under test
# shellcheck source=../pulse-repo-meta.sh
_PULSE_REPO_META_LOADED=""
source "${PARENT_DIR}/pulse-repo-meta.sh"

# Override the cached gh user for deterministic testing
_CACHED_GH_USER="alice"

_gh_current_user_allows_repo_write() {
	local repo_slug="$1"
	case "$repo_slug" in
	alice/owned-repo | alice/auto-detect-repo | alice/unknown-repo | bob/write-capable-contributor)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# --- Tests ---

echo "=== get_repo_role_by_slug ==="

# Test 1: Explicit maintainer role
role=$(get_repo_role_by_slug "alice/owned-repo")
assert_eq "explicit role=maintainer returns maintainer" "maintainer" "$role"

# Test 2: Explicit contributor role
role=$(get_repo_role_by_slug "bob/external-repo")
assert_eq "explicit role=contributor returns contributor" "contributor" "$role"

# Test 3: Auto-detect — slug owner matches gh user → maintainer
role=$(get_repo_role_by_slug "alice/auto-detect-repo")
assert_eq "auto-detect: slug owner matches gh user → maintainer" "maintainer" "$role"

# Test 4: Auto-detect — slug owner differs from gh user → contributor
role=$(get_repo_role_by_slug "charlie/auto-detect-other")
assert_eq "auto-detect: slug owner differs → contributor" "contributor" "$role"

# Test 4b: Configured maintainer matches gh user even when slug owner differs.
role=$(get_repo_role_by_slug "org/maintained-repo")
assert_eq "auto-detect: configured maintainer matches gh user → maintainer" "maintainer" "$role"

# Test 4c: Configured maintainer differs and slug owner differs → contributor.
role=$(get_repo_role_by_slug "org/not-maintained-repo")
assert_eq "auto-detect: configured maintainer differs → contributor" "contributor" "$role"

# Test 5: Empty slug → contributor (safe default)
role=$(get_repo_role_by_slug "")
assert_eq "empty slug → contributor" "contributor" "$role"

# Test 6: Unknown slug (not in repos.json) — auto-detect from slug owner
role=$(get_repo_role_by_slug "alice/unknown-repo")
assert_eq "unknown slug, owner matches gh user → maintainer" "maintainer" "$role"

# Test 7: Unknown slug, different owner → contributor
role=$(get_repo_role_by_slug "stranger/unknown-repo")
assert_eq "unknown slug, different owner → contributor" "contributor" "$role"

# Test 8: Write-capable pulse actions require live admin/maintain/write permission.
if repo_allows_pulse_write_actions "alice/owned-repo"; then
	write_allowed="yes"
else
	write_allowed="no"
fi
assert_eq "write actions allowed for write-authorized repo" "yes" "$write_allowed"

# Test 9: Repos without live write permission stay read-only/noise-free.
if repo_allows_pulse_write_actions "bob/external-repo"; then
	write_allowed="yes"
else
	write_allowed="no"
fi
assert_eq "write actions blocked without repo write permission" "no" "$write_allowed"

# Test 9b: Explicit contributor role remains blocked even with live write permission.
if repo_allows_pulse_write_actions "bob/write-capable-contributor"; then
	write_allowed="yes"
else
	write_allowed="no"
fi
assert_eq "write actions blocked for explicit contributor role" "no" "$write_allowed"

# Test 10: Deterministic merge pass uses the write-action role guard.
if grep -q "repo_allows_pulse_write_actions \"\$repo_slug\"" "${PARENT_DIR}/pulse-merge-pass.sh"; then
	guard_present="yes"
else
	guard_present="no"
fi
assert_eq "merge pass checks contributor write-action guard" "yes" "$guard_present"

# Test 11: Dirty PR sweep uses the write-action role guard.
if grep -q "repo_allows_pulse_write_actions \"\$repo_slug\"" "${PARENT_DIR}/pulse-dirty-pr-sweep.sh"; then
	guard_present="yes"
else
	guard_present="no"
fi
assert_eq "dirty PR sweep checks contributor write-action guard" "yes" "$guard_present"

# Test 12: Dirty PR sweep standalone path loads the repo metadata guard.
if grep -q "source \"\${SCRIPT_DIR}/pulse-repo-meta.sh\"" "${PARENT_DIR}/pulse-dirty-pr-sweep.sh"; then
	guard_present="yes"
else
	guard_present="no"
fi
assert_eq "dirty PR sweep loads repo-role guard for standalone execution" "yes" "$guard_present"

# Test 13: Write sweeps fail closed when the guard helper is unavailable.
if grep -q '! declare -F repo_allows_pulse_write_actions' "${PARENT_DIR}/pulse-merge-pass.sh" \
	&& grep -q "|| ! repo_allows_pulse_write_actions \"\$repo_slug\"" "${PARENT_DIR}/pulse-merge-pass.sh" \
	&& grep -q '! declare -F repo_allows_pulse_write_actions' "${PARENT_DIR}/pulse-dirty-pr-sweep.sh" \
	&& grep -q "|| ! repo_allows_pulse_write_actions \"\$repo_slug\"" "${PARENT_DIR}/pulse-dirty-pr-sweep.sh"; then
	guard_present="yes"
else
	guard_present="no"
fi
assert_eq "write sweeps fail closed when repo-role guard is unavailable" "yes" "$guard_present"

echo ""
echo "Results: ${_TESTS_PASSED}/${_TESTS_RUN} passed, ${_TESTS_FAILED} failed"

if [[ "$_TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
