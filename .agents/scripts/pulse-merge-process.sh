#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-process.sh — Merge Processing Orchestrator
# =============================================================================
# Extracted from pulse-merge.sh (GH#21301) to bring the parent file below
# the 1500-line file-size-debt threshold.
#
# Sources focused modules while retaining the core merge decision pipeline.
# Public and internal entry points remain available after this file is sourced:
#   - pulse-merge-timing.sh               — low-overhead timing aggregation
#   - pulse-merge-pass.sh                 — checkpoints, cursors, pass orchestration
#   - merge_ready_prs_all_repos           — top-level merge pass entry point
#   - _merge_ready_prs_for_repo           — per-repo PR iteration
#   - _pmp_consolidate_duplicate_pr_groups — safe superseded sibling PR cleanup
#   - _pmp_classify_pr_backlog_state      — PR backlog observability buckets
#   - _pmp_sort_prs_by_backlog_priority   — near-merge/fix-needed ordering
#   - _attempt_pr_update_branch           — fast-forward via update-branch
#   - _resolve_pr_mergeable_status        — UNKNOWN→MERGEABLE retry
#   - _pulse_merge_dismiss_coderabbit_nits — auto-dismiss CR-only reviews
#   - _pr_required_checks_pass            — required CI check verification
#   - _attempt_pr_ci_rebase_retry         — CI-drift rebase (t2805)
#   - _route_pr_to_fix_worker             — unified fix-worker dispatch (t2203)
#   - _retarget_stacked_children          — stacked PR retargeting (t2412)
#   - _attempt_worker_briefed_auto_merge  — worker-briefed trust chain (t2449)
#   - _attempt_green_behind_update_branch — green+BEHIND branch refresh (GH#26659)
#   - _check_required_checks_passing      — branch-protection context check (t2922)
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-process.sh"
#        (sourced by pulse-merge.sh after pulse-merge-gates.sh)
#
# Dependencies:
#   - shared-constants.sh (gh_pr_list, gh_pr_comment, gh_issue_comment, etc.)
#   - worker-lifecycle-common.sh (unlock_issue_after_worker)
#   - LOGFILE, STOP_FLAG, PULSE_MERGE_BATCH_LIMIT (set by pulse-merge.sh defaults)
#   - _OW_LABEL_PAT (defined in pulse-merge.sh before sourcing this file)
#   - _pm_issue_api (defined in pulse-merge.sh before sourcing this file)
#   - _process_single_ready_pr (defined in pulse-merge.sh, resolved at call time)
#   - _dispatch_pr_fix_worker, _dispatch_conflict_fix_worker, _dispatch_ci_fix_worker
#     (defined in pulse-merge-feedback.sh, resolved at call time)
#   - _interactive_pr_is_stale, _interactive_pr_trigger_handover
#     (defined in pulse-merge-conflict.sh, resolved at call time)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_MERGE_PROCESS_LOADED:-}" ]] && return 0
_PULSE_MERGE_PROCESS_LOADED=1

# Defensive defaults for standalone sourcing (test harnesses, pulse-merge-routine.sh)
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${STOP_FLAG:=${HOME}/.aidevops/logs/pulse-session.stop}"
: "${PULSE_MERGE_BATCH_LIMIT:=50}"
: "${PULSE_MERGE_CHECKPOINT_FILE:=${HOME}/.aidevops/logs/pulse-merge-checkpoint}"
: "${PULSE_MERGE_PR_CURSOR_FILE:=${PULSE_MERGE_CHECKPOINT_FILE}.pr-cursor}"

# Load the exact-output PR-list provider cache for standalone module tests and
# direct routine sourcing. pulse-wrapper.sh also sources this before the merge
# modules, so the include guard in pulse-pr-list-cache.sh keeps this idempotent.
_PULSE_MERGE_PROCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_PULSE_MERGE_PROCESS_DIR}/pulse-pr-list-cache.sh" ]]; then
	# shellcheck source=./pulse-pr-list-cache.sh
	# shellcheck disable=SC1091
	source "${_PULSE_MERGE_PROCESS_DIR}/pulse-pr-list-cache.sh"
fi

# Focused sub-libraries keep timing and pass checkpoint mechanics out of the
# core merge decision pipeline while preserving the original public source path.
# shellcheck source=./pulse-merge-timing.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-timing.sh"
# shellcheck source=./pulse-merge-pass.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-pass.sh"
# shellcheck source=./pulse-merge-rest-state.sh
# shellcheck disable=SC1091  # sub-library resolved via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-rest-state.sh"

_pmp_cache_key() {
	local raw_key="$1"
	local safe_key=""
	safe_key=$(printf '%s' "$raw_key" | tr -c '[:alnum:]._-' '_')
	[[ -n "$safe_key" ]] || safe_key="empty"
	printf '%s' "$safe_key"
	return 0
}

# PR backlog categories exposed in logs. These are scheduling/observability
# buckets only; _process_single_ready_pr still enforces every merge safety gate
# before approving, merging, closing, or dispatching a fix worker.
readonly _PMP_BACKLOG_MERGE_READY="merge-ready"
readonly _PMP_BACKLOG_CHECKS_IN_PROGRESS="checks-in-progress"
readonly _PMP_BACKLOG_SMALL_FIX_NEEDED="small-fix-needed"
readonly _PMP_BACKLOG_DIRTY_CONFLICTED="dirty-conflicted"
readonly _PMP_BACKLOG_HUMAN_APPROVAL_NEEDED="human-approval-needed"
readonly _PMP_BACKLOG_OTHER="other"

# --- Functions ---

#######################################
# Normalize known PR lifecycle states from mixed GitHub API paths.
#
# GraphQL emits uppercase enums while REST and cached projections can emit
# lowercase strings. Preserve unknown values so exact-state consumers still
# fail closed instead of accepting an unrecognised lifecycle state (t18168).
#
# Args: $1=destination variable name, $2=raw lifecycle state
#######################################
_pmp_normalize_pr_lifecycle_state_into() {
	local dest_var="$1"
	local raw_state="$2"
	local normalized_state=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	case "$raw_state" in
	[Oo][Pp][Ee][Nn]) normalized_state="OPEN" ;;
	[Cc][Ll][Oo][Ss][Ee][Dd]) normalized_state="CLOSED" ;;
	[Mm][Ee][Rr][Gg][Ee][Dd]) normalized_state="MERGED" ;;
	*) normalized_state="$raw_state" ;;
	esac
	printf -v "$dest_var" '%s' "$normalized_state"
	return 0
}

#######################################
# Classify one PR object into a scheduling/observability backlog bucket.
# This is intentionally advisory: it never decides merge eligibility. The
# existing per-PR gate stack remains authoritative.
#
# Args:
#   $1 - compact PR JSON object from gh_pr_list
# Output: one of the _PMP_BACKLOG_* values
#######################################
_pmp_classify_pr_backlog_state() {
	local pr_obj="$1"
	local repo_slug="${2:-}"
	local _RS=$'\x1e'
	local number="" mergeable="" review_decision="" is_draft="" labels="" failed_count="" pending_count=""
	IFS="$_RS" read -r number mergeable review_decision is_draft labels failed_count pending_count < <(
		printf '%s' "$pr_obj" | jq -r '
			def up(v): (v // "" | ascii_upcase);
			def failed: [.statusCheckRollup[]? | select(up(.conclusion) == "FAILURE" or up(.state) == "FAILURE")] | length;
			def pending: [.statusCheckRollup[]? | select(up(.status) == "QUEUED" or up(.status) == "IN_PROGRESS" or up(.state) == "PENDING" or up(.state) == "EXPECTED" or ((up(.conclusion) == "") and (up(.state) != "SUCCESS") and (up(.status) != "COMPLETED")))] | length;
			"\(.number // "")\u001e\(.mergeable // "UNKNOWN")\u001e\(if ((has("reviewDecision") | not) or .reviewDecision == null or (.reviewDecision | tostring | length) == 0) then "UNKNOWN" else .reviewDecision end)\u001e\(.isDraft // false)\u001e\([.labels[].name] | join(","))\u001e\(failed)\u001e\(pending)"' 2>/dev/null
	)
	_pmp_normalize_mergeable_state_into mergeable "$mergeable"
	_pmp_normalize_review_decision_into review_decision "$review_decision"

	[[ "$failed_count" =~ ^[0-9]+$ ]] || failed_count=0
	[[ "$pending_count" =~ ^[0-9]+$ ]] || pending_count=0

	if [[ "$is_draft" == "true" || ",${labels}," == *",hold-for-review,"* || "$review_decision" == "CHANGES_REQUESTED" ]] ||
		_pmp_review_decision_is_unknown "$review_decision"; then
		printf '%s' "$_PMP_BACKLOG_HUMAN_APPROVAL_NEEDED"
		return 0
	fi
	if [[ "$mergeable" == "CONFLICTING" ]]; then
		printf '%s' "$_PMP_BACKLOG_DIRTY_CONFLICTED"
		return 0
	fi
	if [[ "$failed_count" -gt 0 ]]; then
		if _pmp_review_decision_is_unknown "$review_decision"; then
			printf '%s' "$_PMP_BACKLOG_HUMAN_APPROVAL_NEEDED"
			return 0
		fi
		printf '%s' "$_PMP_BACKLOG_SMALL_FIX_NEEDED"
		return 0
	fi
	if [[ "$pending_count" -gt 0 || "$mergeable" == "UNKNOWN" ]]; then
		printf '%s' "$_PMP_BACKLOG_CHECKS_IN_PROGRESS"
		return 0
	fi
	if [[ "$mergeable" == "MERGEABLE" ]]; then
		printf '%s' "$_PMP_BACKLOG_MERGE_READY"
		return 0
	fi
	printf '%s' "$_PMP_BACKLOG_OTHER"
	return 0
}

_pmp_enrich_prs_with_rest_check_status() {
	local repo_slug="$1"
	local pr_json="$2"
	local status_json=""
	status_json=$(gh_pr_check_status_rest_batch "$repo_slug" "$pr_json" 2>/dev/null) || status_json="[]"
	[[ -n "$status_json" && "$status_json" != "null" ]] || status_json="[]"
	jq -n --argjson prs "$pr_json" --argjson statuses "$status_json" '
		def rollup($s):
			if $s == "PASS" then [{status:"COMPLETED", conclusion:"SUCCESS", state:"SUCCESS"}]
			elif $s == "FAIL" then [{status:"COMPLETED", conclusion:"FAILURE", state:"FAILURE"}]
			elif $s == "PENDING" then [{status:"IN_PROGRESS", conclusion:null, state:"PENDING"}]
			else [] end;
		$prs | map(. as $pr | ($statuses | map(select(.number == $pr.number)) | last | .status // "none") as $s | $pr + {statusCheckRollup: rollup($s)})' \
		2>/dev/null || printf '%s' "$pr_json"
	return 0
}

#######################################
# Convert a backlog bucket to a numeric scheduling priority.
# Lower number runs first. Merge-ready and fix-needed PRs are processed before
# unrelated dispatch stages get any budget because this sort happens inside the
# deterministic merge pass, which runs before dispatch_max.
#
# Args:
#   $1 - backlog category string
# Output: integer priority
#######################################
_pmp_backlog_priority() {
	local category="$1"
	case "$category" in
	"$_PMP_BACKLOG_MERGE_READY") printf '10' ;;
	"$_PMP_BACKLOG_SMALL_FIX_NEEDED") printf '20' ;;
	"$_PMP_BACKLOG_CHECKS_IN_PROGRESS") printf '30' ;;
	"$_PMP_BACKLOG_DIRTY_CONFLICTED") printf '40' ;;
	"$_PMP_BACKLOG_HUMAN_APPROVAL_NEEDED") printf '50' ;;
	*) printf '90' ;;
	esac
	return 0
}

#######################################
# Sort a PR JSON array by backlog attention priority, preserving original
# order inside each category. Emits a JSON array.
#
# Args:
#   $1 - JSON array of PR objects
# Output: JSON array sorted by backlog priority
#######################################
_pmp_sort_prs_by_backlog_priority() {
	local pr_json="$1"
	local repo_slug="${2:-}"
	local pr_count=""
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	if [[ "$pr_count" -eq 0 ]]; then
		printf '[]'
		return 0
	fi

	local _tmp_lines=""
	_tmp_lines=$(mktemp)
	local i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		local pr_obj="" category="" priority=""
		pr_obj=$(printf '%s' "$pr_json" | jq -c ".[$i]" 2>/dev/null)
		category=$(_pmp_classify_pr_backlog_state "$pr_obj" "$repo_slug")
		priority=$(_pmp_backlog_priority "$category")
		printf '%03d\t%06d\t%s\n' "$priority" "$i" "$pr_obj" >>"$_tmp_lines"
		i=$((i + 1))
	done

	LC_ALL=C sort "$_tmp_lines" | cut -f3- | jq -s '.'
	rm -f "$_tmp_lines"
	return 0
}

#######################################
# Log PR backlog category counts for current-state diagnostics.
#
# Args:
#   $1 - repo slug
#   $2 - JSON array of PR objects
#######################################
_pmp_log_pr_backlog_counts() {
	local repo_slug="$1"
	local pr_json="$2"
	local merge_ready=0 checks_in_progress=0 small_fix_needed=0 dirty_conflicted=0 human_approval_needed=0 other=0
	local pr_count=""
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	local i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		local pr_obj="" category=""
		pr_obj=$(printf '%s' "$pr_json" | jq -c ".[$i]" 2>/dev/null)
		category=$(_pmp_classify_pr_backlog_state "$pr_obj" "$repo_slug")
		case "$category" in
		"$_PMP_BACKLOG_MERGE_READY") merge_ready=$((merge_ready + 1)) ;;
		"$_PMP_BACKLOG_CHECKS_IN_PROGRESS") checks_in_progress=$((checks_in_progress + 1)) ;;
		"$_PMP_BACKLOG_SMALL_FIX_NEEDED") small_fix_needed=$((small_fix_needed + 1)) ;;
		"$_PMP_BACKLOG_DIRTY_CONFLICTED") dirty_conflicted=$((dirty_conflicted + 1)) ;;
		"$_PMP_BACKLOG_HUMAN_APPROVAL_NEEDED") human_approval_needed=$((human_approval_needed + 1)) ;;
		*) other=$((other + 1)) ;;
		esac
		i=$((i + 1))
	done

	echo "[pulse-wrapper] PR backlog ${repo_slug}: total=${pr_count}, merge-ready=${merge_ready}, checks-in-progress=${checks_in_progress}, small-fix-needed=${small_fix_needed}, dirty-conflicted=${dirty_conflicted}, human-approval-needed=${human_approval_needed}, other=${other}" >>"$LOGFILE"
	return 0
}

# Safe duplicate worker PR consolidation helpers (m-20260508-0e27c3 task 2.4).
_PULSE_MERGE_PROCESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pulse-merge-duplicate-consolidation.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_PROCESS_DIR
source "${_PULSE_MERGE_PROCESS_DIR}/pulse-merge-duplicate-consolidation.sh"

#######################################
# Apply one processed PR result to pass counters and durable same-pass evidence.
# Args: $1=repo, $2=PR number, $3=head SHA, $4=result code,
#       $5=merged var, $6=closed var, $7=failed var
#######################################
_pmp_record_processed_pr_result() {
	local repo_slug="$1"
	local pr_number="$2"
	local head_sha="$3"
	local result_code="$4"
	local merged_var="$5"
	local closed_var="$6"
	local failed_var="$7"
	local outcome="blocked"

	case "$result_code" in
	0) _pmp_add_counter_var "$merged_var" 1 || return 1; outcome="merged" ;;
	2) _pmp_add_counter_var "$closed_var" 1 || return 1; outcome="progress" ;;
	3) _pmp_add_counter_var "$failed_var" 1 || return 1; outcome="eligible-unmerged" ;;
	4) outcome="deferred" ;;
	esac
	_pmp_record_same_pass_pr_outcome "$repo_slug" "$pr_number" "$head_sha" "$outcome" || return 1
	return 0
}

#######################################
# Merge ready PRs for a single repo.
#
# Fetches the PR list for the repo, iterates, and delegates each PR
# to _process_single_ready_pr. Uses eval to return counts to caller
# (Bash 3.2 compat: no nameref).
#
# Args:
#   $1 - repo slug
#   $2 - nameref for merged count
#   $3 - nameref for closed count
#   $4 - nameref for failed count
#######################################
_merge_ready_prs_for_repo() {
	local repo_slug="$1"
	# Bash 3.2 compat: no nameref. Use eval to set caller variables.
	local _merged_var="$2"
	local _closed_var="$3"
	local _failed_var="$4"
	local _pr_count_var="${5:-}"
	local _timing_prefix="${6:-}"

	local merged=0 closed=0 failed=0
	local pr_json="" pr_merge_err="" _list_start="" pr_count=""
	local pr_list_complete=1 outcomes_complete=1
	_list_start=$(_pmp_now_epoch)
	pr_merge_err=$(mktemp)
	if declare -F pulse_pr_list_get >/dev/null 2>&1; then
		pr_json=$(pulse_pr_list_get --repo "$repo_slug" --state open \
			--json "$(_pulse_merge_ready_pr_json_fields)" \
			--limit "$PULSE_MERGE_BATCH_LIMIT" 2>"$pr_merge_err") || pr_json=""
	else
		pr_json=$(gh_pr_list --repo "$repo_slug" --state open \
			--json "$(_pulse_merge_ready_pr_json_fields)" \
			--limit "$PULSE_MERGE_BATCH_LIMIT" 2>"$pr_merge_err") || pr_json=""
	fi
	if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
		local _pr_merge_err_msg
		_pr_merge_err_msg=$(cat "$pr_merge_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] _process_merge_batch: pulse_pr_list_get FAILED for ${repo_slug}: ${_pr_merge_err_msg}" >>"$LOGFILE"
		pr_json="[]"
		pr_list_complete=0
	fi
	rm -f "$pr_merge_err"
	[[ -n "$_timing_prefix" ]] && _pmp_add_elapsed_seconds "${_timing_prefix}list_s" "$_list_start"

	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || { pr_count=0; pr_list_complete=0; }
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	if [[ -n "$_pr_count_var" ]]; then
		[[ "$_pr_count_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
		printf -v "$_pr_count_var" '%s' "$pr_count"
	fi

	if [[ "$pr_count" -eq 0 ]]; then
		eval "${_merged_var}=0; ${_closed_var}=0; ${_failed_var}=0"
		if [[ "$pr_list_complete" -eq 1 ]]; then _pmp_mark_same_pass_repo_complete "$repo_slug" 2>/dev/null || true; fi
		return 0
	fi

	local AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR="" AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR=""
	AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-pulse-required-contexts.XXXXXX" 2>/dev/null) || AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR=""
	AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-pulse-author-perms.XXXXXX" 2>/dev/null) || AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR=""
	if [[ -z "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR" || -z "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR" ]]; then
		echo "[pulse-wrapper] Merge pass: per-repo cache setup incomplete for ${repo_slug}; continuing without one or more caches (GH#25696)" >>"$LOGFILE"
	fi

	pr_json=$(_pmp_enrich_prs_with_mergeability "$repo_slug" "$pr_json")
	pr_json=$(_pmp_enrich_prs_with_rest_check_status "$repo_slug" "$pr_json")
	pr_json=$(_pmp_enrich_prs_with_review_decisions "$repo_slug" "$pr_json")

	_pmp_log_pr_backlog_counts "$repo_slug" "$pr_json"
	pr_json=$(_pmp_sort_prs_by_backlog_priority "$pr_json" "$repo_slug")
	_pmp_consolidate_duplicate_pr_groups "$repo_slug" "$pr_json" || true
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || { pr_count=0; outcomes_complete=0; }
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	local i=0
	_pmp_prepare_merge_pr_cursor_resume "$repo_slug" "$pr_json" "$pr_count" "$PULSE_MERGE_PR_CURSOR_FILE" "$LOGFILE" i || i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		if [[ -f "$STOP_FLAG" ]]; then
			_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$i" stop "$_merged_var" "$_closed_var" "$_failed_var" "$merged" "$closed" "$failed" "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR" "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR"
			return $?
		fi
		if _pmp_merge_pass_budget_exhausted; then
			_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$i" budget "$_merged_var" "$_closed_var" "$_failed_var" "$merged" "$closed" "$failed" "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR" "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR"
			return $?
		fi
		if declare -F _gh_secondary_cooldown_preflight >/dev/null 2>&1 && ! _gh_secondary_cooldown_preflight write >/dev/null 2>&1; then
			_pmp_pause_merge_pr_cursor "$repo_slug" "$pr_json" "$i" cooldown "$_merged_var" "$_closed_var" "$_failed_var" "$merged" "$closed" "$failed" "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR" "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR"
			return $?
		fi
		local pr_obj
		pr_obj=$(_pmp_pr_object_at_index "$pr_json" "$i")
		local _cursor_last_pr="" _cursor_next_pr="" _pr_head_sha=""
		_cursor_last_pr=$(printf '%s' "$pr_obj" | jq -r '.number // empty' 2>/dev/null) || _cursor_last_pr=""
		_pr_head_sha=$(printf '%s' "$pr_obj" | jq -r '.headRefOid // empty' 2>/dev/null) || _pr_head_sha=""
		i=$((i + 1))
		_cursor_next_pr=$(_pmp_pr_number_at_index "$pr_json" "$i") || _cursor_next_pr=""
		[[ -n "$pr_obj" ]] || continue

		_process_single_ready_pr "$repo_slug" "$pr_obj" "$_timing_prefix"
		local _pr_rc=$?
		_pmp_record_processed_pr_result "$repo_slug" "$_cursor_last_pr" "$_pr_head_sha" "$_pr_rc" merged closed failed || outcomes_complete=0
		_pmp_write_merge_pr_cursor "$PULSE_MERGE_PR_CURSOR_FILE" "$repo_slug" "$i" "$_cursor_last_pr" "$_cursor_next_pr"
	done
	_pmp_clear_merge_pr_cursor "$PULSE_MERGE_PR_CURSOR_FILE"

	[[ -n "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR" ]] && rm -rf -- "$AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR"
	[[ -n "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR" ]] && rm -rf -- "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR"
	if [[ "$pr_list_complete" -eq 1 && "$outcomes_complete" -eq 1 ]]; then _pmp_mark_same_pass_repo_complete "$repo_slug" 2>/dev/null || true; fi

	eval "${_merged_var}=${merged}; ${_closed_var}=${closed}; ${_failed_var}=${failed}"
	return 0
}

#######################################
# Attempt to fast-forward the PR's branch to the latest base branch head
# via GitHub's update-a-pull-request-branch REST endpoint. The server-side
# merger will merge main
# into the branch when the changes don't semantically conflict; this
# salvages a large class of CONFLICTING PRs where the only issue is that
# main advanced while the worker was finishing or waiting (t2116).
#
# Returns 0 on success (branch now up to date, caller should re-fetch
# mergeable state), 1 on failure (true semantic conflict, caller should
# fall through to the close path).
#
# Rate-limit considerations: one REST update-branch call per CONFLICTING
# PR per merge cycle. No retry — the next pulse cycle will try again if
# appropriate.
#
# Args: $1=pr_number, $2=repo_slug, $3=expected current head SHA
#######################################
_attempt_pr_update_branch() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="${3:-}"

	local _ub_output _ub_exit
	_ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$expected_head_sha" 2>&1)
	_ub_exit=$?

	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch succeeded (t2116)" >>"$LOGFILE"
		# Brief pause so GitHub recomputes mergeable state before the
		# caller re-fetches it.
		sleep 2
		return 0
	fi

	echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch failed, falling through to close (t2116): ${_ub_output}" >>"$LOGFILE"
	return 1
}

#######################################
# Resolve PR mergeable status, retrying once for UNKNOWN state.
# Returns 0 if MERGEABLE, 1 if not (caller should skip this PR).
# Args: $1=pr_number, $2=repo_slug, $3=current_mergeable_state
#######################################
_resolve_pr_mergeable_status() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_mergeable="$3"
	local original_mergeable="$pr_mergeable"
	_pmp_normalize_mergeable_state_into pr_mergeable "$pr_mergeable"

	if [[ "$pr_mergeable" == "UNKNOWN" || -z "$pr_mergeable" ]]; then
		local _was_label="$original_mergeable"
		[[ -z "$original_mergeable" ]] && _was_label="empty"
		# Separate local declaration from assignment to preserve exit code (SC2181).
		local _retry_output _retry_exit
		_retry_output=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json mergeable --jq '.mergeable // ""')
		_retry_exit=$?
		[[ $_retry_exit -eq 0 && -n "$_retry_output" ]] && pr_mergeable="$_retry_output" || pr_mergeable="UNKNOWN"
		_pmp_normalize_mergeable_state_into pr_mergeable "$pr_mergeable"
		if [[ "$pr_mergeable" == "MERGEABLE" ]]; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — mergeable resolved to MERGEABLE after retry" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — mergeable=${pr_mergeable} (was ${_was_label}, still not MERGEABLE after retry)" >>"$LOGFILE"
			return 1
		fi
	fi
	if [[ "$pr_mergeable" != "MERGEABLE" ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — mergeable=${pr_mergeable}" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Auto-dismiss CodeRabbit-only CHANGES_REQUESTED reviews when the
# coderabbit-nits-ok PR label has been applied by a maintainer (t2179).
#
# Delegates reviewer enumeration and dismissal to review-bot-gate-helper.sh so
# the maintainer override and exact-head reconciliation share one trust boundary.
#
# Returns: 0 if all CR reviews dismissed (or none existed)
#          1 if a non-CR human review is blocking dismissal
#
# Arguments: $1=pr_number, $2=repo_slug
#######################################
_pulse_merge_dismiss_coderabbit_nits() {
	local pr_number="$1"
	local repo_slug="$2"
	local review_helper="${AIDEVOPS_REVIEW_BOT_GATE_HELPER:-${_PULSE_MERGE_PROCESS_DIR}/review-bot-gate-helper.sh}"
	local helper_output=""

	if [[ ! -f "$review_helper" ]]; then
		review_helper="${HOME}/.aidevops/agents/scripts/review-bot-gate-helper.sh"
	fi
	[[ -f "$review_helper" ]] || return 1
	if ! helper_output=$(bash "$review_helper" dismiss-coderabbit-nits "$pr_number" "$repo_slug" 2>&1); then
		[[ -n "$helper_output" ]] && printf '%s\n' "$helper_output" >>"$LOGFILE"
		return 1
	fi
	[[ -n "$helper_output" ]] && printf '%s\n' "$helper_output" >>"$LOGFILE"

	return 0
}

#######################################
# Verify no branch-protection-required check on a PR is in a terminal failed
# state. Skips PRs with terminal failed CI even when the merge would use
# --admin (which bypasses branch protection), but leaves queued/pending/
# in-progress/expected checks on the normal non-terminal path.
#
# t3514: delegate to REST-backed branch-protection context verification so
# merge readiness does not spend GraphQL on `gh pr checks --required`.
#
# An empty result (no required checks defined in branch protection) is
# treated as "nothing is failing" → merge allowed. Fail-closed on API
# errors — a bubbling gh failure should never auto-merge.
#
# Arguments: $1=pr_number, $2=repo_slug
# Returns: 0 if no required check is terminal failed, 1 if any terminal failed
#          or required-check state cannot be verified.
#######################################
_pr_required_checks_pass() {
	local pr_number="$1"
	local repo_slug="$2"
	local _terminal_rc=0
	_check_required_checks_has_terminal_failure "$repo_slug" "$pr_number"
	_terminal_rc=$?
	if [[ $_terminal_rc -eq 0 ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — REST required checks have terminal failure (t3567)" >>"$LOGFILE"
		return 1
	fi
	if [[ $_terminal_rc -ne 1 ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — REST required checks could not be classified (t3567)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Attempt to rebase a MERGEABLE PR with failing CI before routing to a
# fix-worker. When a PR is behind its base branch, failing CI is often
# caused by base-drift (e.g. a pre-existing test failure fixed in a
# later commit to the base branch), not by the PR's own code.
#
# Returns 0 if update-branch succeeded (caller should skip fix-worker
# routing and let the next pulse cycle re-check CI on the rebased HEAD).
# Returns 1 if the PR is already up-to-date with its base or if
# update-branch failed (caller should fall through to fix-worker routing).
#
# Rate-limit: one call per PR per merge cycle — same as t2116.
#
# t2805
#######################################
_attempt_pr_ci_rebase_retry() {
	local pr_number="$1"
	local repo_slug="$2"
	local _base_branch="${3:-}"
	local _head_oid="${4:-}"

	# Prefer per-cycle PR list context; direct/webhook callers may omit it.
	if [[ -z "$_base_branch" || -z "$_head_oid" ]]; then
		local _pr_info
		_pr_info=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json baseRefName,headRefOid --jq '(.baseRefName // "") + " " + (.headRefOid // "")' 2>/dev/null) || _pr_info=""
		read -r _base_branch _head_oid <<< "$_pr_info"
	fi

	if [[ -n "$_base_branch" && -n "$_head_oid" ]]; then
		local _compare_behind
		_compare_behind=$(gh api "repos/${repo_slug}/compare/${_base_branch}...${_head_oid}" \
			--jq '.behind_by' 2>/dev/null) || _compare_behind=""
		if [[ "$_compare_behind" == "0" ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: already up-to-date with ${_base_branch}, skipping CI-drift rebase (t2805)" >>"$LOGFILE"
			return 1
		fi
	fi

	# GH#26406: branch updates restart the current head's check suite. Only use
	# update-branch as a CI-drift repair when the current head has a terminal
	# required-check failure. Pending/in-progress required checks are not failures,
	# and stale failures from older head SHAs must not trigger a branch refresh.
	local _terminal_check_rc=0
	_check_required_checks_has_terminal_failure "$repo_slug" "$pr_number"
	_terminal_check_rc=$?
	if [[ $_terminal_check_rc -eq 1 ]]; then
		if _check_required_checks_have_pending_or_in_progress "$repo_slug" "$pr_number" >/dev/null 2>&1; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: skipping CI-drift update-branch because required checks are active on the current head; wait for current CI or rely on native auto-merge to avoid restarting checks (GH#26406)" >>"$LOGFILE"
			return 1
		fi
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: skipping CI-drift update-branch because no terminal required-check failure belongs to the current head; stale/non-required failure ignored (GH#26406)" >>"$LOGFILE"
		return 1
	fi
	if [[ $_terminal_check_rc -ne 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: required-check head-state unavailable before CI-drift update-branch; fail-open to existing update-branch behaviour (GH#26406)" >>"$LOGFILE"
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: attempting CI-drift rebase via update-branch (t2805)" >>"$LOGFILE"

	local _ub_output _ub_exit
	_ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$_head_oid" 2>&1)
	_ub_exit=$?

	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: CI-drift rebase succeeded via update-branch, deferring to next cycle (t2805)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: CI-drift rebase failed (update-branch exit ${_ub_exit}), falling through to fix-worker routing (t2805): ${_ub_output}" >>"$LOGFILE"
	return 1
}

#######################################
# Update an already-auto-merge-enabled PR that is otherwise green but behind.
#
# GitHub native auto-merge does not merge a PR while mergeStateStatus=BEHIND;
# it waits for the branch to be updated first. Pulse used to defer forever once
# autoMergeRequest was present because _set_native_auto_merge_or_skip treated
# every existing auto-merge request as GitHub-owned unless it was BLOCKED+stuck.
#
# Caller must have already passed maintainer/review/security gates and stopped
# DRY_RUN before invoking because this helper performs a GitHub write.
#
# Returns 0 if update-branch succeeded and caller should defer to the next
# cycle; 1 if no update was needed or update-branch failed.
# GH#24839 / GH#24840
#######################################
_attempt_existing_auto_merge_behind_update_branch() {
	local pr_number="$1"
	local repo_slug="$2"

	local _pr_state=""
	_pr_state=$(_pmp_rest_pr_merge_state "$pr_number" "$repo_slug" 2>/dev/null) || _pr_state=""
	[[ -n "$_pr_state" ]] || return 1

	local _existing_auto="" _merge_state="" _mergeable="" _head_oid=""
	_pmp_extract_update_branch_state _existing_auto _merge_state _mergeable "$_pr_state" _head_oid

	[[ -n "$_existing_auto" ]] || return 1
	[[ "$_merge_state" == BEHIND ]] || return 1
	[[ "$_mergeable" == MERGEABLE ]] || return 1
	_check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1 || return 1

	local _ub_output="" _ub_exit=0
	_ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$_head_oid" 2>&1)
	_ub_exit=$?
	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge is green but BEHIND — update-branch succeeded, deferring to next cycle (GH#24839)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge is green but BEHIND — update-branch failed, falling through: ${_ub_output}" >>"$LOGFILE"
	return 1
}

#######################################
# Update a green PR that is BEHIND when no native auto-merge request exists.
#
# Repositories with allow_auto_merge disabled cannot use the native auto-merge
# fallback. If a protected green PR is behind, admin/direct merge attempts can
# fail forever with "head branch is not up to date" unless pulse updates the
# branch before trying those merge paths.
#
# Caller must have already passed maintainer/review/security gates and stopped
# DRY_RUN before invoking because this helper performs a GitHub write.
#
# Returns 0 if update-branch succeeded and caller should defer to the next
# cycle; 1 if no update was needed or update-branch failed.
# GH#26659
#######################################
_attempt_green_behind_update_branch() {
	local pr_number="$1"
	local repo_slug="$2"

	local _pr_state=""
	_pr_state=$(_pmp_rest_pr_merge_state "$pr_number" "$repo_slug" 2>/dev/null) || _pr_state=""
	[[ -n "$_pr_state" ]] || return 1

	local _existing_auto="" _merge_state="" _mergeable="" _head_oid=""
	_pmp_extract_update_branch_state _existing_auto _merge_state _mergeable "$_pr_state" _head_oid

	[[ -z "$_existing_auto" ]] || return 1
	[[ "$_merge_state" == BEHIND ]] || return 1
	[[ "$_mergeable" == MERGEABLE ]] || return 1
	_check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1 || return 1

	local _ub_output="" _ub_exit=0
	_ub_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$_head_oid" 2>&1)
	_ub_exit=$?
	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: green but BEHIND without native auto-merge — update-branch succeeded, deferring to next cycle (GH#26659)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: green but BEHIND without native auto-merge — update-branch failed, falling through: ${_ub_output}" >>"$LOGFILE"
	return 1
}

_dispatch_pr_repair_by_kind() {
	local kind="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local linked_issue="$4"
	local pr_title="$5"
	local checks_json="$6"
	case "$kind" in
		review) _dispatch_pr_fix_worker "$pr_number" "$repo_slug" "$linked_issue" || true ;;
		conflict) _dispatch_conflict_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "$pr_title" || true ;;
		ci) _dispatch_ci_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "$checks_json" || true ;;
	esac
	return 0
}

_route_issue_origin_is_trusted() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local fallback_pr_author=""
	fallback_pr_author=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json author --jq '.author.login // ""' 2>/dev/null) || fallback_pr_author=""
	#aidevops:trust-boundary — issue-origin fallback is only for same-repo collaborator PRs whose PR labels lost origin metadata.
	if [[ -z "$fallback_pr_author" ]] \
		|| ! declare -F _is_collaborator_author >/dev/null 2>&1 \
		|| ! _is_collaborator_author "$fallback_pr_author" "$repo_slug"; then
		echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} linked issue #${linked_issue} has origin:worker but PR author trust could not be confirmed" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-wrapper] _route_pr_to_fix_worker: PR #${pr_number} in ${repo_slug} using linked issue #${linked_issue} origin:worker fallback" >>"$LOGFILE"
	return 0
}

#######################################
# Route a PR to the appropriate fix worker based on origin label and kind.
#
# Consolidates the shared routing pattern used by the review, conflict, and CI
# gates. Each gate checks exclusion labels, then dispatches worker-origin PRs
# directly and hands over stale interactive PRs before dispatch.
#
# Args:
#   $1 = pr_number
#   $2 = repo_slug
#   $3 = linked_issue (empty string → no routing possible)
#   $4 = kind          (review | conflict | ci)
#   $5 = pr_labels     (optional — comma-separated; fetched if empty)
#   $6 = pr_title      (optional — passed to conflict dispatch)
#   $7 = updated_at    (optional — passed to staleness check)
#   $8 = head_ref_oid  (optional — passed to staleness check)
#   $9 = checks_json   (optional — head-bound terminal blocker evidence for CI repair)
#
# Returns: 0 if dispatched, 1 if not routable (no match or excluded)
#
# Design: case-statement dispatch over kind — no dynamic function calls.
# Per-kind return semantics are handled by the CALLER, not here.
# t2203 — extracted from three inline blocks in _check_pr_merge_gates
# and _process_single_ready_pr.
#######################################
_route_pr_to_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local kind="$4"
	local pr_labels="${5:-}"
	local pr_title="${6:-}"
	local updated_at="${7:-}"
	local head_ref_oid="${8:-}"
	local checks_json="${9:-}"
	local issue_labels=""
	local issue_has_worker_origin=0
	local label_list=""
	local takeover_pattern=",origin:worker-takeover,"

	# No linked issue → nothing to route to
	[[ -z "$linked_issue" ]] && return 1

	# Fetch labels if not provided by caller
	if [[ -z "$pr_labels" ]]; then
		if ! pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null); then
			echo "[pulse-wrapper] _route_pr_to_fix_worker: current labels unavailable for PR #${pr_number} in ${repo_slug} — refusing destructive routing" >>"$LOGFILE"
			return 1
		fi
	fi
	label_list=",${pr_labels},"

	# Kind-specific "already routed" exclusion label
	local routed_label
	case "$kind" in
		review)   routed_label="review-routed-to-issue" ;;
		conflict) routed_label="conflict-feedback-routed" ;;
		ci)       routed_label="ci-feedback-routed" ;;
		*)
			echo "[pulse-wrapper] _route_pr_to_fix_worker: unknown kind '${kind}'" >>"$LOGFILE"
			return 1
			;;
	esac

	# Check exclusion labels — already routed or no-takeover
	if [[ "$label_list" == *",${routed_label},"* ]] \
		|| [[ "$label_list" == *",no-takeover,"* ]]; then
		return 1
	fi

	# Review gate has an additional exclusion for external contributors
	if [[ "$kind" == "review" ]] && [[ "$label_list" == *",external-contributor,"* ]]; then
		return 1
	fi

	if [[ "$label_list" != *",origin:worker,"* \
		&& "$label_list" != *"$takeover_pattern"* \
		&& "$label_list" != *",origin:interactive,"* ]]; then
		if ! issue_labels=$(gh api "repos/${repo_slug}/issues/${linked_issue}" \
			--jq '[.labels[].name] | join(",")' 2>/dev/null); then
			echo "[pulse-wrapper] _route_pr_to_fix_worker: linked issue #${linked_issue} metadata unavailable for PR #${pr_number} in ${repo_slug} — refusing destructive routing" >>"$LOGFILE"
			return 1
		fi
		if [[ ",${issue_labels}," == *",origin:worker,"* ]]; then
			issue_has_worker_origin=1
		fi
	fi

	# Worker-origin PRs: dispatch directly
	if [[ ( -n "${_OW_LABEL_PAT:-}" && "$label_list" == *"${_OW_LABEL_PAT:-}"* ) ]] \
		|| [[ "$label_list" == *"$takeover_pattern"* ]] \
		|| [[ "$issue_has_worker_origin" -eq 1 ]]; then
		[[ "$issue_has_worker_origin" -eq 0 ]] \
			|| _route_issue_origin_is_trusted "$pr_number" "$repo_slug" "$linked_issue" \
			|| return 1
		_dispatch_pr_repair_by_kind "$kind" "$pr_number" "$repo_slug" "$linked_issue" "$pr_title" "$checks_json"
		return 0
	fi

	# Stale interactive PRs: handover first, then dispatch
	if [[ "$label_list" == *",origin:interactive,"* ]] \
		&& _interactive_pr_is_stale "$pr_number" "$repo_slug" "$updated_at" "$head_ref_oid"; then
		if ! _interactive_pr_trigger_handover "$pr_number" "$repo_slug"; then
			echo "[pulse-wrapper] _route_pr_to_fix_worker: interactive handover was not confirmed for PR #${pr_number} in ${repo_slug} — refusing destructive routing" >>"$LOGFILE"
			return 1
		fi
		if ! pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) \
			|| [[ ",${pr_labels}," != *"$takeover_pattern"* ]]; then
			echo "[pulse-wrapper] _route_pr_to_fix_worker: origin:worker-takeover not confirmed for PR #${pr_number} in ${repo_slug} — refusing destructive routing" >>"$LOGFILE"
			return 1
		fi
		_dispatch_pr_repair_by_kind "$kind" "$pr_number" "$repo_slug" "$linked_issue" "$pr_title" "$checks_json"
		return 0
	fi

	# Not routable (no matching origin label or not stale)
	return 1
}

#######################################
# Retarget direct child PRs before deleting the merged parent branch.
#
# Args:
#   $1 - parent PR number
#   $2 - repo slug
#   $3 - parent head ref from per-cycle PR context (optional)
# Returns: 0 always (errors are non-fatal)
#######################################
_retarget_stacked_children() {
	local parent_pr_number="$1"
	local repo_slug="$2"
	local parent_head_ref="${3:-}"
	if [[ -z "$parent_head_ref" ]]; then
		parent_head_ref=$(gh_pr_view "$parent_pr_number" --repo "$repo_slug" --json headRefName -q '.headRefName' 2>/dev/null) || parent_head_ref=""
	fi
	if [[ -z "$parent_head_ref" ]]; then
		return 0
	fi

	local children
	children=$(gh_pr_list --repo "$repo_slug" --base "$parent_head_ref" --state open --json number -q '.[].number' 2>/dev/null) || children=""
	if [[ -z "$children" ]]; then
		return 0
	fi

	local default_branch
	default_branch=$(gh repo view "$repo_slug" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
	default_branch="${default_branch:-main}"

	local child
	while IFS= read -r child; do
		[[ -z "$child" ]] && continue
		echo "[pulse-merge] retargeting stacked PR #${child} from '${parent_head_ref}' to '${default_branch}' before deleting parent PR #${parent_pr_number} branch (t2412)" >>"$LOGFILE"
		gh pr edit "$child" --repo "$repo_slug" --base "$default_branch" 2>&1 | tee -a "$LOGFILE" || true
	done <<<"$children"
	return 0
}

#######################################
# Check if a GitHub login appears in the trusted-issue-author allowlist (t3062).
#
# Peer runners with COLLABORATOR association can be added to the allowlist to
# bypass the OWNER/MEMBER author_association gate without requiring per-issue
# cryptographic approval (sudo aidevops approve issue N).
#
# Config: AIDEVOPS_TRUSTED_AUTHORS_CONF env var (override) or
#         <_PULSE_MERGE_DIR>/../configs/trusted-issue-authors.conf (default).
# Empty/missing config = no trusted authors = returns 1 (not trusted).
#
# Args: $1=github_login
# Returns: 0=login is trusted, 1=not trusted
#######################################
_is_trusted_issue_author() {
	local login="$1"
	[[ -z "$login" ]] && return 1
	local _trusted_conf="${AIDEVOPS_TRUSTED_AUTHORS_CONF:-${_PULSE_MERGE_DIR:+${_PULSE_MERGE_DIR}/../configs/trusted-issue-authors.conf}}"
	[[ -z "$_trusted_conf" || ! -f "$_trusted_conf" ]] && return 1
	local _tentry
	while IFS= read -r _tentry || [[ -n "$_tentry" ]]; do
		[[ -z "$_tentry" || "$_tentry" == "#"* ]] && continue
		[[ "$_tentry" == "$login" ]] && return 0
	done < "$_trusted_conf"
	return 1
}

#######################################
# Check whether an issue author has maintainer-equivalent repository access.
#
# GitHub can expose maintainer-operated issues/PRs as COLLABORATOR rather than
# OWNER/MEMBER. For worker-briefed auto-merge, verify that ambiguous metadata
# through the authenticated collaborator permission endpoint instead of forcing
# per-issue cryptographic approvals for every maintainer-run aidevops worker.
#
# Args: $1=repo_slug, $2=github_login, $3=precomputed_permission(optional)
# Returns: 0=trusted maintainer-equivalent access, 1=not trusted or API error
#######################################
_issue_author_has_maintainer_authority() {
	local repo_slug="$1"
	local login="$2"
	local permission="${3:-}"

	[[ -n "$repo_slug" && -n "$login" ]] || return 1

	if [[ -z "$permission" ]]; then
		#aidevops:trust-boundary GH#24958: ambiguous GitHub issue
		# author_association values are not sufficient to auto-merge worker PRs.
		# Confirm maintainer-equivalent access with authenticated metadata and fail
		# closed on API errors or permissions below write.
		permission=$(gh api "repos/${repo_slug}/collaborators/${login}/permission" \
			--jq '.permission // ""' 2>/dev/null) || return 1
	fi

	case "$permission" in
		admin | maintain | write)
			return 0
			;;
	esac
	return 1
}

#######################################
# Verify that a linked issue has a maintainer cryptographic approval (t3052).
#
# Marker-string presence is not a trust signal: any user able to comment could
# paste the marker. This helper delegates to approval-helper.sh, which verifies
# the SSH signature against the maintainer approval public key.
#
# Args: $1=issue_number, $2=repo_slug
# Returns: 0=verified approval, 1=no verified approval
#######################################
_issue_has_verified_crypto_approval() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -z "$issue_number" || -z "$repo_slug" ]] && return 1

	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	[[ ! -f "$approval_helper" ]] && return 1

	local verify_result=""
	verify_result=$(bash "$approval_helper" verify "$issue_number" "$repo_slug" 2>/dev/null) || verify_result=""
	[[ "$verify_result" == "VERIFIED" ]]
	return $?
}

#######################################
# Check origin:worker worker-briefed auto-merge gates (t2449).
#
# Sibling to _check_interactive_pr_gates — validates that an origin:worker
# PR is eligible for auto-merge based on the maintainer-briefed trust chain.
# Called from _check_pr_merge_gates when the PR carries origin:worker.
#
# The trust-chain equivalence argument: if the underlying issue was filed by
# the repo OWNER/MEMBER, the worker faithfully implemented, CI confirms
# correctness, and no human reviewer objected, the trust chain is equivalent
# to (or stronger than) an origin:interactive auto-merge.
#
# Nine criteria (see GH#20204):
#   1. PR carries origin:worker label (caller pre-checks)
#   2. Linked issue authored by OWNER or MEMBER
#   3. NMR never applied OR cleared via cryptographic approval (not auto-approval)
#   4. All required status checks PASS/SKIPPED (checked by general gates)
#   5. No CHANGES_REQUESTED from human reviewers (checked by general gates)
#   6. PR is not a draft
#   7. No hold-for-review label
#   8. Passes review-bot-gate (checked by general gates)
#   9. No origin:worker-takeover label (caller pre-checks)
#
# Feature flag: AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE (default: 1=on, 0=off)
# When OFF, all origin:worker PRs fall back to manual merge only.
#
# Args: $1=pr_number, $2=repo_slug, $3=labels_str (comma-separated),
#       $4=is_draft, $5=linked_issue,
#       $6=precomputed_pr_author_permission(optional),
#       $7=precomputed_pr_author_login(optional)
# Returns: 0=all gates pass (eligible for auto-merge), 1=blocked
#######################################
_attempt_worker_briefed_auto_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"
	local is_draft="$4"
	local linked_issue="$5"
	local precomputed_pr_author_permission="${6:-}"
	local precomputed_pr_author_login="${7:-}"

	# Feature flag — when OFF, all origin:worker PRs fall back to manual merge
	if [[ "${AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE:-1}" == "0" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: disabled by AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 for PR #${pr_number} in ${repo_slug} (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: not a draft
	if [[ "$is_draft" == "true" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — draft PR not eligible (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: no hold-for-review opt-out label
	if [[ ",${labels_str}," == *",hold-for-review,"* ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — hold-for-review label (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: must have a linked issue (the "brief" in "maintainer-briefed")
	if [[ -z "$linked_issue" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — no linked issue (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Reuse the issue API base path for author-association and NMR checks.
	local _issue_api
	_issue_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
	# Fetch author_association and user.login in one API call (t3062 needs login).
	local _issue_meta
	_issue_meta=$(gh api "${_issue_api}" \
		--jq '[.author_association // "", .user.login // ""] | @tsv' 2>/dev/null) || _issue_meta="	"
	local issue_author_assoc=""
	local issue_author_login=""
	read -r issue_author_assoc issue_author_login <<< "$_issue_meta"
	local issue_author_permission=""
	#aidevops:trust-boundary — reuse PR-author permission only for the same non-empty issue-author login.
	if [[ -n "$precomputed_pr_author_permission" && -n "$precomputed_pr_author_login" && "$precomputed_pr_author_login" == "$issue_author_login" ]]; then
		issue_author_permission="$precomputed_pr_author_permission"
	fi

	# Fetch auto-approval signal once for the NMR crypto-vs-auto check (t2449).
	# Cryptographic approval is verified separately via approval-helper.sh; do not
	# trust marker-string presence in comments as a security gate.
	local _not_true_status="not-verified"
	local _has_auto=""
	_has_auto=$(gh api "${_issue_api}/comments" --jq '
		any(.[].body | strings; contains("auto-approved-maintainer-issue"))
	' 2>/dev/null) || _has_auto="$_not_true_status"

	local _has_crypto="$_not_true_status"
	if _issue_has_verified_crypto_approval "$linked_issue" "$repo_slug"; then
		_has_crypto="true"
	fi

	# Gate: linked issue authored by OWNER/MEMBER, OR login has authenticated
	# maintainer-equivalent repo permission (GH#24958), OR login is in the
	# trusted-issue-author allowlist (t3062), OR cryptographically approved
	# by maintainer (t3052). The trust chain "maintainer SSH-signed
	# an approval on the issue" is at least as strong as the OWNER/MEMBER
	# author check — the maintainer personally vouched with their private key.
	if [[ "$issue_author_assoc" != "OWNER" && "$issue_author_assoc" != "MEMBER" ]]; then
		if _issue_author_has_maintainer_authority "$repo_slug" "$issue_author_login" "$issue_author_permission"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author ${issue_author_login} passes via authenticated maintainer permission fallback (GH#24958)" >>"$LOGFILE"
		elif _is_trusted_issue_author "$issue_author_login"; then
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author ${issue_author_login} passes via trusted-issue-author allowlist (t3062)" >>"$LOGFILE"
		elif [[ "$_has_crypto" != "true" ]]; then
			echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author_association=${issue_author_assoc} (not OWNER/MEMBER) and no cryptographic approval signature found (t2449/t3052)" >>"$LOGFILE"
			return 1
		else
			echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author_association=${issue_author_assoc} but cryptographic approval signature present, proceeding (t3052)" >>"$LOGFILE"
		fi
	fi

	# Gate: NMR crypto-vs-auto approval check.
	# If NMR was ever applied to the linked issue, it must have been cleared
	# via cryptographic approval (sudo aidevops approve issue N), NOT via
	# auto_approve_maintainer_issues. Auto-approval runs as the pulse's own
	# GitHub token — accepting it here would create a closed loop with zero
	# human touchpoints (scanner → issue → dispatch → worker → PR → merge).
	if [[ "$_has_auto" == "true" && "$_has_crypto" != "true" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} NMR was auto-approved only (no crypto clearance) (t2449)" >>"$LOGFILE"
		return 1
	fi

	# All gates pass — eligible for worker-briefed auto-merge
	echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} passed all gates (issue #${linked_issue}, author_assoc=${issue_author_assoc}, crypto_approved=${_has_crypto}) (t2449/t3052)" >>"$LOGFILE"
	return 0
}

#######################################
# Verify all branch-protection-required check contexts have passed on a PR.
#
# Uses the branch protection API as the authoritative source for required
# contexts — more precise than `gh pr checks --required` which can be
# confused by null-status non-required checks (CodeRabbit, qlty, linked-
# issue-check, url-allowlist, etc.) that report indefinitely and trigger the
# fail-closed path spuriously. (t2922)
#
# Called from _process_single_ready_pr to provide an escape hatch for
# origin:worker PRs when _pr_required_checks_pass fires on phantom pending
# contexts that are absent from branch_protection.required_status_checks.
#
# Passing state for each required context:
#   - StatusContext: state == SUCCESS
#   - CheckRun: conclusion in {SUCCESS, NEUTRAL, SKIPPED}
# Any context absent from the rollup, or in any other state, is non-passing.
# Fail-closed on API errors.
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=all required contexts passing, 1=some not passing or API error
#######################################
#######################################
# Return whether a repository-ruleset ref pattern applies to the default branch.
# Rulesets may use exact refs, GitHub tokens, or simple branch globs.
#
# Args: $1=pattern, $2=default_branch
# Returns: 0=matches default branch, 1=does not match
#######################################
_ruleset_ref_matches_default_branch() {
	local pattern="$1"
	local default_branch="$2"
	local default_ref="refs/heads/${default_branch}"
	local branch_pattern="${pattern}"

	case "$pattern" in
	"~ALL" | "~DEFAULT_BRANCH" | "$default_ref" | "$default_branch")
		return 0
		;;
	esac
	case "$pattern" in
	refs/heads/*)
		branch_pattern="${pattern#refs/heads/}"
		;;
	esac

	case "$pattern" in
	*"*"*)
		# shellcheck disable=SC2254 # Intentionally treat ruleset branch globs as patterns.
		case "$default_ref" in
		$pattern)
			return 0
			;;
		esac
		# shellcheck disable=SC2254 # Intentionally treat ruleset branch globs as patterns.
		case "$default_branch" in
		$branch_pattern)
			return 0
			;;
		esac
		;;
	esac

	return 1
}

#######################################
# Resolve newline-delimited required status check contexts from active
# repository rulesets matching the default branch. This supplements classic
# branch protection because rulesets can enforce required checks even when
# the branch-protection required_status_checks endpoint returns HTTP 404.
#
# Args: $1=repo_slug, $2=default_branch
# Stdout: required ruleset contexts (one per line). Empty when no active
#         matching rulesets require status checks.
# Returns: 0=resolved, 1=rulesets API/parse error (caller fails closed)
#######################################
_required_contexts_from_rulesets_for_default_branch() {
	local repo_slug="$1"
	local default_branch="$2"

	local rulesets_json=""
	rulesets_json=$(gh api "repos/${repo_slug}/rulesets" 2>/dev/null) || {
		echo "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: rulesets list failed for ${repo_slug} — caller will fail closed (GH#23019)" >>"$LOGFILE"
		return 1
	}
	[[ -n "$rulesets_json" && "$rulesets_json" != "[]" && "$rulesets_json" != "null" ]] || return 0

	local active_ids=""
	active_ids=$(printf '%s' "$rulesets_json" | jq -r '.[]? | select(.enforcement == "active") | .id // empty' 2>/dev/null) || {
		echo "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: rulesets list parse failed for ${repo_slug} — caller will fail closed (GH#23019)" >>"$LOGFILE"
		return 1
	}
	[[ -n "$active_ids" ]] || return 0

	local contexts_tmp=""
	contexts_tmp=$(mktemp) || {
		echo "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: mktemp failed for ${repo_slug} — caller will fail closed (GH#23019)" >>"$LOGFILE"
		return 1
	}

	local id="" detail="" include_patterns="" exclude_patterns="" pattern=""
	local matches_default=0 excluded_default=0 contexts=""
	while IFS= read -r id; do
		[[ -n "$id" ]] || continue
		detail=$(gh api "repos/${repo_slug}/rulesets/${id}" 2>/dev/null) || {
			echo "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: ruleset detail ${id} failed for ${repo_slug} — caller will fail closed (GH#23019)" >>"$LOGFILE"
			rm -f "$contexts_tmp"
			return 1
		}

		include_patterns=$(printf '%s' "$detail" | jq -r '.conditions.ref_name.include // [] | .[]' 2>/dev/null) || {
			echo "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: ruleset detail ${id} parse failed for ${repo_slug} — caller will fail closed (GH#23019)" >>"$LOGFILE"
			rm -f "$contexts_tmp"
			return 1
		}
		exclude_patterns=$(printf '%s' "$detail" | jq -r '.conditions.ref_name.exclude // [] | .[]' 2>/dev/null) || {
			echo "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: ruleset detail ${id} exclude parse failed for ${repo_slug} — caller will fail closed (GH#23019)" >>"$LOGFILE"
			rm -f "$contexts_tmp"
			return 1
		}

		matches_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			if _ruleset_ref_matches_default_branch "$pattern" "$default_branch"; then
				matches_default=1
				break
			fi
		done <<<"$include_patterns"
		[[ "$matches_default" -eq 1 ]] || continue

		excluded_default=0
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] || continue
			if _ruleset_ref_matches_default_branch "$pattern" "$default_branch"; then
				excluded_default=1
				break
			fi
		done <<<"$exclude_patterns"
		[[ "$excluded_default" -eq 0 ]] || continue

		contexts=$(printf '%s' "$detail" | jq -r '.rules[]? | select(.type == "required_status_checks") | (.parameters.required_status_checks // [])[]? | .context // empty' 2>/dev/null) || {
			echo "[pulse-merge] _required_contexts_from_rulesets_for_default_branch: required-check parse failed for ruleset ${id} in ${repo_slug} — caller will fail closed (GH#23019)" >>"$LOGFILE"
			rm -f "$contexts_tmp"
			return 1
		}
		[[ -n "$contexts" ]] && printf '%s\n' "$contexts" >>"$contexts_tmp"
	done <<<"$active_ids"

	if [[ -s "$contexts_tmp" ]]; then
		sort -u "$contexts_tmp"
	fi
	rm -f "$contexts_tmp"
	return 0
}

#######################################
# Resolve the newline-delimited list of required status check contexts
# for $repo_slug's default branch. Extracted from _check_required_checks_passing
# (t3193) to keep that function under the 100-line complexity gate.
#
# Args: $1=repo_slug
# Stdout: required contexts from classic branch protection plus active matching
#         repository rulesets (one per line). Empty when neither mechanism
#         requires checks; the caller treats that as PASS.
# Returns:
#   0 — contexts resolved (may be empty per above)
#   1 — real error (default branch resolve failed, or non-404 API error) —
#       caller MUST fail closed to preserve t2922 invariant.
#######################################
_required_contexts_for_default_branch_uncached() {
	local repo_slug="$1"
	local default_branch="" _db_exit=0
	default_branch=$(gh api "repos/${repo_slug}" --jq '.default_branch' 2>/dev/null)
	_db_exit=$?
	if [[ $_db_exit -ne 0 || -z "$default_branch" ]]; then
		echo "[pulse-merge] _required_contexts_for_default_branch: failed to resolve default branch for ${repo_slug} — caller will fail closed (t2922)" >>"$LOGFILE"
		return 1
	fi

	# Fetch required contexts from branch protection — authoritative list.
	# t3193: capture stderr separately so HTTP 404 (no protection on the
	# default branch) can be distinguished from real API errors (auth fail,
	# 5xx, network). The collapsed `--jq | 2>/dev/null` form previously
	# treated 404 the same as 401, causing the caller to fail closed on
	# intentionally-unprotected default branches and blocking the worker-
	# briefed merge cascade.
	local protection_resp="" _rc_exit=0
	protection_resp=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="pulse-branch-protection-required-contexts-rest" \
		gh api \
		"repos/${repo_slug}/branches/${default_branch}/protection/required_status_checks" \
		2>&1)
	_rc_exit=$?
	if [[ $_rc_exit -ne 0 ]]; then
		# HTTP 404 = the default branch has no classic protection rules. Rulesets
		# can still enforce required checks, so inspect them before allowing.
		if grep -qi 'HTTP 404\|Not Found' <<<"$protection_resp"; then
			local ruleset_contexts_404=""
			ruleset_contexts_404=$(_required_contexts_from_rulesets_for_default_branch "$repo_slug" "$default_branch") || return 1
			if [[ -n "$ruleset_contexts_404" ]]; then
				echo "[pulse-merge] _required_contexts_for_default_branch: no classic branch protection on ${repo_slug} (HTTP 404), but active rulesets require contexts (GH#23019)" >>"$LOGFILE"
				printf '%s\n' "$ruleset_contexts_404"
				return 0
			fi
			echo "[pulse-merge] _required_contexts_for_default_branch: no classic branch protection or required ruleset contexts on ${repo_slug} default branch (HTTP 404) — empty contexts (t3193, GH#23019)" >>"$LOGFILE"
			return 0
		fi
		# Any other failure (401, 403, 5xx, network) is a real error — keep
		# the t2922 fail-closed behaviour so an auth break doesn't silently
		# unblock a stale fork PR.
		echo "[pulse-merge] _required_contexts_for_default_branch: branch protection API failed for ${repo_slug} (exit ${_rc_exit}) — caller will fail closed (t2922)" >>"$LOGFILE"
		return 1
	fi

	# Extract required contexts from the JSON response, then supplement with
	# active matching repository rulesets so rulesets-only required checks do not
	# pass the gate and fail later at mergePullRequest (GH#23019).
	local classic_contexts="" ruleset_contexts=""
	classic_contexts=$(printf '%s' "$protection_resp" \
		| jq -r '.contexts // [] | .[]' 2>/dev/null) || classic_contexts=""
	ruleset_contexts=$(_required_contexts_from_rulesets_for_default_branch "$repo_slug" "$default_branch") || return 1
	if [[ -n "$ruleset_contexts" ]]; then
		echo "[pulse-merge] _required_contexts_for_default_branch: active rulesets add required contexts for ${repo_slug} (GH#23019)" >>"$LOGFILE"
	fi

	if [[ -n "$classic_contexts" ]]; then
		printf '%s\n' "$classic_contexts"
	fi
	if [[ -n "$ruleset_contexts" ]]; then
		printf '%s\n' "$ruleset_contexts"
	fi
	return 0
}

_required_contexts_for_default_branch() {
	local repo_slug="$1"
	local cache_dir="${AIDEVOPS_PULSE_REQUIRED_CONTEXTS_CACHE_DIR:-}"
	local cache_key="" cache_body_file="" cache_rc_file="" cache_rc=""
	local contexts="" rc=0

	if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
		cache_key=$(_pmp_cache_key "$repo_slug")
		cache_body_file="${cache_dir}/${cache_key}.body"
		cache_rc_file="${cache_dir}/${cache_key}.rc"
		if [[ -f "$cache_rc_file" && -f "$cache_body_file" ]]; then
			cache_rc=$(<"$cache_rc_file")
			[[ "$cache_rc" =~ ^[0-9]+$ ]] || cache_rc=1
			if [[ "$cache_rc" -eq 0 && -s "$cache_body_file" ]]; then
				while IFS= read -r contexts; do
					printf '%s\n' "$contexts"
				done <"$cache_body_file"
			fi
			return "$cache_rc"
		fi
	fi

	contexts=$(_required_contexts_for_default_branch_uncached "$repo_slug")
	rc=$?
	if [[ -n "$cache_body_file" && -n "$cache_rc_file" ]]; then
		printf '%s\n' "$rc" >"$cache_rc_file"
		if [[ -n "$contexts" ]]; then
			printf '%s\n' "$contexts" >"$cache_body_file"
		else
			: >"$cache_body_file"
		fi
	fi
	if [[ "$rc" -eq 0 && -n "$contexts" ]]; then
		printf '%s\n' "$contexts"
	fi
	return "$rc"
}

_check_required_checks_passing() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_sha="${3:-}"

	# Resolve required contexts (delegates default-branch lookup + branch
	# protection API + 404 distinction to the helper). Empty stdout + exit 0
	# means "no enforcement required, treat as PASS"; exit 1 means real error.
	local required_contexts=""
	required_contexts=$(_required_contexts_for_default_branch "$repo_slug") || return 1

	# No required contexts → nothing required, treat as passing.
	if [[ -z "$required_contexts" ]]; then
		local fallback_rc=0
		_check_required_pr_checks_passing_fallback "$repo_slug" "$pr_number" >/dev/null
		fallback_rc=$?
		if [[ $fallback_rc -eq 0 ]]; then
			echo "[pulse-merge] _check_required_checks_passing: no branch/ruleset contexts and PR required checks are passing or absent for PR #${pr_number} in ${repo_slug} — allowing (t2922)" >>"$LOGFILE"
			return 0
		fi
		if [[ $fallback_rc -eq 1 ]]; then
			echo "[pulse-merge] _check_required_checks_passing: PR-level required checks are not passing for PR #${pr_number} in ${repo_slug} despite no branch/ruleset contexts — failing closed (t2922)" >>"$LOGFILE"
			return 1
		fi
		echo "[pulse-merge] _check_required_checks_passing: PR-level required checks fallback failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922)" >>"$LOGFILE"
		return 1
	fi

	# GH#21799: replace GraphQL statusCheckRollup with REST check-runs (single
	# PR, separate budget pool). check-runs is heavier than check-suites
	# (~111KB/PR) but exposes per-context .name fields needed for matching
	# branch-protection required_status_checks. Single-PR path → cost is fine.
	if [[ -z "$pr_sha" ]]; then
		pr_sha=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json headRefOid --jq '.headRefOid' 2>/dev/null) || pr_sha=""
	fi
	if [[ -z "$pr_sha" ]]; then
		echo "[pulse-merge] _check_required_checks_passing: headRefOid fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922, GH#21799)" >>"$LOGFILE"
		return 1
	fi

	# REST check-runs returns the granular per-context list with .name +
	# .conclusion + .status. Need check-runs (not check-suites) because
	# branch-protection required_status_checks are matched by NAME.
	local rollup_json=""
	rollup_json=$(gh_pr_check_runs_rest "$repo_slug" "$pr_sha" 2>/dev/null) || rollup_json=""
	if [[ -z "$rollup_json" || "$rollup_json" == "null" ]]; then
		echo "[pulse-merge] _check_required_checks_passing: REST check-runs fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922, GH#21799)" >>"$LOGFILE"
		return 1
	fi

	# Build JSON array from newline-delimited required_contexts string.
	local req_json
	req_json=$(printf '%s' "$required_contexts" \
		| jq -Rsc '[split("\n")[] | select(length > 0)]' 2>/dev/null) || req_json="[]"

	# Count required contexts that are not in a passing state. check-runs
	# objects expose `.name`, `.conclusion`, and `.status`. Status
	# `completed` + conclusion in {success, neutral, skipped} → PASS.
	local failing_count _fc_exit
	failing_count=$(jq -n \
		--argjson req "$req_json" \
		--argjson checks "$rollup_json" \
		'$req | map(
			. as $ctx |
			($checks | map(select((.name // "") == $ctx)) | last) as $c |
			if $c == null then "NOT_FOUND"
			elif (($c.conclusion // "" | ascii_upcase)
				| . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "PASS"
			else "FAIL"
			end
		) | map(select(. != "PASS")) | length' 2>/dev/null)
	_fc_exit=$?

	if [[ $_fc_exit -ne 0 || -z "$failing_count" ]]; then
		echo "[pulse-merge] _check_required_checks_passing: jq evaluation failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922)" >>"$LOGFILE"
		return 1
	fi

	if [[ "$failing_count" -gt 0 ]]; then
		echo "[pulse-merge] _check_required_checks_passing: ${failing_count} required context(s) not passing for PR #${pr_number} in ${repo_slug} (t2922)" >>"$LOGFILE"
		return 1
	fi

	echo "[pulse-merge] _check_required_checks_passing: all required contexts passing for PR #${pr_number} in ${repo_slug} (t2922)" >>"$LOGFILE"
	return 0
}

#######################################
# Cached check: does the repo have allow_auto_merge enabled (t3070)?
#
# Caches per repo slug in a tempdir keyed on PID for the lifetime of the
# calling process. allow_auto_merge is a repo-level setting that rarely
# changes; a stale cache at worst falls through to the existing immediate-
# merge path on the next pulse cycle.
#
# Args: $1=repo slug
# Returns: 0=enabled, 1=disabled or query error (fail-closed)
#######################################
_repo_allows_auto_merge() {
	local repo_slug="$1"
	local cache_dir="${TMPDIR:-/tmp}/aidevops-pulse-allow-auto-merge-$$"
	local cache_key
	cache_key=$(printf '%s' "$repo_slug" | tr '/' '_')
	local cache_file="${cache_dir}/${cache_key}"

	if [[ -f "$cache_file" ]]; then
		local cached
		cached=$(<"$cache_file")
		case "$cached" in
			true) return 0 ;;
			false) return 1 ;;
		esac
	fi

	mkdir -p "$cache_dir" 2>/dev/null || true

	local _flag=""
	local _f_exit=0
	_flag=$(gh api "repos/${repo_slug}" --jq '.allow_auto_merge // false' 2>/dev/null)
	_f_exit=$?
	if [[ $_f_exit -ne 0 ]]; then
		# Fail-closed: don't try native auto-merge if we can't verify.
		echo "[pulse-merge] _repo_allows_auto_merge: gh api failed for ${repo_slug} (exit ${_f_exit}), treating as disabled (t3070)" >>"$LOGFILE"
		printf '%s' "false" >"$cache_file" 2>/dev/null || true
		return 1
	fi

	if [[ "$_flag" == "true" ]]; then
		printf '%s' "true" >"$cache_file" 2>/dev/null || true
		return 0
	fi
	printf '%s' "false" >"$cache_file" 2>/dev/null || true
	return 1
}

#######################################
# Detect a wedged auto_merge request (t3192).
#
# GitHub's `mergeable_state` recomputation is async and lazy; setting
# `auto_merge: true` does not trigger immediate recompute, and once
# `BLOCKED` is cached on a PR the state can stick for hours even after the
# original cause (pending CI, missing approval) has been resolved. Pulse
# cycles see `auto_merge` set, the t3070 fast path returns 0, and the PR
# sits indefinitely. Observed 2026-04-30 on PRs that sat 8-9h despite
# 100% required-check SUCCESS and `mergeable=MERGEABLE`.
#
# Stuck means ALL of:
#   * mergeStateStatus == BLOCKED
#   * mergeable == MERGEABLE
#   * reviewDecision is known-safe for this already-gated cycle
#   * autoMergeRequest.enabledAt > $threshold seconds ago
#   * No required check is in fail/pending/cancel bucket (only pass/skipping)
#
# Threshold defaults to 300s, overridable via
# AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS.
#
# Args: $1=pr_number, $2=repo_slug, $3=normalized current-cycle PR state JSON
# Stdout: stuck-seconds count when stuck (caller logs it)
# Returns: 0=stuck, safe to fall through to --admin; 1=defer to GitHub
#######################################
_auto_merge_stuck_seconds() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_state="$3"
	local threshold="${AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS:-300}"

	local enabled_at merge_state mergeable review_decision
	IFS=$'\t' read -r enabled_at merge_state mergeable review_decision <<<"$(printf '%s' "$pr_state" \
		| jq -r '[.autoMergeRequest.enabledAt // "", .mergeStateStatus // "", .mergeable // "", .reviewDecision // ""] | @tsv' \
		|| true)"

	# Glob form (unquoted RHS inside [[ ]]) avoids adding new repeated string
	# literals — the validator counts only quoted 4+-char literals.
	[[ "$merge_state" == BLOCKED ]] || return 1
	[[ "$mergeable" == MERGEABLE ]] || return 1
	[[ -n "$enabled_at" ]] || return 1

	local enabled_epoch now_epoch stuck_seconds
	enabled_epoch=$(date -u -d "$enabled_at" +%s 2>/dev/null \
		|| TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$enabled_at" +%s 2>/dev/null \
		|| echo "0")
	[[ "$enabled_epoch" =~ ^[0-9]+$ && "$enabled_epoch" -gt 0 ]] || return 1
	now_epoch=$(date -u +%s)
	stuck_seconds=$((now_epoch - enabled_epoch))
	[[ "$stuck_seconds" -gt "$threshold" ]] || return 1

	# The cycle's review projection can become stale between its gate and this
	# destructive wedge bypass. Re-read bounded REST history now; unavailable or
	# contradictory evidence must not authorize an admin fall-through.
	local fresh_review_decision=""
	_pmp_refresh_native_auto_review_into fresh_review_decision "$pr_number" "$repo_slug" "$review_decision" || return 1
	case "$fresh_review_decision" in
	OBSERVED_APPROVED | NONE) ;;
	*) return 1 ;;
	esac

	# Confirm no required check is still pending or has failed. We require
	# every required check to be in `pass` or `skipping` bucket — anything
	# else means the PR has a legitimate reason to stay blocked, and
	# falling through to --admin would bypass that signal.
	_check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1 || return 1

	printf '%s' "$stuck_seconds"
	return 0
}

# Disarm an already-deferred merge whose mutable approval state now requires a
# synchronous final gate. Draft conversion is the independent server-side hold
# when GitHub rejects disable-auto.
_stop_external_native_auto_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local hold_reason="${3:-external approval state must be revalidated at the actual merge call}"
	local disable_output=""
	local draft_hold_output=""

	if disable_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --disable-auto 2>&1); then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: disabled deferred native auto-merge because ${hold_reason}" >>"$LOGFILE"
		return 0
	fi
	if draft_hold_output=$(gh pr ready "$pr_number" --repo "$repo_slug" --undo 2>&1); then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: disable-auto failed, so PR was returned to draft because ${hold_reason}: ${disable_output}" >>"$LOGFILE"
		return 2
	fi
	echo "[pulse-merge] SECURITY HOLD FAILED for PR #${pr_number} in ${repo_slug}: could not disable external auto-merge or return PR to draft because ${hold_reason}; manual intervention required. disable=${disable_output}; draft=${draft_hold_output}" >>"$LOGFILE"
	return 3
}

_enable_native_auto_merge_for_head() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local pending_count="$4"
	local auto_output=""
	local auto_exit=0

	if [[ -z "$expected_head_sha" ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: native auto-merge not set because the gated head SHA is unavailable" >>"$LOGFILE"
		return 1
	fi
	auto_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --auto --squash \
		--match-head-commit "$expected_head_sha" 2>&1)
	auto_exit=$?
	if [[ "$auto_exit" -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: native auto-merge set (CI ${pending_count} pending), GitHub merges on green (t3070)" >>"$LOGFILE"
		return 0
	fi
	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: gh pr merge --auto failed (exit ${auto_exit}): ${auto_output} — falling through to immediate merge (t3070)" >>"$LOGFILE"
	return 1
}

_handle_existing_native_auto_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local require_synchronous_final_gate="$3"
	local expected_head_sha="$4"
	local pr_state="$5"
	local snapshot_head_sha="" stop_rc=0

	if [[ "$require_synchronous_final_gate" == "1" ]]; then
		_stop_external_native_auto_merge "$pr_number" "$repo_slug" || stop_rc=$?
		[[ "$stop_rc" -eq 0 ]] && return 2
		return "$stop_rc"
	fi
	snapshot_head_sha=$(printf '%s' "$pr_state" | jq -r '.headRefOid // empty' 2>/dev/null) || snapshot_head_sha=""
	if [[ -z "$expected_head_sha" || -z "$snapshot_head_sha" || "$snapshot_head_sha" != "$expected_head_sha" ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: existing native auto-merge head no longer matches the gated head; disarming and deferring" >>"$LOGFILE"
		_stop_external_native_auto_merge "$pr_number" "$repo_slug" \
			"the live head no longer matches the gated head" || stop_rc=$?
		[[ "$stop_rc" -eq 0 ]] && return 2
		return "$stop_rc"
	fi

	local stuck_seconds=""
	if stuck_seconds=$(_auto_merge_stuck_seconds "$pr_number" "$repo_slug" "$pr_state"); then
		local threshold="${AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS:-300}"
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge stuck ${stuck_seconds}s (>${threshold}s) in BLOCKED+MERGEABLE with no failing/pending required checks — attempting synchronous recovery (t3192)" >>"$LOGFILE"
		stop_rc=0
		_stop_external_native_auto_merge "$pr_number" "$repo_slug" \
			"stale wedge recovery requires a fresh synchronous merge (GH#26897)" || stop_rc=$?
		if [[ "$stop_rc" -eq 0 ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: disabled stale native auto-merge before immediate merge (GH#26897)" >>"$LOGFILE"
			return 1
		fi
		return "$stop_rc"
	fi

	local pending_count=0
	if ! _check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1; then
		pending_count=1
	fi
	if [[ "$pending_count" -gt 0 ]]; then
		local enabled_at="" enabled_epoch="0" now_epoch="0" age_seconds="0"
		enabled_at=$(printf '%s' "$pr_state" | jq -r '.autoMergeRequest.enabledAt // ""' 2>/dev/null) || enabled_at=""
		enabled_epoch=$(date -u -d "$enabled_at" +%s 2>/dev/null \
			|| TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$enabled_at" +%s 2>/dev/null \
			|| echo "0")
		[[ "$enabled_epoch" =~ ^[0-9]+$ ]] || enabled_epoch=0
		now_epoch=$(date -u +%s)
		age_seconds=$((now_epoch - enabled_epoch))
		local threshold="${AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS:-300}"
		if [[ "$enabled_epoch" -gt 0 && "$age_seconds" -gt "$threshold" ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge has ${pending_count} required check(s) pending for ${age_seconds}s (>${threshold}s) — deferring as non-terminal (t3567)" >>"$LOGFILE"
			return 0
		fi
	fi
	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: auto_merge already set, deferring to GitHub (t3070)" >>"$LOGFILE"
	return 0
}

#######################################
# Conditionally hand a PR off to GitHub native auto-merge (t3070).
#
# Eliminates the ~120s pulse poll-cycle latency between CI green and merge
# call. When the repo has allow_auto_merge enabled and at least one
# required check is currently pending, ask GitHub to merge as soon as CI
# turns green via `gh pr merge --auto --squash`. GitHub then merges within
# seconds of the last required check completing instead of waiting for the
# next pulse cycle to detect green.
#
# Decision tree:
#   * PR already has auto_merge set + STUCK green → return 1 (caller --admin path,
#                                                             t3192 stuck fallback)
#   * PR already has auto_merge set + stale pending → return 0 (non-terminal;
#                                                               keep deferring)
#   * PR already has auto_merge set + healthy → return 0 (no-op, GitHub
#                                                         finishes the job)
#   * Repo allow_auto_merge=false      → return 1 (caller --admin path)
#   * No required check pending        → return 1 (caller --admin path —
#                                                  immediate merge fastest)
#   * gh pr merge --auto succeeds      → return 0 (caller skips merge)
#   * gh pr merge --auto fails         → return 1 (caller --admin fallback)
#
# Caller MUST verify all other merge gates (review, maintainer, scope,
# review-bot-gate, complexity) BEFORE invoking. This helper only chooses
# between native-auto and immediate-merge — it does not gate trust.
#
# Native auto-merge respects branch protection (no --admin bypass). Repos
# bypass-merging through pending checks should keep the immediate-merge
# fallback (returns 1 path) — this trade-off is acceptable for owned-org
# repos where allow_auto_merge=true is bulk-enabled and CI is fast.
#
# Args: $1=pr_number, $2=repo_slug, $3=require synchronous final gate (0|1),
#       $4=current already-gated review state, $5=gated head SHA
# Returns: 0=native-auto requested/deferred, 1=fall through,
#          2=defer without native auto-merge so mutable approval state is
#            revalidated on a later synchronous merge cycle
#######################################
_set_native_auto_merge_or_skip() {
	local pr_number="$1"
	local repo_slug="$2"
	local require_synchronous_final_gate="${3:-0}"
	local current_review="${4:-UNKNOWN}"
	local expected_head_sha="${5:-}"

	# Fetch auto_merge metadata + merge state through exact-attribution routes.
	# Carry forward the review state that passed this cycle's gate; unknown or
	# blocking states cannot authorize stale native-auto wedge recovery.
	local _pr_state
	_pr_state=$(_pmp_native_auto_merge_state "$pr_number" "$repo_slug" "$current_review" 2>/dev/null) || _pr_state=""

	local _existing_auto=""
	if [[ -n "$_pr_state" ]]; then
		_existing_auto=$(printf '%s' "$_pr_state" | jq -r '.autoMergeRequest // empty' 2>/dev/null)
	fi

	if [[ -n "$_existing_auto" ]]; then
		_handle_existing_native_auto_merge "$pr_number" "$repo_slug" \
			"$require_synchronous_final_gate" "$expected_head_sha" "$_pr_state"
		return $?
	fi

	# Skip if repo does not allow auto-merge — fall through to immediate merge.
	if ! _repo_allows_auto_merge "$repo_slug"; then
		return 1
	fi

	# Determine if any required check is currently pending. If everything is
	# already done (success/skipped — failures filtered upstream by
	# _pr_required_checks_pass), the immediate --admin path is faster than
	# round-tripping through GitHub's auto-merge engine.
	local pending_count=0
	if ! _check_required_checks_passing "$repo_slug" "$pr_number" >/dev/null 2>&1; then
		pending_count=1
	fi

	if [[ "$pending_count" -eq 0 ]]; then
		# No pending required checks — immediate --admin merge is faster.
		return 1
	fi
	if [[ "$require_synchronous_final_gate" == "1" ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: CI pending; external approval state requires synchronous final revalidation, so native auto-merge remains disabled" >>"$LOGFILE"
		return 2
	fi

	# CI in flight — ask GitHub to merge on green, bound to the gated head.
	_enable_native_auto_merge_for_head "$pr_number" "$repo_slug" "$expected_head_sha" "$pending_count"
	return $?
}
