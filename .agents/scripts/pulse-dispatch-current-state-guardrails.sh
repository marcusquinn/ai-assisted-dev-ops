#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-dispatch-current-state-guardrails.sh -- Current-state dispatch caps.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DISPATCH_CURRENT_STATE_GUARDRAILS_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CURRENT_STATE_GUARDRAILS_LOADED=1

#######################################
# Filter ordinary candidates when their repository has reached its open-PR cap.
#
# Args:
#   $1 - repository slug
#   $2 - candidate JSON array
# Stdout: filtered candidate JSON array.
#######################################
_dispatch_filter_repo_pr_backlog_candidates() {
	local repo_slug="$1"
	local candidates_json="$2"
	local pr_threshold="${PULSE_DISPATCH_GUARDRAIL_OPEN_PR_THRESHOLD:-12}"
	[[ "$pr_threshold" =~ ^[0-9]+$ ]] || pr_threshold=12
	if [[ "$pr_threshold" -eq 0 ]] || ! command -v jq >/dev/null 2>&1 || ! declare -F pulse_pr_list_get >/dev/null 2>&1; then
		printf '%s\n' "$candidates_json"
		return 0
	fi

	local pr_json="" open_prs=0 filtered_json="" candidate_count=0 filtered_count=0
	pr_json=$(pulse_pr_list_get --repo "$repo_slug" --state open --json number --limit "$pr_threshold" 2>/dev/null) || {
		printf '%s\n' "$candidates_json"
		return 0
	}
	open_prs=$(jq 'if type == "array" then length else 0 end' <<<"$pr_json" 2>/dev/null) || open_prs=0
	[[ "$open_prs" =~ ^[0-9]+$ ]] || open_prs=0
	if ((open_prs < pr_threshold)); then
		printf '%s\n' "$candidates_json"
		return 0
	fi

	filtered_json=$(jq -c '[.[] | select(
		((.labels // []) | map(.name? // .)) as $labels |
		(($labels | index("quality-debt")) != null and ($labels | index("source:review-feedback")) != null)
	)]' <<<"$candidates_json" 2>/dev/null) || filtered_json="$candidates_json"
	candidate_count=$(jq 'length' <<<"$candidates_json" 2>/dev/null) || candidate_count=0
	filtered_count=$(jq 'length' <<<"$filtered_json" 2>/dev/null) || filtered_count="$candidate_count"
	echo "[pulse-wrapper] Repository PR backlog guardrail: repo=${repo_slug} open_prs=${open_prs} threshold=${pr_threshold} ordinary_candidates_suppressed=$((candidate_count - filtered_count)) exempt_candidates=${filtered_count}" >>"$LOGFILE"
	_dispatch_stats_increment "pulse_dispatch_repo_pr_backlog_guardrail_applied"
	printf '%s\n' "$filtered_json"
	return 0
}

#######################################
# Count recent terminal worker-role signals that should shape launch capacity.
#
# Stdout: "<successes> <failures> <rate_limits> <no_dispatchable>".
#######################################
_dispatch_recent_current_state_counts() {
	local override_line="${PULSE_DISPATCH_CURRENT_STATE_COUNTS:-}"
	if [[ -n "$override_line" ]]; then
		printf '%s\n' "$override_line"
		return 0
	fi

	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local window_seconds="${PULSE_DISPATCH_CURRENT_STATE_WINDOW_SECONDS:-900}"
	[[ "$window_seconds" =~ ^[0-9]+$ ]] || window_seconds=900
	local metrics_counts=""
	metrics_counts=$(python3 - "$metrics_file" "${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" "$window_seconds" <<'PY'
import json
import sys
import time
from collections import deque

metrics_path, log_path, window = sys.argv[1], sys.argv[2], int(sys.argv[3])
since = time.time() - window
successes = failures = rate_limits = 0
try:
    with open(metrics_path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in deque(handle, 2000):
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            ts = float(item.get("ts") or 0)
            if ts < since:
                continue
            if str(item.get("role") or "") != "worker":
                continue
            result = str(item.get("result") or "")
            failure_reason = str(item.get("failure_reason") or "")
            provider_error_type = str(item.get("provider_error_type") or "")
            provider_status = str(item.get("provider_status") or "")
            exit_code = item.get("exit_code")
            if result.endswith("_continue") or result == "brief_recovery":
                continue
            if result == "success" and exit_code == 0:
                successes += 1
            elif result not in {"worker_noop", "no_work", "noop"}:
                failures += 1
            if result in {"rate_limit", "rate_limit_fast"} or "rate_limit" in failure_reason or provider_error_type == "rate_limit" or provider_status == "429":
                rate_limits += 1
except (OSError, ValueError):
    pass

no_dispatchable = 0
try:
    with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
        lines = deque(handle, 2000)
    for raw in lines:
        line = raw.lower()
        if "no ranked candidates" in line or "no eligible candidates" in line or "no dispatchable" in line:
            no_dispatchable += 1
except OSError:
    pass

print(f"{successes} {failures} {rate_limits} {no_dispatchable}")
PY
	) || metrics_counts="0 0 0 0"
	local successes="" failures="" rate_limits="" no_dispatchable=""
	read -r successes failures rate_limits no_dispatchable <<<"$metrics_counts"
	printf '%s %s %s %s\n' "$successes" "$failures" "$rate_limits" "$no_dispatchable"
	return 0
}

#######################################
# Apply current-state guardrails to available worker slots.
#
# Args:
#   $1 - max workers
#   $2 - active workers
#   $3 - available slots
#   $4 - minimum worker floor active (1=yes, optional)
# Stdout: "<max_workers> <active_workers> <available_slots>" after capping.
#######################################
_dispatch_apply_current_state_guardrails() {
	local max_workers="$1"
	local active_workers="$2"
	local available_slots="$3"
	local min_worker_floor_active="${4:-0}"
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$available_slots" =~ ^-?[0-9]+$ ]] || available_slots=0
	[[ "$min_worker_floor_active" =~ ^[0-9]+$ ]] || min_worker_floor_active=0

	if [[ "${AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS:-0}" == "1" || "$available_slots" -le 0 ]]; then
		_dispatch_stats_gauge "pulse_dispatch_guardrail_available_slots" "$available_slots"
		printf '%s %s %s\n' "$max_workers" "$active_workers" "$available_slots"
		return 0
	fi

	local counts_line="" successes="" failures="" rate_limits="" no_dispatchable=""
	counts_line=$(_dispatch_recent_current_state_counts) || counts_line="0 0 0 0"
	read -r successes failures rate_limits no_dispatchable <<<"$counts_line"
	[[ "$successes" =~ ^[0-9]+$ ]] || successes=0
	[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
	[[ "$rate_limits" =~ ^[0-9]+$ ]] || rate_limits=0
	[[ "$no_dispatchable" =~ ^[0-9]+$ ]] || no_dispatchable=0
	_dispatch_stats_gauge "pulse_dispatch_guardrail_successes" "$successes"
	_dispatch_stats_gauge "pulse_dispatch_guardrail_failures" "$failures"
	_dispatch_stats_gauge "pulse_dispatch_guardrail_worker_terminal_failures" "$failures"
	_dispatch_stats_gauge "pulse_dispatch_guardrail_rate_limits" "$rate_limits"
	_dispatch_stats_gauge "pulse_dispatch_guardrail_no_dispatchable" "$no_dispatchable"

	local rl_threshold="${PULSE_DISPATCH_GUARDRAIL_RATE_LIMIT_THRESHOLD:-4}"
	local failure_threshold="${PULSE_DISPATCH_GUARDRAIL_FAILURE_THRESHOLD:-6}"
	local empty_threshold="${PULSE_DISPATCH_GUARDRAIL_NO_DISPATCHABLE_THRESHOLD:-2}"
	[[ "$rl_threshold" =~ ^[0-9]+$ ]] || rl_threshold=4
	[[ "$failure_threshold" =~ ^[0-9]+$ ]] || failure_threshold=6
	[[ "$empty_threshold" =~ ^[0-9]+$ ]] || empty_threshold=2

	local capped_slots="$available_slots" reason=""
	if ((empty_threshold > 0 && no_dispatchable >= empty_threshold && successes == 0 && min_worker_floor_active > 0)); then
		# Stale empty-candidate evidence must not self-lock the configured worker
		# floor. The candidate loop still re-checks eligibility and stops on a true
		# empty queue, but floor repair needs enough slots to test currently
		# dispatchable work instead of a single stale probe.
		reason="no_dispatchable_floor_bypass"
		_dispatch_stats_increment "pulse_dispatch_current_state_guardrail_floor_bypass"
	elif ((empty_threshold > 0 && no_dispatchable >= empty_threshold && successes == 0)); then
		# Keep one probe slot alive. Otherwise stale "no dispatchable" evidence can
		# self-lock the refill loop just as new review/conflict work becomes eligible.
		capped_slots=1
		reason="no_dispatchable_evidence"
	elif ((rl_threshold > 0 && rate_limits >= rl_threshold && successes == 0)); then
		capped_slots=0
		reason="provider_rate_limit_pressure"
	elif ((rl_threshold > 0 && rate_limits >= rl_threshold && capped_slots > 1)); then
		capped_slots=1
		reason="provider_rate_limit_pressure"
	elif ((failure_threshold > 0 && failures >= failure_threshold && successes == 0)); then
		capped_slots=0
		reason="repeated_failure_pressure"
	elif ((failure_threshold > 0 && failures >= failure_threshold && capped_slots > 1)); then
		capped_slots=1
		reason="repeated_failure_pressure"
	fi

	if ((capped_slots < available_slots)); then
		max_workers=$((active_workers + capped_slots))
		echo "[pulse-wrapper] Dispatch current-state guardrail: reason=${reason} capacity_unit=simultaneous_workers capped_available=${capped_slots}/${available_slots} worker_terminal_successes=${successes} worker_terminal_failures=${failures} worker_rate_limits=${rate_limits} failure_observation_window_seconds=${PULSE_DISPATCH_CURRENT_STATE_WINDOW_SECONDS:-900} task_duration_limit=none no_dispatchable=${no_dispatchable} min_worker_floor_active=${min_worker_floor_active}" >>"$LOGFILE"
		_dispatch_stats_increment "pulse_dispatch_current_state_guardrail_applied"
		_dispatch_stats_increment_candidate_failed "$reason"
	elif [[ "$reason" == "no_dispatchable_floor_bypass" ]]; then
		echo "[pulse-wrapper] Dispatch current-state guardrail: reason=${reason} capacity_unit=simultaneous_workers preserved_available=${available_slots} worker_terminal_successes=${successes} worker_terminal_failures=${failures} worker_rate_limits=${rate_limits} failure_observation_window_seconds=${PULSE_DISPATCH_CURRENT_STATE_WINDOW_SECONDS:-900} task_duration_limit=none no_dispatchable=${no_dispatchable} min_worker_floor_active=${min_worker_floor_active}" >>"$LOGFILE"
	fi
	_dispatch_stats_gauge "pulse_dispatch_guardrail_available_slots" "$capped_slots"

	printf '%s %s %s\n' "$max_workers" "$active_workers" "$capped_slots"
	return 0
}
