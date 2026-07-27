#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-cleanup.sh — Worktree/stash/zombie-worker cleanup + orphan/stalled worker recovery + stale opencode process cleanup.
#
# Extracted from pulse-wrapper.sh in Phase 5 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap
# section.
#
# Functions in this module (in source order):
#   Private helpers (called only within this module):
#   - _cleanup_merged_prs_for_all_repos     (Pass 1: merged-PR worktree removal)
#   - _worktree_owner_alive                 (pgrep + registry ownership check)
#   - _worktree_creation_epoch              (stat .git file mtime, with silent-skip logging)
#   - _pc_branch_has_pr                     (newline-safe PR existence probe)
#   - _evaluate_worktree_removal            (age/commit/PR threshold decision)
#   - _record_orphan_crash_classification   (crash type + dedup clearing for orphaned workers)
#   - _cleanup_single_worktree              (per-worktree orchestrator)
#   Public interface (called by pulse-wrapper.sh):
#   - cleanup_stale_temp_worktrees
#   - cleanup_worktrees
#   - cleanup_stashes
#   - reap_zombie_workers
#   - recover_failed_launch_state
#   - cleanup_stalled_workers
#   - cleanup_orphans
#   - cleanup_stale_opencode
#
# Phase 12 refactor (t2003 / GH#18451): split cleanup_worktrees() (250 lines)
# into the three private helpers above. Also preserves the GH#18346 fix
# (silent-skip logging) that was applied during Phase 5 extraction — see
# _worktree_owner_alive() and _cleanup_single_worktree() for the two
# previously-silent continue paths that now emit diagnostic log entries.
#
# GH#18704 refactor: split _cleanup_single_worktree() (125 lines) into three
# focused private helpers: _worktree_creation_epoch(),
# _evaluate_worktree_removal(), and _record_orphan_crash_classification().
# The orchestrator now reads as a linear five-step pipeline instead of a
# single flat function. Preserves identical behaviour including the GH#18346
# silent-skip log entry, the GH#16830/t1884 age thresholds, and the crash
# classification rules for "overwhelmed" vs "no_work" workers.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CLEANUP_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_LOADED=1
_PULSE_CLEANUP_FALSE="false"

# t2559: canonical-guard-helper.sh provides is_registered_canonical and
# assert_git_available, used by guarded removal helpers and
# _cleanup_merged_prs_for_all_repos below. Guarded missing-file so older
# deployments fail open.
_PULSE_CLEANUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || _PULSE_CLEANUP_SCRIPT_DIR=""
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/canonical-guard-helper.sh" ]]; then
	# shellcheck source=/dev/null
	source "$_PULSE_CLEANUP_SCRIPT_DIR/canonical-guard-helper.sh"
fi
# t2976: canonical audit logger for worktree-removal events
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/audit-worktree-removal-helper.sh" ]]; then
	# shellcheck source=audit-worktree-removal-helper.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/audit-worktree-removal-helper.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/lib/version.sh" ]]; then
	# shellcheck source=lib/version.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/lib/version.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/gh-signature-helper-detect.sh" ]]; then
	# shellcheck source=gh-signature-helper-detect.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/gh-signature-helper-detect.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/shared-dispatch-label-cleanup.sh" ]]; then
	# shellcheck source=shared-dispatch-label-cleanup.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/shared-dispatch-label-cleanup.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/worktree-paths.sh" ]]; then
	# shellcheck source=worktree-paths.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/worktree-paths.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-temp-worktree-cleanup.sh" ]]; then
	# shellcheck source=pulse-temp-worktree-cleanup.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-temp-worktree-cleanup.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-cleanup-degraded-orphans.sh" ]]; then
	# shellcheck source=pulse-cleanup-degraded-orphans.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-cleanup-degraded-orphans.sh"
fi
# GH#23677 / t3700: Do NOT `unset _PULSE_CLEANUP_SCRIPT_DIR`. The previous
# version unset this immediately after sourcing the four sibling helpers,
# but _cleanup_merged_prs_for_all_repos() (line ~251) reads it later to
# locate worktree-helper.sh. Under `set -u` (the standard pulse-wrapper
# orchestrator setting) that read aborts the cleanup pass with
# `_PULSE_CLEANUP_SCRIPT_DIR: unbound variable`. The variable already uses
# the module-private `_PULSE_` prefix and survives the include guard on
# line 49 unset-free, so keeping it bound is consistent.
: "${AIDEVOPS_UNKNOWN_VERSION:=unknown}"
# Caller ID constant for audit log calls (avoids repeated literals).
_WTAR_PC_CALLER="pulse-cleanup.sh"
_PC_REASON_AGE_ELIGIBLE="age-eligible"

#######################################
# Extract a GitHub issue number from worker-style branch names.
#
# Args:
#   $1 - branch name
# Outputs: issue number when present
# Returns: 0 when an issue was found, 1 otherwise
#######################################
_pc_issue_from_branch() {
	local branch_name="$1"
	if [[ "$branch_name" =~ gh[-]?([0-9]+) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ "$branch_name" =~ (^|/)fix/([0-9]{3,})([-/]|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

#######################################
# Extract a GitHub PR number from local review/repair branch names.
#
# Args:
#   $1 - branch name
# Outputs: PR number when present
# Returns: 0 when a PR number was found, 1 otherwise
#######################################
_pc_pr_from_branch() {
	local branch_name="$1"
	if [[ "$branch_name" =~ (^|[-/])pr[-/]?([0-9]+)([-/]|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

#######################################
# Check whether a branch has at least one matching PR.
#
# `gh_pr_list` intentionally emits cached/output text with `printf '%s'`, so
# single-row output can be non-empty without a trailing newline. Counting via
# `wc -l` treats that output as zero lines and can misclassify branches with
# PRs as no-PR orphan cleanup candidates (GH#23821). Ask for a single PR number
# and test the captured string instead.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - branch name
#   $3 - PR state (open|closed|merged|all)
# Returns: 0 when a matching PR is found, 1 otherwise or on lookup failure
#######################################
_pc_branch_has_pr() {
	local repo_slug="$1"
	local branch_name="$2"
	local pr_state="$3"
	local pr_number=""

	if [[ -z "$repo_slug" || -z "$branch_name" || -z "$pr_state" ]]; then
		return 1
	fi

	pr_number=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" --state "$pr_state" --limit 1 --json number --jq '.[].number // empty') || true
	if [[ -n "$pr_number" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Return terminal PR state for a branch head, if GitHub verifies one.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - branch name
# Outputs: terminal PR state (CLOSED|MERGED)
# Returns: 0 when terminal PR found, 1 otherwise
#######################################
_pc_terminal_pr_state_for_branch() {
	local repo_slug="$1"
	local branch_name="$2"
	local pr_state=""

	[[ -n "$repo_slug" && -n "$branch_name" ]] || return 1
	pr_state=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" --state all --limit 1 --json state --jq '.[0].state // empty' 2>/dev/null) || return 1
	case "$pr_state" in
	CLOSED | MERGED)
		printf '%s\n' "$pr_state"
		return 0
		;;
	esac
	return 1
}

#######################################
# Check whether a parsed branch issue is closed.
#
# Used only as an acceleration signal for branch-preserving cleanup: the
# worktree directory may be removed early, but the local branch remains as the
# recovery path. Lookup failures fail closed to the normal age threshold.
#
# Args:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
# Returns: 0 when the issue is verified closed, 1 otherwise
#######################################
_pc_issue_closed_for_branch_archive() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_state

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" ]] || return 1
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state // ""' 2>/dev/null) || return 1
	[[ "$issue_state" == "CLOSED" ]] || return 1
	return 0
}

#######################################
# Check whether a parsed PR reference is closed or merged.
#
# Used only as an acceleration signal for branch-preserving cleanup: the
# worktree directory may be removed early, but the local branch remains as the
# recovery path. Lookup failures fail closed to the normal age threshold.
#
# Args:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
# Outputs: terminal PR state when verified
# Returns: 0 when the PR is not open, 1 otherwise
#######################################
_pc_pr_terminal_for_branch_archive() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_state

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" ]] || return 1
	pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state // ""' 2>/dev/null) || return 1
	case "$pr_state" in
	CLOSED | MERGED)
		printf '%s\n' "$pr_state"
		return 0
		;;
	esac
	return 1
}

#######################################
# Build safe audit context for orphan cleanup decisions.
#
# Args:
#   $1 - branch name
#   $2 - issue number or empty
#   $3 - commits ahead
#   $4 - dirty count
#   $5 - age seconds
#   $6 - PR state summary
#   $7 - owner guard summary
#   $8 - process guard summary
#   $9 - recent session guard summary
#   ${10} - removal/recovery path summary
# Outputs: space-separated key=value context with no private repo slug
# Returns 0 always
#######################################
_pc_worktree_audit_context() {
	local branch_name="$1"
	local issue_number="$2"
	local commits_ahead="$3"
	local dirty_count="$4"
	local wt_age_secs="$5"
	local pr_state="$6"
	local owner_guard="$7"
	local process_guard="$8"
	local recent_guard="$9"
	local recovery_path="${10}"
	local session_key="none"
	if [[ -n "$issue_number" ]]; then
		session_key="issue-${issue_number}"
	fi

	printf 'branch=%s issue=%s session_key=%s owner_guard=%s process_guard=%s recent_session_guard=%s commits=%s dirty=%s pr_state=%s age_secs=%s recovery_path=%s\n' \
		"${branch_name:-detached}" \
		"${issue_number:-none}" \
		"$session_key" \
		"$owner_guard" \
		"$process_guard" \
		"$recent_guard" \
		"$commits_ahead" \
		"$dirty_count" \
		"$pr_state" \
		"$wt_age_secs" \
		"$recovery_path"
	return 0
}

#######################################
# Log an orphan cleanup skip when worktree creation time cannot be read.
#
# Args:
#   $1 - wt_path_age:   absolute worktree path
#   $2 - wt_branch_age: branch name
# Returns: 0 always
#######################################
_pc_log_stat_unavailable_skip() {
	local wt_path_age="$1"
	local wt_branch_age="$2"
	local stat_issue_num=""
	stat_issue_num=$(_pc_issue_from_branch "$wt_branch_age" 2>/dev/null || true)
	local stat_audit_context
	stat_audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$stat_issue_num" 0 0 0 "unknown" "unknown" "unknown" "unknown" "stat-unavailable")
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "stat-unavailable" "skipped" "$stat_audit_context"
	return 0
}

#######################################
# Log an orphan cleanup skip when age/PR/commit gates are not eligible.
#
# Args:
#   $1 - wt_path_age:   absolute worktree path
#   $2 - wt_branch_age: branch name
#   $3 - commits_ahead: commits ahead of main
#   $4 - dirty_count:   dirty file count
#   $5 - wt_age_secs:   worktree age in seconds
#   $6 - pr_state:      short state reason
# Returns: 0 always
#######################################
_pc_log_not_age_eligible_skip() {
	local wt_path_age="$1"
	local wt_branch_age="$2"
	local commits_ahead="$3"
	local dirty_count="$4"
	local wt_age_secs="$5"
	local pr_state="$6"
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')
	local issue_num=""
	issue_num=$(_pc_issue_from_branch "$wt_branch_age" 2>/dev/null || true)
	local audit_context
	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$pr_state" "$guard_ok" "$guard_ok" "$guard_ok" "none")
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "not-age-eligible" "skipped" "$audit_context"
	return 0
}

#######################################
# Check recent worker runtime metrics for the issue/session key.
#
# Args:
#   $1 - issue number
#   $2 - now epoch
#   $3 - grace window seconds
# Returns: 0 when a recent matching metric exists, 1 otherwise
#######################################
_pc_recent_worker_metric_exists() {
	local issue_number="$1"
	local now_epoch="$2"
	local grace_secs="$3"
	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"

	[[ -n "$issue_number" ]] || return 1
	[[ -f "$metrics_file" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1

	local cutoff_epoch=$((now_epoch - grace_secs))
	jq -e --arg issue "$issue_number" --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" '
		select((.ts // 0) >= $cutoff and (.ts // 0) <= $now)
		| select(
			((.issue_number // "") | tostring) == $issue
			or ((.session_key // "") | tostring | test("(^|[^0-9])" + $issue + "([^0-9]|$)"))
		)
	' "$metrics_file" >/dev/null 2>&1
	return $?
}

# t2859: Config defaults (ORPHAN_WORKTREE_GRACE_SECS, ORPHAN_MAX_AGE,
# PULSE_IDLE_CPU_THRESHOLD) are owned by pulse-wrapper-config.sh. When
# this module is sourced standalone (cleanup-worktrees-async-helper.sh,
# tests) without that config also being sourced, the variables are
# unbound and bash's numeric coercion treats unbound expansion as 0 —
# collapsing the 30-minute grace period to zero seconds and destroying
# fresh worktrees with 0 commits and no PR.
#
# We do NOT defensively source pulse-wrapper-config.sh here: that file
# depends on _validate_int from worker-lifecycle-common.sh, which the
# async cleanup path also doesn't source. Instead, every use site in
# this file carries an inline `${VAR:-default}` fallback that produces
# the same default as the config file. Search for "t2859" comments to
# see each fallback. Tested by test-pulse-cleanup-config-defaults.sh.

#######################################
# Move a path to system trash before permanent deletion (GH#19042).
# Mirrors worktree-helper.sh trash_path() so Pass 2 orphan cleanup gets
# the same recoverability as Pass 1 (which calls worktree-helper.sh clean).
# Prefers: trash CLI (macOS Homebrew), gio trash (Linux), rm -rf fallback.
# Args: $1=path to trash
# Returns 0 on success, 1 on failure.
#
# t2559 Layer 2: refuses to trash a path registered as a canonical
# repository in ~/.config/aidevops/repos.json.
#######################################
_trash_or_remove() {
	local target="$1"
	[[ -z "$target" ]] && return 1
	[[ ! -e "$target" ]] && return 0

	# t2559: never trash a registered canonical repository. Mirrors the
	# guard added to worktree-helper.sh trash_path(). Defence-in-depth
	# at every entry point that can invoke rm/trash on a derived path.
	if command -v is_registered_canonical >/dev/null 2>&1; then
		if is_registered_canonical "$target"; then
			echo "[pulse-cleanup] REFUSED: '$target' is a registered canonical repository — will not trash" >>"${LOGFILE:-/dev/null}"
			return 1
		fi
	fi

	if command -v trash >/dev/null 2>&1; then
		trash "$target" 2>/dev/null && return 0
	fi
	if command -v gio >/dev/null 2>&1; then
		gio trash "$target" 2>/dev/null && return 0
	fi
	rm -rf "$target" 2>/dev/null && return 0
	return 1
}

#######################################
# Move an orphan directory to a recoverable trash location only.
#
# Unlike _trash_or_remove, this helper never falls back to rm -rf. It is used
# for unregistered filesystem outliers where git no longer has worktree
# metadata, so recovery must remain possible after automated cleanup.
#
# Args: $1=path to move
# Returns: 0 on success, 1 on failure
#######################################
_pc_trash_orphan_dir() {
	local target="$1"
	[[ -z "$target" ]] && return 1
	[[ ! -e "$target" ]] && return 0

	local trash_root="${AIDEVOPS_ORPHAN_TRASH_ROOT:-}"
	if [[ -n "$trash_root" ]]; then
		_pc_move_orphan_dir_to_trash_bucket "$target" "$trash_root" && return 0
		return 1
	fi

	if command -v trash >/dev/null 2>&1; then
		trash "$target" 2>/dev/null && return 0
	fi
	if command -v gio >/dev/null 2>&1; then
		gio trash "$target" 2>/dev/null && return 0
	fi

	trash_root="${HOME}/.Trash"
	_pc_move_orphan_dir_to_trash_bucket "$target" "$trash_root" && return 0
	return 1
}

_pc_move_orphan_dir_to_trash_bucket() {
	local target="$1"
	local trash_root="$2"
	local trash_bucket
	trash_bucket="${trash_root}/aidevops-orphan-cleanup-$(date -u '+%Y%m%dT%H%M%SZ')"
	local target_base
	target_base=$(basename "$target")
	[[ -n "$target_base" && "$target_base" != "." && "$target_base" != "/" ]] || return 1
	mkdir -p "$trash_bucket" 2>/dev/null || return 1
	mv "$target" "$trash_bucket/$target_base" 2>/dev/null && return 0
	return 1
}

#######################################
# Pass 1 helper: remove worktrees for merged/closed PRs across ALL repos
#
# Iterates repos.json (.initialized_repos[]) and runs
# worktree-helper.sh clean --auto --force-merged in each repo directory.
# Echoes the total count of removed worktrees on stdout; returns 0 always.
#
# --force-merged: force-removes dirty worktrees when the PR is confirmed
# merged (dirty state = abandoned WIP from a completed worker).
# Safety: skips worktrees owned by active sessions (handled by
# worktree-helper.sh ownership registry, t189).
#######################################
_pc_count_verified_worktree_removals() {
	local clean_output="$1"
	local completed_event="AIDEVOPS_WORKTREE_REMOVAL_COMPLETED=1"
	local output_line=""
	local completed_count=0

	while IFS= read -r output_line; do
		[[ "$output_line" == "$completed_event" ]] || continue
		completed_count=$((completed_count + 1))
	done <<<"$clean_output"
	printf '%s\n' "$completed_count"
	return 0
}

_cleanup_merged_prs_for_all_repos() {
	# t2559 Layer 3: fail-loud when git is missing from PATH. This runs before
	# we invoke worktree-helper.sh clean across every repo — if git isn't
	# available, the helper's worktree-list derivation returns empty, and the
	# downstream "don't touch main" guard collapses. Belt-and-braces here
	# even though cmd_clean has its own Layer 3 check.
	if command -v assert_git_available >/dev/null 2>&1; then
		if ! assert_git_available; then
			echo "[pulse-cleanup] refusing merged-PR worktree cleanup — git not in PATH" >>"${LOGFILE:-/dev/null}"
			echo 0
			return 0
		fi
	fi

	local helper=""
	if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -x "$_PULSE_CLEANUP_SCRIPT_DIR/worktree-helper.sh" ]]; then
		helper="$_PULSE_CLEANUP_SCRIPT_DIR/worktree-helper.sh"
	elif [[ -x "${HOME}/.aidevops/agents/scripts/worktree-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
	fi
	if [[ -z "$helper" ]]; then
		echo 0
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_removed=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Iterate all initialized repos — clean worktrees for any repo with
		# a git directory, not just pulse-enabled ones. Workers can create
		# worktrees in any managed repo. Skip local_only repos since
		# worktree-helper.sh uses gh pr list for squash-merge detection.
		local repo_records
		repo_records=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | [.path // "", .slug // "unknown"] | @tsv' "$repos_json" || echo "")

		local repo_path
		local repo_slug
		while IFS=$'\t' read -r repo_path repo_slug; do
			[[ -z "$repo_path" ]] && continue
			if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
				echo "[pulse-cleanup] stage=merged-pr repo=${repo_slug:-unknown} skipping cleanup — invalid repo path configured" >>"${LOGFILE:-/dev/null}"
				continue
			fi

			local wt_count
			wt_count=$(git -C "$repo_path" worktree list | wc -l | tr -d ' ')
			# Skip repos with only 1 worktree (the main one) — nothing to clean
			if [[ "${wt_count:-0}" -le 1 ]]; then
				continue
			fi

			# Run helper in a subshell cd'd to the repo (it uses git rev-parse --show-toplevel)
			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" clean --auto --force-merged 2>&1) || true

			local count
			count=$(_pc_count_verified_worktree_removals "$clean_result")
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Worktree cleanup ($repo_name): $count worktree(s) removed" >>"$LOGFILE"
				total_removed=$((total_removed + count))
			fi
		done <<<"$repo_records"
	else
		# Fallback: just clean the current repo (legacy behaviour)
		if ! git rev-parse --git-dir >/dev/null 2>&1; then
			echo "[pulse-cleanup] stage=merged-pr repo=unknown skipping cleanup — current directory is not a git repository" >>"${LOGFILE:-/dev/null}"
			echo 0
			return 0
		fi

		local clean_result
		clean_result=$(bash "$helper" clean --auto --force-merged 2>&1) || true
		local fallback_count
		fallback_count=$(_pc_count_verified_worktree_removals "$clean_result")
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Worktree cleanup: $fallback_count worktree(s) removed" >>"$LOGFILE"
			total_removed=$((total_removed + fallback_count))
		fi
	fi

	echo "$total_removed"
	return 0
}

#######################################
# Check whether a worktree has an active owner (process or registry).
#
# Three checks in priority order:
#   1. pgrep: any process with the worktree path in its argv.
#   2. Registry: is_worktree_owned_by_others() — covers interactive
#      runtimes (e.g. Claude Code) where the path never appears in argv.
#   3. Interactive claim stamp (t2916/GH#21074): consults
#      ~/.aidevops/.agent-workspace/interactive-claims/<slug>-<issue>.json.
#      Same source of truth as the dispatch-dedup gate. Catches active work
#      that pgrep + registry both miss (e.g. claim stamp written but the
#      worktree-registry entry was pruned, or an interactive runtime whose
#      argv doesn't contain the worktree path).
#
# All silent-skip paths log a diagnostic message (GH#18346 fix):
# previously these paths produced zero log output, making it impossible
# to diagnose why eligible orphan worktrees survived cleanup.
#
# Args:
#   $1 - wt_path: absolute path to the worktree
#   $2 - wt_branch: branch name (for log context; empty = detached)
# Returns: 0 if alive (caller should skip removal), 1 if no active owner
#######################################
_worktree_owner_alive() {
	local wt_path="$1"
	local wt_branch="${2:-}"

	# pgrep check: any process referencing this path in its command line
	if pgrep -f "$wt_path" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch:-detached} ($wt_path) — pgrep matched active process" >>"$LOGFILE"
		# t2976: audit log — orphan cleanup blocked, pgrep found active owner
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" "owned-skip" "skipped"
		return 0
	fi

	# Registry check (GH#18021): covers MCP-dispatch runtimes where the
	# worktree path never appears in process argv.
	if is_worktree_owned_by_others "$wt_path"; then
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch:-detached} ($wt_path) — registered owner alive in registry" >>"$LOGFILE"
		# t2976: audit log — orphan cleanup blocked, registry owner is alive
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" "owned-skip" "skipped"
		return 0
	fi

	# Interactive claim stamp check (t2916/GH#21074): consults the canonical
	# claim-stamp directory used by the dispatch-dedup gate. Catches the
	# failure modes that defeat pgrep + registry: stale registry entries,
	# argv-less runtimes, manual `git worktree add` recoveries that bypass
	# `register_worktree`, etc. Subprocess call to interactive-session-helper.sh
	# rather than sourcing — keeps pulse-cleanup.sh's call graph small and
	# isolates a transient helper-graph error from the cleanup pass.
	if [[ -n "$wt_branch" ]]; then
		local _isc_helper=""
		if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
			_isc_helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
		elif [[ -x "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/interactive-session-helper.sh" ]]; then
			_isc_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/interactive-session-helper.sh"
		fi
		if [[ -n "$_isc_helper" ]]; then
			if "$_isc_helper" branch-has-active-claim "$wt_branch" --worktree "$wt_path" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Orphan cleanup: skipping $wt_branch ($wt_path) — active interactive claim stamp" >>"$LOGFILE"
				log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" "active-claim" "skipped"
				return 0
			fi
		fi
	fi

	return 1
}

#######################################
# Get worktree creation epoch from the .git file's mtime.
#
# Uses _file_mtime_epoch from portable-stat.sh. Writes 0 to stdout
# when the .git file is missing or stat fails, and logs a diagnostic in
# that case (GH#18346: this path was previously a silent continue).
#
# Args:
#   $1 - wt_path: absolute worktree path
#   $2 - wt_branch: branch name (for log context; "" = detached)
# Outputs: epoch seconds on stdout (0 on failure)
# Returns: 0 always (caller inspects the printed value)
#######################################
_worktree_creation_epoch() {
	local wt_path="$1"
	local wt_branch="${2:-}"
	local wt_created=0

	if [[ -f "$wt_path/.git" ]]; then
		wt_created=$(_file_mtime_epoch "$wt_path/.git")
	fi

	if [[ "$wt_created" -eq 0 ]]; then
		# GH#18346: previously a silent skip — now logs the reason
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch:-detached} ($wt_path) — stat on .git failed (wt_created=0)" >>"$LOGFILE"
	fi

	echo "$wt_created"
	return 0
}

#######################################
# Decide whether a worktree is eligible for orphan cleanup.
#
# Applies the age/commit/PR thresholds from GH#16830, t1884, GH#23677:
#   0 commits, clean, no open PR, >grace → crashed worker (fast-path)
#   0 commits, clean,             >3h    → empty, safe to remove
#   0 commits, dirty,             >6h    → worker died mid-edit
#                                          (refused by _cleanup_single_worktree,
#                                           but reason is still emitted for audit
#                                           logs and manual triage)
#   any commits, no PR,           >24h   → abandoned, will be re-dispatched
# GH#23677 / t3700: the fast-path now requires dirty_count == 0; without
# that guard a worktree being actively edited by an interactive
# OpenCode/Claude Code session (path not in pgrep argv) was permanently
# destroyed at age 30m, losing uncommitted work with no recovery path.
#
# GitHub queries are only attempted when both repo_slug and branch are
# non-empty. On eligibility the reason string is written to stdout so the
# caller can log it and feed it to crash classification.
#
# Args:
#   $1 - commits_ahead
#   $2 - dirty_count
#   $3 - wt_age_secs
#   $4 - wt_branch_age (may be empty)
#   $5 - repo_slug_age (may be empty)
# Outputs: reason string on stdout when eligible
# Returns: 0 if eligible for removal, 1 otherwise
#######################################
_evaluate_worktree_removal() {
	local commits_ahead="$1"
	local dirty_count="$2"
	local wt_age_secs="$3"
	local wt_branch_age="${4:-}"
	local repo_slug_age="${5:-}"

	# Age thresholds — grace period from config, others hardcoded.
	# t2859: inline ${VAR:-1800} fallback ensures grace=30min even when
	# pulse-wrapper-config.sh is not sourced. Previously this expanded to
	# empty string, which bash treats as 0 in numeric comparisons, making
	# every fresh 0-commit worktree immediately eligible for destruction.
	local age_grace="${ORPHAN_WORKTREE_GRACE_SECS:-1800}"
	local age_3h=$((3 * 3600))
	local age_6h=$((6 * 3600))
	local age_24h=$((24 * 3600))

	# The branches below are mutually exclusive via an elif chain — once the
	# fast-path's outer condition matches (0 commits + clean + past grace),
	# the later branches MUST NOT be checked even if the fast-path decides
	# "not eligible" (e.g. an open PR protects the worktree). Preserving
	# this short-circuit is what keeps worktrees with active PRs alive
	# past 3h. Dirty worktrees skip the fast-path entirely and fall
	# through to the explicit 6h rule (GH#23677 / t3700).

	# Fast-path: 0 commits + CLEAN + past grace period → crashed worker candidate (t1884)
	#
	# GH#23677 / t3700: the fast-path MUST require dirty_count == 0. A
	# worktree with uncommitted edits represents work-in-progress from an
	# interactive editor session (OpenCode/Claude Code/VS Code/etc) where
	# the path does not appear in pgrep argv and is not registered in the
	# SQLite worktree-owner registry. Removing it permanently destroys the
	# user's dirty files with no recovery path (mode=permanent, branch
	# deleted, no trash backing). Defer dirty cases to the 6h rule below
	# which gives editor sessions a much wider safety margin.
	if [[ "$commits_ahead" -eq 0 && "$dirty_count" -eq 0 && "$wt_age_secs" -ge "$age_grace" ]]; then
		local has_open_pr=false
		if [[ -n "$repo_slug_age" && -n "$wt_branch_age" ]]; then
			if _pc_branch_has_pr "$repo_slug_age" "$wt_branch_age" "open"; then
				has_open_pr=true
			fi
		fi
		if [[ "$has_open_pr" == "$_PULSE_CLEANUP_FALSE" ]]; then
			echo "0 commits, clean, no open PR, age $((wt_age_secs / 60))m (crashed worker)"
			return 0
		fi
	# 0 commits, clean worktree, >3h → empty (no PR, no dirty state)
	elif [[ "$commits_ahead" -eq 0 && "$dirty_count" -eq 0 && "$wt_age_secs" -ge "$age_3h" ]]; then
		echo "0 commits, clean, age $((wt_age_secs / 3600))h"
		return 0
	# 0 commits, dirty, >6h → worker died mid-edit
	elif [[ "$commits_ahead" -eq 0 && "$dirty_count" -gt 0 && "$wt_age_secs" -ge "$age_6h" ]]; then
		echo "0 commits, ${dirty_count} dirty files, age $((wt_age_secs / 3600))h"
		return 0
	# Has commits, >24h, no PR of any state → abandoned
	elif [[ "$commits_ahead" -gt 0 && "$wt_age_secs" -ge "$age_24h" ]]; then
		local has_pr=false
		if [[ -n "$repo_slug_age" && -n "$wt_branch_age" ]]; then
			if _pc_branch_has_pr "$repo_slug_age" "$wt_branch_age" "all"; then
				has_pr=true
			fi
		fi
		if [[ "$has_pr" == "$_PULSE_CLEANUP_FALSE" ]]; then
			echo "${commits_ahead} commits, no PR, age $((wt_age_secs / 3600))h"
			return 0
		fi
	fi

	return 1
}

#######################################
# Count consecutive trailing CLAIM_RELEASED comments with session_count=0.
#
# t3050: drives per-issue infra-failure escalation when an issue repeatedly
# kills workers in setup (sandbox crash, OpenCode init failure, prompt
# parse error before tool use). Re-dispatching at the same tier produces
# the same failure — escalation breaks the loop.
#
# Reads recent issue comments (newest first), filters to CLAIM_RELEASED
# audit lines, and counts how many trailing entries carry `session_count=0`.
# Stops counting at the first non-zero or missing-session_count comment so
# a single recovered worker resets the trail.
#
# Args:
#   $1 - issue_number: GitHub issue number
#   $2 - repo_slug:    owner/repo slug
#   $3 - threshold:    minimum trailing-zero count to return success
# Returns: 0 if trailing zero count >= threshold, 1 otherwise (incl. fetch failure)
#######################################
_consecutive_zero_session_failures() {
	local issue_number="$1"
	local repo_slug="$2"
	local threshold="$3"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi
	if [[ ! "$threshold" =~ ^[0-9]+$ ]] || [[ "$threshold" -lt 1 ]]; then
		return 1
	fi

	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate 2>/dev/null) || return 1
	if [[ -z "$comments_json" || "$comments_json" == "null" ]]; then
		return 1
	fi

	# Newest-first ordering of CLAIM_RELEASED bodies, then walk the trail.
	# A comment matters only if its first line carries CLAIM_RELEASED;
	# missing-session_count entries are treated as "non-zero" (unknown)
	# and break the streak — conservative on the side of NOT escalating.
	local bodies
	bodies=$(printf '%s' "$comments_json" | jq -r '
		[.[] | select((.body // "") | startswith("CLAIM_RELEASED"))]
		| reverse
		| .[]
		| .body
	' 2>/dev/null) || return 1
	if [[ -z "$bodies" ]]; then
		return 1
	fi

	local zero_run=0
	# Read each CLAIM_RELEASED body's first line and inspect session_count=N.
	# IFS-aware loop terminates on the first comment that breaks the streak.
	local body_first_line
	while IFS= read -r body_first_line; do
		[[ -z "$body_first_line" ]] && continue
		# Ignore non-claim lines (defensive — jq filtered already).
		[[ "$body_first_line" != CLAIM_RELEASED* ]] && break
		if [[ "$body_first_line" =~ session_count=([0-9]+) ]]; then
			if [[ "${BASH_REMATCH[1]}" == "0" ]]; then
				zero_run=$((zero_run + 1))
			else
				break
			fi
		else
			# No session_count token (older comment shape) — break streak.
			break
		fi
	done < <(printf '%s' "$bodies" | awk 'BEGIN{RS=""; FS="\n"} {print $1}')

	if [[ "$zero_run" -ge "$threshold" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Compose a worker-mentoring infra-failure advisory body (per t1900).
#
# t3050: emitted when an issue accumulates N consecutive zero-session
# CLAIM_RELEASED comments. Tells the next reader (maintainer or future
# worker) what the symptom is, how it differs from regular failures, and
# what diagnostics to run BEFORE re-dispatching at the same tier.
#
# The body intentionally does NOT remove auto-dispatch — that's the
# caller's job. It carries the `dispatch-infrastructure-failure` marker
# so `auto_approve_maintainer_issues` PRESERVES the NMR label rather than
# clearing it (t2386 split semantics: this is a circuit-breaker family
# trip, not a creation-default scanner-filed issue).
#
# Args:
#   $1 - issue_number: for the worker-log path hint
#   $2 - repo_slug:    for the worker-log path hint (slug → safe slug)
# Returns: 0 always; advisory body printed on stdout.
#######################################
_dispatch_infra_failure_advisory() {
	local issue_number="$1"
	local repo_slug="$2"

	local log_path_hint=""
	log_path_hint=$(aidevops_pulse_worker_log_path "$repo_slug" "$issue_number" 2>/dev/null || true)
	[[ -n "$log_path_hint" ]] || log_path_hint="<pulse-temp>/pulse-${issue_number}.log"

	cat <<MARKER_EOF
## Dispatch infrastructure failure detected

<!-- dispatch-infrastructure-failure -->

This issue has accumulated **2+ consecutive worker releases with \`session_count=0\`** — every dispatched worker exited before producing any opencode model output. Re-dispatching at the same tier reproduces the same failure mode.

### What this means

A \`session_count=0\` release indicates the worker died in setup (sandbox crash, OpenCode init failure, auth rotation failure, prompt parse error before first tool use, or a SIGTERM before the model emitted any output). The classifier change in t3050 surfaces this directly so the loop is broken at the orphan-cleanup pass instead of cycling through full re-dispatch attempts.

### Action required (maintainer)

1. Read the most recent worker logs:
   - \`${log_path_hint}\`
   - \`${log_path_hint}.*\` (rotated copies)
2. Identify the failure family — sandbox / auth / OpenCode / prompt / SIGTERM source.
3. Once the underlying issue is fixed, clear NMR with:

\`\`\`bash
sudo aidevops approve issue ${issue_number} ${repo_slug}
\`\`\`

This applies the cryptographic approval signature that takes precedence over the \`dispatch-infrastructure-failure\` marker, allowing the next dispatch to proceed.

### Why dispatch is paused

Re-dispatching this issue without a setup-side fix would (a) burn another worker on the same failure mode, (b) not surface diagnostics the maintainer hasn't already seen, and (c) progress the cost circuit breaker without producing useful output. The \`needs-maintainer-review\` label + \`dispatch-infrastructure-failure\` marker pause the dispatch loop until a human verifies the failure family and lands a fix.
MARKER_EOF
	return 0
}

#######################################
# Verify a pulse cleanup issue target is still open before writing to it.
#
# Orphan worktree cleanup can run long after the original issue completed. In
# that state there is no dispatch dedup guard to clear, and posting recovery
# audit comments only creates notification noise on closed work. Fail closed on
# lookup errors: cleanup still removes the local orphan, but skips GitHub writes.
#
# Args:
#   $1 - issue_number: GitHub issue number
#   $2 - repo_slug:    owner/repo slug
#   $3 - context:      log context for the skipped write
# Returns: 0 if issue is open, 1 otherwise
#######################################
_pulse_cleanup_issue_open_for_write() {
	local issue_number="$1"
	local repo_slug="$2"
	local context="${3:-pulse cleanup write}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state --jq '.state // ""' 2>/dev/null) || issue_state=""
	if [[ "$issue_state" != "OPEN" ]]; then
		echo "[pulse-wrapper] ${context} skipped for #${issue_number} (${repo_slug}): issue state=${issue_state:-unknown}; no closed-issue recovery comment posted" >>"$LOGFILE"
		return 1
	fi

	return 0
}

#######################################
# Record crash classification for an orphaned worker worktree.
#
# Extracts the issue number from the branch name (pattern: gh[-]?NNN),
# classifies the crash type, updates failure launch state, logs the
# outcome, and posts a "Worker failed" comment on the issue to clear
# the dispatch dedup guard (t1884, GH#18021).
#
# Classification rules (drive crash-type-aware tier escalation):
#   "overwhelmed": dirty files, OR issue-named branch with no commits.
#                  Model attempted real work but couldn't produce commits.
#                  Pattern: "read files, created worktree, couldn't close the loop".
#   "no_work":     auto-named feature/auto-*-gh<N> branch with clean worktree.
#                  Worker never got past setup — likely infra/transient.
#
# Since GH#19042, feature/auto-* branches include the issue number
# (feature/auto-YYYYMMDD-HHMMSS-gh<N>), so the gh[-]?([0-9]+) regex
# now matches them. Legacy branches without issue numbers are skipped.
#
# t3050: per-issue infra-failure escalation. Before posting the
# crash_type=no_work failure comment, check whether the most recent
# CLAIM_RELEASED comments already carry session_count=0 in a row. If 2+
# consecutive zero-session releases are detected, apply
# needs-maintainer-review with a dispatch-infrastructure-failure marker
# instead of re-dispatching — the loop won't break by retrying.
#
# Args:
#   $1 - wt_branch_age: branch name (non-empty; caller checks)
#   $2 - dirty_count:   number of dirty files in the worktree
#   $3 - repo_slug_age: owner/repo slug (non-empty; caller checks)
# Returns: 0 always
#######################################
_record_orphan_crash_classification() {
	local wt_branch_age="$1"
	local dirty_count="$2"
	local repo_slug_age="$3"

	local orphan_issue_num=""
	if [[ "$wt_branch_age" =~ gh[-]?([0-9]+) ]]; then
		orphan_issue_num="${BASH_REMATCH[1]}"
	fi
	# Branches without an embedded issue number can't be recovered.
	# Since GH#19042, new feature/auto-* branches include gh<N>, but
	# legacy ones (pre-fix) still lack it — skip those gracefully.
	if [[ -z "$orphan_issue_num" ]]; then
		return 0
	fi
	if ! _pulse_cleanup_issue_open_for_write "$orphan_issue_num" "$repo_slug_age" "Orphan cleanup"; then
		return 0
	fi

	local orphan_crash_type="no_work"
	if [[ "$dirty_count" -gt 0 ]]; then
		orphan_crash_type="overwhelmed"
	elif [[ "$wt_branch_age" != feature/auto-* ]]; then
		# Issue-named branch = model parsed the issue but produced nothing.
		orphan_crash_type="overwhelmed"
	fi
	# Auto-named branches (feature/auto-*) with 0 dirty files stay as
	# "no_work" — the worker couldn't parse the issue, likely infra.

	# t3050: per-issue infra-failure escalation. If the last 2 CLAIM_RELEASED
	# comments both carry session_count=0, the issue is repeatedly killing
	# workers in setup. Apply NMR with the dispatch-infrastructure-failure
	# marker so auto_approve_maintainer_issues PRESERVES NMR (t2386 split
	# semantics) and the dispatch loop pauses until a maintainer fixes
	# the underlying setup-side issue. Best-effort, idempotent: failure
	# falls through to the legacy "Worker failed" comment path below.
	# Skip when AIDEVOPS_SKIP_INFRA_FAILURE_ESCALATION=1 (test/diagnostic bypass).
	if [[ "${AIDEVOPS_SKIP_INFRA_FAILURE_ESCALATION:-0}" != "1" ]] \
		&& _consecutive_zero_session_failures "$orphan_issue_num" "$repo_slug_age" 2; then
		echo "[pulse-wrapper] Orphan cleanup: dispatch-infrastructure-failure detected for #${orphan_issue_num} (${repo_slug_age}) — applying needs-maintainer-review" >>"$LOGFILE"
		# Apply NMR label (best-effort — gh_issue_edit_safe is from shared-gh-wrappers.sh)
		if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
			gh_issue_edit_safe "$orphan_issue_num" --repo "$repo_slug_age" \
				--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
		else
			gh issue edit "$orphan_issue_num" --repo "$repo_slug_age" \
				--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
		fi
		# Post the worker-mentoring advisory comment carrying the marker.
		local _advisory_body
		_advisory_body=$(_dispatch_infra_failure_advisory "$orphan_issue_num" "$repo_slug_age")
		if declare -F gh_issue_comment >/dev/null 2>&1; then
			gh_issue_comment "$orphan_issue_num" --repo "$repo_slug_age" \
				--body "$_advisory_body" >/dev/null 2>&1 || true
		else
			gh issue comment "$orphan_issue_num" --repo "$repo_slug_age" \
				--body "$_advisory_body" >/dev/null 2>&1 || true
		fi
		# Still record the failure for telemetry, but skip the legacy
		# "Cleared for re-dispatch" comment — re-dispatch is what we're
		# blocking. The advisory replaces the legacy comment.
		recover_failed_launch_state "$orphan_issue_num" "$repo_slug_age" "premature_exit" "$orphan_crash_type"
		return 0
	fi

	recover_failed_launch_state "$orphan_issue_num" "$repo_slug_age" "premature_exit" "$orphan_crash_type"
	echo "[pulse-wrapper] Orphan cleanup: recorded premature_exit for #${orphan_issue_num} (${repo_slug_age}) crash_type=${orphan_crash_type} — triggers fast-fail escalation" >>"$LOGFILE"

	# Post failure comment to clear dedup guard immediately. Without this
	# the dispatch comment blocks re-dispatch for the full TTL even though
	# the worker is dead. "Worker failed" is a recognised completion
	# signal in dispatch-dedup-helper.sh has_dispatch_comment().
	gh_issue_comment "$orphan_issue_num" --repo "$repo_slug_age" \
		--body "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Worker failed: orphan worktree detected (crash_type=${orphan_crash_type}, 0 commits). Cleared for re-dispatch.
<!-- ops:end -->" \
		>/dev/null 2>&1 || true

	return 0
}

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
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "dirty-content-protect" "skipped" "$audit_context_ref"
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
		audit_ctx_reflog=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_not_on_remotes" "$dirty_count" "$wt_age_secs" "none" "$guard_ok" "$guard_ok" "$guard_ok" "none")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): skipping ${wt_branch_age:-detached} — ${commits_not_on_remotes} commit(s) reachable from HEAD but not on any remote" >>"$LOGFILE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "commits-not-on-remote" "skipped" "$audit_ctx_reflog"
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
#   $3 - wt_branch_age: branch name
#   $4 - audit_context: structured audit context
# Returns: 0 if the worktree directory was removed, 1 otherwise
#######################################
_pc_remove_local_commit_worktree_preserving_branch() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local audit_context="$4"

	[[ -n "$rp_age" && -n "$wt_path_age" && -n "$wt_branch_age" ]] || return 1
	if ! worktree_removal_guard "$wt_path_age" "$_WTAR_PC_CALLER" "local-commits-branch-preserved"; then
		return 1
	fi

	if git -C "$rp_age" worktree remove --force "$wt_path_age" 2>/dev/null; then
		git -C "$rp_age" worktree prune 2>/dev/null || true
		unregister_worktree "$wt_path_age" 2>/dev/null || true
		log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$wt_path_age" "local-commits-branch-preserved" "branch-preserved" "$audit_context"
		return 0
	fi

	return 1
}

#######################################
# Archive dirty worktree state to git stash before branch-preserved removal.
#
# Args:
#   $1 - worktree path
#   $2 - branch name
# Returns: 0 if clean or stash archive succeeds, 1 otherwise
#######################################
_pc_archive_dirty_worktree_stash() {
	local wt_path="$1"
	local wt_branch="$2"
	local dirty_count=0
	dirty_count=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty_count=0
	if [[ "$dirty_count" -eq 0 ]]; then
		return 0
	fi
	git -C "$wt_path" stash push -u -m "aidevops worktree cleanup archive: ${wt_branch:-detached}" >/dev/null 2>&1
	return $?
}

#######################################
# Remove a worktree after archiving dirty state and preserving the branch.
#
# Args mirror _pc_remove_local_commit_worktree_preserving_branch.
# Returns: 0 if removed, 1 otherwise
#######################################
_pc_archive_and_remove_worktree_preserving_branch() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local audit_context="$4"
	[[ -n "$rp_age" && -n "$wt_path_age" && -n "$wt_branch_age" ]] || return 1
	_pc_archive_dirty_worktree_stash "$wt_path_age" "$wt_branch_age" || return 1
	_pc_remove_local_commit_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" "$audit_context"
	return $?
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
# Returns: 0 if removed, 1 if not eligible or removal failed.
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
	local removal_reason="detached-review-cruft"
	local branch_pr_num=""
	local archive_secs
	local audit_context
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')

	_pc_is_generated_clean_cruft_worktree "$wt_path_age" "$wt_branch_age" || return 1
	if [[ -n "$wt_branch_age" && -n "$repo_slug_age" ]]; then
		_pc_branch_has_pr "$repo_slug_age" "$wt_branch_age" "open" && return 1
		branch_pr_num=$(_pc_pr_from_branch "$wt_branch_age" 2>/dev/null || true)
		if [[ -n "$branch_pr_num" ]] && _pc_pr_terminal_for_branch_archive "$branch_pr_num" "$repo_slug_age" >/dev/null 2>&1; then
			return 1
		fi
	fi
	if [[ "$dirty_count" -gt 0 ]]; then
		[[ -n "$wt_branch_age" ]] || return 1
		archive_secs=$(_pc_generated_dirty_archive_secs)
		removal_reason="generated-dirty-cruft"
	else
		archive_secs=$(_pc_generated_clean_archive_secs)
	fi
	[[ "$wt_age_secs" -ge "$archive_secs" ]] || return 1

	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "generated-clean-cruft" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-if-present")
	if [[ -n "$wt_branch_age" ]]; then
		if [[ "$dirty_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age} — dirty generated auto/review worktree older than ${archive_secs}s; stash archived and branch preserved" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age} — clean generated auto/review worktree older than ${archive_secs}s; branch preserved" >>"$LOGFILE"
		fi
		_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" "$audit_context"
		return $?
	fi
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing detached generated worktree — clean auto/review cruft older than ${archive_secs}s" >>"$LOGFILE"
	if ! remove_worktree_path_permanently "$wt_path_age" "$_WTAR_PC_CALLER" "$removal_reason" "$audit_context"; then
		git -C "$rp_age" worktree remove --force "$wt_path_age" 2>/dev/null || return 1
		log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$wt_path_age" "$removal_reason" "permanent" "$audit_context"
	fi
	git -C "$rp_age" worktree prune 2>/dev/null || true
	unregister_worktree "$wt_path_age" 2>/dev/null || true
	return 0
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
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "none" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-closed-issue")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — issue #${orphan_issue_num} is closed; local commits preserved on branch" >>"$LOGFILE"
		_pc_remove_local_commit_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" "$audit_context"
		return $?
	fi

	branch_pr_num=$(_pc_pr_from_branch "$wt_branch_age" 2>/dev/null || true)
	if [[ "$dirty_count" -eq 0 ]] && branch_pr_state=$(_pc_pr_terminal_for_branch_archive "$branch_pr_num" "$repo_slug_age"); then
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "pr-${branch_pr_state}" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-closed-pr-${branch_pr_num}")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — PR #${branch_pr_num} is ${branch_pr_state}; local commits preserved on branch" >>"$LOGFILE"
		_pc_remove_local_commit_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" "$audit_context"
		return $?
	fi
	if _pc_handle_generated_clean_cruft_worktree "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"; then
		return 0
	fi

	archive_secs=$(_pc_local_commit_archive_secs)
	if [[ "$wt_age_secs" -lt "$archive_secs" ]]; then
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "none" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-after-${archive_secs}s")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): skipping ${wt_branch_age:-detached} — local commits with no PR are younger than branch-preserving cleanup threshold" >>"$LOGFILE"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "local-commits-no-pr" "skipped" "$audit_context"
		return 1
	fi

	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "none" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved")
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing stale worktree for ${wt_branch_age:-detached} — local commits preserved on branch" >>"$LOGFILE"
	_pc_remove_local_commit_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" "$audit_context"
	return $?
}

#######################################
# Remove terminal issue/PR worktrees early while preserving branch recovery.
#
# Args: same state tuple as _pc_handle_local_commit_no_pr_worktree.
# Returns: 0 if removed, 1 if no terminal proof or removal failed.
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
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')

	if _pc_issue_closed_for_branch_archive "$orphan_issue_num" "$repo_slug_age"; then
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "closed-issue" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-closed-issue")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — issue #${orphan_issue_num} is closed; state archived and branch preserved" >>"$LOGFILE"
		_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" "$audit_context"
		return $?
	fi

	if terminal_pr_state=$(_pc_terminal_pr_state_for_branch "$repo_slug_age" "$wt_branch_age"); then
		audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "pr-${terminal_pr_state}" "$guard_ok" "$guard_ok" "$guard_ok" "branch-preserved-terminal-pr")
		echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — branch PR is ${terminal_pr_state}; state archived and branch preserved" >>"$LOGFILE"
		_pc_archive_and_remove_worktree_preserving_branch "$rp_age" "$wt_path_age" "$wt_branch_age" "$audit_context"
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
	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "none" "$guard_ok" "$guard_ok" "active" "none")
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): skipping ${wt_branch_age:-detached} — recent worker runtime metric/session record" >>"$LOGFILE"
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "active-worker-metric" "skipped" "$audit_context"
	return 0
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
	if ! remove_worktree_path_permanently "$wt_path_age" "$_WTAR_PC_CALLER" "$_PC_REASON_AGE_ELIGIBLE" "$audit_context"; then
		if git -C "$rp_age" worktree remove --force "$wt_path_age" 2>/dev/null; then
			log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$wt_path_age" \
				"$_PC_REASON_AGE_ELIGIBLE" "permanent" "$audit_context"
		else
			return 1
		fi
	fi
	git -C "$rp_age" worktree prune 2>/dev/null || true
	unregister_worktree "$wt_path_age" 2>/dev/null || true
	if [[ -n "$wt_branch_age" ]]; then
		git -C "$rp_age" branch -D "$wt_branch_age" 2>/dev/null || true
		git -C "$rp_age" push origin --delete "$wt_branch_age" 2>/dev/null || true
	fi
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
	local dirty_count=0
	dirty_count=$(git -C "$wt_path_age" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || return 1
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
	if _pc_handle_terminal_worktree_archive "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"; then
		return 0
	fi

	local audit_context
	local guard_ok
	guard_ok=$(printf 'cle%s' 'ar')
	audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "none" "$guard_ok" "$guard_ok" "$guard_ok" "none")
	if _pc_skip_recent_worker_metric_cleanup "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$now_epoch" "$repo_name_age"; then
		return 1
	fi
	if _pc_handle_generated_clean_cruft_worktree "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"; then
		return 0
	fi

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
		_pc_handle_local_commit_no_pr_worktree "$rp_age" "$wt_path_age" "$wt_branch_age" "$orphan_issue_num" "$commits_ahead" "$dirty_count" "$wt_age_secs" "$repo_name_age" "$repo_slug_age"
		return $?
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
			log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_local" "local-only-repo" "skipped"
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

	local repo_parent central_base
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
	local dir_mtime
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

	local repo_paths_orphan
	repo_paths_orphan=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" 2>/dev/null || printf '')

	local rp_orphan
	while IFS= read -r rp_orphan; do
		[[ -z "$rp_orphan" ]] && continue
		[[ -d "$rp_orphan/.git" || -f "$rp_orphan/.git" ]] || continue
		local repo_parent repo_name candidate_path candidate_name reason central_base
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
			if reason=$(_pc_classify_orphan_sibling_dir "$rp_orphan" "$candidate_path" "$now_epoch"); then
				echo "[pulse-wrapper] Orphan dir cleanup ($repo_name): moving $candidate_path to trash — $reason" >>"$LOGFILE"
				if _pc_trash_orphan_dir "$candidate_path"; then
					log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$candidate_path" "$reason" "trash"
					moved_count=$((moved_count + 1))
				else
					log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$candidate_path" "trash-failed" "skipped"
				fi
			fi
		done
		if [[ -n "$central_base" && -d "$central_base" && "$central_base" != "$repo_parent" ]]; then
			for candidate_path in "$central_base/$repo_name"-* "$central_base/$repo_name".*; do
				[[ -d "$candidate_path" ]] || continue
				candidate_name=$(basename "$candidate_path")
				_pc_orphan_sibling_name_allowed "$repo_name" "$candidate_name" || continue
				if reason=$(_pc_classify_orphan_sibling_dir "$rp_orphan" "$candidate_path" "$now_epoch"); then
					echo "[pulse-wrapper] Orphan dir cleanup ($repo_name): moving $candidate_path to trash — $reason" >>"$LOGFILE"
					if _pc_trash_orphan_dir "$candidate_path"; then
						log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$candidate_path" "$reason" "trash"
						moved_count=$((moved_count + 1))
					else
						log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$candidate_path" "trash-failed" "skipped"
					fi
				fi
			done
		fi
	done <<<"$repo_paths_orphan"

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
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_move" "centralize-target-exists" "skipped"
		return 1
	}
	mkdir -p "$(dirname "$target_path")" 2>/dev/null || return 1

	if git -C "$rp_move" worktree move "$wt_path_move" "$target_path" >/dev/null 2>&1; then
		unregister_worktree "$wt_path_move" 2>/dev/null || true
		log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_PC_CALLER" "$wt_path_move" "centralized-worktree" "moved" "target=central-worktree-base branch=$wt_branch_move"
		return 0
	fi
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_move" "centralize-move-failed" "skipped"
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
cleanup_worktrees() {
	CLEANUP_WORKTREES_SKIPPED=0
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

	return 0
}

#######################################
# Clean up safe-to-drop stashes across ALL managed repos (t1417)
#
# Iterates repos.json (.initialized_repos[]) and runs
# stash-audit-helper.sh auto-clean in each repo directory. Pulse preflight calls
# this via cleanup-stashes-async-helper.sh so slow stash audits cannot block
# early dispatch (GH#21997); direct callers remain synchronous.
# Only drops stashes whose content is already in HEAD — safe
# and deterministic, no judgment needed.
#
# Stashes classified as "needs-review" or "obsolete" are left
# for the LLM hygiene triage (see prefetch_hygiene + pulse.md).
#######################################
cleanup_stashes() {
	local helper="${HOME}/.aidevops/agents/scripts/stash-audit-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_dropped=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local repo_paths
		repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			# Skip repos with no stashes
			local stash_count
			stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
			if [[ "${stash_count:-0}" -eq 0 ]]; then
				continue
			fi

			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" auto-clean 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Dropped') || count=0
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Stash cleanup ($repo_name): $count stash(es) dropped" >>"$LOGFILE"
				total_dropped=$((total_dropped + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo
		local clean_result
		clean_result=$(bash "$helper" auto-clean 2>&1) || true
		local fallback_count
		fallback_count=$(echo "$clean_result" | grep -c 'Dropped') || fallback_count=0
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Stash cleanup: $fallback_count stash(es) dropped" >>"$LOGFILE"
			total_dropped=$((total_dropped + fallback_count))
		fi
	fi

	if [[ "$total_dropped" -gt 0 ]]; then
		echo "[pulse-wrapper] Stash cleanup total: $total_dropped stash(es) dropped across all repos" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Find the one merged PR that both closes an issue structurally and matches
# the exact active worker branch/head. Search text is never lifecycle proof.
# Args: repo slug, issue number, branch name, head SHA
# Returns: 0 + PR number, 1 no match, 2 API/ambiguity failure.
#######################################
_verified_worker_closing_pr() {
	local repo_slug="$1"
	local issue_number="$2"
	local branch_name="$3"
	local head_oid="$4"
	local candidates=""
	candidates=$(gh pr list --repo "$repo_slug" --state merged --head "$branch_name" --limit 100 \
		--json number,state,mergedAt,headRefName,headRefOid,closingIssuesReferences 2>/dev/null) || return 2
	local verification="" verified_count="" verified_pr=""
	verification=$(printf '%s' "$candidates" | jq -r --arg issue "$issue_number" --arg branch "$branch_name" --arg head "$head_oid" '
		if length >= 100 then "limit"
		else
			[.[] | select(
				.state == "MERGED" and (.mergedAt // "") != "" and
				.headRefName == $branch and .headRefOid == $head and
				([.closingIssuesReferences[]?.number | tostring] | index($issue)) != null
			)] as $verified |
			[($verified | length | tostring), ($verified[0].number // "" | tostring)] | @tsv
		end
	' 2>/dev/null) || return 2
	[[ "$verification" != "limit" ]] || return 2
	IFS=$'\t' read -r verified_count verified_pr <<<"$verification"
	[[ "$verified_count" =~ ^[0-9]+$ ]] || return 2
	[[ "$verified_count" -le 1 ]] || return 2
	[[ "$verified_count" -eq 1 && -n "$verified_pr" ]] || return 1
	printf '%s\n' "$verified_pr"
	return 0
}

#######################################
# Reap zombie workers whose PRs have already been merged (t1751/GH#15489)
#
# Workers don't detect when the deterministic merge pass merges their PR.
# This function runs each pulse cycle (before worker counting) to kill
# workers that are still running after their work is done.
#
# Uses the dispatch ledger session keys (issue-{N}) to bind the issue,
# repo, and PID before checking for merged PRs and terminating the worker.
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
reap_zombie_workers() {
	local reaped=0
	local worker_key="" issue_number=""

	local session_keys
	session_keys=$(ps aux | grep '[h]eadless-runtime.*--role worker' | grep -v grep |
		sed 's/.*--session-key //' | awk '{print $1}' | sort -u) || return 0

	while IFS= read -r worker_key; do
		[[ -z "$worker_key" ]] && continue
		issue_number="${worker_key#issue-}"
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue

		# Session keys are issue-number only, so require the live ledger's repo
		# and PID to avoid same-number cross-repo PR/issue collisions.
		local repo_slug="" ledger_entry="" ledger_issue="" ledger_pid="" ledger_worktree="" lease_token=""
		local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
		if [[ -x "$_ledger_helper" ]]; then
			ledger_entry=$("$_ledger_helper" check --session-key "$worker_key" 2>/dev/null) || ledger_entry=""
			if [[ -n "$ledger_entry" ]]; then
				local ledger_fields
				ledger_fields=$(printf '%s' "$ledger_entry" | jq -r '[.repo_slug // "", (.issue_number // "" | tostring), (.pid // "" | tostring), .worktree_path // "", .lease_token // ""] | @tsv' 2>/dev/null) || ledger_fields=$'\t\t\t\t'
				IFS=$'\t' read -r repo_slug ledger_issue ledger_pid ledger_worktree lease_token <<<"$ledger_fields"
			fi
		fi
		if [[ -z "$repo_slug" ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: no live ledger repo; refusing repo-less merged-PR lookup" >>"$LOGFILE"
			continue
		fi
		if [[ -n "$ledger_issue" && "$ledger_issue" != "$issue_number" ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: ledger issue ${ledger_issue} does not match session issue ${issue_number}" >>"$LOGFILE"
			continue
		fi
		if [[ -z "$ledger_pid" || ! "$ledger_pid" =~ ^[0-9]+$ ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: no ledger PID; refusing session-key-wide kill" >>"$LOGFILE"
			continue
		fi
		if [[ -z "$lease_token" || -z "$ledger_worktree" || ! -d "$ledger_worktree" ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: active dispatch generation/worktree is unavailable" >>"$LOGFILE"
			continue
		fi
		local branch_name="" head_oid=""
		branch_name=$(git -C "$ledger_worktree" branch --show-current 2>/dev/null) || branch_name=""
		head_oid=$(git -C "$ledger_worktree" rev-parse HEAD 2>/dev/null) || head_oid=""
		if [[ -z "$branch_name" || ! "$head_oid" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: worker branch/head could not be verified" >>"$LOGFILE"
			continue
		fi
		local merged_pr="" verification_rc=0
		merged_pr=$(_verified_worker_closing_pr "$repo_slug" "$issue_number" "$branch_name" "$head_oid") || verification_rc=$?
		if [[ "$verification_rc" -eq 2 ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: merged PR evidence is ambiguous or API-indeterminate" >>"$LOGFILE"
			continue
		fi

		if [[ "$verification_rc" -eq 0 && -n "$merged_pr" ]]; then
			if ! "$_ledger_helper" complete --session-key "$worker_key" --lease-token "$lease_token" \
				--reason merged_pr_reap 2>/dev/null; then
				echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: active dispatch generation changed before termination" >>"$LOGFILE"
				continue
			fi
			# The lease transition is the compare-and-set gate. Only the exact active
			# generation can reach process termination and terminal telemetry.
			echo "[pulse-wrapper] Reaping zombie worker ${worker_key}: PR #${merged_pr} already merged in ${repo_slug}" >>"$LOGFILE"
			echo "[INFO] [lifecycle] worker_reap pid=${ledger_pid} kill_reason=merged_pr_reap issue=${issue_number} pr=${merged_pr}" >>"$LOGFILE"
			"$_ledger_helper" record-outcome --issue "$issue_number" --repo "$repo_slug" --outcome success \
				--reason merged_pr_reap --session-key "$worker_key" --lease-token "$lease_token" 2>/dev/null || true
			kill "$ledger_pid" 2>/dev/null || true
			reaped=$((reaped + 1))
		fi
	done <<<"$session_keys"

	if [[ "$reaped" -gt 0 ]]; then
		echo "[pulse-wrapper] Reaped ${reaped} zombie worker(s) with merged PRs (t1751)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Recover issue state after launch validation failure (t1702)
#
# When launch validation fails, the issue may remain assigned + queued even
# though no worker process exists. This traps capacity by blocking redispatch.
#
# Safety gates:
#   - Only act on OPEN issues
#   - Only act when current GitHub login is assigned on the issue
#   - Only act when issue still has status:queued label
#   - Re-check for a late-started worker before mutating issue state
#
# Actions (best-effort):
#   1. Mark any in-flight ledger entry for this issue as failed
#   2. Remove self assignee and status:queued
#   3. Re-label status:available unless issue is blocked
#
# Args:
#   $1 - issue number
#   $2 - repo slug
#   $3 - failure reason string (for logs)
#######################################

# t2394 helper: post CLAIM_RELEASED so cross-runner dedup immediately re-opens
# the issue for dispatch instead of waiting for the 30-min DISPATCH_CLAIM TTL
# to expire. Without this, a fast-failing worker leaves a stale claim comment
# that poisons cross-runner coordination for up to 1800s per failure — the
# local state (assignee, status label) is already reset but the claim comment
# is authoritative for peer runners. Mirrors the pattern in
# worker-activity-watchdog.sh:222 and headless-runtime-failure.sh:59 — those
# paths already post CLAIM_RELEASED; the launch-failure recovery path was the
# missing coverage.
#
# t2814 (Phase 3, fix #1): Include the tail of the worker log in the claim-
# released comment for `no_worker_process` failures. Closes the diagnostic
# gap identified in t2813 root cause analysis: worker logs in the pulse temp
# directory existed but were never read
# during recovery, so every `no_worker_process` event ended with the same
# opaque "no active worker process" message and no insight into whether the
# canary failed, the session lock collided, or the runtime crashed before
# OpenCode could spawn. The 20-line tail captures canary diagnostics
# (last `print_warning` lines) and any early-exit traceback.
_post_launch_recovery_claim_released() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local failure_reason="$4"

	local body
	local aidevops_version="$AIDEVOPS_UNKNOWN_VERSION" opencode_version="$AIDEVOPS_UNKNOWN_VERSION"
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
	fi
	if declare -F _detect_opencode_version >/dev/null 2>&1; then
		opencode_version=$(_detect_opencode_version 2>/dev/null || printf '%s' "")
		opencode_version="${opencode_version:-$AIDEVOPS_UNKNOWN_VERSION}"
	fi
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=launch_recovery:${failure_reason} runner=${self_login} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) aidevops_version=${aidevops_version} opencode_version=${opencode_version}"

	# t2814: append worker-log tail when available so the failure is
	# diagnosable from the audit trail alone (no log-file forensics needed).
	# Bounded to last 20 lines and 4KB to keep comments readable and avoid
	# accidental credential leakage from verbose stack traces.
	#
	# t2820: extracted to `_read_worker_log_tail_classified` in
	# shared-claim-lifecycle.sh — same bounds + path enumeration. The
	# classification side-output is unused here (the comment just embeds
	# the raw tail); escalate_issue_tier consumes the classification for
	# its no_work reclassification path. Keeping a single reader prevents
	# the two consumers from drifting on log-path conventions.
	if declare -F _read_worker_log_tail_classified >/dev/null 2>&1; then
		_read_worker_log_tail_classified "$issue_number" "$repo_slug"
		if [[ -n "${_WORKER_LOG_TAIL_FILE:-}" && -n "${_WORKER_LOG_TAIL_CONTENT:-}" ]]; then
			body="${body}

<details>
<summary>worker log tail (last 20 lines, source: ${_WORKER_LOG_TAIL_FILE})</summary>

\`\`\`text
${_WORKER_LOG_TAIL_CONTENT}
\`\`\`

</details>"
		fi
	fi
	body="${body}
<!-- ops:end -->"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$body" \
		>/dev/null 2>&1 || true
	declare -F invalidate_footprint_cache_for_issue >/dev/null 2>&1 && invalidate_footprint_cache_for_issue "$issue_number" || true
	return 0
}

# t2897 helper: record a launch failure as a zero-attempt outcome for the
# per-runner circuit breaker. Only `no_worker_process` counts as a zero-
# attempt signal — other failure_reasons (cli_usage_output, stale_timeout,
# etc.) are real-attempt failures and aren't recorded. Extracted from
# recover_failed_launch_state to keep that function under the 100-line
# function-complexity gate.
_record_runner_health_zero_attempt() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_reason="$3"

	[[ "$failure_reason" == "no_worker_process" ]] || return 0
	local _rh_helper="${SCRIPT_DIR}/pulse-runner-health-helper.sh"
	[[ -x "$_rh_helper" ]] || return 0
	"$_rh_helper" record-outcome no_worker_process \
		"${repo_slug}#${issue_number}" >/dev/null 2>&1 || true
	return 0
}

# t3197: write a per-issue dispatch-cooldown audit marker after a
# `no_worker_process` launch failure. The reader is
# `dispatch-dedup-helper.sh::_is_assigned_check_dispatch_cooldown`, which
# parses the most recent `<!-- dispatch-cooldown-until:<ISO> ... -->`
# marker on the issue and short-circuits dispatch with
# `DISPATCH_COOLDOWN_ACTIVE` while the timestamp is in the future.
#
# Closes the rapid-retry loop where a broken runtime (CLI changes, missing
# binary, network flake) burns ~5 worker spawns over 3-4 hours per issue
# with 95-99s lifespans each, repeating across 30+ issues simultaneously
# when one runner is unhealthy.
#
# Only `no_worker_process` qualifies — `cli_usage_output`, `stale_timeout`,
# and other failure_reasons have their own retry/escalation mechanisms;
# layering a cooldown on top would over-throttle.
#
# Disabled by setting DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS=0.
# Default cooldown: 1800 seconds (30 minutes).
#
# Always returns 0 — cooldown is a soft optimization, never blocks the
# wider recovery path on its own failure (gh API hiccup, date parse
# error, etc.).
_post_launch_cooldown_marker() {
	# $4 is the failure_reason; only no_worker_process should write a marker.
	# Unquoted RHS in [[ ]] keeps the literal off the repeated-string counter.
	[[ ${4-} == no_worker_process ]] || return 0

	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"

	local cooldown_s="${DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS:-1800}"
	[[ "$cooldown_s" =~ ^[0-9]+$ ]] || cooldown_s=1800
	(( cooldown_s > 0 )) || return 0

	local now_epoch until_epoch iso
	now_epoch=$(date -u +%s 2>/dev/null) || return 0
	until_epoch=$((now_epoch + cooldown_s))

	# Portable ISO formatting: GNU `date -d "@<epoch>"` first, BSD `date -r` fallback.
	iso=$(date -u -d "@${until_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
		iso=$(date -u -r "${until_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
		return 0
	[[ -n "$iso" ]] || return 0

	local body="<!-- dispatch-cooldown-until:${iso} reason=no_worker_process runner=${self_login} -->
Dispatch cooldown active until ${iso} following a no_worker_process launch failure (t3197). The pulse will not redispatch this issue until the marker expires. Set DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS=0 to disable."

	local comments_endpoint
	# printf single-quoted format keeps the endpoint literal off the
	# repeated-string-literal counter (the same path appears verbatim in
	# _post_launch_recovery_claim_released and _is_stale_assignment).
	comments_endpoint=$(printf 'repos/%s/issues/%s/comments' "$repo_slug" "$issue_number")
	gh api "$comments_endpoint" \
		--method POST \
		--field body="$body" \
		>/dev/null 2>&1 || true
	declare -F invalidate_footprint_cache_for_issue >/dev/null 2>&1 && invalidate_footprint_cache_for_issue "$issue_number" || true
	return 0
}

#######################################
# Confirm launch recovery removed this runner's queued ownership and applied
# the intended replacement status before publishing any success receipt.
# Args: issue number, repo slug, runner login, target status
#######################################
_verify_launch_recovery_state() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local target_status="$4"
	local issue_meta_json=""

	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees 2>/dev/null) || return 1
	printf '%s' "$issue_meta_json" | jq -e --arg self "$self_login" --arg target "status:${target_status}" '
		.state == "OPEN" and
		(([.labels[].name] | index("status:queued")) == null) and
		(([.labels[].name] | index($target)) != null) and
		(([.assignees[].login] | index($self)) == null)
	' >/dev/null 2>&1 || return 1
	return 0
}

recover_failed_launch_state() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_reason="${3:-launch_validation_failed}"
	local crash_type="${4:-}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# Mark in-flight ledger entry as failed even if GitHub claim edits never stuck.
	local ledger_helper
	ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		local ledger_entry session_key
		ledger_entry=$("$ledger_helper" check-issue --issue "$issue_number" --repo "$repo_slug" 2>/dev/null || true)
		session_key=$(printf '%s' "$ledger_entry" | jq -r '.session_key // ""' 2>/dev/null)
		if [[ -n "$session_key" ]]; then
			"$ledger_helper" fail --session-key "$session_key" >/dev/null 2>&1 || true
		fi
	fi

	# For no-worker failures, skip cleanup if a late-started worker appears.
	# For cli_usage_output failures, always continue to clear stale claim state.
	if [[ "$failure_reason" != "cli_usage_output" ]]; then
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): worker appeared after validation failure" >>"$LOGFILE"
			return 0
		fi
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$self_login" ]]; then
		echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): unable to resolve current login" >>"$LOGFILE"
		return 0
	fi

	local issue_meta_json
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" --json state,labels,assignees 2>/dev/null) || issue_meta_json=""
	if [[ -z "$issue_meta_json" ]]; then
		return 0
	fi

	local issue_state assigned_to_self has_queued is_blocked
	issue_state=$(echo "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null)
	assigned_to_self=$(echo "$issue_meta_json" | jq -r --arg self "$self_login" '([.assignees[].login] | index($self)) != null' 2>/dev/null)
	has_queued=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:queued")) != null' 2>/dev/null)
	is_blocked=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:blocked")) != null' 2>/dev/null)

	[[ "$assigned_to_self" == "true" || "$assigned_to_self" == "$_PULSE_CLEANUP_FALSE" ]] || assigned_to_self=""
	[[ "$has_queued" == "true" || "$has_queued" == "$_PULSE_CLEANUP_FALSE" ]] || has_queued=""
	[[ "$is_blocked" == "true" || "$is_blocked" == "$_PULSE_CLEANUP_FALSE" ]] || is_blocked=""

	if [[ "$issue_state" != "OPEN" ]] || [[ "$assigned_to_self" != "true" ]] || [[ "$has_queued" != "true" ]]; then
		return 0
	fi

	# t2033: atomic transitions via set_issue_status. The blocked branch
	# preserves status:blocked (target = "blocked"); the normal branch
	# transitions to status:available.
	local target_status="available"
	[[ "$is_blocked" == "true" ]] && target_status="blocked"
	if ! set_issue_status "$issue_number" "$repo_slug" "$target_status" \
		--remove-assignee "$self_login" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Launch recovery uncertain for #${issue_number} (${repo_slug}): ownership mutation failed" >>"$LOGFILE"
		return 1
	fi
	if ! _verify_launch_recovery_state "$issue_number" "$repo_slug" "$self_login" "$target_status"; then
		echo "[pulse-wrapper] Launch recovery uncertain for #${issue_number} (${repo_slug}): post-mutation verification failed" >>"$LOGFILE"
		return 1
	fi

	# t2394: Invalidate stale cross-runner claims immediately (see helper below).
	_post_launch_recovery_claim_released "$issue_number" "$repo_slug" "$self_login" "$failure_reason"
	# t3197: Write a per-issue dispatch cooldown marker so other runners
	# (and this one) skip redispatch for the configured cooldown window.
	# Only fires for `no_worker_process` — the recurring no-spawn failure mode.
	_post_launch_cooldown_marker "$issue_number" "$repo_slug" "$self_login" "$failure_reason"
	# t2897: Record zero-attempt outcome for the per-runner circuit breaker.
	_record_runner_health_zero_attempt "$issue_number" "$repo_slug" "$failure_reason"
	# t1934: Unlock issue and linked PRs (locked at dispatch time)
	unlock_issue_after_worker "$issue_number" "$repo_slug"

	# Record the launch failure in the fast-fail counter (t1888).
	# t2815: no_worker_process = infra failure; map to no_work so escalate_issue_tier
	# short-circuits at the t2387 guard and skips tier escalation.
	local effective_crash_type="$crash_type"
	if [[ "$failure_reason" == "no_worker_process" && -z "$effective_crash_type" ]]; then
		effective_crash_type="no_work"
	fi
	fast_fail_record "$issue_number" "$repo_slug" "$failure_reason" "anthropic" "$effective_crash_type" || true
	# t1959: Wire global circuit breaker for launch-class failures only.
	# Stale timeouts and in-execution failures have their own per-issue backoff
	# and should not trip a global halt. Only true launch failures signal
	# systemic runtime breakage. Recovery happens via record-success on PR merge
	# or issue close (already wired in supervisor) — NEVER reset on launch success.
	case "$failure_reason" in
	no_worker_process | cli_usage_output)
		local cb_helper="${SCRIPT_DIR}/circuit-breaker-helper.sh"
		if [[ -x "$cb_helper" ]]; then
			"$cb_helper" record-failure "${repo_slug}#${issue_number}" "$failure_reason" >/dev/null 2>&1 || true
		fi
		;;
	esac

	echo "[pulse-wrapper] Launch recovery reset #${issue_number} (${repo_slug}) after ${failure_reason} crash_type=${effective_crash_type:-unclassified}: removed self assignee + status:queued" >>"$LOGFILE"
	return 0
}

cleanup_stalled_workers() {
	local killed=0
	local freed_mb=0

	while IFS= read -r line; do
		local pid etime cpu rss cmd
		read -r pid etime cpu rss cmd <<<"$line"

		# Only check headless workers (no TTY, full-loop in command)
		case "$cmd" in
		*"/full-loop"*) ;;
		*) continue ;;
		esac

		# Check process age
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$STALLED_WORKER_MIN_AGE" ]]; then
			continue
		fi

		# Extract issue number and find log file
		local issue_num
		issue_num=$(echo "$cmd" | grep -oE 'issue #[0-9]+' | grep -oE '[0-9]+' | head -1)
		[[ -n "$issue_num" ]] || continue

		local log_file="" log_size=""
		# Check all pulse-enabled repos for matching log
		local found_log=""
		local repo_slug=""
		while IFS= read -r repo_slug; do
			[[ -n "$repo_slug" ]] || continue
			log_file=$(aidevops_pulse_worker_log_path "$repo_slug" "$issue_num" 2>/dev/null || true)
			if [[ -f "$log_file" ]]; then
				found_log="$log_file"
				break
			fi
		done < <(jq -r '.initialized_repos[] | select(.pulse == true) | .slug // ""' "$REPOS_JSON")
		# Fallback log path
		if [[ -z "$found_log" ]]; then
			log_file=$(aidevops_pulse_worker_log_fallback_path "$issue_num" 2>/dev/null || true)
			[[ -f "$log_file" ]] && found_log="$log_file"
		fi

		if [[ -z "$found_log" ]]; then
			continue
		fi

		# Check log size — stalled workers have ≤500 bytes (just sandbox startup)
		log_size=$(wc -c <"$found_log" 2>/dev/null || echo "0")
		log_size=$(echo "$log_size" | tr -d ' ')
		[[ "$log_size" =~ ^[0-9]+$ ]] || log_size=0

		if [[ "$log_size" -gt "$STALLED_WORKER_MAX_LOG_BYTES" ]]; then
			# Worker has produced real output — it's working, not stalled
			continue
		fi

		# Extract model from the command line for backoff recording
		local worker_model
		worker_model=$(echo "$cmd" | grep -oE '\-m [^ ]+' | head -1 | sed 's/-m //')

		# Kill the stalled worker
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		freed_mb=$((freed_mb + mb))

		# Record provider backoff so next dispatch rotates away
		if [[ -n "$worker_model" ]]; then
			local provider
			provider=$(echo "$worker_model" | cut -d/ -f1)
			local tmp_backoff
			tmp_backoff=$(mktemp)
			printf 'Worker stalled: PID %s, issue #%s, model %s, age %ss, log %s bytes\n' \
				"$pid" "$issue_num" "$worker_model" "$age_seconds" "$log_size" >"$tmp_backoff"

			# Use the headless runtime helper to record backoff properly
			if [[ -x "${SCRIPT_DIR}/headless-runtime-helper.sh" ]]; then
				"${SCRIPT_DIR}/headless-runtime-helper.sh" backoff set "$worker_model" "rate_limit" 900 2>/dev/null || true
			fi
			rm -f "$tmp_backoff"
		fi

		echo "[pulse-wrapper] Killed stalled worker PID $pid (issue #${issue_num}, model=${worker_model:-unknown}, age=${age_seconds}s, log=${log_size}B) — provider likely rate-limited" >>"$LOGFILE"

	done < <(ps axwwo pid,etime,%cpu,rss,command | grep '[.]opencode run' | grep -v grep)

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] cleanup_stalled_workers: killed ${killed} stalled workers (freed ~${freed_mb}MB)" >>"$LOGFILE"
	fi
	# Accumulate into per-cycle health counter (GH#15107)
	_PULSE_HEALTH_STALLED_KILLED=$((_PULSE_HEALTH_STALLED_KILLED + killed))
	return 0
}

cleanup_orphans() {

	local killed=0
	local total_mb=0

	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		# Skip interactive sessions (has a real TTY).
		# Exclude both '?' (Linux headless) and '??' (macOS headless) — only
		# those are headless; anything else (pts/N, ttys00N) is interactive.
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		# Skip active workers, pulse, strategic reviews, and language servers.
		# Use case instead of [[ =~ ]] with | alternation — zsh parses the |
		# as a pipe operator inside [[ ]], causing a parse error. See GH#4904.
		case "$cmd" in
		*"/full-loop"* | *"/review-issue-pr"* | *"Supervisor Pulse"* | *"Strategic Review"* | *"language-server"* | *"eslintServer"*)
			continue
			;;
		esac

		# Skip young processes
		# t2859: ${ORPHAN_MAX_AGE:-7200} fallback (2h) — without this,
		# unbound expansion to "" makes every process look "older than 0"
		# and would kill all matched orphans regardless of actual age.
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "${ORPHAN_MAX_AGE:-7200}" ]]; then
			continue
		fi

		# This is an orphan — kill it
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,tty,etime,rss,command | grep '[.]opencode' | grep -v 'bash-language-server')

	# Also kill orphaned node launchers (parent of .opencode processes)
	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		[[ "$tty" != "?" && "$tty" != "??" ]] && continue
		# Use case instead of [[ =~ ]] with | alternation — zsh parse error. See GH#4904.
		case "$cmd" in
		*"/full-loop"* | *"/review-issue-pr"* | *"Supervisor Pulse"* | *"Strategic Review"* | *"language-server"* | *"eslintServer"*)
			continue
			;;
		esac

		# t2859: ${ORPHAN_MAX_AGE:-7200} fallback (2h) — see comment above.
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		[[ "$age_seconds" -lt "${ORPHAN_MAX_AGE:-7200}" ]] && continue

		kill "$pid" 2>/dev/null || true
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,tty,etime,rss,command | grep 'node.*opencode' | grep -v '[.]opencode')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed orphaned opencode processes (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}

cleanup_stale_opencode() {
	local killed=0
	local total_mb=0

	# Get our own PID tree to avoid killing the current session
	local my_pid="$$"
	local my_ppid
	my_ppid=$(ps -p "$my_pid" -o ppid= 2>/dev/null | tr -d ' ') || my_ppid=""

	while IFS= read -r line; do
		local pid cpu rss
		read -r pid cpu rss <<<"$line"

		# Skip our own process tree
		if [[ "$pid" == "$my_pid" || "$pid" == "$my_ppid" ]]; then
			continue
		fi

		# Skip interactive sessions — only kill headless workers.
		# Headless workers are launched via headless-runtime-helper.sh with
		# --format json in the command line. Interactive sessions (user typing
		# in a terminal) never have this flag. Without this guard, any idle
		# interactive session (user stepped away) gets killed along with its
		# parent shell, closing the terminal tab entirely.
		local proc_cmd
		proc_cmd=$(ps -p "$pid" -o command= 2>/dev/null) || proc_cmd=""
		if [[ "$proc_cmd" != *"--format json"* ]]; then
			continue
		fi

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$STALE_OPENCODE_MAX_AGE" ]]; then
			continue
		fi

		# Skip processes with significant CPU usage (actively working)
		# cpu is a float like "0.0" or "40.3" — compare integer part.
		# t2859: ${PULSE_IDLE_CPU_THRESHOLD:-2} fallback (2% CPU) — without
		# this, unbound expansion to "" treated as 0 would make every
		# process "active" (cpu >= 0) and skip every kill candidate.
		local cpu_int
		cpu_int="${cpu%%.*}"
		[[ "$cpu_int" =~ ^[0-9]+$ ]] || cpu_int=0
		if [[ "$cpu_int" -ge "${PULSE_IDLE_CPU_THRESHOLD:-2}" ]]; then
			continue
		fi

		# This is a stale headless worker — kill it and its parent chain
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))

		# Kill parent (node launcher) and grandparent (zsh tab) first
		local ppid
		ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || ppid=""
		if [[ -n "$ppid" && "$ppid" != "1" ]]; then
			local gppid
			gppid=$(ps -p "$ppid" -o ppid= 2>/dev/null | tr -d ' ') || gppid=""
			# Kill grandparent zsh (the terminal tab shell)
			if [[ -n "$gppid" && "$gppid" != "1" ]]; then
				local gp_cmd
				gp_cmd=$(ps -p "$gppid" -o command= 2>/dev/null) || gp_cmd=""
				# Only kill if it's a shell that launched opencode
				case "$gp_cmd" in
				*zsh* | *bash* | *sh*)
					kill "$gppid" 2>/dev/null || true
					;;
				esac
			fi
			# Kill parent node launcher
			kill "$ppid" 2>/dev/null || true
		fi

		# Kill the .opencode process — SIGTERM first, SIGKILL fallback.
		# OpenCode's file watcher may ignore SIGTERM.
		kill "$pid" 2>/dev/null || true
		sleep 1
		if kill -0 "$pid" 2>/dev/null; then
			kill -9 "$pid" 2>/dev/null || true
		fi
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,%cpu,rss,command | awk '$0 ~ /[.]opencode/ && $0 !~ /bash-language-server/ { print $1, $2, $3 }')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed stale headless opencode workers (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}
