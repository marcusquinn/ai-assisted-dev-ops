#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-repo-tier.sh — Per-repo activity tier classifier (t2831)
# =============================================================================
# Classifies pulse-enabled repos into activity tiers (hot/warm/cold) based on
# rolling 7-day GitHub event count and open PR presence. The tier controls how
# often each repo is evaluated by the prefetch stage — hot repos are checked
# every cycle, warm every ~3 cycles, cold every ~10 cycles.
#
# Commands:
#   classify   — classify all pulse-enabled repos and write to cache
#   tier-of <slug>  — return cached tier for one repo (warm on cache miss)
#
# Cache:
#   ~/.aidevops/cache/pulse-repo-tiers.json
#   Schema: { "<slug>": { "tier": "hot|warm|cold", "event_count": N, "ts": epoch } }
#
# Called by:
#   pulse-repo-tier-classifier-routine.sh (hourly via launchd)
#   pulse-prefetch-fetch.sh (tier-of, per cycle, per repo)
#
# Tier thresholds (overridable via env):
#   hot:  >= PULSE_TIER_HOT_EVENT_THRESHOLD (default 30) events in 7 days
#         OR has an open PR with status:in-progress label
#   warm: >= PULSE_TIER_WARM_EVENT_THRESHOLD (default 5) events in 7 days
#   cold: < PULSE_TIER_WARM_EVENT_THRESHOLD events
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# PATH normalisation for launchd/cron environments.
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

# SCRIPT_DIR resolution — uses BASH_SOURCE[0]:-$0 for zsh portability.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# =============================================================================
# Shared constants (sourced for color vars, safe_grep_count, etc.)
# =============================================================================
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# =============================================================================
# Tier name constants (avoid repeated literal violations in linter)
# =============================================================================
_TIER_HOT="hot"
_TIER_WARM="warm"
_TIER_COLD="cold"

# =============================================================================
# Configuration (env-overridable, consistent with pulse-wrapper-config.sh)
# =============================================================================
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
PULSE_TIER_CACHE_FILE="${PULSE_TIER_CACHE_FILE:-${HOME}/.aidevops/cache/pulse-repo-tiers.json}"
PULSE_TIER_CACHE_MAX_AGE_S="${PULSE_TIER_CACHE_MAX_AGE_S:-7200}"   # 2h stale threshold for tier-of fallback
PULSE_TIER_HOT_EVENT_THRESHOLD="${PULSE_TIER_HOT_EVENT_THRESHOLD:-30}"   # >= N events in 7d → hot
PULSE_TIER_WARM_EVENT_THRESHOLD="${PULSE_TIER_WARM_EVENT_THRESHOLD:-5}"  # >= N events in 7d → warm; <N → cold
PULSE_TIER_LOOKBACK_DAYS="${PULSE_TIER_LOOKBACK_DAYS:-7}"
PULSE_TIER_EVENTS_PER_PAGE="${PULSE_TIER_EVENTS_PER_PAGE:-100}"
PULSE_TIER_MAX_PAGES="${PULSE_TIER_MAX_PAGES:-3}"  # Max pagination pages per repo (~300 events max)

# LOGFILE for log messages (use pulse.log when available, else /dev/null)
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

# =============================================================================
# Internal helpers
# =============================================================================

#######################################
# Ensure cache directory exists.
#######################################
_tier_ensure_cache_dir() {
	local cache_dir
	cache_dir="$(dirname "${PULSE_TIER_CACHE_FILE}")"
	[[ -d "$cache_dir" ]] || mkdir -p "$cache_dir" 2>/dev/null || true
	return 0
}

#######################################
# Count GitHub events for a repo in the last N days.
# Uses REST events API (no GraphQL — avoids expensive rate-limit quota).
# Paginates up to PULSE_TIER_MAX_PAGES pages.
#
# Arguments:
#   $1 - slug (owner/repo)
#   $2 - lookback_days (integer)
#
# Outputs: integer count to stdout
# Returns: 0 always (safe default = 0 on API failure)
#######################################
_tier_count_events() {
	local slug="$1"
	local lookback_days="$2"

	local cutoff_epoch
	cutoff_epoch=$(date -v -"${lookback_days}"d +%s 2>/dev/null) || \
		cutoff_epoch=$(date -d "${lookback_days} days ago" +%s 2>/dev/null) || \
		cutoff_epoch=0

	local total=0
	local page=1
	local done_paging=false

	while [[ "$done_paging" != "true" ]] && [[ "$page" -le "$PULSE_TIER_MAX_PAGES" ]]; do
		local events_json
		events_json=$(gh api "/repos/${slug}/events?per_page=${PULSE_TIER_EVENTS_PER_PAGE}&page=${page}" \
			--jq '[.[] | select(.created_at != null) | {ts: (.created_at | split("T")[0])}]' \
			2>/dev/null) || events_json="[]"

		# Empty page → done
		local page_count
		page_count=$(printf '%s' "$events_json" | jq 'length' 2>/dev/null) || page_count=0
		[[ "$page_count" =~ ^[0-9]+$ ]] || page_count=0
		if [[ "$page_count" -eq 0 ]]; then
			done_paging=true
			break
		fi

		# Check each event: count those within cutoff; if we hit one outside, stop paging
		local in_window
		in_window=$(printf '%s' "$events_json" | jq --argjson cutoff "$cutoff_epoch" \
			'[.[] | select((.ts | strptime("%Y-%m-%d") | mktime) >= $cutoff)] | length' \
			2>/dev/null) || in_window=0
		[[ "$in_window" =~ ^[0-9]+$ ]] || in_window=0

		total=$((total + in_window))

		# If fewer events within window than page size, remaining pages have older events
		if [[ "$in_window" -lt "$page_count" ]]; then
			done_paging=true
		fi

		page=$((page + 1))
	done

	echo "$total"
	return 0
}

#######################################
# Check if a repo has any open PR with status:in-progress label.
# Uses REST search (not GraphQL) to stay within rate limits.
#
# Arguments:
#   $1 - slug (owner/repo)
#
# Returns: 0 if found, 1 if not
#######################################
_tier_has_inprogress_pr() {
	local slug="$1"

	local result
	result=$(gh search prs --repo "$slug" --state open --label "status:in-progress" \
		--limit 1 --json number 2>/dev/null) || result="[]"

	local count
	count=$(printf '%s' "$result" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$count" -gt 0 ]] && return 0
	return 1
}

#######################################
# Classify a single repo into hot/warm/cold.
#
# Arguments:
#   $1 - slug (owner/repo)
#
# Outputs: "hot", "warm", or "cold" to stdout
# Returns: 0 always
#######################################
_tier_classify_one() {
	local slug="$1"

	local event_count
	event_count=$(_tier_count_events "$slug" "$PULSE_TIER_LOOKBACK_DAYS")
	[[ "$event_count" =~ ^[0-9]+$ ]] || event_count=0

	local tier="$_TIER_COLD"
	if [[ "$event_count" -ge "$PULSE_TIER_HOT_EVENT_THRESHOLD" ]]; then
		tier="$_TIER_HOT"
	elif [[ "$event_count" -ge "$PULSE_TIER_WARM_EVENT_THRESHOLD" ]]; then
		tier="$_TIER_WARM"
	else
		# Cold by event count, but promote to hot if has in-progress PR
		if _tier_has_inprogress_pr "$slug" 2>/dev/null; then
			tier="$_TIER_HOT"
		fi
	fi

	# Also promote warm to hot if has in-progress PR
	if [[ "$tier" == "$_TIER_WARM" ]] && _tier_has_inprogress_pr "$slug" 2>/dev/null; then
		tier="$_TIER_HOT"
	fi

	echo "$tier"
	return 0
}

#######################################
# Write a single slug's tier entry atomically to the cache file.
# Uses jq to merge into the existing JSON object (atomic mktemp+mv).
#
# Arguments:
#   $1 - slug
#   $2 - tier (hot|warm|cold)
#   $3 - event_count (integer)
#######################################
_tier_cache_write_one() {
	local slug="$1"
	local tier="$2"
	local event_count="$3"

	local now_epoch
	now_epoch=$(date +%s)

	local cache_dir
	cache_dir="$(dirname "${PULSE_TIER_CACHE_FILE}")"

	local existing='{}'
	if [[ -f "$PULSE_TIER_CACHE_FILE" ]]; then
		existing=$(jq '.' "$PULSE_TIER_CACHE_FILE" 2>/dev/null) || existing='{}'
		[[ -n "$existing" ]] || existing='{}'
	fi

	local tmp_cache
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	tmp_cache=$(mktemp "${cache_dir}/.pulse-repo-tiers-XXXXXX") || return 0

	if printf '%s' "$existing" | jq \
		--arg slug "$slug" \
		--arg tier "$tier" \
		--argjson event_count "$event_count" \
		--argjson ts "$now_epoch" \
		'.[$slug] = {tier: $tier, event_count: $event_count, ts: $ts}' \
		>"$tmp_cache" 2>/dev/null && jq empty "$tmp_cache" 2>/dev/null; then
		mv "$tmp_cache" "$PULSE_TIER_CACHE_FILE"
	else
		rm -f "$tmp_cache"
		echo "[pulse-repo-tier] WARNING: jq failed writing tier for ${slug}" >>"$LOGFILE" 2>/dev/null || true
	fi
	return 0
}

# =============================================================================
# Public commands
# =============================================================================

#######################################
# classify — classify all pulse-enabled repos and write tiers to cache.
# Runs each repo sequentially (event API calls are already rate-limit sensitive).
#######################################
cmd_classify() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		echo "[pulse-repo-tier] ERROR: repos.json not found at ${REPOS_JSON}" >&2
		return 1
	fi

	_tier_ensure_cache_dir

	local slugs
	slugs=$(jq -r '.initialized_repos[] |
		select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") |
		.slug
	' "$REPOS_JSON" 2>/dev/null) || slugs=""

	if [[ -z "$slugs" ]]; then
		echo "[pulse-repo-tier] No pulse-enabled repos found in ${REPOS_JSON}" >&2
		return 0
	fi

	echo "[pulse-repo-tier] classify: starting for $(printf '%s\n' "$slugs" | wc -l | tr -d ' ') repos" >>"$LOGFILE" 2>/dev/null || true

	local failed=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local tier event_count
		event_count=$(_tier_count_events "$slug" "$PULSE_TIER_LOOKBACK_DAYS")
		[[ "$event_count" =~ ^[0-9]+$ ]] || event_count=0

		if [[ "$event_count" -ge "$PULSE_TIER_HOT_EVENT_THRESHOLD" ]]; then
			tier="$_TIER_HOT"
		elif [[ "$event_count" -ge "$PULSE_TIER_WARM_EVENT_THRESHOLD" ]]; then
			tier="$_TIER_WARM"
		else
			tier="$_TIER_COLD"
		fi

		# Promote to hot if has in-progress PR (regardless of event count)
		if [[ "$tier" != "$_TIER_HOT" ]]; then
			if _tier_has_inprogress_pr "$slug" 2>/dev/null; then
				tier="$_TIER_HOT"
			fi
		fi

		_tier_cache_write_one "$slug" "$tier" "$event_count"
		echo "[pulse-repo-tier] classify: ${slug} → ${tier} (${event_count} events/7d)" >>"$LOGFILE" 2>/dev/null || true
	done <<<"$slugs"

	echo "[pulse-repo-tier] classify: complete (${failed} errors)" >>"$LOGFILE" 2>/dev/null || true
	return 0
}

#######################################
# tier-of <slug> — return cached tier for one repo.
# Falls back to "warm" on cache miss or stale cache (>PULSE_TIER_CACHE_MAX_AGE_S old).
#
# Arguments:
#   $1 - slug (owner/repo)
#
# Outputs: "hot", "warm", or "cold" to stdout
#######################################
cmd_tier_of() {
	local slug="$1"

	if [[ -z "$slug" ]]; then
		echo "[pulse-repo-tier] ERROR: tier-of requires a slug argument" >&2
		echo "$_TIER_WARM"
		return 0
	fi

	# Cache miss → default
	if [[ ! -f "$PULSE_TIER_CACHE_FILE" ]]; then
		echo "$_TIER_WARM"
		return 0
	fi

	local entry
	entry=$(jq -r --arg slug "$slug" '.[$slug] // empty' "$PULSE_TIER_CACHE_FILE" 2>/dev/null) || entry=""

	if [[ -z "$entry" || "$entry" == "null" ]]; then
		echo "$_TIER_WARM"
		return 0
	fi

	# Check age
	local cached_ts
	cached_ts=$(printf '%s' "$entry" | jq -r '.ts // 0' 2>/dev/null) || cached_ts=0
	[[ "$cached_ts" =~ ^[0-9]+$ ]] || cached_ts=0

	local now_epoch
	now_epoch=$(date +%s)
	local age=$(( now_epoch - cached_ts ))

	if [[ "$age" -gt "$PULSE_TIER_CACHE_MAX_AGE_S" ]]; then
		# Cache stale → safe default (warm so we don't permanently skip active repos)
		echo "$_TIER_WARM"
		return 0
	fi

	local tier
	tier=$(printf '%s' "$entry" | jq -r '.tier // "warm"' 2>/dev/null) || tier="$_TIER_WARM"
	case "$tier" in
		hot|warm|cold) echo "$tier" ;;
		*) echo "$_TIER_WARM" ;;
	esac
	return 0
}

# =============================================================================
# Main dispatcher
# =============================================================================

_usage() {
	cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]:-$0}") <command> [args]

Commands:
  classify         Classify all pulse-enabled repos into tiers and write cache
  tier-of <slug>   Return cached tier for one repo (warm on miss/stale)
  help             Show this message

Environment:
  REPOS_JSON                   Path to repos.json (default: ~/.config/aidevops/repos.json)
  PULSE_TIER_CACHE_FILE        Cache output path (default: ~/.aidevops/cache/pulse-repo-tiers.json)
  PULSE_TIER_HOT_EVENT_THRESHOLD   Events/7d to classify as hot (default: 30)
  PULSE_TIER_WARM_EVENT_THRESHOLD  Events/7d to classify as warm (default: 5)
  PULSE_TIER_CACHE_MAX_AGE_S   Stale threshold for tier-of fallback (default: 7200)
EOF
	return 0
}

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
		classify)
			cmd_classify "$@"
			;;
		tier-of)
			cmd_tier_of "${1:-}"
			;;
		help|--help|-h)
			_usage
			;;
		*)
			echo "[pulse-repo-tier] Unknown command: ${cmd}" >&2
			_usage >&2
			return 1
			;;
	esac
	return 0
}

main "$@"
