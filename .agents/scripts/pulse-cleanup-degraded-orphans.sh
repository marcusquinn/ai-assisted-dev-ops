#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Recoverable Pass 2 cleanup for clean, zero-ahead no-PR worktrees when Linux
# process-CWD visibility is degraded. This module is sourced by pulse-cleanup.sh.

[[ -n "${_PULSE_CLEANUP_DEGRADED_ORPHANS_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_DEGRADED_ORPHANS_LOADED=1

_PCDO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_PCDO_SCRIPT_DIR}/worktree-clean-lib.sh" ]]; then
	# Reuse the cleanup lease and recoverable-move primitives. Their remaining
	# dependencies are resolved only when the corresponding functions are called.
	# shellcheck source=worktree-clean-lib.sh
	source "${_PCDO_SCRIPT_DIR}/worktree-clean-lib.sh"
fi

_pcdo_open_pr_absent_verified() {
	local repo_slug="$1"
	local branch_name="$2"
	local pr_number=""

	[[ -n "$repo_slug" && -n "$branch_name" ]] || return 1
	pr_number=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" --state open \
		--limit 1 --json number --jq '.[].number // empty') || return 1
	[[ -z "$pr_number" ]] || return 1
	return 0
}

_pcdo_release_removal_lease() {
	local wt_path="$1"
	unregister_worktree_if_owner_pid "$wt_path" "$$" 2>/dev/null || true
	return 0
}

_pcdo_post_lease_owner_or_claim_exists() {
	local wt_path="$1"
	local wt_branch="$2"

	if pgrep -f "$wt_path" >/dev/null 2>&1; then
		return 0
	fi
	if _clean_removal_lease_owned_by_others "$wt_path"; then
		return 0
	fi
	if _branch_has_active_interactive_claim "$wt_path" "$wt_branch"; then
		return 0
	fi
	return 1
}

_pcdo_fresh_candidate_state_is_safe() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local now_epoch="$4"
	local repo_slug_age="$5"
	local main_branch="$6"
	local orphan_issue_num="$7"
	local repo_name_age="$8"
	local audit_context="$9"
	local wt_created=0
	local wt_age_secs=0
	local commits_ahead=0
	local dirty_count=0
	local age_grace="${ORPHAN_WORKTREE_GRACE_SECS:-1800}"

	[[ -d "$wt_path_age" ]] || return 1
	wt_created=$(_worktree_creation_epoch "$wt_path_age" "$wt_branch_age")
	[[ "$wt_created" -gt 0 ]] || return 1
	wt_age_secs=$((now_epoch - wt_created))
	[[ "$wt_age_secs" -ge "$age_grace" ]] || return 1
	commits_ahead=$(_pc_commits_ahead_from_default "$rp_age" "$wt_path_age" "$main_branch") || return 1
	[[ "$commits_ahead" -eq 0 ]] || return 1
	dirty_count=$(git -C "$wt_path_age" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || return 1
	[[ "$dirty_count" -eq 0 ]] || return 1
	_pcdo_open_pr_absent_verified "$repo_slug_age" "$wt_branch_age" || return 1
	_pc_assert_no_uncommitted_work "$wt_path_age" "$wt_branch_age" "$dirty_count" \
		"$orphan_issue_num" "$wt_age_secs" "$repo_name_age" "$audit_context" || return 1
	return 0
}

_pcdo_fresh_cwd_state_allows_recovery() {
	local wt_path_age="$1"
	local guard_status=0

	if worktree_removal_guard "$wt_path_age" "$_WTAR_PC_CALLER" "degraded-cwd-orphan-recoverable"; then
		guard_status=0
	else
		guard_status=$?
	fi
	if [[ "$guard_status" -eq 0 || "$guard_status" -eq "${_WT_CWD_CAPTURE_DEGRADED_RC:-2}" ]]; then
		return 0
	fi
	return 1
}

_pc_remove_degraded_orphan_recoverably() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local now_epoch="$4"
	local repo_slug_age="$5"
	local main_branch="$6"
	local orphan_issue_num="$7"
	local repo_name_age="$8"
	local commits_ahead="$9"
	local dirty_count="${10}"
	local wt_age_secs="${11}"
	local reason="${12}"
	local audit_context=""

	[[ "$commits_ahead" -eq 0 && "$dirty_count" -eq 0 ]] || return 1
	[[ "$reason" == *"crashed worker"* ]] || return 1
	_pcdo_open_pr_absent_verified "$repo_slug_age" "$wt_branch_age" || return 1
	if ! _clean_acquire_removal_lease "$wt_path_age" "$wt_branch_age"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" \
			"cleanup-lease-skip" "skipped"
		return 1
	fi

	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" \
		"$commits_ahead" "$dirty_count" "$wt_age_secs" "none" "clear" "degraded" \
		"clear" "recoverable-trash")
	if _pcdo_post_lease_owner_or_claim_exists "$wt_path_age" "$wt_branch_age" ||
		! _pcdo_fresh_candidate_state_is_safe "$rp_age" "$wt_path_age" "$wt_branch_age" \
			"$now_epoch" "$repo_slug_age" "$main_branch" "$orphan_issue_num" \
			"$repo_name_age" "$audit_context" ||
		! _pcdo_fresh_cwd_state_allows_recovery "$wt_path_age"; then
		_pcdo_release_removal_lease "$wt_path_age"
		return 1
	fi

	if ! _clean_move_worktree_recoverably "$wt_path_age"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" \
			"recoverable-move-failed" "skipped" \
			"$audit_context recoverable_backends=${_WT_CLEAN_RECOVERABLE_FAILURE_DETAIL:-unknown}"
		_pcdo_release_removal_lease "$wt_path_age"
		return 1
	fi
	if ! prune_missing_worktree_metadata "$rp_age" "$wt_path_age"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" \
			"metadata-prune-failed" "partial-cleanup" "$audit_context"
		_pcdo_release_removal_lease "$wt_path_age"
		return 1
	fi

	unregister_worktree "$wt_path_age" 2>/dev/null || true
	log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$wt_path_age" \
		"degraded-cwd-orphan-recoverable" "recoverable-trash" "$audit_context"
	if declare -F full_loop_mark_cleanup_cleaned_for_worktree >/dev/null 2>&1; then
		full_loop_mark_cleanup_cleaned_for_worktree "$wt_path_age" || true
	fi
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): recoverably removed ${wt_branch_age:-detached} — $reason" >>"$LOGFILE"
	return 0
}
