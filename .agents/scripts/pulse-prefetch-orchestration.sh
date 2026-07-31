#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-prefetch-orchestration.sh — State assembly, helper fan-out, and repo schedules
# =============================================================================
# Pure-move sub-library split from pulse-prefetch-fetch.sh for GH#18400/t1987.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_PREFETCH_ORCHESTRATION_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_ORCHESTRATION_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_PREFETCH_BOOL_TRUE=true

# =============================================================================
# Parallel Wait + State Assembly (GH#5627)
# =============================================================================

#######################################
# Wait for parallel PIDs with a hard timeout (GH#5627)
#
# Poll-based approach (kill -0) instead of blocking wait — wait $pid
# blocks until the process exits, so a timeout check between waits is
# ineffective when a single wait hangs for minutes.
#
# Arguments:
#   $1 - timeout in seconds
#   $2..N - PIDs to wait for (passed as remaining args)
# Returns: 0 always (best-effort — kills stragglers on timeout)
#######################################
_wait_parallel_pids() {
	local timeout_secs="$1"
	shift
	local pids=("$@")

	local wait_elapsed=0
	local all_done=false
	while [[ "$all_done" != "$_PREFETCH_BOOL_TRUE" ]] && [[ "$wait_elapsed" -lt "$timeout_secs" ]]; do
		all_done=$_PREFETCH_BOOL_TRUE
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				all_done=false
				break
			fi
		done
		if [[ "$all_done" != "$_PREFETCH_BOOL_TRUE" ]]; then
			sleep 2
			wait_elapsed=$((wait_elapsed + 2))
		fi
	done
	if [[ "$all_done" != "$_PREFETCH_BOOL_TRUE" ]]; then
		echo "[pulse-wrapper] Parallel gh fetch timeout after ${wait_elapsed}s — killing remaining fetches" >>"$LOGFILE"
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				_kill_tree "$pid" || true
			fi
		done
		sleep 1
		# Force-kill any survivors
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				_force_kill_tree "$pid" || true
			fi
		done
	fi
	# Reap all child processes (non-blocking since they're dead or killed)
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

#######################################
# Assemble state file from parallel fetch results (GH#5627)
#
# Concatenates numbered output files from tmpdir into STATE_FILE
# with a header timestamp.
#
# Arguments:
#   $1 - tmpdir containing numbered .txt files
#######################################
_assemble_state_file() {
	local tmpdir="$1"

	{
		echo "# Pre-fetched Repo State ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
		echo ""
		echo "This state was fetched by pulse-wrapper.sh BEFORE the pulse started."
		echo "Do NOT re-fetch — act on this data directly. See pulse.md Step 2."
		echo ""
		local -a state_parts=()
		local i=0
		while [[ -f "${tmpdir}/${i}.txt" ]]; do
			state_parts+=("${tmpdir}/${i}.txt")
			i=$((i + 1))
		done
		# GH#22289: concatenate numbered state shards with one awk process
		# instead of one cat fork per shard. The common path has only a handful
		# of files, but large repo sets can produce dozens of shards and this
		# assembly runs in the pulse hot path.
		if [[ "${#state_parts[@]}" -gt 0 ]]; then
			awk '1' "${state_parts[@]}"
		fi
	} >"$STATE_FILE"
	return 0
}

#######################################
# Run a prefetch sub-command with timeout and append output to a target file.
# Encapsulates the repeated pattern: mktemp → run_cmd_with_timeout → cat → rm.
# Arguments:
#   $1 - timeout in seconds
#   $2 - target file to append output to
#   $3 - label for log messages
#   $4..N - command and arguments to run
#######################################
_run_prefetch_step() {
	local timeout="$1"
	local target_file="$2"
	local label="$3"
	shift 3

	local tmp_file
	tmp_file=$(mktemp)
	run_cmd_with_timeout "$timeout" "$@" >"$tmp_file" 2>/dev/null || {
		echo "[pulse-wrapper] ${label} timed out after ${timeout}s (non-fatal)" >>"$LOGFILE"
	}
	cat "$tmp_file" >>"$target_file"
	rm -f "$tmp_file"
	return 0
}

#######################################
# Atomically replace the dedicated triage snapshot after a complete successful
# refresh. Partial, timed-out, malformed, or symlink-target writes preserve the
# prior snapshot so deterministic review dispatch never trusts false emptiness.
#
# Arguments:
#   $1 - newline-delimited slug|path repo entries
#   $2 - target triage state file
#######################################
_write_triage_review_state() {
	local repo_entries="$1"
	local target_file="$2"
	local target_dir="${target_file%/*}"
	local triage_tmp=""
	[[ -n "$target_file" && "$target_dir" != "$target_file" ]] || return 1
	[[ -d "$target_dir" && ! -L "$target_file" ]] || return 1

	triage_tmp=$(mktemp "${target_file}.tmp.XXXXXX") || return 1
	if ! run_cmd_with_timeout 30 prefetch_triage_review_status "$repo_entries" \
		>"$triage_tmp" 2>/dev/null; then
		echo "[pulse-wrapper] prefetch_triage_review_status failed or timed out after 30s — preserving prior triage state" >>"$LOGFILE"
		rm -f "$triage_tmp"
		return 1
	fi
	if ! mv "$triage_tmp" "$target_file" 2>/dev/null; then
		rm -f "$triage_tmp"
		return 1
	fi
	return 0
}

#######################################
# Refresh the dedicated triage snapshot during a long Pulse cycle. The exported
# PULSE_SCOPE_REPOS list preserves the schedule-filtered repo scope established
# by the cycle's primary prefetch; an absent scope falls back to all enabled,
# non-local managed repos.
#######################################
refresh_triage_review_state() {
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local state_file="${STATE_FILE:-}"
	local triage_file="${TRIAGE_STATE_FILE:-}"
	local repo_entries=""
	[[ -n "$triage_file" ]] || {
		[[ -n "$state_file" ]] || return 1
		triage_file="${state_file%.txt}-triage.txt"
	}
	[[ -f "$repos_json" ]] || return 1

	repo_entries=$(jq -r --arg scope "${PULSE_SCOPE_REPOS:-}" '
		.initialized_repos[]? as $repo
		| select($repo.maintenance != false and $repo.pulse == true
			and ($repo.local_only // false) == false
			and ($repo.slug // "") != "" and ($repo.path // "") != "")
		| select($scope == "" or (($scope | split(",")) | index($repo.slug)) != null)
		| "\($repo.slug)|\($repo.path)"
	' "$repos_json" 2>/dev/null) || return 1
	[[ -n "$repo_entries" ]] || return 1
	_write_triage_review_state "$repo_entries" "$triage_file" || return 1
	echo "[pulse-wrapper] Refreshed dedicated triage state during active cycle" >>"$LOGFILE"
	return 0
}

_append_prefetch_sub_helpers() {
	local repo_entries="$1"

	# t2041: Hygiene Anomalies — reads t2040's _normalize_label_invariants
	# counter file. Zero anomalies = one line of text, so this is cheap to
	# include every cycle. Nonzero triggers investigation.
	prefetch_hygiene_anomalies >>"$STATE_FILE"

	# Append mission state (reads local files — fast)
	prefetch_missions "$repo_entries" >>"$STATE_FILE"

	# Append active worker snapshot for orphaned PR detection (t216, local ps — fast)
	prefetch_active_workers >>"$STATE_FILE"

	# Append repo hygiene data for LLM triage (t1417)
	# Total prefetch budget: 60s (parallel) + 30s + 30s + 30s = 150s max,
	# well within the 600s stage timeout.
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_hygiene" prefetch_hygiene

	# Append CI failure patterns from notification mining (GH#4480)
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_ci_failures" prefetch_ci_failures

	# Append priority-class worker allocations (t1423, reads local file — fast)
	_append_priority_allocations >>"$STATE_FILE"

	# Append adaptive queue-governor guidance (t1455, local computation — fast)
	append_adaptive_queue_governor

	# Append external contribution watch summary (t1419, local state — fast)
	prefetch_contribution_watch >>"$STATE_FILE"

	# Append failed-notification systemic summary (t3960)
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_gh_failure_notifications" prefetch_gh_failure_notifications

	# Write needs-maintainer-review triage status to a SEPARATE file (t1894).
	# This data is used only by the deterministic dispatch_triage_reviews()
	# function — it must NOT appear in the LLM's STATE_FILE. NMR issues are
	# a security gate; the LLM should never see or act on them.
	# The atomic writer preserves any previous complete snapshot on failure.
	TRIAGE_STATE_FILE="${STATE_FILE%.txt}-triage.txt"
	_write_triage_review_state "$repo_entries" "$TRIAGE_STATE_FILE" || true

	# Append status:needs-info contributor reply status
	_run_prefetch_step 30 "$STATE_FILE" "prefetch_needs_info_replies" prefetch_needs_info_replies "$repo_entries"

	# Append FOSS contribution scan results (t1702)
	_run_prefetch_step "$FOSS_SCAN_TIMEOUT" "$STATE_FILE" "prefetch_foss_scan" prefetch_foss_scan

	return 0
}

# =============================================================================
# Per-Repo Pulse Schedule Check (GH#6510)
# =============================================================================

########################################
# Check per-repo pulse schedule constraints (GH#6510)
#
# Enforces two optional repos.json fields:
#   pulse_hours: {"start": N, "end": N}  — 24h local time window
#   pulse_expires: "YYYY-MM-DD"          — ISO date after which pulse stops
#
# When pulse_expires is past today, this function atomically sets
# pulse: false in repos.json (temp file + mv) and returns 1 (skip).
# When pulse_hours is set and the current hour is outside the window,
# returns 1 (skip). Overnight windows (start > end, e.g., 17→5) are
# supported. Repos without either field always return 0 (include).
#
# Bash 3.2 compatible: no associative arrays, no bash 4+ features.
# date +%H returns zero-padded strings — strip with 10# prefix for
# arithmetic to avoid octal interpretation (e.g., 08 → 10#08 = 8).
#
# Arguments:
#   $1 - slug (owner/repo, for log messages)
#   $2 - pulse_hours_start (integer 0-23, or "" if not set)
#   $3 - pulse_hours_end   (integer 0-23, or "" if not set)
#   $4 - pulse_expires     (YYYY-MM-DD string, or "" if not set)
#   $5 - repos_json        (path to repos.json, for expiry auto-disable)
#
# Exit codes:
#   0 - repo is in schedule window (include in this pulse)
#   1 - repo is outside window or expired (skip this pulse)
########################################
########################################
# Per-repo pulse interval throttle (GH#20660)
# State file path used by check_repo_pulse_interval and update_repo_pulse_timestamp.
########################################
PULSE_LAST_PER_REPO_FILE="${PULSE_LAST_PER_REPO_FILE:-${HOME}/.aidevops/logs/pulse-last-per-repo.json}"

########################################
# Check whether a per-repo pulse_interval has elapsed since the last poll.
#
# Mirrors the shape of check_repo_pulse_schedule: returns 0 to include the
# repo this cycle, 1 to skip. Backwards compatible: when pulse_interval is
# absent the repo is always included (no throttle).
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - pulse_interval (integer seconds from repos.json, or "" if not set)
#   $3 - state_file (optional; defaults to PULSE_LAST_PER_REPO_FILE)
#
# Exit codes:
#   0 - include this repo (interval elapsed or no interval set)
#   1 - skip this repo (interval not yet elapsed)
########################################
check_repo_pulse_interval() {
	local slug="$1"
	local interval="$2"
	local state_file="${3:-$PULSE_LAST_PER_REPO_FILE}"

	# No interval set: always include (backwards compatible)
	if [[ -z "$interval" ]]; then
		return 0
	fi

	# Must be a positive integer
	if [[ ! "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -eq 0 ]]; then
		echo "[pulse-wrapper] WARNING: pulse_interval for ${slug} is not a valid positive integer (got: '${interval}') — falling back to no throttle" >>"$LOGFILE"
		return 0
	fi

	# Enforce minimum 60s
	if [[ "$interval" -lt 60 ]]; then
		echo "[pulse-wrapper] WARNING: pulse_interval for ${slug} is below minimum 60s (got: ${interval}) — clamping to 60s" >>"$LOGFILE"
		interval=60
	fi

	# Read last-polled timestamp from state file
	local last_polled=0
	if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
		local val
		val=$(jq -r --arg slug "$slug" '.last_pulsed[$slug] // 0' "$state_file" 2>/dev/null)
		[[ "$val" =~ ^[0-9]+$ ]] && last_polled="$val"
	fi

	local now=0 elapsed=0
	now=$(date +%s)
	elapsed=$((now - last_polled))

	if [[ "$elapsed" -lt "$interval" ]]; then
		echo "[pulse-wrapper] pulse_interval_skip repo=${slug} interval=${interval}s elapsed=${elapsed}s last_polled=${last_polled}" >>"$LOGFILE"
		return 1
	fi

	return 0
}

########################################
# Write the current epoch timestamp as the last-polled time for a repo.
#
# Uses atomic mktemp+mv so concurrent pulse runners cannot produce a torn
# read. Last-writer-wins is acceptable since timestamps are monotone.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - state_file (optional; defaults to PULSE_LAST_PER_REPO_FILE)
#
# Returns: 0 always (non-fatal; failures are logged and silently ignored)
########################################
update_repo_pulse_timestamp() {
	local slug="$1"
	local state_file="${2:-$PULSE_LAST_PER_REPO_FILE}"

	command -v jq &>/dev/null || return 0

	local now
	now=$(date +%s)

	# Read existing state or start with an empty object
	local existing='{}'
	if [[ -f "$state_file" ]]; then
		existing=$(jq '.' "$state_file" 2>/dev/null) || existing='{}'
		[[ -n "$existing" ]] || existing='{}'
	fi

	# Ensure the logs directory exists
	local state_dir
	state_dir="${state_file%/*}"
	[[ -d "$state_dir" ]] || mkdir -p "$state_dir" 2>/dev/null || true

	local tmp_state
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	tmp_state=$(mktemp "${state_dir}/.pulse-last-per-repo-XXXXXX") || {
		echo "[pulse-wrapper] update_repo_pulse_timestamp: mktemp failed for ${slug} — skipping write" >>"$LOGFILE"
		return 0
	}

	if printf '%s' "$existing" | jq --arg slug "$slug" --argjson ts "$now" '
		if .last_pulsed then .last_pulsed[$slug] = $ts
		else .last_pulsed = {($slug): $ts} end
	' >"$tmp_state" 2>/dev/null && jq empty "$tmp_state" 2>/dev/null; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
		echo "[pulse-wrapper] WARNING: update_repo_pulse_timestamp: jq produced invalid JSON for ${slug} — aborting write" >>"$LOGFILE"
	fi
	return 0
}

check_repo_pulse_schedule() {
	local slug="$1"
	local ph_start="$2"
	local ph_end="$3"
	local expires="$4"
	local repos_json="$5"

	# --- pulse_expires check ---
	if [[ -n "$expires" ]]; then
		local today_date
		today_date=$(date +%Y-%m-%d)
		# String comparison works for ISO dates (lexicographic == chronological)
		if [[ "$today_date" > "$expires" ]]; then
			echo "[pulse-wrapper] pulse_expires reached for ${slug} (expires=${expires}, today=${today_date}) — auto-disabling pulse" >>"$LOGFILE"
			# Atomic write: temp file + mv (POSIX-guaranteed atomic on local fs)
			# Last-writer-wins is acceptable since expiry is idempotent.
			if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
				local tmp_json
				tmp_json=$(mktemp)
				if jq --arg slug "$slug" '
					.initialized_repos |= map(
						if .slug == $slug then .pulse = false else . end
					)
				' "$repos_json" >"$tmp_json" 2>/dev/null && jq empty "$tmp_json" 2>/dev/null; then
					mv "$tmp_json" "$repos_json"
					echo "[pulse-wrapper] Set pulse:false for ${slug} in repos.json (expiry auto-disable)" >>"$LOGFILE"
				else
					rm -f "$tmp_json"
					echo "[pulse-wrapper] WARNING: jq produced invalid JSON for ${slug} expiry — aborting write (GH#16746)" >>"$LOGFILE"
				fi
			fi
			return 1
		fi
	fi

	# --- pulse_hours check ---
	if [[ -n "$ph_start" && -n "$ph_end" ]]; then
		# Strip leading zeros before arithmetic to avoid octal interpretation
		# (bash treats 08/09 as invalid octal without the 10# prefix)
		local current_hour
		current_hour=$(date +%H)
		local cur=0 ph_s=0 ph_e=0
		cur=$((10#${current_hour}))
		ph_s=$((10#${ph_start}))
		ph_e=$((10#${ph_end}))

		local in_window=false
		if [[ "$ph_s" -le "$ph_e" ]]; then
			# Normal window (e.g., 9→17): in window when cur >= start AND cur < end
			if [[ "$cur" -ge "$ph_s" && "$cur" -lt "$ph_e" ]]; then
				in_window=$_PREFETCH_BOOL_TRUE
			fi
		else
			# Overnight window (e.g., 17→5): in window when cur >= start OR cur < end
			if [[ "$cur" -ge "$ph_s" || "$cur" -lt "$ph_e" ]]; then
				in_window=$_PREFETCH_BOOL_TRUE
			fi
		fi

		if [[ "$in_window" != "$_PREFETCH_BOOL_TRUE" ]]; then
			echo "[pulse-wrapper] pulse_hours window ${ph_s}→${ph_e} not active for ${slug} (current hour: ${cur}) — skipping" >>"$LOGFILE"
			return 1
		fi
	fi

	return 0
}

# =============================================================================
# Per-Repo Activity Tier Skip (t2831)
# =============================================================================
# Controls how often each repo is evaluated based on its activity tier.
# Hot repos: check every cycle (PULSE_TIER_HOT_INTERVAL=0, no skip).
# Warm repos: skip if last full check < PULSE_TIER_WARM_INTERVAL seconds ago.
# Cold repos: skip if last full check < PULSE_TIER_COLD_INTERVAL seconds ago.
#
# Tier assignment is performed hourly by pulse-repo-tier-classifier-routine.sh
# and cached at ~/.aidevops/cache/pulse-repo-tiers.json.
# The tier-of command reads from the cache and falls back to "warm" on miss.
#
# State file: PULSE_TIER_LAST_CHECK_FILE (separate from PULSE_LAST_PER_REPO_FILE
# so tier-based throttle is independent of repos.json pulse_interval).
# =============================================================================

########################################
# State file for per-repo tier-based last-check timestamps.
########################################
PULSE_TIER_LAST_CHECK_FILE="${PULSE_TIER_LAST_CHECK_FILE:-${HOME}/.aidevops/logs/pulse-tier-last-check.json}"

########################################
# Tier classifier script path.
########################################
PULSE_TIER_SCRIPT="${PULSE_TIER_SCRIPT:-${SCRIPT_DIR}/pulse-repo-tier.sh}"

########################################
# Check whether a repo should be skipped this cycle based on its activity tier.
#
# Reads the tier via pulse-repo-tier.sh tier-of (cache-backed, < 1ms typical).
# Compares elapsed time since last full prefetch against the tier interval.
#
# Hot:  PULSE_TIER_HOT_INTERVAL=0 — never skip (every cycle)
# Warm: skip if elapsed < PULSE_TIER_WARM_INTERVAL (default 180s)
# Cold: skip if elapsed < PULSE_TIER_COLD_INTERVAL (default 600s)
#
# Feature-flag: returns 0 (proceed) immediately when
# PULSE_TIER_CLASSIFICATION_ENABLED is unset or 0.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - state_file (optional; defaults to PULSE_TIER_LAST_CHECK_FILE)
#
# Exit codes:
#   0 - proceed with this repo (not skipped)
#   1 - skip this repo (tier interval not elapsed)
########################################
check_repo_tier_skip() {
	local slug="$1"
	local state_file="${2:-$PULSE_TIER_LAST_CHECK_FILE}"

	# Feature flag — enabled by default (set to 0 to disable for rollback)
	if [[ "${PULSE_TIER_CLASSIFICATION_ENABLED:-1}" != "1" ]]; then
		return 0
	fi

	local warm_interval="${PULSE_TIER_WARM_INTERVAL:-180}"
	local cold_interval="${PULSE_TIER_COLD_INTERVAL:-600}"

	# Get tier from cache (fast — reads local JSON file); default to warm on error.
	local tier
	tier="warm"
	if [[ -x "$PULSE_TIER_SCRIPT" ]]; then
		local _t
		_t=$("$PULSE_TIER_SCRIPT" tier-of "$slug" 2>/dev/null) || true
		# Accept only known tier values; anything else stays at the default.
		case "$_t" in hot|warm|cold) tier="$_t" ;; esac
	fi

	# Hot repos always proceed (no skip)
	if [[ "$tier" == "hot" ]]; then
		return 0
	fi

	# Determine minimum interval for this tier
	local min_interval=0
	case "$tier" in
		warm) min_interval="$warm_interval" ;;
		cold) min_interval="$cold_interval" ;;
		*)    return 0 ;;
	esac

	if [[ "$min_interval" -le 0 ]]; then
		return 0
	fi

	# Read last full prefetch epoch from state file
	local last_check=0
	if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
		local val
		val=$(jq -r --arg slug "$slug" '.last_check[$slug] // 0' "$state_file" 2>/dev/null)
		[[ "$val" =~ ^[0-9]+$ ]] && last_check="$val"
	fi

	local now=0 elapsed=0
	now=$(date +%s)
	elapsed=$((now - last_check))

	if [[ "$elapsed" -lt "$min_interval" ]]; then
		echo "[pulse-wrapper] tier_skip repo=${slug} tier=${tier} interval=${min_interval}s elapsed=${elapsed}s" >>"$LOGFILE"
		return 1
	fi

	return 0
}

########################################
# Record the current epoch as the last full prefetch time for a repo (tier tracking).
# Uses atomic mktemp+mv pattern (same as update_repo_pulse_timestamp).
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - state_file (optional; defaults to PULSE_TIER_LAST_CHECK_FILE)
#
# Returns: 0 always (non-fatal)
########################################
update_repo_tier_check_timestamp() {
	local slug="$1"
	local state_file="${2:-$PULSE_TIER_LAST_CHECK_FILE}"

	command -v jq &>/dev/null || return 0

	local now
	now=$(date +%s)

	local existing='{}'
	if [[ -f "$state_file" ]]; then
		existing=$(jq '.' "$state_file" 2>/dev/null) || existing='{}'
		[[ -n "$existing" ]] || existing='{}'
	fi

	local state_dir
	state_dir="${state_file%/*}"
	[[ -d "$state_dir" ]] || mkdir -p "$state_dir" 2>/dev/null || true

	local tmp_state
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp. This was the
	# canonical 142-spam-lines/day offender in pulse-wrapper.log (GH#21408).
	tmp_state=$(mktemp "${state_dir}/.pulse-tier-last-check-XXXXXX") || {
		echo "[pulse-wrapper] update_repo_tier_check_timestamp: mktemp failed for ${slug}" >>"$LOGFILE"
		return 0
	}

	if printf '%s' "$existing" | jq --arg slug "$slug" --argjson ts "$now" '
		if .last_check then .last_check[$slug] = $ts
		else .last_check = {($slug): $ts} end
	' >"$tmp_state" 2>/dev/null && jq empty "$tmp_state" 2>/dev/null; then
		mv "$tmp_state" "$state_file"
	else
		rm -f "$tmp_state"
		echo "[pulse-wrapper] WARNING: update_repo_tier_check_timestamp: jq produced invalid JSON for ${slug}" >>"$LOGFILE"
	fi
	return 0
}
