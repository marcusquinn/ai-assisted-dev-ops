#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-batch-prefetch-helper.sh — Batch prefetch with search as last resort
# =============================================================================
# Groups pulse-enabled repos by owner and refreshes per-slug cache files. Search
# fanout is deliberately a last resort because GitHub secondary-limit heuristics
# penalize bursty search patterns more aggressively than ordinary cached REST
# reads. This is L3 in the layered cache hierarchy:
#
#   L1: State fingerprint (t2041) — 0 API calls, local hash comparison
#   L2: Idle skip (t2098)         — 0 API calls, reads L4 cache
#   L3: Batch prefetch (THIS)     — conditional REST first, Search only by opt-in
#   L4: Delta prefetch (GH#15286) — 2 calls per repo for changes since last fetch
#   L5: Per-PR enrichment         — 1 call per repo with open PRs (GraphQL)
#
# Usage:
#   pulse-batch-prefetch-helper.sh refresh              # Fetch and cache
#   pulse-batch-prefetch-helper.sh cache-path --kind issues --slug owner/repo
#   pulse-batch-prefetch-helper.sh read-snapshot --kind issues --slug owner/repo
#   pulse-batch-prefetch-helper.sh evict-issue owner/repo 123
#   pulse-batch-prefetch-helper.sh clear                # Wipe cache
#   pulse-batch-prefetch-helper.sh status               # Show cache ages
#
# Feature flag: PULSE_BATCH_PREFETCH_ENABLED (default: 1)
# When 0, all subcommands exit 0 immediately (no-op).
#
# GH#19963: Originally reduced GraphQL consumption by using the separate Search
# API bucket. Secondary-limit incidents showed that raw search bursts can still
# cascade; the default is now REST/cache-first with Search available by opt-in.
#
# Part of aidevops framework: https://aidevops.sh
# =============================================================================

set -euo pipefail

# --- Bash 3.2 re-exec guard (macOS compatibility) ---
# shellcheck disable=SC2292
if [ "${AIDEVOPS_BASH_REEXECED:-}" != "1" ]; then
	_modern_bash=""
	if [ -x "/opt/homebrew/bin/bash" ]; then
		_modern_bash="/opt/homebrew/bin/bash"
	elif [ -x "/usr/local/bin/bash" ]; then
		_modern_bash="/usr/local/bin/bash"
	fi
	if [ -n "$_modern_bash" ]; then
		_major="${BASH_VERSINFO[0]:-3}"
		if [ "$_major" -lt 4 ]; then
			export AIDEVOPS_BASH_REEXECED=1
			exec "$_modern_bash" "$0" "$@"
		fi
	fi
	unset _modern_bash
fi

# --- Constants ---
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
_PULSE_BATCH_SEARCH_LAST_RESORT_ENV="${PULSE_BATCH_SEARCH_LAST_RESORT-}"

# shellcheck source=./shared-gh-request-state.sh
if [[ -f "${SCRIPT_DIR}/shared-gh-request-state.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/shared-gh-request-state.sh"
fi

# Source shared constants for colors and helpers
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Source privacy-safe efficiency instrumentation for cache/single-flight events.
# shellcheck source=./gh-api-instrument.sh
# shellcheck disable=SC1091
if ! declare -F gh_record_efficiency_evidence >/dev/null 2>&1 \
	&& [[ -f "${SCRIPT_DIR}/gh-api-instrument.sh" ]]; then
	source "${SCRIPT_DIR}/gh-api-instrument.sh"
fi

# Source L1 events ETag tickle helper (t2830, GH#20868).
# Provides events_tickle <owner> — skips batch search on 304 ETag match.
# Fail-open: if the file is absent, events_tickle is a no-op stub below.
# shellcheck source=./pulse-events-tickle.sh
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/pulse-events-tickle.sh" ]]; then
	source "${SCRIPT_DIR}/pulse-events-tickle.sh"
elif ! declare -F events_tickle >/dev/null 2>&1; then
	# Stub: always returns "unknown" (exit 2) so the batch search runs.
	events_tickle() { return 2; }
fi

# Source pulse-stats-helper for persistent counter recording (fail-open).
# shellcheck source=./pulse-stats-helper.sh
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/pulse-stats-helper.sh" ]]; then
	source "${SCRIPT_DIR}/pulse-stats-helper.sh" 2>/dev/null || true
fi

_prefetch_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

# --- Configuration ---
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
BATCH_CACHE_DIR="${PULSE_BATCH_PREFETCH_CACHE_DIR:-${HOME}/.aidevops/logs/batch-prefetch}"
PULSE_BATCH_PREFETCH_ENABLED="${PULSE_BATCH_PREFETCH_ENABLED:-1}"
PULSE_PREFETCH_FULL_SWEEP_INTERVAL="${PULSE_PREFETCH_FULL_SWEEP_INTERVAL:-14400}"
BATCH_SEARCH_LIMIT="${PULSE_BATCH_SEARCH_LIMIT:-200}"
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse-wrapper.log}"
PULSE_BATCH_CONDITIONAL_REST_ENABLED="${PULSE_BATCH_CONDITIONAL_REST_ENABLED:-1}"
PULSE_BATCH_SEARCH_LAST_RESORT="${_PULSE_BATCH_SEARCH_LAST_RESORT_ENV:-${PULSE_BATCH_SEARCH_LAST_RESORT:-1}}"
unset _PULSE_BATCH_SEARCH_LAST_RESORT_ENV

# String constants to avoid repeated-literal ratchet violations
_KIND_ISSUES="issues"
_KIND_PRS="prs"
_JSON_NULL="null"
_JSON_EMPTY_OBJ="{}"
_JSON_EMPTY_ARR="[]"
_JSON_TYPE_ARRAY=array
_JSON_TYPE_BOOLEAN=boolean
_JSON_TYPE_STRING=string
_STATE_OPEN="open"
_CACHE_STATE_MALFORMED="malformed"
_CACHE_STATE_INVALIDATED="invalidated"
_CACHE_CARDINALITY_EMPTY=empty
_CACHE_CARDINALITY_UNKNOWN=unknown
_CACHE_SNAPSHOT_STATE="missing"
_CACHE_SNAPSHOT_PATH=""
_SNAPSHOT_SCHEMA="aidevops-pulse-snapshot/v1"
_SNAPSHOT_ISSUES_PROJECTION="number,title,state,labels,updatedAt,assignees,body,authorAssociation,author"
_SNAPSHOT_PRS_PROJECTION="number,title,labels,updatedAt,assignees,createdAt,author,headRefOid,headRefName"
_BATCH_SNAPSHOT_GENERATION="${PULSE_BATCH_SNAPSHOT_GENERATION:-}"
_BATCH_SNAPSHOT_AUTH_SCOPE="${PULSE_BATCH_SNAPSHOT_AUTH_SCOPE:-${GH_HOST:-github.com}|${AIDEVOPS_GH_AUTH_MODE:-gh}|${AIDEVOPS_GH_AUTH_PRINCIPAL:-default}}|${AIDEVOPS_GH_API_POOL:-default}"
_BATCH_INITIAL_SNAPSHOT_MARKERS=""
_BATCH_INITIAL_INVALIDATION_GENERATIONS=""
_BATCH_SNAPSHOT_MARKER_MISSING="$_CACHE_SNAPSHOT_STATE"
_BATCH_INVALIDATION_INITIAL="${_GHRS_INVALIDATION_INITIAL:-0000000000000000000000000000000000000000000000000000000000000000}"

# --- Feature flag gate ---
_check_enabled() {
	if [[ "$PULSE_BATCH_PREFETCH_ENABLED" != "1" ]]; then
		return 1
	fi
	return 0
}

_snapshot_projection() {
	local kind="$1"
	case "$kind" in
	issues) printf '%s\n' "$_SNAPSHOT_ISSUES_PROJECTION" ;;
	prs) printf '%s\n' "$_SNAPSHOT_PRS_PROJECTION" ;;
	*) return 1 ;;
	esac
	return 0
}

_snapshot_request_key() {
	local kind="$1"
	local slug="$2"
	local projection=""
	projection=$(_snapshot_projection "$kind") || return 1
	declare -F gh_request_state_request_key >/dev/null 2>&1 || return 1
	gh_request_state_request_key "$slug" canonical-snapshot "$projection" "$kind" rest-core
	return $?
}

_snapshot_invalidation_key() {
	local kind="$1"
	local slug="$2"
	local projection=""
	projection=$(_snapshot_projection "$kind") || return 1
	declare -F gh_request_state_invalidation_key >/dev/null 2>&1 || return 1
	gh_request_state_invalidation_key "$slug" canonical-snapshot "$projection" "$kind"
	return $?
}

_snapshot_invalidation_generation() {
	local kind="$1"
	local slug="$2"
	local request_key=""
	if ! declare -F gh_request_state_invalidation_generation_get >/dev/null 2>&1; then
		printf '%s\n' "$_BATCH_INVALIDATION_INITIAL"
		return 0
	fi
	request_key="$(_snapshot_invalidation_key "$kind" "$slug")" || return 1
	gh_request_state_invalidation_generation_get "$request_key"
	return $?
}

_snapshot_invalidation_generation_is_current() {
	local kind="$1"
	local slug="$2"
	local generation="$3"
	local request_key=""
	request_key="$(_snapshot_invalidation_key "$kind" "$slug")" || return 1
	gh_request_state_invalidation_generation_is_current "$request_key" "$generation"
	return $?
}

_snapshot_initial_invalidation_generation() {
	local kind="$1"
	local slug="$2"
	local stored_kind="" stored_slug="" generation=""
	while IFS='|' read -r stored_kind stored_slug generation; do
		if [[ "$stored_kind" == "$kind" && "$stored_slug" == "$slug" && -n "$generation" ]]; then
			printf '%s\n' "$generation"
			return 0
		fi
	done <<<"$_BATCH_INITIAL_INVALIDATION_GENERATIONS"
	_snapshot_invalidation_generation "$kind" "$slug"
	return $?
}

_snapshot_collection_complete() {
	local payload="$1"
	local limit="${2:-100}"
	[[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]] || limit=100
	[[ "$limit" -le 100 ]] || limit=100
	local count=""
	count=$(printf '%s' "$payload" | jq -er 'select(type == "array") | length' 2>/dev/null) || return 1
	if [[ "$count" =~ ^[0-9]+$ && "$count" -lt "$limit" ]]; then
		return 0
	fi
	return 1
}

# --- Logging ---
_log() {
	local msg="$1"
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	echo "[${ts}] [pulse-batch-prefetch] ${msg}" >>"$LOGFILE"
	return 0
}

# --- Search API rate-limit detection ---
# The Search API uses a separate rate-limit bucket from GraphQL.
# Detection patterns cover both Search API limits AND GraphQL exhaustion:
#   - "GraphQL: API rate limit (already) exceeded" — observed in production
#     2026-04-22 17:36–18:45 UTC: gh search prs/issues internally uses GraphQL;
#     when the GraphQL quota is exhausted the error contains this string.
#   - "API rate limit exceeded for user" — alternate GitHub phrasing.
# Both are distinct from the Search-API-specific patterns (30/min bucket).
_is_search_rate_limited() {
	local err_file="$1"
	[[ -n "$err_file" && -s "$err_file" ]] || return 1
	grep -qiE 'Search rate limit exceeded|search API rate limit|HTTP 422.*abuse detection|secondary rate limit|was submitted too quickly|GraphQL: API rate limit (already )?exceeded|API rate limit exceeded for user' "$err_file"
}

# --- REST fallback: issues fetch for a single slug ---
# Called when gh search issues is rate-limited (GraphQL or Search API exhausted).
# Fetches open issues via GET /repos/{slug}/issues (REST core bucket: 5000/hr,
# independent of GraphQL quota). Writes the normalized cache file directly.
# Field mapping: REST updated_at → prefetch-schema updatedAt.
#
# Arguments: $1=slug (owner/repo)
# Returns: 0 on success (cache written), 1 on failure (REST also failed/no data)
_prefetch_rest_issues_for_slug() {
	local slug="$1"
	local invalidation_generation=""
	invalidation_generation="$(_snapshot_initial_invalidation_generation "$_KIND_ISSUES" "$slug")" || return 1
	declare -F gh_record_call >/dev/null && gh_record_call rest pulse_batch_prefetch_rest_issues || true
	local rest_json
	rest_json=$(_prefetch_gh_read gh api "/repos/${slug}/issues?state=open&per_page=${BATCH_SEARCH_LIMIT}" 2>/dev/null) || rest_json=""
	if [[ -z "$rest_json" || "$rest_json" == "$_JSON_NULL" ]]; then
		_log "REST issues fallback: empty/null response for ${slug}"
		return 1
	fi
	local cache_file
	cache_file=$(_cache_file_path "$_KIND_ISSUES" "$slug")
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local complete=false
	_snapshot_collection_complete "$rest_json" "$BATCH_SEARCH_LIMIT" && complete=true
	local projection=""
	projection=$(_snapshot_projection "$_KIND_ISSUES") || return 1
	local tmp_file=""
	tmp_file=$(mktemp "${BATCH_CACHE_DIR}/.issues-snapshot.XXXXXX") || return 1
	if ! printf '%s\n' "$rest_json" | jq --arg ts "$ts" --arg state_open "$_STATE_OPEN" \
		--arg schema "$_SNAPSHOT_SCHEMA" --arg slug "$slug" --arg collection "$_KIND_ISSUES" \
		--arg projection "$projection" --arg auth_scope "$_BATCH_SNAPSHOT_AUTH_SCOPE" \
		--arg generation "$_BATCH_SNAPSHOT_GENERATION" \
		--arg invalidation_generation "$invalidation_generation" --argjson complete "$complete" '{
		schema: $schema,
		repository: $slug,
		collection: $collection,
		projection: $projection,
		auth_scope: $auth_scope,
		generation: $generation,
		invalidation_generation: $invalidation_generation,
		source: "rest-fallback",
		complete: $complete,
		truncated: ($complete | not),
		fetched_at: $ts,
		timestamp: $ts,
		items: [.[] | select(.pull_request == null) | {
			number: .number,
			title: .title,
			state: (.state // $state_open),
			labels: (.labels // []),
			updatedAt: .updated_at,
			assignees: (.assignees // []),
			body: (if (has("body") | not) then error("missing issue body") elif .body == null then "" elif (.body | type) == "string" then .body else error("invalid issue body") end),
			authorAssociation: (.author_association // "NONE"),
			author: (if .user then {
				login: (.user.login // ""),
				type: (.user.type // ""),
				is_bot: ((.user.type // "") == "Bot")
			} else null end)
		}]
	}' >"$tmp_file" 2>/dev/null; then
		rm -f "$tmp_file"
		_log "REST issues fallback: failed to write cache for ${slug}"
		return 1
	fi
	if ! _snapshot_invalidation_generation_is_current "$_KIND_ISSUES" "$slug" "$invalidation_generation"; then
		rm -f "$tmp_file"
		_log "REST issues fallback: publication fenced for ${slug}"
		return 1
	fi
	mv "$tmp_file" "$cache_file" || {
		rm -f "$tmp_file"
		return 1
	}
	_snapshot_invalidation_generation_is_current "$_KIND_ISSUES" "$slug" "$invalidation_generation" || return 1
	local item_count
	item_count=$(jq '.items | length' "$cache_file" 2>/dev/null) || item_count=0
	_log "REST issues fallback: wrote ${item_count} items to cache for ${slug}"
	return 0
}

# --- REST fallback: PRs fetch for a single slug ---
# Called when gh search prs is rate-limited (GraphQL or Search API exhausted).
# Fetches open PRs via GET /repos/{slug}/pulls (REST core budget: 5000/hr,
# independent of GraphQL quota). Writes the normalized cache file directly.
# Field mapping: REST updated_at → updatedAt, created_at → createdAt, user → author.
#
# Arguments: $1=slug (owner/repo)
# Returns: 0 on success (cache written), 1 on failure (REST also failed/no data)
_prefetch_rest_prs_for_slug() {
	local slug="$1"
	local invalidation_generation=""
	invalidation_generation="$(_snapshot_initial_invalidation_generation "$_KIND_PRS" "$slug")" || return 1
	declare -F gh_record_call >/dev/null && gh_record_call rest pulse_batch_prefetch_rest_prs || true
	local rest_json
	rest_json=$(_prefetch_gh_read gh api "/repos/${slug}/pulls?state=open&per_page=${BATCH_SEARCH_LIMIT}" 2>/dev/null) || rest_json=""
	if [[ -z "$rest_json" || "$rest_json" == "$_JSON_NULL" ]]; then
		_log "REST PRs fallback: empty/null response for ${slug}"
		return 1
	fi
	local cache_file
	cache_file=$(_cache_file_path "$_KIND_PRS" "$slug")
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local complete=false
	_snapshot_collection_complete "$rest_json" "$BATCH_SEARCH_LIMIT" && complete=true
	local projection=""
	projection=$(_snapshot_projection "$_KIND_PRS") || return 1
	local tmp_file=""
	tmp_file=$(mktemp "${BATCH_CACHE_DIR}/.prs-snapshot.XXXXXX") || return 1
	if ! printf '%s\n' "$rest_json" | jq --arg ts "$ts" --arg schema "$_SNAPSHOT_SCHEMA" \
		--arg slug "$slug" --arg collection "$_KIND_PRS" --arg projection "$projection" \
		--arg auth_scope "$_BATCH_SNAPSHOT_AUTH_SCOPE" --arg generation "$_BATCH_SNAPSHOT_GENERATION" \
		--arg invalidation_generation "$invalidation_generation" \
		--argjson complete "$complete" '{
		schema: $schema,
		repository: $slug,
		collection: $collection,
		projection: $projection,
		auth_scope: $auth_scope,
		generation: $generation,
		invalidation_generation: $invalidation_generation,
		source: "rest-fallback",
		complete: $complete,
		truncated: ($complete | not),
		fetched_at: $ts,
		timestamp: $ts,
		items: [.[] | {
			number: .number,
			title: .title,
			labels: (.labels // []),
			updatedAt: .updated_at,
			assignees: (.assignees // []),
			createdAt: (.created_at // null),
			author: (if .user then {login: .user.login} else null end),
			headRefOid: (.head.sha // null),
			headRefName: (.head.ref // null)
		}]
	}' >"$tmp_file" 2>/dev/null; then
		rm -f "$tmp_file"
		_log "REST PRs fallback: failed to write cache for ${slug}"
		return 1
	fi
	if ! _snapshot_invalidation_generation_is_current "$_KIND_PRS" "$slug" "$invalidation_generation"; then
		rm -f "$tmp_file"
		_log "REST PRs fallback: publication fenced for ${slug}"
		return 1
	fi
	mv "$tmp_file" "$cache_file" || {
		rm -f "$tmp_file"
		return 1
	}
	_snapshot_invalidation_generation_is_current "$_KIND_PRS" "$slug" "$invalidation_generation" || return 1
	local item_count
	item_count=$(jq '.items | length' "$cache_file" 2>/dev/null) || item_count=0
	_log "REST PRs fallback: wrote ${item_count} items to cache for ${slug}"
	return 0
}

# --- REST per-slug iteration (t2902) ---
# Iterate a comma-separated slug list and dispatch each to the per-slug REST
# fallback helper for the requested kind. Updates _OWNER_CACHE_WRITES /
# _OWNER_ERRORS (Bash 3.2 namerefs workaround — these are pseudo-globals
# set by the caller).
#
# Used by both:
#   (a) the proactive guard in _refresh_owner_* (skip gh search when GraphQL
#       budget is below threshold), and
#   (b) the reactive fallback after a gh search rate-limit error.
#
# Arguments: $1=kind ("issues" | "prs")  $2=slugs (comma-separated)
# Returns: 0 always (per-slug failures roll into _OWNER_ERRORS counter)
_prefetch_rest_per_slug() {
	local kind="$1"
	local slugs="${2:-}"
	[[ -n "$slugs" ]] || return 0
	local slug="" ok=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		ok=0
		case "$kind" in
		issues) _prefetch_rest_issues_for_slug "$slug" && ok=1 ;;
		prs) _prefetch_rest_prs_for_slug "$slug" && ok=1 ;;
		*)
			_log "_prefetch_rest_per_slug: unknown kind=${kind}"
			return 1
			;;
		esac
		if [[ "$ok" -eq 1 ]]; then
			_OWNER_CACHE_WRITES=$((_OWNER_CACHE_WRITES + 1))
		else
			_OWNER_ERRORS=$((_OWNER_ERRORS + 1))
		fi
	done < <(tr ',' '\n' <<< "$slugs")
	return 0
}

# --- Owner grouping ---
# Read repos.json and group pulse-enabled, non-local-only repos by owner.
# Output: one line per owner with pipe-separated slugs.
# Format: owner|slug1,slug2,slug3
_group_repos_by_owner() {
	local repos_json="$1"
	[[ -f "$repos_json" ]] || return 1

	jq -r '
		[.initialized_repos[] |
			select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") |
			.slug
		] |
		group_by(split("/")[0]) |
		map(
			(.[0] | split("/")[0]) + "|" + (map(.) | join(","))
		) |
		.[]
	' "$repos_json" 2>/dev/null
	return 0
}

# --- Normalization ---
# Map gh search output to the same schema as _prefetch_cache_set expects.
# gh search returns .repository.nameWithOwner but not .createdAt or .author
# for issues. We add null placeholders so downstream consumers don't break.
#
# Arguments:
#   $1 - kind: "issues" or "prs"
# Input: JSON array on stdin (from gh search)
# Output: JSON object keyed by slug, each value an array of normalized items
_normalize_search_to_prefetch_schema() {
	local kind="$1"

	if [[ "$kind" == "$_KIND_ISSUES" ]]; then
		jq --arg state_open "$_STATE_OPEN" '
			group_by(.repository.nameWithOwner) |
			map({
				key: (.[0].repository.nameWithOwner),
				value: [.[] | {
					number: .number,
					title: .title,
					state: (.state // $state_open),
					labels: .labels,
					updatedAt: .updatedAt,
					assignees: .assignees,
					body: (if (has("body") | not) then error("missing issue body") elif .body == null then "" elif (.body | type) == "string" then .body else error("invalid issue body") end),
					authorAssociation: (.authorAssociation // "NONE"),
					author: (.author // null)
				}]
			}) |
			from_entries
		' 2>/dev/null
	else
		# PRs: normalize to prefetch schema.
		# Note: headRefName is NOT available from gh search prs (Search API
		# returns issue-shaped results). Consumers needing branch names must
		# fetch lazily via `gh pr view <N> --json headRefName`.
		jq '
			group_by(.repository.nameWithOwner) |
			map({
				key: (.[0].repository.nameWithOwner),
				value: [.[] | {
					number: .number,
					title: .title,
					labels: (.labels // []),
					updatedAt: .updatedAt,
					assignees: (.assignees // []),
					createdAt: (.createdAt // null),
					author: (.author // null),
					headRefOid: (.headRefOid // null),
					headRefName: (.headRefName // null)
				}]
			}) |
			from_entries
		' 2>/dev/null
	fi
	return 0
}

# --- Cache file path ---
# Generate deterministic cache file path for a slug+kind combo.
# Slug slashes are replaced with double dashes for filesystem safety.
_cache_file_path() {
	local kind="$1"
	local slug="$2"
	local safe_slug="${slug//\//__}"
	echo "${BATCH_CACHE_DIR}/${kind}-${safe_slug}.json"
	return 0
}

_conditional_rest_endpoint() {
	local kind="$1"
	local slug="$2"
	case "$kind" in
	issues) printf '/repos/%s/issues?state=open&per_page=%s\n' "$slug" "$BATCH_SEARCH_LIMIT" ;;
	prs) printf '/repos/%s/pulls?state=open&per_page=%s\n' "$slug" "$BATCH_SEARCH_LIMIT" ;;
	*) return 1 ;;
	esac
	return 0
}

_conditional_rest_snapshot_marker() {
	local kind="$1"
	local slug="$2"
	local projection=""
	local cache_file=""
	local invalidation_generation=""
	projection=$(_snapshot_projection "$kind") || return 1
	invalidation_generation="$(_snapshot_invalidation_generation "$kind" "$slug")" || return 1
	cache_file=$(_cache_file_path "$kind" "$slug")
	[[ -s "$cache_file" ]] || return 1
	jq -er --arg schema "$_SNAPSHOT_SCHEMA" --arg slug "$slug" --arg kind "$kind" \
		--arg projection "$projection" --arg auth_scope "$_BATCH_SNAPSHOT_AUTH_SCOPE" \
		--arg string_type "$_JSON_TYPE_STRING" \
		--arg invalidation_generation "$invalidation_generation" \
		--arg invalidation_initial "$_BATCH_INVALIDATION_INITIAL" '
		select(
			.schema == $schema and .repository == $slug and .collection == $kind and
			.projection == $projection and .auth_scope == $auth_scope and
			(.invalidation_generation // $invalidation_initial) == $invalidation_generation and
			.source == "conditional-rest" and .complete == true and
			(.generation | type == $string_type and length > 0) and
			(.fetched_at | type == $string_type and length > 0)
		) |
		[.generation, .fetched_at, (.etag // "")] | @tsv
	' "$cache_file" 2>/dev/null
	return $?
}

_conditional_rest_capture_initial_markers() {
	local owner_groups="$1"
	local owner="" slugs="" slug="" kind="" marker="" record=""
	local invalidation_generation="" invalidation_record=""
	_BATCH_INITIAL_SNAPSHOT_MARKERS=""
	_BATCH_INITIAL_INVALIDATION_GENERATIONS=""
	while IFS='|' read -r owner slugs; do
		[[ -n "$owner" ]] || continue
		while IFS= read -r slug; do
			[[ -n "$slug" ]] || continue
			for kind in "$_KIND_ISSUES" "$_KIND_PRS"; do
				marker=$(_conditional_rest_snapshot_marker "$kind" "$slug") || marker="$_BATCH_SNAPSHOT_MARKER_MISSING"
				invalidation_generation=$(_snapshot_invalidation_generation "$kind" "$slug") || invalidation_generation=""
				record="${kind}|${slug}|${marker}"
				invalidation_record="${kind}|${slug}|${invalidation_generation}"
				if [[ -n "$_BATCH_INITIAL_SNAPSHOT_MARKERS" ]]; then
					_BATCH_INITIAL_SNAPSHOT_MARKERS="${_BATCH_INITIAL_SNAPSHOT_MARKERS}"$'\n'"${record}"
				else
					_BATCH_INITIAL_SNAPSHOT_MARKERS="$record"
				fi
				if [[ -n "$_BATCH_INITIAL_INVALIDATION_GENERATIONS" ]]; then
					_BATCH_INITIAL_INVALIDATION_GENERATIONS="${_BATCH_INITIAL_INVALIDATION_GENERATIONS}"$'\n'"${invalidation_record}"
				else
					_BATCH_INITIAL_INVALIDATION_GENERATIONS="$invalidation_record"
				fi
			done
		done < <(tr ',' '\n' <<<"$slugs")
	done <<<"$owner_groups"
	return 0
}

_conditional_rest_initial_marker() {
	local kind="$1"
	local slug="$2"
	local stored_kind="" stored_slug="" marker=""
	while IFS='|' read -r stored_kind stored_slug marker; do
		if [[ "$stored_kind" == "$kind" && "$stored_slug" == "$slug" ]]; then
			printf '%s\n' "$marker"
			return 0
		fi
	done <<<"$_BATCH_INITIAL_SNAPSHOT_MARKERS"
	return 1
}

_conditional_rest_update_cache_from_response() {
	local kind="$1"
	local slug="$2"
	local response_file="$3"
	local cache_file="$4"
	local invalidation_generation="$5"
	# Keep response parsing in Python so this shell library stays below the
	# function-complexity gate while preserving atomic cache writes.
	local projection=""
	projection=$(_snapshot_projection "$kind") || return 1
	python3 "${SCRIPT_DIR}/pulse-batch-conditional-cache.py" \
		"$kind" "$slug" "$response_file" "$cache_file" \
		"$_BATCH_SNAPSHOT_GENERATION" "$_BATCH_SNAPSHOT_AUTH_SCOPE" "$projection" \
		"$invalidation_generation"
	return 0
}

_conditional_rest_refresh_slug_leader() {
	local kind="$1"
	local slug="$2"
	local request_key="${3:-}"
	local generation="${4:-}"
	local invalidation_generation="${5:-}"
	[[ "${PULSE_BATCH_CONDITIONAL_REST_ENABLED:-1}" == "1" ]] || return 1
	if [[ -z "$invalidation_generation" ]]; then
		invalidation_generation="$(_snapshot_initial_invalidation_generation "$kind" "$slug")" || return 1
	fi
	local cache_file
	cache_file=$(_cache_file_path "$kind" "$slug")
	local endpoint
	endpoint=$(_conditional_rest_endpoint "$kind" "$slug") || return 1
	local projection=""
	projection=$(_snapshot_projection "$kind") || return 1
	local etag=""
	if [[ -f "$cache_file" ]]; then
		etag=$(jq -r --arg schema "$_SNAPSHOT_SCHEMA" --arg kind "$kind" \
			--arg projection "$projection" --arg auth_scope "$_BATCH_SNAPSHOT_AUTH_SCOPE" \
			--arg invalidation_generation "$invalidation_generation" \
			--arg invalidation_initial "$_BATCH_INVALIDATION_INITIAL" '
			select(.schema == $schema and .collection == $kind and .projection == $projection) |
			select(.auth_scope == $auth_scope and .complete == true) |
			select((.invalidation_generation // $invalidation_initial) == $invalidation_generation) |
			.etag // ""
		' "$cache_file" 2>/dev/null) || etag=""
		[[ "$etag" == "$_JSON_NULL" ]] && etag=""
	fi
	[[ -n "$etag" ]] || _OWNER_CONDITIONAL_MISSES=$((_OWNER_CONDITIONAL_MISSES + 1))
	local response_file="" err_file=""
	response_file=$(mktemp)
	err_file=$(mktemp)
	local rc=0
	if [[ -n "$etag" ]]; then
		_prefetch_gh_read gh api -i -H "Accept: application/vnd.github+json" -H "If-None-Match: ${etag}" "$endpoint" >"$response_file" 2>"$err_file" || rc=$?
	else
		_prefetch_gh_read gh api -i -H "Accept: application/vnd.github+json" "$endpoint" >"$response_file" 2>"$err_file" || rc=$?
	fi
	local status=""
	if [[ -n "$request_key" && -n "$generation" ]] && ! gh_request_state_singleflight_is_owner "$request_key" "$generation"; then
		rm -f "$response_file" "$err_file"
		return 1
	fi
	if ! _snapshot_invalidation_generation_is_current "$kind" "$slug" "$invalidation_generation"; then
		rm -f "$response_file" "$err_file"
		return 1
	fi
	status=$(_conditional_rest_update_cache_from_response "$kind" "$slug" "$response_file" "$cache_file" "$invalidation_generation" 2>/dev/null) || status=""
	rm -f "$response_file" "$err_file"
	if [[ -n "$status" ]] && ! _snapshot_invalidation_generation_is_current "$kind" "$slug" "$invalidation_generation"; then
		_log "conditional REST ${kind}: publication invalidated for ${slug}"
		return 1
	fi
	case "$status" in
	304)
		_OWNER_CONDITIONAL_304=$((_OWNER_CONDITIONAL_304 + 1))
		_OWNER_CACHE_WRITES=$((_OWNER_CACHE_WRITES + 1))
		_log "conditional REST ${kind}: 304 cache hit for ${slug}"
		return 0
		;;
	2*)
		_OWNER_CONDITIONAL_REFRESHES=$((_OWNER_CONDITIONAL_REFRESHES + 1))
		_OWNER_CACHE_WRITES=$((_OWNER_CACHE_WRITES + 1))
		_log "conditional REST ${kind}: refreshed ${slug} status=${status}"
		return 0
		;;
	*)
		[[ "$rc" -eq 0 ]] || _log "conditional REST ${kind}: failed for ${slug}; falling back"
		return 1
		;;
	esac
	return 1
}

_conditional_rest_refresh_slug() {
	local kind="$1"
	local slug="$2"
	local projection=""
	local request_key=""
	local generation=""
	local invalidation_generation=""
	local initial_marker=""
	local current_marker=""
	projection=$(_snapshot_projection "$kind") || return 1
	invalidation_generation="$(_snapshot_initial_invalidation_generation "$kind" "$slug")" || return 1
	initial_marker=$(_conditional_rest_initial_marker "$kind" "$slug") || {
		initial_marker=$(_conditional_rest_snapshot_marker "$kind" "$slug") || initial_marker="$_BATCH_SNAPSHOT_MARKER_MISSING"
	}
	if ! declare -F gh_request_state_singleflight_begin >/dev/null 2>&1; then
		_conditional_rest_refresh_slug_leader "$kind" "$slug" "" "" "$invalidation_generation"
		return $?
	fi
	request_key="$(_snapshot_request_key "$kind" "$slug")" || {
		_conditional_rest_refresh_slug_leader "$kind" "$slug" "" "" "$invalidation_generation"
		return $?
	}
	gh_request_state_singleflight_begin "$request_key"
	generation="$_GHRS_BEGIN_GENERATION"
	case "$_GHRS_BEGIN_ROLE" in
	leader)
		current_marker=$(_conditional_rest_snapshot_marker "$kind" "$slug") || current_marker=""
		if [[ -n "$current_marker" && "$current_marker" != "$initial_marker" ]]; then
			gh_request_state_singleflight_finish "$request_key" "$generation" success || true
			_log "conditional REST ${kind}: reused concurrently published snapshot for ${slug}"
			return 0
		fi
		if _conditional_rest_refresh_slug_leader "$kind" "$slug" "$request_key" "$generation" "$invalidation_generation"; then
			gh_request_state_singleflight_finish "$request_key" "$generation" success || true
			return 0
		fi
		gh_request_state_singleflight_finish "$request_key" "$generation" failure || true
		return 1
		;;
	follower-success)
		if _conditional_rest_snapshot_marker "$kind" "$slug" >/dev/null 2>&1; then
			_log "conditional REST ${kind}: coalesced shared refresh for ${slug}"
			return 0
		fi
		return 1
		;;
	follower-failure | timeout) return 1 ;;
	bypass)
		_conditional_rest_refresh_slug_leader "$kind" "$slug" "" "" "$invalidation_generation"
		return $?
		;;
	esac
	return 1
}

_conditional_rest_per_slug() {
	local kind="$1"
	local slugs="${2:-}"
	[[ -n "$slugs" ]] || return 1
	local slug="" failures=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		_conditional_rest_refresh_slug "$kind" "$slug" || failures=$((failures + 1))
	done < <(tr ',' '\n' <<< "$slugs")
	[[ "$failures" -eq 0 ]] || return 1
	return 0
}

# --- Write per-slug cache files ---
# Takes normalized JSON (keyed by slug) and writes individual cache files.
_write_per_slug_caches() {
	local kind="$1"
	local normalized_json="$2"

	local slugs
	slugs=$(echo "$normalized_json" | jq -r 'keys[]' 2>/dev/null) || return 1
	local projection=""
	projection=$(_snapshot_projection "$kind") || return 1

	local slug
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local invalidation_generation=""
		invalidation_generation="$(_snapshot_initial_invalidation_generation "$kind" "$slug")" || continue
		local cache_file
		cache_file=$(_cache_file_path "$kind" "$slug")
		local ts
		ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		local tmp_file=""
		tmp_file=$(mktemp "${BATCH_CACHE_DIR}/.search-snapshot.XXXXXX") || continue
		if ! printf '%s\n' "$normalized_json" | jq --arg slug "$slug" --arg ts "$ts" \
			--arg schema "$_SNAPSHOT_SCHEMA" --arg collection "$kind" \
			--arg projection "$projection" --arg auth_scope "$_BATCH_SNAPSHOT_AUTH_SCOPE" \
			--arg generation "$_BATCH_SNAPSHOT_GENERATION" \
			--arg invalidation_generation "$invalidation_generation" '{
			schema: $schema,
			repository: $slug,
			collection: $collection,
			projection: $projection,
			auth_scope: $auth_scope,
			generation: $generation,
			invalidation_generation: $invalidation_generation,
			source: "owner-search",
			complete: false,
			truncated: true,
			fetched_at: $ts,
			timestamp: $ts,
			items: .[$slug]
		}' >"$tmp_file" 2>/dev/null; then
			rm -f "$tmp_file"
			_log "WARNING: failed to write cache for ${kind}/${slug}"
			continue
		fi
		if ! _snapshot_invalidation_generation_is_current "$kind" "$slug" "$invalidation_generation"; then
			rm -f "$tmp_file"
			_log "WARNING: fenced stale cache publication for ${kind}/${slug}"
			continue
		fi
		mv "$tmp_file" "$cache_file" || {
			rm -f "$tmp_file"
			continue
		}
		_snapshot_invalidation_generation_is_current "$kind" "$slug" "$invalidation_generation" || true
	done <<<"$slugs"
	return 0
}

# =============================================================================
# Subcommand: refresh — per-owner fetch helpers
# =============================================================================

_search_should_route_to_rest() {
	local graphql_remaining="${1:-}"
	if [[ "${PULSE_BATCH_SEARCH_LAST_RESORT:-1}" == "1" ]]; then
		return 0
	fi
	if _rest_should_fallback "$graphql_remaining" 2>/dev/null; then
		return 0
	fi
	if declare -F _gh_secondary_cooldown_preflight >/dev/null 2>&1; then
		_gh_secondary_cooldown_preflight read >/dev/null 2>&1 || return 0
	fi
	return 1
}

_route_owner_search_to_rest() {
	local kind="$1"
	local owner="$2"
	local slugs="${3:-}"
	local caller="pulse_batch_prefetch_search_${kind}_fallback"
	_log "search last-resort active — routing ${kind} prefetch for owner=${owner} through per-repo REST"
	declare -F gh_record_call >/dev/null && gh_record_call search-rest "$caller" || true
	_prefetch_rest_per_slug "$kind" "$slugs"
	return 0
}

# Fetch and cache issues for a single owner.
# Sets _OWNER_SEARCH_CALLS, _OWNER_CACHE_WRITES, _OWNER_ERRORS (Bash 3.2 namerefs workaround)
# Arguments: $1=owner  $2=slugs (comma-separated owner/repo list for REST fallback)
#            $3=graphql_remaining (optional pre-computed integer; pass to avoid redundant
#                                  rate-limit API calls when iterating over many owners)
_refresh_owner_issues() {
	local owner="$1"
	local slugs="${2:-}"
	local graphql_remaining="${3:-}"
	if _conditional_rest_per_slug issues "$slugs"; then
		_log "conditional REST issues complete for owner=${owner} — skipped search"
		return 0
	fi
	if _search_should_route_to_rest "$graphql_remaining"; then
		_route_owner_search_to_rest issues "$owner" "$slugs"
		return 0
	fi
	# Proactive REST fallback (t2902): if GraphQL is at/below the fallback
	# threshold, skip `gh search issues` (which uses the GraphQL Search API,
	# ~30 points/call) and go straight to per-slug REST iteration. Avoids
	# burning points on a call that will fail and then be retried via REST.
	# Pass pre-computed remaining to avoid a redundant rate-limit API call per owner.
	if _rest_should_fallback "$graphql_remaining" 2>/dev/null; then
		_log "GraphQL <= threshold — skipping gh search issues for owner=${owner}, going straight to REST"
		declare -F gh_record_call >/dev/null && gh_record_call search-rest pulse_batch_prefetch_search_issues_fallback || true
		_prefetch_rest_per_slug issues "$slugs"
		return 0
	fi
	declare -F gh_record_call >/dev/null && gh_record_call search-graphql pulse_batch_prefetch_search_issues || true
	local issue_err
	issue_err=$(mktemp)
	local issue_json=""
	issue_json=$(_prefetch_gh_read gh search issues --owner "$owner" --state open \
		--limit "$BATCH_SEARCH_LIMIT" \
		--json number,title,state,labels,updatedAt,assignees,body,authorAssociation,author,repository 2>"$issue_err") || issue_json=""
	_OWNER_SEARCH_CALLS=$((_OWNER_SEARCH_CALLS + 1))

	if [[ -z "$issue_json" || "$issue_json" == "$_JSON_NULL" ]]; then
		local issue_err_msg
		issue_err_msg=$(cat "$issue_err" 2>/dev/null || echo "unknown error")
		if _is_search_rate_limited "$issue_err"; then
			_log "Search/GraphQL rate-limited during issues fetch for owner=${owner} — falling back to per-repo REST"
			rm -f "$issue_err"
			# Reactive REST fallback: iterate per-slug via core REST bucket.
			_prefetch_rest_per_slug issues "$slugs"
			return 0
		else
			_log "gh search issues failed for owner=${owner}: ${issue_err_msg}"
		fi
		_OWNER_ERRORS=$((_OWNER_ERRORS + 1))
		rm -f "$issue_err"
		return 1
	fi
	rm -f "$issue_err"

	local normalized_issues
	normalized_issues=$(echo "$issue_json" | _normalize_search_to_prefetch_schema "$_KIND_ISSUES")
	if [[ -n "$normalized_issues" && "$normalized_issues" != "$_JSON_NULL" && "$normalized_issues" != "$_JSON_EMPTY_OBJ" ]]; then
		_write_per_slug_caches "$_KIND_ISSUES" "$normalized_issues"
		local issue_slug_count
		issue_slug_count=$(echo "$normalized_issues" | jq 'keys | length' 2>/dev/null) || issue_slug_count=0
		_OWNER_CACHE_WRITES=$((_OWNER_CACHE_WRITES + issue_slug_count))
		_log "issues refresh for owner=${owner}: ${issue_slug_count} slug caches written"
	fi
	return 0
}

# Fetch and cache PRs for a single owner.
# Sets _OWNER_SEARCH_CALLS, _OWNER_CACHE_WRITES, _OWNER_ERRORS
# Arguments: $1=owner  $2=slugs (comma-separated owner/repo list for REST fallback)
#            $3=graphql_remaining (optional pre-computed integer; pass to avoid redundant
#                                  rate-limit API calls when iterating over many owners)
_refresh_owner_prs() {
	local owner="$1"
	local slugs="${2:-}"
	local graphql_remaining="${3:-}"
	if _conditional_rest_per_slug prs "$slugs"; then
		_log "conditional REST prs complete for owner=${owner} — skipped search"
		return 0
	fi
	if _search_should_route_to_rest "$graphql_remaining"; then
		_route_owner_search_to_rest prs "$owner" "$slugs"
		return 0
	fi
	# Proactive REST fallback (t2902): same pattern as _refresh_owner_issues.
	# Pass pre-computed remaining to avoid a redundant rate-limit API call per owner.
	if _rest_should_fallback "$graphql_remaining" 2>/dev/null; then
		_log "GraphQL <= threshold — skipping gh search prs for owner=${owner}, going straight to REST"
		declare -F gh_record_call >/dev/null && gh_record_call search-rest pulse_batch_prefetch_search_prs_fallback || true
		_prefetch_rest_per_slug prs "$slugs"
		return 0
	fi
	declare -F gh_record_call >/dev/null && gh_record_call search-graphql pulse_batch_prefetch_search_prs || true
	local pr_err
	pr_err=$(mktemp)
	local pr_json=""
	pr_json=$(_prefetch_gh_read gh search prs --owner "$owner" --state open \
		--limit "$BATCH_SEARCH_LIMIT" \
		--json number,title,labels,updatedAt,assignees,repository,createdAt,author 2>"$pr_err") || pr_json=""
	_OWNER_SEARCH_CALLS=$((_OWNER_SEARCH_CALLS + 1))

	if [[ -z "$pr_json" || "$pr_json" == "$_JSON_NULL" ]]; then
		local pr_err_msg
		pr_err_msg=$(cat "$pr_err" 2>/dev/null || echo "unknown error")
		if _is_search_rate_limited "$pr_err"; then
			_log "Search/GraphQL rate-limited during PR fetch for owner=${owner} — falling back to per-repo REST"
			rm -f "$pr_err"
			# Reactive REST fallback: iterate per-slug via core REST bucket.
			_prefetch_rest_per_slug prs "$slugs"
			return 0
		else
			_log "gh search prs failed for owner=${owner}: ${pr_err_msg}"
		fi
		_OWNER_ERRORS=$((_OWNER_ERRORS + 1))
		rm -f "$pr_err"
		return 1
	fi
	rm -f "$pr_err"

	local normalized_prs
	normalized_prs=$(echo "$pr_json" | _normalize_search_to_prefetch_schema "$_KIND_PRS")
	if [[ -n "$normalized_prs" && "$normalized_prs" != "$_JSON_NULL" && "$normalized_prs" != "$_JSON_EMPTY_OBJ" ]]; then
		_write_per_slug_caches "$_KIND_PRS" "$normalized_prs"
		local pr_slug_count
		pr_slug_count=$(echo "$normalized_prs" | jq 'keys | length' 2>/dev/null) || pr_slug_count=0
		_OWNER_CACHE_WRITES=$((_OWNER_CACHE_WRITES + pr_slug_count))
		_log "prs refresh for owner=${owner}: ${pr_slug_count} slug caches written"
	fi
	return 0
}

_record_events_tickle_stats() {
	if ! declare -F pulse_stats_increment >/dev/null 2>&1; then
		return 0
	fi
	local _fi=0
	while [[ "$_fi" -lt "$_PULSE_EVENTS_TICKLE_FRESH" ]]; do
		pulse_stats_increment "pulse_events_tickle_fresh" 2>/dev/null || true
		_fi=$((_fi + 1))
	done
	local _si=0
	while [[ "$_si" -lt "$_PULSE_EVENTS_TICKLE_STALE" ]]; do
		pulse_stats_increment "pulse_events_tickle_stale" 2>/dev/null || true
		_si=$((_si + 1))
	done
	return 0
}

# =============================================================================
# Subcommand: refresh
# =============================================================================
_cmd_refresh() {
	_check_enabled || {
		_log "batch prefetch disabled (PULSE_BATCH_PREFETCH_ENABLED=0)"
		return 0
	}

	[[ -f "$REPOS_JSON" ]] || {
		_log "repos.json not found at ${REPOS_JSON} — skipping batch prefetch"
		return 1
	}

	mkdir -p "$BATCH_CACHE_DIR" 2>/dev/null || true
	_BATCH_SNAPSHOT_GENERATION="$(date -u +%Y%m%dT%H%M%SZ)-$$"

	local owner_groups
	owner_groups=$(_group_repos_by_owner "$REPOS_JSON") || {
		_log "failed to group repos by owner"
		return 1
	}

	if [[ -z "$owner_groups" ]]; then
		_log "no pulse-enabled repos found — nothing to prefetch"
		return 0
	fi
	_conditional_rest_capture_initial_markers "$owner_groups"

	# Shared counters updated by _refresh_owner_issues/_refresh_owner_prs
	_OWNER_SEARCH_CALLS=0
	_OWNER_CACHE_WRITES=0
	_OWNER_ERRORS=0
	_OWNER_CONDITIONAL_304=0
	_OWNER_CONDITIONAL_REFRESHES=0
	_OWNER_CONDITIONAL_MISSES=0

	# Pre-fetch GraphQL remaining once per refresh cycle (t2902 review followup).
	# Both _refresh_owner_issues and _refresh_owner_prs call _rest_should_fallback,
	# which issues a `gh api rate_limit` call when no pre-computed value is supplied.
	# With N owners that produces 2×N redundant API calls. Fetch here and pass the
	# integer down so each per-owner function can reuse it without hitting the API again.
	# Fail-open: if the fetch fails, an empty string is passed and the per-owner functions
	# fall back to their own rate-limit call (the existing behaviour).
	local _graphql_remaining=""
	declare -F gh_record_call >/dev/null && gh_record_call rest pulse_batch_prefetch_rate_limit || true
	_graphql_remaining=$(_prefetch_gh_read gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null) || _graphql_remaining=""

	# L1 tickle counters — reset per refresh cycle (module globals from
	# pulse-events-tickle.sh; may already be 0 if sourced fresh, but
	# explicit reset ensures correct totals when _cmd_refresh is called
	# multiple times within the same process).
	_PULSE_EVENTS_TICKLE_FRESH=0
	_PULSE_EVENTS_TICKLE_STALE=0

	local owner="" slugs=""
	while IFS='|' read -r owner slugs; do
		[[ -n "$owner" ]] || continue

		# L1 events ETag tickle (t2830, GH#20868): cheap conditional GET
		# via REST core bucket. On 304 (ETag unchanged), skip the 2 Search
		# API calls for this owner entirely. On error (exit 2), fail-open
		# and let the normal batch search proceed.
		local _tickle_rc=0
		events_tickle "$owner" || _tickle_rc=$?
		if [[ "$_tickle_rc" -eq 0 ]]; then
			_log "events tickle fresh for owner=${owner} — skipping search calls"
			continue
		fi

		_refresh_owner_issues "$owner" "$slugs" "$_graphql_remaining" || true
		_refresh_owner_prs "$owner" "$slugs" "$_graphql_remaining" || true
	done <<<"$owner_groups"

	_log "refresh complete: search_calls=${_OWNER_SEARCH_CALLS} cache_writes=${_OWNER_CACHE_WRITES} errors=${_OWNER_ERRORS} tickle_fresh=${_PULSE_EVENTS_TICKLE_FRESH} tickle_stale=${_PULSE_EVENTS_TICKLE_STALE} conditional_304=${_OWNER_CONDITIONAL_304} conditional_refreshes=${_OWNER_CONDITIONAL_REFRESHES} conditional_misses=${_OWNER_CONDITIONAL_MISSES}"

	# The completed Pulse cycle owns report/sidecar publication and retention.
	# A partial prefetch must not overwrite its bounded coverage with a later
	# cutoff. Standalone diagnostics use gh-api-instrument.sh report instead.

	# Record tickle counters to pulse-stats.json (one timestamp entry per
	# fresh/stale owner). Fail-open: pulse_stats_increment is sourced from
	# pulse-stats-helper.sh above; if it was not sourced, the declare -F
	# guard is a no-op and the batch search continues unaffected.
	_record_events_tickle_stats

	# Export counters for health instrumentation (parsed by _prefetch_batch_refresh
	# in pulse-prefetch.sh and added to per-cycle health totals).
	echo "search_calls=${_OWNER_SEARCH_CALLS}"
	echo "cache_writes=${_OWNER_CACHE_WRITES}"
	echo "errors=${_OWNER_ERRORS}"
	echo "events_tickle_fresh=${_PULSE_EVENTS_TICKLE_FRESH}"
	echo "events_tickle_stale=${_PULSE_EVENTS_TICKLE_STALE}"
	echo "conditional_304=${_OWNER_CONDITIONAL_304}"
	echo "conditional_refreshes=${_OWNER_CONDITIONAL_REFRESHES}"
	echo "conditional_misses=${_OWNER_CONDITIONAL_MISSES}"
	return 0
}

# Resolve a cache snapshot to one canonical state without printing payload data.
# Sets _CACHE_SNAPSHOT_STATE and _CACHE_SNAPSHOT_PATH for Bash 3.2 callers.
_resolve_cache_snapshot() {
	local kind="$1"
	local slug="$2"
	local cache_file=""
	local cache_ts=""
	local cache_epoch=0
	local now_epoch=0
	local age=0
	local invalidation_generation=""
	local stored_invalidation_generation=""

	_CACHE_SNAPSHOT_STATE="missing"
	_CACHE_SNAPSHOT_PATH=""
	if ! _check_enabled; then
		_CACHE_SNAPSHOT_STATE="disabled"
		return 1
	fi

	cache_file=$(_cache_file_path "$kind" "$slug")
	_CACHE_SNAPSHOT_PATH="$cache_file"
	[[ -f "$cache_file" ]] || return 1
	invalidation_generation="$(_snapshot_invalidation_generation "$kind" "$slug")" || {
		_CACHE_SNAPSHOT_STATE="$_CACHE_STATE_INVALIDATED"
		return 1
	}
	stored_invalidation_generation=$(jq -er --arg initial "$_BATCH_INVALIDATION_INITIAL" \
		'.invalidation_generation // $initial' "$cache_file" 2>/dev/null) || {
		_CACHE_SNAPSHOT_STATE="$_CACHE_STATE_MALFORMED"
		return 1
	}
	if [[ "$stored_invalidation_generation" != "$invalidation_generation" ]]; then
		_CACHE_SNAPSHOT_STATE="$_CACHE_STATE_INVALIDATED"
		return 1
	fi

	cache_ts=$(jq -er '
		select((.timestamp | type) == "string" and (.timestamp | length) > 0) |
		select((.items | type) == "array") |
		.timestamp
	' "$cache_file" 2>/dev/null) || {
		_CACHE_SNAPSHOT_STATE="$_CACHE_STATE_MALFORMED"
		return 1
	}

	if [[ "$(uname)" == "Darwin" ]]; then
		cache_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$cache_ts" "+%s" 2>/dev/null) || cache_epoch=0
	else
		cache_epoch=$(date -u -d "$cache_ts" +%s 2>/dev/null) || cache_epoch=0
	fi
	now_epoch=$(date -u +%s) || now_epoch=0
	if [[ "$cache_epoch" -le 0 || "$now_epoch" -le 0 ]]; then
		_CACHE_SNAPSHOT_STATE="$_CACHE_STATE_MALFORMED"
		return 1
	fi

	age=$((now_epoch - cache_epoch))
	if [[ "$age" -lt 0 ]]; then
		_CACHE_SNAPSHOT_STATE="$_CACHE_STATE_MALFORMED"
		return 1
	fi
	if [[ "$age" -ge "$PULSE_PREFETCH_FULL_SWEEP_INTERVAL" ]]; then
		_CACHE_SNAPSHOT_STATE="stale"
		return 1
	fi

	_CACHE_SNAPSHOT_STATE="hit"
	return 0
}

_record_cache_state_evidence() {
	local state="$1"
	local cardinality="${2:-$_CACHE_CARDINALITY_UNKNOWN}"
	declare -F gh_record_efficiency_evidence >/dev/null 2>&1 || return 0
	case "$state" in
	hit)
		if [[ "$cardinality" == "$_CACHE_CARDINALITY_EMPTY" ]]; then
			gh_record_efficiency_evidence cache.fresh_empty_hits 1 2>/dev/null || true
		else
			gh_record_efficiency_evidence cache.fresh_hits 1 2>/dev/null || true
		fi
		;;
	stale | malformed | incompatible)
		gh_record_efficiency_evidence cache.misses 1 2>/dev/null || true
		gh_record_efficiency_evidence cache.stale 1 2>/dev/null || true
		gh_record_efficiency_evidence guardrails.stale_snapshot_detections 1 2>/dev/null || true
		gh_record_efficiency_evidence guardrails.forced_live_refreshes 1 2>/dev/null || true
		;;
	invalidated)
		gh_record_efficiency_evidence cache.misses 1 2>/dev/null || true
		gh_record_efficiency_evidence cache.invalidated 1 2>/dev/null || true
		gh_record_efficiency_evidence guardrails.forced_live_refreshes 1 2>/dev/null || true
		;;
	missing | disabled)
		gh_record_efficiency_evidence cache.misses 1 2>/dev/null || true
		gh_record_efficiency_evidence guardrails.forced_live_refreshes 1 2>/dev/null || true
		;;
	esac
	return 0
}

_emit_cache_state() {
	local state="$1"
	local kind="$2"
	local slug="$3"
	local cardinality="${4:-$_CACHE_CARDINALITY_UNKNOWN}"
	_record_cache_state_evidence "$state" "$cardinality"
	printf 'cache_state=%s kind=%s slug=%s cardinality=%s\n' \
		"$state" "$kind" "$slug" "$cardinality" >&2
	return 0
}

# =============================================================================
# Subcommand: cache-path
# =============================================================================
_cmd_cache_path() {
	local kind=""
	local slug=""
	local _args=("$@")
	local _i=0
	while [[ $_i -lt ${#_args[@]} ]]; do
		case "${_args[$_i]}" in
		--kind)
			kind="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		--slug)
			slug="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		*)
			_i=$((_i + 1))
			;;
		esac
	done

	if [[ -z "$kind" || -z "$slug" ]]; then
		echo "Usage: pulse-batch-prefetch-helper.sh cache-path --kind issues|prs --slug owner/repo" >&2
		return 1
	fi

	case "$kind" in
	"$_KIND_ISSUES" | "$_KIND_PRS") ;;
	*)
		echo "Usage: pulse-batch-prefetch-helper.sh cache-path --kind issues|prs --slug owner/repo" >&2
		return 1
		;;
	esac

	_resolve_cache_snapshot "$kind" "$slug" || return 1
	printf '%s\n' "$_CACHE_SNAPSHOT_PATH"
	return 0
}

# =============================================================================
# Subcommand: read-cache
# Read normalized items from a batch cache file for a given slug+kind.
# Used by pulse-prefetch integration to read batch data without making API calls.
# Arguments: --kind issues|prs --slug owner/repo
# Output: JSON array of items on stdout, exit 1 on miss/stale
# =============================================================================
_cmd_read_cache() {
	local kind=""
	local slug=""
	local _args=("$@")
	local _i=0
	while [[ $_i -lt ${#_args[@]} ]]; do
		case "${_args[$_i]}" in
		--kind)
			kind="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		--slug)
			slug="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		*)
			_i=$((_i + 1))
			;;
		esac
	done

	if [[ -z "$kind" || -z "$slug" ]]; then
		echo "Usage: pulse-batch-prefetch-helper.sh read-cache --kind issues|prs --slug owner/repo" >&2
		return 1
	fi

	case "$kind" in
	"$_KIND_ISSUES" | "$_KIND_PRS") ;;
	*)
		echo "Usage: pulse-batch-prefetch-helper.sh read-cache --kind issues|prs --slug owner/repo" >&2
		return 1
		;;
	esac

	if ! _resolve_cache_snapshot "$kind" "$slug"; then
		_emit_cache_state "$_CACHE_SNAPSHOT_STATE" "$kind" "$slug"
		return 1
	fi

	local items=""

	if [[ "$kind" == "$_KIND_ISSUES" ]]; then
		items=$(jq -ce --arg state_open "$_STATE_OPEN" --arg type_string "$_JSON_TYPE_STRING" \
			'select(all(.items[]; (.body | type) == $type_string)) |
			[.items[] | select(has("state") and ((.state | ascii_downcase) == $state_open))]' \
			"$_CACHE_SNAPSHOT_PATH" 2>/dev/null) || {
			_CACHE_SNAPSHOT_STATE="$_CACHE_STATE_MALFORMED"
			_emit_cache_state "$_CACHE_SNAPSHOT_STATE" "$kind" "$slug"
			return 1
		}
	else
		items=$(jq -ce '.items' "$_CACHE_SNAPSHOT_PATH" 2>/dev/null) || {
			_CACHE_SNAPSHOT_STATE="$_CACHE_STATE_MALFORMED"
			_emit_cache_state "$_CACHE_SNAPSHOT_STATE" "$kind" "$slug"
			return 1
		}
	fi

	local cardinality="nonempty"
	[[ "$items" == "$_JSON_EMPTY_ARR" ]] && cardinality="$_CACHE_CARDINALITY_EMPTY"
	_emit_cache_state "$_CACHE_SNAPSHOT_STATE" "$kind" "$slug" "$cardinality"
	printf '%s\n' "$items"
	return 0
}

# =============================================================================
# Subcommand: read-snapshot
# Read a versioned canonical envelope. Legacy caches remain valid for read-cache
# but cannot authorize state-fingerprint hits through this stricter interface.
# =============================================================================
_cmd_read_snapshot() {
	local kind=""
	local slug=""
	local _args=("$@")
	local _i=0
	while [[ $_i -lt ${#_args[@]} ]]; do
		case "${_args[$_i]}" in
		--kind)
			kind="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		--slug)
			slug="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		*) _i=$((_i + 1)) ;;
		esac
	done

	local projection=""
	projection=$(_snapshot_projection "$kind") || {
		echo "Usage: pulse-batch-prefetch-helper.sh read-snapshot --kind issues|prs --slug owner/repo" >&2
		return 1
	}
	[[ -n "$slug" ]] || {
		echo "Usage: pulse-batch-prefetch-helper.sh read-snapshot --kind issues|prs --slug owner/repo" >&2
		return 1
	}

	if ! _resolve_cache_snapshot "$kind" "$slug"; then
		_emit_cache_state "$_CACHE_SNAPSHOT_STATE" "$kind" "$slug"
		return 1
	fi

	local envelope=""
	envelope=$(jq -ce \
		--arg schema "$_SNAPSHOT_SCHEMA" --arg slug "$slug" --arg kind "$kind" \
		--arg projection "$projection" --arg auth_scope "$_BATCH_SNAPSHOT_AUTH_SCOPE" \
		--arg type_array "$_JSON_TYPE_ARRAY" --arg type_boolean "$_JSON_TYPE_BOOLEAN" \
		--arg type_string "$_JSON_TYPE_STRING" '
		select(.schema == $schema and .repository == $slug and .collection == $kind) |
		select(.projection == $projection and .auth_scope == $auth_scope) |
		select((.generation | type) == $type_string and (.generation | length) > 0) |
		select((.source | type) == $type_string and (.source | length) > 0) |
		select((.fetched_at | type) == $type_string and (.fetched_at | length) > 0) |
		select((.complete | type) == $type_boolean and (.items | type) == $type_array) |
		if $kind == "issues" then
			select(all(.items[];
				(.number | type) == "number" and has("title") and
				(.state | type) == $type_string and (.labels | type) == $type_array and
				has("updatedAt") and (.assignees | type) == $type_array and
				(.body | type) == $type_string)) |
			.items = [.items[] | select((.state | ascii_downcase) == "open")]
		else
			select(all(.items[];
				(.number | type) == "number" and has("title") and
				(.labels | type) == $type_array and has("updatedAt") and
				(.assignees | type) == $type_array and has("createdAt") and
				has("author") and (.headRefOid | type) == $type_string and
				(.headRefOid | length) > 0 and has("headRefName")))
		end
	' "$_CACHE_SNAPSHOT_PATH" 2>/dev/null) || {
		_CACHE_SNAPSHOT_STATE="incompatible"
		_emit_cache_state "$_CACHE_SNAPSHOT_STATE" "$kind" "$slug"
		return 1
	}

	local cardinality="nonempty"
	[[ "$(printf '%s' "$envelope" | jq -c '.items')" == "$_JSON_EMPTY_ARR" ]] && cardinality="$_CACHE_CARDINALITY_EMPTY"
	_emit_cache_state "$_CACHE_SNAPSHOT_STATE" "$kind" "$slug" "$cardinality"
	printf '%s\n' "$envelope"
	return 0
}

# =============================================================================
# Subcommand: evict-issue
# Remove a single issue from the normalized owner/repo issues cache.
# Arguments: owner/repo issue_number
# =============================================================================
_cmd_evict_issue() {
	local slug="$1"
	local issue_number="$2"

	if [[ -z "$slug" || -z "$issue_number" ]]; then
		echo "Usage: pulse-batch-prefetch-helper.sh evict-issue owner/repo issue_number" >&2
		return 1
	fi

	_check_enabled || return 0

	local cache_file
	cache_file=$(_cache_file_path "$_KIND_ISSUES" "$slug")
	if [[ ! -f "$cache_file" ]]; then
		return 0
	fi

	local tmp_file
	tmp_file=$(mktemp "${BATCH_CACHE_DIR}/.evict-snapshot.XXXXXX") || return 1
	if jq --argjson issue_number "$issue_number" '
		(.items // []) as $items |
		.items = [$items[] | select((.number // 0) != $issue_number)] |
		.complete = false |
		.truncated = true |
		.source = "local-eviction"
	' "$cache_file" >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$cache_file"
		_log "evicted issue #${issue_number} from issues cache for ${slug}"
		return 0
	fi

	rm -f "$tmp_file"
	_log "failed to evict issue #${issue_number} from issues cache for ${slug}"
	return 1
}

# =============================================================================
# Subcommand: invalidate-collection
# Advance the canonical request generation before removing one repository cache.
# =============================================================================
_cmd_invalidate_collection() {
	local kind=""
	local slug=""
	local request_key=""
	local cache_file=""
	local _args=("$@")
	local _i=0
	while [[ $_i -lt ${#_args[@]} ]]; do
		case "${_args[$_i]}" in
		--kind)
			kind="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		--slug)
			slug="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		*) _i=$((_i + 1)) ;;
		esac
	done
	case "$kind" in
	"$_KIND_ISSUES" | "$_KIND_PRS") ;;
	*) return 1 ;;
	esac
	[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	request_key="$(_snapshot_invalidation_key "$kind" "$slug")" || return 1
	declare -F gh_request_state_invalidate >/dev/null 2>&1 || return 1
	gh_request_state_invalidate "$request_key" || return 1
	cache_file=$(_cache_file_path "$kind" "$slug")
	rm -f "$cache_file" || return 1
	_log "invalidated canonical ${kind} snapshot for ${slug}"
	gh_request_state_invalidation_generation_get "$request_key" || return 1
	return 0
}

# =============================================================================
# Subcommand: clear
# =============================================================================
_cmd_clear() {
	if [[ -d "$BATCH_CACHE_DIR" ]]; then
		rm -rf "${BATCH_CACHE_DIR:?}"/*
		_log "batch cache cleared"
		echo "Batch cache cleared: ${BATCH_CACHE_DIR}"
	else
		echo "No batch cache directory found at ${BATCH_CACHE_DIR}"
	fi
	return 0
}

# =============================================================================
# Subcommand: status
# =============================================================================
_cmd_status() {
	if [[ ! -d "$BATCH_CACHE_DIR" ]]; then
		echo "No batch cache directory at ${BATCH_CACHE_DIR}"
		return 0
	fi

	local cache_files
	cache_files=$(find "$BATCH_CACHE_DIR" -name "*.json" -type f 2>/dev/null | sort)

	if [[ -z "$cache_files" ]]; then
		echo "No cache files found in ${BATCH_CACHE_DIR}"
		return 0
	fi

	local now_epoch
	now_epoch=$(date -u +%s)
	local ttl="$PULSE_PREFETCH_FULL_SWEEP_INTERVAL"

	echo "Batch prefetch cache status (TTL=${ttl}s, enabled=${PULSE_BATCH_PREFETCH_ENABLED})"
	echo "---"

	local file
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local basename
		basename=$(basename "$file" .json)
		local ts="" item_count="" age_s=0 freshness=""
		ts=$(jq -r '.timestamp // "unknown"' "$file" 2>/dev/null) || ts="unknown"
		item_count=$(jq '.items | length' "$file" 2>/dev/null) || item_count="?"

		if [[ "$ts" != "unknown" ]]; then
			local cache_epoch
			if [[ "$(uname)" == "Darwin" ]]; then
				cache_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null) || cache_epoch=0
			else
				cache_epoch=$(date -u -d "$ts" +%s 2>/dev/null) || cache_epoch=0
			fi
			age_s=$((now_epoch - cache_epoch))
			if [[ "$age_s" -lt "$ttl" ]]; then
				freshness="FRESH (${age_s}s old)"
			else
				freshness="STALE (${age_s}s old, TTL=${ttl}s)"
			fi
		else
			freshness="UNKNOWN"
		fi

		echo "  ${basename}: ${item_count} items, ${freshness}, ts=${ts}"
	done <<<"$cache_files"

	return 0
}

# =============================================================================
# Main dispatcher
# =============================================================================
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	refresh)
		_cmd_refresh
		;;
	cache-path)
		_cmd_cache_path "$@"
		;;
	read-cache)
		_cmd_read_cache "$@"
		;;
	read-snapshot)
		_cmd_read_snapshot "$@"
		;;
	invalidate-collection)
		_cmd_invalidate_collection "$@"
		;;
	evict-issue)
		_cmd_evict_issue "$@"
		;;
	clear)
		_cmd_clear
		;;
	status)
		_cmd_status
		;;
	help | --help | -h)
		echo "Usage: pulse-batch-prefetch-helper.sh <command> [options]"
		echo ""
		echo "Commands:"
		echo "  refresh                          Fetch all repos via org-level search and cache"
		echo "  cache-path --kind K --slug S     Return cache path if fresh, exit 1 if stale"
		echo "  read-cache --kind K --slug S     Read cached items as JSON array"
		echo "  read-snapshot --kind K --slug S  Read a canonical snapshot envelope"
		echo "  invalidate-collection --kind K --slug S  Invalidate one canonical collection"
		echo "  evict-issue owner/repo N         Remove one issue from the issues cache"
		echo "  clear                            Wipe batch cache directory"
		echo "  status                           Show cache file ages and counts"
		echo ""
		echo "Environment:"
		echo "  PULSE_BATCH_PREFETCH_ENABLED     Enable/disable (default: 1)"
		echo "  PULSE_BATCH_PREFETCH_CACHE_DIR   Cache directory"
		echo "  PULSE_BATCH_SEARCH_LIMIT         Max results per search call (default: 200)"
		echo "  PULSE_BATCH_SEARCH_LAST_RESORT   Route owner search through REST/cache by default (default: 1)"
		return 0
		;;
	*)
		echo "Unknown command: ${cmd}. Run with --help for usage." >&2
		return 1
		;;
	esac
}

main "$@"
