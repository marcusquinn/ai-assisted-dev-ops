#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-close.sh — Issue close/done reconciliation helpers
# =============================================================================
# Extracted from pulse-issue-reconcile.sh (GH#21286) to keep the orchestrator
# file below the 1500-line file-size-debt gate. Mirrors the split precedent
# from pulse-issue-reconcile-stale.sh (t2375).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined LOGFILE, REPOS_JSON, and
# PULSE_QUEUED_SCAN_LIMIT.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-close.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, gh_issue_list, etc.)
#   - pulse-issue-reconcile.sh (_read_cache_issues_for_slug, _build_oimp_lookup_for_slug, _gh_pr_list_merged)
#   - pulse-issue-reconcile-actions.sh (_action_ciw_single, _action_rsd_single, _action_oimp_single, _should_oimp)
#
# Exports:
#   close_issues_with_merged_prs          — close available issues whose dedup guard detects a merged PR
#   reconcile_stale_done_issues           — reconcile status:done issues (close or reset)
#   reconcile_open_issues_with_merged_prs — close open issues whose linked PR already merged
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_ISSUE_RECONCILE_CLOSE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_CLOSE_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Module-level variable defaults (set -u guards)
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"
: "${PULSE_QUEUED_SCAN_LIMIT:=1000}"

# Module-level label constant (from orchestrator)
[[ -n "${_PIR_PT_LABEL+x}" ]] || _PIR_PT_LABEL="parent-task"

# Module-level null sentinel for JSON checks (string-literal ratchet compliance)
[[ -n "${_PIR_NULL+x}" ]] || _PIR_NULL="null"

# Module-level slug iteration filter (string-literal ratchet: avoids repeating
# the jq filter 3x across close_issues_with_merged_prs, reconcile_stale_done_issues,
# and reconcile_open_issues_with_merged_prs).
_pir_close_slug_filter='.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""'

#######################################
# Close open issues whose work is already done — a merged PR exists
# that references the issue via "Closes #N" or matching task ID in
# the PR title (GH#16851).
#
# The dedup guard (Layer 4) detects these and blocks re-dispatch,
# but the issue stays open forever. This stage closes them with a
# comment linking to the merged PR, cleaning the backlog.
#######################################
close_issues_with_merged_prs() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"

	local total_closed=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# Only check issues marked available for dispatch. Capped at 20
		# per repo to limit API calls (dedup helper makes 1 call per issue).
		# t2773: prefer prefetch cache; fall back to gh_issue_list wrapper on cache miss.
		# _ciw_lbl: label name variable avoids repeating the string literal (string-literal ratchet).
		local _ciw_lbl="status:available"
		local issues_json _cache_issues_ciw
		if _cache_issues_ciw=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json=$(printf '%s' "$_cache_issues_ciw" | \
				jq -c --arg lbl "$_ciw_lbl" \
				'[.[] | select(.labels | map(.name) | index($lbl))] | .[0:20]' \
				2>/dev/null) || issues_json="[]"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--label "$_ciw_lbl" \
				--json number,title,labels --limit 20 2>/dev/null) || issues_json="[]"
		fi
		[[ -n "$issues_json" && "$issues_json" != "$_PIR_NULL" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			issue_title=$(printf '%s' "$issues_json" | jq -r ".[$i].title // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# t2776: delegate per-issue action to shared helper (_action_ciw_single).
			if _action_ciw_single "$slug" "$issue_num" "$issue_title" "$dedup_helper" "$verify_helper"; then
				total_closed=$((total_closed + 1))
			fi
		done
	done < <(jq -r "$_pir_close_slug_filter" "$repos_json" || true)

	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Close issues with merged PRs: closed ${total_closed} issue(s)" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Reconcile status:done issues that are still open.
#
# Workers set status:done when they believe work is complete, but the
# issue may stay open if: (1) PR merged but Closes #N was missing,
# (2) worker declared done but never created a PR, (3) PR was rejected.
#
# Case 1: merged PR found → close the issue (work verified done).
# Cases 2+3: no merged PR → reset to status:available for re-dispatch.
#
# Capped at 20 per repo per cycle to limit API calls.
#######################################
reconcile_stale_done_issues() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local dedup_helper="${HOME}/.aidevops/agents/scripts/dispatch-dedup-helper.sh"
	[[ -x "$dedup_helper" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"

	local total_closed=0
	local total_reset=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		# t2773: prefer prefetch cache; fall back to gh_issue_list wrapper on cache miss.
		local issues_json _cache_issues_rsd
		if _cache_issues_rsd=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json=$(printf '%s' "$_cache_issues_rsd" | \
				jq -c --arg lbl "status:done" \
				'[.[] | select(.labels | map(.name) | index($lbl))] | .[0:20]' \
				2>/dev/null) || issues_json="[]"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--label "status:done" \
				--json number,title --limit 20 2>/dev/null) || issues_json="[]"
		fi
		[[ -n "$issues_json" && "$issues_json" != "$_PIR_NULL" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$issue_count" ]]; do
			local issue_num issue_title
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			issue_title=$(printf '%s' "$issues_json" | jq -r ".[$i].title // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# t2776: delegate per-issue action to shared helper (_action_rsd_single).
			local _rsd_rc
			_action_rsd_single "$slug" "$issue_num" "$issue_title" "$dedup_helper" "$verify_helper"
			_rsd_rc=$?
			if [[ "$_rsd_rc" -eq 0 ]]; then
				total_closed=$((total_closed + 1))
			elif [[ "$_rsd_rc" -eq 2 ]]; then
				total_reset=$((total_reset + 1))
			fi
		done
	done < <(jq -r "$_pir_close_slug_filter" "$repos_json" || true)

	if [[ "$((total_closed + total_reset))" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile stale done issues: closed=${total_closed}, reset=${total_reset}" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Close open issues whose linked PR has already merged.
#
# Gap: _handle_post_merge_actions only closes issues when the PULSE merges
# the PR. PRs merged by --admin (interactive sessions), GitHub merge button,
# or any other mechanism leave the issue open. This reconciliation pass
# catches those orphans.
#
# Scans open issues with active status labels (in-review, in-progress,
# queued, available) and checks whether a merged PR references them via
# `Resolves #N`, `Closes #N`, or `Fixes #N`. If found, closes the issue.
#
# Rate-limited: max 10 closes per cycle to avoid API abuse.
#######################################
reconcile_open_issues_with_merged_prs() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local verify_helper="${HOME}/.aidevops/agents/scripts/verify-issue-close-helper.sh"
	local total_closed=0
	local max_closes=10

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		[[ "$total_closed" -lt "$max_closes" ]] || break

		# Get open issues — t2773: prefer prefetch cache; fall back to gh_issue_list wrapper.
		# Include labels in the fallback so the parent-task check below works without a
		# separate gh api call in either path.
		local issues_json _cache_issues_oimp
		if _cache_issues_oimp=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			issues_json=$(printf '%s' "$_cache_issues_oimp" | jq -c '.[0:30]' 2>/dev/null) || issues_json="[]"
		else
			issues_json=$(gh_issue_list --repo "$slug" --state open \
				--json number,title,labels,body --limit 30 2>/dev/null) || issues_json="[]"
		fi
		[[ -n "$issues_json" && "$issues_json" != "$_PIR_NULL" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		# Pre-extract parent-task issue numbers in one jq pass to avoid spawning
		# jq once per loop iteration (GH#20675: Gemini review feedback on PR #20667).
		local parent_task_nums
		parent_task_nums=$(printf '%s' "$issues_json" | \
			jq -r --arg pt "$_PIR_PT_LABEL" '.[] | select((.labels // []) | map(.name) | index($pt) != null) | .number' \
			2>/dev/null) || parent_task_nums=""

		# t2985: per-repo merged-PR prefetch (replaces per-issue gh search).
		# Same pattern as reconcile_issues_single_pass — one gh call here
		# replaces N per-issue gh search calls in _action_oimp_single.
		local oimp_lookup=""
		oimp_lookup=$(_build_oimp_lookup_for_slug "$slug")

		local i=0
		while [[ "$i" -lt "$issue_count" ]] && [[ "$total_closed" -lt "$max_closes" ]]; do
			local issue_num="" issue_body=""
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			issue_body=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].body // ""' 2>/dev/null) || issue_body=""
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Skip parent-task issues (closing a parent from a child PR is wrong).
			# Labels pre-extracted above in a single jq pass (GH#20675).
			_should_oimp "$issue_num" "$parent_task_nums" || continue

			# t2776: delegate per-issue action to shared helper (_action_oimp_single).
			# t2985: pass oimp_lookup as 4th arg.
			if _action_oimp_single "$slug" "$issue_num" "$verify_helper" "$oimp_lookup" "$issue_body"; then
				total_closed=$((total_closed + 1))
			fi
		done
	done < <(jq -r "$_pir_close_slug_filter" "$repos_json" || true)

	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile open issues with merged PRs: closed=${total_closed}" >>"$LOGFILE"
	fi

	return 0
}
