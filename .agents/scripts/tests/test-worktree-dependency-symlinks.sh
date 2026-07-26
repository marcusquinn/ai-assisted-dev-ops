#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
: "${RED:=}"
: "${NC:=}"
print_warning() { return 0; }

# shellcheck source=../worktree-helper-add.sh
source "${SCRIPT_DIR}/worktree-helper-add.sh"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	return 1
}

fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
repo_dir="${fixture_dir}/repo"
worktree_dir="${fixture_dir}/worktree"
mkdir -p "${repo_dir}/node_modules/.bin" "${repo_dir}/vendor/bin" "$worktree_dir" || fail "failed to create fixture"
touch "${repo_dir}/package.json" "${repo_dir}/composer.json" "${repo_dir}/node_modules/.bin/tool" "${repo_dir}/vendor/bin/tool"
touch "${worktree_dir}/package.json" "${worktree_dir}/composer.json"

WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S=0
WORKTREE_NODE_MODULES_RESTORE_MAX_DIRS=2
_restore_worktree_node_modules "$worktree_dir" "$repo_dir"

[[ -L "${worktree_dir}/node_modules" ]] || fail "node_modules was not symlinked"
[[ -L "${worktree_dir}/vendor" ]] || fail "vendor was not symlinked"
[[ "$(readlink "${worktree_dir}/node_modules")" == "${repo_dir}/node_modules" ]] || fail "node_modules link target was incorrect"
[[ "$(readlink "${worktree_dir}/vendor")" == "${repo_dir}/vendor" ]] || fail "vendor link target was incorrect"

printf 'PASS worktree dependencies link to canonical checkout\n'
