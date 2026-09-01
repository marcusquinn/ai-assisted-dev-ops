#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-prefetch-infra.sh — Rate-limit detection + Cache/sweep infrastructure
# =============================================================================
# Sub-library extracted from pulse-prefetch.sh (GH#19964).
# Covers two functional areas:
#   1. Rate-limit detection and marking (GH#18979 / t2097)
#   2. Cache and sweep-budget management (t2041)
#
# Usage: source "${SCRIPT_DIR}/pulse-prefetch-infra.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - Environment vars: PULSE_RATE_LIMIT_FLAG, LOGFILE, PULSE_PREFETCH_CACHE_FILE,
#     PULSE_PREFETCH_FULL_SWEEP_INTERVAL, PULSE_QUEUED_SCAN_LIMIT,
#     PULSE_SWEEP_TOKEN_BUDGET, PULSE_SWEEP_MAX_EVENTS_PER_PASS,
#     PULSE_SWEEP_DEFERRAL_PROMOTION_THRESHOLD, PULSE_SWEEP_CACHE_HIT_ENABLED
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_PREFETCH_INFRA_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_INFRA_LOADED=1

# Defensive SCRIPT_DIR fallback — caller (pulse-prefetch.sh) normally sets this,
# but test harnesses and direct sourcing may not.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# GH#18979 (t2097): Rate-limit detection helpers
#
# When GitHub's GraphQL budget is exhausted (5000/hr), `gh` commands return
# empty results with an error on stderr. The existing prefetch error handlers
# swallow this into a `"[]"` fallback, which makes the pulse run a full cycle
# on empty data while holding the instance lock ~3 min. These helpers detect
# rate-limit errors at each prefetch site, write a shared flag file, and let
# `_preflight_prefetch_and_scope` abort the cycle cleanly via its existing
# return-1 path.
#
# Non-rate-limit errors (network blips, 5xx) still fall back to `"[]"` and
# continue — only exhaustion, where empty data is indistinguishable from a
# quiet backlog, triggers the cycle abort.
# =============================================================================

#######################################
# Classify a gh CLI stderr blob as a rate-limit exhaustion error.
#
# gh surfaces GraphQL / REST budget exhaustion in several forms depending on
# which endpoint triggered it. This helper matches the common phrases
# case-insensitively. The list is intentionally narrow — false positives
# would turn transient network blips into cycle aborts.
#
# Arguments:
#   $1 - path to a stderr file captured from `gh` (typically via `2>"$err"`)
# Returns:
#   0 if stderr indicates rate-limit exhaustion
#   1 otherwise (file missing, empty, or unrelated error)
#######################################
_pulse_gh_err_is_rate_limit() {
	local err_file="$1"
	[[ -n "$err_file" && -s "$err_file" ]] || return 1
	grep -qiE 'API rate limit exceeded|rate limit exceeded for|was submitted too quickly|secondary rate limit|GraphQL: API rate limit|You have exceeded a secondary rate limit' "$err_file"
}

#######################################
# Verify live GraphQL-pool rate limit before committing to rate-limit abort.
#
# Cross-checks the classifier's signal against the zero-cost REST rate_limit
# resource instead of spending an unattributable GraphQL request. Defends
# against gh CLI cache poisoning (stale RATE_LIMIT response from a prior
# transient budget exhaustion) keeping the pulse stuck for hours.
#
# GH#19622: observed 2026-04-17 — a single 1322-byte poisoned cache file
# caused a 5h 32min pulse stall. Live GraphQL budget was 4898/5000 the
# entire time; the classifier had no way to tell.
#
# Returns:
#   0 if rate-limit signal is corroborated (remaining below threshold)
#   1 if signal appears stale (remaining healthy — suspected cache poison)
#
# Arguments:
#   $1 - remaining threshold below which the signal is trusted (default 100)
#######################################
_pulse_verify_rate_limit_live() {
	local threshold="${1:-100}"
	local remaining
	# Once a shared secondary cooldown is active, the corroboration probe is
	# itself nonessential read pressure. Trust the observed classifier signal
	# until the cooldown expires instead of producing another HTTP 403.
	if declare -F _gh_secondary_cooldown_preflight >/dev/null 2>&1; then
		_gh_secondary_cooldown_preflight read >/dev/null 2>&1 || return 0
	fi
	# The REST rate_limit resource does not hit the --label/--search cache.
	# Failure modes: network error, auth error — treat as "can't verify, trust classifier".
	remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null) || return 0
	[[ -z "$remaining" || ! "$remaining" =~ ^[0-9]+$ ]] && return 0
	[[ "$remaining" -lt "$threshold" ]] && return 0
	return 1
}

#######################################
# Mark the current cycle as rate-limited.
#
# Writes a timestamp + context line to the flag file. Idempotent — if the
# flag already exists from an earlier prefetch site in the same cycle,
# append the new context so postmortem logs show all affected sites.
# Also emits a loud, greppable log line at the site of detection.
#
# Arguments:
#   $1 - context string (function name + repo slug)
#######################################
_pulse_mark_rate_limited() {
	local context="$1"
	local ts
	# GH#19622: sanity-check before trusting classifier signal. Defends
	# against gh CLI cache poisoning where a stale RATE_LIMIT response
	# keeps pulse aborting for hours after actual budget reset.
	# _pulse_verify_rate_limit_live returns 1 when budget is healthy (suspected poison).
	if ! _pulse_verify_rate_limit_live 100; then
		echo "[pulse-wrapper] WARNING: rate-limit classifier matched for ${context} but live probe shows healthy budget — suspected gh cache poisoning, continuing cycle" >>"$LOGFILE"
		echo "[pulse-wrapper] HINT: check for poisoned cache entries with: find ~/.cache/gh -type f -exec grep -l graphql_rate_limit {} +" >>"$LOGFILE"
		return 0  # Do NOT set flag; let cycle continue.
	fi
	# Original behaviour: commit the flag.
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	mkdir -p "$(dirname "$PULSE_RATE_LIMIT_FLAG")" 2>/dev/null || true
	printf '%s %s\n' "$ts" "$context" >>"$PULSE_RATE_LIMIT_FLAG"
	echo "[pulse-wrapper] GraphQL RATE_LIMIT_EXHAUSTED during ${context}" >>"$LOGFILE"
	return 0
}

#######################################
# Check whether a complete repo cache proves that no issue has a given label.
# Used by NMR and needs-info scans to skip only proven-zero repositories.
#
# Arguments:
#   $1 - repo slug
#   $2 - label name to check for
# Returns:
#   0 if a valid complete cache has exactly 0 matches (safe to skip)
#   1 if matches exist or cache evidence is absent, invalid, or incomplete
#######################################
_prefetch_cached_label_count_is_zero() {
	local slug="$1"
	local label="$2"
	local cache_entry=""
	local cached_count=""

	[[ -n "$slug" && -n "$label" ]] || return 1
	cache_entry=$(_prefetch_cache_get "$slug" 2>/dev/null) || return 1
	[[ -n "$cache_entry" ]] || return 1
	cached_count=$(printf '%s\n' "$cache_entry" | jq -er --arg label "$label" '
		"object" as $object_type | "array" as $array_type | "string" as $string_type
		| select(type == $object_type and .snapshot_complete == true)
		| .issues
		| select(type == $array_type and all(.[];
			type == $object_type and (.labels | type) == $array_type
			and all(.labels[]; type == $object_type and (.name | type) == $string_type)))
		| [.[] | select(.labels | map(.name) | index($label))] | length
	' 2>/dev/null) || return 1
	[[ "$cached_count" == "0" ]] && return 0
	return 1
}

# =============================================================================
# t2041: Budget-aware LLM sweep — state fingerprint, hygiene anomalies,
# cache-hit detection. See .agents/reference/pulse-llm-budget.md and
# .agents/configs/pulse-sweep-budget.json for the design contract.
# =============================================================================

# Default token budget values. These are the fallback when
# .agents/configs/pulse-sweep-budget.json is unavailable or missing
# keys — `_load_pulse_sweep_budget_config` overlays the JSON values.
: "${PULSE_SWEEP_TOKEN_BUDGET:=3000}"
: "${PULSE_SWEEP_MAX_EVENTS_PER_PASS:=50}"
: "${PULSE_SWEEP_DEFERRAL_PROMOTION_THRESHOLD:=3}"
: "${PULSE_SWEEP_CACHE_HIT_ENABLED:=true}"

_PREFETCH_SNAPSHOT_SCHEMA="aidevops-pulse-snapshot/v1"
_PREFETCH_ISSUES_PROJECTION="number,title,state,labels,updatedAt,assignees,body,authorAssociation,author"
_PREFETCH_PRS_PROJECTION="number,title,labels,updatedAt,assignees,createdAt,author,headRefOid,headRefName"
_PREFETCH_FINGERPRINT_SCHEMA="canonical-snapshot-v1"

#######################################
# Hash stdin with SHA-256 without exposing repository identities.
#######################################
_prefetch_sha256_stdin() {
	local hash=""
	if command -v shasum >/dev/null 2>&1; then
		hash=$(shasum -a 256 2>/dev/null | awk '{print $1}') || hash=""
	elif command -v sha256sum >/dev/null 2>&1; then
		hash=$(sha256sum 2>/dev/null | awk '{print $1}') || hash=""
	fi
	[[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$hash"
	return 0
}

#######################################
# Record the active repository population using count + opaque set digest.
# Arguments: $1=newline-delimited slug|path entries
#######################################
_prefetch_record_efficiency_population() {
	local repo_entries="$1"
	local repo_slugs=""
	local repo_count=""
	local repo_set_hash=""
	declare -F gh_record_efficiency_evidence >/dev/null 2>&1 || return 0
	repo_slugs=$(printf '%s\n' "$repo_entries" | awk -F'|' 'NF && $1 != "" {print $1}' | LC_ALL=C sort -u) || return 0
	repo_count=$(printf '%s\n' "$repo_slugs" | awk 'NF {count++} END {print count + 0}') || return 0
	[[ "$repo_count" =~ ^[0-9]+$ && "$repo_count" -gt 0 ]] || return 0
	repo_set_hash=$(printf '%s\n' "$repo_slugs" | _prefetch_sha256_stdin) || return 0
	gh_record_efficiency_evidence population.repository_count "$repo_count" 2>/dev/null || true
	gh_record_efficiency_evidence population.repository_set_sha256 "$repo_set_hash" 2>/dev/null || true
	return 0
}

# Load the budget config once per process. Called lazily from the t2041
# helpers. Reads `.agents/configs/pulse-sweep-budget.json` relative to
# the aidevops repo deploy. Per-repo overrides override default values;
# falls back to existing env vars on any read failure (fail-open).
_PULSE_SWEEP_BUDGET_LOADED="${_PULSE_SWEEP_BUDGET_LOADED:-false}"
_load_pulse_sweep_budget_config() {
	[[ "$_PULSE_SWEEP_BUDGET_LOADED" == "true" ]] && return 0
	_PULSE_SWEEP_BUDGET_LOADED=true

	local config_file=""
	# Prefer deployed path (runtime). Fall back to repo path (tests).
	if [[ -f "${HOME}/.aidevops/agents/configs/pulse-sweep-budget.json" ]]; then
		config_file="${HOME}/.aidevops/agents/configs/pulse-sweep-budget.json"
	elif [[ -n "${AIDEVOPS_REPO_ROOT:-}" && -f "${AIDEVOPS_REPO_ROOT}/.agents/configs/pulse-sweep-budget.json" ]]; then
		config_file="${AIDEVOPS_REPO_ROOT}/.agents/configs/pulse-sweep-budget.json"
	fi
	[[ -f "$config_file" ]] || return 0
	jq empty "$config_file" 2>/dev/null || return 0

	local _v
	_v=$(jq -r '.default.token_budget // empty' "$config_file" 2>/dev/null)
	[[ "$_v" =~ ^[0-9]+$ ]] && PULSE_SWEEP_TOKEN_BUDGET="$_v"
	_v=$(jq -r '.default.max_events_per_pass // empty' "$config_file" 2>/dev/null)
	[[ "$_v" =~ ^[0-9]+$ ]] && PULSE_SWEEP_MAX_EVENTS_PER_PASS="$_v"
	_v=$(jq -r '.default.deferral_promotion_threshold // empty' "$config_file" 2>/dev/null)
	[[ "$_v" =~ ^[0-9]+$ ]] && PULSE_SWEEP_DEFERRAL_PROMOTION_THRESHOLD="$_v"
	_v=$(jq -r '.default.state_fingerprint_cache_hit_enabled // empty' "$config_file" 2>/dev/null)
	[[ "$_v" == "true" || "$_v" == "false" ]] && PULSE_SWEEP_CACHE_HIT_ENABLED="$_v"

	return 0
}

#######################################
# Return 0 only when two canonical collection snapshots form one complete,
# projection-compatible repository generation.
# Arguments: $1=slug, $2=issue snapshot envelope, $3=PR snapshot envelope
#######################################
_canonical_snapshot_pair_complete() {
	local slug="$1"
	local issues_snapshot="$2"
	local prs_snapshot="$3"
	[[ -n "$slug" && -n "$issues_snapshot" && -n "$prs_snapshot" ]] || return 1

	local issues_identity="" prs_identity=""
	issues_identity=$(printf '%s' "$issues_snapshot" | jq -er \
		--arg schema "$_PREFETCH_SNAPSHOT_SCHEMA" --arg slug "$slug" \
		--arg projection "$_PREFETCH_ISSUES_PROJECTION" '
		select(.schema == $schema and .repository == $slug and .collection == "issues") |
		select(.projection == $projection and .complete == true and (.items | type) == "array") |
		select(all(.items[];
			(.number | type) == "number" and (.state | type) == "string" and
			(.labels | type) == "array" and (.assignees | type) == "array" and
			(.body | type) == "string" and
			(.authorAssociation | type) == "string" and has("updatedAt"))) |
		select((.source | type) == "string" and (.fetched_at | type) == "string") |
		[.generation, .auth_scope] | select(all(.[]; type == "string" and length > 0)) | @tsv
	' 2>/dev/null) || return 1
	prs_identity=$(printf '%s' "$prs_snapshot" | jq -er \
		--arg schema "$_PREFETCH_SNAPSHOT_SCHEMA" --arg slug "$slug" \
		--arg projection "$_PREFETCH_PRS_PROJECTION" '
		select(.schema == $schema and .repository == $slug and .collection == "prs") |
		select(.projection == $projection and .complete == true and (.items | type) == "array") |
		select(all(.items[];
			(.number | type) == "number" and (.labels | type) == "array" and
			(.assignees | type) == "array" and has("updatedAt") and
			(.headRefOid | type) == "string" and (.headRefOid | length) > 0)) |
		select((.source | type) == "string" and (.fetched_at | type) == "string") |
		[.generation, .auth_scope] | select(all(.[]; type == "string" and length > 0)) | @tsv
	' 2>/dev/null) || return 1
	if [[ "$issues_identity" == "$prs_identity" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Compute a short deterministic fingerprint from one canonical snapshot pair.
#
# The fingerprint is a SHA-256 of the canonicalized set of:
#   - issues: (number, labels_sorted, assignees_sorted, updatedAt)
#   - PRs:    (number, labels_sorted, assignees_sorted, updatedAt, headRefOid)
# across all open issues and PRs. GraphQL-only projections remain on the exact
# PR-list provider; this normalized fingerprint never fabricates those fields.
# Final dispatch and merge authority remains live and fail-closed.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - canonical issue snapshot envelope
#   $3 - canonical PR snapshot envelope
# Outputs:
#   16-char hex fingerprint on stdout, empty string on error
# Returns: 0 always (empty forces the full-analysis path)
#######################################
_compute_repo_state_fingerprint() {
	local slug="$1"
	local issues_snapshot="${2:-}"
	local prs_snapshot="${3:-}"
	[[ -n "$slug" ]] || {
		echo ""
		return 0
	}
	_canonical_snapshot_pair_complete "$slug" "$issues_snapshot" "$prs_snapshot" || {
		echo ""
		return 0
	}

	# Canonicalize both lists. The PR/issue arrays can exceed Linux
	# MAX_ARG_STRLEN, so pass their envelopes through files instead of jq argv.
	local canon
	local issues_file="" prs_file=""
	issues_file=$(mktemp) || {
		echo ""
		return 0
	}
	prs_file=$(mktemp) || {
		rm -f "$issues_file"
		echo ""
		return 0
	}
	if ! printf '%s' "$issues_snapshot" >"$issues_file"; then
		rm -f "$issues_file" "$prs_file"
		echo ""
		return 0
	fi
	if ! printf '%s' "$prs_snapshot" >"$prs_file"; then
		rm -f "$issues_file" "$prs_file"
		echo ""
		return 0
	fi
	canon=$(jq -cSn \
		--slurpfile issues "$issues_file" \
		--slurpfile prs "$prs_file" '
		($issues[0].items // []) as $issues |
		($prs[0].items // []) as $prs |
		{
			issues: ($issues | sort_by(.number) | map({
				n: .number,
				l: ([.labels[].name] | sort),
				a: ([.assignees[].login] | sort),
				u: .updatedAt
			})),
			prs: ($prs | sort_by(.number) | map({
				n: .number,
				l: ([.labels[].name] | sort),
				a: ([.assignees[].login] | sort),
				u: .updatedAt,
				h: .headRefOid
			}))
		}
	' 2>/dev/null) || canon=""
	rm -f "$issues_file" "$prs_file"
	[[ -n "$canon" ]] || {
		echo ""
		return 0
	}

	# SHA-256 truncated to 16 chars.
	local hash
	if command -v shasum >/dev/null 2>&1; then
		hash=$(printf '%s' "$canon" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,16)}')
	elif command -v sha256sum >/dev/null 2>&1; then
		hash=$(printf '%s' "$canon" | sha256sum 2>/dev/null | awk '{print substr($1,1,16)}')
	else
		hash=""
	fi
	echo "$hash"
	return 0
}

#######################################
# t2041: Emit the Hygiene Anomalies section to stdout.
#
# Reads the counter file written by _normalize_label_invariants (t2040)
# in pulse-issue-reconcile.sh. Zero anomalies = one line (literal
# "## Hygiene Anomalies\n\nNone — label invariants clean.\n"). Nonzero
# anomalies emit a call-to-action with the counts.
#
# No arguments. Output: markdown section on stdout.
#######################################
prefetch_hygiene_anomalies() {
	local hostname_short
	hostname_short=$(hostname -s 2>/dev/null || echo unknown)
	local counters_file="${HOME}/.aidevops/cache/pulse-label-invariants.${hostname_short}.json"

	echo "## Hygiene Anomalies"
	echo ""

	if [[ ! -f "$counters_file" ]]; then
		echo "Counter file not yet written — first cycle after t2040 deploy."
		echo ""
		return 0
	fi

	local status_fixed tier_fixed triage_missing ts checked
	status_fixed=$(jq -r '.status_fixed // 0' "$counters_file" 2>/dev/null) || status_fixed=0
	tier_fixed=$(jq -r '.tier_fixed // 0' "$counters_file" 2>/dev/null) || tier_fixed=0
	triage_missing=$(jq -r '.triage_missing // 0' "$counters_file" 2>/dev/null) || triage_missing=0
	ts=$(jq -r '.timestamp // ""' "$counters_file" 2>/dev/null) || ts=""
	checked=$(jq -r '.checked // 0' "$counters_file" 2>/dev/null) || checked=0

	if [[ "$status_fixed" -eq 0 && "$tier_fixed" -eq 0 && "$triage_missing" -eq 0 ]]; then
		echo "None — label invariants clean (checked=${checked} at ${ts})."
		echo ""
		return 0
	fi

	echo "Label invariant reconciler detected anomalies on last pass (${ts}):"
	echo ""
	if [[ "$status_fixed" -gt 0 ]]; then
		echo "- **${status_fixed} issues** had multiple \`status:*\` labels (reconciled via precedence)"
	fi
	if [[ "$tier_fixed" -gt 0 ]]; then
		echo "- **${tier_fixed} issues** had multiple \`tier:*\` labels (reconciled via rank)"
	fi
	if [[ "$triage_missing" -gt 0 ]]; then
		echo "- **${triage_missing} issues** marked \`origin:interactive\` but missing tier/auto-dispatch/status (need maintainer triage)"
	fi
	echo ""
	echo "If non-zero on consecutive cycles, investigate the source of the pollution —"
	echo "a write path is not using \`set_issue_status\` or is concatenating tier labels."
	echo ""
	return 0
}

#######################################
# t2041 Layer 1: Detect cache hit for a repo.
#
# Returns 0 (hit — LLM can skip deep analysis) if:
#   1. Cache entry has a state_fingerprint field
#   2. Current fingerprint equals cached fingerprint
#   3. Both snapshots are complete, compatible, and from one generation
# Returns 1 (miss — run full analysis) otherwise.
#
# Arguments:
#   $1 - repo slug
#   $2 - cache entry JSON (from _prefetch_cache_get)
#   $3 - canonical issue snapshot envelope
#   $4 - canonical PR snapshot envelope
#######################################
_prefetch_detect_cache_hit() {
	local slug="$1"
	local cache_entry="$2"
	local issues_snapshot="${3:-}"
	local prs_snapshot="${4:-}"

	PREFETCH_CURRENT_FINGERPRINT=""
	PREFETCH_CURRENT_SNAPSHOT_GENERATION=""

	PREFETCH_CURRENT_FINGERPRINT=$(_compute_repo_state_fingerprint \
		"$slug" "$issues_snapshot" "$prs_snapshot")
	[[ -n "$PREFETCH_CURRENT_FINGERPRINT" ]] || return 1
	PREFETCH_CURRENT_SNAPSHOT_GENERATION=$(printf '%s' "$issues_snapshot" | jq -r '.generation // ""' 2>/dev/null) || PREFETCH_CURRENT_SNAPSHOT_GENERATION=""

	local cached_fp="" cached_schema=""
	cached_fp=$(echo "$cache_entry" | jq -r '.state_fingerprint // ""' 2>/dev/null) || cached_fp=""
	cached_schema=$(echo "$cache_entry" | jq -r '.state_fingerprint_schema // ""' 2>/dev/null) || cached_schema=""
	[[ "$cached_schema" == "$_PREFETCH_FINGERPRINT_SCHEMA" ]] || return 1
	[[ -n "$cached_fp" && "$cached_fp" != "null" ]] || return 1
	[[ "$cached_fp" == "$PREFETCH_CURRENT_FINGERPRINT" ]] || return 1

	return 0
}

#######################################
# Load the prefetch cache for a single repo slug.
#
# Outputs the JSON object for the slug, or "{}" if not found/corrupt.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#######################################
_prefetch_cache_get() {
	local slug="$1"
	local cache_file="$PULSE_PREFETCH_CACHE_FILE"
	if [[ ! -f "$cache_file" ]]; then
		echo "{}"
		return 0
	fi
	local entry
	entry=$(jq -r --arg slug "$slug" '.[$slug] // {}' "$cache_file" 2>/dev/null) || entry="{}"
	[[ -n "$entry" ]] || entry="{}"
	echo "$entry"
	return 0
}

#######################################
# Write updated cache entry for a repo slug.
#
# Merges the new entry into the cache file atomically (write to tmp, mv).
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - JSON object to store for this slug
#######################################
_prefetch_cache_set() {
	local slug="$1"
	local entry="$2"
	local cache_file="$PULSE_PREFETCH_CACHE_FILE"
	local cache_dir
	cache_dir=$(dirname "$cache_file")
	mkdir -p "$cache_dir" 2>/dev/null || true

	local existing="{}"
	if [[ -f "$cache_file" ]]; then
		existing=$(cat "$cache_file" 2>/dev/null) || existing="{}"
		# Validate JSON; reset if corrupt
		printf '%s' "$existing" | jq empty 2>/dev/null || existing="{}"
	fi

	local tmp_file="" entry_file=""
	local failure_msg
	failure_msg='[pulse-wrapper] _prefetch_cache_set: failed to write cache for'
	tmp_file=$(mktemp "${cache_dir}/.pulse-prefetch-cache.XXXXXX") || {
		printf '%s %s\n' "$failure_msg" "$slug" >>"$LOGFILE"
		return 0
	}
	entry_file=$(mktemp "${cache_dir}/.pulse-prefetch-entry.XXXXXX") || {
		rm -f "$tmp_file"
		printf '%s %s\n' "$failure_msg" "$slug" >>"$LOGFILE"
		return 0
	}
	if ! printf '%s' "$entry" >"$entry_file"; then
		rm -f "$tmp_file" "$entry_file"
		printf '%s %s\n' "$failure_msg" "$slug" >>"$LOGFILE"
		return 0
	fi
	printf '%s' "$existing" | jq --arg slug "$slug" --slurpfile entry "$entry_file" \
		'.[$slug] = ($entry[0] // {})' >"$tmp_file" 2>/dev/null && mv "$tmp_file" "$cache_file" || {
		rm -f "$tmp_file" "$entry_file"
		printf '%s %s\n' "$failure_msg" "$slug" >>"$LOGFILE"
	}
	rm -f "$entry_file"
	return 0
}

#######################################
# Determine whether a full sweep is needed for a repo.
#
# Returns 0 (true) if:
#   - Cache entry missing or has no last_full_sweep
#   - last_full_sweep is older than PULSE_PREFETCH_FULL_SWEEP_INTERVAL seconds
#
# Arguments:
#   $1 - cache entry JSON (from _prefetch_cache_get)
#######################################
_prefetch_needs_full_sweep() {
	local entry="$1"
	local last_full_sweep
	last_full_sweep=$(echo "$entry" | jq -r '.last_full_sweep // ""' 2>/dev/null) || last_full_sweep=""
	if [[ -z "$last_full_sweep" ]]; then
		return 0 # No prior full sweep — must do one
	fi

	# Convert ISO timestamp to epoch — cross-platform (macOS/Linux)
	local last_epoch now_epoch
	# GH#17699: TZ=UTC required — macOS date interprets input as local time
	if [[ "$(uname)" == "Darwin" ]]; then
		last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_full_sweep" "+%s" 2>/dev/null) || last_epoch=0
	else
		last_epoch=$(date -u -d "$last_full_sweep" +%s 2>/dev/null) || last_epoch=0
	fi
	now_epoch=$(date -u +%s)
	local age=$((now_epoch - last_epoch))
	if [[ "$age" -ge "$PULSE_PREFETCH_FULL_SWEEP_INTERVAL" ]]; then
		return 0 # Sweep interval elapsed
	fi
	return 1 # Delta is sufficient
}
