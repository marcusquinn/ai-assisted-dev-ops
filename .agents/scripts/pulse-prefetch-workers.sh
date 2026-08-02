#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-prefetch-workers.sh — Top-level prefetch worker functions
# =============================================================================
# Pure-move sub-library split from pulse-prefetch.sh for GH#18400/t1987.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_PREFETCH_WORKERS_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_WORKERS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_PREFETCH_BOOL_FALSE=false
_PREFETCH_BOOL_TRUE=true

_prefetch_batch_refresh() {
	local _batch_helper="${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
	if [[ "${PULSE_BATCH_PREFETCH_ENABLED:-1}" != "1" || ! -x "$_batch_helper" ]]; then
		return 0
	fi
	local _batch_output
	_batch_output=$("$_batch_helper" refresh 2>/dev/null) || true
	# Parse counters for health instrumentation (t2830: also parses tickle counters)
	local _batch_search_calls=0 _batch_cache_writes=0
	local _tickle_fresh=0 _tickle_stale=0
	local _conditional_304=0 _conditional_refreshes=0 _conditional_misses=0
	if [[ -n "$_batch_output" ]]; then
		local _line
		while IFS= read -r _line; do
			case "$_line" in
			search_calls=*)         _batch_search_calls="${_line#search_calls=}" ;;
			cache_writes=*)         _batch_cache_writes="${_line#cache_writes=}" ;;
			events_tickle_fresh=*)  _tickle_fresh="${_line#events_tickle_fresh=}" ;;
			events_tickle_stale=*)  _tickle_stale="${_line#events_tickle_stale=}" ;;
			conditional_304=*)      _conditional_304="${_line#conditional_304=}" ;;
			conditional_refreshes=*) _conditional_refreshes="${_line#conditional_refreshes=}" ;;
			conditional_misses=*)   _conditional_misses="${_line#conditional_misses=}" ;;
			esac
		done <<<"$_batch_output"
	fi
	_PULSE_HEALTH_BATCH_SEARCH_CALLS=$((${_PULSE_HEALTH_BATCH_SEARCH_CALLS:-0} + _batch_search_calls))
	_PULSE_HEALTH_BATCH_CACHE_HITS=$((${_PULSE_HEALTH_BATCH_CACHE_HITS:-0} + _batch_cache_writes))
	_PULSE_HEALTH_EVENTS_TICKLE_FRESH=$((${_PULSE_HEALTH_EVENTS_TICKLE_FRESH:-0} + _tickle_fresh))
	_PULSE_HEALTH_EVENTS_TICKLE_STALE=$((${_PULSE_HEALTH_EVENTS_TICKLE_STALE:-0} + _tickle_stale))
	_PULSE_HEALTH_CONDITIONAL_304=$((${_PULSE_HEALTH_CONDITIONAL_304:-0} + _conditional_304))
	_PULSE_HEALTH_CONDITIONAL_REFRESHES=$((${_PULSE_HEALTH_CONDITIONAL_REFRESHES:-0} + _conditional_refreshes))
	_PULSE_HEALTH_CONDITIONAL_MISSES=$((${_PULSE_HEALTH_CONDITIONAL_MISSES:-0} + _conditional_misses))
	echo "[pulse-wrapper] Batch prefetch: search_calls=${_batch_search_calls} cache_writes=${_batch_cache_writes} tickle_fresh=${_tickle_fresh} tickle_stale=${_tickle_stale} conditional_304=${_conditional_304} conditional_refreshes=${_conditional_refreshes} conditional_misses=${_conditional_misses}" >>"$LOGFILE"

	# t3027 (GH#21584): Bridge counters across run_stage_with_timeout subshell.
	# prefetch_state runs inside a subshell created by run_stage_with_timeout
	# in _run_preflight_stages, so updates to _PULSE_HEALTH_* shell vars die
	# when the subshell exits. The pulse-wrapper.sh deterministic pipeline
	# reads this temp file after the subshell returns and accumulates the
	# counters into the cycle-scoped totals. Pattern mirrors the merge
	# counter bridge at pulse-wrapper.sh:996-1008 (GH#18571).
	#
	# Format: single line of 7 space-separated integers in fixed positional
	# order: search_calls cache_hits tickle_fresh tickle_stale conditional_304 conditional_refreshes conditional_misses. Cumulative
	# within this prefetch_state invocation (we accumulate here rather than
	# requiring the reader to sum across multiple files). The reader
	# `read -r` parses positionally — DO NOT change column order without
	# updating pulse-wrapper.sh::_pulse_drain_prefetch_counters.
	local _pf_counters_file="${TMPDIR:-/tmp}/pulse-health-prefetch-$$.tmp"
	printf '%d %d %d %d %d %d %d\n' \
		"$_PULSE_HEALTH_BATCH_SEARCH_CALLS" \
		"$_PULSE_HEALTH_BATCH_CACHE_HITS" \
		"$_PULSE_HEALTH_EVENTS_TICKLE_FRESH" \
		"$_PULSE_HEALTH_EVENTS_TICKLE_STALE" \
		"$_PULSE_HEALTH_CONDITIONAL_304" \
		"$_PULSE_HEALTH_CONDITIONAL_REFRESHES" \
		"$_PULSE_HEALTH_CONDITIONAL_MISSES" \
		>"$_pf_counters_file" 2>/dev/null || true
	return 0
}

prefetch_missions() {
	local repo_entries="$1"
	local found_any=$_PREFETCH_BOOL_FALSE

	# Collect mission files from repo-attached locations
	local mission_files=()
	while IFS='|' read -r slug path; do
		local missions_dir="${path}/todo/missions"
		if [[ -d "$missions_dir" ]]; then
			while IFS= read -r mfile; do
				[[ -n "$mfile" ]] && mission_files+=("${slug}|${path}|${mfile}")
			done < <(find "$missions_dir" -name "mission.md" -type f 2>/dev/null || true)
		fi
	done <<<"$repo_entries"

	# Also check homeless missions
	local homeless_dir="${HOME}/.aidevops/missions"
	if [[ -d "$homeless_dir" ]]; then
		while IFS= read -r mfile; do
			[[ -n "$mfile" ]] && mission_files+=("|homeless|${mfile}")
		done < <(find "$homeless_dir" -name "mission.md" -type f 2>/dev/null || true)
	fi

	if [[ ${#mission_files[@]} -eq 0 ]]; then
		return 0
	fi

	local active_count=0

	for entry in "${mission_files[@]}"; do
		local slug="" path="" mfile=""
		IFS='|' read -r slug path mfile <<<"$entry"

		# Extract frontmatter status — look for status: in YAML frontmatter
		local status
		status=$(_extract_frontmatter_field "$mfile" "status")

		# Only include active/paused/blocked/validating missions
		case "$status" in
		active | paused | blocked | validating) ;;
		*) continue ;;
		esac

		if [[ "$found_any" == "$_PREFETCH_BOOL_FALSE" ]]; then
			echo ""
			echo "# Active Missions"
			echo ""
			echo "Mission state files detected by pulse-wrapper.sh. See pulse.md Step 3.5."
			echo ""
			found_any=$_PREFETCH_BOOL_TRUE
		fi

		local mission_id
		mission_id=$(_extract_frontmatter_field "$mfile" "id")
		local title
		title=$(_extract_frontmatter_field "$mfile" "title")
		local mode
		mode=$(_extract_frontmatter_field "$mfile" "mode")
		local mission_dir
		mission_dir=$(dirname "$mfile")

		echo "## Mission: ${mission_id} — ${title}"
		echo ""
		echo "- **Status:** ${status}"
		echo "- **Mode:** ${mode}"
		echo "- **Repo:** ${slug:-homeless}"
		echo "- **Path:** ${mfile}"
		echo ""

		# Extract milestone summaries — find lines matching "### Milestone N:"
		# and their status lines
		_extract_milestone_summary "$mfile"

		echo ""
		active_count=$((active_count + 1))
	done

	if [[ "$active_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Found $active_count active mission(s)" >>"$LOGFILE"
	fi
	return 0
}

prefetch_foss_scan() {
	local helper="${SCRIPT_DIR}/foss-contribution-helper.sh"
	if [[ ! -f "$helper" ]]; then
		return 0
	fi

	# Quick check: is FOSS globally enabled? Skip the scan entirely if not.
	local foss_enabled="$_PREFETCH_BOOL_FALSE"
	local config_jsonc="${HOME}/.config/aidevops/config.jsonc"
	if [[ -f "$config_jsonc" ]] && command -v jq &>/dev/null; then
		foss_enabled=$(sed 's|//.*||g; s|/\*.*\*/||g' "$config_jsonc" 2>/dev/null |
			jq -r '.foss.enabled // "false"' 2>/dev/null) || foss_enabled="$_PREFETCH_BOOL_FALSE"
	fi
	if [[ "$foss_enabled" != "true" ]]; then
		return 0
	fi

	# Check if any foss:true repos exist in repos.json
	local foss_repo_count=0
	local repos_json_path="${REPOS_JSON:-}"
	if [[ -n "$repos_json_path" && -f "$repos_json_path" ]] && command -v jq &>/dev/null; then
		foss_repo_count=$(jq '[.initialized_repos[] | select(.maintenance != false and (.local_only // false) == false and .foss == true)] | length' "$repos_json_path" || echo 0)
	fi
	if [[ "${foss_repo_count:-0}" -eq 0 ]]; then
		return 0
	fi

	local scan_output
	scan_output=$(bash "$helper" scan --dry-run 2>/dev/null) || scan_output=""

	if [[ -z "$scan_output" ]]; then
		return 0
	fi

	# Extract eligible and skipped counts from the summary line
	local eligible_count=0
	local skipped_count=0
	if [[ "$scan_output" =~ ([0-9]+)\ eligible ]]; then
		eligible_count="${BASH_REMATCH[1]}"
	fi
	if [[ "$scan_output" =~ ([0-9]+)\ skipped ]]; then
		skipped_count="${BASH_REMATCH[1]}"
	fi

	# Get budget info
	local budget_output
	budget_output=$(bash "$helper" budget 2>/dev/null) || budget_output=""
	local daily_used=0
	local daily_max=200000
	local daily_remaining=0
	local foss_max_dispatch_per_cycle="${FOSS_MAX_DISPATCH_PER_CYCLE:-2}"
	if [[ "$budget_output" =~ Used\ today:\ +([0-9]+) ]]; then
		daily_used="${BASH_REMATCH[1]}"
	fi
	if [[ "$budget_output" =~ Max\ daily\ tokens:\ +([0-9]+) ]]; then
		daily_max="${BASH_REMATCH[1]}"
	fi
	daily_remaining=$((daily_max - daily_used))
	if [[ "$daily_remaining" -lt 0 ]]; then
		daily_remaining=0
	fi

	# Extract per-repo eligible details (lines matching ELIGIBLE)
	local eligible_details
	eligible_details=$(echo "$scan_output" | grep -i 'ELIGIBLE' | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^[[:space:]]*/  - /' || true)

	{
		echo ""
		echo "# FOSS Contribution Scan (t1702)"
		echo ""
		echo "FOSS contributions are **enabled**. Scan results from \`foss-contribution-helper.sh scan --dry-run\`."
		echo ""
		echo "- Eligible repos: **${eligible_count}**"
		echo "- Skipped repos: ${skipped_count} (blocklisted, budget exceeded, or rate limited)"
		echo "- Daily token budget: ${daily_used}/${daily_max} used (${daily_remaining} remaining)"
		echo "- Max FOSS dispatches per cycle: ${foss_max_dispatch_per_cycle}"
		echo ""
		if [[ -n "$eligible_details" && "$eligible_count" -gt 0 ]]; then
			echo "### Eligible FOSS Repos"
			echo ""
			echo "$eligible_details"
			echo ""
		fi
		echo "**Dispatch rule:** When idle worker capacity exists (all managed repo issues dispatched"
		echo "and worker slots remain), dispatch contribution workers for eligible FOSS repos."
		echo "Max ${foss_max_dispatch_per_cycle} FOSS dispatches per pulse cycle. Use \`foss-contribution-helper.sh check <slug>\`"
		echo "before each dispatch. Record token usage after completion with \`foss-contribution-helper.sh record <slug> <tokens>\`."
		echo ""
	}

	echo "[pulse-wrapper] FOSS scan: ${eligible_count} eligible, ${skipped_count} skipped, budget ${daily_used}/${daily_max}" >>"$LOGFILE"
	return 0
}

_prefetch_triage_nmr_json() {
	local slug="$1"
	local nmr_json="" nmr_err="" nmr_read_ok=$_PREFETCH_BOOL_TRUE
	local nmr_err_msg=""
	nmr_err=$(mktemp) || return 1
	if ! nmr_json=$(gh_issue_list --repo "$slug" --label "needs-maintainer-review" \
		--state open --json number,title,author,createdAt,updatedAt,labels \
		--limit 50 2>"$nmr_err"); then
		nmr_read_ok=$_PREFETCH_BOOL_FALSE
	fi
	if [[ -z "$nmr_json" || "$nmr_json" == "null" ]] || \
		! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$nmr_json"; then
		nmr_read_ok=$_PREFETCH_BOOL_FALSE
	fi
	if [[ "$nmr_read_ok" != "$_PREFETCH_BOOL_TRUE" ]]; then
		nmr_err_msg=$(<"$nmr_err")
		[[ -n "$nmr_err_msg" ]] || nmr_err_msg="unknown error"
		if _pulse_gh_err_is_rate_limit "$nmr_err"; then
			_pulse_mark_rate_limited "prefetch_triage_review_status:${slug}"
		fi
		echo "[pulse-wrapper] prefetch_triage_review_status: gh_issue_list FAILED for ${slug}: ${nmr_err_msg}" >>"$LOGFILE"
		rm -f "$nmr_err"
		return 1
	fi
	# Persistent monitoring/tracking issues are unconditional non-task blockers;
	# NMR review and triage-failure state are inapplicable to them.
	if ! nmr_json=$(printf '%s' "$nmr_json" | jq -c \
		'[.[] | select((((.labels // []) | map(.name) | index("persistent")) == null))]'); then
		echo "[pulse-wrapper] prefetch_triage_review_status: failed to filter persistent issues for ${slug}" >>"$LOGFILE"
		rm -f "$nmr_err"
		return 1
	fi
	rm -f "$nmr_err"
	printf '%s\n' "$nmr_json"
	return 0
}

prefetch_triage_review_status() {
	local repo_entries="$1"
	local found_any=$_PREFETCH_BOOL_FALSE
	local total_pending=0
	local refresh_failed=$_PREFETCH_BOOL_FALSE

	while IFS='|' read -r slug path; do
		[[ -n "$slug" ]] || continue

		# GH#18984 (t2098): skip repos with 0 cached NMR issues
		if _prefetch_cached_label_count_is_zero "$slug" "needs-maintainer-review"; then
			echo "[pulse-wrapper] prefetch_triage_review_status: SKIP ${slug} — 0 NMR issues in cache" >>"$LOGFILE"
			continue
		fi

		# A failed or malformed read invalidates the complete snapshot so callers
		# preserve the prior atomic state instead of trusting false emptiness.
		local nmr_json=""
		if ! nmr_json=$(_prefetch_triage_nmr_json "$slug"); then
			refresh_failed=$_PREFETCH_BOOL_TRUE
			continue
		fi

		local nmr_count
		nmr_count=$(echo "$nmr_json" | jq 'length')
		[[ "$nmr_count" -gt 0 ]] || continue

		if [[ "$found_any" == "$_PREFETCH_BOOL_FALSE" ]]; then
			echo ""
			echo "# Needs Maintainer Review — Triage Status"
			echo ""
			echo "Issues with \`needs-maintainer-review\` label and their automated triage review status."
			echo "Dispatch a thinking-tier \`/review-issue-pr\` worker for items marked **needs-review**."
			echo "Max ${PULSE_TRIAGE_BUDGET_PER_CYCLE:-2} triage review dispatches per pulse cycle."
			echo ""
			found_any=$_PREFETCH_BOOL_TRUE
		fi

		echo "## ${slug}"
		echo ""

		# Check each issue for an existing agent review comment
		local i=0
		while [[ "$i" -lt "$nmr_count" ]]; do
			local number="" title="" author="" created_at=""
			number=$(echo "$nmr_json" | jq -r ".[$i].number")
			title=$(echo "$nmr_json" | jq -r ".[$i].title" | tr '\r\n' '  ')
			author=$(echo "$nmr_json" | jq -r ".[$i].author.login // \"unknown\"")
			[[ "$author" =~ ^[A-Za-z0-9-]+$ ]] || author="unknown"
			created_at=$(echo "$nmr_json" | jq -r ".[$i].createdAt")

			# Check for agent review comment (contains "## Review:" or "## Issue/PR Review:")
			# Use --paginate to handle issues with many comments (default page size is 30).
			# On API failure, mark as "unknown" rather than falsely reporting "needs-review".
			local review_response=""
			local review_exists=0
			local api_ok=true
			review_response=$(gh api "repos/${slug}/issues/${number}/comments" --paginate \
				--jq '[.[] | select(.body | test("## (Issue/PR )?Review:"))] | length' 2>/dev/null) || api_ok=false

			if [[ "$api_ok" == true ]]; then
				review_exists="$review_response"
				[[ "$review_exists" =~ ^[0-9]+$ ]] || review_exists=0
			fi

			local status_label
			if [[ "$api_ok" != true ]]; then
				status_label="unknown"
				refresh_failed=$_PREFETCH_BOOL_TRUE
				echo "[pulse-wrapper] API error checking review status for ${slug}#${number}" >>"$LOGFILE"
			elif [[ "$review_exists" -gt 0 ]]; then
				status_label="reviewed"
			else
				status_label="needs-review"
				total_pending=$((total_pending + 1))
			fi

			echo "- Issue #${number}: ${title} [status: **${status_label}**] [created: ${created_at}] [author: @${author}]"

			i=$((i + 1))
		done

		echo ""
	done <<<"$repo_entries"

	if [[ "$found_any" == "$_PREFETCH_BOOL_TRUE" ]]; then
		echo "**Total pending triage reviews: ${total_pending}**"
		echo ""
		echo "[pulse-wrapper] Triage review status: ${total_pending} issues pending review" >>"$LOGFILE"
	fi

	[[ "$refresh_failed" != "$_PREFETCH_BOOL_TRUE" ]] || return 1
	return 0
}
