#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSE_CLEANUP="${SCRIPT_DIR}/../pulse-cleanup.sh"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

# Keep isolated fixture mutations on native Git. The repository-level canonical
# guard is under separate test and must not classify temporary main worktrees.
git() {
	"$GIT_BIN" "$@"
	return $?
}

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

setup_subject() {
	TEST_ROOT=$(mktemp -d)
	TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P) || return 1
	trap teardown EXIT
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_REPOS_JSON="${HOME}/.config/aidevops/repos.json"
	export AIDEVOPS_WORKTREE_BASE_DIR="${TEST_ROOT}/Git/_worktrees"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup.log"
	mkdir -p "${HOME}/.config/aidevops" "${HOME}/.aidevops/logs" "${TEST_ROOT}/Git"

	is_registered_canonical() { return 1; }
	unregister_worktree() { local wt_path="$1"; : "$wt_path"; return 0; }
	gh() { return 1; }
	gh_pr_list() { return 0; }
	recover_failed_launch_state() { return 0; }
	gh_issue_comment() { return 0; }

	unset _PULSE_CLEANUP_LOADED 2>/dev/null || true
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../portable-stat.sh
	source "${SCRIPT_DIR}/../portable-stat.sh"
	# shellcheck source=../pulse-cleanup.sh
	source "$PULSE_CLEANUP"
	return 0
}

test_registered_parent_worktree_moves_to_central_base() {
	setup_subject || return 1
	local repo_dir="${TEST_ROOT}/Git/example"
	local old_wt="${TEST_ROOT}/Git/example-feature-old-location"
	local new_wt="${TEST_ROOT}/Git/_worktrees/example-feature-old-location"
	local branch="feature/old-location"
	local rc=0 moved=""

	mkdir -p "$repo_dir" || rc=1
	git -C "$repo_dir" init -q -b main || rc=1
	git -C "$repo_dir" config user.email test@example.invalid || rc=1
	git -C "$repo_dir" config user.name 'Aidevops Test' || rc=1
	printf 'base\n' >"${repo_dir}/README.md" || rc=1
	git -C "$repo_dir" add README.md || rc=1
	git -C "$repo_dir" commit -q -m init || rc=1
	git -C "$repo_dir" worktree add -q -b "$branch" "$old_wt" main || rc=1
	printf '{"initialized_repos":[{"slug":"example/repo","path":"%s","local_only":false}],"worktree_base_dir":"%s"}\n' \
		"$repo_dir" "$AIDEVOPS_WORKTREE_BASE_DIR" >"$AIDEVOPS_REPOS_JSON" || rc=1

	moved=$(_pc_relocate_registered_worktrees "$AIDEVOPS_REPOS_JSON") || rc=1

	[[ "$moved" == "1" ]] || rc=1
	[[ ! -d "$old_wt" ]] || rc=1
	[[ -d "$new_wt" ]] || rc=1
	git -C "$repo_dir" worktree list --porcelain | grep -q "worktree $new_wt" 2>/dev/null || rc=1
	grep -q 'worktree-removed.*centralized-worktree.*mode=moved' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "registered parent worktree moves to central base" "$rc" \
		"moved=$moved log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_current_worktree_is_not_moved() {
	teardown
	setup_subject || return 1
	local repo_dir="${TEST_ROOT}/Git/example-current"
	local old_wt="${TEST_ROOT}/Git/example-current-feature-active"
	local branch="feature/active"
	local rc=0 moved=""
	mkdir -p "$repo_dir" || rc=1
	git -C "$repo_dir" init -q -b main || rc=1
	git -C "$repo_dir" config user.email test@example.invalid || rc=1
	git -C "$repo_dir" config user.name 'Aidevops Test' || rc=1
	git -C "$repo_dir" commit -q --allow-empty -m init || rc=1
	git -C "$repo_dir" worktree add -q -b "$branch" "$old_wt" main || rc=1
	printf '{"initialized_repos":[{"slug":"example/current","path":"%s","local_only":false}],"worktree_base_dir":"%s"}\n' \
		"$repo_dir" "$AIDEVOPS_WORKTREE_BASE_DIR" >"$AIDEVOPS_REPOS_JSON" || rc=1

	(
		cd "$old_wt" || exit 1
		moved=$(_pc_relocate_registered_worktrees "$AIDEVOPS_REPOS_JSON") || exit 1
		[[ "$moved" == "0" ]] || exit 1
	) || rc=1
	[[ -d "$old_wt" ]] || rc=1
	grep -q 'worktree-skipped.*current-worktree.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "current worktree is not relocated" "$rc" \
		"log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_registered_parent_worktree_moves_to_central_base
test_current_worktree_is_not_moved

printf '\n'
printf 'Results: %s/%s passed, %s failed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
