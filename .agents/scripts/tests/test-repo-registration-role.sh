#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-repo-registration-role.sh — registration persists authoritative Pulse roles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${SCRIPT_DIR%/scripts/tests}"
INSTALL_DIR="${AGENTS_DIR%/.agents}"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
CONFIG_DIR="$TEST_ROOT/config"
REPOS_FILE="$CONFIG_DIR/repos.json"
TEST_PERMISSION="ADMIN"

print_info() { return 0; }
print_warning() { return 0; }

gh() {
	local command="$1"
	local subject="$2"
	if [[ "$command" == "api" && "$subject" == "user" ]]; then
		printf 'alice\n'
		return 0
	fi
	if [[ "$command" == "repo" && "$subject" == "view" ]]; then
		[[ "$TEST_PERMISSION" != "FAIL" ]] || return 1
		printf '%s\n' "$TEST_PERMISSION"
		return 0
	fi
	return 1
}

# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "${AGENTS_DIR}/scripts/aidevops-cli/aidevops-repos-lib.sh"

make_repo() {
	local name="$1"
	local repo="$TEST_ROOT/$name"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" remote add origin "https://github.com/org/${name}.git"
	(cd "$repo" && pwd -P)
	return 0
}

assert_role() {
	local description="$1"
	local path="$2"
	local expected="$3"
	local actual=""
	actual=$(jq -r --arg path "$path" '.initialized_repos[] | select(.path == $path) | .role // ""' "$REPOS_FILE")
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$description"
	return 0
}

admin_repo=$(make_repo admin-repo)
TEST_PERMISSION="ADMIN"
register_repo "$admin_repo" "1.0.0" "planning"
assert_role "organization ADMIN persists maintainer" "$admin_repo" "maintainer"

maintain_repo=$(make_repo maintain-repo)
TEST_PERMISSION="MAINTAIN"
register_repo "$maintain_repo" "1.0.0" "planning"
assert_role "organization MAINTAIN persists maintainer" "$maintain_repo" "maintainer"

write_repo=$(make_repo write-repo)
TEST_PERMISSION="WRITE"
register_repo "$write_repo" "1.0.0" "planning"
assert_role "organization WRITE persists maintainer" "$write_repo" "maintainer"

read_repo=$(make_repo read-repo)
TEST_PERMISSION="READ"
register_repo "$read_repo" "1.0.0" "planning"
assert_role "confirmed READ persists contributor" "$read_repo" "contributor"

unknown_repo=$(make_repo unknown-repo)
TEST_PERMISSION="FAIL"
register_repo "$unknown_repo" "1.0.0" "planning"
assert_role "permission failure does not persist a downgrade" "$unknown_repo" ""

TEST_PERMISSION="ADMIN"
jq --arg path "$read_repo" '(.initialized_repos[] | select(.path == $path)).role = "contributor"' "$REPOS_FILE" >"${REPOS_FILE}.tmp"
mv "${REPOS_FILE}.tmp" "$REPOS_FILE"
register_repo "$read_repo" "1.0.1" "planning"
assert_role "existing explicit contributor role is preserved" "$read_repo" "contributor"

TEST_PERMISSION="FAIL"
jq --arg path "$admin_repo" '(.initialized_repos[] | select(.path == $path)).role = "maintainer"' "$REPOS_FILE" >"${REPOS_FILE}.tmp"
mv "${REPOS_FILE}.tmp" "$REPOS_FILE"
register_repo "$admin_repo" "1.0.1" "planning"
assert_role "API failure preserves existing maintainer role" "$admin_repo" "maintainer"

printf 'All repository registration role tests passed.\n'
