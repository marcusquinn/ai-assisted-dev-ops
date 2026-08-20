#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Worktree Clean Library — Merged-branch worktree cleanup helpers
# =============================================================================
# Functions for detecting and removing worktrees whose branches have been
# merged, squash-merged, remote-deleted, or abandoned (closed PR).
#
# Extracted from worktree-helper.sh (GH#21409) to reduce the orchestrator
# below the 2000-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/worktree-clean-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (colour vars, register/unregister_worktree, etc.)
#   - audit-worktree-removal-helper.sh (log_worktree_removal_event, _WTAR_*)
#     Must be sourced by the orchestrator before this library is loaded.
#   - worktree-helper.sh helper functions (resolved at call time):
#       worktree_has_changes, branch_was_pushed,
#       _branch_exists_on_any_remote, get_default_branch,
#       localdev_auto_branch_rm, assert_git_available,
#       assert_main_worktree_sane
#   - _WTAR_WH_CALLER must be set in the orchestrator before calling any
#     function in this library.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKTREE_CLEAN_LIB_LOADED:-}" ]] && return 0
_WORKTREE_CLEAN_LIB_LOADED=1
_WT_CLEAN_DEFERRED_MARKER=".agents/.full-loop-cleanup-deferred"
_WT_CLEAN_DEFERRED_OWNER_PID=""
_WT_CLEAN_REASON_OWNED_SKIP="owned-skip"
_WT_CLEAN_REMOVAL_LEASE_SESSION="cleanup:$$"
_WT_CLEAN_REMOVAL_LEASE_TASK="worktree-removal"
_WT_CLEAN_MARKER_CLOCK_SKEW_SECONDS=2

# SCRIPT_DIR fallback — covers sourcing from test harnesses or direct invocation
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if [[ -f "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh" ]]; then
	# shellcheck source=./full-loop-cleanup-receipt.sh
	source "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh"
fi

# --- Functions ---

_clean_process_age_seconds() {
	local owner_pid="$1"
	local elapsed=""
	local days=0
	local hours=0
	local minutes=0
	local seconds=0
	local colons_only=""
	local colon_count=0

	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	elapsed=$(ps -p "$owner_pid" -o etime= 2>/dev/null | tr -d ' ') || return 1
	[[ -n "$elapsed" ]] || return 1
	if [[ "$elapsed" == *-* ]]; then
		days="${elapsed%%-*}"
		elapsed="${elapsed#*-}"
	fi
	colons_only="${elapsed//[!:]/}"
	colon_count="${#colons_only}"
	if [[ "$colon_count" -eq 2 ]]; then
		IFS=':' read -r hours minutes seconds <<<"$elapsed"
	elif [[ "$colon_count" -eq 1 ]]; then
		IFS=':' read -r minutes seconds <<<"$elapsed"
	else
		seconds="$elapsed"
	fi
	[[ "$days" =~ ^[0-9]+$ ]] || return 1
	[[ "$hours" =~ ^[0-9]+$ ]] || return 1
	[[ "$minutes" =~ ^[0-9]+$ ]] || return 1
	[[ "$seconds" =~ ^[0-9]+$ ]] || return 1
	days=$((10#${days}))
	hours=$((10#${hours}))
	minutes=$((10#${minutes}))
	seconds=$((10#${seconds}))
	printf '%s\n' "$((days * 86400 + hours * 3600 + minutes * 60 + seconds))"
	return 0
}

_clean_legacy_marker_matches_process_generation() {
	local marker_path="$1"
	local owner_pid="$2"
	local marker_mtime=0
	local now_epoch=0
	local marker_age=0
	local process_age=0

	[[ -f "$marker_path" && "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$owner_pid" 2>/dev/null || return 1
	# Legacy markers contain only a PID. Compare ages so a process that started
	# after the marker cannot inherit cleanup ownership through PID reuse.
	# Missing timing evidence fails closed and preserves the worktree.
	declare -F _file_mtime_epoch >/dev/null 2>&1 || return 0
	marker_mtime=$(_file_mtime_epoch "$marker_path" 2>/dev/null) || return 0
	process_age=$(_clean_process_age_seconds "$owner_pid" 2>/dev/null) || return 0
	now_epoch=$(date +%s 2>/dev/null) || return 0
	[[ "$marker_mtime" =~ ^[0-9]+$ && "$marker_mtime" -gt 0 ]] || return 0
	[[ "$process_age" =~ ^[0-9]+$ ]] || return 0
	[[ "$now_epoch" =~ ^[0-9]+$ && "$now_epoch" -ge "$marker_mtime" ]] || return 0
	marker_age=$((now_epoch - marker_mtime))
	if [[ $((process_age + _WT_CLEAN_MARKER_CLOCK_SKEW_SECONDS)) -ge "$marker_age" ]]; then
		return 0
	fi
	return 1
}

_clean_deferred_parent_alive() {
	local wt_path="$1"
	local marker_path="${wt_path}/${_WT_CLEAN_DEFERRED_MARKER}"
	local receipt_path=""
	_WT_CLEAN_DEFERRED_OWNER_PID=""
	_WT_CLEAN_DEFERRED_RECEIPT=""
	if declare -F full_loop_cleanup_receipt_for_worktree >/dev/null 2>&1; then
		receipt_path=$(full_loop_cleanup_receipt_for_worktree "$wt_path" 2>/dev/null || true)
	fi
	if [[ -n "$receipt_path" && -f "$receipt_path" ]]; then
		_WT_CLEAN_DEFERRED_RECEIPT="$receipt_path"
		if full_loop_cleanup_owner_alive "$receipt_path"; then
			_WT_CLEAN_DEFERRED_OWNER_PID="${_FULL_LOOP_CLEANUP_OWNER_PID:-}"
			return 0
		fi
		_WT_CLEAN_DEFERRED_OWNER_PID="${_FULL_LOOP_CLEANUP_OWNER_PID:-}"
		rm -f "$marker_path" 2>/dev/null || true
		return 2
	fi
	[[ -f "$marker_path" ]] || return 1

	local owner_pid=""
	IFS= read -r owner_pid <"$marker_path" || true
	_WT_CLEAN_DEFERRED_OWNER_PID="$owner_pid"
	if _clean_legacy_marker_matches_process_generation "$marker_path" "$owner_pid"; then
		return 0
	fi
	rm -f "$marker_path" 2>/dev/null || true
	return 2
}

_clean_acquire_removal_lease() {
	local wt_path="$1"
	local wt_branch="$2"
	declare -F claim_worktree_ownership >/dev/null 2>&1 || return 1
	claim_worktree_ownership "$wt_path" "$wt_branch" \
		--owner-pid "$$" --session "$_WT_CLEAN_REMOVAL_LEASE_SESSION" \
		--task "$_WT_CLEAN_REMOVAL_LEASE_TASK" >/dev/null 2>&1 || return 1
	local receipt_path=""
	if declare -F full_loop_cleanup_receipt_for_worktree >/dev/null 2>&1; then
		receipt_path=$(full_loop_cleanup_receipt_for_worktree "$wt_path" 2>/dev/null || true)
	fi
	if [[ -n "$receipt_path" ]] && ! full_loop_transition_cleanup_receipt "$receipt_path" "$_FULL_LOOP_CLEANUP_LEASED" "$$"; then
		_clean_release_removal_lease "$wt_path" || true
		return 1
	fi
	return 0
}

_clean_has_exact_removal_lease() {
	local wt_path="$1"
	declare -F worktree_has_exact_owner_contract >/dev/null 2>&1 || return 1
	worktree_has_exact_owner_contract "$wt_path" "$$" \
		"$_WT_CLEAN_REMOVAL_LEASE_SESSION" "$_WT_CLEAN_REMOVAL_LEASE_TASK" || return 1
	return 0
}

_clean_release_removal_lease() {
	local wt_path="$1"
	declare -F unregister_worktree_if_owner_contract >/dev/null 2>&1 || return 1
	unregister_worktree_if_owner_contract "$wt_path" "$$" \
		"$_WT_CLEAN_REMOVAL_LEASE_SESSION" "$_WT_CLEAN_REMOVAL_LEASE_TASK" \
		>/dev/null 2>&1 || return 1
	return 0
}

_clean_terminal_owner_blocks_cleanup() {
	local wt_path="$1"
	local deferred_parent_state=0
	_clean_deferred_parent_alive "$wt_path" || deferred_parent_state=$?
	if [[ "$deferred_parent_state" -eq 0 ]]; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "parent-runtime-active" "$_WT_CLEAN_MODE_SKIPPED"
		return 0
	fi
	if [[ "$deferred_parent_state" -eq 2 ]]; then
		if [[ -n "$_WT_CLEAN_DEFERRED_OWNER_PID" ]] &&
			unregister_worktree_if_owner_pid "$wt_path" "$_WT_CLEAN_DEFERRED_OWNER_PID" 2>/dev/null; then
			return 1
		fi
		if is_worktree_owned_by_others "$wt_path"; then
			log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "$_WT_CLEAN_REASON_OWNED_SKIP" "$_WT_CLEAN_MODE_SKIPPED"
			return 0
		fi
		return 1
	fi
	if is_worktree_owned_by_others "$wt_path"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "$_WT_CLEAN_REASON_OWNED_SKIP" "$_WT_CLEAN_MODE_SKIPPED"
		return 0
	fi
	return 1
}

get_validated_grace_hours() {
	local grace_hours="${WORKTREE_CLEAN_GRACE_HOURS:-4}"

	# Check if it's a valid positive integer
	if [[ "$grace_hours" =~ ^[0-9]+$ ]] && [[ "$grace_hours" -gt 0 ]]; then
		echo "$grace_hours"
		return 0
	fi

	# Invalid value - warn and use default
	echo -e "${YELLOW}Warning: WORKTREE_CLEAN_GRACE_HOURS='$grace_hours' is invalid, using default 4 hours${NC}" >&2
	echo "4"
	return 0
}

# Check if a worktree directory is younger than the grace period.
# Returns 0 (true) if the worktree is within the grace period, 1 (false) if old enough to clean.
# Grace period defaults to WORKTREE_CLEAN_GRACE_HOURS (default: 4 hours).
# Uses directory mtime as a proxy for creation time (set at worktree creation).
# Bash 3.2 compatible — no associative arrays, no bash 4+ features.
worktree_is_in_grace_period() {
	local wt_path="${1:-}"
	local grace_hours
	grace_hours=$(get_validated_grace_hours)
	[[ -z "$wt_path" ]] && return 1
	[[ ! -d "$wt_path" ]] && return 1

	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || return 1

	local dir_mtime
	dir_mtime=$(_file_mtime_epoch "$wt_path")
	if [[ "$dir_mtime" -eq 0 ]]; then
		# Cannot determine mtime — fail safe (treat as in grace period)
		return 0
	fi

	local age_seconds=$((now_epoch - dir_mtime))
	local grace_seconds=$((grace_hours * 3600))

	if [[ "$age_seconds" -lt "$grace_seconds" ]]; then
		return 0 # Within grace period
	fi
	return 1 # Outside grace period
}

# Check if a branch has an open PR on any remote.
# Returns 0 (true) if an open PR exists, 1 (false) otherwise.
# Requires gh CLI. Returns 0 (skip deletion) if gh is unavailable or fails.
branch_has_open_pr() {
	local branch="${1:-}"
	[[ -z "$branch" ]] && return 1
	command -v gh &>/dev/null || return 0
	local repo_slug
	repo_slug=$(_clean_repo_slug 2>/dev/null || true)
	[[ -z "$repo_slug" ]] && return 0

	local open_count
	if ! open_count=$(gh_pr_list --repo "$repo_slug" --state open --head "$branch" --json number --jq 'length' 2>/dev/null); then
		# gh command failed - return 0 to skip deletion (safety-first)
		return 0
	fi
	[[ "$open_count" -gt 0 ]] && return 0
	return 1
}

# Check if a branch has zero commits ahead of the default branch.
# A branch with 0 commits ahead looks "merged" to git branch --merged but may
# just be a freshly created worktree with no commits yet.
# Returns 0 (true) if zero commits ahead, 1 (false) if has commits.
branch_has_zero_commits_ahead() {
	local branch="${1:-}"
	local default_br="${2:-}"
	[[ -z "$branch" ]] && return 1
	[[ -z "$default_br" ]] && return 1

	local ahead_count
	ahead_count=$(git rev-list --count "refs/heads/$default_br..refs/heads/$branch" 2>/dev/null || echo "1")
	[[ "$ahead_count" -eq 0 ]] && return 0
	return 1
}

# Check whether a worktree's branch has an active interactive-session claim.
# Returns 0 (true) if an active claim exists (stamp present, PID alive),
# 1 otherwise. Fail-OPEN: any error in branch parsing, slug derivation, or
# subprocess invocation returns 1 so the caller falls through to the existing
# 4 safety checks (no regression on degraded environments).
#
# t2916/GH#21074: Two worktree-loss incidents on 2026-04-26 motivated this
# check. Pre-existing safety checks (PID-ownership, 4h grace, open-PR list,
# zero-commit-dirty) all have known failure modes that let active interactive
# work through. The interactive-session claim-stamp directory at
# `~/.aidevops/.agent-workspace/interactive-claims/` is the canonical "an
# interactive session owns this work right now" signal — same source the
# dispatch-dedup gate (`_has_active_claim` in dispatch-dedup-helper.sh) trusts.
#
# Implementation: subprocess-call to interactive-session-helper.sh subcommand
# `branch-has-active-claim` rather than sourcing. Sourcing would drag in the
# full helper graph (orchestrator + 4 sub-libs, ~1500 lines) and reset
# SCRIPT_DIR. Subprocess cost is ~10ms per worktree — for typical sweeps of
# 5-20 worktrees this is negligible vs the source-time parse cost.
_branch_has_active_interactive_claim() {
	local wt_path="$1"
	local wt_branch="$2"

	[[ -z "$wt_branch" ]] && return 1

	# Locate the helper. Prefer the deployed copy (runtime source of truth);
	# fall back to the in-repo copy when running from the canonical repo
	# pre-deploy. Same priority order as worktree-helper.sh:_interactive_session_auto_claim.
	local helper=""
	if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
	elif [[ -n "${SCRIPT_DIR:-}" && -x "${SCRIPT_DIR}/interactive-session-helper.sh" ]]; then
		helper="${SCRIPT_DIR}/interactive-session-helper.sh"
	else
		# No helper available — fail OPEN, fall through to existing checks.
		return 1
	fi

	# Subprocess call. Exit 0 = active claim, exit 1 = no claim, any other
	# exit = error (treated as no claim — fail OPEN).
	if "$helper" branch-has-active-claim "$wt_branch" --worktree "$wt_path" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_skip_cleanup_emit() {
	local wt_branch="$1"
	local wt_path="$2"
	local reason_message="$3"
	local audit_reason="$4"

	echo -e "  ${RED:-}$wt_branch${NC:-} (${reason_message} - skipping)"
	echo "    $wt_path"
	printf '\n'
	log_worktree_removal_event "${_WTAR_SKIPPED:-}" "${_WTAR_WH_CALLER:-}" "$wt_path" "$audit_reason" "${_WT_CLEAN_MODE_SKIPPED:-}"
	return 0
}

_skip_cleanup_for_current_worktree() {
	local wt_path="$1"
	local wt_branch="$2"
	local current_dir=""

	# GH#22154: Never remove the worktree that is executing cleanup.
	# A caller may run `worktree-helper.sh clean --auto` from a linked worktree
	# whose branch is already merged. Without this guard, the cleanup pass can
	# trash the caller's current directory mid-command, producing getcwd failures
	# and cascading "script not found" errors in the next gate.
	current_dir=$(pwd -P 2>/dev/null || true)
	if [[ -n "$current_dir" ]]; then
		case "$current_dir" in
		"$wt_path" | "$wt_path"/*)
			_skip_cleanup_emit "$wt_branch" "$wt_path" "current working tree" "current-worktree"
			return 0
			;;
		esac
	fi
	return 1
}

_skip_cleanup_for_active_claim() {
	local wt_path="$1"
	local wt_branch="$2"

	# t2916/GH#21074: Active interactive-session claim check.
	# Consults the same canonical claim-stamp directory the dispatch-dedup
	# gate uses. Placed BEFORE the 4h grace cliff so claim-stamp wins on
	# stale work too — a >4h interactive session is still legitimately
	# owned, but the grace cliff would otherwise let cleanup through.
	if _branch_has_active_interactive_claim "$wt_path" "$wt_branch"; then
		_skip_cleanup_emit "$wt_branch" "$wt_path" "active interactive claim" "active-claim"
		return 0
	fi
	return 1
}

_skip_cleanup_for_owner() {
	local wt_path="$1"
	local wt_branch="$2"
	local owner_info=""
	local owner_pid=""
	local owner_dead_seen_at=""

	# Ownership check (t189): skip if owned by another active session
	if ! is_worktree_owned_by_others "$wt_path"; then
		return 1
	fi

	owner_info=$(check_worktree_owner "$wt_path")
	owner_pid="${owner_info%%|*}"
	if declare -F worktree_owner_dead_seen_at >/dev/null 2>&1; then
		owner_dead_seen_at=$(worktree_owner_dead_seen_at "$wt_path")
	fi
	if [[ -n "$owner_dead_seen_at" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
		_skip_cleanup_emit "$wt_branch" "$wt_path" "dead owner PID $owner_pid in cooldown since $owner_dead_seen_at" "owner-pid-dead"
		return 0
	fi
	_skip_cleanup_emit "$wt_branch" "$wt_path" "owned by active session PID $owner_pid" "$_WT_CLEAN_REASON_OWNED_SKIP"
	return 0
}

_skip_cleanup_for_grace_period() {
	local wt_path="$1"
	local wt_branch="$2"
	local grace_hours=""

	# GH#5694 Safety check A: Grace period
	# Skip worktrees younger than WORKTREE_CLEAN_GRACE_HOURS (default 4h).
	# A freshly created worktree with 0 commits looks "merged" to git branch --merged.
	# The grace period prevents deletion of in-progress work that hasn't been committed yet.
	if worktree_is_in_grace_period "$wt_path"; then
		grace_hours=$(get_validated_grace_hours)
		_skip_cleanup_emit "$wt_branch" "$wt_path" "within grace period ${grace_hours}h" "grace-period"
		return 0
	fi
	return 1
}

_skip_cleanup_for_branch_state() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local open_pr_list="$4"
	local force_merged_flag="$5"

	# GH#5694 Safety check B: Open PR. Applies even with --force-merged.
	if _clean_branch_list_contains_exact "$wt_branch" "$open_pr_list"; then
		_skip_cleanup_emit "$wt_branch" "$wt_path" "has open PR" "open-pr"
		return 0
	fi

	# t3545/GH#22606 Safety check C-pre: Empty branch (zero commits ahead).
	# On the non-force-merged path this is pre-work, not merged work, and must
	# be preserved even when the worktree is clean. With --force-merged, fall
	# through to the legacy dirty zero-commit guard and later classification.
	if [[ "$force_merged_flag" != "true" ]] && branch_has_zero_commits_ahead "$wt_branch" "$default_br"; then
		_skip_cleanup_emit "$wt_branch" "$wt_path" "0 commits ahead = empty/pre-work branch" "empty-branch"
		return 0
	fi
	return 1
}

_skip_cleanup_for_dirty_state() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local force_merged_flag="$4"

	# GH#5694 Safety check C: Zero-commit + dirty (legacy — kept for the
	# --force-merged path; the empty-branch check above already covers the
	# non-force path). Retained so the audit-log reason "zero-commit-dirty"
	# remains a valid emission and existing diagnostics stay readable.
	if worktree_has_changes "$wt_path" && branch_has_zero_commits_ahead "$wt_branch" "$default_br"; then
		_skip_cleanup_emit "$wt_branch" "$wt_path" "0 commits ahead + dirty files = in-progress, not merged" "zero-commit-dirty"
		return 0
	fi

	# Dirty check: behaviour depends on --force-merged flag.
	# force_merged=true: dirty state is abandoned WIP, safe to force-remove.
	if worktree_has_changes "$wt_path" && [[ "$force_merged_flag" != "true" ]]; then
		_skip_cleanup_emit "$wt_branch" "$wt_path" "has uncommitted changes" "dirty-skip"
		return 0
	fi
	return 1
}

# Check if a worktree should be skipped during cleanup due to safety constraints.
# Returns 0 (true) if worktree should be skipped, 1 (false) if safe to remove.
# Args: $1=worktree_path, $2=worktree_branch, $3=default_branch, $4=open_pr_branches, $5=force_merged
# Prints skip reason to stdout if skipping.
should_skip_cleanup() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local open_pr_list="$4"
	local force_merged_flag="$5"

	_skip_cleanup_for_current_worktree "$wt_path" "$wt_branch" && return 0
	_skip_cleanup_for_active_claim "$wt_path" "$wt_branch" && return 0
	_skip_cleanup_for_owner "$wt_path" "$wt_branch" && return 0
	_skip_cleanup_for_grace_period "$wt_path" "$wt_branch" && return 0
	_skip_cleanup_for_branch_state "$wt_path" "$wt_branch" "$default_br" "$open_pr_list" "$force_merged_flag" && return 0
	_skip_cleanup_for_dirty_state "$wt_path" "$wt_branch" "$default_br" "$force_merged_flag" && return 0

	# All safety checks passed
	return 1
}

# Fetch and prune all remotes. Sets remote_state_unknown=true in caller's scope on failure.
# Prints warnings for failed remotes. Returns 0 always (failures are non-fatal).
# Args: none. Modifies caller's remote_state_unknown variable via echo to a temp file.
# Usage: remote_state_unknown=$(_clean_fetch_remotes)
_clean_fetch_remotes() {
	local state_unknown=false
	local remote
	# GH#18979: Apply a 10-second timeout per remote fetch. In pulse cleanup
	# context, git fetch --prune can hang indefinitely on network I/O or
	# slow remote negotiation with many branches, stalling the entire pulse
	# cycle. 10s is generous for a prune-only fetch; if it exceeds that,
	# the remote is unreachable and we should treat state as unknown.
	local fetch_timeout_cmd=""
	if command -v gtimeout &>/dev/null; then
		fetch_timeout_cmd="gtimeout 10"
	elif command -v timeout &>/dev/null; then
		fetch_timeout_cmd="timeout 10"
	fi
	for remote in $(git remote 2>/dev/null); do
		if [[ -n "$fetch_timeout_cmd" ]]; then
			if ! $fetch_timeout_cmd git fetch --prune "$remote" 2>/dev/null; then
				echo -e "${YELLOW}Warning: failed to refresh $remote; skipping remote-deleted cleanup checks${NC}" >&2
				state_unknown=true
			fi
		else
			# No timeout command available — run unguarded but with a background kill
			git fetch --prune "$remote" 2>/dev/null &
			local _fetch_pid=$!
			local _fetch_waited=0
			while kill -0 "$_fetch_pid" 2>/dev/null && [[ "$_fetch_waited" -lt 10 ]]; do
				sleep 1
				_fetch_waited=$((_fetch_waited + 1))
			done
			if kill -0 "$_fetch_pid" 2>/dev/null; then
				kill "$_fetch_pid" 2>/dev/null || true
				wait "$_fetch_pid" 2>/dev/null || true
				echo -e "${YELLOW}Warning: fetch timed out for $remote; skipping remote-deleted cleanup checks${NC}" >&2
				state_unknown=true
			else
				wait "$_fetch_pid" 2>/dev/null || state_unknown=true
			fi
		fi
	done
	echo "$state_unknown"
	return 0
}

# Build newline-delimited lists of merged and open PR branch names via gh CLI.
# Outputs two lines: merged_branches and open_branches (each may be empty).
# Caller splits on a delimiter. Returns 0 always.
# Usage: _clean_build_pr_lists; merged_pr_branches=...; open_pr_branches=...
_clean_repo_slug() {
	local remote_url=""
	remote_url=$(git remote get-url origin 2>/dev/null || true)
	[[ -z "$remote_url" ]] && return 1
	remote_url="${remote_url%.git}"
	remote_url="${remote_url#git@github.com:}"
	remote_url="${remote_url#https://github.com/}"
	remote_url="${remote_url#http://github.com/}"
	[[ "$remote_url" == */* ]] || return 1
	printf '%s\n' "$remote_url"
	return 0
}

_clean_gh_graphql() {
	command -v gh >/dev/null 2>&1 || return 1
	gh api graphql "$@"
	return $?
}

_clean_list_worktree_branches() {
	local default_br="$1"
	local porcelain=""
	local line=""
	local branch=""

	porcelain=$(git worktree list --porcelain 2>/dev/null) || return 1
	while IFS= read -r line; do
		if [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			branch="${BASH_REMATCH[1]}"
			[[ "$branch" == "$default_br" ]] || printf '%s\n' "$branch"
		fi
	done <<<"$porcelain"
	return 0
}

_clean_query_exact_merged_pr_batch() {
	local owner="$1"
	local repo_name="$2"
	shift 2
	[[ $# -gt 0 ]] || return 0

	local query_vars="\$owner:String!,\$name:String!"
	local query_fields=""
	local query=""
	local response=""
	local reported_cost=""
	local branch=""
	local index=0
	local -a graphql_args=(-f "owner=$owner" -f "name=$repo_name")

	for branch in "$@"; do
		query_vars="${query_vars},\$h${index}:String!"
		query_fields="${query_fields} q${index}:pullRequests(first:1,states:MERGED,headRefName:\$h${index}){nodes{headRefName}}"
		graphql_args+=(-f "h${index}=$branch")
		index=$((index + 1))
	done
	query="query(${query_vars}){repository(owner:\$owner,name:\$name){${query_fields}} rateLimit{cost}}"

	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="worktree-clean-merged-pr-batch-exact-cost" \
		_clean_gh_graphql -f "query=$query" "${graphql_args[@]}") || return 1
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || return 1
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s' "$response" | jq -r '(.data.repository // {}) | .[] | .nodes[]? | .headRefName'
	return $?
}

# Prefetch exact merged-PR proof for every registered worktree branch. A single
# GraphQL request can resolve many branch heads, avoiding one network round-trip
# per worktree when the repository has more merged PRs than the summary list.
_clean_build_exact_merged_pr_branches() {
	local default_br="$1"
	local repo_slug=""
	local owner=""
	local repo_name=""
	local branches=""
	local branch=""
	local batch_size="${AIDEVOPS_WORKTREE_PR_BATCH_SIZE:-100}"
	local -a batch=()

	[[ "$batch_size" =~ ^[0-9]+$ ]] && [[ "$batch_size" -ge 1 ]] && [[ "$batch_size" -le 100 ]] || batch_size=100
	repo_slug=$(_clean_repo_slug 2>/dev/null || true)
	[[ "$repo_slug" == */* ]] || return 1
	owner="${repo_slug%%/*}"
	repo_name="${repo_slug#*/}"
	branches=$(_clean_list_worktree_branches "$default_br") || return 1
	[[ -n "$branches" ]] || return 0

	while IFS= read -r branch; do
		[[ -n "$branch" ]] || continue
		batch+=("$branch")
		if [[ "${#batch[@]}" -ge "$batch_size" ]]; then
			_clean_query_exact_merged_pr_batch "$owner" "$repo_name" "${batch[@]}" || return 1
			batch=()
		fi
	done <<<"$branches"
	if [[ "${#batch[@]}" -gt 0 ]]; then
		_clean_query_exact_merged_pr_batch "$owner" "$repo_name" "${batch[@]}" || return 1
	fi
	return 0
}

_clean_prepare_git_branch_caches() {
	local default_br="$1"
	local merged_branches=""
	local upstream_lines=""
	local remote_branches=""
	local branch=""
	local remote_name=""
	local pushed_branches=""
	local upstream_status=0
	local remote_status=0

	_WT_CLEAN_LOCAL_MERGED_BRANCHES=""
	_WT_CLEAN_LOCAL_MERGED_CACHE_READY=false
	_WT_CLEAN_PUSHED_BRANCHES=""
	_WT_CLEAN_REMOTE_BRANCHES=""
	_WT_CLEAN_REMOTE_BRANCH_CACHE_READY=false
	_WT_CLEAN_REMOTE_DEFAULT_REF=""

	if merged_branches=$(git branch --format='%(refname:short)' --merged "$default_br" 2>/dev/null); then
		_WT_CLEAN_LOCAL_MERGED_BRANCHES="$merged_branches"
		_WT_CLEAN_LOCAL_MERGED_CACHE_READY=true
	fi
	_WT_CLEAN_REMOTE_DEFAULT_REF=$(_clean_remote_default_ref "$default_br" 2>/dev/null || true)

	upstream_lines=$(git for-each-ref --format='%(refname:short)%09%(upstream:remotename)' refs/heads/ 2>/dev/null) || upstream_status=$?
	remote_branches=$(git for-each-ref --format='%(refname:lstrip=3)' refs/remotes/ 2>/dev/null) || remote_status=$?
	if [[ "$upstream_status" -eq 0 && "$remote_status" -eq 0 ]]; then
		while IFS=$'\t' read -r branch remote_name; do
			[[ -n "$branch" && -n "$remote_name" ]] || continue
			pushed_branches="${pushed_branches}${pushed_branches:+$'\n'}${branch}"
		done <<<"$upstream_lines"
		if [[ -n "$remote_branches" ]]; then
			pushed_branches="${pushed_branches}${pushed_branches:+$'\n'}${remote_branches}"
		fi
		_WT_CLEAN_PUSHED_BRANCHES="$pushed_branches"
		_WT_CLEAN_REMOTE_BRANCHES="$remote_branches"
		_WT_CLEAN_REMOTE_BRANCH_CACHE_READY=true
	fi
	return 0
}

_clean_remote_default_ref() {
	local default_br="$1"
	local remote_ref=""

	[[ -n "$default_br" ]] || return 1
	if git show-ref --verify --quiet "refs/remotes/origin/${default_br}" 2>/dev/null; then
		printf 'origin/%s\n' "$default_br"
		return 0
	fi
	while IFS= read -r remote_ref; do
		[[ -n "$remote_ref" ]] || continue
		case "$remote_ref" in
		*/HEAD) continue ;;
		esac
		printf '%s\n' "$remote_ref"
		return 0
	done < <(git for-each-ref --format='%(refname:short)' "refs/remotes/*/${default_br}" 2>/dev/null)
	return 1
}

_clean_branch_is_locally_merged() {
	local wt_branch="$1"
	local default_br="$2"
	local merged_branches=""

	if [[ "$_WT_CLEAN_LOCAL_MERGED_CACHE_READY" == "true" ]]; then
		_clean_branch_list_contains_exact "$wt_branch" "$_WT_CLEAN_LOCAL_MERGED_BRANCHES"
		return $?
	fi
	merged_branches=$(git branch --format='%(refname:short)' --merged "$default_br" 2>/dev/null) || return 1
	_clean_branch_list_contains_exact "$wt_branch" "$merged_branches"
	return $?
}

_clean_branch_is_remote_default_contained() {
	local wt_branch="$1"
	local default_br="$2"
	local remote_default_ref="${_WT_CLEAN_REMOTE_DEFAULT_REF:-}"
	local counts=""
	local _left_count=""
	local right_count=""

	[[ -n "$wt_branch" && -n "$default_br" ]] || return 1
	if [[ -z "$remote_default_ref" ]]; then
		remote_default_ref=$(_clean_remote_default_ref "$default_br" 2>/dev/null || true)
	fi
	[[ -n "$remote_default_ref" ]] || return 1
	counts=$(git rev-list --left-right --count "${remote_default_ref}...refs/heads/${wt_branch}" 2>/dev/null) || return 1
	IFS=$'\t ' read -r _left_count right_count <<<"$counts"
	[[ "$right_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$right_count" -eq 0 ]] || return 1
	return 0
}

_clean_branch_was_pushed_cached() {
	local wt_branch="$1"
	if [[ "$_WT_CLEAN_REMOTE_BRANCH_CACHE_READY" == "true" ]]; then
		_clean_branch_list_contains_exact "$wt_branch" "$_WT_CLEAN_PUSHED_BRANCHES"
		return $?
	fi
	branch_was_pushed "$wt_branch"
	return $?
}

_clean_branch_exists_on_remote_cached() {
	local wt_branch="$1"
	if [[ "$_WT_CLEAN_REMOTE_BRANCH_CACHE_READY" == "true" ]]; then
		_clean_branch_list_contains_exact "$wt_branch" "$_WT_CLEAN_REMOTE_BRANCHES"
		return $?
	fi
	_branch_exists_on_any_remote "$wt_branch"
	return $?
}

_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS=${_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS:-}

_clean_pr_proof_unknown_add() {
	local reason="$1"
	[[ -z "$reason" ]] && return 0
	case $'\n'"$_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS"$'\n' in
	*$'\n'"$reason"$'\n'*) ;;
	*) _WT_CLEAN_PR_PROOF_UNKNOWN_REASONS="${_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS}${reason}"$'\n' ;;
	esac
	return 0
}

_clean_pr_proof_unknown_context() {
	local reasons="$_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS"
	[[ -n "$reasons" ]] || return 1
	reasons="${reasons//$'\n'/,}"
	reasons="${reasons%,}"
	printf '%s' "$reasons"
	return 0
}

_clean_build_merged_pr_branches() {
	local repo_slug=""
	repo_slug=$(_clean_repo_slug 2>/dev/null || true)
	if command -v gh &>/dev/null; then
		if [[ -n "$repo_slug" ]]; then
			if ! gh_pr_list --repo "$repo_slug" --state merged --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null; then
				_clean_pr_proof_unknown_add "unknown:merged-pr-list-unavailable"
				return 1
			fi
		else
			_clean_pr_proof_unknown_add "unknown:repo-slug-unavailable"
			return 1
		fi
	else
		_clean_pr_proof_unknown_add "unknown:gh-unavailable"
		return 1
	fi
	return 0
}

_clean_build_open_pr_branches() {
	local repo_slug=""
	repo_slug=$(_clean_repo_slug 2>/dev/null || true)
	if command -v gh &>/dev/null; then
		if [[ -n "$repo_slug" ]]; then
			if ! gh_pr_list --repo "$repo_slug" --state open --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null; then
				_clean_pr_proof_unknown_add "unknown:open-pr-list-unavailable"
				return 1
			fi
		else
			_clean_pr_proof_unknown_add "unknown:repo-slug-unavailable"
			return 1
		fi
	else
		_clean_pr_proof_unknown_add "unknown:gh-unavailable"
		return 1
	fi
	return 0
}

# Build newline-delimited list of CLOSED (abandoned, not merged) PR branch names.
# These are PRs that were closed without merging — the work is abandoned and the
# worktree is safe to remove. The remote branch may still exist if auto-delete
# only fires on merge.
_clean_build_closed_pr_branches() {
	local repo_slug=""
	repo_slug=$(_clean_repo_slug 2>/dev/null || true)
	if command -v gh &>/dev/null; then
		if [[ -n "$repo_slug" ]]; then
			if ! gh_pr_list --repo "$repo_slug" --state closed --limit 200 --json headRefName,mergedAt --jq '[.[] | select(.mergedAt == null)] | .[].headRefName' 2>/dev/null; then
				_clean_pr_proof_unknown_add "unknown:closed-pr-list-unavailable"
				return 1
			fi
		else
			_clean_pr_proof_unknown_add "unknown:repo-slug-unavailable"
			return 1
		fi
	else
		_clean_pr_proof_unknown_add "unknown:gh-unavailable"
		return 1
	fi
	return 0
}

_clean_branch_has_exact_merged_pr() {
	local wt_branch="$1"
	local merged_prs="${2:-}"
	local merged_count

	[[ -z "$wt_branch" ]] && return 1
	if _clean_branch_list_contains_exact "$wt_branch" "$merged_prs"; then
		return 0
	fi
	if [[ "$_WT_CLEAN_EXACT_PR_PREFETCH_COMPLETE" == "true" ]]; then
		return 1
	fi
	if ! command -v gh_pr_list &>/dev/null; then
		return 1
	fi
	local repo_slug=""
	repo_slug=$(_clean_repo_slug 2>/dev/null || true)
	if [[ -n "$repo_slug" ]]; then
		if ! merged_count=$(gh_pr_list --repo "$repo_slug" --head "$wt_branch" --state merged --limit 1 --json number --jq 'length' 2>/dev/null); then
			_clean_pr_proof_unknown_add "unknown:exact-merged-pr-unavailable"
			return 1
		fi
	else
		_clean_pr_proof_unknown_add "unknown:repo-slug-unavailable"
		return 1
	fi
	if [[ "$merged_count" =~ ^[1-9][0-9]*$ ]]; then
		return 0
	fi
	return 1
}

_clean_branch_list_contains_exact() {
	local wt_branch="$1"
	local branch_list="${2:-}"

	[[ -n "$wt_branch" && -n "$branch_list" ]] || return 1
	[[ $'\n'"$branch_list"$'\n' == *$'\n'"$wt_branch"$'\n'* ]] || return 1
	return 0
}

_clean_branch_has_terminal_pr_proof() {
	local wt_branch="$1"
	local merged_prs="${2:-}"
	local closed_prs="${3:-}"

	[[ -n "$wt_branch" ]] || return 1
	_clean_branch_list_contains_exact "$wt_branch" "$merged_prs" && return 0
	_clean_branch_list_contains_exact "$wt_branch" "$closed_prs" && return 0
	_clean_branch_has_exact_merged_pr "$wt_branch" "$merged_prs" && return 0
	return 1
}

_clean_merge_type_has_terminal_pr_proof() {
	local merge_type="$1"
	case "$merge_type" in
	"$_WT_CLEAN_TYPE_SQUASH_MERGED_PR" | "$_WT_CLEAN_TYPE_CLOSED_PR" | "$_WT_CLEAN_TYPE_CLOSED_ISSUE_ARCHIVE")
		return 0
		;;
	esac
	return 1
}

_WT_CLEAN_PROTECTED_PATHS="${_WT_CLEAN_PROTECTED_PATHS:-}"
_WT_CLEAN_LAST_MERGE_TYPE="${_WT_CLEAN_LAST_MERGE_TYPE:-}"
_WT_CLEAN_LAST_AUDIT_CONTEXT="${_WT_CLEAN_LAST_AUDIT_CONTEXT:-}"
_WT_CLEAN_LOCAL_MERGED_BRANCHES="${_WT_CLEAN_LOCAL_MERGED_BRANCHES:-}"
_WT_CLEAN_LOCAL_MERGED_CACHE_READY="${_WT_CLEAN_LOCAL_MERGED_CACHE_READY:-false}"
_WT_CLEAN_PUSHED_BRANCHES="${_WT_CLEAN_PUSHED_BRANCHES:-}"
_WT_CLEAN_REMOTE_BRANCHES="${_WT_CLEAN_REMOTE_BRANCHES:-}"
_WT_CLEAN_REMOTE_BRANCH_CACHE_READY="${_WT_CLEAN_REMOTE_BRANCH_CACHE_READY:-false}"
_WT_CLEAN_REMOTE_DEFAULT_REF="${_WT_CLEAN_REMOTE_DEFAULT_REF:-}"
_WT_CLEAN_EXACT_PR_PREFETCH_COMPLETE="${_WT_CLEAN_EXACT_PR_PREFETCH_COMPLETE:-false}"
_WT_CLEAN_TYPE_SQUASH_MERGED_PR="squash-merged PR"
_WT_CLEAN_TYPE_CLOSED_PR="closed PR"
_WT_CLEAN_TYPE_REMOTE_TRACKING_MERGED="merged remote-tracking default"
_WT_CLEAN_PROOF_GH_MERGED_PR="github-merged-pr"
_WT_CLEAN_PROOF_GH_MERGED_PR_STATE="github-merged-pr-state"
_WT_CLEAN_PROOF_REMOTE_TRACKING_DEFAULT="remote-tracking-default-is-ancestor"
_WT_CLEAN_PROOF_REMOTE_TRACKING_RESULT="merged-remote-tracking-default"
_WT_CLEAN_PROOF_NOT_ANCESTOR="not-ancestor"
_WT_CLEAN_REASON_BRANCH_MERGED="branch-merged"
_WT_CLEAN_REASON_PR_PROOF_UNKNOWN="unknown:pr-proof-unavailable"
_WT_CLEAN_REASON_PROTECTED_PASS="protected-pass-skip"
_WT_CLEAN_REASON_CLOSED_ISSUE_ARCHIVE="closed-issue-branch-preserved"
_WT_CLEAN_TYPE_CLOSED_ISSUE_ARCHIVE="closed issue branch archive"
_WT_CLEAN_MODE_SKIPPED="skipped"
_WT_CLEAN_MODE_BRANCH_PRESERVED="branch-preserved"
_WT_CLEAN_MODE_PERMANENT="permanent"
_WT_CLEAN_MODE_RECOVERABLE="recoverable-trash"
_WT_CLEAN_MODE_PARTIAL="partial-cleanup"
_WT_CLEAN_COMPLETED_EVENT="AIDEVOPS_WORKTREE_REMOVAL_COMPLETED=1"
_WT_CLEAN_BOOL_TRUE=true
_WT_CLEAN_BOOL_FALSE=false
_WT_CLEAN_OUTCOME_SKIPPED="skipped"
_WT_CLEAN_OUTCOME_FAILED="failed"
_WT_CLEAN_OUTCOME_REMOVED="removed"
_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_SKIPPED"
_WT_CLEAN_STASH_ARCHIVE_SEQUENCE=0
_WT_CLEAN_LAST_PRESERVE_BRANCH="${_WT_CLEAN_LAST_PRESERVE_BRANCH:-$_WT_CLEAN_BOOL_FALSE}"

_clean_protected_mark() {
	local wt_path="$1"
	[[ -z "$wt_path" ]] && return 0
	case $'\n'"$_WT_CLEAN_PROTECTED_PATHS"$'\n' in
	*$'\n'"$wt_path"$'\n'*) ;;
	*) _WT_CLEAN_PROTECTED_PATHS="${_WT_CLEAN_PROTECTED_PATHS}${wt_path}"$'\n' ;;
	esac
	return 0
}

_clean_protected_contains() {
	local wt_path="$1"
	[[ -z "$wt_path" ]] && return 1
	case $'\n'"$_WT_CLEAN_PROTECTED_PATHS"$'\n' in
	*$'\n'"$wt_path"$'\n'*) return 0 ;;
	esac
	return 1
}

_clean_branch_head() {
	local wt_branch="$1"
	git rev-parse --verify "refs/heads/${wt_branch}" 2>/dev/null
	return $?
}

_clean_branch_merge_proof_context() {
	local wt_branch="$1"
	local default_br="$2"
	local head_sha="${3:-unknown}"
	local proof_result="${4:-unknown}"
	local proof_method="${5:-merge-base-is-ancestor}"
	printf 'target_branch=%s merge_proof=%s merge_proof_result=%s head=%s branch=%s owner_guard=clear protected_status=clear' \
		"$default_br" "$proof_method" "$proof_result" "$head_sha" "$wt_branch"
	return 0
}

_clean_issue_from_branch() {
	local wt_branch="$1"
	if [[ "$wt_branch" =~ gh[-]?([0-9]+) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ "$wt_branch" =~ (^|/)fix/([0-9]{3,})([-/]|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return 0
	fi
	if [[ "$wt_branch" =~ (^|[-/])t([0-9]+)([-/]|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

_clean_issue_is_closed() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_state

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" ]] || return 1
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state // empty' 2>/dev/null) || return 1
	[[ "$issue_state" == "CLOSED" ]] || return 1
	return 0
}

_clean_archive_dirty_worktree_stash() {
	local wt_path="$1"
	local wt_branch="$2"
	local archive_token=""
	local candidate_oid=""
	local candidate_subject=""
	local match_count=0
	local stash_entries=""
	local stash_oid=""
	if ! worktree_has_changes "$wt_path"; then
		return 0
	fi
	_WT_CLEAN_STASH_ARCHIVE_SEQUENCE=$((_WT_CLEAN_STASH_ARCHIVE_SEQUENCE + 1))
	archive_token="aidevops-stash-archive:$$:${_WT_CLEAN_STASH_ARCHIVE_SEQUENCE}:${RANDOM}"
	git -C "$wt_path" stash push -u \
		-m "aidevops worktree cleanup archive [${archive_token}]: ${wt_branch:-detached}" \
		>/dev/null 2>&1 || return 1
	stash_entries=$(git -C "$wt_path" stash list --format='%H%x09%gs' 2>/dev/null) || return 1
	while IFS=$'\t' read -r candidate_oid candidate_subject; do
		case "$candidate_subject" in
		*"$archive_token"*)
			stash_oid="$candidate_oid"
			match_count=$((match_count + 1))
			;;
		esac
	done <<<"$stash_entries"
	[[ "$match_count" -eq 1 && -n "$stash_oid" ]] || return 1
	git -C "$wt_path" cat-file -e "${stash_oid}^{commit}" 2>/dev/null || return 1
	# Keep the immutable stash while restoring the exact dirty worktree before
	# final native Git removal. If a preservation lock wins, the surviving
	# worktree retains its tracked, staged, and untracked files.
	git -C "$wt_path" stash apply --index "$stash_oid" >/dev/null 2>&1 || return 1
	return 0
}

_clean_remove_preserving_branch() {
	local wt_path="$1"
	local wt_branch="$2"
	local audit_context="$3"

	_clean_archive_dirty_worktree_stash "$wt_path" "$wt_branch" || return 1
	worktree_removal_guard "$wt_path" "$_WTAR_WH_CALLER" \
		"$_WT_CLEAN_REASON_CLOSED_ISSUE_ARCHIVE" || return 1
	_worktree_remove_with_native_git "$wt_path" "$_WTAR_WH_CALLER" "$audit_context" "true" || return 1
	return 0
}

_clean_closed_issue_archive_allowed() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local open_prs="$4"
	local issue_number
	local repo_slug

	_clean_branch_list_contains_exact "$wt_branch" "$open_prs" && return 1
	local current_dir=""
	current_dir=$(pwd -P 2>/dev/null || true)
	case "$current_dir" in
	"$wt_path" | "$wt_path"/*) return 1 ;;
	esac
	_branch_has_active_interactive_claim "$wt_path" "$wt_branch" && return 1
	is_worktree_owned_by_others "$wt_path" && return 1
	issue_number=$(_clean_issue_from_branch "$wt_branch" 2>/dev/null) || return 1
	repo_slug=$(_clean_repo_slug 2>/dev/null || true)
	_clean_issue_is_closed "$issue_number" "$repo_slug" || return 1
	printf '%s\n' "$issue_number"
	return 0
}

_clean_skip_unknown_pr_proof() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local head_sha="$4"
	local unknown_context
	local audit_context

	unknown_context=$(_clean_pr_proof_unknown_context) || return 1
	audit_context=$(_clean_branch_merge_proof_context "$wt_branch" "$default_br" "$head_sha" "$_WT_CLEAN_REASON_PR_PROOF_UNKNOWN" "github-pr-state")
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "$_WT_CLEAN_REASON_PR_PROOF_UNKNOWN" "$_WT_CLEAN_MODE_SKIPPED" "${audit_context} unknown_reasons=${unknown_context}"
	return 0
}

_clean_branch_requires_ancestor_proof() {
	local merge_type="$1"

	case "$merge_type" in
	"$_WT_CLEAN_TYPE_SQUASH_MERGED_PR" | "$_WT_CLEAN_TYPE_CLOSED_PR")
		# GitHub squash merges intentionally create a new target-branch commit,
		# and abandoned closed PRs are not expected to reach the default branch.
		# In both cases, GitHub PR state is the proof source rather than ancestry.
		return 1
		;;
	esac
	return 0
}

_clean_branch_head_is_ancestor() {
	local wt_branch="$1"
	local default_br="$2"
	local head_sha
	head_sha=$(_clean_branch_head "$wt_branch") || return 1
	git merge-base --is-ancestor "$head_sha" "$default_br" 2>/dev/null
	return $?
}

_clean_resolve_merge_proof() {
	local wt_branch="$1"
	local default_br="$2"
	local merge_type="$3"
	local merged_prs="$4"

	if ! _clean_branch_requires_ancestor_proof "$merge_type"; then
		printf '%s\t%s\n' "$merge_type" "$_WT_CLEAN_PROOF_GH_MERGED_PR"
		return 0
	fi
	if [[ "$merge_type" == "$_WT_CLEAN_TYPE_REMOTE_TRACKING_MERGED" ]]; then
		_clean_resolve_remote_tracking_proof "$wt_branch" "$default_br" "$merge_type"
		return $?
	fi
	if _clean_branch_head_is_ancestor "$wt_branch" "$default_br"; then
		printf '%s\t%s\n' "$merge_type" "ancestor"
		return 0
	fi
	if _clean_branch_has_exact_merged_pr "$wt_branch" "$merged_prs"; then
		printf '%s\t%s\n' "$_WT_CLEAN_TYPE_SQUASH_MERGED_PR" "$_WT_CLEAN_PROOF_GH_MERGED_PR"
		return 0
	fi

	printf '%s\t%s\n' "$merge_type" "$_WT_CLEAN_PROOF_NOT_ANCESTOR"
	return 1
}

_clean_resolve_remote_tracking_proof() {
	local wt_branch="$1"
	local default_br="$2"
	local merge_type="$3"

	if _clean_branch_is_remote_default_contained "$wt_branch" "$default_br"; then
		printf '%s\t%s\n' "$merge_type" "$_WT_CLEAN_PROOF_REMOTE_TRACKING_RESULT"
		return 0
	fi
	printf '%s\t%s\n' "$merge_type" "$_WT_CLEAN_PROOF_NOT_ANCESTOR"
	return 1
}

_clean_select_merge_type() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local remote_unknown="$4"
	local merged_prs="$5"
	local closed_prs="$6"

	if _clean_branch_is_locally_merged "$wt_branch" "$default_br" &&
		! branch_has_zero_commits_ahead "$wt_branch" "$default_br"; then
		printf '%s\n' "merged"
		return 0
	fi
	# Remote-tracking default proof is used specifically when the local default
	# branch is stale. Keep it stricter than legacy --force-merged cleanup: dirty
	# worktrees are preserved because remote containment alone says nothing about
	# uncommitted local WIP.
	if _clean_branch_is_remote_default_contained "$wt_branch" "$default_br" &&
		! worktree_has_changes "$wt_path"; then
		printf '%s\n' "$_WT_CLEAN_TYPE_REMOTE_TRACKING_MERGED"
		return 0
	fi
	if _clean_branch_has_exact_merged_pr "$wt_branch" "$merged_prs"; then
		printf '%s\n' "$_WT_CLEAN_TYPE_SQUASH_MERGED_PR"
		return 0
	fi
	if _clean_branch_list_contains_exact "$wt_branch" "$closed_prs"; then
		printf '%s\n' "$_WT_CLEAN_TYPE_CLOSED_PR"
		return 0
	fi
	if [[ "$remote_unknown" == "false" ]] && _clean_branch_was_pushed_cached "$wt_branch" && ! _clean_branch_exists_on_remote_cached "$wt_branch"; then
		printf '%s\n' "remote deleted"
		return 0
	fi
	return 1
}

# Determine if a worktree entry is merged, and print it if so.
# Args: $1=wt_path, $2=wt_branch, $3=default_branch, $4=remote_state_unknown,
#       $5=merged_pr_branches, $6=open_pr_branches, $7=force_merged,
#       $8=closed_pr_branches
# Outputs merge_type<TAB>audit_context to stdout if safely merged.
_clean_classify_worktree() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local remote_unknown="$4"
	local merged_prs="$5"
	local open_prs="$6"
	local force_merged="$7"
	local closed_prs="${8:-}"

	local merge_type=""
	local head_sha="unknown"
	local proof_result="unavailable"
	local audit_context=""
	_WT_CLEAN_LAST_MERGE_TYPE=""
	_WT_CLEAN_LAST_AUDIT_CONTEXT=""
	_WT_CLEAN_LAST_PRESERVE_BRANCH="$_WT_CLEAN_BOOL_FALSE"

	if _clean_protected_contains "$wt_path" &&
		! _clean_branch_has_terminal_pr_proof "$wt_branch" "$merged_prs" "$closed_prs"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "$_WT_CLEAN_REASON_PROTECTED_PASS" "$_WT_CLEAN_MODE_SKIPPED" \
			"branch=$wt_branch target_branch=$default_br owner_guard=protected protected_status=pass-local"
		return 0
	fi

	if ! merge_type=$(_clean_select_merge_type "$wt_path" "$wt_branch" "$default_br" "$remote_unknown" "$merged_prs" "$closed_prs"); then
		return 0
	fi

	head_sha=$(_clean_branch_head "$wt_branch" 2>/dev/null || printf '%s' "unknown")
	local proof_pair
	if proof_pair=$(_clean_resolve_merge_proof "$wt_branch" "$default_br" "$merge_type" "$merged_prs"); then
		IFS=$'\t' read -r merge_type proof_result <<<"$proof_pair"
	else
		IFS=$'\t' read -r merge_type proof_result <<<"$proof_pair"
		proof_result="$_WT_CLEAN_PROOF_NOT_ANCESTOR"
		if _clean_skip_unknown_pr_proof "$wt_path" "$wt_branch" "$default_br" "$head_sha"; then
			return 0
		fi
		local closed_issue_number
		if closed_issue_number=$(_clean_closed_issue_archive_allowed "$wt_path" "$wt_branch" "$default_br" "$open_prs"); then
			merge_type="$_WT_CLEAN_TYPE_CLOSED_ISSUE_ARCHIVE"
			audit_context=$(_clean_branch_merge_proof_context "$wt_branch" "$default_br" "$head_sha" "$proof_result")
			audit_context="${audit_context} issue=${closed_issue_number} recovery_path=branch-preserved-closed-issue"
			_WT_CLEAN_LAST_MERGE_TYPE="$merge_type"
			_WT_CLEAN_LAST_AUDIT_CONTEXT="$audit_context"
			_WT_CLEAN_LAST_PRESERVE_BRANCH="$_WT_CLEAN_BOOL_TRUE"
			printf '%s\t%s\n' "$merge_type" "$audit_context"
			return 0
		fi
		audit_context=$(_clean_branch_merge_proof_context "$wt_branch" "$default_br" "$head_sha" "$proof_result")
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "branch-merged-unproven" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
		return 0
	fi

	# Terminal PR/closed-issue proof means the worktree is no longer active work.
	# Keep hard current/canonical/process-cwd guards, but do not let stale owner,
	# protected-pass, grace, or dirty markers preserve terminal clutter forever.
	if _clean_merge_type_has_terminal_pr_proof "$merge_type" ||
		_clean_branch_has_terminal_pr_proof "$wt_branch" "$merged_prs" "$closed_prs"; then
		_clean_terminal_owner_blocks_cleanup "$wt_path" && return 0
		_skip_cleanup_for_current_worktree "$wt_path" "$wt_branch" && return 0
	else
		# Apply safety checks using shared helper
		if should_skip_cleanup "$wt_path" "$wt_branch" "$default_br" "$open_prs" "$force_merged"; then
			_clean_protected_mark "$wt_path"
			return 0
		fi
	fi

	if [[ "$merge_type" == "$_WT_CLEAN_TYPE_REMOTE_TRACKING_MERGED" ]]; then
		audit_context=$(_clean_branch_merge_proof_context "$wt_branch" "$default_br" "$head_sha" "$proof_result" "$_WT_CLEAN_PROOF_REMOTE_TRACKING_DEFAULT")
	elif _clean_branch_requires_ancestor_proof "$merge_type"; then
		audit_context=$(_clean_branch_merge_proof_context "$wt_branch" "$default_br" "$head_sha" "$proof_result")
	else
		audit_context=$(_clean_branch_merge_proof_context "$wt_branch" "$default_br" "$head_sha" "$proof_result" "$_WT_CLEAN_PROOF_GH_MERGED_PR_STATE")
	fi

	if [[ "$merge_type" == "remote deleted" ]]; then
		if _clean_skip_unknown_pr_proof "$wt_path" "$wt_branch" "$default_br" "$head_sha"; then
			return 0
		fi
	fi

	if worktree_has_changes "$wt_path" && [[ "$force_merged" == "true" ]]; then
		# PR is confirmed merged — dirty state is abandoned WIP, safe to force-remove
		merge_type="$merge_type, dirty (force)"
	fi

	_WT_CLEAN_LAST_MERGE_TYPE="$merge_type"
	_WT_CLEAN_LAST_AUDIT_CONTEXT="$audit_context"
	printf '%s\t%s\n' "$merge_type" "$audit_context"
	return 0
}

# Scan worktrees and print those eligible for cleanup. Returns 0 if any found, 1 if none.
# Args: $1=default_branch, $2=main_worktree_path, $3=remote_state_unknown,
#       $4=merged_pr_branches, $5=open_pr_branches, $6=force_merged,
#       $7=closed_pr_branches
_clean_scan_merged() {
	local default_br="$1"
	local main_wt_path="$2"
	local remote_unknown="$3"
	local merged_prs="$4"
	local open_prs="$5"
	local force_merged="$6"
	local closed_prs="${7:-}"

	local found_any=false
	local worktree_path=""
	local worktree_branch=""

	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			worktree_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			worktree_branch="${BASH_REMATCH[1]}"
		elif [[ -z "$line" ]]; then
			if [[ -n "$worktree_branch" ]] && [[ "$worktree_branch" != "$default_br" ]] && [[ "$worktree_path" != "$main_wt_path" ]]; then
				local merge_type
				_clean_classify_worktree "$worktree_path" "$worktree_branch" "$default_br" "$remote_unknown" "$merged_prs" "$open_prs" "$force_merged" "$closed_prs" >/dev/null
				merge_type="$_WT_CLEAN_LAST_MERGE_TYPE"
				if [[ -n "$merge_type" ]]; then
					found_any=true
					echo -e "  ${YELLOW}$worktree_branch${NC} ($merge_type)" >&2
					echo "    $worktree_path" >&2
					echo "" >&2
				fi
			fi
			worktree_path=""
			worktree_branch=""
		fi
	done < <(
		git worktree list --porcelain
		echo ""
	)

	[[ "$found_any" == "true" ]] && return 0
	return 1
}

# Copy a worktree to recoverable trash before any source removal. This is the
# only physical-removal preparation permitted when process-CWD visibility is
# degraded, so interruption or a late lock always leaves a recoverable copy.
_clean_archive_worktree_recoverably() {
	local worktree_path="$1"
	local caller="${2:-${_WTAR_WH_CALLER:-worktree-helper.sh}}"
	_WT_CLEAN_RECOVERABLE_FAILURE_DETAIL=""
	_WT_CLEAN_RECOVERABLE_ARCHIVE_PATH=""

	[[ -n "$worktree_path" ]] || return 1
	if [[ ! -e "$worktree_path" && ! -L "$worktree_path" ]]; then
		_WT_CLEAN_RECOVERABLE_FAILURE_DETAIL="path-already-gone"
		return 0
	fi
	if ! archive_worktree_path_recoverably "$worktree_path" "$caller" \
		"recoverable-cleanup"; then
		_WT_CLEAN_RECOVERABLE_FAILURE_DETAIL="archive-copy-failed"
		return 1
	fi
	_WT_CLEAN_RECOVERABLE_ARCHIVE_PATH="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	return 0
}

_clean_merge_type_has_terminal_pr_state() {
	local merge_type="$1"
	case "$merge_type" in
	"$_WT_CLEAN_TYPE_SQUASH_MERGED_PR" | "$_WT_CLEAN_TYPE_CLOSED_PR") return 0 ;;
	esac
	return 1
}

# A degraded process snapshot can authorize only a candidate-local recoverable
# move. Every mutable predicate is rechecked after the cleanup lease is held.
_clean_degraded_visibility_fallback_allowed() {
	local worktree_path="$1"
	local worktree_branch="$2"
	local merge_type="$3"
	local merged_prs="$4"
	local closed_prs="$5"
	local open_prs="$6"
	local audit_context="$7"
	local default_br="$8"

	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "${_WT_CWD_REASON_DEGRADED:-cwd-visibility-degraded}" ]] || return 1
	_clean_worktree_index_is_readable "$worktree_path" "$worktree_branch" "$audit_context" || return 1
	if worktree_has_changes "$worktree_path"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "degraded-cwd-dirty-skip" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
		return 1
	fi
	if _branch_has_active_interactive_claim "$worktree_path" "$worktree_branch"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "active-claim" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
		return 1
	fi
	if ! _clean_has_exact_removal_lease "$worktree_path"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "$_WT_CLEAN_REASON_OWNED_SKIP" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
		return 1
	fi
	if _clean_branch_list_contains_exact "$worktree_branch" "$open_prs"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "open-pr" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
		return 1
	fi
	if worktree_is_in_grace_period "$worktree_path"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "grace-period" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
		return 1
	fi
	if _clean_merge_type_has_terminal_pr_state "$merge_type" ||
		_clean_branch_has_terminal_pr_proof "$worktree_branch" "$merged_prs" "$closed_prs"; then
		return 0
	fi
	if [[ "$merge_type" == "$_WT_CLEAN_TYPE_REMOTE_TRACKING_MERGED" ]] &&
		_clean_branch_is_remote_default_contained "$worktree_branch" "$default_br"; then
		return 0
	fi
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "degraded-cwd-pr-proof-required" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
	return 1
}

_clean_remove_recoverably_after_lease() {
	local worktree_path="$1"
	local audit_context="$2"
	local recoverable_archive=""

	if ! _clean_archive_worktree_recoverably "$worktree_path"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" \
			"recoverable-archive-failed" "$_WT_CLEAN_MODE_SKIPPED" \
			"$audit_context recoverable_backends=${_WT_CLEAN_RECOVERABLE_FAILURE_DETAIL:-unknown}"
		_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_FAILED"
		return 1
	fi
	recoverable_archive="$_WT_CLEAN_RECOVERABLE_ARCHIVE_PATH"
	if [[ -z "$recoverable_archive" && ! -e "$worktree_path" && ! -L "$worktree_path" ]]; then
		return 0
	fi
	if ! _clean_has_exact_removal_lease "$worktree_path"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" \
			"cleanup-lease-changed-after-archive" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
		_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_FAILED"
		return 1
	fi
	if ! remove_archived_worktree_path "$worktree_path" "$recoverable_archive" \
		"$_WTAR_WH_CALLER" "$_WT_CLEAN_REASON_BRANCH_MERGED" "$audit_context" \
		"$_WT_CLEAN_BOOL_TRUE" "$_WT_CLEAN_BOOL_FALSE"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" \
			"recoverable-remove-failed" "$_WT_CLEAN_MODE_SKIPPED" "$audit_context"
		_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_FAILED"
		return 1
	fi
	return 0
}

_clean_worktree_index_is_readable() {
	local worktree_path="$1"
	local worktree_branch="$2"
	local audit_context="$3"

	if GIT_OPTIONAL_LOCKS=0 git -C "$worktree_path" status --porcelain >/dev/null 2>&1; then
		return 0
	fi
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" \
		"unreadable-git-state" "$_WT_CLEAN_MODE_SKIPPED" \
		"branch=${worktree_branch:-detached} $audit_context"
	echo -e "${YELLOW}Skipped $worktree_branch - Git index/state is unreadable${NC}" >&2
	return 1
}

_clean_remove_classified_worktree() {
	local worktree_path="$1"
	local worktree_branch="$2"
	local force_merged="$3"
	local preserve_branch="$4"
	local audit_context="$5"
	local repo_context="$6"
	local removal_mode="${7:-$_WT_CLEAN_MODE_PERMANENT}"
	local recovery_authorized="${8:-$_WT_CLEAN_BOOL_FALSE}"
	local use_force="$_WT_CLEAN_BOOL_FALSE"
	local removed="$_WT_CLEAN_BOOL_FALSE"
	local guard_status=0
	local audit_reason="$_WT_CLEAN_REASON_BRANCH_MERGED"
	local completed_mode="$_WT_CLEAN_MODE_PERMANENT"
	_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_SKIPPED"

	if worktree_removal_guard "$worktree_path" "$_WTAR_WH_CALLER" "$_WT_CLEAN_REASON_BRANCH_MERGED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	if [[ "$removal_mode" == "$_WT_CLEAN_MODE_RECOVERABLE" ]]; then
		[[ "$recovery_authorized" == "$_WT_CLEAN_BOOL_TRUE" ]] || return 1
		if [[ "$guard_status" -ne 0 && "$guard_status" -ne "${_WT_CWD_CAPTURE_DEGRADED_RC:-2}" ]]; then
			return 1
		fi
	elif [[ "$guard_status" -ne 0 ]]; then
		return "$guard_status"
	fi
	_clean_worktree_index_is_readable "$worktree_path" "$worktree_branch" "$audit_context" || return 1
	if [[ "$removal_mode" == "$_WT_CLEAN_MODE_RECOVERABLE" ]]; then
		worktree_has_changes "$worktree_path" && return 1
		_branch_has_active_interactive_claim "$worktree_path" "$worktree_branch" && return 1
		_clean_has_exact_removal_lease "$worktree_path" || return 1
	fi

	if worktree_has_changes "$worktree_path" && [[ "$force_merged" == "$_WT_CLEAN_BOOL_TRUE" ]]; then
		use_force="$_WT_CLEAN_BOOL_TRUE"
	fi
	if [[ "$removal_mode" == "$_WT_CLEAN_MODE_RECOVERABLE" ]]; then
		_clean_remove_recoverably_after_lease "$worktree_path" "$audit_context" || return 1
		removed="$_WT_CLEAN_BOOL_TRUE"
		completed_mode="$_WT_CLEAN_MODE_RECOVERABLE"
	elif [[ "$preserve_branch" == "$_WT_CLEAN_BOOL_TRUE" ]]; then
		if _clean_remove_preserving_branch "$worktree_path" "$worktree_branch" "$audit_context"; then
			removed="$_WT_CLEAN_BOOL_TRUE"
			audit_reason="$_WT_CLEAN_REASON_CLOSED_ISSUE_ARCHIVE"
			completed_mode="$_WT_CLEAN_MODE_BRANCH_PRESERVED"
		fi
	else
		local remove_flag=""
		if [[ "$use_force" == "$_WT_CLEAN_BOOL_TRUE" ]]; then
			remove_flag="--force"
		fi
		# Git is the final physical-removal authority. A concurrent lock makes
		# this command fail; cleanup never falls back to direct rm.
		# shellcheck disable=SC2086
		if git worktree remove $remove_flag "$worktree_path" 2>/dev/null; then
			removed="$_WT_CLEAN_BOOL_TRUE"
		fi
	fi
	if [[ "$removed" != "$_WT_CLEAN_BOOL_TRUE" ]]; then
		_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_FAILED"
		echo -e "${RED}Failed to remove $worktree_branch - may have uncommitted changes${NC}" >&2
		return 1
	fi
	if ! prune_missing_worktree_metadata "$repo_context" "$worktree_path"; then
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" \
			"metadata-prune-failed" "$_WT_CLEAN_MODE_PARTIAL" "$audit_context"
		_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_FAILED"
		return 1
	fi
	_clean_release_removal_lease "$worktree_path" || true
	if [[ "$preserve_branch" != "$_WT_CLEAN_BOOL_TRUE" ]]; then
		localdev_auto_branch_rm "$worktree_branch"
		git branch -D "$worktree_branch" 2>/dev/null || true
	fi
	log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_WH_CALLER" "$worktree_path" "$audit_reason" "$completed_mode" "$audit_context"
	if declare -F full_loop_mark_cleanup_cleaned_for_worktree >/dev/null 2>&1; then
		full_loop_mark_cleanup_cleaned_for_worktree "$worktree_path" || true
	fi
	printf '%s\n' "$_WT_CLEAN_COMPLETED_EVENT"
	_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_REMOVED"
	return 0
}

_clean_remove_candidate_after_lease() {
	local worktree_path="$1"
	local worktree_branch="$2"
	local force_merged="$3"
	local preserve_branch="$4"
	local audit_context="$5"
	local main_wt_path="$6"
	local merge_type="$7"
	local merged_prs="$8"
	local closed_prs="$9"
	local open_prs="${10}"
	local default_br="${11}"
	local guard_status=0
	local removal_status=0
	local removal_mode="$_WT_CLEAN_MODE_PERMANENT"
	local recovery_authorized="$_WT_CLEAN_BOOL_FALSE"
	_WT_CLEAN_LAST_REMOVAL_OUTCOME="$_WT_CLEAN_OUTCOME_SKIPPED"

	if worktree_removal_guard "$worktree_path" "$_WTAR_WH_CALLER" "$_WT_CLEAN_REASON_BRANCH_MERGED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	if [[ "$guard_status" -eq "${_WT_CWD_CAPTURE_DEGRADED_RC:-2}" ]] &&
		_clean_degraded_visibility_fallback_allowed "$worktree_path" "$worktree_branch" "$merge_type" "$merged_prs" "$closed_prs" "$open_prs" "$audit_context" "$default_br"; then
		removal_mode="$_WT_CLEAN_MODE_RECOVERABLE"
		recovery_authorized="$_WT_CLEAN_BOOL_TRUE"
	elif [[ "$guard_status" -ne 0 ]]; then
		_clean_release_removal_lease "$worktree_path" || true
		echo -e "${YELLOW}Skipped $worktree_branch - removal guard refused path${NC}" >&2
		return 1
	fi

	if _clean_remove_classified_worktree "$worktree_path" "$worktree_branch" "$force_merged" "$preserve_branch" "$audit_context" "$main_wt_path" "$removal_mode" "$recovery_authorized"; then
		return 0
	else
		removal_status=$?
	fi
	if [[ "$removal_status" -eq "${_WT_CWD_CAPTURE_DEGRADED_RC:-2}" ]] &&
		_clean_degraded_visibility_fallback_allowed "$worktree_path" "$worktree_branch" "$merge_type" "$merged_prs" "$closed_prs" "$open_prs" "$audit_context" "$default_br" &&
		_clean_remove_classified_worktree "$worktree_path" "$worktree_branch" "$force_merged" "$preserve_branch" "$audit_context" "$main_wt_path" "$_WT_CLEAN_MODE_RECOVERABLE" "$_WT_CLEAN_BOOL_TRUE"; then
		return 0
	fi
	_clean_release_removal_lease "$worktree_path" || true
	return 1
}

# Remove worktrees that are eligible for cleanup (second pass after user confirmation).
# Args: $1=default_branch, $2=main_worktree_path, $3=remote_state_unknown,
#       $4=merged_pr_branches, $5=open_pr_branches, $6=force_merged,
#       $7=closed_pr_branches
_clean_remove_merged() {
	local default_br="$1"
	local main_wt_path="$2"
	local remote_unknown="$3"
	local merged_prs="$4"
	local open_prs="$5"
	local force_merged="$6"
	local closed_prs="${7:-}"

	local worktree_path=""
	local worktree_branch=""
	local removal_failures=0

	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			worktree_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			worktree_branch="${BASH_REMATCH[1]}"
		elif [[ -z "$line" ]]; then
			if [[ -n "$worktree_branch" ]] && [[ "$worktree_branch" != "$default_br" ]] && [[ "$worktree_path" != "$main_wt_path" ]]; then
				if _clean_protected_contains "$worktree_path" &&
					! _clean_branch_has_terminal_pr_proof "$worktree_branch" "$merged_prs" "$closed_prs"; then
					log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "$_WT_CLEAN_REASON_PROTECTED_PASS" "$_WT_CLEAN_MODE_SKIPPED" \
						"branch=$worktree_branch target_branch=$default_br owner_guard=protected protected_status=pass-local"
					worktree_path=""
					worktree_branch=""
					continue
				fi
				local merge_type
				local audit_context
				_clean_classify_worktree "$worktree_path" "$worktree_branch" "$default_br" "$remote_unknown" "$merged_prs" "$open_prs" "$force_merged" "$closed_prs" >/dev/null
				merge_type="$_WT_CLEAN_LAST_MERGE_TYPE"
				audit_context="$_WT_CLEAN_LAST_AUDIT_CONTEXT"
				local preserve_branch="$_WT_CLEAN_LAST_PRESERVE_BRANCH"
				if [[ -n "$merge_type" ]]; then
					echo -e "${BLUE}Removing $worktree_branch...${NC}" >&2
					if _clean_protected_contains "$worktree_path" &&
						! _clean_branch_has_terminal_pr_proof "$worktree_branch" "$merged_prs" "$closed_prs"; then
						log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "$_WT_CLEAN_REASON_PROTECTED_PASS" "$_WT_CLEAN_MODE_SKIPPED" \
							"branch=$worktree_branch target_branch=$default_br owner_guard=protected protected_status=pass-local"
						echo -e "${YELLOW}Skipped $worktree_branch - protected earlier in this cleanup pass${NC}" >&2
						worktree_path=""
						worktree_branch=""
						continue
					fi
					if is_worktree_owned_by_others "$worktree_path"; then
						log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "$_WT_CLEAN_REASON_OWNED_SKIP" "$_WT_CLEAN_MODE_SKIPPED"
						echo -e "${YELLOW}Skipped $worktree_branch - worktree was reclaimed before removal${NC}" >&2
						worktree_path=""
						worktree_branch=""
						continue
					fi
					if ! _clean_acquire_removal_lease "$worktree_path" "$worktree_branch"; then
						log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$worktree_path" "cleanup-lease-skip" "$_WT_CLEAN_MODE_SKIPPED"
						echo -e "${YELLOW}Skipped $worktree_branch - cleanup lease was not acquired${NC}" >&2
						worktree_path=""
						worktree_branch=""
						continue
					fi
					if ! _clean_remove_candidate_after_lease "$worktree_path" "$worktree_branch" "$force_merged" "$preserve_branch" \
						"$audit_context" "$main_wt_path" "$merge_type" "$merged_prs" "$closed_prs" "$open_prs" "$default_br"; then
						if [[ "$_WT_CLEAN_LAST_REMOVAL_OUTCOME" == "$_WT_CLEAN_OUTCOME_FAILED" ]]; then
							removal_failures=$((removal_failures + 1))
						fi
					fi
				fi
			fi
			worktree_path=""
			worktree_branch=""
		fi
	done < <(
		git worktree list --porcelain
		echo ""
	)

	[[ "$removal_failures" -eq 0 ]] || return 1
	return 0
}

# Clean up worktrees whose branches have been merged, remote-deleted, or squash-merged.
# Supports --auto (non-interactive) and --force-merged (skip confirmation for merged).
# Safety checks (GH#5694):
#   - Grace period: worktrees younger than WORKTREE_CLEAN_GRACE_HOURS (default 4h) are skipped
#   - Open PR check: worktrees with an open PR are skipped (active work in progress)
#   - Zero-commit + dirty check: branch with 0 commits ahead AND dirty files = in-progress, not merged
# t2559: preflight guard for cmd_clean. Combines L1 (empty-derivation),
# L2 (sane main-worktree-path), and L3 (git-in-PATH) into a single entry point.
# On success, prints the validated main_worktree_path to stdout and returns 0.
# On any failure, prints the reason to stderr and returns 1 so cmd_clean can
# refuse to touch any filesystem state.
#
# Extracted to keep cmd_clean body under the 100-line complexity threshold
# while preserving all four defensive layers from the 2026-04-20 incident.
_clean_preflight_main_worktree() {
	# L3: refuse to run cleanup at all if git is missing from PATH.
	# Without git, the worktree-list derivation below returns empty, and the
	# downstream `[[ "$worktree_path" != "$main_wt_path" ]]` guard reduces to
	# "!= empty" — always true for real paths — and canonical gets swept.
	if command -v assert_git_available >/dev/null 2>&1; then
		if ! assert_git_available; then
			echo -e "${RED}Refusing worktree cleanup — git not in PATH${NC}" >&2
			return 1
		fi
	fi

	# L1: derive main worktree path from porcelain; fail loud on empty output.
	# The first entry in `git worktree list --porcelain` is always the main
	# worktree. Avoid piping through head — with set -o pipefail and many
	# worktrees, head closes the pipe early → git SIGPIPE (exit 141) →
	# pipefail → set -e abort.
	if ! git rev-parse --git-dir >/dev/null 2>&1; then
		echo -e "${YELLOW}Warning: skipping worktree cleanup — current directory is not a git repository${NC}" >&2
		return 1
	fi

	local _porcelain main_worktree_path
	_porcelain=$(git worktree list --porcelain 2>/dev/null)
	if [[ -z "$_porcelain" ]]; then
		echo -e "${RED}FATAL: 'git worktree list --porcelain' returned empty — refusing cleanup${NC}" >&2
		return 1
	fi
	main_worktree_path="${_porcelain%%$'\n'*}"           # first line
	main_worktree_path="${main_worktree_path#worktree }" # strip prefix

	# L2: validate the extracted path is sane (non-empty, absolute) before
	# handing it to cleanup loops as the "never trash this" anchor.
	if command -v assert_main_worktree_sane >/dev/null 2>&1; then
		if ! assert_main_worktree_sane "$main_worktree_path"; then
			echo -e "${RED}Refusing worktree cleanup — main_worktree_path derivation is not sane${NC}" >&2
			return 1
		fi
	elif [[ -z "$main_worktree_path" || "${main_worktree_path:0:1}" != "/" ]]; then
		# Fallback when canonical-guard-helper is missing: still refuse to run.
		echo -e "${RED}FATAL: derived main_worktree_path is empty or non-absolute: '$main_worktree_path'${NC}" >&2
		return 1
	fi

	printf '%s\n' "$main_worktree_path"
	return 0
}

cmd_clean() {
	local auto_mode=false
	local force_merged=false
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--auto) auto_mode=true ;;
		--force-merged) force_merged=true ;;
		*) break ;;
		esac
		shift
	done

	# t2559: run the combined L1+L2+L3 preflight. On any refusal, bail before
	# touching filesystem state. This is the primary defence against the
	# 2026-04-20 canonical-trash incident (see _clean_preflight_main_worktree).
	local main_worktree_path
	if ! main_worktree_path=$(_clean_preflight_main_worktree); then
		return 1
	fi
	if declare -F full_loop_reconcile_cleanup_receipts >/dev/null 2>&1; then
		full_loop_reconcile_cleanup_receipts
	fi

	echo -e "${BOLD}Checking for worktrees with merged branches...${NC}" >&2
	echo "" >&2

	local default_branch
	default_branch=$(get_default_branch)
	_clean_prepare_git_branch_caches "$default_branch"

	# Fetch to get current remote branch state (detects deleted branches)
	# Prune all remotes, not just origin (GH#3797)
	local remote_state_unknown
	remote_state_unknown=$(_clean_fetch_remotes)

	# Build PR branch lists for squash-merge detection and open-PR safety check.
	# NOTE: bash 3.2 (macOS default) lacks declare -A — do NOT use associative arrays.
	_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS=
	local merged_pr_branches
	if ! merged_pr_branches=$(_clean_build_merged_pr_branches); then
		_clean_pr_proof_unknown_add "unknown:merged-pr-list-unavailable"
	fi
	_WT_CLEAN_EXACT_PR_PREFETCH_COMPLETE=false
	local exact_merged_pr_branches=""
	local exact_prefetch_status=0
	exact_merged_pr_branches=$(_clean_build_exact_merged_pr_branches "$default_branch") || exact_prefetch_status=$?
	if [[ -n "$exact_merged_pr_branches" ]]; then
		merged_pr_branches="${merged_pr_branches}${merged_pr_branches:+$'\n'}${exact_merged_pr_branches}"
	fi
	if [[ "$exact_prefetch_status" -eq 0 ]]; then
		_WT_CLEAN_EXACT_PR_PREFETCH_COMPLETE=true
	fi

	local open_pr_branches
	if ! open_pr_branches=$(_clean_build_open_pr_branches); then
		_clean_pr_proof_unknown_add "unknown:open-pr-list-unavailable"
	fi

	# Closed (abandoned) PRs: closed without merging. Remote branch may linger
	# because auto-delete only fires on merge.
	local closed_pr_branches
	if ! closed_pr_branches=$(_clean_build_closed_pr_branches); then
		_clean_pr_proof_unknown_add "unknown:closed-pr-list-unavailable"
	fi

	local response="n"
	if [[ "$auto_mode" == "true" ]]; then
		# The removal pass performs the complete classification and every mutable
		# safety check. Avoid a redundant preview pass when no user confirmation
		# is possible; interactive cleanup retains the candidate preview.
		response="y"
	else
		if ! _clean_scan_merged "$default_branch" "$main_worktree_path" "$remote_state_unknown" "$merged_pr_branches" "$open_pr_branches" "$force_merged" "$closed_pr_branches"; then
			echo -e "${GREEN}No merged worktrees to clean up${NC}" >&2
			return 0
		fi
		echo "" >&2
		echo -e "${YELLOW}Remove these worktrees? [y/N]${NC}" >&2
		read -r response
	fi

	if [[ "$response" =~ ^[Yy]$ ]]; then
		# Second pass: remove merged worktrees
		local cleanup_status=0
		_clean_remove_merged "$default_branch" "$main_worktree_path" "$remote_state_unknown" "$merged_pr_branches" "$open_pr_branches" "$force_merged" "$closed_pr_branches" || cleanup_status=$?
		if declare -F full_loop_reconcile_cleanup_receipts >/dev/null 2>&1; then
			full_loop_reconcile_cleanup_receipts
		fi
		if [[ "$cleanup_status" -ne 0 ]]; then
			echo -e "${YELLOW}Cleanup completed with one or more removal failures${NC}" >&2
			return 1
		fi
		echo -e "${GREEN}Cleanup complete${NC}" >&2
	else
		echo "Cancelled" >&2
	fi

	return 0
}
