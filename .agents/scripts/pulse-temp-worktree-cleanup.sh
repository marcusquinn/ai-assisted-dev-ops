#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-temp-worktree-cleanup.sh — Fast cleanup for abandoned detached fixture worktrees.

[[ -n "${_PULSE_TEMP_WORKTREE_CLEANUP_LOADED:-}" ]] && return 0
_PULSE_TEMP_WORKTREE_CLEANUP_LOADED=1

_PTWC_REASON="stale-temp-fixture"
_PTWC_GUARD_CLEAR="clear"
_PTWC_LOCK_DIR=""
_PTWC_LOCK_OWNER_PID=""
_PTWC_LOCK_OWNER_START=""
_PTWC_RECLAIM_GUARD_TOKEN=""

_PTWC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_PTWC_SCRIPT_DIR}/pulse-todo-sync-workspace.sh" ]]; then
	# shellcheck source=pulse-todo-sync-workspace.sh
	source "${_PTWC_SCRIPT_DIR}/pulse-todo-sync-workspace.sh"
fi

_ptwc_is_temp_fixture_path() {
	local wt_path="$1"
	case "$wt_path" in
	/tmp/tmp.* | /private/tmp/tmp.* | /var/folders/*/T/tmp.* | /private/var/folders/*/T/tmp.*)
		return 0
		;;
	esac
	return 1
}

_ptwc_file_mtime_epoch() {
	local file_path="$1"
	local mtime=""
	[[ -e "$file_path" || -L "$file_path" ]] || return 1
	mtime=$(_file_mtime_epoch "$file_path") || return 1
	[[ "$mtime" =~ ^[0-9]+$ ]] || return 1
	[[ "$mtime" -gt 0 ]] || return 1
	printf '%s\n' "$mtime"
	return 0
}

_ptwc_process_start_fingerprint() {
	local process_pid="$1"
	local process_start=""
	[[ "$process_pid" =~ ^[0-9]+$ ]] || return 1
	process_start=$(ps -p "$process_pid" -o lstart= 2>/dev/null) || return 1
	process_start="${process_start#"${process_start%%[![:space:]]*}"}"
	process_start="${process_start%"${process_start##*[![:space:]]}"}"
	[[ -n "$process_start" ]] || return 1
	printf '%s\n' "$process_start"
	return 0
}

_ptwc_publish_lock_owner() {
	local lock_dir="$1"
	local owner_pid="$2"
	local owner_start="$3"
	local pid_file="${lock_dir}/pid"
	local start_file="${lock_dir}/start"
	local start_tmp="${start_file}.tmp.${owner_pid}"
	printf '%s\n' "$owner_pid" >"$pid_file" 2>/dev/null || return 1
	if ! printf '%s\n' "$owner_start" >"$start_tmp" 2>/dev/null; then
		rm -f "$start_tmp" 2>/dev/null || true
		return 1
	fi
	if ! mv "$start_tmp" "$start_file" 2>/dev/null; then
		rm -f "$start_tmp" 2>/dev/null || true
		return 1
	fi
	return 0
}

_ptwc_inode_compare_unlink() {
	local guard_path="$1"
	local snapshot_path="$2"
	local compare_rc=0
	command -v python3 >/dev/null 2>&1 || return 1
	python3 - "$guard_path" "$snapshot_path" <<'PY' || compare_rc=$?
import os
import sys

guard_path, snapshot_path = sys.argv[1:3]
try:
    with open(snapshot_path, "rb") as snapshot:
        snapshot_stat = os.fstat(snapshot.fileno())
        try:
            guard_stat = os.stat(guard_path, follow_symlinks=False)
        except FileNotFoundError:
            raise SystemExit(0)
        if (guard_stat.st_dev, guard_stat.st_ino) != (
            snapshot_stat.st_dev,
            snapshot_stat.st_ino,
        ):
            raise SystemExit(1)
        try:
            os.unlink(guard_path)
        except FileNotFoundError:
            pass
except OSError:
    raise SystemExit(1)
PY
	return "$compare_rc"
}

_ptwc_guard_compare_unlink() {
	local guard_path="$1"
	local expected_record="$2"
	local snapshot_tag="$3"
	local snapshot_path="${guard_path}.snapshot.${snapshot_tag}"
	local snapshot_record=""
	local compare_rc=0
	[[ -e "$guard_path" || -L "$guard_path" ]] || return 0
	[[ ! -e "$snapshot_path" && ! -L "$snapshot_path" ]] || return 1
	ln "$guard_path" "$snapshot_path" 2>/dev/null || return 1
	IFS= read -r snapshot_record <"$snapshot_path" || snapshot_record=""
	if [[ "$snapshot_record" != "$expected_record" ]]; then
		rm -f "$snapshot_path" 2>/dev/null || true
		return 1
	fi
	_ptwc_inode_compare_unlink "$guard_path" "$snapshot_path" || compare_rc=$?
	rm -f "$snapshot_path" 2>/dev/null || true
	return "$compare_rc"
}

_ptwc_reclaim_guard_acquire() {
	local guard_path="$1"
	local owner_pid="$2"
	local owner_start="$3"
	local stale_secs="$4"
	local token_epoch=""
	local owner_token=""
	local owner_record=""
	local candidate_path=""
	local guard_record=""
	local guard_token=""
	local guard_pid=""
	local guard_start=""
	local current_start=""
	local guard_mtime=0
	local guard_age=0
	local now_epoch=0
	local needs_age_guard=0

	_PTWC_RECLAIM_GUARD_TOKEN=""
	token_epoch=$(date +%s) || return 1
	[[ "$token_epoch" =~ ^[0-9]+$ ]] || return 1
	owner_token="${owner_pid}_${token_epoch}_${RANDOM}_${RANDOM}"
	printf -v owner_record '%s\t%s\t%s' "$owner_token" "$owner_pid" "$owner_start"
	candidate_path="${guard_path}.candidate.${owner_token}"
	[[ ! -e "$candidate_path" && ! -L "$candidate_path" ]] || return 1
	printf '%s\n' "$owner_record" >"$candidate_path" 2>/dev/null || return 1
	if ln "$candidate_path" "$guard_path" 2>/dev/null; then
		rm -f "$candidate_path" 2>/dev/null || true
		_PTWC_RECLAIM_GUARD_TOKEN="$owner_token"
		return 0
	fi
	[[ -f "$guard_path" ]] || {
		rm -f "$candidate_path" 2>/dev/null || true
		return 1
	}
	IFS= read -r guard_record <"$guard_path" || guard_record=""
	IFS=$'\t' read -r guard_token guard_pid guard_start <<<"$guard_record"
	[[ "$guard_token" =~ ^[A-Za-z0-9_]+$ ]] || needs_age_guard=1
	if [[ "$guard_pid" =~ ^[0-9]+$ ]] && kill -0 "$guard_pid" 2>/dev/null; then
		if [[ -n "$guard_start" ]]; then
			current_start=$(_ptwc_process_start_fingerprint "$guard_pid") || current_start=""
			if [[ -n "$current_start" && "$current_start" == "$guard_start" ]]; then
				rm -f "$candidate_path" 2>/dev/null || true
				return 1
			fi
			[[ -n "$current_start" ]] || needs_age_guard=1
		else
			needs_age_guard=1
		fi
	elif [[ -z "$guard_pid" || ! "$guard_pid" =~ ^[0-9]+$ ]]; then
		needs_age_guard=1
	fi
	if [[ "$needs_age_guard" -eq 1 ]]; then
		guard_mtime=$(_ptwc_file_mtime_epoch "$guard_path") || guard_mtime=0
		now_epoch=$(date +%s) || now_epoch=0
		if [[ "$guard_mtime" -le 0 || "$now_epoch" -le 0 ]]; then
			rm -f "$candidate_path" 2>/dev/null || true
			return 1
		fi
		guard_age=$((now_epoch - guard_mtime))
		if [[ "$guard_age" -lt "$stale_secs" ]]; then
			rm -f "$candidate_path" 2>/dev/null || true
			return 1
		fi
	fi
	if ! _ptwc_guard_compare_unlink "$guard_path" "$guard_record" "$owner_token"; then
		rm -f "$candidate_path" 2>/dev/null || true
		return 1
	fi
	if ! ln "$candidate_path" "$guard_path" 2>/dev/null; then
		rm -f "$candidate_path" 2>/dev/null || true
		return 1
	fi
	rm -f "$candidate_path" 2>/dev/null || true
	_PTWC_RECLAIM_GUARD_TOKEN="$owner_token"
	return 0
}

_ptwc_reclaim_guard_release() {
	local guard_path="$1"
	local owner_token="$2"
	local owner_pid="$3"
	local owner_start="$4"
	local expected_record=""
	local guard_record=""
	local release_rc=0
	[[ -n "$owner_token" ]] || return 0
	printf -v expected_record '%s\t%s\t%s' "$owner_token" "$owner_pid" "$owner_start"
	if [[ ! -e "$guard_path" && ! -L "$guard_path" ]]; then
		_PTWC_RECLAIM_GUARD_TOKEN=""
		return 0
	fi
	IFS= read -r guard_record <"$guard_path" || guard_record=""
	if [[ "$guard_record" != "$expected_record" ]]; then
		_PTWC_RECLAIM_GUARD_TOKEN=""
		return 0
	fi
	_ptwc_guard_compare_unlink "$guard_path" "$expected_record" "${owner_token}_release" || release_rc=$?
	_PTWC_RECLAIM_GUARD_TOKEN=""
	return "$release_rc"
}

_ptwc_head_reachable_from_remote() {
	local repo_path="$1"
	local head_sha="$2"
	local remote_ref=""
	remote_ref=$(git -C "$repo_path" for-each-ref --count=1 --contains "$head_sha" \
		--format='%(refname)' refs/remotes 2>/dev/null) || remote_ref=""
	[[ -n "$remote_ref" ]] || return 1
	return 0
}

_ptwc_worktree_is_clean() {
	local wt_path="$1"
	local status_output=""
	# Ignored files are still user data. A detached fixture is disposable only
	# when tracked, untracked, and ignored content are all absent.
	status_output=$(git -C "$wt_path" status --porcelain=v1 --untracked-files=all \
		--ignored=matching --ignore-submodules=none 2>/dev/null) || return 1
	[[ -z "$status_output" ]] || return 1
	return 0
}

_ptwc_lock_acquire() {
	local log_dir="${AIDEVOPS_LOG_DIR:-${HOME:-}/.aidevops/logs}"
	local lock_dir="${log_dir}/cleanup_temp_worktrees.lock"
	local pid_file="${lock_dir}/pid"
	local start_file="${lock_dir}/start"
	local lock_pid=""
	local lock_start=""
	local owner_pid=""
	local owner_start=""
	local current_start=""
	local lock_mtime=0
	local lock_age=0
	local needs_age_guard=0
	local stale_secs="${TEMP_WORKTREE_LOCK_STALE_SECS:-300}"
	local reclaim_dir=""
	local reclaim_guard="${lock_dir}.reclaim.v2.lock"
	local reclaim_token=""

	[[ -n "$log_dir" ]] || return 1
	[[ "$stale_secs" =~ ^[1-9][0-9]*$ ]] || stale_secs=300
	owner_pid="${BASHPID:-$$}"
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	owner_start=$(_ptwc_process_start_fingerprint "$owner_pid") || return 1
	mkdir -p "$log_dir" 2>/dev/null || return 1
	if mkdir "$lock_dir" 2>/dev/null; then
		if ! _ptwc_publish_lock_owner "$lock_dir" "$owner_pid" "$owner_start"; then
			rm -rf "$lock_dir" 2>/dev/null || true
			return 1
		fi
		_PTWC_LOCK_DIR="$lock_dir"
		_PTWC_LOCK_OWNER_PID="$owner_pid"
		_PTWC_LOCK_OWNER_START="$owner_start"
		return 0
	fi
	# Serialize stale-owner inspection with an atomically published file guard.
	# Stale guard removal uses a hard-link snapshot plus inode-checked unlink so a
	# delayed contender cannot remove a successor's freshly published guard.
	_ptwc_reclaim_guard_acquire "$reclaim_guard" "$owner_pid" "$owner_start" "$stale_secs" || return 1
	reclaim_token="$_PTWC_RECLAIM_GUARD_TOKEN"
	lock_pid=""
	if [[ -f "$pid_file" ]]; then
		IFS= read -r lock_pid <"$pid_file" || lock_pid=""
	fi
	if [[ -f "$start_file" ]]; then
		IFS= read -r lock_start <"$start_file" || lock_start=""
	fi
	if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
		if [[ -n "$lock_start" ]]; then
			current_start=$(_ptwc_process_start_fingerprint "$lock_pid") || current_start=""
			if [[ -n "$current_start" && "$current_start" == "$lock_start" ]]; then
				_ptwc_reclaim_guard_release "$reclaim_guard" "$reclaim_token" "$owner_pid" "$owner_start" || true
				return 1
			fi
			[[ -n "$current_start" ]] || needs_age_guard=1
		else
			needs_age_guard=1
		fi
	elif [[ -z "$lock_pid" || ! "$lock_pid" =~ ^[0-9]+$ ]]; then
		needs_age_guard=1
	fi
	if [[ "$needs_age_guard" -eq 1 ]]; then
		lock_mtime=$(_ptwc_file_mtime_epoch "$lock_dir") || lock_mtime=0
		if [[ "$lock_mtime" -le 0 ]]; then
			_ptwc_reclaim_guard_release "$reclaim_guard" "$reclaim_token" "$owner_pid" "$owner_start" || true
			return 1
		fi
		lock_age=$(($(date +%s) - lock_mtime))
		if [[ "$lock_age" -lt "$stale_secs" ]]; then
			_ptwc_reclaim_guard_release "$reclaim_guard" "$reclaim_token" "$owner_pid" "$owner_start" || true
			return 1
		fi
	fi
	# Rename-before-delete makes stale-lock reclamation atomic. A second caller
	# racing here cannot delete a newly acquired lock owned by the winner.
	reclaim_dir="${lock_dir}.reclaim.${reclaim_token}"
	if ! mv "$lock_dir" "$reclaim_dir" 2>/dev/null; then
		_ptwc_reclaim_guard_release "$reclaim_guard" "$reclaim_token" "$owner_pid" "$owner_start" || true
		return 1
	fi
	if ! rm -rf "$reclaim_dir" 2>/dev/null; then
		_ptwc_reclaim_guard_release "$reclaim_guard" "$reclaim_token" "$owner_pid" "$owner_start" || true
		return 1
	fi
	if ! mkdir "$lock_dir" 2>/dev/null; then
		_ptwc_reclaim_guard_release "$reclaim_guard" "$reclaim_token" "$owner_pid" "$owner_start" || true
		return 1
	fi
	if ! _ptwc_publish_lock_owner "$lock_dir" "$owner_pid" "$owner_start"; then
		rm -rf "$lock_dir" 2>/dev/null || true
		_ptwc_reclaim_guard_release "$reclaim_guard" "$reclaim_token" "$owner_pid" "$owner_start" || true
		return 1
	fi
	_PTWC_LOCK_DIR="$lock_dir"
	_PTWC_LOCK_OWNER_PID="$owner_pid"
	_PTWC_LOCK_OWNER_START="$owner_start"
	if ! _ptwc_reclaim_guard_release "$reclaim_guard" "$reclaim_token" "$owner_pid" "$owner_start"; then
		_ptwc_lock_release "$lock_dir"
		return 1
	fi
	return 0
}

_ptwc_lock_release() {
	local lock_dir="$1"
	local pid_file="${lock_dir}/pid"
	local start_file="${lock_dir}/start"
	local lock_pid=""
	local lock_start=""
	[[ -n "$lock_dir" ]] || return 0
	if [[ -f "$pid_file" ]]; then
		IFS= read -r lock_pid <"$pid_file" || lock_pid=""
	fi
	if [[ -f "$start_file" ]]; then
		IFS= read -r lock_start <"$start_file" || lock_start=""
	fi
	if [[ -z "$_PTWC_LOCK_OWNER_PID" || -z "$_PTWC_LOCK_OWNER_START" || \
		"$lock_pid" != "$_PTWC_LOCK_OWNER_PID" || "$lock_start" != "$_PTWC_LOCK_OWNER_START" ]]; then
		_PTWC_LOCK_DIR=""
		_PTWC_LOCK_OWNER_PID=""
		_PTWC_LOCK_OWNER_START=""
		return 0
	fi
	rm -rf "$lock_dir" 2>/dev/null || true
	_PTWC_LOCK_DIR=""
	_PTWC_LOCK_OWNER_PID=""
	_PTWC_LOCK_OWNER_START=""
	return 0
}

_ptwc_remove_candidate() {
	local repo_path="$1"
	local wt_path="$2"
	local head_sha="$3"
	local detached="$4"
	local now_epoch="$5"
	local grace_secs="$6"
	local created_epoch=0
	local age_secs=0
	local audit_context=""
	local current_head=""
	local cwd_snapshot=""
	local cwd_capture_status=0
	local cwd_visibility="${_WT_CWD_VISIBILITY_UNUSABLE:-unusable}"

	[[ "$detached" == "1" ]] || return 1
	_ptwc_is_temp_fixture_path "$wt_path" || return 1
	[[ -f "$wt_path/.git" ]] || return 1
	created_epoch=$(_ptwc_file_mtime_epoch "$wt_path/.git") || return 1
	age_secs=$((now_epoch - created_epoch))
	[[ "$age_secs" -ge "$grace_secs" ]] || return 1
	declare -F worktree_removal_guard >/dev/null 2>&1 || return 1
	declare -F capture_worktree_process_cwds >/dev/null 2>&1 || return 1
	declare -F _worktree_owner_alive >/dev/null 2>&1 || return 1

	# Recheck candidate-local mutable predicates immediately before the
	# destructive primitive. Each destructive candidate gets a fresh process-CWD
	# snapshot; the outer pass bounds removals so this remains fast enough without
	# widening the check/delete race across candidates.
	git -C "$wt_path" symbolic-ref --quiet HEAD >/dev/null 2>&1 && return 1
	current_head=$(git -C "$wt_path" rev-parse --verify HEAD 2>/dev/null) || return 1
	[[ "$current_head" == "$head_sha" ]] || return 1
	_worktree_owner_alive "$wt_path" "" && return 1
	_ptwc_worktree_is_clean "$wt_path" || return 1
	_ptwc_head_reachable_from_remote "$repo_path" "$current_head" || return 1
	if cwd_snapshot=$(capture_worktree_process_cwds); then
		cwd_capture_status=0
	else
		cwd_capture_status=$?
	fi
	case "$cwd_capture_status" in
	0) cwd_visibility="${_WT_CWD_VISIBILITY_COMPLETE:-complete}" ;;
	"${_WT_CWD_CAPTURE_DEGRADED_RC:-2}") cwd_visibility="${_WT_CWD_VISIBILITY_DEGRADED:-degraded}" ;;
	*) cwd_visibility="${_WT_CWD_VISIBILITY_UNUSABLE:-unusable}" ;;
	esac
	worktree_removal_guard "$wt_path" "pulse-temp-worktree-cleanup.sh" "$_PTWC_REASON" \
		"$cwd_snapshot" "$cwd_visibility" || return 1
	# Keep the post-snapshot window minimal while still proving HEAD did not move.
	git -C "$wt_path" symbolic-ref --quiet HEAD >/dev/null 2>&1 && return 1
	[[ "$(git -C "$wt_path" rev-parse --verify HEAD 2>/dev/null)" == "$current_head" ]] || return 1
	if declare -F _pc_worktree_audit_context >/dev/null 2>&1; then
		audit_context=$(_pc_worktree_audit_context "" "" "0" "0" "$age_secs" \
			"remote-ref" "$_PTWC_GUARD_CLEAR" "$_PTWC_GUARD_CLEAR" "$_PTWC_GUARD_CLEAR" "remote-ref")
	fi
	# Use the linked candidate as Git context. The canonical Git guard permits
	# linked-worktree mutation but correctly rejects `worktree remove` when -C
	# points at the canonical checkout.
	git -C "$wt_path" worktree remove "$wt_path" >/dev/null 2>&1 || return 1
	if declare -F log_worktree_removal_event >/dev/null 2>&1; then
		log_worktree_removal_event "${_WTAR_REMOVED:-worktree-removed}" "pulse-temp-worktree-cleanup.sh" \
			"$wt_path" "$_PTWC_REASON" "permanent" "$audit_context"
	fi
	if declare -F unregister_worktree >/dev/null 2>&1; then
		unregister_worktree "$wt_path" 2>/dev/null || true
	fi
	printf '%s\n' "[pulse-wrapper] Temp worktree cleanup: removed detached fixture ${wt_path} — clean, age ${age_secs}s, HEAD reachable from remote" >>"${LOGFILE:-/dev/null}"
	return 0
}

_ptwc_cleanup_repo() {
	local repo_path="$1"
	local now_epoch="$2"
	local grace_secs="$3"
	local max_removals="${4:-10}"
	local porcelain=""
	local line=""
	local wt_path=""
	local head_sha=""
	local detached=0
	local removed=0
	[[ "$max_removals" =~ ^[1-9][0-9]*$ ]] || max_removals=10

	porcelain=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null) || {
		printf '0\n'
		return 0
	}
	while IFS= read -r line; do
		case "$line" in
		worktree\ *) wt_path="${line#worktree }" ;;
		HEAD\ *) head_sha="${line#HEAD }" ;;
		detached) detached=1 ;;
		"")
			if [[ "$removed" -ge "$max_removals" ]]; then
				break
			fi
			if [[ -n "$wt_path" && -n "$head_sha" ]] && \
				_ptwc_remove_candidate "$repo_path" "$wt_path" "$head_sha" "$detached" "$now_epoch" "$grace_secs"; then
				removed=$((removed + 1))
			fi
			wt_path=""
			head_sha=""
			detached=0
			;;
		esac
	done <<<"${porcelain}"$'\n'
	printf '%s\n' "$removed"
	return 0
}

cleanup_stale_temp_worktrees() {
	local lock_dir=""
	local repos_json="${AIDEVOPS_REPOS_JSON:-${HOME:-}/.config/aidevops/repos.json}"
	local grace_secs="${TEMP_WORKTREE_GRACE_SECS:-3600}"
	local max_removals="${TEMP_WORKTREE_MAX_REMOVALS_PER_RUN:-10}"
	local now_epoch=0
	local repo_paths=""
	local repo_path=""
	local repo_removed=0
	local todo_sync_removed=0
	local worktree_removed=0
	local total_removed=0
	local remaining_removals=0

	[[ "$grace_secs" =~ ^[0-9]+$ ]] || grace_secs=3600
	[[ "$max_removals" =~ ^[1-9][0-9]*$ ]] || max_removals=10
	if ! _ptwc_lock_acquire; then
		printf '0\n'
		return 0
	fi
	lock_dir="$_PTWC_LOCK_DIR"
	if declare -F _ptsw_sweep_stale_workspaces >/dev/null 2>&1; then
		todo_sync_removed=$(_ptsw_sweep_stale_workspaces) || todo_sync_removed=0
		[[ "$todo_sync_removed" =~ ^[0-9]+$ ]] || todo_sync_removed=0
		total_removed=$((total_removed + todo_sync_removed))
	fi
	if [[ ! -f "$repos_json" ]] || ! command -v jq >/dev/null 2>&1; then
		_ptwc_lock_release "$lock_dir"
		printf '%s\n' "$total_removed"
		return 0
	fi
	now_epoch=$(date +%s)
	repo_paths=$(jq -r '.initialized_repos[]? | select((.local_only // false) != true) | .path // empty' \
		"$repos_json" 2>/dev/null) || repo_paths=""
	while IFS= read -r repo_path; do
		[[ -n "$repo_path" ]] || continue
		[[ "$worktree_removed" -lt "$max_removals" ]] || break
		git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || continue
		remaining_removals=$((max_removals - worktree_removed))
		repo_removed=$(_ptwc_cleanup_repo "$repo_path" "$now_epoch" "$grace_secs" "$remaining_removals")
		[[ "$repo_removed" =~ ^[0-9]+$ ]] || repo_removed=0
		worktree_removed=$((worktree_removed + repo_removed))
		total_removed=$((total_removed + repo_removed))
	done <<<"$repo_paths"
	_ptwc_lock_release "$lock_dir"
	if [[ "$worktree_removed" -gt 0 ]]; then
		printf '%s\n' "[pulse-wrapper] Temp worktree cleanup total: ${worktree_removed} stale detached fixture(s) removed" >>"${LOGFILE:-/dev/null}"
	fi
	printf '%s\n' "$total_removed"
	return 0
}

_pc_default_branch_compare_ref() {
	local repo_path="$1"
	local main_branch="$2"
	if git -C "$repo_path" rev-parse --verify --quiet "refs/remotes/origin/${main_branch}^{commit}" >/dev/null 2>&1; then
		printf 'origin/%s\n' "$main_branch"
		return 0
	fi
	printf '%s\n' "$main_branch"
	return 0
}

_pc_commits_ahead_from_default() {
	local repo_path="$1"
	local wt_path="$2"
	local main_branch="$3"
	local compare_ref=""
	compare_ref=$(_pc_default_branch_compare_ref "$repo_path" "$main_branch") || return 1
	git -C "$wt_path" rev-list --count HEAD "^${compare_ref}" 2>/dev/null
	return $?
}
