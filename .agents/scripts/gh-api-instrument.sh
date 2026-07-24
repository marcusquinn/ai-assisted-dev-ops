#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-api-instrument.sh -- Lightweight gh API call instrumentation (t2902)
# =============================================================================
# Records logical routing/cache events separately from native gh transport
# attempts. Attempts include stable logical/attempt identities, retry/page
# metadata, outcome, elapsed time, and known quota cost without recording argv,
# request bodies, headers, tokens, or query values. Aggregation produces
# a JSON report at ~/.aidevops/logs/gh-api-calls-by-stage.json so heavy
# GraphQL consumers can be identified and routed through the separate REST
# core pool (t2574, t2689) or the Search API bucket where applicable.
#
# Why this exists (t2902):
#   The pulse circuit breaker fires repeatedly even though REST fallback
#   covers writes (t2574) and reads (t2689). Something is still draining
#   GraphQL between resets. Without per-call-site visibility, the heavy
#   consumer is invisible. This file is a minimum-overhead recorder; it
#   adds one bounded append to a tab-separated log per event or attempt.
#
# Usage from a sourced shell script:
#
#     source "${SCRIPT_DIR}/gh-api-instrument.sh"
#     # Before calling a GraphQL-backed gh command:
#     gh_record_call graphql
#     gh issue create ...
#     # After falling back to REST:
#     gh_record_call rest
#     gh api /repos/.../issues
#
# CLI usage:
#
#     gh-api-instrument.sh record <path> [caller] [auth] [pool] [decision] [budget]
#     gh-api-instrument.sh report [out_path]        # aggregate to JSON
#     gh-api-instrument.sh trim                     # rotate log if oversize
#     gh-api-instrument.sh clear                    # wipe log + report
#
# Path values (fixed enum):
#   graphql        — gh CLI command that internally hits the GraphQL endpoint
#   rest           — gh api or REST translator that hits the core REST pool
#   search-graphql — gh search issues/prs/code/repos (GraphQL Search API)
#   search-rest    — REST per-repo iteration replacing a search call
#   other          — anything not covered above (counted but not partitioned)
#
# Legacy log format (TSV, still readable):
#   <unix_ts>\t<caller_basename>\t<path>\t<auth_mode>\t<api_pool>\t<route_decision>\t<budget_remaining>
# Version 2 appends these privacy-safe fields after the legacy prefix:
#   v2\t<event_kind>\t<logical_id>\t<attempt_id>\t<page>\t<retry>\t<outcome>\t<http_status>\t<elapsed_ms>\t<quota_cost>
#
# Override env vars:
#   AIDEVOPS_GH_API_LOG          — path to the log file (default
#                                   ~/.aidevops/logs/gh-api-calls.log)
#   AIDEVOPS_GH_API_REPORT       — path to the JSON report (default
#                                   ~/.aidevops/logs/gh-api-calls-by-stage.json)
#   AIDEVOPS_GH_API_EVIDENCE     — path to the digest-bound evidence sidecar
#                                   (default ~/.aidevops/logs/gh-api-efficiency-evidence.json)
#   AIDEVOPS_GH_API_EVIDENCE_DISABLE=1 — skip automatic sidecar generation
#   AIDEVOPS_GH_API_LOG_MAX_LINES — when set and exceeded, trim() retains
#                                   the newest bounded records (default 1000000)
#   AIDEVOPS_GH_API_LOG_MAX_BYTES — maximum retained log bytes (default 128 MiB)
#   AIDEVOPS_GH_API_RETENTION_SECONDS — maximum record age (default 172800)
#   AIDEVOPS_GH_API_EMPTY_LOCK_GRACE_TRIES — 10ms waits before reclaiming an
#                                   empty lock directory (default 100)
#   AIDEVOPS_GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS — minimum age before exact
#                                   legacy .source/.tmp/.trim files are reaped
#                                   (default 3600)
#   AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1 — make all calls no-ops
#
# Part of aidevops framework: https://aidevops.sh
# =============================================================================

# Include guard — safe to source multiple times.
[[ -n "${_GH_API_INSTRUMENT_LOADED:-}" ]] && return 0
_GH_API_INSTRUMENT_LOADED=1

# Apply strict mode only when executed directly (not when sourced).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Legacy scratch cleanup needs portable file timestamps, but this helper is
# also sourced standalone by the gh shim. Load only the focused stat library;
# sourcing shared-constants.sh here would create a circular dependency through
# shared-gh-wrappers.sh.
_GH_API_INSTRUMENT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_GH_API_INSTRUMENT_DIR" == "${BASH_SOURCE[0]}" ]] && _GH_API_INSTRUMENT_DIR="."
if ! command -v _file_mtime_epoch >/dev/null 2>&1 &&
	[[ -f "${_GH_API_INSTRUMENT_DIR}/portable-stat.sh" ]]; then
	# shellcheck source=portable-stat.sh
	source "${_GH_API_INSTRUMENT_DIR}/portable-stat.sh"
fi

# --- Configuration --------------------------------------------------------
_GH_API_HOME="${HOME:-}"
if [[ -z "$_GH_API_HOME" ]]; then
	_GH_API_UID="${UID:-}"
	[[ -z "$_GH_API_UID" ]] && _GH_API_UID="$(id -u)"
	if command -v getent >/dev/null 2>&1; then
		_GH_API_HOME="$(getent passwd "$_GH_API_UID" | cut -d: -f6 || true)"
	fi
	_GH_API_HOME="${_GH_API_HOME:-${TMPDIR:-/tmp}/aidevops-${USER:-${_GH_API_UID:-shared}}}"
fi

# If HOME cannot be resolved and we must fall back under a shared temporary
# parent, create/lock down a user-owned root before any nested log path exists.
# Otherwise a pre-created /tmp/aidevops-* tree can contain symlinks that make the
# later append follow attacker-controlled paths.
case "$_GH_API_HOME" in
"${TMPDIR:-/tmp}"/* | /tmp/*)
	if [[ -L "$_GH_API_HOME" ]]; then
		AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1
	elif [[ ! -e "$_GH_API_HOME" ]]; then
		mkdir -p "$_GH_API_HOME" 2>/dev/null || AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1
	fi
	if [[ -e "$_GH_API_HOME" && "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" != "1" ]]; then
		if [[ ! -O "$_GH_API_HOME" || -L "$_GH_API_HOME" ]]; then
			AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1
		else
			chmod 0700 "$_GH_API_HOME" || true
		fi
	fi
	;;
esac
GH_API_LOG="${AIDEVOPS_GH_API_LOG:-${_GH_API_HOME}/.aidevops/logs/gh-api-calls.log}"
GH_API_REPORT="${AIDEVOPS_GH_API_REPORT:-${_GH_API_HOME}/.aidevops/logs/gh-api-calls-by-stage.json}"
GH_API_EVIDENCE="${AIDEVOPS_GH_API_EVIDENCE:-${_GH_API_HOME}/.aidevops/logs/gh-api-efficiency-evidence.json}"
_GH_API_DEFAULT_LOG_MAX_LINES=1000000
_GH_API_DEFAULT_LOG_MAX_BYTES=134217728
_GH_API_DEFAULT_RETENTION_SECONDS=172800
GH_API_LOG_MAX_LINES="${AIDEVOPS_GH_API_LOG_MAX_LINES:-$_GH_API_DEFAULT_LOG_MAX_LINES}"
GH_API_LOG_MAX_BYTES="${AIDEVOPS_GH_API_LOG_MAX_BYTES:-$_GH_API_DEFAULT_LOG_MAX_BYTES}"
GH_API_RETENTION_SECONDS="${AIDEVOPS_GH_API_RETENTION_SECONDS:-$_GH_API_DEFAULT_RETENTION_SECONDS}"
GH_API_ERROR_KEY="error"
_GH_API_EMPTY_LOCK_GRACE_TRIES="${AIDEVOPS_GH_API_EMPTY_LOCK_GRACE_TRIES:-100}"
[[ "$_GH_API_EMPTY_LOCK_GRACE_TRIES" =~ ^[0-9]+$ ]] || _GH_API_EMPTY_LOCK_GRACE_TRIES=100
_GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS="${AIDEVOPS_GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS:-3600}"
[[ "$_GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS" =~ ^[0-9]+$ ]] || _GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS=3600
_GH_API_SCRATCH_DIR=""

_gh_now_seconds() {
	local now=""
	printf -v now '%(%s)T' -1 2>/dev/null || now=$(date +%s 2>/dev/null) || return 1
	printf '%s\n' "$now"
	return 0
}

_gh_now_ms() {
	local now=""
	if command -v perl >/dev/null 2>&1; then
		now=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000' 2>/dev/null || true)
	elif command -v python3 >/dev/null 2>&1; then
		now=$(python3 -c 'import time; print(round(time.time() * 1000))' 2>/dev/null || true)
	fi
	if [[ ! "$now" =~ ^[0-9]+$ ]]; then
		now=$(_gh_now_seconds) || return 1
		now=$((now * 1000))
	fi
	printf '%s\n' "$now"
	return 0
}

_gh_managed_scratch_owner_pid() {
	local basename="$1"
	if [[ "$basename" =~ ^(report|source|trim)\.([1-9][0-9]*)\.[[:alnum:]]{6}$ ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

# Remove only framework-owned scratch files whose filename carries a dead
# creator PID. The private directory and exact basename grammar keep unrelated
# files and symlinks outside the deletion boundary.
_gh_cleanup_managed_scratch() {
	local scratch_dir="$1"
	local candidate=""
	local basename=""
	local owner_pid=""
	[[ -d "$scratch_dir" && ! -L "$scratch_dir" && -O "$scratch_dir" ]] || return 1
	for candidate in \
		"$scratch_dir"/report.*.* \
		"$scratch_dir"/source.*.* \
		"$scratch_dir"/trim.*.*; do
		[[ -f "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || continue
		basename="${candidate##*/}"
		owner_pid=$(_gh_managed_scratch_owner_pid "$basename") || continue
		if ! kill -0 "$owner_pid" 2>/dev/null; then
			rm -f "$candidate" 2>/dev/null || true
		fi
	done
	return 0
}

# Scratch files that must be renamed atomically live in a private child of the
# destination directory. This preserves same-filesystem rename semantics while
# keeping transient files out of the durable log namespace.
_gh_prepare_scratch_dir() {
	local target="$1"
	local target_dir="."
	local scratch_dir=""
	[[ -n "$target" ]] || return 1
	if [[ "$target" == */* ]]; then
		target_dir="${target%/*}"
		[[ -n "$target_dir" ]] || target_dir="/"
	fi
	[[ -d "$target_dir" && ! -L "$target_dir" && -O "$target_dir" ]] || return 1
	scratch_dir="${target_dir%/}/.gh-api-instrument-scratch"
	[[ -n "$scratch_dir" ]] || return 1
	if [[ ! -e "$scratch_dir" && ! -L "$scratch_dir" ]]; then
		if ! (umask 077 && mkdir "$scratch_dir" 2>/dev/null); then
			[[ -d "$scratch_dir" && ! -L "$scratch_dir" ]] || return 1
		fi
	fi
	[[ -d "$scratch_dir" && ! -L "$scratch_dir" && -O "$scratch_dir" ]] || return 1
	chmod 0700 "$scratch_dir" 2>/dev/null || return 1
	_GH_API_SCRATCH_DIR="$scratch_dir"
	_gh_cleanup_managed_scratch "$scratch_dir" || return 1
	return 0
}

# Migrate exact pre-owner scratch names left by older releases. These files do
# not encode a PID, so deletion is restricted to regular user-owned files under
# configured output prefixes and a conservative age floor.
_gh_cleanup_legacy_scratch() {
	local candidate=""
	local candidate_dir="."
	local legacy_prefix=""
	local legacy_suffix=""
	local modified=""
	local now=""
	local age=0
	command -v _file_mtime_epoch >/dev/null 2>&1 || return 0
	now=$(_gh_now_seconds) || return 0
	for candidate in \
		"${GH_API_REPORT}.source."* \
		"${GH_API_REPORT}.tmp."* \
		"${GH_API_LOG}.trim."*; do
		[[ -f "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || continue
		case "$candidate" in
		"${GH_API_REPORT}.source."*) legacy_prefix="${GH_API_REPORT}.source." ;;
		"${GH_API_REPORT}.tmp."*) legacy_prefix="${GH_API_REPORT}.tmp." ;;
		"${GH_API_LOG}.trim."*) legacy_prefix="${GH_API_LOG}.trim." ;;
		*) continue ;;
		esac
		legacy_suffix="${candidate#"$legacy_prefix"}"
		[[ "$legacy_suffix" =~ ^[[:alnum:]]{6}$ ]] || continue
		if [[ "$candidate" == */* ]]; then
			candidate_dir="${candidate%/*}"
			[[ -n "$candidate_dir" ]] || candidate_dir="/"
		else
			candidate_dir="."
		fi
		[[ -d "$candidate_dir" && ! -L "$candidate_dir" && -O "$candidate_dir" ]] || continue
		modified=$(_file_mtime_epoch "$candidate") || continue
		[[ "$now" -ge "$modified" ]] || continue
		age=$((now - modified))
		[[ "$age" -ge "$_GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS" ]] || continue
		rm -f "$candidate" 2>/dev/null || true
	done
	return 0
}

_gh_safe_text() {
	local value="$1"
	local fallback="$2"
	value="${value##*/}"
	if [[ "$value" =~ ^[A-Za-z0-9_.:+-]+$ ]]; then
		printf '%s' "$value"
	else
		printf '%s' "$fallback"
	fi
	return 0
}

_gh_safe_number() {
	local value="$1"
	[[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value"
	return 0
}

_gh_default_pool() {
	local path="$1"
	case "$path" in
	graphql | search-graphql) printf 'graphql' ;;
	rest) printf 'rest-core' ;;
	search-rest) printf 'rest-search' ;;
	*) printf 'other' ;;
	esac
	return 0
}

_gh_default_auth() {
	local api_pool="$1"
	case "$api_pool" in
	rest-core | rest-search)
		if command -v github_app_is_configured >/dev/null 2>&1 && github_app_is_configured; then
			printf 'github-app'
		else
			printf 'gh-pat'
		fi
		;;
	*) printf 'gh-pat' ;;
	esac
	return 0
}

_gh_resolve_caller() {
	local caller="$1"
	local i=1
	local src=""
	if [[ -z "$caller" ]]; then
		while [[ $i -lt ${#BASH_SOURCE[@]} ]]; do
			src="${BASH_SOURCE[$i]}"
			if [[ -n "$src" && "${src##*/}" != "gh-api-instrument.sh" ]]; then
				caller="${src##*/}"
				break
			fi
			i=$((i + 1))
		done
		[[ -z "$caller" ]] && caller="${0##*/}"
	fi
	case "$caller" in
	"" | -bash | bash) caller="unknown" ;;
	esac
	_gh_safe_text "$caller" unknown
	return 0
}

_gh_log_lock_reclaim() {
	local lock_dir="$1"
	local tries="$2"
	local pid_path="${lock_dir}/pid"
	local owner=""
	[[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
	if [[ -f "$pid_path" && ! -L "$pid_path" ]]; then
		if ! IFS= read -r owner 2>/dev/null <"$pid_path"; then
			owner=""
		fi
		if [[ -n "$owner" ]]; then
			if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
				return 1
			fi
			rm -f "$pid_path" 2>/dev/null || return 1
			rmdir "$lock_dir" 2>/dev/null || return 1
			return 0
		fi
	fi
	# mkdir and PID publication are separate operations. Give a live owner one
	# second to publish an empty PID, then reclaim it if its owner was killed
	# inside that gap. Malformed and dead PIDs are reclaimed immediately.
	# rmdir still fails closed if unexpected files exist.
	[[ "$tries" -ge "${_GH_API_EMPTY_LOCK_GRACE_TRIES:-100}" ]] || return 1
	[[ ! -L "$pid_path" ]] || return 1
	rm -f "$pid_path" 2>/dev/null || return 1
	rmdir "$lock_dir" 2>/dev/null || return 1
	return 0
}

_gh_log_lock_acquire() {
	local lock_dir="${GH_API_LOG}.lock"
	local tries=0
	local owner_pid="${BASHPID:-$$}"
	command -v mkdir >/dev/null 2>&1 || return 1
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if _gh_log_lock_reclaim "$lock_dir" "$tries"; then
			tries=0
			continue
		fi
		tries=$((tries + 1))
		[[ $tries -ge 200 ]] && return 1
		command -v sleep >/dev/null 2>&1 || return 1
		sleep 0.01
	done
	if ! printf '%s\n' "$owner_pid" >"$lock_dir/pid" 2>/dev/null; then
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	fi
	return 0
}

_gh_log_lock_release() {
	local lock_dir="${GH_API_LOG}.lock"
	rm -f "$lock_dir/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_gh_append_record() {
	local record="$1"
	[[ ${#record} -le 4000 ]] || return 0
	[[ "$GH_API_LOG" == */* ]] && mkdir -p "${GH_API_LOG%/*}" 2>/dev/null || true
	_gh_log_lock_acquire || return 0
	printf '%s\n' "$record" >>"$GH_API_LOG" 2>/dev/null || true
	_gh_log_lock_release
	return 0
}

gh_new_logical_id() {
	local ts=""
	ts=$(_gh_now_seconds) || ts=0
	printf 'l%s-%s-%s\n' "$ts" "${BASHPID:-$$}" "${RANDOM:-0}"
	return 0
}

gh_new_attempt_id() {
	local logical_id="$1"
	_GH_API_ATTEMPT_SEQUENCE=$((${_GH_API_ATTEMPT_SEQUENCE:-0} + 1))
	printf '%s-a%s-%s-%s\n' "$logical_id" "${BASHPID:-$$}" "$_GH_API_ATTEMPT_SEQUENCE" "${RANDOM:-0}"
	return 0
}

gh_attempt_count_for_logical() {
	local logical_id="$1"
	[[ -f "$GH_API_LOG" ]] || {
		printf '0\n'
		return 0
	}
	awk -F'\t' -v logical_id="$logical_id" \
		'$8 == "v2" && $9 == "attempt" && $10 == logical_id { count++ } END { print count + 0 }' \
		"$GH_API_LOG" 2>/dev/null || printf '0\n'
	return 0
}

_gh_append_v2() {
	local event_kind="$1"
	shift
	local caller="$1"
	shift
	local path="$1"
	shift
	local auth_mode="$1"
	shift
	local api_pool="$1"
	shift
	local route_decision="$1"
	shift
	local budget_remaining="$1"
	shift
	local logical_id="$1"
	shift
	local attempt_id="$1"
	shift
	local page="$1"
	shift
	local retry="$1"
	shift
	local outcome="$1"
	shift
	local http_status="$1"
	shift
	local elapsed_ms="$1"
	shift
	local quota_cost="$1"
	shift
	local recorded_at="${1:-}"
	local ts=""
	local record=""
	if [[ -n "$recorded_at" ]]; then
		[[ "$recorded_at" =~ ^[1-9][0-9]*$ ]] || return 1
		ts="$recorded_at"
	else
		ts=$(_gh_now_seconds) || return 0
	fi
	caller=$(_gh_resolve_caller "$caller")
	path=$(_gh_safe_text "$path" other)
	auth_mode=$(_gh_safe_text "$auth_mode" unknown)
	api_pool=$(_gh_safe_text "$api_pool" other)
	route_decision=$(_gh_safe_text "$route_decision" unspecified)
	event_kind=$(_gh_safe_text "$event_kind" logical)
	logical_id=$(_gh_safe_text "$logical_id" unknown)
	attempt_id=$(_gh_safe_text "$attempt_id" unknown)
	outcome=$(_gh_safe_text "$outcome" unknown)
	budget_remaining=$(_gh_safe_number "$budget_remaining")
	page=$(_gh_safe_number "$page")
	retry=$(_gh_safe_number "$retry")
	http_status=$(_gh_safe_number "$http_status")
	elapsed_ms=$(_gh_safe_number "$elapsed_ms")
	quota_cost=$(_gh_safe_number "$quota_cost")
	printf -v record '%s\t%s\t%s\t%s\t%s\t%s\t%s\tv2\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
		"$ts" "$caller" "$path" "$auth_mode" "$api_pool" "$route_decision" "$budget_remaining" \
		"$event_kind" "$logical_id" "$attempt_id" "$page" "$retry" "$outcome" "$http_status" "$elapsed_ms" "$quota_cost"
	_gh_append_record "$record"
	return 0
}

# --- gh_record_call <path> [caller] [auth] [pool] [decision] [budget] [kind]
# Append a logical routing or cache event. Existing six-argument callers remain
# compatible; known cache decisions are classified automatically.
# Failure is silent — instrumentation must never break the host script.
#
# Args:
#   $1 path   — one of: graphql | rest | search-graphql | search-rest | other
#   $2 caller — optional; defaults to BASH_SOURCE[1] basename. Pass an
#               explicit caller when wrapping is multiple frames deep.
#   $3 auth   — optional auth mode: github-app | gh-pat | unknown.
#   $4 pool   — optional API pool: graphql | rest-core | rest-search | other.
#   $5 route  — optional route decision string.
#   $6 budget — optional remaining budget for the route's limiting pool.
#
# Returns: 0 always.
gh_record_call() {
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]] && return 0
	local path="${1:-other}"
	local caller="${2:-}"
	local auth_mode="${3:-${AIDEVOPS_GH_AUTH_MODE:-}}"
	local api_pool="${4:-${AIDEVOPS_GH_API_POOL:-}}"
	local route_decision="${5:-${AIDEVOPS_GH_ROUTE_DECISION:-}}"
	local budget_remaining="${6:-${AIDEVOPS_GH_BUDGET_REMAINING:-${_GH_LAST_GRAPHQL_REMAINING:-}}}"
	local event_kind="${7:-logical}"
	local logical_id="${AIDEVOPS_GH_LOGICAL_ID:-}"
	caller=$(_gh_resolve_caller "$caller")
	if [[ -z "$api_pool" ]]; then
		api_pool=$(_gh_default_pool "$path")
	fi
	if [[ -z "$auth_mode" ]]; then
		auth_mode=$(_gh_default_auth "$api_pool")
	fi
	[[ -z "$route_decision" ]] && route_decision="${api_pool}-selected"
	case "$route_decision" in
	hit | miss | store | stale | invalid-json | bypass | bypass-disabled) event_kind="cache" ;;
	esac
	[[ -n "$logical_id" ]] || logical_id=$(gh_new_logical_id)
	_gh_append_v2 "$event_kind" "$caller" "$path" "$auth_mode" "$api_pool" "$route_decision" \
		"$budget_remaining" "$logical_id" "" "" "" "" "" "" ""
	return 0
}

# --- gh_record_efficiency_evidence <name> [value] [recorded_at] ---------
# Append a typed, privacy-safe benchmark evidence event. Names and values are
# restricted to bounded identifiers; repository names, URLs, payloads, and
# credentials are never accepted. The optional epoch aligns a completed-cycle
# boundary's record timestamp with its already-captured inclusive cutoff and is
# rejected if it is in the future. Returns 1 for an invalid event.
gh_record_efficiency_evidence() {
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]] && return 0
	local name="$1"
	local value="${2:-1}"
	local recorded_at="${3:-}"
	local current_now=""
	local decision=""
	if [[ ! "$name" =~ ^[a-z][a-z0-9_.-]{0,95}$ ]]; then
		return 1
	fi
	if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; then
		return 1
	fi
	if [[ -n "$recorded_at" ]]; then
		[[ "$recorded_at" =~ ^[1-9][0-9]*$ ]] || return 1
		current_now=$(_gh_now_seconds) || return 1
		[[ "$recorded_at" -le "$current_now" ]] || return 1
	fi
	decision="evidence:${name}:${value}"
	_gh_append_v2 evidence github-api-efficiency other unknown other "$decision" \
		"" "" "" "" "" "" "" "" "" "$recorded_at"
	return $?
}

# --- gh_record_attempt ---------------------------------------------------
# Record one completed native transport try/page. Arguments are metadata only;
# command argv never enters the record.
gh_record_attempt() {
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]] && return 0
	local path="$1"
	shift
	local caller="$1"
	shift
	local logical_id="$1"
	shift
	local attempt_id="$1"
	shift
	local page="$1"
	shift
	local retry="$1"
	shift
	local outcome="$1"
	shift
	local http_status="$1"
	shift
	local elapsed_ms="$1"
	shift
	local quota_cost="$1"
	shift
	local auth_mode="$1"
	shift
	local api_pool="$1"
	shift
	local route_decision="$1"
	shift
	local budget_remaining="$1"
	[[ -n "$logical_id" ]] || logical_id=$(gh_new_logical_id)
	[[ -n "$attempt_id" ]] || attempt_id=$(gh_new_attempt_id "$logical_id")
	[[ -n "$page" ]] || page=1
	[[ -n "$retry" ]] || retry=0
	[[ -n "$api_pool" ]] || api_pool=$(_gh_default_pool "$path")
	[[ -n "$auth_mode" ]] || auth_mode="${AIDEVOPS_GH_AUTH_MODE:-$(_gh_default_auth "$api_pool")}"
	[[ -n "$route_decision" ]] || route_decision="${AIDEVOPS_GH_ROUTE_DECISION:-${api_pool}-selected}"
	_gh_append_v2 attempt "$caller" "$path" "$auth_mode" "$api_pool" "$route_decision" \
		"$budget_remaining" "$logical_id" "$attempt_id" "$page" "$retry" "$outcome" \
		"$http_status" "$elapsed_ms" "$quota_cost"
	return 0
}

# --- gh_run_transport_attempt <path> <caller> <logical> <page> <retry> -- cmd
# Execute one native transport command with unmodified stdout and status. Normal
# mode appends one process-level attempt; exact capture may append one record per
# response frame or none for a proven local-only command. Telemetry failures
# remain fail-open.
gh_run_transport_attempt() {
	local path="$1"
	shift
	local caller="$1"
	shift
	local logical_id="$1"
	shift
	local page="$1"
	shift
	local retry="$1"
	shift
	[[ "${1:-}" == "--" ]] && shift
	local start_ms=""
	local end_ms=""
	local elapsed_ms=""
	local rc=0
	local capture_rc=0
	local outcome="success"
	local quota_cost="${AIDEVOPS_GH_QUOTA_COST:-}"
	local success_quota_cost="${AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS:-}"
	if declare -F _ghqa_run_transport_attempt >/dev/null 2>&1 \
		&& [[ "${AIDEVOPS_GH_EXACT_QUOTA_CAPTURE:-0}" == "1" ]]; then
		_GHQA_TRANSPORT_HANDLED=0
		if _ghqa_run_transport_attempt "$path" "$caller" "$logical_id" "$page" "$retry" -- "$@"; then
			capture_rc=0
		else
			capture_rc=$?
		fi
		if [[ "${_GHQA_TRANSPORT_HANDLED:-0}" == "1" ]]; then
			return "$capture_rc"
		fi
	fi
	start_ms=$(_gh_now_ms) || start_ms=""
	if "$@"; then
		rc=0
		if [[ -z "$quota_cost" && -n "$success_quota_cost" ]]; then
			quota_cost="$success_quota_cost"
		fi
	else
		rc=$?
		outcome="$GH_API_ERROR_KEY"
	fi
	end_ms=$(_gh_now_ms) || end_ms=""
	if [[ "$start_ms" =~ ^[0-9]+$ && "$end_ms" =~ ^[0-9]+$ && "$end_ms" -ge "$start_ms" ]]; then
		elapsed_ms=$((end_ms - start_ms))
	fi
	gh_record_attempt "$path" "$caller" "$logical_id" "" "$page" "$retry" "$outcome" \
		"${AIDEVOPS_GH_HTTP_STATUS:-}" "$elapsed_ms" "$quota_cost" \
		"${AIDEVOPS_GH_AUTH_MODE:-}" "${AIDEVOPS_GH_API_POOL:-}" "${AIDEVOPS_GH_ROUTE_DECISION:-}" \
		"${AIDEVOPS_GH_BUDGET_REMAINING:-${_GH_LAST_GRAPHQL_REMAINING:-}}"
	return "$rc"
}

# Generate a digest-bound sidecar for the production aggregate. Evidence build
# failures remain fail-open for the host process and fail-closed for comparison.
_gh_write_efficiency_sidecar() {
	local report="$1"
	local output="${2:-$GH_API_EVIDENCE}"
	local script_dir="${BASH_SOURCE[0]%/*}"
	local producer="${script_dir}/github-api-efficiency-evidence.sh"
	[[ "${AIDEVOPS_GH_API_EVIDENCE_DISABLE:-0}" != "1" ]] || return 0
	[[ -f "$report" && -x "$producer" ]] || return 0
	if ! "$producer" build --transport-report "$report" --output "$output" >/dev/null 2>&1; then
		rm -f "$output" 2>/dev/null || true
	fi
	return 0
}

# Copy one stable input while holding the same short-lived lock as appenders.
# Aggregation then reads the private snapshot without chasing a growing log.
_gh_snapshot_log() {
	local destination="$1"
	_gh_log_lock_acquire || return 1
	if ! cp "$GH_API_LOG" "$destination" 2>/dev/null; then
		_gh_log_lock_release
		return 1
	fi
	_gh_log_lock_release
	chmod 0600 "$destination" 2>/dev/null || true
	return 0
}

# --- gh_aggregate_calls [out_path] [window_secs] [end_ts] ----------------
# Snapshot the active log and atomically publish a deterministic JSON report.
# An explicit end timestamp creates a completed-cycle cutoff even while other
# processes keep appending. Successful production reports automatically receive
# a SHA-256-bound evidence sidecar.
gh_aggregate_calls() {
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]] && return 0
	local out="${1:-$GH_API_REPORT}"
	local window="${2:-86400}"
	local requested_end="${3:-}"
	local current_now=""
	local now=""
	local cutoff=0
	local out_dir="."
	local tmp=""
	local snapshot=""
	local awk_script=""
	local owner_pid="${BASHPID:-$$}"
	[[ "$window" =~ ^[1-9][0-9]*$ ]] || window=86400
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 1
	current_now=$(_gh_now_seconds) || return 1
	now="$current_now"
	if [[ -n "$requested_end" ]]; then
		[[ "$requested_end" =~ ^[1-9][0-9]*$ && "$requested_end" -le "$current_now" ]] || return 1
		now="$requested_end"
	fi
	cutoff=$((now - window))
	if [[ "$out" == */* ]]; then
		out_dir="${out%/*}"
	fi
	mkdir -p "$out_dir" 2>/dev/null || return 1
	_gh_cleanup_legacy_scratch || true
	_gh_prepare_scratch_dir "$out" || return 1
	tmp=$(mktemp "${_GH_API_SCRATCH_DIR}/report.${owner_pid}.XXXXXX" 2>/dev/null) || return 1
	chmod 600 "$tmp" 2>/dev/null || {
		rm -f "$tmp"
		return 1
	}
	if [[ ! -f "$GH_API_LOG" ]]; then
		printf '{"_meta":{"%s":"no-log","schema_version":2,"requested_window_seconds":%d,"window_seconds":%d},"by_caller":{}}\n' \
			"$GH_API_ERROR_KEY" "$window" "$window" >"$tmp" 2>/dev/null || {
			rm -f "$tmp"
			return 1
		}
		mv "$tmp" "$out" 2>/dev/null || {
			rm -f "$tmp"
			return 1
		}
		return 1
	fi
	awk_script="${BASH_SOURCE[0]%/*}/gh-api-aggregate.awk"
	if [[ ! -f "$awk_script" ]]; then
		printf '{"_meta":{"%s":"missing-awk-script","path":"%s"},"by_caller":{}}\n' \
			"$GH_API_ERROR_KEY" "$awk_script" >"$tmp" 2>/dev/null || true
		mv "$tmp" "$out" 2>/dev/null || rm -f "$tmp"
		return 1
	fi
	snapshot=$(mktemp "${_GH_API_SCRATCH_DIR}/source.${owner_pid}.XXXXXX" 2>/dev/null) || {
		rm -f "$tmp"
		return 1
	}
	chmod 0600 "$snapshot" 2>/dev/null || true
	if ! _gh_snapshot_log "$snapshot"; then
		rm -f "$tmp" "$snapshot"
		return 1
	fi
	if ! awk -F'\t' -v now="$now" -v cutoff="$cutoff" -v window="$window" \
		-f "$awk_script" "$snapshot" >"$tmp" 2>/dev/null; then
		rm -f "$tmp" "$snapshot"
		return 1
	fi
	rm -f "$snapshot"
	if ! mv "$tmp" "$out" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	if [[ "$out" == "$GH_API_REPORT" ]]; then
		_gh_write_efficiency_sidecar "$out" "$GH_API_EVIDENCE"
	fi
	return 0
}

# --- gh_trim_log ----------------------------------------------------------
# Atomically retain only valid records within the configured age, line, and byte
# bounds. Appenders share the same short-lived lock so replacement cannot lose
# a concurrent record. The original remains untouched if filtering fails.
gh_trim_log() {
	local now=""
	local cutoff=0
	local tmp=""
	local owner_pid="${BASHPID:-$$}"
	_gh_cleanup_legacy_scratch || true
	[[ -f "$GH_API_LOG" ]] || return 0
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 0
	[[ "$GH_API_LOG_MAX_LINES" =~ ^[0-9]+$ && "$GH_API_LOG_MAX_LINES" -gt 0 ]] || GH_API_LOG_MAX_LINES="$_GH_API_DEFAULT_LOG_MAX_LINES"
	[[ "$GH_API_LOG_MAX_BYTES" =~ ^[0-9]+$ && "$GH_API_LOG_MAX_BYTES" -gt 0 ]] || GH_API_LOG_MAX_BYTES="$_GH_API_DEFAULT_LOG_MAX_BYTES"
	[[ "$GH_API_RETENTION_SECONDS" =~ ^[0-9]+$ && "$GH_API_RETENTION_SECONDS" -gt 0 ]] || GH_API_RETENTION_SECONDS="$_GH_API_DEFAULT_RETENTION_SECONDS"
	now=$(_gh_now_seconds) || return 0
	cutoff=$((now - GH_API_RETENTION_SECONDS))
	_gh_prepare_scratch_dir "$GH_API_LOG" || return 0
	_gh_log_lock_acquire || return 0
	tmp=$(mktemp "${_GH_API_SCRATCH_DIR}/trim.${owner_pid}.XXXXXX") || {
		_gh_log_lock_release
		return 0
	}
	chmod 0600 "$tmp" 2>/dev/null || {
		rm -f "$tmp" 2>/dev/null || true
		_gh_log_lock_release
		return 0
	}
	if LC_ALL=C awk -F'\t' -v cutoff="$cutoff" -v max_lines="$GH_API_LOG_MAX_LINES" -v max_bytes="$GH_API_LOG_MAX_BYTES" '
		$1 ~ /^[0-9]+$/ && $1 >= cutoff {
			last++
			rows[last] = $0
			row_bytes[last] = length($0) + 1
			bytes += row_bytes[last]
			while (first < last && ((last - first) > max_lines || bytes > max_bytes)) {
				first++
				bytes -= row_bytes[first]
				delete rows[first]
				delete row_bytes[first]
			}
		}
		END {
			for (i = first + 1; i <= last; i++) {
				if (i in rows) print rows[i]
			}
		}
	' "$GH_API_LOG" >"$tmp" 2>/dev/null && mv "$tmp" "$GH_API_LOG" 2>/dev/null; then
		:
	else
		rm -f "$tmp" 2>/dev/null || true
	fi
	_gh_log_lock_release
	return 0
}

# --- gh_clear_log ---------------------------------------------------------
# Remove the log + report. Used by tests and by the `clear` subcommand.
gh_clear_log() {
	rm -f "$GH_API_LOG" "$GH_API_REPORT" "$GH_API_EVIDENCE" 2>/dev/null
	return 0
}

# --- CLI dispatch ---------------------------------------------------------
# Only runs when executed directly (not when sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	cmd="${1:-help}"
	shift || true
	case "$cmd" in
	record)
		gh_record_call "$@"
		;;
	evidence)
		gh_record_efficiency_evidence "$@"
		;;
	report | aggregate)
		gh_aggregate_calls "$@"
		printf 'Wrote %s\n' "${1:-$GH_API_REPORT}" >&2
		;;
	trim)
		gh_trim_log
		;;
	clear)
		gh_clear_log
		;;
	help | --help | -h)
		cat <<EOF
gh-api-instrument.sh — gh API call instrumentation (t2902)

Subcommands:
  record <path> [caller] [auth] [pool] [decision] [budget]
                          Append one routing/cache record
  evidence <name> [value] Append one typed benchmark evidence record
  report [out] [window_s] [end_ts]
                          Aggregate a fixed-cutoff JSON window
                          (default ${GH_API_REPORT##*/}, 24h, current time)
  trim                     Atomically apply age, line, and byte retention bounds
  clear                    Remove log + report

Path values:
  graphql | rest | search-graphql | search-rest | other

See header comments for full env-var reference.
EOF
		;;
	*)
		printf 'Unknown subcommand: %s\n' "$cmd" >&2
		printf 'Run "%s help" for usage.\n' "${0##*/}" >&2
		exit 2
		;;
	esac
fi
