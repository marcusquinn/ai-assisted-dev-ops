#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../worktree-helper.sh"
ADD_HELPER="${SCRIPT_DIR}/../worktree-helper-add.sh"
REAL_GIT=$(command -v git)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

REMOTE="${ROOT}/remote.git"
CANONICAL="${ROOT}/canonical"
UPDATER="${ROOT}/updater"
WORKTREES="${ROOT}/worktrees"
HOME="${ROOT}/home"
export HOME AIDEVOPS_WORKTREE_BASE_DIR="$WORKTREES"

git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$CANONICAL"
git -C "$CANONICAL" switch -q -c main
git -C "$CANONICAL" config user.name Test
git -C "$CANONICAL" config user.email test@example.invalid
git -C "$CANONICAL" commit -q --allow-empty -m seed
git -C "$CANONICAL" push -q -u origin main
git -C "$CANONICAL" remote set-head origin main

git clone -q "$REMOTE" "$UPDATER"
git -C "$UPDATER" switch -q main
git -C "$UPDATER" config user.name Test
git -C "$UPDATER" config user.email test@example.invalid
printf 'remote tip\n' >"${UPDATER}/remote.txt"
git -C "$UPDATER" add remote.txt
git -C "$UPDATER" commit -q -m remote-tip
git -C "$UPDATER" push -q origin main
REMOTE_SHA=$(git -C "$UPDATER" rev-parse HEAD)

# Simulate a remote branch that has not been fetched into the canonical repo.
# The bootstrap worktree must not depend on the missing remote-tracking ref.
git -C "$CANONICAL" update-ref -d refs/remotes/origin/main
if git -C "$CANONICAL" show-ref --verify --quiet refs/remotes/origin/main; then
	printf 'FAIL origin/main still exists before bootstrap test\n'
	exit 1
fi

# Optional integration mode: prepend the repository Git shim after fixture
# setup so worktree creation exercises the canonical guard without blocking
# the fixture's intentional canonical branch/bootstrap mutations.
if [[ -n "${AIDEVOPS_TEST_GIT_SHIM:-}" ]]; then
	PATH="$(dirname "$AIDEVOPS_TEST_GIT_SHIM"):${PATH}"
	export PATH
fi

(cd "$CANONICAL" && "$HELPER" add test/fresh-base >/dev/null)
FRESH_PATH="${WORKTREES}/canonical-test-fresh-base"
[[ "$(git -C "$FRESH_PATH" rev-parse HEAD)" == "$REMOTE_SHA" ]] || {
	printf 'FAIL worktree did not start at freshly fetched origin/main\n'
	exit 1
}
printf 'PASS worktree starts at freshly fetched origin/main\n'
if compgen -G "${WORKTREES}/.canonical-fetch-*" >/dev/null; then
	printf 'FAIL temporary fetch worktree was not removed\n'
	exit 1
fi
printf 'PASS canonical-guard bootstrap fetch worktree is removed\n'

"$REAL_GIT" -C "$CANONICAL" remote set-url origin "${ROOT}/missing.git"
if (cd "$CANONICAL" && "$HELPER" add test/fetch-failure >/dev/null 2>&1); then
	printf 'FAIL worktree creation accepted an unrefreshable remote base\n'
	exit 1
fi
printf 'PASS worktree creation fails closed when origin/main cannot refresh\n'

PINNED_SHA=$(git -C "$CANONICAL" rev-parse main)
(cd "$CANONICAL" && "$HELPER" add test/pinned-base --base "$PINNED_SHA" >/dev/null)
PINNED_PATH="${WORKTREES}/canonical-test-pinned-base"
[[ "$(git -C "$PINNED_PATH" rev-parse HEAD)" == "$PINNED_SHA" ]] || {
	printf 'FAIL immutable explicit base was not preserved\n'
	exit 1
}
printf 'PASS immutable explicit base permits audited offline recovery\n'

REGISTRY_DB="${HOME}/.aidevops/.agent-workspace/worktree-registry.db"
PINNED_OWNER=$(sqlite3 -separator '|' "$REGISTRY_DB" \
	"SELECT branch, task_id FROM worktree_owners WHERE branch = 'test/pinned-base';")
[[ "$PINNED_OWNER" == "test/pinned-base|" ]] || {
	printf 'FAIL worktree without --issue registered unexpected owner row %s\n' "${PINNED_OWNER:-<missing>}"
	exit 1
}
printf 'PASS worktree without --issue retains an empty registry task ID\n'

(cd "$CANONICAL" && AIDEVOPS_SKIP_AUTO_CLAIM=1 "$HELPER" add test/issue-task \
	--issue 123 --base "$PINNED_SHA" >/dev/null)
ISSUE_OWNER=$(sqlite3 -separator '|' "$REGISTRY_DB" \
	"SELECT branch, task_id FROM worktree_owners WHERE branch = 'test/issue-task';")
[[ "$ISSUE_OWNER" == "test/issue-task|123" ]] || {
	printf 'FAIL explicit --issue registered unexpected owner row %s\n' "${ISSUE_OWNER:-<missing>}"
	exit 1
}
printf 'PASS explicit --issue propagates into the registry task ID\n'

git -C "$CANONICAL" branch test/race-guard "$PINNED_SHA"
RACE_OUTPUT=""
RACE_RC=0
RACE_OUTPUT=$(
	cd "$CANONICAL" || exit 1
	SCRIPT_DIR="$(cd "$(dirname "$ADD_HELPER")" && pwd)"
	# shellcheck source=../worktree-helper-add.sh
	source "$ADD_HELPER"
	_ADD_FRESH_ON_COLLISION=1
	_ADD_COLLISION_EXPECTED_SHA="$REMOTE_SHA"
	_ADD_COLLISION_TARGET_SHA="$REMOTE_SHA"
	_ADD_COLLISION_AHEAD=0
	_ADD_COLLISION_BEHIND=1
	_cmd_add_assert_collision_ref_unchanged test/race-guard 2>&1
) || RACE_RC=$?
if [[ "$RACE_RC" -eq 1 && "$RACE_OUTPUT" == *"WORKTREE_COLLISION=branch_changed_during_creation"* ]]; then
	printf 'PASS collision ref changes are rejected at mutation time\n'
else
	printf 'FAIL collision ref change was not rejected: rc=%s output=%s\n' "$RACE_RC" "$RACE_OUTPUT"
	exit 1
fi

RACE_BRANCH=test/race-e2e
RACE_PATH="${WORKTREES}/canonical-test-race-e2e"
RACE_MUTATED_SHA=$(printf 'race mutation\n' | git -C "$CANONICAL" commit-tree \
	"$(git -C "$CANONICAL" rev-parse "${REMOTE_SHA}^{tree}")" -p "$REMOTE_SHA")
git -C "$CANONICAL" branch "$RACE_BRANCH" "$REMOTE_SHA"
RACE_OUTPUT=""
RACE_RC=0
RACE_OUTPUT=$(
	cd "$CANONICAL" || exit 1
	SCRIPT_DIR="$(cd "$(dirname "$ADD_HELPER")" && pwd)"
	# shellcheck source=../worktree-helper-add.sh
	source "$ADD_HELPER"
	RED=""
	NC=""
	BLUE=""
	GREEN=""
	YELLOW=""
	BOLD=""
	get_repo_root() {
		git rev-parse --show-toplevel 2>/dev/null
		return $?
	}
	aidevops_worktree_capacity_check() { return 0; }
	eval "$(declare -f _cmd_add_create_worktree | sed '1s/_cmd_add_create_worktree/_cmd_add_create_worktree_original/')"
	_cmd_add_create_worktree() {
		local branch="$1"
		local path="$2"
		local explicit_base="$3"
		git update-ref "refs/heads/${branch}" "$RACE_MUTATED_SHA" || return 1
		_cmd_add_create_worktree_original "$branch" "$path" "$explicit_base"
		return $?
	}
	AIDEVOPS_SKIP_AUTO_CLAIM=1 cmd_add "$RACE_BRANCH" "$RACE_PATH" \
		--issue 456 --base "$REMOTE_SHA" --fresh-on-collision 2>&1
) || RACE_RC=$?
RACE_BRANCH_AFTER=$(git -C "$CANONICAL" rev-parse "refs/heads/${RACE_BRANCH}")
if [[ "$RACE_RC" -eq 1 && "$RACE_BRANCH_AFTER" == "$RACE_MUTATED_SHA" && ! -d "$RACE_PATH" &&
	"$RACE_OUTPUT" == *"WORKTREE_COLLISION=branch_changed_during_creation"* ]]; then
	printf 'PASS post-creation race guard preserves ref and removes wrong-tip worktree\n'
else
	printf 'FAIL post-creation race guard: rc=%s branch=%s path=%s output=%s\n' \
		"$RACE_RC" "$RACE_BRANCH_AFTER" "$RACE_PATH" "$RACE_OUTPUT"
	exit 1
fi

exit 0
