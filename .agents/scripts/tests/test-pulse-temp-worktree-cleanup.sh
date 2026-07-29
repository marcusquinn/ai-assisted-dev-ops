#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for stale detached fixture cleanup and stale local main.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSE_CLEANUP="${SCRIPT_DIR}/../pulse-cleanup.sh"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

# Fixture repositories are intentionally isolated under TEST_ROOT. Use native
# Git so the production canonical-worktree shim does not block test setup.
git() {
	/usr/bin/git "$@"
	return $?
}

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$detail"
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

age_gitfile() {
	local gitfile="$1"
	local hours_ago="$2"
	if touch -d "${hours_ago} hours ago" "$gitfile" 2>/dev/null; then
		return 0
	fi
	local old_ts=""
	old_ts=$(date -v-"${hours_ago}"H +%Y%m%d%H%M 2>/dev/null \
		|| date -d "${hours_ago} hours ago" +%Y%m%d%H%M 2>/dev/null) || return 1
	touch -t "$old_ts" "$gitfile"
	return $?
}

setup_subject() {
	TEST_ROOT=$(mktemp -d) || return 1
	TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P) || return 1
	trap teardown EXIT
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_LOG_DIR="${HOME}/.aidevops/logs"
	export AIDEVOPS_REPOS_JSON="${HOME}/.config/aidevops/repos.json"
	export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup.log"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/automation"
	export AIDEVOPS_TODO_SYNC_TRASH_ROOT="${TEST_ROOT}/todo-sync-trash"
	export TEMP_WORKTREE_GRACE_SECS=3600
	export TEMP_WORKTREE_MAX_REMOVALS_PER_RUN=10
	export PRE_RUN_STAGE_TIMEOUT=10
	export PULSE_TODO_SYNC_WORKSPACE_GRACE_SECS=11
	export PULSE_TODO_SYNC_MAX_RECOVERIES_PER_RUN=5
	unset TEMP_WORKTREE_LOCK_STALE_SECS PULSE_TODO_SYNC_LEGACY_MIN_AGE_SECS \
		PULSE_TODO_SYNC_MAX_LEGACY_MIGRATIONS_PER_RUN 2>/dev/null || true
	mkdir -p "$AIDEVOPS_LOG_DIR" "${HOME}/.config/aidevops" "$AIDEVOPS_TEMP_DIR" || return 1

	is_registered_canonical() { local wt_path="$1"; : "$wt_path"; return 1; }
	is_worktree_owned_by_others() { local wt_path="$1"; : "$wt_path"; return 1; }
	unregister_worktree() { local wt_path="$1"; : "$wt_path"; return 0; }
	gh_pr_list() { return 0; }
	recover_failed_launch_state() { return 0; }
	gh_issue_comment() { return 0; }

	unset _PULSE_CLEANUP_LOADED 2>/dev/null || true
	unset _PULSE_TEMP_WORKTREE_CLEANUP_LOADED 2>/dev/null || true
	unset _PULSE_TODO_SYNC_WORKSPACE_LOADED 2>/dev/null || true
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../portable-stat.sh
	source "${SCRIPT_DIR}/../portable-stat.sh"
	# shellcheck source=../pulse-cleanup.sh
	source "$PULSE_CLEANUP"
	return 0
}

create_repo_with_remote() {
	local repo_path="$1"
	local remote_path="$2"
	git init -q --bare "$remote_path" || return 1
	git init -q -b main "$repo_path" || return 1
	git -C "$repo_path" config user.email test@example.invalid || return 1
	git -C "$repo_path" config user.name 'Aidevops Test' || return 1
	printf 'base\n' >"${repo_path}/README.md" || return 1
	printf '.fixture-cache\n' >"${repo_path}/.gitignore" || return 1
	git -C "$repo_path" add README.md .gitignore || return 1
	git -C "$repo_path" commit -q -m base || return 1
	git -C "$repo_path" remote add origin "$remote_path" || return 1
	git -C "$repo_path" push -q -u origin main || return 1
	git -C "$remote_path" symbolic-ref HEAD refs/heads/main || return 1
	printf '{"initialized_repos":[{"path":"%s","slug":"example/repo"}]}\n' \
		"$repo_path" >"$AIDEVOPS_REPOS_JSON" || return 1
	return 0
}

create_todo_sync_candidate() {
	local identity="$1"
	local owner_pid="$2"
	local owner_start="$3"
	local owner_created="$4"
	local workspace_root="${AIDEVOPS_TEMP_DIR}/${identity}"
	mkdir -p "$workspace_root" || return 1
	printf '%s\t%s\t%s\t%s\n' "$_PTSW_MARKER_VERSION" "$owner_pid" \
		"$owner_created" "$owner_start" >"${workspace_root}/${_PTSW_OWNER_MARKER}" || return 1
	printf '%s\n' "$workspace_root"
	return 0
}

create_legacy_todo_sync_candidate() {
	local identity="$1"
	local workspace_root="${AIDEVOPS_TEMP_DIR}/${identity}"
	mkdir -p "${workspace_root}/repo" || return 1
	git init -q "${workspace_root}/repo" || return 1
	printf '%s\n' "$workspace_root"
	return 0
}

count_todo_sync_candidates() {
	local workspace_root=""
	local candidate_count=0
	for workspace_root in "$AIDEVOPS_TEMP_DIR"/pulse-todo-sync.*; do
		[[ -d "$workspace_root" ]] || continue
		candidate_count=$((candidate_count + 1))
	done
	printf '%s\n' "$candidate_count"
	return 0
}

test_fast_temp_cleanup_guards() {
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo"
	local remote_path="${TEST_ROOT}/remote.git"
	local old_clean="${TEST_ROOT}/tmp.old-clean"
	local old_dirty="${TEST_ROOT}/tmp.old-dirty"
	local old_ignored="${TEST_ROOT}/tmp.old-ignored"
	local old_unpushed="${TEST_ROOT}/tmp.old-unpushed"
	local old_active="${TEST_ROOT}/tmp.old-active"
	local fresh_clean="${TEST_ROOT}/tmp.fresh-clean"
	local snapshot_count_file="${TEST_ROOT}/snapshot-count"
	local removed=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1

	git -C "$repo_path" worktree add -q --detach "$old_clean" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$old_dirty" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$old_ignored" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$old_unpushed" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$old_active" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$fresh_clean" origin/main || return 1
	age_gitfile "$old_clean/.git" 2 || return 1
	age_gitfile "$old_dirty/.git" 2 || return 1
	age_gitfile "$old_ignored/.git" 2 || return 1
	age_gitfile "$old_unpushed/.git" 2 || return 1
	age_gitfile "$old_active/.git" 2 || return 1
	printf 'dirty fixture\n' >"${old_dirty}/dirty.txt" || return 1
	printf 'ignored fixture data\n' >"${old_ignored}/.fixture-cache" || return 1
	printf 'unique detached commit\n' >"${old_unpushed}/unique.txt" || return 1
	git -C "$old_unpushed" add unique.txt || return 1
	git -C "$old_unpushed" -c user.email=test@example.invalid -c user.name='Aidevops Test' \
		commit -q -m 'unique detached commit' || return 1
	capture_worktree_process_cwds() {
		local snapshot_count=0
		if [[ -f "$snapshot_count_file" ]]; then
			IFS= read -r snapshot_count <"$snapshot_count_file" || snapshot_count=0
		fi
		snapshot_count=$((snapshot_count + 1))
		printf '%s\n' "$snapshot_count" >"$snapshot_count_file"
		printf '%s\n' "$old_active"
		return 0
	}

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "1" ]] || rc=1
	[[ ! -e "$old_clean" ]] || rc=1
	[[ -d "$old_dirty" && -f "$old_dirty/dirty.txt" ]] || rc=1
	[[ -d "$old_ignored" && -f "$old_ignored/.fixture-cache" ]] || rc=1
	[[ -d "$old_unpushed" && -f "$old_unpushed/unique.txt" ]] || rc=1
	[[ -d "$old_active" ]] || rc=1
	[[ -d "$fresh_clean" ]] || rc=1
	# Both otherwise-removable candidates get independent snapshots. The active
	# candidate is refused and the clean candidate is removed.
	[[ -f "$snapshot_count_file" ]] && [[ "$(<"$snapshot_count_file")" == "2" ]] || rc=1
	git -C "$repo_path" worktree list --porcelain | grep -Fq "worktree $old_clean" && rc=1
	grep -q 'stale-temp-fixture' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "fast cleanup removes only old clean remote-reachable detached fixtures" "$rc" \
		"removed=$removed"
	return 0
}

test_local_only_repo_is_excluded() {
	teardown
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo-local"
	local remote_path="${TEST_ROOT}/remote-local.git"
	local wt_path="${TEST_ROOT}/tmp.local-only"
	local capture_marker="${TEST_ROOT}/capture-called"
	local removed=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_path" origin/main || return 1
	age_gitfile "$wt_path/.git" 2 || return 1
	printf '{"initialized_repos":[{"path":"%s","slug":"example/local","local_only":true}]}\n' \
		"$repo_path" >"$AIDEVOPS_REPOS_JSON" || return 1
	capture_worktree_process_cwds() {
		: >"$capture_marker"
		return 0
	}

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "0" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	[[ ! -e "$capture_marker" ]] || rc=1
	print_result "fast cleanup excludes local-only repositories" "$rc" "removed=$removed"
	return 0
}

test_cleanup_bounds_fresh_snapshots() {
	teardown
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo-bounded"
	local remote_path="${TEST_ROOT}/remote-bounded.git"
	local wt_one="${TEST_ROOT}/tmp.bound-one"
	local wt_two="${TEST_ROOT}/tmp.bound-two"
	local snapshot_count_file="${TEST_ROOT}/bounded-snapshot-count"
	local remaining=0
	local removed=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_one" origin/main || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_two" origin/main || return 1
	age_gitfile "$wt_one/.git" 2 || return 1
	age_gitfile "$wt_two/.git" 2 || return 1
	export TEMP_WORKTREE_MAX_REMOVALS_PER_RUN=1
	capture_worktree_process_cwds() {
		local snapshot_count=0
		if [[ -f "$snapshot_count_file" ]]; then
			IFS= read -r snapshot_count <"$snapshot_count_file" || snapshot_count=0
		fi
		snapshot_count=$((snapshot_count + 1))
		printf '%s\n' "$snapshot_count" >"$snapshot_count_file"
		return 0
	}

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "1" ]] || rc=1
	[[ "$(<"$snapshot_count_file")" == "1" ]] || rc=1
	[[ -d "$wt_one" ]] && remaining=$((remaining + 1))
	[[ -d "$wt_two" ]] && remaining=$((remaining + 1))
	[[ "$remaining" -eq 1 ]] || rc=1
	print_result "fast cleanup bounds removals and captures one fresh snapshot per removal" "$rc" \
		"removed=$removed remaining=$remaining"
	return 0
}

test_degraded_visibility_preserves_temp_candidate() {
	teardown
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo-degraded"
	local remote_path="${TEST_ROOT}/remote-degraded.git"
	local wt_path="${TEST_ROOT}/tmp.degraded-visibility"
	local removed=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_path" origin/main || return 1
	age_gitfile "$wt_path/.git" 2 || return 1
	capture_worktree_process_cwds() {
		printf '%s\n' "/unrelated-readable-cwd"
		return "${_WT_CWD_CAPTURE_DEGRADED_RC:-2}"
	}

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "0" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	grep -q 'cwd-visibility-degraded' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "temp cleanup blocks degraded absence-only visibility" "$rc" \
		"removed=$removed candidate_exists=$([[ -d "$wt_path" ]] && printf y || printf n)"
	return 0
}

test_cleanup_lock_race_guards() {
	teardown
	setup_subject || return 1
	local lock_dir="${AIDEVOPS_LOG_DIR}/cleanup_temp_worktrees.lock"
	local reclaim_guard="${lock_dir}.reclaim.v2.lock"
	local guard_snapshot="${reclaim_guard}.snapshot.manual"
	local guard_record=""
	local fresh_record=""
	local guard_token=""
	local live_start=""
	local rc=0

	# A freshly-created lock without its PID is an owner publication window, not
	# stale state. A contender must preserve it.
	mkdir "$lock_dir" || return 1
	if _ptwc_lock_acquire; then
		rc=1
	fi
	[[ -d "$lock_dir" ]] || rc=1
	rm -rf "$lock_dir"

	# PID liveness alone is not ownership: the stored process-start fingerprint
	# must match so a recycled PID cannot preserve an abandoned lock.
	live_start=$(_ptwc_process_start_fingerprint "$$") || return 1
	mkdir "$lock_dir" || return 1
	printf '%s\n' "$$" >"${lock_dir}/pid" || return 1
	printf '%s\n' "$live_start" >"${lock_dir}/start" || return 1
	if _ptwc_lock_acquire; then
		rc=1
	fi
	[[ -d "$lock_dir" ]] || rc=1
	printf 'recycled-process-start\n' >"${lock_dir}/start" || return 1
	_ptwc_lock_acquire || rc=1
	[[ -n "$_PTWC_LOCK_OWNER_PID" && -n "$_PTWC_LOCK_OWNER_START" ]] || rc=1
	_ptwc_lock_release "$lock_dir"
	[[ ! -e "$lock_dir" ]] || rc=1

	# Inode comparison prevents a delayed stale-guard reclaimer from unlinking a
	# newly published successor at the same path.
	guard_record=$'stale_guard\t99999999\tdead-process-start'
	printf -v fresh_record '%s\t%s\t%s' "fresh_guard" "$$" "$live_start"
	printf '%s\n' "$guard_record" >"$reclaim_guard" || return 1
	ln "$reclaim_guard" "$guard_snapshot" || return 1
	rm -f "$reclaim_guard" || return 1
	printf '%s\n' "$fresh_record" >"$reclaim_guard" || return 1
	if _ptwc_inode_compare_unlink "$reclaim_guard" "$guard_snapshot"; then
		rc=1
	fi
	[[ -f "$reclaim_guard" ]] || rc=1
	rm -f "$guard_snapshot" "$reclaim_guard"

	# A live reclaim owner serialises dead-main-lock inspection. Once that owner
	# is gone, a stranded guard is recovered through the inode-checked protocol.
	mkdir "$lock_dir" || return 1
	printf '99999999\n' >"${lock_dir}/pid" || return 1
	printf 'dead-process-start\n' >"${lock_dir}/start" || return 1
	_ptwc_reclaim_guard_acquire "$reclaim_guard" "$$" "$live_start" 300 || return 1
	guard_token="$_PTWC_RECLAIM_GUARD_TOKEN"
	if _ptwc_lock_acquire; then
		rc=1
	fi
	[[ -f "${lock_dir}/pid" ]] || rc=1
	_ptwc_reclaim_guard_release "$reclaim_guard" "$guard_token" "$$" "$live_start" || rc=1
	guard_record=$'stranded_guard\t99999999\tdead-process-start'
	printf '%s\n' "$guard_record" >"$reclaim_guard" || return 1
	_ptwc_lock_acquire || rc=1
	[[ -n "$_PTWC_LOCK_OWNER_PID" && ! -e "$reclaim_guard" ]] || rc=1

	# Release must not delete a successor lock whose process identity no longer
	# matches this caller's ownership token, even if the PID is unchanged.
	printf '%s\n' "$_PTWC_LOCK_OWNER_PID" >"${lock_dir}/pid" || return 1
	printf 'successor-process-start\n' >"${lock_dir}/start" || return 1
	_ptwc_lock_release "$lock_dir"
	[[ -d "$lock_dir" ]] || rc=1
	[[ -z "$_PTWC_LOCK_DIR" && -z "$_PTWC_LOCK_OWNER_PID" && \
		-z "$_PTWC_LOCK_OWNER_START" && -z "$_PTWC_RECLAIM_GUARD_TOKEN" ]] || rc=1
	rm -rf "$lock_dir"
	print_result "cleanup locks recover stranded guards without deleting successors" "$rc"
	return 0
}

test_stale_local_main_uses_remote_default() {
	teardown
	setup_subject || return 1
	local repo_path="${TEST_ROOT}/repo-stale-main"
	local remote_path="${TEST_ROOT}/remote-stale-main.git"
	local wt_path="${TEST_ROOT}/tmp.remote-tip"
	local base_sha=""
	local now_epoch=0
	local cleanup_rc=0
	local rc=0
	create_repo_with_remote "$repo_path" "$remote_path" || return 1
	base_sha=$(git -C "$repo_path" rev-parse HEAD) || return 1
	printf 'remote tip\n' >"${repo_path}/remote-tip.txt" || return 1
	git -C "$repo_path" add remote-tip.txt || return 1
	git -C "$repo_path" commit -q -m 'remote tip' || return 1
	git -C "$repo_path" push -q origin main || return 1
	git -C "$repo_path" worktree add -q --detach "$wt_path" origin/main || return 1
	git -C "$repo_path" reset -q --hard "$base_sha" || return 1
	age_gitfile "$wt_path/.git" 2 || return 1
	now_epoch=$(date +%s)

	_cleanup_single_worktree "$repo_path" "$wt_path" "" "$now_epoch" "example/repo" "main" >/dev/null 2>&1
	cleanup_rc=$?
	[[ "$cleanup_rc" -eq 0 ]] || rc=1
	[[ ! -e "$wt_path" ]] || rc=1
	print_result "orphan cleanup compares against origin/main when local main is stale" "$rc" \
		"cleanup_rc=$cleanup_rc"
	return 0
}

test_path_classifier_rejects_normal_linked_worktree() {
	local rc=0
	_ptwc_is_temp_fixture_path "/home/example/Git/_worktrees/repo-feature" && rc=1
	_ptwc_is_temp_fixture_path "/private/var/folders/aa/bb/T/tmp.fixture/base-worktree" || rc=1
	print_result "temp cleanup path classifier is narrowly scoped" "$rc"
	return 0
}

test_todo_sync_active_grace_and_visibility_guards() {
	teardown
	setup_subject || return 1
	local now_epoch=0
	local live_start=""
	local active_workspace=""
	local grace_workspace=""
	local unknown_workspace=""
	local visibility_definition=""
	local removed=0
	local rc=0
	now_epoch=$(date +%s) || return 1
	live_start=$(_ptsw_process_start_fingerprint "$$") || return 1
	active_workspace=$(create_todo_sync_candidate "pulse-todo-sync.ACTIVE" "$$" "$live_start" "$((now_epoch - 20))") || return 1
	grace_workspace=$(create_todo_sync_candidate "pulse-todo-sync.GRACE1" "99999991" "dead-owner" "$now_epoch") || return 1
	unknown_workspace=$(create_todo_sync_candidate "pulse-todo-sync.UNKNWN" "99999992" "dead-owner" "$((now_epoch - 20))") || return 1
	visibility_definition=$(declare -f _ptsw_process_visibility_available)
	_ptsw_process_visibility_available() { return 1; }

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	eval "$visibility_definition"
	[[ "$removed" == "0" ]] || rc=1
	[[ -d "$active_workspace" && -d "$grace_workspace" && -d "$unknown_workspace" ]] || rc=1
	grep -q 'reason=active-owner workspace=pulse-todo-sync.ACTIVE' "$LOGFILE" 2>/dev/null || rc=1
	grep -q 'reason=grace-period workspace=pulse-todo-sync.GRACE1' "$LOGFILE" 2>/dev/null || rc=1
	grep -q 'reason=owner-visibility-unknown workspace=pulse-todo-sync.UNKNWN' "$LOGFILE" 2>/dev/null || rc=1
	print_result "TODO-sync cleanup preserves active, fresh, and visibility-unknown owners" "$rc" \
		"removed=$removed"
	return 0
}

test_todo_sync_live_pid_with_hidden_identity_is_preserved() {
	teardown
	setup_subject || return 1
	local now_epoch=0
	local live_start=""
	local workspace_root=""
	local visibility_definition=""
	local ps_definition=""
	local removed=0
	local rc=0
	now_epoch=$(date +%s) || return 1
	live_start=$(_ptsw_process_start_fingerprint "$$") || return 1
	workspace_root=$(create_todo_sync_candidate "pulse-todo-sync.LIVEID" "$$" "$live_start" "$((now_epoch - 20))") || return 1
	visibility_definition=$(declare -f _ptsw_process_visibility_available)
	ps_definition=$(declare -f ps 2>/dev/null || true)
	_ptsw_process_visibility_available() { return 0; }
	ps() { return 1; }

	removed=$(_ptsw_sweep_stale_workspaces) || rc=1
	eval "$visibility_definition"
	if [[ -n "$ps_definition" ]]; then
		eval "$ps_definition"
	else
		unset -f ps
	fi
	[[ "$removed" == "0" ]] || rc=1
	[[ -d "$workspace_root" ]] || rc=1
	grep -q 'reason=owner-visibility-unknown workspace=pulse-todo-sync.LIVEID' "$LOGFILE" 2>/dev/null || rc=1
	print_result "TODO-sync cleanup fails closed for a live PID with hidden identity" "$rc" \
		"removed=$removed"
	return 0
}

test_todo_sync_stale_recovery_name_guard_and_cap() {
	teardown
	setup_subject || return 1
	local now_epoch=0
	local first_workspace=""
	local second_workspace=""
	local malformed_workspace=""
	local remaining=0
	local trash_count=0
	local trash_path=""
	local removed=0
	local rc=0
	now_epoch=$(date +%s) || return 1
	export PULSE_TODO_SYNC_MAX_RECOVERIES_PER_RUN=1
	first_workspace=$(create_todo_sync_candidate "pulse-todo-sync.AAAAAA" "99999993" "dead-owner" "$((now_epoch - 20))") || return 1
	second_workspace=$(create_todo_sync_candidate "pulse-todo-sync.BBBBBB" "99999994" "dead-owner" "$((now_epoch - 20))") || return 1
	malformed_workspace=$(create_todo_sync_candidate "pulse-todo-sync.bad-name" "99999995" "dead-owner" "$((now_epoch - 20))") || return 1

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "1" ]] || rc=1
	remaining=$(count_todo_sync_candidates)
	[[ "$remaining" == "2" ]] || rc=1
	[[ -d "$malformed_workspace" ]] || rc=1
	if [[ ! -d "$first_workspace" && ! -d "$second_workspace" ]]; then
		rc=1
	fi
	for trash_path in "$AIDEVOPS_TODO_SYNC_TRASH_ROOT"/aidevops-pulse-todo-sync-*; do
		[[ -d "$trash_path" ]] || continue
		trash_count=$((trash_count + 1))
	done
	[[ "$trash_count" -eq 1 ]] || rc=1
	grep -q 'outcome=removed reason=dead-owner workspace=pulse-todo-sync\.' "$LOGFILE" 2>/dev/null || rc=1
	grep -q 'reason=recovery-cap workspace=pulse-todo-sync\.' "$LOGFILE" 2>/dev/null || rc=1
	grep -q 'reason=malformed-name workspace=pulse-todo-sync.bad-name' "$LOGFILE" 2>/dev/null || rc=1
	print_result "TODO-sync cleanup trashes only valid stale candidates within its cap" "$rc" \
		"removed=$removed remaining=$remaining trash_count=$trash_count"
	return 0
}

test_todo_sync_trash_failure_is_audited() {
	teardown
	setup_subject || return 1
	local now_epoch=0
	local workspace_root=""
	local blocked_trash="${TEST_ROOT}/blocked-trash"
	local removed=0
	local rc=0
	now_epoch=$(date +%s) || return 1
	workspace_root=$(create_todo_sync_candidate "pulse-todo-sync.FAIL01" "99999996" "dead-owner" "$((now_epoch - 20))") || return 1
	printf 'not a directory\n' >"$blocked_trash" || return 1
	export AIDEVOPS_TODO_SYNC_TRASH_ROOT="$blocked_trash"

	removed=$(cleanup_stale_temp_worktrees) || rc=1
	[[ "$removed" == "0" ]] || rc=1
	[[ -d "$workspace_root" ]] || rc=1
	grep -q 'outcome=failure reason=trash-move-failed workspace=pulse-todo-sync.FAIL01' "$LOGFILE" 2>/dev/null || rc=1
	print_result "TODO-sync trash failures remain recoverable and auditable" "$rc" \
		"removed=$removed candidate_exists=$([[ -d "$workspace_root" ]] && printf y || printf n)"
	return 0
}

test_todo_sync_legacy_markerless_migration_is_guarded() {
	teardown
	setup_subject || return 1
	local old_workspace="" fresh_workspace="" active_workspace="" malformed_workspace=""
	local cwd_capture_definition="" command_snapshot_definition=""
	local trash_path="" trash_count=0 removed=0 rc=0
	old_workspace=$(create_legacy_todo_sync_candidate "pulse-todo-sync.LEGACY") || return 1
	fresh_workspace=$(create_legacy_todo_sync_candidate "pulse-todo-sync.FRESH1") || return 1
	active_workspace=$(create_legacy_todo_sync_candidate "pulse-todo-sync.ACTIVE") || return 1
	malformed_workspace="${AIDEVOPS_TEMP_DIR}/pulse-todo-sync.BAD001"
	mkdir -p "${malformed_workspace}/unexpected" || return 1
	age_gitfile "$old_workspace" 2 || return 1
	age_gitfile "$active_workspace" 2 || return 1
	age_gitfile "$malformed_workspace" 2 || return 1
	export PULSE_TODO_SYNC_LEGACY_MIN_AGE_SECS=12
	export PULSE_TODO_SYNC_MAX_LEGACY_MIGRATIONS_PER_RUN=10
	cwd_capture_definition=$(declare -f capture_worktree_process_cwds)
	command_snapshot_definition=$(declare -f _ptsw_process_command_snapshot)
	capture_worktree_process_cwds() {
		printf '%s\n' "$active_workspace"
		return 0
	}
	_ptsw_process_command_snapshot() {
		printf '/safe/process\n'
		return 0
	}

	removed=$(_ptsw_sweep_stale_workspaces) || rc=1
	eval "$cwd_capture_definition"
	eval "$command_snapshot_definition"
	[[ "$removed" == "1" ]] || rc=1
	[[ ! -e "$old_workspace" ]] || rc=1
	[[ -d "$fresh_workspace" && -d "$active_workspace" && -d "$malformed_workspace" ]] || rc=1
	for trash_path in "$AIDEVOPS_TODO_SYNC_TRASH_ROOT"/aidevops-pulse-todo-sync-*; do
		[[ -d "$trash_path" ]] || continue
		trash_count=$((trash_count + 1))
	done
	[[ "$trash_count" -eq 1 ]] || rc=1
	grep -q 'outcome=removed reason=legacy-markerless workspace=pulse-todo-sync.LEGACY' "$LOGFILE" 2>/dev/null || rc=1
	grep -q 'reason=legacy-age-guard workspace=pulse-todo-sync.FRESH1' "$LOGFILE" 2>/dev/null || rc=1
	grep -q 'reason=legacy-active-process workspace=pulse-todo-sync.ACTIVE' "$LOGFILE" 2>/dev/null || rc=1
	grep -q 'reason=legacy-shape-mismatch workspace=pulse-todo-sync.BAD001' "$LOGFILE" 2>/dev/null || rc=1
	if grep -q "$TEST_ROOT" "$LOGFILE" 2>/dev/null; then
		rc=1
	fi
	print_result "TODO-sync cleanup migrates only old, idle, clone-shaped markerless workspaces" "$rc" \
		"removed=$removed trash_count=$trash_count"
	return 0
}

test_todo_sync_legacy_markerless_migration_fails_closed() {
	teardown
	setup_subject || return 1
	local workspace_root="" cwd_capture_definition="" command_snapshot_definition=""
	local removed=0 rc=0
	workspace_root=$(create_legacy_todo_sync_candidate "pulse-todo-sync.UNKNWN") || return 1
	age_gitfile "$workspace_root" 2 || return 1
	export PULSE_TODO_SYNC_LEGACY_MIN_AGE_SECS=12
	cwd_capture_definition=$(declare -f capture_worktree_process_cwds)
	command_snapshot_definition=$(declare -f _ptsw_process_command_snapshot)
	capture_worktree_process_cwds() {
		printf '/safe/process\n'
		return 2
	}
	_ptsw_process_command_snapshot() {
		printf '/safe/process\n'
		return 0
	}

	removed=$(_ptsw_sweep_stale_workspaces) || rc=1
	eval "$cwd_capture_definition"
	eval "$command_snapshot_definition"
	[[ "$removed" == "0" && -d "$workspace_root" ]] || rc=1
	grep -q 'reason=legacy-process-visibility-unknown workspace=pulse-todo-sync.UNKNWN' "$LOGFILE" 2>/dev/null || rc=1
	print_result "TODO-sync markerless migration fails closed on degraded process visibility" "$rc" \
		"removed=$removed candidate_exists=$([[ -d "$workspace_root" ]] && printf y || printf n)"
	return 0
}

test_todo_sync_legacy_markerless_migration_is_capped() {
	teardown
	setup_subject || return 1
	local first_workspace="" second_workspace=""
	local cwd_capture_definition="" command_snapshot_definition=""
	local remaining=0 removed=0 rc=0
	first_workspace=$(create_legacy_todo_sync_candidate "pulse-todo-sync.AAAAAA") || return 1
	second_workspace=$(create_legacy_todo_sync_candidate "pulse-todo-sync.BBBBBB") || return 1
	age_gitfile "$first_workspace" 2 || return 1
	age_gitfile "$second_workspace" 2 || return 1
	export PULSE_TODO_SYNC_LEGACY_MIN_AGE_SECS=12
	export PULSE_TODO_SYNC_MAX_LEGACY_MIGRATIONS_PER_RUN=1
	cwd_capture_definition=$(declare -f capture_worktree_process_cwds)
	command_snapshot_definition=$(declare -f _ptsw_process_command_snapshot)
	capture_worktree_process_cwds() {
		printf '/safe/process\n'
		return 0
	}
	_ptsw_process_command_snapshot() {
		printf '/safe/process\n'
		return 0
	}

	removed=$(_ptsw_sweep_stale_workspaces) || rc=1
	eval "$cwd_capture_definition"
	eval "$command_snapshot_definition"
	remaining=$(count_todo_sync_candidates)
	[[ "$removed" == "1" && "$remaining" == "1" ]] || rc=1
	grep -q 'reason=legacy-recovery-cap workspace=legacy-batch cap=1' "$LOGFILE" 2>/dev/null || rc=1
	print_result "TODO-sync markerless migration obeys its per-run recovery cap" "$rc" \
		"removed=$removed remaining=$remaining"
	return 0
}

run_test() {
	local test_function="$1"
	local tests_before="$TESTS_RUN"
	local test_rc=0
	if "$test_function"; then
		test_rc=0
	else
		test_rc=$?
	fi
	if [[ "$TESTS_RUN" -eq "$tests_before" ]]; then
		print_result "$test_function" 1 "aborted before reporting a result (rc=$test_rc)"
	fi
	return 0
}

run_test test_fast_temp_cleanup_guards
run_test test_local_only_repo_is_excluded
run_test test_cleanup_bounds_fresh_snapshots
run_test test_degraded_visibility_preserves_temp_candidate
run_test test_cleanup_lock_race_guards
run_test test_stale_local_main_uses_remote_default
run_test test_path_classifier_rejects_normal_linked_worktree
run_test test_todo_sync_active_grace_and_visibility_guards
run_test test_todo_sync_live_pid_with_hidden_identity_is_preserved
run_test test_todo_sync_stale_recovery_name_guard_and_cap
run_test test_todo_sync_trash_failure_is_audited
run_test test_todo_sync_legacy_markerless_migration_is_guarded
run_test test_todo_sync_legacy_markerless_migration_fails_closed
run_test test_todo_sync_legacy_markerless_migration_is_capped

printf '\nResults: %s/%s passed, %s failed.\n' \
	"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
