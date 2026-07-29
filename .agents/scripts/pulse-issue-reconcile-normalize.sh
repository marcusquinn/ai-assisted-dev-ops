#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-normalize.sh — Label invariant normalization helpers
# =============================================================================
# Extracted from pulse-issue-reconcile.sh (GH#21376) to keep the orchestrator
# file below the 2000-line file-size-debt gate. Mirrors the split precedent
# from pulse-issue-reconcile-stale.sh (t2375).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined LOGFILE, REPOS_JSON, and
# PULSE_QUEUED_SCAN_LIMIT, plus the ISSUE_STATUS_LABELS, ISSUE_STATUS_LABEL_PRECEDENCE,
# and ISSUE_TIER_LABEL_RANK arrays from shared-constants.sh.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-normalize.sh"
#
# Exports:
#   _filter_core_status_labels         — filter status list to core labels
#   _pick_status_survivor              — select winner from core status array
#   _pick_tier_survivor                — select winner from tier array
#   _enforce_status_invariant_one_issue — fix multi-status issues
#   _enforce_tier_invariant_one_issue   — fix multi-tier issues
#   _fetch_label_invariant_rows        — fetch per-repo issue rows for invariant check
#   _normalize_label_invariants_for_repo — per-repo invariant pass
#   _write_label_invariants_counter_file — persist cycle counters for t2041
#   _normalize_label_invariants        — coordinator (t2040 Phase 3)

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_NORMALIZE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_NORMALIZE_LOADED=1

#######################################
# (t2040 Phase 3 helper) Enforce label invariants across all open issues.
#
# Walks every open issue in every pulse-enabled repo and enforces:
#
#   1. At most one core `status:*` label. When multiple are present,
#      the survivor is picked by ISSUE_STATUS_LABEL_PRECEDENCE
#      (`done > in-review > in-progress > queued > claimed > available
#      > blocked`). `done` is terminal — it always wins if present.
#      Atomic migration via `set_issue_status`.
#
#   2. At most one `tier:*` label. Rank matches
#      .github/workflows/dedup-tier-labels.yml so this pass is idempotent
#      with the GH Action: rank `reasoning > standard > simple`.
#
# Also counts (but does not auto-fix) triage-missing issues — those with
# `origin:interactive` label AND no `tier:*` AND no `auto-dispatch` AND no
# `status:*` AND created >30min ago. These need human tier assignment and
# brief creation; surfaced via the summary log line so the LLM sweep
# (t2041) can highlight them in the Hygiene Anomalies section.
#
# This pass is the backfill path for the 14 already-polluted issues left
# by the write-without-remove bug (fixed forward by PR #18519 / t2033)
# and the tier concatenation bug (fixed forward by PR #18441 / t1997).
# After a single pulse cycle post-merge, polluted state should normalize.
#
# Args:
#   $1 runner_user — GH login of the current runner (unused, kept for
#                    symmetry with other _normalize_* helpers)
#   $2 repos_json  — path to repos.json
# Returns: 0 always (best-effort; logs counters to $LOGFILE)
#######################################
# Helper: filter a space-separated list of status names down to those
# that are members of ISSUE_STATUS_LABELS. Used by the status-invariant
# check to ignore out-of-band labels (needs-info, verify-failed, etc.)
# which can legitimately coexist with a core status.
#
# Writes the result to the global array _LI_FILTERED_STATUS (bash 3.2
# has no namerefs; eval-based output patterns break under `set -u` when
# the result array is empty).
#
# Args:
#   $1 - space-separated status names (e.g. "available queued")
_filter_core_status_labels() {
	local status_list="$1"
	_LI_FILTERED_STATUS=()
	local _s="" _core_label=""
	[[ -n "$status_list" ]] || return 0
	for _s in $status_list; do
		for _core_label in "${ISSUE_STATUS_LABELS[@]}"; do
			if [[ "$_s" == "$_core_label" ]]; then
				_LI_FILTERED_STATUS+=("$_s")
				break
			fi
		done
	done
	return 0
}

# Helper: given an array of core status names, pick the survivor per
# ISSUE_STATUS_LABEL_PRECEDENCE and emit it on stdout. Empty if none.
_pick_status_survivor() {
	local _precedent="" _current=""
	local _has_available="" _has_blocked="" _has_active=""
	local _blocked_status="blocked"
	for _current in "$@"; do
		[[ "$_current" == "available" ]] && _has_available="1"
		[[ "$_current" == "$_blocked_status" ]] && _has_blocked="1"
		[[ "$_current" != "available" && "$_current" != "$_blocked_status" ]] && _has_active="1"
	done
	# A dual blocked/available state is unsafe regardless of ordinary lifecycle
	# precedence: queue readers may otherwise advertise the issue before the
	# dependency pass repairs it. Fail closed and make the pair exclusive.
	if [[ -n "$_has_available" && -n "$_has_blocked" && -z "$_has_active" ]]; then
		echo "$_blocked_status"
		return 0
	fi
	for _precedent in "${ISSUE_STATUS_LABEL_PRECEDENCE[@]}"; do
		for _current in "$@"; do
			if [[ "$_current" == "$_precedent" ]]; then
				echo "$_precedent"
				return 0
			fi
		done
	done
	return 0
}

# Helper: given an array of tier names, pick the survivor per
# ISSUE_TIER_LABEL_RANK and emit it on stdout. Empty if none.
_pick_tier_survivor() {
	local _rank="" _current_tier=""
	for _rank in "${ISSUE_TIER_LABEL_RANK[@]}"; do
		for _current_tier in "$@"; do
			if [[ "$_current_tier" == "$_rank" ]]; then
				echo "$_rank"
				return 0
			fi
		done
	done
	return 0
}

# Helper: enforce status invariant for one issue. Caller passes the
# already-filtered core_status names as positional args (guaranteed
# by the caller to have length >1). Returns 0 if a fix was applied.
_enforce_status_invariant_one_issue() {
	local issue_num="$1" slug="$2"
	shift 2
	local survivor
	survivor=$(_pick_status_survivor "$@")
	[[ -n "$survivor" ]] || return 1

	echo "[pulse-wrapper] label_invariants: #${issue_num} in ${slug} had status labels [$*] -> keeping '${survivor}'" >>"$LOGFILE"
	set_issue_status "$issue_num" "$slug" "$survivor" >/dev/null 2>&1 || true
	return 0
}

# Helper: enforce tier invariant for one issue. Caller passes tier
# names as positional args (guaranteed to have length >1).
_enforce_tier_invariant_one_issue() {
	local issue_num="$1" slug="$2"
	shift 2
	local tier_survivor
	tier_survivor=$(_pick_tier_survivor "$@")
	[[ -n "$tier_survivor" ]] || return 1

	echo "[pulse-wrapper] label_invariants: #${issue_num} in ${slug} had tier labels [$*] -> keeping 'tier:${tier_survivor}'" >>"$LOGFILE"
	local -a tier_flags=()
	local _losing
	for _losing in "$@"; do
		if [[ "$_losing" != "$tier_survivor" ]]; then
			tier_flags+=(--remove-label "tier:${_losing}")
		fi
	done
	[[ "${#tier_flags[@]}" -gt 0 ]] || return 1
	gh issue edit "$issue_num" --repo "$slug" "${tier_flags[@]}" >/dev/null 2>&1 || true
	return 0
}

# Helper: fetch issues for a repo and emit '|'-delimited rows per issue.
# See delimiter note in _normalize_label_invariants_for_repo.
_fetch_label_invariant_rows() {
	local slug="$1"
	# t2773: route through gh_issue_list wrapper (REST fallback on rate-limit exhaustion).
	# This fetch needs createdAt which is not in the prefetch cache, so the cache cannot
	# serve it — gh_issue_list is used directly (not the cache path).
	local issues_json
	issues_json=$(gh_issue_list --repo "$slug" --state open \
		--json number,labels,createdAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || issues_json=""
	[[ -n "$issues_json" && "$issues_json" != "null" ]] || return 1

	# has_any_status counts ALL status:* labels (core + exception) so the
	# triage-missing counter correctly ignores issues that are actively
	# managed via an exception label (needs-info, verify-failed, stale,
	# needs-testing, orphaned). See CodeRabbit review on PR #18546.
	printf '%s' "$issues_json" | jq -r '
		.[] | (.labels // []) as $labels | [
			(.number | tostring),
			([$labels[].name | select(startswith("status:")) | sub("^status:"; "")] | join(" ")),
			([$labels[].name | select(startswith("tier:"))   | sub("^tier:";   "")] | join(" ")),
			(any($labels[].name; . == "origin:interactive") | tostring),
			(any($labels[].name; . == "auto-dispatch")      | tostring),
			(any($labels[].name; . == ("supervisor", "contributor", "persistent", "quality-review", "needs-maintainer-review", "routine-tracking", "on hold")) | tostring),
			(.createdAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | tostring),
			(([$labels[].name | select(startswith("status:"))] | length) | tostring)
		] | join("|")
	' 2>/dev/null
	return 0
}

# Helper: process all issues for one repo. Updates the global
# _LI_* counters (caller accumulates into totals).
#
# Uses global accumulators rather than per-call output vars because
# the outer coordinator needs three counters and one checked count.
#
# DELIMITER CHOICE: '|' — a non-whitespace character that GitHub
# label names cannot contain. Do NOT use @tsv: bash read with
# IFS=$'\t' collapses consecutive tabs because tab is a whitespace
# character in bash's field-splitting rules, so empty fields silently
# disappear and the next field shifts into place, corrupting parses
# on issues with no status labels (tier-only pollution case).
_normalize_label_invariants_for_repo() {
	local slug="$1"
	local triage_cutoff="$2"

	local rows
	rows=$(_fetch_label_invariant_rows "$slug") || return 0
	[[ -n "$rows" ]] || return 0

	local issue_num="" status_list="" tier_list="" has_origin_i="" has_auto="" is_non_task="" created_epoch="" all_status_count=""
	while IFS='|' read -r issue_num status_list tier_list has_origin_i has_auto is_non_task created_epoch all_status_count; do
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
		_LI_CHECKED=$((_LI_CHECKED + 1))

		_filter_core_status_labels "$status_list"
		local core_count="${#_LI_FILTERED_STATUS[@]}"

		if [[ "$core_count" -gt 1 ]] &&
			_enforce_status_invariant_one_issue "$issue_num" "$slug" "${_LI_FILTERED_STATUS[@]}"; then
			_LI_STATUS_FIXED=$((_LI_STATUS_FIXED + 1))
		fi

		local -a tier_arr=()
		if [[ -n "$tier_list" ]]; then
			local _t
			for _t in $tier_list; do
				tier_arr+=("$_t")
			done
		fi

		local tier_count="${#tier_arr[@]}"
		if [[ "$tier_count" -gt 1 ]] &&
			_enforce_tier_invariant_one_issue "$issue_num" "$slug" "${tier_arr[@]}"; then
			_LI_TIER_FIXED=$((_LI_TIER_FIXED + 1))
		fi

		# Triage-missing count (flag only, no auto-fix). origin:interactive
		# + no tier + no auto-dispatch + no status:* AT ALL (including
		# exception labels like needs-info/verify-failed/stale — an issue
		# in those states is actively managed, not awaiting triage) +
		# no non-task label (routine-tracking/supervisor/etc.) +
		# created >30min ago = maintainer-intended issue not briefed into
		# the dispatch pipeline.
		if [[ "$has_origin_i" == "true" &&
			-z "$tier_list" &&
			"$has_auto" == "false" &&
			"$is_non_task" == "false" &&
			"$all_status_count" == "0" &&
			"$created_epoch" =~ ^[0-9]+$ &&
			"$created_epoch" -lt "$triage_cutoff" ]]; then
			_LI_TRIAGE_MISSING=$((_LI_TRIAGE_MISSING + 1))
		fi
	done <<<"$rows"
	return 0
}

# Helper: write the counter JSON file consumed by t2041 prefetch layer.
_write_label_invariants_counter_file() {
	local counters_dir="${HOME}/.aidevops/cache"
	local hostname_short
	hostname_short=$(hostname -s 2>/dev/null || echo unknown)
	local counters_file="${counters_dir}/pulse-label-invariants.${hostname_short}.json"
	mkdir -p "$counters_dir" 2>/dev/null || true
	{
		printf '{"timestamp": "%s", "checked": %d, "status_fixed": %d, "tier_fixed": %d, "triage_missing": %d}\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
			"$_LI_CHECKED" "$_LI_STATUS_FIXED" "$_LI_TIER_FIXED" "$_LI_TRIAGE_MISSING"
	} >"$counters_file" 2>/dev/null || true
	return 0
}

# t2040: coordinator for the label-invariant pass. Delegates the per-issue
# work to focused helpers so each function stays under the 100-line block
# threshold. Global accumulators (_LI_*) are used instead of per-call
# output vars because the coordinator needs four counters and bash 3.2
# lacks namerefs.
_normalize_label_invariants() {
	local runner_user="$1"
	local repos_json="$2"
	# shellcheck disable=SC2034  # runner_user kept for signature symmetry
	local _unused_runner="$runner_user"

	# Guard: requires the precedence arrays from shared-constants.sh.
	# Silently skip (fail-open) to avoid blocking the pulse on a bootstrap bug.
	if [[ -z "${ISSUE_STATUS_LABEL_PRECEDENCE+x}" || -z "${ISSUE_TIER_LABEL_RANK+x}" ]]; then
		echo "[pulse-wrapper] normalize_label_invariants skipped: precedence arrays not loaded" >>"$LOGFILE"
		return 0
	fi

	# Shared accumulators — reset at start of every pass.
	_LI_CHECKED=0
	_LI_STATUS_FIXED=0
	_LI_TIER_FIXED=0
	_LI_TRIAGE_MISSING=0

	local now_epoch
	now_epoch=$(date +%s)
	local triage_cutoff=$((now_epoch - 1800))

	local slug
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		_normalize_label_invariants_for_repo "$slug" "$triage_cutoff"
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	echo "[pulse-wrapper] label_invariants: checked=${_LI_CHECKED} status_fixed=${_LI_STATUS_FIXED} tier_fixed=${_LI_TIER_FIXED} triage_missing=${_LI_TRIAGE_MISSING}" >>"$LOGFILE"

	_write_label_invariants_counter_file
	return 0
}
