#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Cleanup Worktree State Library
# =============================================================================
# Branch, PR, age, ownership, audit, and orphan classification helpers.
#
# Sourced by pulse-cleanup.sh; dependencies and configuration are provided by
# the pulse-wrapper orchestrator.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_CLEANUP_WORKTREE_STATE_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_WORKTREE_STATE_LOADED=1
_PC_STATE_SKIPPED="skipped"
_PC_STATE_UNKNOWN="unknown"
_PC_ARCHIVE_ATTRIBUTION_UNCLEAR="archive-attribution-unclear"

if [[ -z "${_PULSE_CLEANUP_SCRIPT_DIR:-}" ]]; then
	_pulse_cleanup_worktree_state_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pulse_cleanup_worktree_state_path" == "${BASH_SOURCE[0]}" ]] && _pulse_cleanup_worktree_state_path="."
	_PULSE_CLEANUP_SCRIPT_DIR="$(cd "$_pulse_cleanup_worktree_state_path" && pwd)"
	unset _pulse_cleanup_worktree_state_path
fi

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
# Resolve the state of a PR number embedded in a local repair/review branch.
#
# CI-repair workers commit on a local `repair/<hash>-pr-<N>-...` branch but
# push back to the contributor's original PR branch. A head-branch lookup for
# the local repair branch therefore cannot find that PR; the embedded number
# is the durable lookup key.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - local branch name
# Outputs: PR state (OPEN|CLOSED|MERGED)
# Returns: 0 when a referenced PR state was verified, 1 otherwise
#######################################
_pc_pr_state_for_branch_reference() {
	local repo_slug="$1"
	local branch_name="$2"
	local pr_number=""
	local pr_state=""

	[[ -n "$repo_slug" && -n "$branch_name" ]] || return 1
	pr_number=$(_pc_pr_from_branch "$branch_name" 2>/dev/null) || return 1
	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
	pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state // ""' 2>/dev/null) || return 1
	case "$pr_state" in
	OPEN | CLOSED | MERGED)
		printf '%s\n' "$pr_state"
		return 0
		;;
	esac
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
	local referenced_pr_state=""

	if [[ -z "$repo_slug" || -z "$branch_name" || -z "$pr_state" ]]; then
		return 1
	fi

	pr_number=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" --state "$pr_state" --limit 1 --json number --jq '.[].number // empty') || true
	if [[ -n "$pr_number" ]]; then
		return 0
	fi

	# CI-repair branches are deliberately local-only, so their actual PR cannot
	# be found by `--head`. Preserve open repairs and recognize terminal ones by
	# the immutable PR number embedded in the branch name.
	referenced_pr_state=$(_pc_pr_state_for_branch_reference "$repo_slug" "$branch_name" 2>/dev/null) || return 1
	case "${pr_state}:${referenced_pr_state}" in
	open:OPEN | closed:CLOSED | closed:MERGED | merged:MERGED | all:OPEN | all:CLOSED | all:MERGED)
		return 0
		;;
	esac
	return 1
}

#######################################
# Verify that branch PR evidence is readable and has no open handoff.
#
# An empty successful query proves no head PR. A terminal head/reference PR is
# safe for archive-backed cleanup; OPEN, malformed, or unavailable evidence is
# a hard veto.
#
# Args:
#   $1 - repository slug
#   $2 - branch name
# Returns: 0 when PR state is clear for archival, 1 otherwise
#######################################
_pc_branch_archive_pr_state_clear() {
	local repo_slug="$1"
	local branch_name="$2"
	local states=""
	local state=""
	local referenced_number=""

	[[ -n "$repo_slug" && -n "$branch_name" ]] || return 1
	states=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" --state all \
		--limit 10 --json state --jq '.[].state // empty' 2>/dev/null) || return 1
	while IFS= read -r state; do
		[[ -n "$state" ]] || continue
		case "$state" in
		CLOSED | MERGED) ;;
		*) return 1 ;;
		esac
	done <<<"$states"
	if [[ -n "$states" ]]; then
		return 0
	fi

	referenced_number=$(_pc_pr_from_branch "$branch_name" 2>/dev/null || true)
	[[ -n "$referenced_number" ]] || return 0
	state=$(_pc_pr_state_for_branch_reference "$repo_slug" "$branch_name" 2>/dev/null) || return 1
	case "$state" in
	CLOSED | MERGED) return 0 ;;
	esac
	return 1
}

#######################################
# Return terminal PR state and identity for a branch head, if GitHub verifies one.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - branch name
# Outputs: tab-separated terminal PR state (CLOSED|MERGED) and PR number
# Returns: 0 when terminal PR found, 1 otherwise
#######################################
_pc_terminal_pr_for_branch() {
	local repo_slug="$1"
	local branch_name="$2"
	local pr_state=""
	local pr_number=""
	local pr_record=""
	local open_pr=""

	[[ -n "$repo_slug" && -n "$branch_name" ]] || return 1
	# A branch can have multiple historical PRs: no terminal result may hide a
	# still-open handoff. Query that veto independently of terminal pagination.
	open_pr=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" --state open --limit 1 \
		--json number --jq '.[0].number // empty' 2>/dev/null) || return 1
	[[ -z "$open_pr" ]] || return 1
	pr_record=$(gh_pr_list --repo "$repo_slug" --head "$branch_name" --state all --limit 1 --json state,number \
		--jq '.[0] | select(. != null) | [.state, .number] | @tsv' 2>/dev/null) || return 1
	IFS=$'\t' read -r pr_state pr_number <<<"$pr_record"
	case "$pr_state" in
	CLOSED | MERGED)
		[[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1
		printf '%s\t%s\n' "$pr_state" "$pr_number"
		return 0
		;;
	esac
	# A directly associated OPEN PR outranks any numeric token embedded in the
	# branch name. Only fall back when the local-only branch has no head PR.
	[[ -z "$pr_record" ]] || return 1

	pr_number=$(_pc_pr_from_branch "$branch_name" 2>/dev/null) || return 1
	[[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1
	pr_state=$(_pc_pr_state_for_branch_reference "$repo_slug" "$branch_name" 2>/dev/null) || return 1
	case "$pr_state" in
	CLOSED | MERGED)
		printf '%s\t%s\n' "$pr_state" "$pr_number"
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
# Verify terminal remote evidence for a PR-attributed detached worktree.
#
# Args:
#   $1 - PR number
#   $2 - repository slug
# Returns: 0 for CLOSED/MERGED, 1 for OPEN/unknown/unavailable
#######################################
_pc_pr_archive_state_clear() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_state=""

	[[ "$pr_number" =~ ^[1-9][0-9]*$ && -n "$repo_slug" ]] || return 1
	pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state \
		--jq '.state // empty' 2>/dev/null) || return 1
	case "$pr_state" in
	CLOSED | MERGED) return 0 ;;
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
	stat_audit_context=$(_pc_worktree_audit_context "$wt_branch_age" "$stat_issue_num" 0 0 0 "$_PC_STATE_UNKNOWN" "$_PC_STATE_UNKNOWN" "$_PC_STATE_UNKNOWN" "$_PC_STATE_UNKNOWN" "stat-unavailable")
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "stat-unavailable" "$_PC_STATE_SKIPPED" "$stat_audit_context"
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
	log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path_age" "not-age-eligible" "$_PC_STATE_SKIPPED" "$audit_context"
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

#######################################
# Verify that compact archival is allowed for a failed/completed worker.
#
# Local marker files and remote task labels are hard vetoes. A failed label
# lookup is also a veto because cleanup cannot prove that forensics/security
# retention is unnecessary.
#
# Args:
#   $1 - worktree path
#   $2 - issue or PR number
#   $3 - repository slug
#   $4 - target type: issue or pr
#   $5 - optional branch issue whose retention policy must also pass for a PR
# Outputs: a short skip reason when blocked
# Returns: 0 when archival may proceed, 1 otherwise
#######################################
_pc_compact_archive_policy_clear() {
	local wt_path="$1"
	local target_number="$2"
	local repo_slug="$3"
	local target_type="$4"
	local branch_issue="${5:-}"
	local labels=""
	local label=""
	local normalized_label=""

	[[ -n "$wt_path" && "$target_number" =~ ^[1-9][0-9]*$ ]] || {
		printf '%s\n' "$_PC_ARCHIVE_ATTRIBUTION_UNCLEAR"
		return 1
	}
	[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
		printf '%s\n' "$_PC_ARCHIVE_ATTRIBUTION_UNCLEAR"
		return 1
	}
	case "$target_type" in
	issue | pr) ;;
	*)
		printf '%s\n' "$_PC_ARCHIVE_ATTRIBUTION_UNCLEAR"
		return 1
		;;
	esac

	if [[ -e "$wt_path/.aidevops-preserve-forensics" ||
		-e "$wt_path/.preserve-forensics" ||
		-e "$wt_path/.aidevops-security-incident" ]]; then
		printf '%s\n' "preserve-forensics"
		return 1
	fi

	labels=$(gh "$target_type" view "$target_number" --repo "$repo_slug" \
		--json labels --jq '.labels[].name' 2>/dev/null) || {
		printf '%s\n' "archive-policy-unverified"
		return 1
	}
	while IFS= read -r label; do
		[[ -n "$label" ]] || continue
		normalized_label=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')
		case "$normalized_label" in
		preserve-forensics | security | security-incident | incident:security | status:blocked)
			printf '%s\n' "protected-${normalized_label//:/-}"
			return 1
			;;
		esac
	done <<<"$labels"
	if [[ "$target_type" == "issue" ]] &&
		_consecutive_zero_session_failures "$target_number" "$repo_slug" 2; then
		printf '%s\n' "protected-repeated-failures"
		return 1
	fi

	if [[ "$target_type" == "pr" && "$branch_issue" =~ ^[1-9][0-9]*$ ]]; then
		_pc_compact_archive_policy_clear "$wt_path" "$branch_issue" "$repo_slug" "issue" || return 1
	fi
	return 0
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
# Move a path to system trash without a permanent-delete fallback (GH#19042).
# Mirrors worktree-helper.sh trash_path() so Pass 2 orphan cleanup gets
# the same recoverability as Pass 1 (which calls worktree-helper.sh clean).
# Prefers: trash CLI (macOS Homebrew), then gio trash (Linux).
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
		repo_records=$(jq -r --arg unknown "$_PC_STATE_UNKNOWN" '.initialized_repos[] | select((.local_only // false) == false) | [.path // "", .slug // $unknown] | @tsv' "$repos_json" || echo "")

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
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" "owned-skip" "$_PC_STATE_SKIPPED"
		return 0
	fi

	# Registry check (GH#18021): covers MCP-dispatch runtimes where the
	# worktree path never appears in process argv.
	if is_worktree_owned_by_others "$wt_path"; then
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch:-detached} ($wt_path) — registered owner alive in registry" >>"$LOGFILE"
		# t2976: audit log — orphan cleanup blocked, registry owner is alive
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" "owned-skip" "$_PC_STATE_SKIPPED"
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
				log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_PC_CALLER" "$wt_path" "active-claim" "$_PC_STATE_SKIPPED"
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
# The body intentionally does NOT remove auto-dispatch — that's the caller's
# job. It carries the backward-compatible `dispatch-infrastructure-failure`
# marker while `status:blocked` provides the machine-recoverable dispatch fuse.
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
3. Once the underlying issue is fixed and no recoverable worker output remains, restore \`status:available\`.

### Why dispatch is paused

Re-dispatching this issue without a setup-side fix would (a) burn another worker on the same failure mode, (b) not surface diagnostics the maintainer hasn't already seen, and (c) progress the cost circuit breaker without producing useful output. The \`status:blocked\` lifecycle state + \`dispatch-infrastructure-failure\` marker pause the dispatch loop until the failure family is fixed.
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
# consecutive zero-session releases are detected, apply `status:blocked` with a
# dispatch-infrastructure-failure marker instead of re-dispatching — the loop
# won't break by retrying.
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
	# workers in setup. Apply status:blocked with the
	# dispatch-infrastructure-failure marker so the dispatch loop pauses until a
	# maintainer fixes the underlying setup-side issue. Best-effort, idempotent: failure
	# falls through to the legacy "Worker failed" comment path below.
	# Skip when AIDEVOPS_SKIP_INFRA_FAILURE_ESCALATION=1 (test/diagnostic bypass).
	if [[ "${AIDEVOPS_SKIP_INFRA_FAILURE_ESCALATION:-0}" != "1" ]] \
		&& _consecutive_zero_session_failures "$orphan_issue_num" "$repo_slug_age" 2; then
		echo "[pulse-wrapper] Orphan cleanup: dispatch-infrastructure-failure detected for #${orphan_issue_num} (${repo_slug_age}) — applying status:blocked" >>"$LOGFILE"
		if declare -F set_issue_status >/dev/null 2>&1; then
			set_issue_status "$orphan_issue_num" "$repo_slug_age" "blocked" >/dev/null 2>&1 || true
		else
			gh issue edit "$orphan_issue_num" --repo "$repo_slug_age" \
				--add-label "status:blocked" >/dev/null 2>&1 || true
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
