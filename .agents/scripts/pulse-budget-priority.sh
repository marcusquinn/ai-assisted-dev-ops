#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse stage-boundary scheduler for GraphQL and REST-core budgets (GH#22479, GH#29742).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_BUDGET_PRIORITY_LOADED:-}" ]] && return 0
_PULSE_BUDGET_PRIORITY_LOADED=1

_PULSE_BUDGET_MODE_UNKNOWN="unknown"
_PULSE_BUDGET_MODE_RESERVE="reserve"
_PULSE_BUDGET_PRIORITY_DEFERRABLE="deferrable"
_PULSE_BUDGET_PREFETCH_STAGE="preflight_prefetch_and_scope"

#######################################
# Read the GraphQL rate-limit projection through a bounded shared transport.
#######################################
_pulse_gh_rate_limit_json() {
	local rate_json=""
	local rc=0
	local secs="${AIDEVOPS_GH_READ_TIMEOUT:-15}"
	[[ "$secs" =~ ^[0-9]+$ ]] || secs=15

	if declare -F _cb_rate_limit_json >/dev/null 2>&1; then
		rate_json=$(_cb_rate_limit_json normal 2>/dev/null) || rc=$?
	elif declare -F _gh_with_timeout >/dev/null 2>&1; then
		rate_json=$(_gh_with_timeout read gh api rate_limit 2>/dev/null) || rc=$?
	elif declare -F timeout_sec >/dev/null 2>&1; then
		rate_json=$(timeout_sec "$secs" gh api rate_limit 2>/dev/null) || rc=$?
	elif command -v timeout >/dev/null 2>&1; then
		rate_json=$(timeout "$secs" gh api rate_limit 2>/dev/null) || rc=$?
	elif command -v gtimeout >/dev/null 2>&1; then
		rate_json=$(gtimeout "$secs" gh api rate_limit 2>/dev/null) || rc=$?
	else
		return 1
	fi

	[[ "$rc" -eq 0 ]] || return "$rc"
	[[ -n "$rate_json" ]] || return 1
	printf '%s\n' "$rate_json"
	return 0
}

#######################################
# Classify GraphQL headroom for optional-stage scheduling.
# Stdout: "<mode> <remaining> <limit> <threshold>".
#######################################
_pulse_graphql_budget_priority_decision() {
	local threshold="${AIDEVOPS_PULSE_OPTIONAL_BUDGET_THRESHOLD:-${AIDEVOPS_PULSE_PREFETCH_BUDGET_THRESHOLD:-1250}}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=1250
	local rate_json=""
	rate_json=$(_pulse_gh_rate_limit_json) || rate_json=""
	if [[ -z "$rate_json" ]]; then
		printf 'unknown ? ? %s\n' "$threshold"
		return 0
	fi
	local remaining
	local limit
	remaining=$(printf '%s' "$rate_json" | jq -r '.resources.graphql.remaining // ""' 2>/dev/null) || remaining=""
	limit=$(printf '%s' "$rate_json" | jq -r '.resources.graphql.limit // ""' 2>/dev/null) || limit=""
	if [[ ! "$remaining" =~ ^[0-9]+$ ]] || [[ ! "$limit" =~ ^[0-9]+$ ]]; then
		printf 'unknown ? ? %s\n' "$threshold"
		return 0
	fi
	if [[ "$remaining" -lt "$threshold" ]]; then
		printf 'reserve %s %s %s\n' "$remaining" "$limit" "$threshold"
		return 0
	fi
	printf 'normal %s %s %s\n' "$remaining" "$limit" "$threshold"
	return 0
}

#######################################
# Export the current GraphQL mode. Pass "quiet" to suppress per-stage logs.
#######################################
_pulse_set_graphql_budget_priority() {
	local log_mode="${1:-log}"
	local decision
	local budget_class
	local remaining
	local limit
	local threshold
	decision=$(_pulse_graphql_budget_priority_decision)
	read -r budget_class remaining limit threshold <<<"$decision"
	[[ -n "$budget_class" ]] || budget_class="$_PULSE_BUDGET_MODE_UNKNOWN"
	export AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS="$budget_class"
	export AIDEVOPS_PULSE_GRAPHQL_BUDGET_REMAINING="$remaining"
	export AIDEVOPS_PULSE_GRAPHQL_BUDGET_LIMIT="$limit"
	export AIDEVOPS_PULSE_GRAPHQL_BUDGET_THRESHOLD="$threshold"
	[[ "$log_mode" == "quiet" ]] && return 0
	if [[ "$budget_class" == "$_PULSE_BUDGET_MODE_RESERVE" ]]; then
		echo "[pulse-wrapper] GraphQL budget reserve mode: remaining=${remaining}/${limit} < optional_threshold=${threshold}; deferring optional stages, preserving merge/dispatch budget (GH#22479)" >>"$LOGFILE"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_graphql_budget_reserve_mode" 2>/dev/null || true
		fi
	elif [[ "$budget_class" == "$_PULSE_BUDGET_MODE_UNKNOWN" ]]; then
		echo "[pulse-wrapper] GraphQL budget priority unknown — proceeding fail-open for optional stages (GH#22479)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Read the authoritative REST-core priority mode.
# Stdout: "<mode> <remaining> <limit> <adaptive> <soft> <hard> <reset>".
#######################################
_pulse_rest_core_budget_priority_decision() {
	if ! declare -F pulse_rest_core_priority_snapshot >/dev/null 2>&1; then
		printf 'unknown ? ? ? ? ? ?\n'
		return 0
	fi
	local decision
	local gate_ttl=""
	if declare -F _cb_rest_core_gate_probe_ttl >/dev/null 2>&1; then
		gate_ttl=$(_cb_rest_core_gate_probe_ttl)
	fi
	decision=$(pulse_rest_core_priority_snapshot "$gate_ttl" 2>/dev/null) || decision=""
	[[ -n "$decision" ]] || decision="${_PULSE_BUDGET_MODE_UNKNOWN} ? ? ? ? ? ?"
	printf '%s\n' "$decision"
	return 0
}

#######################################
# Export the current REST mode. Pass "quiet" to suppress per-stage logs.
#######################################
_pulse_set_rest_core_budget_priority() {
	local log_mode="${1:-log}"
	local decision
	local budget_class
	local remaining
	local limit
	local adaptive
	local soft_cap
	local hard_floor
	local reset_epoch
	local in_flight_allowance="?"
	local progress_start_floor="?"
	decision=$(_pulse_rest_core_budget_priority_decision)
	read -r budget_class remaining limit adaptive soft_cap hard_floor reset_epoch <<<"$decision"
	[[ -n "$budget_class" ]] || budget_class="$_PULSE_BUDGET_MODE_UNKNOWN"
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS="$budget_class"
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_REMAINING="$remaining"
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_LIMIT="$limit"
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_ADAPTIVE_THRESHOLD="$adaptive"
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_SOFT_CAP="$soft_cap"
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_HARD_FLOOR="$hard_floor"
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_RESET="$reset_epoch"
	if declare -F _cb_rest_core_in_flight_allowance >/dev/null 2>&1; then
		in_flight_allowance=$(_cb_rest_core_in_flight_allowance)
	fi
	if declare -F _cb_rest_core_progress_start_floor >/dev/null 2>&1 && [[ "$hard_floor" =~ ^[0-9]+$ && "$soft_cap" =~ ^[0-9]+$ ]]; then
		progress_start_floor=$(_cb_rest_core_progress_start_floor "$hard_floor" "$soft_cap") || progress_start_floor="?"
	fi
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_IN_FLIGHT_ALLOWANCE="$in_flight_allowance"
	export AIDEVOPS_PULSE_REST_CORE_BUDGET_PROGRESS_START_FLOOR="$progress_start_floor"
	[[ "$log_mode" == "quiet" ]] && return 0
	case "$budget_class" in
	reserve | emergency)
		echo "[pulse-wrapper] REST-core budget ${budget_class} mode: remaining=${remaining}/${limit} adaptive=${adaptive} soft_cap=${soft_cap} hard_floor=${hard_floor} in_flight_allowance=${in_flight_allowance} progress_start_floor=${progress_start_floor} reset=${reset_epoch} (GH#29742)" >>"$LOGFILE"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_rest_core_budget_${budget_class}_mode" 2>/dev/null || true
		fi
		;;
	unknown)
		echo "[pulse-wrapper] REST-core budget priority unknown — conservatively deferring non-critical API stages (GH#29742)" >>"$LOGFILE"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_rest_core_budget_unknown_mode" 2>/dev/null || true
		fi
		;;
	esac
	return 0
}

#######################################
# Return the deterministic priority class for a Pulse stage.
#######################################
_pulse_stage_priority_class() {
	local stage="$1"
	case "$stage" in
	cache_prime | fix_the_fixer_detector | coderabbit_review | post_merge_scanner | pr_review_thread_response | auto_decomposer_scanner | dedup_cleanup | fast_fail_prune_expired | evaluate_routines | dependabot_alert_monitor | canonical_maintenance | dashboard_freshness_check | llm_supervisor | dirty_pr_sweep | stale_blocked_reconcile | sync_todo_refs_all_repos | build_dependency_graph_cache | refresh_blocked_status_from_graph | preflight_label_maintenance | preflight_trusted_nmr_reconcile | "$_PULSE_BUDGET_PREFETCH_STAGE")
		printf 'deferrable\n'
		;;
	approval_merge_trigger | deterministic_merge_pass | dispatch_max | preflight_early_dispatch | preflight_post_label_refill)
		printf 'progress\n'
		;;
	*)
		printf 'critical\n'
		;;
	esac
	return 0
}

#######################################
# Return 0 when GraphQL reserve mode defers this deferrable stage.
#######################################
_pulse_graphql_budget_defers_stage() {
	local stage="$1"
	local priority="$2"
	[[ "$priority" == "$_PULSE_BUDGET_PRIORITY_DEFERRABLE" ]] || return 1
	[[ "${AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS:-normal}" == "$_PULSE_BUDGET_MODE_RESERVE" ]] || return 1
	if [[ "$stage" == "$_PULSE_BUDGET_PREFETCH_STAGE" && "${AIDEVOPS_SKIP_PULSE_PREFETCH_BUDGET_GATE:-0}" == "1" ]]; then
		return 1
	fi
	return 0
}

#######################################
# Return 0 when REST-core policy defers this non-critical priority class.
#######################################
_pulse_rest_core_budget_defers_priority() {
	local priority="$1"
	[[ "$priority" != "critical" ]] || return 1

	local rest_mode="${AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS:-$_PULSE_BUDGET_MODE_UNKNOWN}"
	if declare -F _cb_rest_core_priority_decision_allows >/dev/null 2>&1; then
		local decision="${rest_mode} ${AIDEVOPS_PULSE_REST_CORE_BUDGET_REMAINING:-?} ${AIDEVOPS_PULSE_REST_CORE_BUDGET_LIMIT:-?} ${AIDEVOPS_PULSE_REST_CORE_BUDGET_ADAPTIVE_THRESHOLD:-?} ${AIDEVOPS_PULSE_REST_CORE_BUDGET_SOFT_CAP:-?} ${AIDEVOPS_PULSE_REST_CORE_BUDGET_HARD_FLOOR:-?} ${AIDEVOPS_PULSE_REST_CORE_BUDGET_RESET:-?}"
		local rest_rc=0
		_cb_rest_core_priority_decision_allows "$priority" "$decision" || rest_rc=$?
		[[ "$rest_rc" -ne 0 ]] && return 0
		return 1
	fi

	case "${rest_mode}:${priority}" in
	reserve:deferrable | emergency:deferrable | unknown:deferrable | emergency:progress | unknown:progress)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

#######################################
# Return 0 when a mapped stage should defer at its current budget class.
#######################################
_pulse_should_defer_budget_priority_stage() {
	local stage="$1"
	local priority
	priority=$(_pulse_stage_priority_class "$stage")
	[[ "$priority" != "critical" ]] || return 1

	_pulse_set_graphql_budget_priority quiet
	_pulse_set_rest_core_budget_priority quiet
	if _pulse_graphql_budget_defers_stage "$stage" "$priority"; then
		return 0
	fi

	# Unknown REST evidence intentionally keeps non-critical work fail-closed.
	# Later cycles repeat the bounded authoritative probe; elapsed time alone must
	# never turn missing quota evidence into permission to spend maintainer quota.
	if _pulse_rest_core_budget_defers_priority "$priority"; then
		return 0
	fi
	return 1
}

#######################################
# Record a stage-boundary deferral with pool-specific counters.
#######################################
_pulse_defer_budget_priority_stage() {
	local stage="$1"
	local priority
	priority=$(_pulse_stage_priority_class "$stage")
	local graphql_mode="${AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS:-$_PULSE_BUDGET_MODE_UNKNOWN}"
	local rest_mode="${AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS:-$_PULSE_BUDGET_MODE_UNKNOWN}"
	echo "[pulse-wrapper] budget-priority: deferred ${priority} stage '${stage}' (graphql=${graphql_mode}:${AIDEVOPS_PULSE_GRAPHQL_BUDGET_REMAINING:-?}/${AIDEVOPS_PULSE_GRAPHQL_BUDGET_LIMIT:-?}@${AIDEVOPS_PULSE_GRAPHQL_BUDGET_THRESHOLD:-?}, rest=${rest_mode}:${AIDEVOPS_PULSE_REST_CORE_BUDGET_REMAINING:-?}/${AIDEVOPS_PULSE_REST_CORE_BUDGET_LIMIT:-?}@${AIDEVOPS_PULSE_REST_CORE_BUDGET_ADAPTIVE_THRESHOLD:-?}, hard_floor=${AIDEVOPS_PULSE_REST_CORE_BUDGET_HARD_FLOOR:-?}, progress_start_floor=${AIDEVOPS_PULSE_REST_CORE_BUDGET_PROGRESS_START_FLOOR:-?})" >>"$LOGFILE"
	if ! declare -F pulse_stats_increment >/dev/null 2>&1; then
		return 0
	fi
	pulse_stats_increment "pulse_budget_priority_stage_deferred" 2>/dev/null || true
	pulse_stats_increment "pulse_budget_priority_stage_deferred_${stage}" 2>/dev/null || true
	if _pulse_graphql_budget_defers_stage "$stage" "$priority"; then
		pulse_stats_increment "pulse_graphql_budget_stage_deferred" 2>/dev/null || true
		pulse_stats_increment "pulse_graphql_budget_stage_deferred_${stage}" 2>/dev/null || true
	fi
	if _pulse_rest_core_budget_defers_priority "$priority"; then
		pulse_stats_increment "pulse_rest_core_budget_stage_deferred" 2>/dev/null || true
		pulse_stats_increment "pulse_rest_core_budget_stage_deferred_${stage}" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Run a stage only when its priority class is currently eligible.
#######################################
_pulse_run_budget_priority_stage() {
	local stage="$1"
	shift
	if _pulse_should_defer_budget_priority_stage "$stage"; then
		_pulse_defer_budget_priority_stage "$stage"
		return 0
	fi
	"$@"
	return $?
}

#######################################
# Run a timeout-wrapped stage only when its priority class is eligible.
#######################################
_pulse_run_budget_priority_stage_with_timeout() {
	local stage="$1"
	local timeout_seconds="$2"
	shift 2
	if _pulse_should_defer_budget_priority_stage "$stage"; then
		_pulse_defer_budget_priority_stage "$stage"
		return 0
	fi
	run_stage_with_timeout "$stage" "$timeout_seconds" "$@"
	return $?
}

# Backward-compatible names for existing optional-stage callers.
_pulse_run_optional_stage() {
	_pulse_run_budget_priority_stage "$@"
	return $?
}

_pulse_run_optional_stage_with_timeout() {
	_pulse_run_budget_priority_stage_with_timeout "$@"
	return $?
}
