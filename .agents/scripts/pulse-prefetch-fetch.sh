#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-prefetch-fetch.sh — PR/issue fetch helpers + single-repo orchestration
# =============================================================================
# Sub-library extracted from pulse-prefetch.sh (GH#19964).
# Covers:
#   1. PR delta/full fetch, enrichment, and formatting
#   2. Issue delta fetch helper
#   3. Single-repo idle-skip replay and orchestration
#   4. Parallel pid wait
#   5. State assembly and sub-helper runner
#   6. Per-repo pulse schedule checking
#   7. Per-repo pulse interval throttle (GH#20660)
#   8. Per-repo activity tier skip (t2831) — hot/warm/cold cadence control
#
# Usage: source "${SCRIPT_DIR}/pulse-prefetch-fetch.sh"
#
# Dependencies:
#   - pulse-prefetch-infra.sh (cache helpers, rate-limit helpers)
#   - shared-constants.sh
#   - pulse-repo-tier.sh (t2831: tier-of command, optional — degrades gracefully)
#   - Environment vars: LOGFILE, PULSE_PREFETCH_PR_LIMIT, PULSE_PREFETCH_ISSUE_LIMIT,
#     DAILY_PR_CAP, STATE_FILE, TRIAGE_STATE_FILE, REPOS_JSON, FOSS_SCAN_TIMEOUT
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_PREFETCH_FETCH_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_FETCH_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# PR Prefetch Helpers (GH#5627, GH#15286, GH#15060)
# =============================================================================

_PREFETCH_PR_SWEEP_FULL=full
_PREFETCH_BOOL_TRUE=true
_PREFETCH_JSON_NULL=null
_PREFETCH_JSON_TYPE_ARRAY=array
_PREFETCH_UNKNOWN=unknown
_PREFETCH_UNKNOWN_ERROR="unknown error"

#######################################
# Attempt delta PR fetch and merge into cached list (GH#15286).
# Sets PREFETCH_PR_SWEEP_MODE=full on failure (caller falls through).
# Sets PREFETCH_PR_RESULT on success.
# Arguments: $1=slug, $2=cache_entry, $3=pr_err_file
#######################################
_prefetch_prs_try_delta() {
	local slug="$1"
	local cache_entry="$2"
	local pr_err="$3"

	# gh pr list --search is GraphQL-only in the compatibility wrapper and does
	# not expose operation-owned cost. Under REST-first collection, prefer one
	# full REST list over an unattributable delta query (GH#27777).
	if [[ "${AIDEVOPS_GH_REST_FIRST_READS:-0}" == "1" || "${AIDEVOPS_GH_FORCE_REST_READS:-0}" == "1" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_prs: REST-first mode bypasses GraphQL-only delta search for ${slug}; using full REST sweep (GH#27777)" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="$_PREFETCH_PR_SWEEP_FULL"
		return 0
	fi

	local last_prefetch
	last_prefetch=$(echo "$cache_entry" | jq -r '.last_prefetch // ""' 2>/dev/null) || last_prefetch=""

	# No usable timestamp — fall back to full
	if [[ -z "$last_prefetch" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_prs: delta fetch failed for ${slug} (falling back to full): no timestamp or fetch error" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="$_PREFETCH_PR_SWEEP_FULL"
		return 0
	fi

	# headRefOid required for REST check-suites lookup (GH#21799).
	local delta_json=""
	delta_json=$(gh_pr_list --repo "$slug" --state open \
		--json number,title,updatedAt,headRefName,headRefOid,createdAt,author \
		--search "updated:>=${last_prefetch}" \
		--limit "$PULSE_PREFETCH_PR_LIMIT" 2>"$pr_err") || delta_json=""

	if [[ -z "$delta_json" || "$delta_json" == "$_PREFETCH_JSON_NULL" ]]; then
		local _delta_err_msg
		_delta_err_msg=$(cat "$pr_err" 2>/dev/null || echo "no timestamp or fetch error")
		echo "[pulse-wrapper] _prefetch_repo_prs: delta fetch failed for ${slug} (falling back to full): ${_delta_err_msg}" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="$_PREFETCH_PR_SWEEP_FULL"
		return 0
	fi

	# Merge delta into cached full list: replace matching numbers, append new ones
	local cached_prs
	cached_prs=$(echo "$cache_entry" | jq '.prs // []' 2>/dev/null) || cached_prs="[]"
	local merged
	merged=$(echo "$cached_prs" | jq --argjson delta "$delta_json" '
		($delta | map(.number) | map(tostring) | map({(.) : true}) | add // {}) as $delta_nums |
		[.[] | select((.number | tostring) as $n | $delta_nums[$n] | not)] +
		$delta
	' 2>/dev/null) || merged=""

	if [[ -z "$merged" || "$merged" == "$_PREFETCH_JSON_NULL" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_prs: delta merge failed for ${slug} (falling back to full)" >>"$LOGFILE"
		PREFETCH_PR_SWEEP_MODE="$_PREFETCH_PR_SWEEP_FULL"
		return 0
	fi

	local delta_count
	delta_count=$(echo "$delta_json" | jq 'length' 2>/dev/null) || delta_count=0
	echo "[pulse-wrapper] _prefetch_repo_prs: delta for ${slug}: ${delta_count} changed PRs merged into cache" >>"$LOGFILE"
	PREFETCH_PR_RESULT="$merged"
	return 0
}

#######################################
# Compute aggregated check status for a list of open PRs via REST
# `/commits/{sha}/check-suites` (GH#21799 — replaces the GraphQL
# `statusCheckRollup` field that was the single heaviest payload in the
# pulse's GraphQL budget).
#
# The batch helper caches only this observational aggregate, emits cache/fetch
# decisions to gh transport telemetry, and preserves live named-check reads for
# final required-check and merge authority. Non-fatal: returns "[]" on failure
# (caller treats as "no check info").
#
# Arguments:
#   $1 - repo slug
#   $2 - pr_json (already-fetched PR list with .number and .headRefOid)
#
# Output: JSON array `[{"number":N,"status":"PASS|FAIL|PENDING|none"}, ...]`
#######################################
_prefetch_prs_enrich_checks() {
	local slug="$1"
	local pr_json="$2"

	if [[ -z "$pr_json" || "$pr_json" == "[]" || "$pr_json" == "$_PREFETCH_JSON_NULL" ]]; then
		printf '[]'
		return 0
	fi

	local checks_json=""
	checks_json=$(gh_pr_check_status_rest_batch "$slug" "$pr_json" 2>/dev/null) || checks_json=""

	if [[ -z "$checks_json" || "$checks_json" == "$_PREFETCH_JSON_NULL" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_prs: REST check-suites enrichment FAILED for ${slug} (non-fatal, PRs shown without check status)" >>"$LOGFILE"
		checks_json="[]"
	fi

	printf '%s' "$checks_json"
	return 0
}

#######################################
# Format PR list as markdown with optional check status enrichment.
# Arguments: $1=pr_json, $2=pr_count, $3=checks_json
# Output: markdown to stdout
#######################################
_prefetch_prs_format_output() {
	local pr_json="$1"
	local pr_count="$2"
	local checks_json="$3"

	if [[ "$pr_count" -le 0 ]]; then
		echo "### Open PRs (0)"
		echo "- None"
		return 0
	fi

	echo "### Open PRs ($pr_count)"
	if [[ -n "$checks_json" && "$checks_json" != "[]" ]]; then
		# GH#21799: checks_json now contains pre-computed status strings
		# from REST check-suites (~15KB total vs ~245KB GraphQL rollup).
		# Stdin keeps the path that handles large pr_json safely.
		echo "$checks_json" | jq -r --argjson prs "$pr_json" --arg unknown "$_PREFETCH_UNKNOWN" '
			(. | map({(.number | tostring): .status}) | add // {}) as $check_map |
			$prs[] |
			(.number | tostring) as $num |
			($check_map[$num] // $unknown) as $cs |
			"- PR #\(.number): \(.title) [checks: \($cs)] [review: \(
				if has("reviewDecision") | not then "UNKNOWN"
				elif .reviewDecision == null or .reviewDecision == "" then "NONE"
				else .reviewDecision
				end
			)] [author: \(.author.login // $unknown)] [branch: \(.headRefName // $unknown)] [updated: \(.updatedAt)]"
		'
	else
		echo "$pr_json" | jq -r --arg unknown "$_PREFETCH_UNKNOWN" '.[] | "- PR #\(.number): \(.title) [checks: \($unknown)] [review: \(if has("reviewDecision") | not then "UNKNOWN" elif .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end)] [author: \(.author.login // $unknown)] [branch: \(.headRefName // $unknown)] [updated: \(.updatedAt)]"'
	fi
	return 0
}

#######################################
# Record a validated batch-cache hit without counting an HTTP attempt.
# Arguments: $1=kind, $2=validated JSON-array payload
#######################################
_prefetch_record_batch_cache_hit() {
	local kind="$1"
	local payload="$2"
	local decision="hit-nonempty"
	[[ "$payload" == "[]" ]] && decision="hit-empty"
	if command -v gh_record_call >/dev/null 2>&1; then
		gh_record_call other "pulse_batch_prefetch_${kind}_cache" unknown other \
			"$decision" "" cache 2>/dev/null || true
	fi
	return 0
}

#######################################
# Log a canonical cache state that occurs after a cache miss.
# Arguments: $1=state, $2=kind, $3=slug
#######################################
_prefetch_log_batch_cache_state() {
	local state="$1"
	local kind="$2"
	local slug="$3"
	printf '[pulse-wrapper] cache_state=%s kind=%s slug=%s cardinality=unknown\n' \
		"$state" "$kind" "$slug" >>"$LOGFILE"
	return 0
}

#######################################
# Read a validated item array from a canonical snapshot envelope.
# Arguments: $1=canonical snapshot envelope
#######################################
_prefetch_snapshot_items() {
	local canonical_snapshot="$1"
	printf '%s' "$canonical_snapshot" |
		jq -ce --arg array_type "$_PREFETCH_JSON_TYPE_ARRAY" \
			'.items | select(type == $array_type)' 2>/dev/null
	return $?
}

#######################################
# Record an invariant violation only when a live fallback follows an
# authoritative fresh-empty canonical snapshot.
# Arguments: $1=snapshot-supplied bool, $2=canonical snapshot envelope
#######################################
_prefetch_record_fresh_empty_live_fallback() {
	local snapshot_supplied="$1"
	local canonical_snapshot="$2"
	local items=""
	[[ "$snapshot_supplied" == "$_PREFETCH_BOOL_TRUE" ]] || return 0
	items=$(_prefetch_snapshot_items "$canonical_snapshot") || return 0
	[[ "$items" == "[]" ]] || return 0
	if declare -F gh_record_efficiency_evidence >/dev/null 2>&1; then
		gh_record_efficiency_evidence path_budgets.fresh_empty_live_fallbacks 1 2>/dev/null || true
	fi
	return 0
}

#######################################
# Fetch the complete open-PR projection while preserving rate-limit state.
# Arguments: $1=slug, $2=error file
# Sets PREFETCH_PR_RESULT.
#######################################
_prefetch_prs_fetch_full() {
	local slug="$1"
	local pr_err="$2"
	local err_msg=""

	PREFETCH_PR_RESULT=$(gh_pr_list --repo "$slug" --state open \
		--json number,title,updatedAt,headRefName,headRefOid,createdAt,author \
		--limit "$PULSE_PREFETCH_PR_LIMIT" 2>"$pr_err") || PREFETCH_PR_RESULT=""
	if [[ -z "$PREFETCH_PR_RESULT" || "$PREFETCH_PR_RESULT" == "$_PREFETCH_JSON_NULL" ]]; then
		err_msg=$(cat "$pr_err" 2>/dev/null || echo "$_PREFETCH_UNKNOWN_ERROR")
		if _pulse_gh_err_is_rate_limit "$pr_err"; then
			_pulse_mark_rate_limited "_prefetch_repo_prs:${slug}"
		fi
		echo "[pulse-wrapper] _prefetch_repo_prs: gh_pr_list FAILED for ${slug}: ${err_msg}" >>"$LOGFILE"
		_prefetch_log_batch_cache_state fetch-failed prs "$slug"
		PREFETCH_PR_RESULT="[]"
	fi
	return 0
}

_prefetch_repo_prs() {
	local slug="$1"
	local cache_entry="${2:-}"
	[[ -n "$cache_entry" ]] || cache_entry="{}"
	local sweep_mode="${3:-full}"
	local canonical_snapshot="${4:-}"
	local canonical_snapshot_supplied=false
	[[ "$#" -ge 4 ]] && canonical_snapshot_supplied=true

	# PRs (createdAt included for daily PR cap — GH#3821)
	# GH#15060: statusCheckRollup is the heaviest field in the GraphQL payload —
	# each PR's full check suite data can be kilobytes. With 100+ PRs, the
	# response exceeds GitHub's internal timeout and `gh` returns an error that
	# the `2>/dev/null || pr_json="[]"` pattern silently swallows, producing
	# "Open PRs (0)" when hundreds exist. This was the root cause of the pulse
	# seeing 0 PRs and never merging anything.
	#
	# Fix: fetch without statusCheckRollup first (fast, always works), then
	# enrich with check status in a separate lightweight call. If the enrichment
	# fails, the pulse still sees the PR list; authoritative merge review state is
	# enriched separately from bounded REST review history.
	#
	# GH#15286: Delta mode — fetch only PRs updated since last_prefetch, then
	# merge into cached full list. Full sweep replaces the cache entirely.
	local pr_json="" pr_err
	pr_err=$(mktemp)

	# GH#19963 L3: Check batch prefetch cache before per-repo API calls.
	# Execution order: idle skip (L2, handled by caller) → batch cache (L3) → delta/full (L4/L5)
	local _batch_helper="${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
	local _used_batch_cache=false
	if [[ "$canonical_snapshot_supplied" == "$_PREFETCH_BOOL_TRUE" ]]; then
		local _canonical_prs=""
		if _canonical_prs=$(_prefetch_snapshot_items "$canonical_snapshot"); then
			pr_json="$_canonical_prs"
			_used_batch_cache=true
			echo "[pulse-wrapper] _prefetch_repo_prs: using cycle canonical snapshot for ${slug}" >>"$LOGFILE"
			_prefetch_record_batch_cache_hit prs "$_canonical_prs"
			_PULSE_HEALTH_BATCH_CACHE_HITS=$((${_PULSE_HEALTH_BATCH_CACHE_HITS:-0} + 1))
		fi
	elif [[ "${PULSE_BATCH_PREFETCH_ENABLED:-1}" == "1" && -x "$_batch_helper" ]]; then
		local _batch_prs
		if _batch_prs=$("$_batch_helper" read-cache --kind prs --slug "$slug" 2>>"$LOGFILE"); then
			pr_json="$_batch_prs"
			_used_batch_cache=true
			echo "[pulse-wrapper] _prefetch_repo_prs: using batch cache for ${slug}" >>"$LOGFILE"
			_prefetch_record_batch_cache_hit prs "$_batch_prs"
			_PULSE_HEALTH_BATCH_CACHE_HITS=$((${_PULSE_HEALTH_BATCH_CACHE_HITS:-0} + 1))
		fi
	fi

	if [[ "$_used_batch_cache" == "false" ]]; then
		_prefetch_record_fresh_empty_live_fallback \
			"$canonical_snapshot_supplied" "$canonical_snapshot"
		# Delta fetch: try merging recent changes into cache (GH#15286)
		PREFETCH_PR_SWEEP_MODE="$sweep_mode"
		PREFETCH_PR_RESULT=""
		if [[ "$sweep_mode" == "delta" ]]; then
			_prefetch_prs_try_delta "$slug" "$cache_entry" "$pr_err"
			sweep_mode="$PREFETCH_PR_SWEEP_MODE"
			pr_json="$PREFETCH_PR_RESULT"
		fi

		# Full fetch: either requested directly or delta fell back.
		if [[ "$sweep_mode" == "$_PREFETCH_PR_SWEEP_FULL" ]]; then
			_prefetch_prs_fetch_full "$slug" "$pr_err"
			pr_json="$PREFETCH_PR_RESULT"
		fi
	fi
	rm -f "$pr_err"

	# Export updated PR list for cache update by caller (Bash 3.2: no namerefs)
	PREFETCH_UPDATED_PRS="$pr_json"

	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	# Enrichment: derive PASS/FAIL/PENDING via REST check-suites (GH#21799,
	# replacing the heavier GraphQL statusCheckRollup originally added in GH#15060).
	local checks_json=""
	if [[ "$pr_count" -gt 0 ]]; then
		checks_json=$(_prefetch_prs_enrich_checks "$slug" "$pr_json")
	fi

	_prefetch_prs_format_output "$pr_json" "$pr_count" "$checks_json"

	echo ""
	return 0
}

#######################################
# Print the Daily PR Cap section for a repo (GH#5627)
#
# Counts ALL PRs created today (open+merged+closed) to enforce the
# daily cap. Must use --state all — open-only undercounts (GH#3821,
# GH#4412). Emits a markdown section to stdout.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#######################################
_prefetch_repo_daily_cap() {
	local slug="$1"

	local today_utc
	today_utc=$(date -u +%Y-%m-%d)
	local daily_cap_json daily_cap_err
	daily_cap_err=$(mktemp)
	daily_cap_json=$(gh_pr_list --repo "$slug" --state all \
		--json createdAt --limit 200 2>"$daily_cap_err") || daily_cap_json="[]"
	if [[ -z "$daily_cap_json" || "$daily_cap_json" == "$_PREFETCH_JSON_NULL" ]]; then
		local _daily_cap_err_msg
		_daily_cap_err_msg=$(cat "$daily_cap_err" 2>/dev/null || echo "$_PREFETCH_UNKNOWN_ERROR")
		# GH#18979 (t2097): detect rate-limit exhaustion
		if _pulse_gh_err_is_rate_limit "$daily_cap_err"; then
			_pulse_mark_rate_limited "_prefetch_repo_daily_cap:${slug}"
		fi
		echo "[pulse-wrapper] _prefetch_repo_daily_cap: gh_pr_list FAILED for ${slug}: ${_daily_cap_err_msg}" >>"$LOGFILE"
		daily_cap_json="[]"
	fi
	rm -f "$daily_cap_err"
	local daily_pr_count
	daily_pr_count=$(echo "$daily_cap_json" | jq --arg today "$today_utc" \
		'[.[] | select((.createdAt // "") | startswith($today))] | length') || daily_pr_count=0
	[[ "$daily_pr_count" =~ ^[0-9]+$ ]] || daily_pr_count=0
	local daily_pr_remaining=$((DAILY_PR_CAP - daily_pr_count))
	if [[ "$daily_pr_remaining" -lt 0 ]]; then
		daily_pr_remaining=0
	fi

	echo "### Daily PR Cap"
	if [[ "$daily_pr_count" -ge "$DAILY_PR_CAP" ]]; then
		echo "- **DAILY PR CAP REACHED** — ${daily_pr_count}/${DAILY_PR_CAP} PRs created today (UTC)"
		echo "- **DO NOT dispatch new workers for this repo.** Wait for the next UTC day."
		echo "[pulse-wrapper] Daily PR cap reached for ${slug}: ${daily_pr_count}/${DAILY_PR_CAP}" >>"$LOGFILE"
	else
		echo "- PRs created today: ${daily_pr_count}/${DAILY_PR_CAP} (${daily_pr_remaining} remaining)"
	fi

	echo ""
	return 0
}

#######################################
# Render normalized issues and export them for the cache-update path.
# Arguments: $1=issue JSON array
#######################################
_prefetch_repo_issues_render() {
	local issue_json="$1"

	# Export updated issue list for cache update by caller (Bash 3.2: no namerefs)
	PREFETCH_UPDATED_ISSUES="$issue_json"

	# Remove issues with non-dispatchable labels (GH#20048: shared helper)
	local filtered_json
	filtered_json=$(echo "$issue_json" | _filter_non_task_issues)

	# GH#10308: Split issues into dispatchable vs quality-sweep-tracked.
	local dispatchable_json="" sweep_tracked_json=""
	dispatchable_json=$(echo "$filtered_json" | jq '[.[] | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")) | not)]')
	sweep_tracked_json=$(echo "$filtered_json" | jq '[.[] | select(.labels | map(.name) | (index("source:quality-sweep") or index("source:review-feedback")))]')

	local dispatchable_count=0 sweep_tracked_count=0
	dispatchable_count=$(echo "$dispatchable_json" | jq 'length')
	sweep_tracked_count=$(echo "$sweep_tracked_json" | jq 'length')

	if [[ "$dispatchable_count" -gt 0 ]]; then
		echo "### Open Issues ($dispatchable_count)"
		echo "$dispatchable_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)] [updated: \(.updatedAt)]"'
	else
		echo "### Open Issues (0)"
		echo "- None"
	fi

	echo ""

	# GH#10308: Show quality-sweep-tracked issues so the LLM knows what's
	# already filed and avoids creating duplicates from sweep findings.
	if [[ "$sweep_tracked_count" -gt 0 ]]; then
		echo "### Already Tracked by Quality Sweep ($sweep_tracked_count)"
		echo "_These issues were auto-created by the quality sweep or review feedback pipeline._"
		echo "_DO NOT create new issues for findings already covered below. Dispatch these as normal quality-debt/file-size-debt/function-complexity-debt work._"
		echo "$sweep_tracked_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [assignees: \(if (.assignees | length) == 0 then "none" else (.assignees | map(.login) | join(", ")) end)]"'
		echo ""
	fi
	return 0
}

_prefetch_repo_issues() {
	local slug="$1"
	local cache_entry="${2:-}"
	[[ -n "$cache_entry" ]] || cache_entry="{}"
	local sweep_mode="${3:-full}"
	local canonical_snapshot="${4:-}"
	local canonical_snapshot_supplied=false
	[[ "$#" -ge 4 ]] && canonical_snapshot_supplied=true

	# Issues (include assignees for dispatch dedup)
	# Filter out supervisor/contributor/persistent/quality-review issues —
	# these are managed by pulse-wrapper.sh and must not be touched by the
	# pulse agent. Exposing them in pre-fetched state causes the LLM to
	# close them as "stale", creating churn (wrapper recreates on next cycle).
	# GH#15060: Log errors instead of silently swallowing them with 2>/dev/null.
	# GH#15286: Delta mode — fetch only recently-updated issues, merge into cache.
	local issue_json="" issue_err
	issue_err=$(mktemp)

	# GH#19963 L3: Check batch prefetch cache before per-repo API calls.
	# Execution order: idle skip (L2, handled by caller) → batch cache (L3) → delta/full (L4/L5)
	local _batch_helper="${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
	local _used_batch_cache=false
	if [[ "$canonical_snapshot_supplied" == "$_PREFETCH_BOOL_TRUE" ]]; then
		local _canonical_issues=""
		if _canonical_issues=$(_prefetch_snapshot_items "$canonical_snapshot"); then
			issue_json="$_canonical_issues"
			_used_batch_cache=true
			echo "[pulse-wrapper] _prefetch_repo_issues: using cycle canonical snapshot for ${slug}" >>"$LOGFILE"
			_prefetch_record_batch_cache_hit issues "$_canonical_issues"
			_PULSE_HEALTH_BATCH_CACHE_HITS=$((${_PULSE_HEALTH_BATCH_CACHE_HITS:-0} + 1))
		fi
	elif [[ "${PULSE_BATCH_PREFETCH_ENABLED:-1}" == "1" && -x "$_batch_helper" ]]; then
		local _batch_issues
		if _batch_issues=$("$_batch_helper" read-cache --kind issues --slug "$slug" 2>>"$LOGFILE"); then
			issue_json="$_batch_issues"
			_used_batch_cache=true
			echo "[pulse-wrapper] _prefetch_repo_issues: using batch cache for ${slug}" >>"$LOGFILE"
			_prefetch_record_batch_cache_hit issues "$_batch_issues"
			_PULSE_HEALTH_BATCH_CACHE_HITS=$((${_PULSE_HEALTH_BATCH_CACHE_HITS:-0} + 1))
		fi
	fi

	if [[ "$_used_batch_cache" == "false" ]]; then
		_prefetch_record_fresh_empty_live_fallback \
			"$canonical_snapshot_supplied" "$canonical_snapshot"
		# Delta fetch: try merging recent changes into cache (GH#15286)
		PREFETCH_ISSUE_SWEEP_MODE="$sweep_mode"
		PREFETCH_ISSUE_RESULT=""
		if [[ "$sweep_mode" == "delta" ]]; then
			_prefetch_issues_try_delta "$slug" "$cache_entry" "$issue_err"
			sweep_mode="$PREFETCH_ISSUE_SWEEP_MODE"
			issue_json="$PREFETCH_ISSUE_RESULT"
		fi

		# Full fetch: either requested directly or delta fell back
		if [[ "$sweep_mode" == "full" ]]; then
			issue_json=$(gh_issue_list --repo "$slug" --state open \
				--json number,title,state,labels,updatedAt,assignees,body \
				--limit "$PULSE_PREFETCH_ISSUE_LIMIT" 2>"$issue_err") || issue_json=""

			if [[ -z "$issue_json" || "$issue_json" == "$_PREFETCH_JSON_NULL" ]]; then
				local issue_err_msg
				issue_err_msg=$(cat "$issue_err" 2>/dev/null || echo "$_PREFETCH_UNKNOWN_ERROR")
				# GH#18979 (t2097): detect rate-limit exhaustion
				if _pulse_gh_err_is_rate_limit "$issue_err"; then
					_pulse_mark_rate_limited "_prefetch_repo_issues:${slug}"
				fi
				echo "[pulse-wrapper] _prefetch_repo_issues: gh_issue_list FAILED for ${slug}: ${issue_err_msg}" >>"$LOGFILE"
				_prefetch_log_batch_cache_state fetch-failed issues "$slug"
				issue_json="[]"
			fi
		fi
	fi
	rm -f "$issue_err"
	issue_json=$(echo "$issue_json" | _prefetch_open_issues_only)
	_prefetch_repo_issues_render "$issue_json"
	return 0
}

# =============================================================================
# Issue Delta Fetch Helper (GH#15286)
# =============================================================================

_prefetch_open_issues_only() {
	jq -c '[.[]? | select(((.state // "open") | ascii_downcase) == "open")]' 2>/dev/null || printf '[]'
	return 0
}

_prefetch_issue_cache_lacks_state() {
	jq -e 'any(.[]?; has("state") | not)' >/dev/null 2>&1
	return $?
}

_prefetch_cache_entry_issues_lack_state() {
	jq -e 'any((.issues // [])[]?; has("state") | not)' >/dev/null 2>&1
	return $?
}

_PREFETCH_ISSUE_SWEEP_FULL=full

#######################################
# Attempt delta issue fetch and merge into cached list (GH#15286).
# Sets PREFETCH_ISSUE_SWEEP_MODE=$_PREFETCH_ISSUE_SWEEP_FULL on failure (caller falls through).
# Sets PREFETCH_ISSUE_RESULT on success.
# Arguments: $1=slug, $2=cache_entry, $3=issue_err_file
#######################################
_prefetch_issues_try_delta() {
	local slug="$1"
	local cache_entry="$2"
	local issue_err="$3"

	local last_prefetch
	last_prefetch=$(echo "$cache_entry" | jq -r '.last_prefetch // ""' 2>/dev/null) || last_prefetch=""

	# No usable timestamp — fall back to full
	if [[ -z "$last_prefetch" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_issues: delta fetch failed for ${slug} (falling back to full): no timestamp or fetch error" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="$_PREFETCH_ISSUE_SWEEP_FULL"
		return 0
	fi

	local delta_json=""
	delta_json=$(gh_issue_list --repo "$slug" --state open \
		--json number,title,state,labels,updatedAt,assignees,body \
		--search "updated:>=${last_prefetch}" \
		--limit "$PULSE_PREFETCH_ISSUE_LIMIT" 2>"$issue_err") || delta_json=""

	if [[ -z "$delta_json" || "$delta_json" == "$_PREFETCH_JSON_NULL" ]]; then
		local _delta_issue_err
		_delta_issue_err=$(cat "$issue_err" 2>/dev/null || echo "no timestamp or fetch error")
		echo "[pulse-wrapper] _prefetch_repo_issues: delta fetch failed for ${slug} (falling back to full): ${_delta_issue_err}" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="$_PREFETCH_ISSUE_SWEEP_FULL"
		return 0
	fi

	# Merge delta into cached full list
	local cached_issues
	cached_issues=$(echo "$cache_entry" | jq '.issues // []' 2>/dev/null) || cached_issues="[]"
	if echo "$cached_issues" | _prefetch_issue_cache_lacks_state; then
		echo "[pulse-wrapper] _prefetch_repo_issues: cached issue schema lacks state for ${slug} (falling back to full)" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="$_PREFETCH_ISSUE_SWEEP_FULL"
		return 0
	fi
	local merged
	merged=$(echo "$cached_issues" | jq --argjson delta "$delta_json" '
		($delta | map(.number) | map(tostring) | map({(.) : true}) | add // {}) as $delta_nums |
		[.[] | select((.number | tostring) as $n | $delta_nums[$n] | not)] +
		$delta
	' 2>/dev/null) || merged=""

	if [[ -z "$merged" || "$merged" == "null" ]]; then
		echo "[pulse-wrapper] _prefetch_repo_issues: delta merge failed for ${slug} (falling back to full)" >>"$LOGFILE"
		PREFETCH_ISSUE_SWEEP_MODE="$_PREFETCH_ISSUE_SWEEP_FULL"
		return 0
	fi

	local delta_count
	delta_count=$(echo "$delta_json" | jq 'length' 2>/dev/null) || delta_count=0
	echo "[pulse-wrapper] _prefetch_repo_issues: delta for ${slug}: ${delta_count} changed issues merged into cache" >>"$LOGFILE"
	PREFETCH_ISSUE_RESULT=$(echo "$merged" | _prefetch_open_issues_only)
	return 0
}
