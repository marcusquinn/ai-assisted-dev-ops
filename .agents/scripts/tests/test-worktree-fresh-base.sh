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
export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="${ROOT}/cleanup-receipts"
REGISTRY_DB="${HOME}/.aidevops/.agent-workspace/worktree-registry.db"

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

# Recreating a manually retained branch at a path whose prior lifecycle is
# terminal must preserve the old receipt while superseding it as active truth.
# shellcheck source=../full-loop-cleanup-receipt.sh
source "${SCRIPT_DIR}/../full-loop-cleanup-receipt.sh"
RECREATED_BRANCH="test/recreated-cleaned-path"
RECREATED_PATH="${WORKTREES}/canonical-test-recreated-cleaned-path"
git -C "$CANONICAL" branch "$RECREATED_BRANCH" "$PINNED_SHA"
RECREATED_RECEIPT=$(full_loop_write_cleanup_deferred example/repository 777 \
	"$RECREATED_PATH" "$RECREATED_BRANCH" "$$" test-session not-requested)
full_loop_transition_cleanup_receipt "$RECREATED_RECEIPT" "$_FULL_LOOP_CLEANUP_CLEANED"
RECREATED_OUTPUT=$(
	cd "$CANONICAL" || exit 1
	AIDEVOPS_SKIP_AUTO_CLAIM=1 "$HELPER" add "$RECREATED_BRANCH" "$RECREATED_PATH" 2>&1
)
[[ -d "$RECREATED_PATH" ]] || {
	printf 'FAIL terminal receipt reconciliation removed the valid recreated worktree\n'
	exit 1
}
RECREATED_OWNER=$(sqlite3 -separator '|' "$REGISTRY_DB" \
	"SELECT owner_pid, owner_session, branch, task_id FROM worktree_owners WHERE branch = '${RECREATED_BRANCH}';")
IFS='|' read -r RECREATED_OWNER_PID RECREATED_OWNER_SESSION RECREATED_OWNER_BRANCH RECREATED_OWNER_TASK <<<"$RECREATED_OWNER"
if [[ ! "$RECREATED_OWNER_PID" =~ ^[0-9]+$ || "$RECREATED_OWNER_BRANCH" != "$RECREATED_BRANCH" ||
	-n "$RECREATED_OWNER_TASK" ]]; then
	printf 'FAIL recreated path lacks verified ownership registration: %s\n' "${RECREATED_OWNER:-<missing>}"
	exit 1
fi
jq -e --arg branch "$RECREATED_BRANCH" --arg head "$PINNED_SHA" \
	--argjson owner_pid "$RECREATED_OWNER_PID" --arg owner_session "$RECREATED_OWNER_SESSION" '
	.resource_cleanup_state == "CLEANED"
	and .receipt_disposition.state == "SUPERSEDED_BY_PATH_RECREATION"
	and .receipt_disposition.reason == "worktree-path-recreated"
	and .receipt_disposition.replacement_generation.branch == $branch
	and .receipt_disposition.replacement_generation.head == $head
	and .receipt_disposition.replacement_generation.owner.pid == $owner_pid
	and .receipt_disposition.replacement_generation.owner.session == $owner_session
' "$RECREATED_RECEIPT" >/dev/null || {
	printf 'FAIL recreated path did not preserve registered-generation receipt evidence\n'
	exit 1
}
if full_loop_cleanup_receipt_for_worktree "$RECREATED_PATH" >/dev/null 2>&1; then
	printf 'FAIL superseded terminal receipt remained selectable for the recreated path\n'
	exit 1
fi
if [[ "$RECREATED_OUTPUT" != *"AIDEVOPS_WORKTREE_LIFECYCLE_DISPOSITION=PATH_RECREATED_AFTER_CLEANUP"* ||
	"$RECREATED_OUTPUT" != *"prior_pr=777"* ]]; then
	printf 'FAIL recreated path omitted explicit lifecycle disposition: %s\n' "$RECREATED_OUTPUT"
	exit 1
fi
printf 'PASS recreated path supersedes terminal receipt with explicit lifecycle disposition\n'

REGISTRATION_FAILURE_BRANCH="test/recreated-registration-failure"
REGISTRATION_FAILURE_PATH="${WORKTREES}/canonical-test-recreated-registration-failure"
git -C "$CANONICAL" branch "$REGISTRATION_FAILURE_BRANCH" "$PINNED_SHA"
REGISTRATION_FAILURE_RECEIPT=$(full_loop_write_cleanup_deferred example/repository 779 \
	"$REGISTRATION_FAILURE_PATH" "$REGISTRATION_FAILURE_BRANCH" "$$" registration-failure-session not-requested)
full_loop_transition_cleanup_receipt "$REGISTRATION_FAILURE_RECEIPT" "$_FULL_LOOP_CLEANUP_CLEANED"
BROKEN_HOME="${ROOT}/broken-registry-home"
mkdir -p "${BROKEN_HOME}/.aidevops/.agent-workspace/worktree-registry.db"
REGISTRATION_FAILURE_OUTPUT=""
REGISTRATION_FAILURE_RC=0
REGISTRATION_FAILURE_OUTPUT=$(
	cd "$CANONICAL" || exit 1
	HOME="$BROKEN_HOME" AIDEVOPS_SKIP_AUTO_CLAIM=1 \
		"$HELPER" add "$REGISTRATION_FAILURE_BRANCH" "$REGISTRATION_FAILURE_PATH" 2>&1
) || REGISTRATION_FAILURE_RC=$?
if [[ "$REGISTRATION_FAILURE_RC" -eq 0 || ! -d "$REGISTRATION_FAILURE_PATH" ||
	"$REGISTRATION_FAILURE_OUTPUT" != *"AIDEVOPS_WORKTREE_LIFECYCLE_DISPOSITION=REGISTRATION_FAILED"* ]]; then
	printf 'FAIL registration failure did not preserve unverifiable path recreation: rc=%s output=%s\n' \
		"$REGISTRATION_FAILURE_RC" "$REGISTRATION_FAILURE_OUTPUT"
	exit 1
fi
jq -e '
	.resource_cleanup_state == "CLEANED"
	and (.receipt_disposition == null)
' "$REGISTRATION_FAILURE_RECEIPT" >/dev/null || {
	printf 'FAIL registration failure superseded terminal receipt before ownership was durable\n'
	exit 1
}
[[ "$(full_loop_cleanup_receipt_for_worktree "$REGISTRATION_FAILURE_PATH")" == "$REGISTRATION_FAILURE_RECEIPT" ]] || {
	printf 'FAIL registration failure retired selectable terminal receipt evidence\n'
	exit 1
}
printf 'PASS registration failure preserves terminal receipt and unverifiable worktree generation\n'

ACTIVE_RECEIPT_BRANCH="test/recreated-active-path"
ACTIVE_RECEIPT_PATH="${WORKTREES}/canonical-test-recreated-active-path"
git -C "$CANONICAL" branch "$ACTIVE_RECEIPT_BRANCH" "$PINNED_SHA"
ACTIVE_RECEIPT=$(full_loop_write_cleanup_deferred example/repository 778 \
	"$ACTIVE_RECEIPT_PATH" "$ACTIVE_RECEIPT_BRANCH" "$$" active-session not-requested)
ACTIVE_OUTPUT=""
ACTIVE_RC=0
ACTIVE_OUTPUT=$(
	cd "$CANONICAL" || exit 1
	AIDEVOPS_SKIP_AUTO_CLAIM=1 "$HELPER" add "$ACTIVE_RECEIPT_BRANCH" "$ACTIVE_RECEIPT_PATH" 2>&1
) || ACTIVE_RC=$?
if [[ "$ACTIVE_RC" -eq 0 || -d "$ACTIVE_RECEIPT_PATH" ||
	"$ACTIVE_OUTPUT" != *"AIDEVOPS_WORKTREE_LIFECYCLE_DISPOSITION=RECONCILIATION_FAILED"* ]]; then
	printf 'FAIL active cleanup receipt did not roll back path recreation: rc=%s output=%s\n' \
		"$ACTIVE_RC" "$ACTIVE_OUTPUT"
	exit 1
fi
jq -e '
	.resource_cleanup_state == "CLEANUP_DEFERRED"
	and (.receipt_disposition == null)
' "$ACTIVE_RECEIPT" >/dev/null || {
	printf 'FAIL active cleanup receipt was mutated during rejected path recreation\n'
	exit 1
}
printf 'PASS active cleanup receipt blocks and rolls back path recreation\n'
ACTIVE_OWNER_COUNT=$(sqlite3 "$REGISTRY_DB" \
	"SELECT COUNT(*) FROM worktree_owners WHERE branch = '${ACTIVE_RECEIPT_BRANCH}';")
[[ "$ACTIVE_OWNER_COUNT" == "0" ]] || {
	printf 'FAIL rejected path recreation retained a stale ownership registration\n'
	exit 1
}
printf 'PASS receipt reconciliation rollback retires ownership registration\n'

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
