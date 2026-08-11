#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GH Wrappers -- PR Check Status (REST check-suites/check-runs)
# =============================================================================
# REST-based PR check status helpers (GH#21799). Replaces the GraphQL
# `statusCheckRollup` field — the heaviest single field in the pulse's
# GraphQL payload — with per-PR REST calls that hit the separate REST
# budget pool (5000/hr, mostly unused) instead of the shared GraphQL pool.
#
# Why this exists:
#   - GraphQL `statusCheckRollup` is ~21KB per PR, ~230KB per pulse cycle
#     across 11 open PRs (cycle observed via `gh-api-instrument.sh report`).
#   - REST `/commits/{sha}/check-suites` is ~1.3KB per PR (~15x smaller),
#     uses a separate budget pool, and returns conclusion+status enough to
#     derive PASS/FAIL/PENDING.
#   - For consumers that need per-context names (required-status-checks
#     filtering, name-based check exclusions), `/commits/{sha}/check-runs`
#     is heavier (~111KB per PR) but still hits the separate REST pool —
#     and is only used in single-PR paths (merge gate, NMR recovery).
#
# Public API:
#   gh_pr_check_status_rest <slug> <sha>
#     → echoes "PASS" | "FAIL" | "PENDING" | "none"
#       Aggregate status derived from check-suites conclusions.
#       Use for any consumer that only needs the rolled-up state.
#
#   gh_pr_check_runs_rest <slug> <sha>
#     → echoes JSON array of check-runs ([{name,conclusion,status}, ...]).
#       Use when per-context filtering by name is required (e.g.
#       skip-by-name in NMR/merge-gate pipelines).
#
#   gh_pr_check_status_rest_batch <slug> <pr_json>
#     → echoes JSON array [{"number":N,"status":"..."},...].
#       Convenience for prefetch/capacity/governor consumers that fetch a
#       PR list (with .number and .headRefOid) and need each PR's
#       aggregated status.
#
#   gh_pr_checks_exact_json <slug> <pr_number> <required|all>
#     → echoes the internal `gh pr checks --json` field superset while every
#       GraphQL page reports its own operation-owned rateLimit.cost.
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers-checks.sh"
#
# Dependencies:
#   - gh CLI (for `gh api`)
#   - jq
#   - bash 3.2+ (no associative arrays / nameref usage)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_CHECKS_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_CHECKS_LIB_LOADED=1

_gh_checks_lib_dir="${_SHARED_GH_WRAPPERS_DIR:-}"
if [[ -z "$_gh_checks_lib_dir" && -n "${BASH_SOURCE[0]:-}" ]]; then
	_gh_checks_lib_dir="${BASH_SOURCE[0]%/*}"
	[[ "$_gh_checks_lib_dir" == "${BASH_SOURCE[0]}" ]] && _gh_checks_lib_dir="."
elif [[ -z "$_gh_checks_lib_dir" && -n "${ZSH_VERSION:-}" && -f "${0:-}" ]]; then
	_gh_checks_lib_dir="${0%/*}"
	[[ "$_gh_checks_lib_dir" == "$0" ]] && _gh_checks_lib_dir="."
fi
if ! declare -F gh_request_state_singleflight_begin >/dev/null 2>&1 && [[ -f "${_gh_checks_lib_dir}/shared-gh-request-state.sh" ]]; then
	# shellcheck source=./shared-gh-request-state.sh
	# shellcheck disable=SC1091
	source "${_gh_checks_lib_dir}/shared-gh-request-state.sh"
fi
unset _gh_checks_lib_dir

_GH_PR_CHECK_STATUS_SCHEMA="aidevops-gh-pr-check-status/v1"
_GH_PR_CHECK_STATUS_PROJECTION="check-suites-aggregate/v1"
_GH_PR_CHECK_STATUS_SOURCE="rest-check-suites"
_GH_PR_CHECK_STATUS_NONE=none
_GH_PR_CHECK_STATUS_CACHE_PUT_OK=0
_GH_PR_CHECK_STATUS_FETCH_INVALIDATED=0
_GH_PR_CHECK_STATUS_INVALIDATION_INITIAL="${_GHRS_INVALIDATION_INITIAL:-0000000000000000000000000000000000000000000000000000000000000000}"

#######################################
# Record an observational check-status cache decision without counting an HTTP
# attempt. The transport wrapper records actual REST attempts separately.
# Args: $1=decision
#######################################
_gh_pr_check_status_cache_record() {
	local decision="$1"
	if declare -F gh_record_call >/dev/null 2>&1; then
		gh_record_call other gh_pr_check_status_cache unknown other "$decision" "" cache 2>/dev/null || true
	fi
	if declare -F gh_record_efficiency_evidence >/dev/null 2>&1; then
		case "$decision" in
		hit-empty)
			gh_record_efficiency_evidence cache.fresh_empty_hits 1 2>/dev/null || true
			;;
		hit-*)
			gh_record_efficiency_evidence cache.fresh_hits 1 2>/dev/null || true
			;;
		miss | bypass | bypass-disabled)
			gh_record_efficiency_evidence cache.misses 1 2>/dev/null || true
			;;
		invalid | invalid-* | refresh-*)
			gh_record_efficiency_evidence cache.misses 1 2>/dev/null || true
			gh_record_efficiency_evidence cache.stale 1 2>/dev/null || true
			gh_record_efficiency_evidence guardrails.stale_snapshot_detections 1 2>/dev/null || true
			gh_record_efficiency_evidence guardrails.forced_live_refreshes 1 2>/dev/null || true
			;;
		invalidate)
			gh_record_efficiency_evidence cache.invalidated 1 2>/dev/null || true
			;;
		fetch)
			gh_record_efficiency_evidence path_budgets.aggregate_check_fetches 1 2>/dev/null || true
			if [[ "${AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID:-}" =~ ^[0-9]+$ ]]; then
				gh_record_efficiency_evidence path_budgets.cycle_scoped_aggregate_check_fetches 1 2>/dev/null || true
			fi
			;;
		publish-fenced | publish-invalidated)
			gh_record_efficiency_evidence guardrails.stale_snapshot_detections 1 2>/dev/null || true
			;;
		esac
	fi
	return 0
}

_gh_pr_check_status_record_actionable_head() {
	local slug="$1"
	local sha="$2"
	local normalized_sha=""
	local token=""
	local cycle_id="${AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID:-}"
	local cycle_token=""
	_gh_pr_check_status_cache_identity_valid "$slug" "$sha" || return 0
	declare -F gh_record_efficiency_evidence >/dev/null 2>&1 || return 0
	gh_record_efficiency_evidence population.actionable_changes 1 2>/dev/null || true
	normalized_sha=$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')
	if declare -F _ghrs_digest >/dev/null 2>&1; then
		token=$(_ghrs_digest "$normalized_sha") || token=""
	fi
	if [[ -n "$token" ]]; then
		gh_record_efficiency_evidence population.actionable_head_token "$token" 2>/dev/null || true
	else
		gh_record_efficiency_evidence population.actionable_head_hash_failures 1 2>/dev/null || true
	fi
	[[ "$cycle_id" =~ ^[0-9]+$ ]] || return 0
	if declare -F _ghrs_digest >/dev/null 2>&1; then
		cycle_token=$(_ghrs_digest "${cycle_id}"$'\034'"${normalized_sha}") || cycle_token=""
	fi
	if [[ -n "$cycle_token" ]]; then
		gh_record_efficiency_evidence path_budgets.cycle_scoped_actionable_head_token "$cycle_token" 2>/dev/null || true
	else
		gh_record_efficiency_evidence path_budgets.cycle_scoped_actionable_head_hash_failures 1 2>/dev/null || true
	fi
	return 0
}

#######################################
# Resolve the non-secret auth identity used to isolate cache entries.
#######################################
_gh_pr_check_status_cache_auth_scope() {
	printf '%s|%s' "${AIDEVOPS_GH_CHECK_STATUS_CACHE_AUTH_SCOPE:-${GH_HOST:-github.com}|${AIDEVOPS_GH_AUTH_MODE:-gh}|${AIDEVOPS_GH_AUTH_PRINCIPAL:-default}}" "${AIDEVOPS_GH_API_POOL:-default}"
	return 0
}

#######################################
# Emit the current epoch. Kept as a seam for deterministic TTL tests.
#######################################
_gh_pr_check_status_cache_now() {
	date +%s 2>/dev/null || printf '0\n'
	return 0
}

#######################################
# Validate the immutable cache identity. GitHub currently returns full
# 40-character hex OIDs; 64-character OIDs are accepted for SHA-256 repositories.
# Args: $1=repo slug, $2=full head SHA
#######################################
_gh_pr_check_status_cache_identity_valid() {
	local slug="$1"
	local sha="$2"
	[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	[[ "$sha" =~ ^[A-Fa-f0-9]{40}$ || "$sha" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
	return 0
}

#######################################
# Classify aggregate states for bounded expiry.
# Args: $1=PASS|FAIL|PENDING|none
# Stdout: terminal|actionable
#######################################
_gh_pr_check_status_cache_class() {
	local check_state="$1"
	case "$check_state" in
	PASS | FAIL) printf 'terminal\n' ;;
	PENDING | none) printf 'actionable\n' ;;
	*) return 1 ;;
	esac
	return 0
}

#######################################
# Resolve a validated bounded TTL. Terminal observations default to six hours
# (maximum seven days); pending/none observations default to 30 seconds
# (maximum five minutes) so actionable changes refresh promptly.
# Args: $1=terminal|actionable
#######################################
_gh_pr_check_status_cache_ttl() {
	local expiry_class="$1"
	local ttl="" default_ttl="" max_ttl=""
	case "$expiry_class" in
	terminal)
		default_ttl=21600
		max_ttl=604800
		ttl="${AIDEVOPS_GH_CHECK_STATUS_CACHE_TERMINAL_TTL:-$default_ttl}"
		;;
	actionable)
		default_ttl=30
		max_ttl=300
		ttl="${AIDEVOPS_GH_CHECK_STATUS_CACHE_ACTIONABLE_TTL:-$default_ttl}"
		;;
	*) return 1 ;;
	esac
	if [[ ! "$ttl" =~ ^[0-9]+$ || "$ttl" -le 0 || "$ttl" -gt "$max_ttl" ]]; then
		ttl="$default_ttl"
	fi
	printf '%s\n' "$ttl"
	return 0
}

#######################################
# Build a collision-resistant cache key from auth scope, repository, exact full
# head SHA, and aggregate projection version.
# Args: $1=repo slug, $2=full head SHA
#######################################
_gh_pr_check_status_cache_key() {
	local slug="$1"
	local sha="$2"
	local auth_scope="" material="" key=""
	_gh_pr_check_status_cache_identity_valid "$slug" "$sha" || return 1
	auth_scope="$(_gh_pr_check_status_cache_auth_scope)"
	material="${auth_scope}"$'\034'"${slug}"$'\034'"${sha}"$'\034'"${_GH_PR_CHECK_STATUS_PROJECTION}"
	if command -v shasum >/dev/null 2>&1; then
		key=$(printf '%s' "$material" | shasum -a 256 | awk '{print $1}')
	elif command -v openssl >/dev/null 2>&1; then
		key=$(printf '%s' "$material" | openssl dgst -sha256 | awk '{print $NF}')
	else
		return 1
	fi
	[[ -n "$key" ]] || return 1
	printf '%s\n' "$key"
	return 0
}

_gh_pr_check_status_request_key() {
	local slug="$1"
	local sha="$2"
	declare -F gh_request_state_request_key >/dev/null 2>&1 || return 1
	gh_request_state_request_key "$slug" check-suites-aggregate \
		"$_GH_PR_CHECK_STATUS_PROJECTION" "$sha" rest-core
	return $?
}

_gh_pr_check_status_invalidation_key() {
	local slug="$1"
	local sha="$2"
	declare -F gh_request_state_invalidation_key >/dev/null 2>&1 || return 1
	gh_request_state_invalidation_key "$slug" check-suites-aggregate \
		"$_GH_PR_CHECK_STATUS_PROJECTION" "$sha"
	return $?
}

_gh_pr_check_status_invalidation_generation() {
	local slug="$1"
	local sha="$2"
	local request_key=""
	if ! declare -F gh_request_state_invalidation_generation_get >/dev/null 2>&1; then
		printf '%s\n' "$_GH_PR_CHECK_STATUS_INVALIDATION_INITIAL"
		return 0
	fi
	request_key="$(_gh_pr_check_status_invalidation_key "$slug" "$sha")" || return 1
	gh_request_state_invalidation_generation_get "$request_key"
	return $?
}

_gh_pr_check_status_invalidation_generation_is_current() {
	local slug="$1"
	local sha="$2"
	local generation="$3"
	local invalidation_key=""
	invalidation_key="$(_gh_pr_check_status_invalidation_key "$slug" "$sha")" || return 1
	gh_request_state_invalidation_generation_is_current "$invalidation_key" "$generation"
	return $?
}

#######################################
# Resolve a private disposable cache path.
# Args: $1=repo slug, $2=full head SHA
#######################################
_gh_pr_check_status_cache_path() {
	local slug="$1"
	local sha="$2"
	local dir="${AIDEVOPS_GH_CHECK_STATUS_CACHE_DIR:-${HOME}/.aidevops/cache/gh-pr-check-status}"
	local key=""
	key="$(_gh_pr_check_status_cache_key "$slug" "$sha")" || return 1
	mkdir -p "$dir" 2>/dev/null || return 1
	chmod 700 "$dir" 2>/dev/null || return 1
	printf '%s/entry-%s.json\n' "$dir" "$key"
	return 0
}

#######################################
# Emit a fresh validated aggregate state from cache.
# Args: $1=repo slug, $2=full head SHA
# Returns: 0=hit, 1=miss/stale/invalid/disabled
#######################################
_gh_pr_check_status_cache_get() {
	local slug="$1"
	local sha="$2"
	if [[ "${AIDEVOPS_GH_CHECK_STATUS_CACHE_DISABLE:-0}" == "1" ]]; then
		_gh_pr_check_status_cache_record bypass-disabled
		return 1
	fi
	if ! _gh_pr_check_status_cache_identity_valid "$slug" "$sha"; then
		_gh_pr_check_status_cache_record bypass-invalid-identity
		return 1
	fi

	local path="" auth_scope="" entry="" invalidation_generation=""
	path="$(_gh_pr_check_status_cache_path "$slug" "$sha")" || {
		_gh_pr_check_status_cache_record bypass
		return 1
	}
	[[ -s "$path" ]] || {
		_gh_pr_check_status_cache_record miss
		return 1
	}
	auth_scope="$(_gh_pr_check_status_cache_auth_scope)"
	invalidation_generation="$(_gh_pr_check_status_invalidation_generation "$slug" "$sha")" || {
		_gh_pr_check_status_cache_record invalid-invalidation-marker
		return 1
	}
	entry=$(jq -er --arg schema "$_GH_PR_CHECK_STATUS_SCHEMA" \
		--arg repository "$slug" --arg head_sha "$sha" \
		--arg projection "$_GH_PR_CHECK_STATUS_PROJECTION" \
		--arg auth_scope "$auth_scope" --arg source "$_GH_PR_CHECK_STATUS_SOURCE" \
		--arg none_state "$_GH_PR_CHECK_STATUS_NONE" \
		--arg invalidation_generation "$invalidation_generation" \
		--arg invalidation_initial "$_GH_PR_CHECK_STATUS_INVALIDATION_INITIAL" '
		select(
			.schema == $schema and .repository == $repository and
			.head_sha == $head_sha and .projection == $projection and
			.auth_scope == $auth_scope and .source == $source and
			(.invalidation_generation // $invalidation_initial) == $invalidation_generation and
			.validation == "validated" and
			(.fetched_at | type == "number" and floor == .) and
			(
				((.state == "PASS" or .state == "FAIL") and .expiry_class == "terminal") or
				((.state == "PENDING" or .state == $none_state) and .expiry_class == "actionable")
			)
		) |
		[.state, (.fetched_at | tostring), .expiry_class] | @tsv' "$path" 2>/dev/null) || entry=""
	if [[ -z "$entry" ]]; then
		_gh_pr_check_status_cache_record invalid
		return 1
	fi

	local check_state="" fetched_at="" expiry_class="" ttl="" now="" age=0
	IFS=$'\t' read -r check_state fetched_at expiry_class <<<"$entry"
	ttl="$(_gh_pr_check_status_cache_ttl "$expiry_class")" || return 1
	now="$(_gh_pr_check_status_cache_now)"
	if [[ ! "$now" =~ ^[0-9]+$ || ! "$fetched_at" =~ ^[0-9]+$ ]]; then
		_gh_pr_check_status_cache_record invalid-time
		return 1
	fi
	age=$((now - fetched_at))
	if [[ "$age" -lt 0 || "$age" -gt "$ttl" ]]; then
		_gh_pr_check_status_cache_record "refresh-${expiry_class}"
		return 1
	fi
	if [[ "$check_state" == "$_GH_PR_CHECK_STATUS_NONE" ]]; then
		_gh_pr_check_status_cache_record hit-empty
	else
		_gh_pr_check_status_cache_record "hit-${expiry_class}"
	fi
	printf '%s\n' "$check_state"
	return 0
}

#######################################
# Atomically store one validated aggregate observation. Concurrent writers use
# unique temp files; last-writer-wins is safe for the same immutable identity.
# Args: $1=repo slug, $2=full head SHA, $3=aggregate state,
#       $4=request invalidation generation (optional)
#######################################
_gh_pr_check_status_cache_put() {
	local slug="$1"
	local sha="$2"
	local check_state="$3"
	local invalidation_generation="${4:-}"
	_GH_PR_CHECK_STATUS_CACHE_PUT_OK=0
	[[ "${AIDEVOPS_GH_CHECK_STATUS_CACHE_DISABLE:-0}" != "1" ]] || return 0
	_gh_pr_check_status_cache_identity_valid "$slug" "$sha" || return 0
	local expiry_class="" path="" dir="" tmp="" now="" auth_scope=""
	expiry_class="$(_gh_pr_check_status_cache_class "$check_state")" || return 0
	if [[ -z "$invalidation_generation" ]]; then
		invalidation_generation="$(_gh_pr_check_status_invalidation_generation "$slug" "$sha")" || return 0
	fi
	path="$(_gh_pr_check_status_cache_path "$slug" "$sha")" || return 0
	dir="${path%/*}"
	now="$(_gh_pr_check_status_cache_now)"
	[[ "$now" =~ ^[0-9]+$ ]] || return 0
	auth_scope="$(_gh_pr_check_status_cache_auth_scope)"
	tmp=$(mktemp "${dir}/.pr-check-status.XXXXXX" 2>/dev/null) || return 0
	chmod 600 "$tmp" 2>/dev/null || {
		rm -f "$tmp"
		return 0
	}
	if ! jq -n --arg schema "$_GH_PR_CHECK_STATUS_SCHEMA" \
		--arg repository "$slug" --arg head_sha "$sha" \
		--arg projection "$_GH_PR_CHECK_STATUS_PROJECTION" \
		--arg auth_scope "$auth_scope" --arg state "$check_state" \
		--arg expiry_class "$expiry_class" --arg source "$_GH_PR_CHECK_STATUS_SOURCE" \
		--arg invalidation_generation "$invalidation_generation" \
		--argjson fetched_at "$now" \
		'{schema:$schema,repository:$repository,head_sha:$head_sha,projection:$projection,
		auth_scope:$auth_scope,state:$state,fetched_at:$fetched_at,
		expiry_class:$expiry_class,source:$source,validation:"validated",
		invalidation_generation:$invalidation_generation}' >"$tmp"; then
		rm -f "$tmp"
		return 0
	fi
	if mv "$tmp" "$path" 2>/dev/null; then
		_GH_PR_CHECK_STATUS_CACHE_PUT_OK=1
		_gh_pr_check_status_cache_record "store-${expiry_class}"
	else
		rm -f "$tmp"
	fi
	return 0
}

#######################################
# Idempotently invalidate one repository/full-head/projection/auth entry. This
# interface is intentionally webhook-agnostic for the later invalidation phase.
# Args: $1=repo slug, $2=full head SHA
#######################################
gh_pr_check_status_cache_invalidate() {
	local slug="$1"
	local sha="$2"
	local path=""
	local request_key=""
	request_key="$(_gh_pr_check_status_invalidation_key "$slug" "$sha")" || return 1
	declare -F gh_request_state_invalidate >/dev/null 2>&1 || return 1
	gh_request_state_invalidate "$request_key" || return 1
	path="$(_gh_pr_check_status_cache_path "$slug" "$sha")" || return 0
	rm -f "$path" || return 1
	_gh_pr_check_status_cache_record invalidate
	return 0
}

#######################################
# Internal: invoke a read-only `gh api` request with a wall-clock cap.
#
# Prefer the shared `_gh_with_timeout` wrapper when this sub-library is loaded
# through shared-gh-wrappers.sh. Keep a local fallback because some tests and
# single-purpose pulse helpers source shared-gh-wrappers-checks.sh directly.
#
# Args:
#   $1 - REST API endpoint
#   $@ - remaining gh api arguments
# Returns: passthrough command exit code (124 when coreutils timeout fires)
#######################################
_gh_checks_api_read() {
	local endpoint="$1"
	shift

	if declare -f _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh api "$endpoint" "$@"
		return $?
	fi

	local secs="${AIDEVOPS_GH_READ_TIMEOUT:-15}"
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" gh api "$endpoint" "$@"
		return $?
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$secs" gh api "$endpoint" "$@"
		return $?
	fi

	gh api "$endpoint" "$@"
	return $?
}

#######################################
# Emit a stable diagnostic for an indeterminate exact PR-check read.
# Args: $1=detail
#######################################
_gh_pr_checks_exact_error() {
	local detail="$1"
	printf 'gh_pr_checks_exact_json: %s\n' "$detail" >&2
	return 0
}

#######################################
# Normalize and deduplicate collected status-rollup pages like gh CLI 2.96.0.
# The newest StatusContext wins by context name. The newest CheckRun wins by
# name/workflow/event. Deduplication happens before required-only filtering.
#
# Args: $1=required|all, $2=JSON-lines file containing one nodes array per page
# Stdout: normalized JSON array
# Returns: 0=valid, 1=invalid response shape
#######################################
_gh_pr_checks_exact_aggregate() {
	local mode="$1"
	local pages_file="$2"
	local array_type='array'
	local required_mode='required'

	jq -cs --arg mode "$mode" --arg array_type "$array_type" \
		--arg required_mode "$required_mode" '
		def bucket_for($state):
			if $state == "SUCCESS" then "pass"
			elif ($state == "SKIPPED" or $state == "NEUTRAL") then "skipping"
			elif ($state == "ERROR" or $state == "FAILURE" or $state == "TIMED_OUT" or $state == "ACTION_REQUIRED") then "fail"
			elif $state == "CANCELLED" then "cancel"
			else "pending" end;
		if all(.[]; type == $array_type) then add else error("invalid page collection") end
		| map(
			if .__typename == "StatusContext" then
				(.state // "") as $state
				| {
					_dedup_key: ("status\u0000" + .context),
					_sort_at: (.createdAt // ""),
					isRequired: .isRequired,
					name: .context,
					state: $state,
					startedAt: (.createdAt // ""),
					completedAt: "",
					link: (.targetUrl // ""),
					bucket: bucket_for($state),
					event: "",
					workflow: "",
					description: (.description // "")
				}
			elif .__typename == "CheckRun" then
				(.checkSuite.workflowRun.workflow.name // "") as $workflow
				| (.checkSuite.workflowRun.event // "") as $event
				| (if .status == "COMPLETED" then (.conclusion // "") else (.status // "") end) as $state
				| {
					_dedup_key: ("check\u0000" + .name + "\u0000" + $workflow + "\u0000" + $event),
					_sort_at: (.startedAt // ""),
					isRequired: .isRequired,
					name: .name,
					state: $state,
					startedAt: (.startedAt // ""),
					completedAt: (.completedAt // ""),
					link: (.detailsUrl // ""),
					bucket: bucket_for($state),
					event: $event,
					workflow: $workflow,
					description: ""
				}
			else error("unsupported check context") end
		)
		| sort_by(._sort_at) | reverse
		| reduce .[] as $item (
			{seen: {}, items: []};
			if .seen[$item._dedup_key] then .
			else .seen[$item._dedup_key] = true | .items += [$item] end
		)
		| .items
		| if $mode == $required_mode then map(select(.isRequired == true)) else . end
		| map(del(._dedup_key, ._sort_at, .isRequired))
	' "$pages_file" 2>/dev/null
	return $?
}

#######################################
# Resolve and validate the immutable identity needed for an exact PR-check read.
# Args: $1=repo slug, $2=numeric PR
# Stdout: PR node ID, head ref, and head SHA as TSV
# Returns: 0=valid identity, 2=API/parse failure
#######################################
_gh_pr_checks_exact_identity() {
	local slug="$1"
	local pr_number="$2"
	local identity_json="" identity=""
	local object_type='object'
	local string_type='string'

	identity_json=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="gh-pr-checks-identity-rest" \
		_gh_checks_api_read "repos/${slug}/pulls/${pr_number}" 2>/dev/null) || {
		_gh_pr_checks_exact_error "pull-request identity read failed"
		return 2
	}
	identity=$(printf '%s' "$identity_json" | jq -er --argjson expected "$pr_number" \
		--arg object_type "$object_type" --arg string_type "$string_type" '
		select(type == $object_type and .number == $expected)
		| select((.node_id | type) == $string_type and (.node_id | length) > 0)
		| select((.head.ref | type) == $string_type and (.head.ref | length) > 0)
		| select((.head.sha | type) == $string_type and (.head.sha | test("^[0-9A-Fa-f]{40}$|^[0-9A-Fa-f]{64}$")))
		| [.node_id, .head.ref, .head.sha] | @tsv
	' 2>/dev/null) || identity=""
	if [[ -z "$identity" ]]; then
		_gh_pr_checks_exact_error "pull-request identity response was malformed"
		return 2
	fi
	printf '%s\n' "$identity"
	return 0
}

#######################################
# Emit the bounded status-rollup query used by exact PR-check reads.
# Stdout: GraphQL query
#######################################
_gh_pr_checks_exact_query() {
	# CheckRun.event is part of GitHub CLI's duplicate identity on hosts that
	# support it. A host returning a field error fails closed rather than silently
	# collapsing distinct workflow events into one check.
	# shellcheck disable=SC2016
	printf '%s\n' 'query PullRequestStatusChecks($id: ID!, $endCursor: String) {
		node(id: $id) {
			__typename
			... on PullRequest {
				statusCheckRollup: commits(last: 1) {
					nodes {
						commit {
							statusCheckRollup {
								contexts(first: 100, after: $endCursor) {
									nodes {
										__typename
										... on StatusContext {
											context state targetUrl createdAt description
											isRequired(pullRequestId: $id)
										}
										... on CheckRun {
											name status conclusion startedAt completedAt detailsUrl
											checkSuite { workflowRun { event workflow { name } } }
											isRequired(pullRequestId: $id)
										}
									}
									pageInfo { hasNextPage endCursor }
								}
							}
						}
					}
				}
			}
		}
		rateLimit { cost }
	}'
	return 0
}

#######################################
# Validate one status-rollup page and return its pagination metadata.
# Args: $1=GraphQL response JSON
# Stdout: hasNextPage and endCursor as TSV
# Returns: 0=valid page, 1=partial or malformed page
#######################################
_gh_pr_checks_exact_page_meta() {
	local response="$1"
	local object_type='object'
	local array_type='array'
	local string_type='string'
	local boolean_type='boolean'

	printf '%s' "$response" | jq -er --arg object_type "$object_type" \
		--arg array_type "$array_type" --arg string_type "$string_type" \
		--arg boolean_type "$boolean_type" '
		select(type == $object_type)
		| select(((.errors // []) | type) == $array_type and ((.errors // []) | length) == 0)
		| select((.data.rateLimit.cost | type) == "number" and .data.rateLimit.cost > 0 and (.data.rateLimit.cost | floor) == .data.rateLimit.cost)
		| select(.data.node.__typename == "PullRequest")
		| .data.node.statusCheckRollup.nodes as $commits
		| select(($commits | type) == $array_type and ($commits | length) == 1)
		| $commits[0].commit.statusCheckRollup.contexts as $contexts
		| select(($contexts | type) == $object_type)
		| select(($contexts.nodes | type) == $array_type)
		| select(all($contexts.nodes[];
			(.__typename == "StatusContext" and (.context | type) == $string_type and (.context | length) > 0 and (.state | type) == $string_type and (.isRequired | type) == $boolean_type)
			or
			(.__typename == "CheckRun" and (.name | type) == $string_type and (.name | length) > 0 and (.status | type) == $string_type and (.isRequired | type) == $boolean_type)
		))
		| select(($contexts.pageInfo.hasNextPage | type) == $boolean_type)
		| select(($contexts.pageInfo.hasNextPage == false) or (($contexts.pageInfo.endCursor | type) == $string_type and ($contexts.pageInfo.endCursor | length) > 0))
		| [$contexts.pageInfo.hasNextPage, ($contexts.pageInfo.endCursor // "")] | @tsv
	' 2>/dev/null
	return $?
}

#######################################
# Collect every bounded status-rollup page into a JSON-lines file.
# Args: $1=PR node ID, $2=GraphQL query, $3=page file, $4=max pages
# Returns: 0=complete collection, 2=API/parse/pagination failure
#######################################
_gh_pr_checks_exact_collect_pages() {
	local node_id="$1"
	local query="$2"
	local pages_file="$3"
	local max_pages="$4"
	local page_number=0 cursor="" next_cursor="" has_next="" page_meta=""
	local response="" nodes_json="" seen_cursors=$'\n' cursor_flag="" cursor_field=""
	local false_text='false'

	while true; do
		page_number=$((page_number + 1))
		if [[ "$page_number" -gt "$max_pages" ]]; then
			rm -f "$pages_file"
			_gh_pr_checks_exact_error "status-rollup pagination exceeded ${max_pages} pages"
			return 2
		fi
		if [[ -n "$cursor" ]]; then
			cursor_flag="-f"
			cursor_field="endCursor=${cursor}"
		else
			cursor_flag="-F"
			cursor_field="endCursor=null"
		fi
		response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
			AIDEVOPS_GH_ROUTE_DECISION="gh-pr-checks-status-rollup-exact-cost" \
			_gh_checks_api_read graphql -f id="$node_id" "$cursor_flag" "$cursor_field" -f query="$query" 2>/dev/null) || {
			rm -f "$pages_file"
			_gh_pr_checks_exact_error "status-rollup page ${page_number} read failed"
			return 2
		}
		page_meta=$(_gh_pr_checks_exact_page_meta "$response") || page_meta=""
		if [[ -z "$page_meta" ]]; then
			_gh_pr_checks_exact_error "status-rollup page ${page_number} response was partial or malformed"
			return 2
		fi
		IFS=$'\t' read -r has_next next_cursor <<<"$page_meta"
		nodes_json=$(printf '%s' "$response" | jq -c '.data.node.statusCheckRollup.nodes[0].commit.statusCheckRollup.contexts.nodes' 2>/dev/null) || nodes_json=""
		if [[ -z "$nodes_json" ]]; then
			_gh_pr_checks_exact_error "status-rollup page ${page_number} contexts were unavailable"
			return 2
		fi
		printf '%s\n' "$nodes_json" >>"$pages_file" || {
			_gh_pr_checks_exact_error "status-rollup page collection failed"
			return 2
		}
		if [[ "$has_next" == "$false_text" ]]; then
			return 0
		fi
		if [[ -z "$next_cursor" || "$seen_cursors" == *$'\n'"$next_cursor"$'\n'* ]]; then
			_gh_pr_checks_exact_error "status-rollup pagination cursor was incomplete or repeated"
			return 2
		fi
		seen_cursors="${seen_cursors}${next_cursor}"$'\n'
		cursor="$next_cursor"
	done
	return 0
}

#######################################
# Aggregate collected pages, emit JSON, and map check buckets to CLI exits.
# Args: $1=required|all, $2=head ref, $3=JSON-lines page file
# Returns: 0=pass, 1=terminal failure/no checks, 8=pending, 2=parse failure
#######################################
_gh_pr_checks_exact_emit_result() {
	local mode="$1"
	local head_ref="$2"
	local pages_file="$3"
	local checks_json="" check_count="" result_flags="" has_failure="" has_pending=""
	local required_mode='required'
	local fail_bucket='fail'
	local pending_bucket='pending'
	local true_text='true'
	local false_text='false'

	checks_json=$(_gh_pr_checks_exact_aggregate "$mode" "$pages_file") || checks_json=""
	if [[ -z "$checks_json" ]]; then
		_gh_pr_checks_exact_error "status-rollup aggregation failed"
		return 2
	fi
	check_count=$(printf '%s' "$checks_json" | jq -r 'length' 2>/dev/null) || check_count=""
	if [[ ! "$check_count" =~ ^[0-9]+$ ]]; then
		_gh_pr_checks_exact_error "status-rollup aggregate was malformed"
		return 2
	fi
	if [[ "$check_count" -eq 0 ]]; then
		if [[ "$mode" == "$required_mode" ]]; then
			printf "no required checks reported on the '%s' branch\n" "$head_ref" >&2
		else
			printf "no checks reported on the '%s' branch\n" "$head_ref" >&2
		fi
		return 1
	fi

	result_flags=$(printf '%s' "$checks_json" | jq -r --arg fail_bucket "$fail_bucket" \
		--arg pending_bucket "$pending_bucket" \
		'[any(.[]; .bucket == $fail_bucket), any(.[]; .bucket == $pending_bucket)] | @tsv' 2>/dev/null) || result_flags=""
	IFS=$'\t' read -r has_failure has_pending <<<"$result_flags"
	if [[ "$has_failure" != "$true_text" && "$has_failure" != "$false_text" ]] || \
		[[ "$has_pending" != "$true_text" && "$has_pending" != "$false_text" ]]; then
		_gh_pr_checks_exact_error "status-rollup outcome was malformed"
		return 2
	fi
	printf '%s\n' "$checks_json"
	if [[ "$has_failure" == "$true_text" ]]; then
		return 1
	fi
	if [[ "$has_pending" == "$true_text" ]]; then
		return 8
	fi
	return 0
}

#######################################
# Read one PR's checks through a bounded status-rollup GraphQL query whose every
# page carries its own rateLimit.cost. This intentionally covers only the JSON
# surface used by framework internals; it is not a replacement for interactive
# `gh pr checks` modes such as --watch, --web, or templates.
#
# Args: $1=repo slug, $2=numeric PR, $3=required|all
# Stdout: JSON array with name/state/bucket/link/workflow plus CLI-compatible
#         event, description, startedAt, and completedAt fields
# Returns: 0=no failing or pending checks, 1=terminal failure/no matching checks,
#          8=pending checks, 2=API/parse/partial-page failure
#######################################
gh_pr_checks_exact_json() {
	local slug="$1"
	local pr_number="$2"
	local mode="$3"
	local max_pages="${AIDEVOPS_GH_PR_CHECKS_MAX_PAGES:-20}"
	local identity="" identity_exit=0 node_id="" head_ref="" head_sha=""
	local pages_file="" temp_root="${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}"
	local query="" collect_exit=0 result_exit=0
	local required_mode='required'
	local all_mode='all'

	if [[ ! "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! "$pr_number" =~ ^[1-9][0-9]*$ ]]; then
		_gh_pr_checks_exact_error "repository and numeric PR are required"
		return 2
	fi
	if [[ "$mode" != "$required_mode" && "$mode" != "$all_mode" ]]; then
		_gh_pr_checks_exact_error "mode must be required or all"
		return 2
	fi
	if [[ ! "$max_pages" =~ ^[1-9][0-9]*$ || "$max_pages" -gt 100 ]]; then
		max_pages=20
	fi

	identity=$(_gh_pr_checks_exact_identity "$slug" "$pr_number") || identity_exit=$?
	[[ "$identity_exit" -eq 0 ]] || return "$identity_exit"
	IFS=$'\t' read -r node_id head_ref head_sha <<<"$identity"
	if [[ -z "$node_id" || -z "$head_ref" || -z "$head_sha" ]]; then
		_gh_pr_checks_exact_error "pull-request identity response was incomplete"
		return 2
	fi

	pages_file=$(mktemp "${temp_root}/aidevops-gh-pr-checks.XXXXXX" 2>/dev/null) || {
		_gh_pr_checks_exact_error "temporary page collection unavailable"
		return 2
	}
	query=$(_gh_pr_checks_exact_query)
	_gh_pr_checks_exact_collect_pages "$node_id" "$query" "$pages_file" "$max_pages" || collect_exit=$?
	if [[ "$collect_exit" -ne 0 ]]; then
		rm -f "$pages_file"
		return "$collect_exit"
	fi

	_gh_pr_checks_exact_emit_result "$mode" "$head_ref" "$pages_file" || result_exit=$?
	rm -f "$pages_file"
	return "$result_exit"
}

#######################################
# Aggregate PR check status via REST `/commits/{sha}/check-suites`.
#
# REST check-suites is ~15x smaller than GraphQL statusCheckRollup
# (~1.3KB vs ~21KB per PR) and uses the separate REST budget pool.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - commit SHA (PR's headRefOid)
#
# Output (stdout): one of "PASS", "FAIL", "PENDING", "none". Valid aggregate
# observations are cached by repository/auth/full-head/projection identity.
# Returns: 0 always (returns "none" on missing args / API error — fail-open
#          since callers treat "none" as "no checks recorded yet")
#######################################
_gh_pr_check_status_rest_fetch() {
	local slug="$1"
	local sha="$2"
	# NOTE: variable is `_check_state` not `status` — zsh treats `status` as a
	# read-only special variable, which would silently fail under zsh-sourced
	# interactive use even though the script declares `#!/usr/bin/env bash`.
	local _check_state=""
	# shellcheck disable=SC2016 # jq program uses $active as a jq variable.
	if ! _check_state=$(_gh_checks_api_read "repos/${slug}/commits/${sha}/check-suites" --jq '
		((.check_suites // []) | map(select(.conclusion != null or .status != "queued"))) as $active |
		if ($active | length) == 0 then "none"
		elif ($active | all(.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral")) then "PASS"
		elif ($active | any(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")) then "FAIL"
		else "PENDING"
		end' 2>/dev/null); then
		return 1
	fi
	_gh_pr_check_status_cache_class "$_check_state" >/dev/null || return 1
	printf '%s\n' "$_check_state"
	return 0
}

#######################################
# Fetch and publish one aggregate observation. A coordinated leader must still
# own its generation immediately before the cache write.
# Args: $1=repo slug, $2=full head SHA, $3=request key (optional),
#       $4=lease generation (optional), $5=invalidation generation (optional)
#######################################
_gh_pr_check_status_fetch_and_cache() {
	local slug="$1"
	local sha="$2"
	local request_key="${3:-}"
	local generation="${4:-}"
	local invalidation_generation="${5:-}"
	local check_state=""
	_GH_PR_CHECK_STATUS_FETCH_INVALIDATED=0
	if [[ -z "$request_key" ]]; then
		request_key="$(_gh_pr_check_status_request_key "$slug" "$sha")" || return 1
	fi
	if [[ -z "$invalidation_generation" ]]; then
		invalidation_generation=$(_gh_pr_check_status_invalidation_generation "$slug" "$sha") || return 1
	fi
	_gh_pr_check_status_cache_record fetch
	if ! check_state="$(_gh_pr_check_status_rest_fetch "$slug" "$sha")"; then
		_gh_pr_check_status_cache_record fetch-failed
		return 1
	fi
	if [[ -n "$request_key" && -n "$generation" ]] && ! gh_request_state_singleflight_is_owner "$request_key" "$generation"; then
		_gh_pr_check_status_cache_record publish-fenced
		return 1
	fi
	if ! _gh_pr_check_status_invalidation_generation_is_current "$slug" "$sha" "$invalidation_generation"; then
		_GH_PR_CHECK_STATUS_FETCH_INVALIDATED=1
		_gh_pr_check_status_cache_record publish-invalidated
		return 1
	fi
	if [[ "${AIDEVOPS_GH_CHECK_STATUS_CACHE_DISABLE:-0}" == "1" ]]; then
		printf '%s\n' "$check_state"
		return 0
	fi
	_gh_pr_check_status_cache_put "$slug" "$sha" "$check_state" "$invalidation_generation"
	if [[ -n "$request_key" && "$_GH_PR_CHECK_STATUS_CACHE_PUT_OK" != "1" ]]; then
		_gh_pr_check_status_cache_record publish-failed
		return 1
	fi
	if ! _gh_pr_check_status_invalidation_generation_is_current "$slug" "$sha" "$invalidation_generation"; then
		_GH_PR_CHECK_STATUS_FETCH_INVALIDATED=1
		_gh_pr_check_status_cache_record publish-invalidated
		return 1
	fi
	printf '%s\n' "$check_state"
	return 0
}

#######################################
# Coordinate only the exact-SHA aggregate check-suites cache miss. Named check
# runs remain deliberately outside this path because they have different output
# and freshness semantics.
# Args: $1=repo slug, $2=full head SHA
#######################################
_gh_pr_check_status_singleflight() {
	local slug="$1"
	local sha="$2"
	local request_key=""
	local generation=""
	local invalidation_generation=""
	local check_state=""
	local attempts=0
	if [[ "${AIDEVOPS_GH_CHECK_STATUS_CACHE_DISABLE:-0}" == "1" ]] || ! declare -F gh_request_state_singleflight_begin >/dev/null 2>&1; then
		_gh_pr_check_status_fetch_and_cache "$slug" "$sha" || printf 'none\n'
		return 0
	fi
	request_key="$(_gh_pr_check_status_request_key "$slug" "$sha")" || {
		_gh_pr_check_status_fetch_and_cache "$slug" "$sha" || printf 'none\n'
		return 0
	}
	while [[ "$attempts" -lt 2 ]]; do
		attempts=$((attempts + 1))
		gh_request_state_singleflight_begin "$request_key"
		generation="$_GHRS_BEGIN_GENERATION"
		case "$_GHRS_BEGIN_ROLE" in
	leader)
		if check_state="$(_gh_pr_check_status_cache_get "$slug" "$sha")"; then
			gh_request_state_singleflight_finish "$request_key" "$generation" success || true
			printf '%s\n' "$check_state"
			return 0
		fi
		invalidation_generation=$(_gh_pr_check_status_invalidation_generation "$slug" "$sha") || invalidation_generation=""
		if [[ -n "$invalidation_generation" ]] && \
			_gh_pr_check_status_fetch_and_cache "$slug" "$sha" "$request_key" "$generation" "$invalidation_generation"; then
			gh_request_state_singleflight_finish "$request_key" "$generation" success || true
			return 0
		fi
		gh_request_state_singleflight_finish "$request_key" "$generation" failure || true
		if [[ "$_GH_PR_CHECK_STATUS_FETCH_INVALIDATED" == "1" && "$attempts" -lt 2 ]]; then
			continue
		fi
		printf 'none\n'
		return 0
		;;
	follower-success)
		_gh_pr_check_status_cache_record coalesced
		if _gh_pr_check_status_cache_get "$slug" "$sha"; then
			return 0
		fi
		[[ "$attempts" -lt 2 ]] && continue
		printf 'none\n'
		return 0
		;;
	follower-failure | timeout)
		_gh_pr_check_status_cache_record "coalesced-${_GHRS_BEGIN_ROLE}"
		printf 'none\n'
		return 0
		;;
	bypass)
		_gh_pr_check_status_fetch_and_cache "$slug" "$sha" || printf 'none\n'
		return 0
		;;
		esac
	done
	printf 'none\n'
	return 0
}

gh_pr_check_status_rest() {
	local slug="$1"
	local sha="$2"

	if [[ -z "$slug" || -z "$sha" ]]; then
		printf 'none\n'
		return 0
	fi

	local _check_state=""
	if _check_state="$(_gh_pr_check_status_cache_get "$slug" "$sha")"; then
		printf '%s\n' "$_check_state"
		return 0
	fi

	_gh_pr_check_status_singleflight "$slug" "$sha"
	return $?
}

#######################################
# Fetch all PR check states (check-runs + legacy status contexts) for a PR
# via REST `/commits/{sha}/check-runs` and `/commits/{sha}/status`.
#
# Heavier than check-suites (~111KB/PR) but returns per-context .name and
# .conclusion fields needed for name-based matching. Use ONLY in single-PR
# paths that need name-based filtering (required-status-check matching,
# named-check exclusions).
#
# Combines two endpoints because GitHub branch-protection required_status_checks
# can list either type:
#   - check-runs (GitHub Actions, Apps): `.name`, `.conclusion`, `.status`
#   - status contexts (legacy CI, repo statuses): `.context`, `.state`
# Status contexts are normalised to look like check-runs so consumers can
# match uniformly on `.name` and `.conclusion`.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - commit SHA
#
# Output (stdout): JSON array of normalised check entries:
#   [{"name":"...","conclusion":"success|failure|null","status":"..."}, ...]
#   Empty array "[]" on missing args / API error.
# Returns: 0 always
#######################################
gh_pr_check_runs_rest() {
	local slug="$1"
	local sha="$2"

	if [[ -z "$slug" || -z "$sha" ]]; then
		echo "[]"
		return 0
	fi

	# 1. Modern check-runs (GitHub Actions / GitHub Apps) — AUTHORITATIVE.
	# Almost all check signal in modern repos lives here. If this endpoint
	# fails, we emit empty so callers can fail-closed; /status alone is
	# insufficient signal for branch-protection gating.
	local runs=""
	runs=$(_gh_checks_api_read "repos/${slug}/commits/${sha}/check-runs" --paginate \
		--jq '[.check_runs[]? | {name, conclusion, status}]' 2>/dev/null) || runs=""

	if [[ -z "$runs" ]]; then
		# /check-runs unreachable or empty output — emit empty so callers
		# distinguish "fetch failed" from "no checks recorded".
		echo ""
		return 0
	fi

	# 2. Legacy combined status (third-party CI services, repo statuses) —
	# SUPPLEMENT only. Normalise each entry to the check-run shape so
	# consumers see a uniform `.name`/`.conclusion`/`.status` triple
	# regardless of source. state mapping: success→success,
	# failure/error→failure, pending→null + status="in_progress".
	local statuses=""
	# Normalise each status entry to the check-run shape.  jq variables
	# ($ok/$fail) avoid repeating "success"/"failure" literals three times
	# each across the file (string-literal ratchet gate).
	# shellcheck disable=SC2016  # $ok/$fail are jq variables, not bash expansions
	statuses=$(_gh_checks_api_read "repos/${slug}/commits/${sha}/status" \
		--jq '[.statuses[]? |
			"success" as $ok | "failure" as $fail |
			{
				name: .context,
				conclusion: (
					if .state == $ok
					then $ok
					elif .state == $fail or .state == "error"
					then $fail
					else null
					end
				),
				status: (
					if .state == "pending"
					then "in_progress"
					else "completed"
					end
				)
			}
		]' 2>/dev/null) || statuses=""

	# Concatenate possibly-multi-page check-runs output, then merge with
	# normalised statuses. `jq -s 'add'` flattens into a single array.
	# /status failure here is non-fatal: /check-runs already succeeded.
	local merged=""
	if [[ -n "$statuses" ]]; then
		merged=$(printf '%s\n%s' "$runs" "$statuses" | jq -s 'add // []' 2>/dev/null) || merged=""
	else
		merged=$(printf '%s' "$runs" | jq -s 'add // []' 2>/dev/null) || merged=""
	fi
	[[ -n "$merged" ]] || merged="[]"

	echo "$merged"
	return 0
}

#######################################
# Batch-enrich a PR list with aggregated REST check status.
#
# Resolves each unique full head SHA once, reusing fresh aggregate cache entries
# and fetching only missing/expired/actionable identities. It then fans the
# state back out to every input PR in original order.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - JSON array of PR objects with at least .number and .headRefOid
#
# Output (stdout): JSON array `[{"number":N,"status":"PASS|FAIL|PENDING|none"}, ...]`
#   Empty array "[]" on missing args / empty input / parse error.
# Returns: 0 always
#######################################
gh_pr_check_status_rest_batch() {
	local slug="$1"
	local pr_json="$2"

	if [[ -z "$slug" || -z "$pr_json" || "$pr_json" == "null" || "$pr_json" == "[]" ]]; then
		echo "[]"
		return 0
	fi

	# Extract (number, sha) pairs as TSV; one PR per line.
	local pairs=""
	pairs=$(printf '%s' "$pr_json" | jq -r '.[] | select(.number and .headRefOid) | [.number, .headRefOid] | @tsv' 2>/dev/null) || pairs=""

	if [[ -z "$pairs" ]]; then
		echo "[]"
		return 0
	fi

	local unique_shas=""
	unique_shas=$(printf '%s\n' "$pairs" | awk -F '\t' 'NF >= 2 && !seen[$2]++ {print $2}')
	[[ -n "$unique_shas" ]] || {
		printf '[]\n'
		return 0
	}

	# Build one SHA→state map. A tmpfile avoids bash 3.2 pipeline-subshell
	# variable loss while keeping duplicate identities transport-free.
	local tmp=""
	tmp=$(mktemp 2>/dev/null) || {
		printf '[]\n'
		return 0
	}
	# NOTE: see gh_pr_check_status_rest above — `status` is read-only in zsh.
	local pr_sha="" _check_state=""
	while IFS= read -r pr_sha; do
		[[ -n "$pr_sha" ]] || continue
		_gh_pr_check_status_record_actionable_head "$slug" "$pr_sha"
		_check_state=$(gh_pr_check_status_rest "$slug" "$pr_sha")
		printf '%s\t%s\n' "$pr_sha" "$_check_state" >>"$tmp"
	done <<<"$unique_shas"

	local result=""
	result=$(jq -n --argjson prs "$pr_json" --rawfile states "$tmp" \
		--arg none_state "$_GH_PR_CHECK_STATUS_NONE" '
		($states | split("\n") |
			map(select(length > 0) | split("\t") | select(length == 2) | {(.[0]): .[1]}) |
			add // {}) as $state_map |
		[$prs[] | select(.number and .headRefOid) |
			{number: .number, status: ($state_map[.headRefOid] // $none_state)}]' 2>/dev/null) || result="[]"
	rm -f "$tmp"
	[[ -n "$result" && "$result" != "null" ]] || result="[]"

	echo "$result"
	return 0
}
