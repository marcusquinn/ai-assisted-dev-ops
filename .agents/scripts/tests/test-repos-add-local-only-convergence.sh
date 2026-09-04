#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-repos-local-only.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
INSTALL_DIR="$REPO_ROOT"
AGENTS_DIR="$REPO_ROOT/.agents"
AIDEVOPS_AGENTS_DIR="$AGENTS_DIR"
CONFIG_DIR="${HOME}/.config/aidevops"
REPOS_FILE="${CONFIG_DIR}/repos.json"
AIDEVOPS_REPOS_FILE="$REPOS_FILE"
export INSTALL_DIR AGENTS_DIR AIDEVOPS_AGENTS_DIR CONFIG_DIR REPOS_FILE AIDEVOPS_REPOS_FILE

mkdir -p "$CONFIG_DIR"

print_info() { return 0; }
print_warning() { return 0; }

# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"
# shellcheck source=../dispatch-single-issue-helper.sh
source "$REPO_ROOT/.agents/scripts/dispatch-single-issue-helper.sh"

_repo_registration_maintainer() {
	printf '\n'
	return 0
}

repo_path="${TEST_ROOT}/repo"
mkdir -p "$repo_path"
git -C "$repo_path" init -q
repo_path="$(cd "$repo_path" && pwd -P)"

register_repo "$repo_path" "1.0.0" "planning"

[[ "$(jq -r '.initialized_repos[0].local_only' "$REPOS_FILE")" == "true" ]]
[[ "$(jq -r '.initialized_repos[0].pulse' "$REPOS_FILE")" == "false" ]]

cat >>"${repo_path}/.git/config" <<'GITCONFIG'
[remote "origin"]
    url = https://github.com/example/remote-backed.git
    fetch = +refs/heads/*:refs/remotes/origin/*
GITCONFIG
register_repo "$repo_path" "1.0.1" "planning"

[[ "$(jq -r '.initialized_repos[0].slug' "$REPOS_FILE")" == "example/remote-backed" ]]
[[ "$(jq -r '.initialized_repos[0] | has("local_only")' "$REPOS_FILE")" == "false" ]]
[[ "$(jq -r '.initialized_repos[0].pulse' "$REPOS_FILE")" == "false" ]]
[[ "$(_dsi_repo_path_for_slug "example/remote-backed")" == "$repo_path" ]]

bootstrap_repo="${TEST_ROOT}/bootstrap-repo"
bootstrap_remote="${TEST_ROOT}/bootstrap-remote.git"
bootstrap_url="https://github.com/example/bootstrap-repo.git"
linked_repo="${TEST_ROOT}/bootstrap-linked"
git init -q --bare "$bootstrap_remote"
git init -q -b main "$bootstrap_repo"
git -C "$bootstrap_repo" config user.name Test
git -C "$bootstrap_repo" config user.email test@example.invalid
git -C "$bootstrap_repo" config commit.gpgsign false
git -C "$bootstrap_repo" config "url.${bootstrap_remote}.insteadOf" "$bootstrap_url"
printf 'seed\n' >"${bootstrap_repo}/README.md"
git -C "$bootstrap_repo" add README.md
git -C "$bootstrap_repo" commit -q -m seed
git -C "$bootstrap_repo" remote add origin "$bootstrap_url"
git -C "$bootstrap_repo" push -q -u origin main
git -C "$bootstrap_remote" symbolic-ref HEAD refs/heads/main
printf 'preserve me\n' >"${bootstrap_repo}/untracked.txt"

if (
	cd "$bootstrap_repo" || exit 1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$REPO_ROOT/aidevops.sh" repos add \
		--slug example/bootstrap-repo
) >/dev/null 2>&1; then
	printf 'FAIL bootstrap registration accepted missing confirmation\n'
	exit 1
fi
if jq -e --arg path "$bootstrap_repo" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" >/dev/null; then
	printf 'FAIL failed bootstrap registration mutated repos.json\n'
	exit 1
fi

if (
	cd "$bootstrap_repo" || exit 1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$REPO_ROOT/aidevops.sh" repos add \
		--slug example/wrong-repo --confirm REGISTER_CANONICAL_REPOSITORY
) >/dev/null 2>&1; then
	printf 'FAIL bootstrap registration accepted a mismatched slug\n'
	exit 1
fi

git -C "$bootstrap_repo" worktree add -q -b test/bootstrap-linked "$linked_repo"
if (
	cd "$linked_repo" || exit 1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$REPO_ROOT/aidevops.sh" repos add \
		--slug example/bootstrap-repo --confirm REGISTER_CANONICAL_REPOSITORY
) >/dev/null 2>&1; then
	printf 'FAIL bootstrap registration accepted a linked worktree\n'
	exit 1
fi
git -C "$bootstrap_repo" worktree remove "$linked_repo"

if ! (
	cd "$bootstrap_repo" || exit 1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git bash "$REPO_ROOT/aidevops.sh" repos add \
		--slug example/bootstrap-repo --confirm REGISTER_CANONICAL_REPOSITORY
) >/dev/null; then
	printf 'FAIL confirmed bootstrap registration was rejected\n'
	exit 1
fi
bootstrap_repo="$(cd "$bootstrap_repo" && pwd -P)"
[[ "$(jq -r --arg path "$bootstrap_repo" '.initialized_repos[] | select(.path == $path) | .slug' "$REPOS_FILE")" == "example/bootstrap-repo" ]]
[[ -f "${bootstrap_repo}/untracked.txt" ]]

printf 'PASS repos add clears stale local_only, preserves pulse, and restores dispatch path resolution\n'
printf 'PASS confirmed bootstrap registration validates identity without editing the canonical checkout\n'
