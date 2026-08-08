#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-rate-limit-circuit-breaker.sh — Pulse GraphQL breaker and REST priority budget (t2690, GH#20310, GH#29742)
#
# Proactive defence: pauses worker dispatch when the GitHub GraphQL rate-limit
# budget is exhausted or nearly exhausted. Without this, the pulse keeps spawning
# workers that fail at step 1 (issue read / PR create / issue edit), burning
# $0.05–$0.25 per doomed dispatch and triggering watchdog kills.
#
# Defence-in-depth layers (all complementary):
#   - t2574: REST fallback for CREATE/EDIT operations (reactive, per-call)
#   - t2689: REST fallback for READ operations (reactive, per-call)
#   - THIS: proactive dispatch pause (prevents spawning workers that will fail)
#
# Subcommands:
#   check   — exit 0 if budget is sufficient (dispatch may proceed),
#             exit 1 if tripped or REST evidence blocks dispatch,
#             exit 2 when GraphQL is unavailable after REST authorizes fail-open
#   status  — print human-readable status to stdout (for `aidevops status`)
#   help    — usage information
#
# Environment overrides:
#   AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD — fraction of total budget below
#     which the breaker trips (default 0.05 = 5% = 250/5000). Set to 0 to
#     disable the GraphQL check; REST priority gating remains active. Tuned as
#     an emergency floor (t2896): the previous
#     0.30 raise (t2744) was justified to "preserve headroom for in-flight
#     reads", but t2689 shipped read-side REST fallback after t2744 — reads
#     now route through the 5000/hr REST core pool when GraphQL is low.
#     With t2574 (write-side) and t2689 (read-side) REST fallbacks both
#     active, the GraphQL reserve is mostly redundant for in-flight ops.
#     Operational data: 43 fires/4.5 days at 0.30, GraphQL still hit 0/5000
#     during fires — the breaker fires alongside exhaustion, not preventing
#     it. 0.05 restores the original t2690 emergency-floor value: still
#     fires in genuine exhaustion (last 250 points), recovers ~25% of
#     dispatch budget for productive work.
#   AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1 — emergency bypass (dispatch proceeds
#     unconditionally, logged)
#
# Integration:
#   Sourced by pulse-dispatch-engine.sh. The `is_graphql_budget_sufficient`
#   function is called at the top of `_dispatch_compute_capacity` and at the start
#   of `apply_dispatch_max` — one cheap check that gates all dispatch.
#
# Counter:
#   `pulse_dispatch_circuit_broken` in ~/.aidevops/logs/pulse-stats.json
#   (via pulse-stats-helper.sh). Surfaced by `aidevops status`.
#
# Multi-runner: concurrent local runners share a short-lived, auth-scoped rate
# snapshot and single-flight probe. Remote runners retain independent local state.
#
# Cost: `gh api rate_limit` is free. The authoritative REST `user` probe costs
# at most one core request per cache TTL across local concurrent runners.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=./shared-gh-request-state.sh
if [[ -f "${SCRIPT_DIR}/shared-gh-request-state.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/shared-gh-request-state.sh"
fi

# Source pulse-stats-helper.sh for counter support (optional — fail-open if missing).
# shellcheck source=pulse-stats-helper.sh
if [[ -f "${SCRIPT_DIR}/pulse-stats-helper.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/pulse-stats-helper.sh"
fi

# Source canonical circuit-breaker threshold from conf file (GH#20638, t2768).
# Existing values take precedence; the conf fills every missing default; 0.05
# is the hardcoded fallback if the conf file is missing (graceful degradation).
# Sourced here so standalone invocations also receive partial-config defaults.
_CB_RL_CONF="${SCRIPT_DIR}/../configs/pulse-rate-limit.conf"
if [[ -f "$_CB_RL_CONF" ]]; then
	# shellcheck disable=SC1090
	source "$_CB_RL_CONF"
fi

# LOGFILE for sourced-mode usage (caller sets it; standalone mode defines a default).
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

# State file for tracking when the breaker last tripped (for status reporting).
_CIRCUIT_BREAKER_STATE_FILE="${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state"

# Short-lived cache for the free rate_limit endpoint. The dispatch loop can ask
# for budget state once per candidate; caching keeps diagnostics and in-loop
# checks from hammering GitHub while preserving sub-minute recovery.
_CB_RL_CACHE_FILE="${AIDEVOPS_PULSE_RATE_LIMIT_CACHE:-${HOME}/.aidevops/cache/pulse-graphql-rate-limit.json}"
_CB_RL_CACHE_TTL="${AIDEVOPS_PULSE_RATE_LIMIT_CACHE_TTL:-20}"
_CB_RL_MODE_CACHED_ONLY="cached-only"

# REST-core observations deliberately use a separate cache: the /rate_limit
# projection can describe a different principal from the one serving a routed
# REST request. A response header is authoritative for the request principal.
_CB_REST_CORE_CACHE_FILE="${AIDEVOPS_PULSE_REST_CORE_CACHE:-${HOME}/.aidevops/cache/pulse-rest-core.json}"
_CB_REST_CORE_PROBE_TTL="${AIDEVOPS_PULSE_REST_CORE_PROBE_TTL:-20}"
_CB_REST_CORE_RESOURCE="core"
_CB_REST_CORE_UNKNOWN="unknown"
_CB_REST_CORE_UNKNOWN_STATE_FILE="${AIDEVOPS_PULSE_REST_CORE_UNKNOWN_STATE:-${HOME}/.aidevops/cache/pulse-rest-core-unknown.state}"

# Log prefix for all messages from this module.
_CB_RL_LOG_PREFIX="[circuit-breaker-rl]"

# Unknown value placeholder for status output.
_CB_RL_UNKNOWN="?"

#######################################
# Run a GitHub CLI read with a bounded wall-clock.
#
# Args:
#   Remaining arguments form the command to execute.
#
# Stdout: command stdout.
#######################################
_cb_gh_read() {
	local rc=0
	local secs="${AIDEVOPS_GH_READ_TIMEOUT:-15}"
	[[ "$secs" =~ ^[0-9]+$ ]] || secs=15

	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	elif declare -F timeout_sec >/dev/null 2>&1; then
		timeout_sec "$secs" "$@" || rc=$?
	elif command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@" || rc=$?
	elif command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$secs" "$@" || rc=$?
	else
		return 1
	fi

	return "$rc"
}

#######################################
# Fetch the full rate-limit projection through the circuit breaker's timeout.
#######################################
_cb_rate_limit_transport() {
	_cb_gh_read gh api rate_limit
	return $?
}

#######################################
# Read GitHub rate-limit state with a short TTL cache.
#
# Args:
#   $1 - mode: normal (default) or cached-only
#
# Stdout: raw `gh api rate_limit` JSON.
#######################################
_cb_rate_limit_json() {
	local mode="${1:-normal}"
	local ttl="$_CB_RL_CACHE_TTL"
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=20
	if declare -F gh_request_state_rate_json >/dev/null 2>&1; then
		gh_request_state_rate_json "$mode" "$ttl" _cb_rate_limit_transport
		return $?
	fi
	[[ "$mode" == "$_CB_RL_MODE_CACHED_ONLY" ]] && return 1
	_cb_rate_limit_transport
	return $?
}

#######################################
# Probe REST core using response headers from the active gh principal.
#
# Stdout: the final HTTP response block, including headers. `-i` is essential:
# rate_limit JSON is a projection and can identify a different principal.
#######################################
_cb_rest_core_probe() {
	_cb_gh_read gh api -i user
	return $?
}

#######################################
# Extract one response-header value from the final HTTP response block.
#######################################
_cb_rest_core_header() {
	local response="$1"
	local name="$2"
	printf '%s\n' "$response" | awk -v wanted="$name" '
		BEGIN { IGNORECASE=1 }
		/^HTTP\// { value=""; next }
		{
			line=$0
			sub(/\r$/, "", line)
			if (tolower(line) ~ "^" tolower(wanted) ":[[:space:]]*") {
				sub(/^[^:]*:[[:space:]]*/, "", line)
				value=line
			}
		}
		END { print value }
	'
	return 0
}

#######################################
# Return normalized REST-core priority bounds.
#
# Stdout: "<soft-cap> <hard-floor> <window-seconds>".
#######################################
_cb_rest_core_bounds() {
	local soft_cap="${AIDEVOPS_PULSE_REST_CORE_RESERVE:-${AIDEVOPS_PULSE_REST_DISPATCH_MIN_CORE_REMAINING:-500}}"
	local hard_floor="${AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR:-100}"
	local window_seconds="${AIDEVOPS_PULSE_REST_CORE_ADAPTIVE_WINDOW_SECONDS:-3600}"
	[[ "$soft_cap" =~ ^[0-9]+$ ]] || soft_cap=500
	[[ "$hard_floor" =~ ^[0-9]+$ ]] || hard_floor=100
	[[ "$window_seconds" =~ ^[1-9][0-9]*$ ]] || window_seconds=3600
	if [[ "$soft_cap" -eq 0 ]]; then
		hard_floor=0
	elif [[ "$hard_floor" -gt "$soft_cap" ]]; then
		hard_floor="$soft_cap"
	fi
	printf '%s %s %s\n' "$soft_cap" "$hard_floor" "$window_seconds"
	return 0
}

#######################################
# Return normalized headroom reserved for already-admitted REST work.
#######################################
_cb_rest_core_in_flight_allowance() {
	local allowance="${AIDEVOPS_PULSE_REST_CORE_IN_FLIGHT_ALLOWANCE:-250}"
	[[ "$allowance" =~ ^[0-9]+$ ]] || allowance=250
	printf '%s\n' "$allowance"
	return 0
}

#######################################
# Return the minimum remaining budget required to launch progress work.
# Args: $1=hard floor, $2=soft cap
#######################################
_cb_rest_core_progress_start_floor() {
	local hard_floor="$1"
	local soft_cap="$2"
	[[ "$hard_floor" =~ ^[0-9]+$ ]] || return 1
	[[ "$soft_cap" =~ ^[0-9]+$ ]] || return 1
	if [[ "$soft_cap" -eq 0 ]]; then
		printf '0\n'
		return 0
	fi
	local allowance
	allowance=$(_cb_rest_core_in_flight_allowance)
	printf '%s\n' "$((hard_floor + allowance))"
	return 0
}

#######################################
# Return normalized cache TTL for launch-gate observations.
#######################################
_cb_rest_core_gate_probe_ttl() {
	local ttl="${AIDEVOPS_PULSE_REST_CORE_GATE_PROBE_TTL:-2}"
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=2
	printf '%s\n' "$ttl"
	return 0
}

#######################################
# Compute the adaptive REST-core soft threshold for a reset epoch.
#
# Args:
#   $1 - reset epoch
#   $2 - current epoch
#
# Stdout: "<adaptive-threshold> <soft-cap> <hard-floor>".
#######################################
_cb_rest_core_thresholds() {
	local reset_epoch="$1"
	local now_epoch="$2"
	local soft_cap
	local hard_floor
	local window_seconds
	read -r soft_cap hard_floor window_seconds < <(_cb_rest_core_bounds)
	[[ "$reset_epoch" =~ ^[0-9]+$ ]] || return 1
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	if [[ "$soft_cap" -eq 0 ]]; then
		printf '0 0 0\n'
		return 0
	fi

	local seconds_until_reset=0
	if [[ "$reset_epoch" -gt "$now_epoch" ]]; then
		seconds_until_reset=$((reset_epoch - now_epoch))
	fi
	[[ "$seconds_until_reset" -le "$window_seconds" ]] || seconds_until_reset="$window_seconds"

	local reserve_span=$((soft_cap - hard_floor))
	local adaptive_threshold=$((hard_floor + (reserve_span * seconds_until_reset + window_seconds - 1) / window_seconds))
	[[ "$adaptive_threshold" -ge "$hard_floor" ]] || adaptive_threshold="$hard_floor"
	[[ "$adaptive_threshold" -le "$soft_cap" ]] || adaptive_threshold="$soft_cap"
	printf '%s %s %s\n' "$adaptive_threshold" "$soft_cap" "$hard_floor"
	return 0
}

#######################################
# Read an authoritative REST-core observation from cache or response headers.
#
# Stdout: "<remaining> <limit> <reset-epoch>".
# Returns: 0 on valid evidence; 2 on unavailable or malformed evidence.
# Cached observations are never used past their TTL or GitHub reset epoch.
#######################################
_cb_rest_core_observation() {
	local ttl="${1:-$_CB_REST_CORE_PROBE_TTL}"
	local now observed=0 remaining limit reset resource
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=20
	now=$(date +%s 2>/dev/null) || now=0
	[[ "$now" =~ ^[0-9]+$ ]] || now=0

	if [[ -f "$_CB_REST_CORE_CACHE_FILE" ]]; then
		read -r observed remaining limit reset resource < <(jq -r --arg unknown "$_CB_REST_CORE_UNKNOWN" '[.observed // 0, .remaining // $unknown, .limit // $unknown, .reset // 0, .resource // $unknown] | @tsv' "$_CB_REST_CORE_CACHE_FILE" 2>/dev/null) || true
		if [[ "$observed" =~ ^[0-9]+$ && "$remaining" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ && "$reset" =~ ^[0-9]+$ &&
			"$resource" == "$_CB_REST_CORE_RESOURCE" && "$now" -ge "$observed" && "$now" -lt "$reset" ]]; then
			local cache_age=$((now - observed))
			if [[ "$cache_age" -le "$ttl" ]]; then
				printf '%s %s %s\n' "$remaining" "$limit" "$reset"
				return 0
			fi
		fi
	fi

	local response
	response=$(_cb_rest_core_probe) || return 2
	remaining=$(_cb_rest_core_header "$response" "X-RateLimit-Remaining")
	limit=$(_cb_rest_core_header "$response" "X-RateLimit-Limit")
	reset=$(_cb_rest_core_header "$response" "X-RateLimit-Reset")
	resource=$(_cb_rest_core_header "$response" "X-RateLimit-Resource")
	if [[ ! "$remaining" =~ ^[0-9]+$ || ! "$limit" =~ ^[0-9]+$ || ! "$reset" =~ ^[0-9]+$ || "$resource" != "$_CB_REST_CORE_RESOURCE" || "$reset" -le "$now" ]]; then
		return 2
	fi
	local cache_dir
	local cache_tmp
	cache_dir=$(dirname "$_CB_REST_CORE_CACHE_FILE")
	cache_tmp="${_CB_REST_CORE_CACHE_FILE}.tmp.$$"
	mkdir -p "$cache_dir" 2>/dev/null || true
	if jq -cn --arg resource "$_CB_REST_CORE_RESOURCE" --argjson observed "$now" --argjson remaining "$remaining" \
		--argjson limit "$limit" --argjson reset "$reset" \
		'{observed: $observed, remaining: $remaining, limit: $limit, reset: $reset, resource: $resource}' \
		>"$cache_tmp" 2>/dev/null; then
		mv "$cache_tmp" "$_CB_REST_CORE_CACHE_FILE" 2>/dev/null || rm -f "$cache_tmp" 2>/dev/null || true
	else
		rm -f "$cache_tmp" 2>/dev/null || true
	fi
	printf '%s %s %s\n' "$remaining" "$limit" "$reset"
	return 0
}

#######################################
# Classify authoritative REST-core headroom for stage-boundary scheduling.
# Args: $1=optional cache TTL override.
#
# Stdout:
#   "<mode> <remaining> <limit> <adaptive> <soft-cap> <hard-floor> <reset>"
# Modes: normal, reserve, emergency, disabled, unknown.
#######################################
pulse_rest_core_priority_snapshot() {
	local observation_ttl="${1:-}"
	local soft_cap
	local hard_floor
	local window_seconds
	read -r soft_cap hard_floor window_seconds < <(_cb_rest_core_bounds)
	if [[ "${AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER:-0}" == "1" || "$soft_cap" -eq 0 ]]; then
		printf 'disabled ? ? 0 %s %s ?\n' "$soft_cap" "$hard_floor"
		return 0
	fi

	local observation
	local remaining
	local limit
	local reset_epoch
	observation=$(_cb_rest_core_observation "$observation_ttl") || observation=""
	if [[ -z "$observation" ]]; then
		printf 'unknown ? ? ? %s %s ?\n' "$soft_cap" "$hard_floor"
		return 0
	fi
	read -r remaining limit reset_epoch <<<"$observation"

	local adaptive_threshold=""
	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	if [[ ! "$reset_epoch" =~ ^[0-9]+$ || "$reset_epoch" -le "$now_epoch" ]]; then
		printf 'unknown ? ? ? %s %s ?\n' "$soft_cap" "$hard_floor"
		return 0
	fi
	read -r adaptive_threshold soft_cap hard_floor < <(_cb_rest_core_thresholds "$reset_epoch" "$now_epoch") || adaptive_threshold=""
	if [[ ! "$remaining" =~ ^[0-9]+$ || ! "$limit" =~ ^[0-9]+$ || ! "$adaptive_threshold" =~ ^[0-9]+$ ]]; then
		printf 'unknown ? ? ? %s %s ?\n' "$soft_cap" "$hard_floor"
		return 0
	fi

	local mode="normal"
	if [[ "$remaining" -le "$hard_floor" ]]; then
		mode="emergency"
	elif [[ "$remaining" -le "$adaptive_threshold" ]]; then
		mode="reserve"
	fi
	printf '%s %s %s %s %s %s %s\n' "$mode" "$remaining" "$limit" "$adaptive_threshold" "$soft_cap" "$hard_floor" "$reset_epoch"
	return 0
}

#######################################
# Reset the bounded unknown-evidence streak after an authoritative observation.
#######################################
_cb_rest_core_reset_unknown_progress_streak() {
	rm -f "$_CB_REST_CORE_UNKNOWN_STATE_FILE" 2>/dev/null || true
	return 0
}

#######################################
# Permit progress after a bounded streak of distinct unknown gate-probe slots.
# Deferrable work never calls this helper and remains fail-closed.
#######################################
_cb_rest_core_unknown_progress_allows() {
	local limit="${AIDEVOPS_PULSE_REST_CORE_UNKNOWN_PROGRESS_LIMIT:-3}"
	local gate_ttl
	local now
	local slot
	local state_dir
	local state_slot=""
	local state_count=0
	local lock_dir
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=3
	[[ "$limit" -gt 0 ]] || return 2
	gate_ttl=$(_cb_rest_core_gate_probe_ttl)
	[[ "$gate_ttl" =~ ^[1-9][0-9]*$ ]] || gate_ttl=1
	now=$(date +%s 2>/dev/null) || now=0
	[[ "$now" =~ ^[0-9]+$ ]] || return 2
	slot=$((now / gate_ttl))
	state_dir=$(dirname "$_CB_REST_CORE_UNKNOWN_STATE_FILE")
	lock_dir="${_CB_REST_CORE_UNKNOWN_STATE_FILE}.lock"
	mkdir -p "$state_dir" 2>/dev/null || return 2
	mkdir "$lock_dir" 2>/dev/null || return 2
	if [[ -f "$_CB_REST_CORE_UNKNOWN_STATE_FILE" ]]; then
		read -r state_slot state_count <"$_CB_REST_CORE_UNKNOWN_STATE_FILE" || true
	fi
	[[ "$state_count" =~ ^[0-9]+$ ]] || state_count=0
	if [[ "$state_slot" != "$slot" ]]; then
		state_count=$((state_count + 1))
		printf '%s %s\n' "$slot" "$state_count" >"${_CB_REST_CORE_UNKNOWN_STATE_FILE}.tmp.$$" &&
			mv "${_CB_REST_CORE_UNKNOWN_STATE_FILE}.tmp.$$" "$_CB_REST_CORE_UNKNOWN_STATE_FILE" 2>/dev/null || true
	fi
	rmdir "$lock_dir" 2>/dev/null || true
	[[ "$state_count" -ge "$limit" ]] && return 0
	return 2
}

#######################################
# Apply a REST priority class to one already-observed budget snapshot.
#
# Args:
#   $1 - critical, progress, or deferrable.
#   $2 - output from pulse_rest_core_priority_snapshot.
# Returns: 0 allowed; 1 deferred by threshold; 2 unknown/invalid evidence.
#######################################
_cb_rest_core_priority_decision_allows() {
	local priority="$1"
	local decision="$2"
	case "$priority" in
	critical)
		return 0
		;;
	progress | deferrable) ;;
	*) return 2 ;;
	esac

	local mode
	local remaining
	local limit
	local adaptive
	local soft_cap
	local hard_floor
	local reset_epoch
	read -r mode remaining limit adaptive soft_cap hard_floor reset_epoch <<<"$decision"
	case "$mode" in
	disabled)
		_cb_rest_core_reset_unknown_progress_streak
		return 0
		;;
	normal | reserve | emergency)
		_cb_rest_core_reset_unknown_progress_streak
		;;
	unknown)
		[[ "$priority" == "progress" ]] || return 2
		_cb_rest_core_unknown_progress_allows
		return $?
		;;
	*)
		return 2
		;;
	esac
	if [[ ! "$remaining" =~ ^[0-9]+$ || ! "$adaptive" =~ ^[0-9]+$ || ! "$soft_cap" =~ ^[0-9]+$ || ! "$hard_floor" =~ ^[0-9]+$ ]]; then
		return 2
	fi

	local progress_start_floor
	progress_start_floor=$(_cb_rest_core_progress_start_floor "$hard_floor" "$soft_cap") || return 2
	if [[ "$priority" == "progress" ]]; then
		[[ "$remaining" -gt "$progress_start_floor" ]] && return 0
		return 1
	fi

	local deferrable_start_floor="$adaptive"
	if [[ "$progress_start_floor" -gt "$deferrable_start_floor" ]]; then
		deferrable_start_floor="$progress_start_floor"
	fi
	[[ "$remaining" -gt "$deferrable_start_floor" ]] && return 0
	return 1
}

#######################################
# Return whether a REST priority class may start new API-heavy work.
#
# Args: $1 - critical, progress, or deferrable.
# Returns: 0 allowed; 1 deferred by threshold; 2 unknown/invalid evidence.
#######################################
pulse_rest_core_priority_allows() {
	local priority="$1"
	case "$priority" in
	critical)
		return 0
		;;
	progress | deferrable) ;;
	*) return 2 ;;
	esac

	local decision
	decision=$(pulse_rest_core_priority_snapshot)
	_cb_rest_core_priority_decision_allows "$priority" "$decision"
	return $?
}

#######################################
# Return whether one new API-heavy work unit may start using a fresh-enough
# authoritative observation. Repeated checks share the short gate cache.
# Args: $1=priority, $2=static log context (optional).
# Returns: 0 allowed; 1 threshold block; 2 unknown/invalid evidence.
#######################################
pulse_rest_core_priority_allows_next() {
	local priority="$1"
	local context="${2:-unspecified}"
	case "$priority" in
	critical)
		return 0
		;;
	progress | deferrable) ;;
	*) return 2 ;;
	esac

	local decision
	local gate_ttl
	local decision_rc=0
	gate_ttl=$(_cb_rest_core_gate_probe_ttl)
	decision=$(pulse_rest_core_priority_snapshot "$gate_ttl")
	_cb_rest_core_priority_decision_allows "$priority" "$decision" || decision_rc=$?
	[[ "$decision_rc" -eq 0 ]] && return 0

	local mode remaining limit adaptive soft_cap hard_floor reset_epoch progress_start_floor="?"
	read -r mode remaining limit adaptive soft_cap hard_floor reset_epoch <<<"$decision"
	if [[ "$hard_floor" =~ ^[0-9]+$ && "$soft_cap" =~ ^[0-9]+$ ]]; then
		progress_start_floor=$(_cb_rest_core_progress_start_floor "$hard_floor" "$soft_cap") || progress_start_floor="?"
	fi
	echo "${_CB_RL_LOG_PREFIX} REST-core ${priority} unit blocked: context=${context} mode=${mode} remaining=${remaining}/${limit} adaptive=${adaptive} progress_start_floor=${progress_start_floor} reset=${reset_epoch} rc=${decision_rc} (GH#29742)" >>"$LOGFILE"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "pulse_rest_core_unit_blocked" 2>/dev/null || true
		pulse_stats_increment "pulse_rest_core_unit_blocked_${priority}" 2>/dev/null || true
	fi
	return "$decision_rc"
}

#######################################
# Backward-compatible optional-work reserve entrypoint.
#######################################
pulse_rest_core_reserve_allows() {
	pulse_rest_core_priority_allows deferrable
	return $?
}

#######################################
# Describe why the REST-core progress policy rejected a stage.
#######################################
_cb_rest_core_progress_block_reason() {
	local progress_rc="$1"
	case "$progress_rc" in
	1) printf 'known REST-core progress launch floor reached\n' ;;
	2) printf 'authoritative REST-core quota evidence unavailable\n' ;;
	*) printf 'unexpected REST-core progress decision (rc=%s)\n' "$progress_rc" ;;
	esac
	return 0
}

#######################################
# Gate new dispatch work at the hard floor and on unknown REST evidence. Unknown
# evidence fails closed until AIDEVOPS_PULSE_REST_CORE_UNKNOWN_PROGRESS_LIMIT
# distinct gate-probe slots are unknown; then only progress work resumes.
# A limit of 0 preserves permanent fail-closed behavior, and a valid observation
# resets the streak. Deferrable work remains deferred throughout.
#######################################
_cb_rest_core_progress_allows_dispatch() {
	local decision
	local mode
	local remaining
	local limit
	local adaptive
	local soft_cap
	local hard_floor
	local reset_epoch
	decision=$(pulse_rest_core_priority_snapshot "$(_cb_rest_core_gate_probe_ttl)")
	local progress_rc=0
	_cb_rest_core_priority_decision_allows progress "$decision" || progress_rc=$?
	[[ "$progress_rc" -eq 0 ]] && return 0

	read -r mode remaining limit adaptive soft_cap hard_floor reset_epoch <<<"$decision"
	local block_reason
	block_reason=$(_cb_rest_core_progress_block_reason "$progress_rc")
	local progress_start_floor="?"
	if [[ "$hard_floor" =~ ^[0-9]+$ && "$soft_cap" =~ ^[0-9]+$ ]]; then
		progress_start_floor=$(_cb_rest_core_progress_start_floor "$hard_floor" "$soft_cap") || progress_start_floor="?"
	fi
	echo "${_CB_RL_LOG_PREFIX} REST-core progress gate blocked: ${block_reason}; deferring until a later authoritative probe allows progress; mode=${mode} remaining=${remaining}/${limit} adaptive=${adaptive} soft_cap=${soft_cap} hard_floor=${hard_floor} progress_start_floor=${progress_start_floor} reset=${reset_epoch} rc=${progress_rc} (GH#29742)" >>"$LOGFILE"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "pulse_rest_core_progress_blocked" 2>/dev/null || true
		pulse_stats_increment "pulse_rest_core_progress_blocked_${mode}" 2>/dev/null || true
	fi
	return 1
}

#######################################
# Allow degraded dispatch when only GraphQL is exhausted.
#
# Args:
#   $1 - rate_limit JSON
#   $2 - GraphQL remaining count
#   $3 - GraphQL limit count
#   $4 - GraphQL threshold count
#   $5 - configured GraphQL threshold string
#
# Returns: 0 if REST fallback is active and dispatch may proceed, 1 otherwise.
#######################################
_cb_allow_dispatch_with_rest_fallback() {
	local rate_json="$1"
	local graphql_remaining="$2"
	local graphql_limit="$3"
	local graphql_threshold_count="$4"
	local threshold="$5"

	if [[ "${AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK:-1}" != "1" ]]; then
		return 1
	fi

	local core_rc=0
	if declare -F pulse_rest_core_priority_allows_next >/dev/null 2>&1; then
		pulse_rest_core_priority_allows_next progress "graphql_rest_fallback" || core_rc=$?
	else
		pulse_rest_core_priority_allows progress || core_rc=$?
	fi
	if [[ "$core_rc" -ne 0 ]]; then
		local block_reason
		block_reason=$(_cb_rest_core_progress_block_reason "$core_rc")
		echo "${_CB_RL_LOG_PREFIX} GraphQL budget exhausted and REST fallback unavailable: ${block_reason}; deferring until a later authoritative probe allows progress (rc=${core_rc})" >>"$LOGFILE"
		return 1
	fi

	export AIDEVOPS_GH_FORCE_REST_READS=1
	export AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK_ACTIVE=1
	export AIDEVOPS_PULSE_DISPATCH_REST_FALLBACK_CORE_REMAINING="header-authorized"
	echo "${_CB_RL_LOG_PREFIX} GraphQL budget EXHAUSTED: remaining=${graphql_remaining}/${graphql_limit} (threshold=${graphql_threshold_count}, configured=${threshold}) — dispatch_rest_fallback=true; proceeding with header-authorized REST-backed dispatch reads" >>"$LOGFILE"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "pulse_dispatch_rest_fallback" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Gate GraphQL projection failures through independent REST-core evidence.
#
# Args:
#   $1 - diagnostic reason the GraphQL projection is unusable.
#
# Returns: 1 when REST blocks dispatch; 2 when REST authorizes GraphQL fail-open.
#######################################
_cb_graphql_projection_unavailable() {
	local reason="$1"
	echo "${_CB_RL_LOG_PREFIX} WARNING: ${reason}; checking the independent REST-core progress gate before GraphQL fail-open" >>"$LOGFILE"
	if ! _cb_rest_core_progress_allows_dispatch; then
		return 1
	fi

	echo "${_CB_RL_LOG_PREFIX} WARNING: GraphQL projection unavailable but authoritative REST-core evidence permits progress — proceeding with dispatch (fail-open)" >>"$LOGFILE"
	return 2
}

#######################################
# Check whether the GitHub GraphQL rate-limit budget is sufficient for dispatch.
# Falls back to REST-backed dispatch when GraphQL is exhausted but REST core has
# enough headroom for issue/comment/label operations.
#
# Returns: 0 when dispatch may proceed, 1 when a known floor or unknown REST
# observation should defer, 2 when GraphQL is unavailable after REST authorizes
# fail-open dispatch.
#######################################
is_graphql_budget_sufficient() {
	# Emergency bypass.
	if [[ "${AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER:-0}" == "1" ]]; then
		echo "${_CB_RL_LOG_PREFIX} AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1 — bypassing rate-limit check" >>"$LOGFILE"
		return 0
	fi

	local threshold="${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD:-0.05}"

	# A zero threshold disables only the GraphQL floor. The independent REST-core
	# gate still protects its hard floor and remains fail-closed on unknown quota
	# evidence; AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1 bypasses both explicitly.
	if awk -v t="$threshold" 'BEGIN { exit (t + 0 == 0) ? 0 : 1 }' 2>/dev/null; then
		_cb_rest_core_progress_allows_dispatch
		return $?
	fi

	# Query rate limit (free endpoint, short-TTL cached).
	local rate_json
	rate_json=$(_cb_rate_limit_json normal) || rate_json=""

	if [[ -z "$rate_json" ]]; then
		_cb_graphql_projection_unavailable "gh api rate_limit failed"
		return $?
	fi

	local remaining="" limit=""
	remaining=$(printf '%s' "$rate_json" | jq -r '.resources.graphql.remaining // ""') || remaining=""
	limit=$(printf '%s' "$rate_json" | jq -r '.resources.graphql.limit // ""') || limit=""

	if [[ ! "$remaining" =~ ^[0-9]+$ ]] || [[ ! "$limit" =~ ^[0-9]+$ ]]; then
		_cb_graphql_projection_unavailable "could not parse GraphQL rate-limit response (remaining='${remaining}', limit='${limit}')"
		return $?
	fi

	# Avoid division by zero.
	if [[ "$limit" -eq 0 ]]; then
		_cb_graphql_projection_unavailable "GraphQL limit is 0"
		return $?
	fi

	# Compute threshold as integer: threshold_count = ceil(threshold * limit).
	local threshold_count
	threshold_count=$(_compute_threshold_count "$threshold" "$limit") || threshold_count=0

	if [[ "$remaining" -le "$threshold_count" ]]; then
		if _cb_allow_dispatch_with_rest_fallback "$rate_json" "$remaining" "$limit" "$threshold_count" "$threshold"; then
			return 0
		fi

		# Breaker trips.
		echo "${_CB_RL_LOG_PREFIX} GraphQL budget EXHAUSTED: remaining=${remaining}/${limit} (threshold=${threshold_count}, configured=${threshold}) — deferring dispatch until next cycle" >>"$LOGFILE"

		# Record state for status reporting.
		printf '%s %s %s %s\n' "$(date +%s)" "$remaining" "$limit" "$threshold" >"$_CIRCUIT_BREAKER_STATE_FILE" 2>/dev/null || true

		# Increment stats counter.
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_dispatch_circuit_broken" 2>/dev/null || true
		fi

		return 1
	fi

	# Budget sufficient — clear state file if present (breaker recovered).
	if [[ -f "$_CIRCUIT_BREAKER_STATE_FILE" ]]; then
		echo "${_CB_RL_LOG_PREFIX} GraphQL budget recovered: remaining=${remaining}/${limit} — circuit breaker reset" >>"$LOGFILE"
		rm -f "$_CIRCUIT_BREAKER_STATE_FILE" 2>/dev/null || true
	fi

	_cb_rest_core_progress_allows_dispatch
	return $?
}

#######################################
# Compute the integer threshold count from a fractional threshold and limit.
#
# Args:
#   $1 - threshold (decimal string, e.g. "0.05", "0.1", "0.025")
#   $2 - limit (integer, e.g. 5000)
#
# Stdout: integer threshold_count
#
# Uses awk for portable floating-point arithmetic (bash has no FP support).
# Ceil semantics: 0.05 * 5000 = 250, 0.03 * 5000 = 150.
#######################################
_compute_threshold_count() {
	local threshold="$1"
	local limit="$2"

	# Validate threshold is a reasonable decimal (0-1 range).
	if ! printf '%s' "$threshold" | grep -qE '^[0-9]*\.?[0-9]+$'; then
		echo "0"
		return 0
	fi

	# awk for ceil(threshold * limit).
	local result
	result=$(awk -v t="$threshold" -v l="$limit" 'BEGIN { v = t * l; printf "%d", (v == int(v)) ? v : int(v) + 1 }' 2>/dev/null) || result=0
	[[ "$result" =~ ^[0-9]+$ ]] || result=0

	printf '%s\n' "$result"
	return 0
}

#######################################
# Print human-readable circuit breaker status.
# Used by `aidevops status` to surface breaker state.
#
# Stdout: status line (one of: "OK: ...", "TRIPPED: ...", "UNKNOWN: ...")
#######################################
_circuit_breaker_status() {
	local mode="${1:-normal}"
	# Check for emergency bypass.
	if [[ "${AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER:-0}" == "1" ]]; then
		printf 'BYPASSED: AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1\n'
		return 0
	fi

	local threshold="${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD:-0.05}"
	if awk -v t="$threshold" 'BEGIN { exit (t + 0 == 0) ? 0 : 1 }' 2>/dev/null; then
		printf 'DISABLED: threshold=0\n'
		return 0
	fi

	# Check current rate-limit state.
	local rate_json
	rate_json=$(_cb_rate_limit_json "$mode") || rate_json=""

	if [[ -z "$rate_json" ]]; then
		if [[ "$mode" == "$_CB_RL_MODE_CACHED_ONLY" ]]; then
			printf 'UNKNOWN: no cached gh api rate_limit data\n'
		else
			printf 'UNKNOWN: gh api rate_limit unavailable\n'
		fi
		return 0
	fi

	local remaining="" limit="" reset_epoch=""
	remaining=$(printf '%s' "$rate_json" | jq -r ".resources.graphql.remaining // \"${_CB_RL_UNKNOWN}\"") || remaining="$_CB_RL_UNKNOWN"
	limit=$(printf '%s' "$rate_json" | jq -r ".resources.graphql.limit // \"${_CB_RL_UNKNOWN}\"") || limit="$_CB_RL_UNKNOWN"
	reset_epoch=$(printf '%s' "$rate_json" | jq -r ".resources.graphql.reset // \"${_CB_RL_UNKNOWN}\"") || reset_epoch="$_CB_RL_UNKNOWN"

	local reset_human="$_CB_RL_UNKNOWN"
	if [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
		local now_epoch
		now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
		if [[ "$now_epoch" -gt 0 ]]; then
			local secs_until_reset=$((reset_epoch - now_epoch))
			if [[ "$secs_until_reset" -gt 0 ]]; then
				reset_human="${secs_until_reset}s until reset"
			else
				reset_human="reset imminent"
			fi
		fi
	fi

	local threshold_count="$_CB_RL_UNKNOWN"
	if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -gt 0 ]]; then
		threshold_count=$(_compute_threshold_count "$threshold" "$limit") || threshold_count="$_CB_RL_UNKNOWN"
	fi

	# Report 24h trip count if stats helper is available.
	local trip_count_24h="$_CB_RL_UNKNOWN"
	if declare -F pulse_stats_get_24h >/dev/null 2>&1; then
		trip_count_24h=$(pulse_stats_get_24h "pulse_dispatch_circuit_broken" 2>/dev/null) || trip_count_24h="$_CB_RL_UNKNOWN"
	fi

	if [[ -f "$_CIRCUIT_BREAKER_STATE_FILE" ]]; then
		printf 'TRIPPED: remaining=%s/%s (threshold=%s, trips_24h=%s, %s)\n' \
			"$remaining" "$limit" "$threshold_count" "$trip_count_24h" "$reset_human"
	else
		printf 'OK: remaining=%s/%s (threshold=%s, trips_24h=%s, %s)\n' \
			"$remaining" "$limit" "$threshold_count" "$trip_count_24h" "$reset_human"
	fi
	return 0
}

#######################################
# Check whether GitHub Actions runner queue is saturated for a repo (t3211, GH#21942).
#
# Saturation criteria (BOTH must hold):
#   - queued > AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN (default 50)
#   - queued / max(in_progress, 1) > AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN (default 10)
#
# Distinct from the GraphQL circuit breaker: GraphQL points and Actions
# runner-minutes are independent GitHub resource pools. The two breakers
# do not interact — saturation can occur even when GraphQL budget is healthy,
# and vice versa.
#
# Args: $1 = repo_slug (e.g. "owner/repo")
#
# Stdout (KEY=VALUE lines, one per line, parseable by `grep | cut`):
#   queued=N         (count of queued workflow runs)
#   in_progress=M    (count of in-progress workflow runs)
#   ratio=R          (integer queued / max(in_progress,1); use as advisory)
#   saturated=0|1    (1 iff both threshold conditions hold)
#   provider_incident=0|1 (1 iff GitHub Status reports an Actions incident)
#
# Returns:
#   0 — successful query (saturated may be 0 or 1)
#   2 — gh api error (fail-open: stdout reports saturated=0)
#
# Bypass:
#   AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION=1 — return saturated=0 unconditionally
#   QUEUED_MIN=0                              — disable check via threshold
#######################################
_check_actions_queue_saturation() {
	local repo_slug="$1"
	local queued_min="${AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN:-50}"
	local ratio_min="${AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN:-10}"

	# Validate inputs — invalid env values default to safe disabled state.
	[[ "$queued_min" =~ ^[0-9]+$ ]] || queued_min=50
	[[ "$ratio_min" =~ ^[0-9]+$ ]] || ratio_min=10

	# Empty repo_slug → cannot query → fail-open with zeros.
	if [[ -z "$repo_slug" ]]; then
		printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\nprovider_incident=0\n'
		return 0
	fi

	# Emergency bypass.
	if [[ "${AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION:-0}" == "1" ]]; then
		echo "${_CB_RL_LOG_PREFIX} AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION=1 — bypassing actions queue check for ${repo_slug}" >>"$LOGFILE"
		printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\nprovider_incident=0\n'
		return 0
	fi

	# Disabled if QUEUED_MIN is 0.
	if [[ "$queued_min" -eq 0 ]]; then
		printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\nprovider_incident=0\n'
		return 0
	fi

	# Consult the public provider status only on the stuck/queue path. The helper
	# caches responses, and an unknown/unreachable Statuspage fails open so a
	# third-party diagnostic dependency cannot stop healthy automation.
	local status_helper="${AIDEVOPS_GH_STATUS_HELPER:-${SCRIPT_DIR}/gh-status-helper.sh}"
	local status_rc=0
	if [[ "${AIDEVOPS_SKIP_GITHUB_ACTIONS_STATUS:-0}" != "1" && -x "$status_helper" ]]; then
		"$status_helper" check-actions --json >/dev/null 2>&1 || status_rc=$?
		if [[ "$status_rc" -eq 1 ]]; then
			echo "${_CB_RL_LOG_PREFIX} GitHub Status reports an active Actions incident — treating delayed queues as provider saturation" >>"$LOGFILE"
			printf 'queued=0\nin_progress=0\nratio=0\nsaturated=1\nprovider_incident=1\n'
			return 0
		fi
	fi

	# Query Actions runs for queued + in_progress states. per_page=1 is
	# enough — the .total_count field carries the population size without
	# pulling the run bodies (cheap REST call).
	local queued_json="" in_progress_json=""
	queued_json=$(gh api "repos/${repo_slug}/actions/runs?status=queued&per_page=1" 2>/dev/null) || queued_json=""
	in_progress_json=$(gh api "repos/${repo_slug}/actions/runs?status=in_progress&per_page=1" 2>/dev/null) || in_progress_json=""

	# Fail-open on any API error — instrumentation must never break the pulse.
	if [[ -z "$queued_json" || -z "$in_progress_json" ]]; then
		echo "${_CB_RL_LOG_PREFIX} WARNING: gh api repos/${repo_slug}/actions/runs failed — fail-open with saturated=0" >>"$LOGFILE"
		printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\nprovider_incident=0\n'
		return 2
	fi

	local queued="" in_progress=""
	queued=$(printf '%s' "$queued_json" | jq -r '.total_count // 0' 2>/dev/null) || queued=0
	in_progress=$(printf '%s' "$in_progress_json" | jq -r '.total_count // 0' 2>/dev/null) || in_progress=0
	[[ "$queued" =~ ^[0-9]+$ ]] || queued=0
	[[ "$in_progress" =~ ^[0-9]+$ ]] || in_progress=0

	# Compute integer ratio = queued / max(in_progress, 1). Bash 3.2 has
	# no floating-point — integer division is appropriate here because the
	# threshold is itself an integer (10 vs ratio of 36 in the canonical
	# incident; the precision floor is "ratio≥1", well below threshold).
	local denom=1
	[[ "$in_progress" -gt 0 ]] && denom="$in_progress"
	local ratio=$((queued / denom))

	# Saturation requires BOTH conditions to hold (high absolute queue AND
	# imbalanced ratio). Either alone is a false-positive — light-load
	# bursts hit absolute counts; healthy busy periods hit ratio with high
	# in_progress counts that the runner pool is already serving.
	local saturated=0
	if [[ "$queued" -gt "$queued_min" && "$ratio" -gt "$ratio_min" ]]; then
		saturated=1
		echo "${_CB_RL_LOG_PREFIX} ${repo_slug} actions queue SATURATED: queued=${queued} in_progress=${in_progress} ratio=${ratio} (thresholds queued>${queued_min} ratio>${ratio_min})" >>"$LOGFILE"
	fi

	printf 'queued=%s\nin_progress=%s\nratio=%s\nsaturated=%s\nprovider_incident=0\n' \
		"$queued" "$in_progress" "$ratio" "$saturated"
	return 0
}

#######################################
# Standalone CLI entry point.
#######################################
_main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	check)
		is_graphql_budget_sufficient
		return $?
		;;
	check-actions-queue)
		# Args: $1=repo_slug. Prints KEY=VALUE lines.
		local repo_slug="${1:-}"
		if [[ -z "$repo_slug" ]]; then
			echo "Usage: pulse-rate-limit-circuit-breaker.sh check-actions-queue <owner/repo>" >&2
			return 1
		fi
		_check_actions_queue_saturation "$repo_slug"
		return $?
		;;
	status)
		local status_mode="normal"
		if [[ "${1:-}" == "--cached" ]]; then
			status_mode="$_CB_RL_MODE_CACHED_ONLY"
		fi
		_circuit_breaker_status "$status_mode"
		return 0
		;;
	help | --help | -h)
		echo "pulse-rate-limit-circuit-breaker.sh — Pulse GraphQL breaker + REST priority budget + Actions queue saturation"
		echo ""
		echo "Usage:"
		echo "  pulse-rate-limit-circuit-breaker.sh check                          # exit 0=OK, 1=blocked, 2=GraphQL unavailable after REST allows"
		echo "  pulse-rate-limit-circuit-breaker.sh check-actions-queue OWNER/REPO # KEY=VALUE: queued/in_progress/ratio/saturated"
		echo "  pulse-rate-limit-circuit-breaker.sh status [--cached]              # human-readable status line"
		echo ""
		echo "Environment (GraphQL):"
		echo "  AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD  fraction threshold (default 0.05 = 5%)"
		echo "  AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1     emergency bypass"
		echo "  AIDEVOPS_PULSE_RATE_LIMIT_CACHE_TTL       rate_limit cache TTL seconds (default 20)"
		echo "  AIDEVOPS_PULSE_REST_CORE_RESERVE          REST soft-cap maximum (default 500; 0 disables)"
		echo "  AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR       REST emergency floor (default 100)"
		echo "  AIDEVOPS_PULSE_REST_CORE_ADAPTIVE_WINDOW_SECONDS  soft-cap decay window (default 3600)"
		echo ""
		echo "Environment (Actions queue, t3211):"
		echo "  AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN  min queued runs (default 50; 0 disables)"
		echo "  AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN   min queued/in_progress ratio (default 10)"
		echo "  AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION=1      emergency bypass"
		echo "  AIDEVOPS_SKIP_GITHUB_ACTIONS_STATUS=1         bypass public Actions incident signal"
		return 0
		;;
	*)
		echo "Unknown command: ${cmd}" >&2
		echo "Run: pulse-rate-limit-circuit-breaker.sh help" >&2
		return 1
		;;
	esac
}

# Only run _main when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_main "$@"
fi
