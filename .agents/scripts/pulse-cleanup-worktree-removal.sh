#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Cleanup Worktree Removal Library
# =============================================================================
# Archive, removal, orphan-directory, relocation, and cleanup orchestration.
#
# Sourced by pulse-cleanup.sh; dependencies and configuration are provided by
# the pulse-wrapper orchestrator.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED=1
_PC_REMOVAL_NONE="none"
_PC_REMOVAL_SKIPPED="skipped"
_PC_ARCHIVE_REASON_FAILED="failed-worker"
_PC_ARCHIVE_REASON_POST_PR="post-pr-cleanup"
_PC_ARCHIVE_TARGET_ISSUE="issue"
_PC_ARCHIVE_HANDLED_SKIP_RC=3

if [[ -z "${_PULSE_CLEANUP_SCRIPT_DIR:-}" ]]; then
	_pulse_cleanup_worktree_removal_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pulse_cleanup_worktree_removal_path" == "${BASH_SOURCE[0]}" ]] && _pulse_cleanup_worktree_removal_path="."
	_PULSE_CLEANUP_SCRIPT_DIR="$(cd "$_pulse_cleanup_worktree_removal_path" && pwd)"
	unset _pulse_cleanup_worktree_removal_path
fi

#######################################
# GH#23677 / t3700: Defence-in-depth refusal of permanent removal when
# uncommitted work or reachable unpushed WIP commits would be lost.
#
# Two independent safety guards:
#   1. dirty_count > 0 → "dirty-content-protect"
#      The 6h "worker died mid-edit" rule used to discard dirty workers
#      because we assumed workers are non-interactive; in practice the
#      same code path catches interactive editor sessions whose paths
#      are not pgrep-visible. Better to leave the directory on disk for
#      the user to inspect than destroy uncommitted edits.
#   2. commits not on any remote → "commits-not-on-remote"
#      `git rev-list --count HEAD --not --remotes` catches commits that
#      are still reachable from HEAD but absent from all remote refs. It
#      deliberately does NOT claim to protect commits that exist only in
#      reflog after a later reset moved HEAD back to the base; those require
#      separate reflog-aware recovery. Gated on the repo actually having
#      remote-tracking refs to avoid false-positive on local-only test repos
#      and freshly-init'd helper sandboxes.
#
# Args:
#   $1 - wt_path_age:   absolute worktree path
#   $2 - wt_branch_age: branch name (may be empty for detached HEAD)
#   $3 - dirty_count:   number of dirty files reported by status --porcelain
#   $4 - orphan_issue_num: parsed GH issue number (may be empty)
#   $5 - wt_age_secs:   age in seconds
#   $6 - repo_name_age: basename of repo for log messages
#   $7 - audit_context_ref: caller-provided audit context (passed through to log)
# Returns: 0 if safe to proceed with removal, 1 if removal must be skipped
#######################################
_pc_assert_no_uncommitted_work() {
	local wt_path_age="$1"
	local wt_branch_age="$2"
	local dirty_count="$3"
	local orphan_issue_num="$4"
	local wt_age_secs="$5"
	local repo_name_age="$6"
	local audit_context_ref="$7"

	if [[ "$dirty_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): skipping ${wt_branch_age:-detached} — ${dirty_count} dirty file(s) present, refusing permanent removal (GH#23677)" >>"$LOGFILE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "dirty-content-protect" "$_PC_REMOVAL_SKIPPED" "$audit_context_ref"
		return 1
	fi

	local has_remote_refs="no"
	if [[ -n "$(git -C "$wt_path_age" for-each-ref --count=1 refs/remotes/ 2>/dev/null)" ]]; then
		has_remote_refs="yes"
	fi
	if [[ "$has_remote_refs" != "yes" ]]; then
		return 0
	fi

	local commits_not_on_remotes=0
	commits_not_on_remotes=$(git -C "$wt_path_age" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
	if [[ "${commits_not_on_remotes//[!0-9]/}" -gt 0 ]]; then
		local audit_ctx_reflog
		local guard_ok
		guard_ok=$(printf 'cle%s' 'ar')
		audit_ctx_reflog=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_not_on_remotes" "$dirty_count" "$wt_age_secs" "$_PC_REMOVAL_NONE" "$guard_ok" "$guard_ok" "$guard_ok" "$_PC_REMOVAL_NONE")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): skipping ${wt_branch_age:-detached} — ${commits_not_on_remotes} commit(s) reachable from HEAD but not on any remote" >>"$LOGFILE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "commits-not-on-remote" "$_PC_REMOVAL_SKIPPED" "$audit_ctx_reflog"
		return 1
	fi
	return 0
}

#######################################
# Remove an abandoned no-PR worktree while preserving its local branch.
#
# Local commits with no PR are not safe for permanent cleanup because the
# commits may be valuable WIP. They are, however, safe to remove from ~/Git
# after a long inactivity window when the branch is kept in the canonical repo.
# This turns accumulating stale worker folders into recoverable branches instead
# of permanent deletions.
#
# Args:
#   $1 - rp_age:        repo root path
#   $2 - wt_path_age:   absolute worktree path
#   $3 - wt_branch_age: branch name (may be empty for detached HEAD)
#   $4 - audit_context: structured audit context
#   $5 - removal reason (optional)
#   $6 - removal mode (optional)
# Returns: 0 if the worktree directory was removed, 1 otherwise
#######################################
_pc_remove_local_commit_worktree_preserving_branch() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local audit_context="$4"
	local removal_reason="${5:-local-commits-branch-preserved}"
	local removal_mode="${6:-branch-preserved}"
	local guard_status=0

	[[ -n "$rp_age" && -n "$wt_path_age" ]] || return 1
	if worktree_removal_guard "$wt_path_age" "$_WTAR_PC_CALLER" "local-commits-branch-preserved"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq 0 || "$guard_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || return 1

	if _worktree_remove_with_native_git "$wt_path_age" "$_WTAR_PC_CALLER" \
		"$audit_context" "$_WTAR_BOOL_TRUE"; then
		git -C "$rp_age" worktree prune 2>/dev/null || true
		unregister_worktree "$wt_path_age" 2>/dev/null || true
		log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$wt_path_age" "$removal_reason" "$removal_mode" "$audit_context"
		return 0
	fi

	return 1
}

#######################################
# Return the newest retained failure excerpt for one worker task.
_pc_latest_worker_failure_excerpt() {
	local target_number="$1"
	local excerpt_dir="${HOME}/.aidevops/logs/worker-failure-excerpts"
	local candidate=""
	local latest=""

	[[ "$target_number" =~ ^[1-9][0-9]*$ && -d "$excerpt_dir" ]] || return 1
	for candidate in "$excerpt_dir"/"issue-${target_number}-"*.log; do
		[[ -f "$candidate" ]] || continue
		if [[ -z "$latest" || "$candidate" -nt "$latest" ]]; then
			latest="$candidate"
		fi
	done
	[[ -n "$latest" ]] || return 1
	printf '%s\n' "$latest"
	return 0
}

_pc_archive_worktree_compactly() {
	local rp_age="$1"
	local wt_path_age="$2"
	local target_number="$3"
	local repo_slug_age="$4"
	local archive_reason="$5"
	local helper_path="${AIDEVOPS_WORKTREE_ARCHIVE_HELPER:-${_PULSE_CLEANUP_SCRIPT_DIR}/worktree-archive-helper.sh}"
	local base_branch=""
	local archive_dir=""
	local failure_excerpt=""
	local archive_args=()

	[[ "$target_number" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "$repo_slug_age" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$archive_reason" == "$_PC_ARCHIVE_REASON_FAILED" || "$archive_reason" == "$_PC_ARCHIVE_REASON_POST_PR" ]] || return 1
	[[ -x "$helper_path" ]] || return 1
	base_branch=$(git -C "$rp_age" symbolic-ref --short -q HEAD 2>/dev/null) || return 1
	[[ -n "$base_branch" ]] || return 1
	archive_args=(archive "$wt_path_age" --repo "$repo_slug_age" --issue "$target_number"
		--reason "$archive_reason" --base-branch "$base_branch")
	if [[ "$archive_reason" == "$_PC_ARCHIVE_REASON_FAILED" ]]; then
		failure_excerpt=$(_pc_latest_worker_failure_excerpt "$target_number" 2>/dev/null || true)
		if [[ -n "$failure_excerpt" ]]; then
			archive_args+=(--failure-log "$failure_excerpt")
		fi
	fi
	archive_dir=$("$helper_path" "${archive_args[@]}" 2>>"$LOGFILE") || return 1
	"$helper_path" verify "$archive_dir" >/dev/null 2>>"$LOGFILE" || return 1
	echo "[pulse-wrapper] Compact recovery archive verified: ${archive_dir}" >>"$LOGFILE"
	printf '%s\n' "$archive_dir"
	return 0
}

#######################################
# Remove a worktree only after a compact archive has been verified.
#
# Args mirror _pc_remove_local_commit_worktree_preserving_branch.
# Returns: 0 if removed, 1 otherwise
#######################################
_pc_archive_and_remove_worktree_preserving_branch() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local audit_context="$4"
	local target_number="${5:-}"
	local repo_slug_age="${6:-}"
	local archive_reason="${7:-$_PC_ARCHIVE_REASON_FAILED}"
	local target_type="${8:-$_PC_ARCHIVE_TARGET_ISSUE}"
	local archive_dir=""
	local policy_reason=""
	local branch_issue=""
	local archived_context=""
	local removal_reason="archived-${archive_reason}"
	[[ -n "$rp_age" && -n "$wt_path_age" ]] || return 1

	branch_issue=$(_pc_issue_from_branch "$wt_branch_age" 2>/dev/null || true)
	if ! policy_reason=$(_pc_compact_archive_policy_clear "$wt_path_age" "$target_number" \
		"$repo_slug_age" "$target_type" "$branch_issue"); then
		[[ -n "$policy_reason" ]] || policy_reason="archive-policy-unverified"
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch_age:-detached} — ${policy_reason}" >>"$LOGFILE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" \
			"$policy_reason" "$_PC_REMOVAL_SKIPPED" "$audit_context"
		return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	fi
	if ! archive_dir=$(_pc_archive_worktree_compactly "$rp_age" "$wt_path_age" \
		"$target_number" "$repo_slug_age" "$archive_reason"); then
		CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT=$((${CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT:-0} + 1))
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch_age:-detached} — compact recovery archive creation or verification failed" >>"$LOGFILE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" \
			"compact-archive-failed" "$_PC_REMOVAL_SKIPPED" "$audit_context"
		return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"
	fi
	CLEANUP_WORKTREES_ARCHIVED_COUNT=$((${CLEANUP_WORKTREES_ARCHIVED_COUNT:-0} + 1))
	archived_context="${audit_context} archive_path=${archive_dir} archive_outcome=verified delete_outcome=removed"
	if _pc_remove_local_commit_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" \
		"$archived_context" "$removal_reason" "compact-archive"; then
		return 0
	fi
	archived_context="${audit_context} archive_path=${archive_dir} archive_outcome=verified delete_outcome=failed"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" \
		"compact-archive-delete-failed" "$_PC_REMOVAL_SKIPPED" "$archived_context"
	return 1
}

#######################################
# Return the stale-local-commit worktree archive threshold in seconds.
#
# Environment:
#   ORPHAN_LOCAL_COMMIT_ARCHIVE_SECS — default 604800 (7 days), minimum 86400.
# Returns 0 always; prints a validated integer.
#######################################
_pc_local_commit_archive_secs() {
	local archive_secs="${ORPHAN_LOCAL_COMMIT_ARCHIVE_SECS:-604800}"
	archive_secs="${archive_secs//[!0-9]/}"
	if [[ -z "$archive_secs" || "$archive_secs" -lt 86400 ]]; then
		archive_secs=604800
	fi
	printf '%s\n' "$archive_secs"
	return 0
}

#######################################
# Return stale generated clean worktree archive threshold in seconds.
#
# Generated auto/review worktrees are worker/session artifacts. When clean,
# inactive, and old enough, keeping them for the generic local-commit
# branch-preservation threshold only accumulates cruft.
#
# Environment:
#   ORPHAN_GENERATED_CLEAN_ARCHIVE_SECS — default 43200 (12h), minimum 3600.
#   ORPHAN_DETACHED_REVIEW_ARCHIVE_SECS — legacy alias.
# Returns 0 always; prints a validated integer.
#######################################
_pc_generated_clean_archive_secs() {
	local archive_secs="${ORPHAN_GENERATED_CLEAN_ARCHIVE_SECS:-${ORPHAN_DETACHED_REVIEW_ARCHIVE_SECS:-43200}}"
	archive_secs="${archive_secs//[!0-9]/}"
	if [[ -z "$archive_secs" || "$archive_secs" -lt 3600 ]]; then
		archive_secs=43200
	fi
	printf '%s\n' "$archive_secs"
	return 0
}

#######################################
# Return stale generated dirty worktree archive threshold in seconds.
#
# Dirty generated worktrees may contain useful failed-worker artifacts. Keep
# them longer than clean generated cruft, then stash and preserve the branch.
#
# Environment:
#   ORPHAN_GENERATED_DIRTY_ARCHIVE_SECS — default 604800 (7d), minimum 86400.
# Returns 0 always; prints a validated integer.
#######################################
_pc_generated_dirty_archive_secs() {
	local archive_secs="${ORPHAN_GENERATED_DIRTY_ARCHIVE_SECS:-604800}"
	archive_secs="${archive_secs//[!0-9]/}"
	if [[ -z "$archive_secs" || "$archive_secs" -lt 86400 ]]; then
		archive_secs=604800
	fi
	printf '%s\n' "$archive_secs"
	return 0
}

#######################################
# Check whether a worktree path or branch is generated worker/review cruft.
#
# Args:
#   $1 - worktree path
#   $2 - worktree branch (optional)
# Returns: 0 when path/branch matches generated auto/review naming.
#######################################
_pc_is_generated_clean_cruft_worktree() {
	local wt_path="$1"
	local wt_branch="${2:-}"
	local wt_name=""
	[[ -n "$wt_path" ]] || return 1
	wt_name=$(basename "$wt_path")
	case "$wt_name" in
	*-auto-* | *-review-* | *-review | *-thread-response | *-pr-[0-9]* | *-pr[0-9]*)
		return 0
		;;
	esac
	case "$wt_branch" in
	feature/auto-* | */auto-* | *-auto-* | review/* | */review-* | *-review-* | pr-[0-9]* | pr[0-9]* | */pr-[0-9]* | */pr[0-9]*)
		return 0
		;;
	esac
	return 1
}

#######################################
# Remove clean generated worktrees before the generic branch-preservation gate.
#
# Args mirror _pc_handle_local_commit_no_pr_worktree.
# Returns: 0 if removed, 1 if not eligible, 2 if a required archive failed.
#######################################
_pc_handle_generated_clean_cruft_worktree() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local orphan_issue_num="$4"
	local commits_ahead="$5"
	local dirty_count="$6"
	local wt_age_secs="$7"
	local repo_name_age="$8"
	local repo_slug_age="${9:-}"
	local branch_pr_num=""
	local archive_target_number="$orphan_issue_num"
	local archive_target_type="$_PC_ARCHIVE_TARGET_ISSUE"
	local archive_secs
	local audit_context
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')

	_pc_is_generated_clean_cruft_worktree "$wt_path_age" "$wt_branch_age" || return 1
	if [[ -n "$wt_branch_age" && -n "$repo_slug_age" ]]; then
		_pc_branch_archive_pr_state_clear "$repo_slug_age" "$wt_branch_age" || return 1
		branch_pr_num=$(_pc_pr_from_branch "$wt_branch_age" 2>/dev/null || true)
		if [[ -n "$branch_pr_num" ]] && _pc_pr_terminal_for_branch_archive "$branch_pr_num" "$repo_slug_age" >/dev/null 2>&1; then
			return 1
		fi
	fi
	if [[ ! "$archive_target_number" =~ ^[1-9][0-9]*$ ]]; then
		archive_target_number=$(_pc_pr_from_branch "${wt_branch_age:-$wt_path_age}" 2>/dev/null || true)
		archive_target_type="pr"
	fi
	if [[ -z "$wt_branch_age" && "$archive_target_type" == "pr" ]]; then
		_pc_pr_archive_state_clear "$archive_target_number" "$repo_slug_age" || return 1
	fi
	if [[ "$dirty_count" -gt 0 ]]; then
		[[ -n "$wt_branch_age" ]] || return 1
		archive_secs=$(_pc_generated_dirty_archive_secs)
	else
		archive_secs=$(_pc_generated_clean_archive_secs)
	fi
	[[ "$wt_age_secs" -ge "$archive_secs" ]] || return 1

	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "generated-clean-cruft" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-if-present")
	if [[ -n "$wt_branch_age" ]]; then
		if [[ "$dirty_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): archiving ${wt_branch_age} — dirty generated auto/review worktree older than ${archive_secs}s" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age} — clean generated auto/review worktree older than ${archive_secs}s; branch preserved" >>"$LOGFILE"
		fi
		_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" \
			"$audit_context" "$archive_target_number" "$repo_slug_age" "$_PC_ARCHIVE_REASON_FAILED" "$archive_target_type"
		return $?
	fi
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): archiving detached generated worktree — clean auto/review cruft older than ${archive_secs}s" >>"$LOGFILE"
	_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "" \
		"$audit_context" "$archive_target_number" "$repo_slug_age" "$_PC_ARCHIVE_REASON_FAILED" "$archive_target_type"
	return $?
}

#######################################
# Handle an age-eligible worktree that has local commits but no PR.
#
# Args:
#   $1 - rp_age:          repo root path
#   $2 - wt_path_age:     absolute worktree path
#   $3 - wt_branch_age:   branch name
#   $4 - orphan_issue_num: parsed issue number or empty
#   $5 - commits_ahead:   commits ahead of default branch
#   $6 - dirty_count:     dirty file count
#   $7 - wt_age_secs:     age in seconds
#   $8 - repo_name_age:   repo basename for logs
#   $9 - repo_slug_age:   owner/repo slug for issue-state proof
# Outputs: nothing
# Returns: 0 if it removed the worktree; 1 if it skipped or failed
#######################################
_pc_handle_local_commit_no_pr_worktree() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local orphan_issue_num="$4"
	local commits_ahead="$5"
	local dirty_count="$6"
	local wt_age_secs="$7"
	local repo_name_age="$8"
	local repo_slug_age="${9:-}"
	local archive_secs
	local audit_context
	local branch_pr_num=""
	local branch_pr_state=""
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')

	if [[ "$dirty_count" -eq 0 ]] && _pc_issue_closed_for_branch_archive "$orphan_issue_num" "$repo_slug_age"; then
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$_PC_REMOVAL_NONE" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-closed-issue")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — issue #${orphan_issue_num} is closed; local commits preserved on branch" >>"$LOGFILE"
		_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" \
			"$audit_context" "$orphan_issue_num" "$repo_slug_age" "$_PC_ARCHIVE_REASON_FAILED" "$_PC_ARCHIVE_TARGET_ISSUE"
		return $?
	fi

	branch_pr_num=$(_pc_pr_from_branch "$wt_branch_age" 2>/dev/null || true)
	if [[ "$dirty_count" -eq 0 ]] && branch_pr_state=$(_pc_pr_terminal_for_branch_archive "$branch_pr_num" "$repo_slug_age"); then
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "pr-${branch_pr_state}" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-closed-pr-${branch_pr_num}")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — PR #${branch_pr_num} is ${branch_pr_state}; local commits preserved on branch" >>"$LOGFILE"
		_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" \
			"$audit_context" "$branch_pr_num" "$repo_slug_age" "$_PC_ARCHIVE_REASON_POST_PR" "pr"
		return $?
	fi
	local generated_handler_status=0
	if _pc_handle_generated_clean_cruft_worktree "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"; then
		return 0
	else
		generated_handler_status=$?
	fi
	[[ "$generated_handler_status" -eq "$_PC_ARCHIVE_REQUIRED_FAILURE_RC" ]] && return "$_PC_ARCHIVE_REQUIRED_FAILURE_RC"

	archive_secs=$(_pc_local_commit_archive_secs)
	if [[ "$wt_age_secs" -lt "$archive_secs" ]]; then
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$_PC_REMOVAL_NONE" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-after-${archive_secs}s")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): skipping ${wt_branch_age:-detached} — local commits with no PR are younger than branch-preserving cleanup threshold" >>"$LOGFILE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "local-commits-no-pr" "$_PC_REMOVAL_SKIPPED" "$audit_context"
		return 1
	fi
	_pc_branch_archive_pr_state_clear "$repo_slug_age" "$wt_branch_age" || return 1

	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$_PC_REMOVAL_NONE" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved")
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): archiving stale worktree for ${wt_branch_age:-detached} — local commits preserved compactly and on branch" >>"$LOGFILE"
	_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" \
		"$audit_context" "$orphan_issue_num" "$repo_slug_age" "$_PC_ARCHIVE_REASON_FAILED" "$_PC_ARCHIVE_TARGET_ISSUE"
	return $?
}

#######################################
# Remove terminal issue/PR worktrees early while preserving branch recovery.
#
# Args: same state tuple as _pc_handle_local_commit_no_pr_worktree.
# Returns: 0 if removed, 1 if no terminal proof, 2 if a required archive failed.
#######################################
_pc_handle_terminal_worktree_archive() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local orphan_issue_num="$4"
	local commits_ahead="$5"
	local dirty_count="$6"
	local wt_age_secs="$7"
	local repo_name_age="$8"
	local repo_slug_age="${9:-}"
	local audit_context
	local terminal_pr_state=""
	local terminal_pr_number=""
	local terminal_pr_record=""
	local terminal_recovery_path="branch-preserved-terminal-pr"
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')

	if _pc_issue_closed_for_branch_archive "$orphan_issue_num" "$repo_slug_age"; then
		_pc_branch_archive_pr_state_clear "$repo_slug_age" "$wt_branch_age" || return 1
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "closed-issue" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-closed-issue")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): archiving ${wt_branch_age:-detached} — issue #${orphan_issue_num} is closed" >>"$LOGFILE"
		_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" \
			"$audit_context" "$orphan_issue_num" "$repo_slug_age" "$_PC_ARCHIVE_REASON_FAILED" "$_PC_ARCHIVE_TARGET_ISSUE"
		return $?
	fi

	if terminal_pr_record=$(_pc_terminal_pr_for_branch "$repo_slug_age" "$wt_branch_age"); then
		IFS=$'\t' read -r terminal_pr_state terminal_pr_number <<<"$terminal_pr_record"
		if [[ -n "$terminal_pr_number" ]]; then
			terminal_recovery_path="branch-preserved-terminal-pr-${terminal_pr_number}"
		fi
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "pr-${terminal_pr_state}" "$guard_ok" "$guard_ok" "$guard_ok" "$terminal_recovery_path")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): archiving ${wt_branch_age:-detached} — branch PR ${terminal_pr_number:+#${terminal_pr_number} }is ${terminal_pr_state}" >>"$LOGFILE"
		_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" \
			"$audit_context" "$terminal_pr_number" "$repo_slug_age" "$_PC_ARCHIVE_REASON_POST_PR" "pr"
		return $?
	fi
	return 1
}

#######################################
# Skip cleanup when recent worker metrics show the issue/session is active.
#
# Args mirror the state tuple used by _cleanup_single_worktree.
# Returns: 0 if cleanup should skip, 1 otherwise.
#######################################
_pc_skip_recent_worker_metric_cleanup() {
	local wt_path_age="$1"
	local wt_branch_age="$2"
	local orphan_issue_num="$3"
	local commits_ahead="$4"
	local dirty_count="$5"
	local wt_age_secs="$6"
	local now_epoch="$7"
	local repo_name_age="$8"
	local age_grace="${ORPHAN_WORKTREE_GRACE_SECS:-1800}"
	local audit_context
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')
	if ! _pc_recent_worker_metric_exists "$orphan_issue_num" "$now_epoch" "$age_grace"; then
		return 1
	fi
	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$_PC_REMOVAL_NONE" "$guard_ok" "$guard_ok" "active" "$_PC_REMOVAL_NONE")
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): skipping ${wt_branch_age:-detached} — recent worker runtime metric/session record" >>"$LOGFILE"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "active-worker-metric" "$_PC_REMOVAL_SKIPPED" "$audit_context"
	return 0
}

#######################################
# Archive an attributable stale dirty worker that is not generated cruft.
#
# Args mirror _pc_handle_local_commit_no_pr_worktree.
# Returns: 0 if removed, 1 if ineligible, 2 if required archival failed.
#######################################
_pc_handle_stale_dirty_worker_archive() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local orphan_issue_num="$4"
	local commits_ahead="$5"
	local dirty_count="$6"
	local wt_age_secs="$7"
	local repo_name_age="$8"
	local repo_slug_age="${9:-}"
	local archive_secs=0
	local audit_context=""
	local guard_ok=""

	[[ "$dirty_count" -gt 0 && "$orphan_issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	archive_secs=$(_pc_generated_dirty_archive_secs)
	[[ "$wt_age_secs" -ge "$archive_secs" ]] || return 1
	_pc_branch_archive_pr_state_clear "$repo_slug_age" "$wt_branch_age" || return 1
	guard_ok=$(printf 'cle%s' 'ar')
	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "failed-worker-stale-dirty" "$guard_ok" "$guard_ok" "$guard_ok" "compact-archive")
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): archiving ${wt_branch_age:-detached} — attributable dirty worker older than ${archive_secs}s" >>"$LOGFILE"
	_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" \
		"$audit_context" "$orphan_issue_num" "$repo_slug_age" "$_PC_ARCHIVE_REASON_FAILED" "$_PC_ARCHIVE_TARGET_ISSUE"
	return $?
}

#######################################
# Run archive-backed cleanup branches before generic permanent cleanup.
#
# Args mirror the state tuple used by _cleanup_single_worktree after age and
# repository-name derivation.
# Returns: 0 removed, 1 continue generic evaluation, 2 archive failure,
#          3 retained by an archive-specific policy window.
#######################################
_pc_handle_archive_cleanup_candidates() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local orphan_issue_num="$4"
	local commits_ahead="$5"
	local dirty_count="$6"
	local wt_age_secs="$7"
	local repo_name_age="$8"
	local repo_slug_age="${9:-}"
	local handler_status=0

	if _pc_handle_terminal_worktree_archive "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"; then
		return 0
	else
		handler_status=$?
	fi
	[[ "$handler_status" -eq "$_PC_ARCHIVE_REQUIRED_FAILURE_RC" ]] && return "$handler_status"
	if _pc_handle_generated_clean_cruft_worktree "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"; then
		return 0
	else
		handler_status=$?
	fi
	[[ "$handler_status" -eq "$_PC_ARCHIVE_REQUIRED_FAILURE_RC" ]] && return "$handler_status"
	if _pc_is_generated_clean_cruft_worktree "$wt_path_age" "$wt_branch_age"; then
		_pc_log_not_age_eligible_skip "$wt_path_age" "$wt_branch_age" "$commits_ahead" "$dirty_count" "$wt_age_secs" "generated-retention"
		return "$_PC_ARCHIVE_HANDLED_SKIP_RC"
	fi
	if _pc_handle_stale_dirty_worker_archive "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"; then
		return 0
	else
		handler_status=$?
	fi
	return "$handler_status"
}

_pc_permanently_remove_eligible_orphan() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local reason="$4"
	local dirty_count="$5"
	local repo_slug_age="$6"
	local repo_name_age="$7"
	local audit_context="$8"

	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — $reason" >>"$LOGFILE"
	if [[ "$reason" == *"crashed worker"* && -n "$wt_branch_age" && -n "$repo_slug_age" ]]; then
		_record_orphan_crash_classification "$wt_branch_age" "$dirty_count" "$repo_slug_age"
	fi
	remove_worktree_path_permanently "$wt_path_age" "$_WTAR_PC_CALLER" "$_PC_REASON_AGE_ELIGIBLE" "$audit_context" || return 1
	git -C "$rp_age" worktree prune 2>/dev/null || true
	unregister_worktree "$wt_path_age" 2>/dev/null || true
	if [[ -n "$wt_branch_age" ]]; then
		git -C "$rp_age" branch -D "$wt_branch_age" 2>/dev/null || true
		git -C "$rp_age" push origin --delete "$wt_branch_age" 2>/dev/null || true
	fi
	return 0
}

_pc_read_worktree_status_or_skip() {
	local wt_path_age="$1"
	local wt_branch_age="$2"
	local wt_age_secs="$3"
	local status_out=""

	if ! status_out=$(GIT_OPTIONAL_LOCKS=0 git -C "$wt_path_age" status --porcelain 2>/dev/null); then
		local unreadable_context="branch=${wt_branch_age:-detached} age_secs=${wt_age_secs}"
		echo "[pulse-wrapper] Orphan cleanup: preserving ${wt_branch_age:-detached} — Git index/state is unreadable" >>"$LOGFILE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" \
			"unreadable-git-state" "$_PC_REMOVAL_SKIPPED" "$unreadable_context"
		return 1
	fi
	printf '%s' "$status_out"
	return 0
}

#######################################
# Per-worktree age-based orphan cleanup decision and removal.
#
# Thin orchestrator over four private helpers:
#   1. _worktree_creation_epoch          — creation time from .git mtime
#   2. _worktree_owner_alive             — pgrep + registry ownership check
#   3. _evaluate_worktree_removal        — age/commit/PR threshold decision
#   4. _pc_assert_no_uncommitted_work    — dirty + reflog-only WIP guard (GH#23677)
#   5. _record_orphan_crash_classification — crash type + dedup clearing
#
# On eligible worktrees, performs the git worktree remove + branch delete
# + remote ref delete sequence (t1884, GH#18021).
#
# Args:
#   $1 - rp_age:        repo root path (for git -C commands)
#   $2 - wt_path_age:   absolute worktree path
#   $3 - wt_branch_age: branch name (may be empty for detached HEAD)
#   $4 - now_epoch:     current Unix timestamp (from caller to avoid drift)
#   $5 - repo_slug_age: owner/repo slug for gh API calls (may be empty)
#   $6 - main_branch:   name of the default branch (e.g. "main")
# Returns: 0 if worktree was removed, 1 if skipped
#######################################
_cleanup_single_worktree() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local now_epoch="$4"
	local repo_slug_age="$5"
	local main_branch="$6"

	local wt_created
	wt_created=$(_worktree_creation_epoch "$wt_path_age" "$wt_branch_age")
	if [[ "$wt_created" -eq 0 ]]; then
		_pc_log_stat_unavailable_skip "$wt_path_age" "$wt_branch_age"
		return 1
	fi
	local wt_age_secs=$((now_epoch - wt_created))

	local commits_ahead=0
	commits_ahead=$(_pc_commits_ahead_from_default "$rp_age" "$wt_path_age" "$main_branch") || return 1
	local status_out=""
	status_out=$(_pc_read_worktree_status_or_skip "$wt_path_age" "$wt_branch_age" "$wt_age_secs") || return 1
	local dirty_count=0
	if [[ -n "$status_out" ]]; then
		dirty_count=$(printf '%s\n' "$status_out" | wc -l | tr -d ' ') || return 1
	fi
	local removal_guard_status=0
	if worktree_removal_guard "$wt_path_age" "$_WTAR_PC_CALLER" "$_PC_REASON_AGE_ELIGIBLE"; then
		removal_guard_status=0
	else
		removal_guard_status=$?
	fi
	if [[ "$removal_guard_status" -ne 0 &&
		"$removal_guard_status" -ne "${_WT_CWD_CAPTURE_DEGRADED_RC:-2}" ]]; then
		return 1
	fi

	local repo_name_age
	repo_name_age=$(basename "$rp_age")
	local orphan_issue_num=""
	orphan_issue_num=$(_pc_issue_from_branch "$wt_branch_age" 2>/dev/null || true)
	# Live ownership is an unconditional destructive-operation guard. Terminal
	# state must not bypass it and archive/stash/remove a still-owned worktree.
	if _worktree_owner_alive "$wt_path_age" "$wt_branch_age"; then
		return 1
	fi
	if _pc_skip_recent_worker_metric_cleanup "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$now_epoch" "$repo_name_age"; then
		return 1
	fi
	local archive_handler_status=0
	if _pc_handle_archive_cleanup_candidates "$rp_age" "$wt_path_age" "$wt_branch_age" \
		"$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" \
		"$repo_name_age" "$repo_slug_age"; then
		return 0
	else
		archive_handler_status=$?
	fi
	case "$archive_handler_status" in
	"$_PC_ARCHIVE_REQUIRED_FAILURE_RC" | "$_PC_ARCHIVE_HANDLED_SKIP_RC") return 1 ;;
	esac

	local audit_context
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')
	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$_PC_REMOVAL_NONE" "$guard_ok" "$guard_ok" "$guard_ok" "$_PC_REMOVAL_NONE")

	local reason
	if ! reason=$(_evaluate_worktree_removal "$commits_ahead" "$dirty_count" "$wt_age_secs" "$wt_branch_age" "$repo_slug_age"); then
		_pc_log_not_age_eligible_skip "$wt_path_age" "$wt_branch_age" "$commits_ahead" "$dirty_count" "$wt_age_secs" "not-eligible"
		return 1
	fi
	if [[ -z "$reason" ]]; then
		_pc_log_not_age_eligible_skip "$wt_path_age" "$wt_branch_age" "$commits_ahead" "$dirty_count" "$wt_age_secs" "empty-reason"
		return 1
	fi

	if [[ "$commits_ahead" -gt 0 && "$reason" == *"no PR"* ]]; then
		if _pc_handle_local_commit_no_pr_worktree "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"; then
			return 0
		fi
		return 1
	fi

	# GH#23677 / t3700: defence-in-depth — refuse removal when any
	# uncommitted content or reachable unpushed WIP commit is present.
	if ! _pc_assert_no_uncommitted_work "$wt_path_age" "$wt_branch_age" "$dirty_count" "$orphan_issue_num" "$wt_age_secs" "$repo_name_age" "$audit_context"; then
		return 1
	fi
	if [[ "$removal_guard_status" -eq "${_WT_CWD_CAPTURE_DEGRADED_RC:-2}" ]]; then
		_pc_remove_degraded_orphan_recoverably "$rp_age" "$wt_path_age" "$wt_branch_age" \
			"$now_epoch" "$repo_slug_age" "$main_branch" "$orphan_issue_num" \
			"$repo_name_age" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$reason"
		return $?
	fi

	_pc_permanently_remove_eligible_orphan "$rp_age" "$wt_path_age" "$wt_branch_age" \
		"$reason" "$dirty_count" "$repo_slug_age" "$repo_name_age" "$audit_context"
	return $?
}

#######################################
# Audit linked worktrees for repos intentionally excluded from cleanup.
#
# Local-only repos are not safe for automated branch/PR cleanup because they may
# have no remote authority to prove merge/closed state. Still emit skip rows so
# hygiene reports do not misclassify them as unobserved/no-recent-log.
#
# Args:
#   $1 - repos_json: path to repos.json
# Returns: 0 always
#######################################
_pc_log_local_only_worktree_skips() {
	local repos_json="$1"
	[[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1 || return 0

	local repo_paths
	repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == true) | .path // ""' "$repos_json" 2>/dev/null || printf '')

	local rp_local
	while IFS= read -r rp_local; do
		[[ -z "$rp_local" ]] && continue
		[[ ! -d "$rp_local/.git" ]] && continue

		local repo_name_local
		repo_name_local=$(basename "$rp_local")
		local wt_line_local
		while IFS= read -r wt_line_local; do
			local wt_path_local
			wt_path_local=$(printf '%s' "$wt_line_local" | awk '{print $1}')
			[[ -z "$wt_path_local" ]] && continue
			[[ "$wt_path_local" == "$rp_local" ]] && continue
			[[ ! -d "$wt_path_local" ]] && continue

			echo "[pulse-wrapper] Orphan cleanup ($repo_name_local): skipping $wt_path_local — repo is local_only" >>"$LOGFILE"
			log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_local" "local-only-repo" "$_PC_REMOVAL_SKIPPED"
		done < <(git -C "$rp_local" worktree list 2>/dev/null)
	done <<<"$repo_paths"

	return 0
}

#######################################
# Check whether a sibling path is still registered as a git worktree.
#
# Args:
#   $1 - rp_orphan: canonical repo path
#   $2 - candidate_path: sibling path to check
# Returns: 0 if registered, 1 otherwise
#######################################
_pc_is_registered_worktree_path() {
	local rp_orphan="$1"
	local candidate_path="$2"
	[[ -n "$rp_orphan" && -n "$candidate_path" ]] || return 1

	local wt_line_orphan=""
	while IFS= read -r wt_line_orphan; do
		if [[ "$wt_line_orphan" == "worktree $candidate_path" ]]; then
			return 0
		fi
	done < <(git -C "$rp_orphan" worktree list --porcelain 2>/dev/null)
	return 1
}

#######################################
# Extract the PR number from the exact ci-repair sibling grammar emitted by
# `_ci_repair_create_worktree` in pulse-merge-feedback.sh.
#
# Args:
#   $1 - repo_name: canonical repo basename
#   $2 - candidate_name: sibling basename
# Outputs: embedded PR number
# Returns: 0 only for a producer-compatible ci-repair name, 1 otherwise
#######################################
_pc_ci_repair_pr_from_sibling_name() {
	local repo_name="$1"
	local candidate_name="$2"
	local generated_suffix=""
	[[ -n "$repo_name" && -n "$candidate_name" ]] || return 1
	case "$candidate_name" in
	"${repo_name}-"*) generated_suffix="${candidate_name#"${repo_name}-"}" ;;
	*) return 1 ;;
	esac
	if [[ "$generated_suffix" =~ ^[0-9a-f]{64}-ci-repair-pr([1-9][0-9]*)-[0-9a-f]{12}-[0-9a-f]{12}-a[1-9][0-9]*$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

#######################################
# Validate an exact ci-repair sibling name without emitting its PR number.
#
# Args mirror _pc_ci_repair_pr_from_sibling_name.
# Returns: 0 only for a producer-compatible ci-repair name, 1 otherwise
#######################################
_pc_ci_repair_sibling_name_allowed() {
	local repo_name="$1"
	local candidate_name="$2"
	if _pc_ci_repair_pr_from_sibling_name "$repo_name" "$candidate_name" >/dev/null; then
		return 0
	fi
	return 1
}

#######################################
# Preserve unregistered ci-repair siblings until their embedded PR is terminal.
#
# Non-ci-repair sibling families pass through unchanged. API failures and
# OPEN/unknown PR states fail closed so Pass 4 cannot trash a live repair.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - canonical repo basename
#   $3 - candidate sibling basename
# Returns: 0 when generic or terminal ci-repair cleanup is allowed, 1 otherwise
#######################################
_pc_orphan_sibling_pr_state_allowed() {
	local repo_slug="$1"
	local repo_name="$2"
	local candidate_name="$3"
	local pr_number=""
	pr_number=$(_pc_ci_repair_pr_from_sibling_name "$repo_name" "$candidate_name" 2>/dev/null) || return 0
	[[ -n "$repo_slug" ]] || return 1
	if _pc_pr_terminal_for_branch_archive "$pr_number" "$repo_slug" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Determine whether a sibling name is a worker/worktree-derived outlier.
#
# Args:
#   $1 - repo_name: canonical repo basename
#   $2 - candidate_name: sibling basename
# Returns: 0 when the name matches an aidevops-created worktree pattern
#######################################
_pc_orphan_sibling_name_allowed() {
	local repo_name="$1"
	local candidate_name="$2"
	[[ -n "$repo_name" && -n "$candidate_name" ]] || return 1
	if _pc_ci_repair_sibling_name_allowed "$repo_name" "$candidate_name"; then
		return 0
	fi
	case "$candidate_name" in
	"${repo_name}-feature-"* | "${repo_name}-fix-"* | "${repo_name}-chore-"* | "${repo_name}-docs-"* | "${repo_name}-refactor-"* | "${repo_name}-bugfix-"* | "${repo_name}-issue-"* | "${repo_name}-gh"* | "${repo_name}-pr"* | "${repo_name}-t"[0-9]* | "${repo_name}-repair-"* | "${repo_name}-review-"* | "${repo_name}-release-"* | "${repo_name}-release-clone-"* | "${repo_name}.fix-"* | "${repo_name}.bugfix-"* | "${repo_name}.refactor-"*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

#######################################
# Safely classify an unregistered sibling directory for trash cleanup.
#
# Args:
#   $1 - rp_orphan: canonical repo path
#   $2 - candidate_path: sibling path
#   $3 - now_epoch: current Unix timestamp
# Outputs: reason string when eligible
# Returns: 0 if eligible for trash move, 1 otherwise
#######################################
_pc_classify_orphan_sibling_dir() {
	local rp_orphan="$1"
	local candidate_path="$2"
	local now_epoch="$3"
	[[ -d "$candidate_path" ]] || return 1

	local repo_parent="" central_base=""
	repo_parent=$(dirname "$rp_orphan")
	central_base=""
	if declare -F aidevops_worktree_base_dir_configured >/dev/null 2>&1; then
		central_base=$(aidevops_worktree_base_dir_configured)
	fi
	case "$candidate_path" in
	"$repo_parent"/*) : ;;
	*)
		if [[ -n "$central_base" ]]; then
			case "$candidate_path" in
			"$central_base"/*) : ;;
			*) return 1 ;;
			esac
		else
			return 1
		fi
		;;
	esac

	if command -v is_registered_canonical >/dev/null 2>&1; then
		is_registered_canonical "$candidate_path" && return 1
	fi
	_pc_is_registered_worktree_path "$rp_orphan" "$candidate_path" && return 1

	local age_grace="${ORPHAN_WORKTREE_GRACE_SECS:-1800}"
	local dir_mtime=""
	dir_mtime=$(_file_mtime_epoch "$candidate_path")
	[[ "$dir_mtime" -gt 0 ]] || return 1
	[[ $((now_epoch - dir_mtime)) -ge "$age_grace" ]] || return 1

	if [[ -f "$candidate_path/.git" ]]; then
		if git -C "$candidate_path" status --porcelain >/dev/null 2>&1; then
			return 1
		fi
		printf '%s\n' "unregistered-gitfile-status-fails"
		return 0
	fi
	if [[ -d "$candidate_path/.git" ]]; then
		local standalone_branch=""
		standalone_branch=$(git -C "$candidate_path" branch --show-current 2>/dev/null || true)
		case "$standalone_branch" in
		main | master)
			local status_out=""
			if status_out=$(git -C "$candidate_path" status --porcelain 2>/dev/null) && [[ -z "$status_out" ]]; then
				printf '%s\n' "unregistered-standalone-clean-${standalone_branch}-dir"
				return 0
			fi
			;;
		esac
		return 1
	fi
	printf '%s\n' "unregistered-non-git-worker-dir"
	return 0
}

#######################################
# Trash stale sibling directories left behind after git worktree metadata loss.
#
# Args:
#   $1 - repos_json: managed repo registry
#   $2 - now_epoch: current Unix timestamp
# Outputs: number of directories moved to trash
# Returns: 0 always
#######################################
_pc_cleanup_orphan_sibling_dirs() {
	local repos_json="$1"
	local now_epoch="$2"
	local moved_count=0
	[[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1 || { echo 0; return 0; }

	local repo_records_orphan
	repo_records_orphan=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | [(.path // ""), (.slug // "")] | @tsv' "$repos_json" 2>/dev/null || printf '')

	local rp_orphan="" repo_slug_orphan=""
	while IFS=$'\t' read -r rp_orphan repo_slug_orphan; do
		[[ -z "$rp_orphan" ]] && continue
		[[ -d "$rp_orphan/.git" || -f "$rp_orphan/.git" ]] || continue
		local repo_parent="" repo_name="" candidate_path="" candidate_name="" reason="" central_base=""
		repo_parent=$(dirname "$rp_orphan")
		repo_name=$(basename "$rp_orphan")
		central_base=""
		if declare -F aidevops_worktree_base_dir_configured >/dev/null 2>&1; then
			central_base=$(aidevops_worktree_base_dir_configured)
		fi
		[[ -d "$repo_parent" && -n "$repo_name" ]] || continue
		for candidate_path in "$repo_parent/$repo_name"-* "$repo_parent/$repo_name".*; do
			[[ -d "$candidate_path" ]] || continue
			candidate_name=$(basename "$candidate_path")
			_pc_orphan_sibling_name_allowed "$repo_name" "$candidate_name" || continue
			_pc_orphan_sibling_pr_state_allowed "$repo_slug_orphan" "$repo_name" "$candidate_name" || continue
			if reason=$(_pc_classify_orphan_sibling_dir "$rp_orphan" "$candidate_path" "$now_epoch"); then
				echo "[pulse-wrapper] Orphan dir cleanup ($repo_name): moving $candidate_path to trash — $reason" >>"$LOGFILE"
				if _pc_trash_orphan_dir "$candidate_path"; then
					log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$candidate_path" "$reason" "trash"
					moved_count=$((moved_count + 1))
				else
					log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$candidate_path" "trash-failed" "$_PC_REMOVAL_SKIPPED"
				fi
			fi
		done
		if [[ -n "$central_base" && -d "$central_base" && "$central_base" != "$repo_parent" ]]; then
			for candidate_path in "$central_base/$repo_name"-* "$central_base/$repo_name".*; do
				[[ -d "$candidate_path" ]] || continue
				candidate_name=$(basename "$candidate_path")
				_pc_orphan_sibling_name_allowed "$repo_name" "$candidate_name" || continue
				_pc_orphan_sibling_pr_state_allowed "$repo_slug_orphan" "$repo_name" "$candidate_name" || continue
				if reason=$(_pc_classify_orphan_sibling_dir "$rp_orphan" "$candidate_path" "$now_epoch"); then
					echo "[pulse-wrapper] Orphan dir cleanup ($repo_name): moving $candidate_path to trash — $reason" >>"$LOGFILE"
					if _pc_trash_orphan_dir "$candidate_path"; then
						log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$candidate_path" "$reason" "trash"
						moved_count=$((moved_count + 1))
					else
						log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$candidate_path" "trash-failed" "$_PC_REMOVAL_SKIPPED"
					fi
				fi
			done
		fi
	done <<<"$repo_records_orphan"

	echo "$moved_count"
	return 0
}

#######################################
# Determine whether a worktree path is under a parent directory.
#
# Args:
#   $1 - child path
#   $2 - parent directory
# Returns: 0 when child is inside parent, 1 otherwise
#######################################
_pc_path_inside_dir() {
	local child_path="$1"
	local parent_dir="$2"
	[[ -n "$child_path" && -n "$parent_dir" ]] || return 1
	case "$child_path" in
	"$parent_dir"/*) return 0 ;;
	esac
	return 1
}

#######################################
# Relocate one registered linked worktree into the central worktree base.
#
# Args:
#   $1 - canonical repo path
#   $2 - main worktree path
#   $3 - worktree path to move
#   $4 - branch name
#   $5 - central worktree base directory
# Returns: 0 when moved, 1 when skipped or failed
#######################################
_pc_relocate_registered_worktree() {
	local rp_move="$1"
	local main_wt_move="$2"
	local wt_path_move="$3"
	local wt_branch_move="$4"
	local central_base="$5"

	[[ -n "$rp_move" && -n "$main_wt_move" && -n "$wt_path_move" && -n "$wt_branch_move" && -n "$central_base" ]] || return 1
	[[ "$wt_path_move" != "$main_wt_move" ]] || return 1
	_pc_path_inside_dir "$wt_path_move" "$central_base" && return 1

	local repo_parent_move
	repo_parent_move=$(dirname "$main_wt_move")
	_pc_path_inside_dir "$wt_path_move" "$repo_parent_move" || return 1
	worktree_removal_guard "$wt_path_move" "$_WTAR_PC_CALLER" "centralize-worktree" || return 1

	local target_path=""
	if declare -F aidevops_generate_worktree_path >/dev/null 2>&1; then
		target_path=$(aidevops_generate_worktree_path "$main_wt_move" "$wt_branch_move" 2>/dev/null || true)
	fi
	if [[ -z "$target_path" ]]; then
		local repo_name_move="" branch_slug_move=""
		repo_name_move=$(basename "$main_wt_move")
		branch_slug_move=$(printf '%s\n' "$wt_branch_move" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
		target_path="${central_base}/${repo_name_move}-${branch_slug_move}"
	fi
	[[ -n "$target_path" && "$target_path" != "$wt_path_move" ]] || return 1
	[[ ! -e "$target_path" ]] || {
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_move" "centralize-target-exists" "$_PC_REMOVAL_SKIPPED"
		return 1
	}
	mkdir -p "$(dirname "$target_path")" 2>/dev/null || return 1

	if git -C "$rp_move" worktree move "$wt_path_move" "$target_path" >/dev/null 2>&1; then
		unregister_worktree "$wt_path_move" 2>/dev/null || true
		log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$wt_path_move" "centralized-worktree" "moved" "target=central-worktree-base branch=$wt_branch_move"
		return 0
	fi
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_move" "centralize-move-failed" "$_PC_REMOVAL_SKIPPED"
	return 1
}

#######################################
# Relocate registered linked worktrees from repo parents into central base.
#
# Args:
#   $1 - repos_json: managed repo registry
# Outputs: number of worktrees relocated
# Returns: 0 always
#######################################
_pc_relocate_registered_worktrees() {
	local repos_json="$1"
	local moved_count=0
	[[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1 || { echo 0; return 0; }

	local central_base=""
	if declare -F aidevops_worktree_base_dir >/dev/null 2>&1; then
		central_base=$(aidevops_worktree_base_dir 2>/dev/null || true)
	elif declare -F aidevops_worktree_base_dir_configured >/dev/null 2>&1; then
		central_base=$(aidevops_worktree_base_dir_configured 2>/dev/null || true)
		[[ -n "$central_base" ]] && mkdir -p "$central_base" 2>/dev/null || true
	fi
	[[ -n "$central_base" && -d "$central_base" ]] || { echo 0; return 0; }

	local repo_paths_move
	repo_paths_move=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" 2>/dev/null || printf '')

	local rp_move
	while IFS= read -r rp_move; do
		[[ -z "$rp_move" ]] && continue
		[[ -d "$rp_move/.git" || -f "$rp_move/.git" ]] || continue
		local porcelain_move="" main_wt_move="" wt_path_move="" wt_branch_move="" line_move=""
		porcelain_move=$(git -C "$rp_move" worktree list --porcelain 2>/dev/null || true)
		[[ -n "$porcelain_move" ]] || continue
		main_wt_move="${porcelain_move%%$'\n'*}"
		main_wt_move="${main_wt_move#worktree }"
		[[ -n "$main_wt_move" ]] || continue
		wt_path_move=""
		wt_branch_move=""
		while IFS= read -r line_move; do
			if [[ "$line_move" =~ ^worktree\ (.+)$ ]]; then
				wt_path_move="${BASH_REMATCH[1]}"
				wt_branch_move=""
			elif [[ "$line_move" =~ ^branch\ refs/heads/(.+)$ ]]; then
				wt_branch_move="${BASH_REMATCH[1]}"
			elif [[ -z "$line_move" ]]; then
				if _pc_relocate_registered_worktree "$rp_move" "$main_wt_move" "$wt_path_move" "$wt_branch_move" "$central_base"; then
					moved_count=$((moved_count + 1))
				fi
				wt_path_move=""
				wt_branch_move=""
			fi
		done <<<"${porcelain_move}"$'\n'
	done <<<"$repo_paths_move"

	echo "$moved_count"
	return 0
}
#######################################
# Clean up worktrees for merged/closed PRs and orphaned workers
# across ALL managed repos.
#
# Multi-pass approach:
#   Pass 0 (cleanup_stale_temp_worktrees): remove abandoned detached
#           regression-helper fixtures without GitHub API calls.
#   Pass 1 (_cleanup_merged_prs_for_all_repos): remove worktrees whose
#           PR has merged. Uses worktree-helper.sh.
#   Pass 2 (_cleanup_single_worktree): age-based orphan cleanup for
#           worktrees that have no PR (crashed/abandoned workers).
#           Age thresholds: >30m no-PR, >3h clean, >6h dirty, >24h commits.
#
# See also: GH#18346 (silent-skip logging fix preserved in helpers above)
#######################################
_pc_cleanup_fixture_passes() {
	local total_removed=0
	# Fast, API-free pass for detached regression-helper fixtures. Run before
	# the GraphQL gate and merged-PR scan so a stale long-running cleanup cannot
	# leave the dispatch worktree cap permanently saturated.
	if declare -F cleanup_stale_temp_worktrees >/dev/null 2>&1; then
		local temp_removed=0
		temp_removed=$(cleanup_stale_temp_worktrees) || temp_removed=0
		[[ "$temp_removed" =~ ^[0-9]+$ ]] || temp_removed=0
		total_removed=$((total_removed + temp_removed))
	fi
	if declare -F _pc_cleanup_central_fixture_orphans >/dev/null 2>&1; then
		local fixtures_moved=0
		fixtures_moved=$(_pc_cleanup_central_fixture_orphans "$(date +%s)") || fixtures_moved=0
		[[ "$fixtures_moved" =~ ^[0-9]+$ ]] || fixtures_moved=0
		total_removed=$((total_removed + fixtures_moved))
	fi
	printf '%s\n' "$total_removed"
	return 0
}

cleanup_worktrees() {
	CLEANUP_WORKTREES_SKIPPED=0
	CLEANUP_WORKTREES_REMOVED_COUNT=0
	CLEANUP_WORKTREES_ARCHIVED_COUNT=0
	CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT=0
	local total_removed=0
	total_removed=$(_pc_cleanup_fixture_passes)
	CLEANUP_WORKTREES_REMOVED_COUNT="$total_removed"
	# GH#18979: Skip cleanup when API rate limit is low — both passes call
	# `gh pr list` per repo/worktree, and blocking rate-limit waits cause
	# the cleanup stage to hang for 10+ minutes, stalling the entire pulse
	# cycle. The cost of skipping one cleanup pass is negligible (worktrees
	# accumulate slowly); the cost of hanging is total pipeline stall.
	local _rl_remaining=""
	_rl_remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null) || _rl_remaining=""
	if [[ "$_rl_remaining" =~ ^[0-9]+$ ]] && [[ "$_rl_remaining" -lt 100 ]]; then
		echo "[pulse-wrapper] Worktree cleanup: skipped — GraphQL rate limit low (${_rl_remaining} remaining)" >>"$LOGFILE"
		CLEANUP_WORKTREES_SKIPPED=1
		return 0
	fi

	# Pass 1: remove worktrees for merged PRs
	local merged_removed
	merged_removed=$(_cleanup_merged_prs_for_all_repos)
	total_removed=$((total_removed + merged_removed))

	# Pass 2: age-based orphan cleanup
	local now_epoch
	now_epoch=$(date +%s)

	local repos_json="${HOME}/.config/aidevops/repos.json"
	[[ -f "$repos_json" ]] && command -v jq &>/dev/null || return 0
	_pc_log_local_only_worktree_skips "$repos_json"

	local repo_paths_age
	repo_paths_age=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" || echo "")

	local rp_age
	while IFS= read -r rp_age; do
		[[ -z "$rp_age" ]] && continue
		[[ ! -d "$rp_age/.git" ]] && continue

		local main_branch
		main_branch=$(git -C "$rp_age" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || main_branch="main"

		local repo_slug_age
		repo_slug_age=$(git -C "$rp_age" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||') || repo_slug_age=""

		# Parse worktree list — non-porcelain: "path  hash [branch]" per line.
		# Using process substitution (not pipe) so total_removed propagates.
		local wt_line_age
		while IFS= read -r wt_line_age; do
			local wt_path_age
			wt_path_age=$(printf '%s' "$wt_line_age" | awk '{print $1}')
			[[ -z "$wt_path_age" ]] && continue
			[[ "$wt_path_age" == "$rp_age" ]] && continue
			[[ ! -d "$wt_path_age" ]] && continue

			local wt_branch_age=""
			if [[ "$wt_line_age" == *"["*"]"* ]]; then
				wt_branch_age=$(printf '%s' "$wt_line_age" | sed 's/.*\[//;s/\]//')
			fi

			if _cleanup_single_worktree "$rp_age" "$wt_path_age" "$wt_branch_age" \
				"$now_epoch" "$repo_slug_age" "$main_branch"; then
				total_removed=$((total_removed + 1))
			fi
		done < <(git -C "$rp_age" worktree list 2>/dev/null)
	done <<<"$repo_paths_age"

	# Pass 3: registered linked worktrees accidentally created beside canonical
	# repos are moved into the central worktree base instead of cluttering the
	# canonical repo parent.
	local registered_moved
	registered_moved=$(_pc_relocate_registered_worktrees "$repos_json")
	if [[ "$registered_moved" -gt 0 ]]; then
		echo "[pulse-wrapper] Worktree relocation total: $registered_moved worktree(s) moved to central base" >>"$LOGFILE"
	fi

	# Pass 4: filesystem outliers that are no longer present in git worktree
	# metadata. These are moved to a recoverable trash bucket only; standalone
	# git repos and valid gitfile worktrees are skipped.
	local orphan_dirs_moved
	orphan_dirs_moved=$(_pc_cleanup_orphan_sibling_dirs "$repos_json" "$now_epoch")
	total_removed=$((total_removed + orphan_dirs_moved))

	if [[ "$total_removed" -gt 0 ]]; then
		echo "[pulse-wrapper] Worktree cleanup total: $total_removed worktree(s) removed across all repos" >>"$LOGFILE"
	fi
	CLEANUP_WORKTREES_REMOVED_COUNT="$total_removed"

	return 0
}
