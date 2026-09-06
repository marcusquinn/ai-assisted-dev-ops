#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="${TMP_DIR}/home"
export PULSE_JITTER_MAX=0
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export WRAPPER_LOGFILE="$LOGFILE"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache" "${HOME}/.aidevops/.agent-workspace/supervisor"

gh() {
	local command_name="${1:-}"
	local first_arg="${2:-}"
	local second_arg="${3:-}"
	if [[ "$command_name" == "api" && "$first_arg" == "-i" && "$second_arg" == "user" ]]; then
		if [[ "${GH_REST_CORE_UNKNOWN:-0}" == "1" ]]; then
			printf '{}\n'
			return 0
		fi
		printf 'HTTP/2 200\nx-ratelimit-resource: core\nx-ratelimit-remaining: %s\nx-ratelimit-limit: 5000\nx-ratelimit-reset: %s\n\n{}\n' \
			"${GH_REST_CORE_REMAINING:-5000}" "${GH_REST_CORE_RESET:-$(($(date +%s) + 3600))}"
		return 0
	fi
	if [[ "$command_name" == "api" && "$first_arg" == "user" ]]; then
		printf '{"login":"test-user"}\n'
		return 0
	fi
	if [[ "$command_name" == "api" && "$first_arg" == "rate_limit" ]]; then
		printf '{"resources":{"graphql":{"remaining":%s,"limit":5000}}}\n' "${GH_GRAPHQL_REMAINING:-5000}"
		return 0
	fi
	printf '[]\n'
	return 0
}
export -f gh

# shellcheck source=/dev/null
source "${TEST_SCRIPT_DIR}/../pulse-wrapper.sh" >/dev/null 2>&1

pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"${TMP_DIR}/counters.log"
	return 0
}

_cb_rate_limit_json() {
	local mode="${1:-normal}"
	[[ -n "$mode" ]] || mode="normal"
	printf '{"resources":{"graphql":{"remaining":%s,"limit":5000}}}\n' "${GH_GRAPHQL_REMAINING:-5000}"
	return 0
}

export AIDEVOPS_PULSE_OPTIONAL_BUDGET_THRESHOLD=1250
export AIDEVOPS_PULSE_REST_CORE_RESERVE=500
export AIDEVOPS_PULSE_REST_CORE_HARD_FLOOR=100
export AIDEVOPS_PULSE_REST_CORE_IN_FLIGHT_ALLOWANCE=250
export AIDEVOPS_PULSE_REST_CORE_ADAPTIVE_WINDOW_SECONDS=3600
export AIDEVOPS_PULSE_REST_CORE_GATE_PROBE_TTL=2
export GH_GRAPHQL_REMAINING=100
export GH_REST_CORE_REMAINING=5000
export GH_REST_CORE_RESET="$(($(date +%s) + 3600))"
_pulse_set_graphql_budget_priority
_pulse_set_rest_core_budget_priority
[[ "${AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS}" == "reserve" ]]
[[ "${AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS}" == "normal" ]]
_pulse_should_defer_budget_priority_stage "dashboard_freshness_check"
_pulse_should_defer_budget_priority_stage "evaluate_routines"
_pulse_should_defer_budget_priority_stage "pr_review_thread_response"
export AIDEVOPS_SKIP_PULSE_PREFETCH_BUDGET_GATE=1
if _pulse_should_defer_budget_priority_stage "preflight_prefetch_and_scope"; then
	printf 'FAIL: GraphQL prefetch bypass did not preserve healthy-REST prefetch\n' >&2
	exit 1
fi
unset AIDEVOPS_SKIP_PULSE_PREFETCH_BUDGET_GATE
if _pulse_should_defer_budget_priority_stage "deterministic_merge_pass"; then
	printf 'FAIL: merge-critical stage was deferred\n' >&2
	exit 1
fi
if _pulse_should_defer_budget_priority_stage "dispatch_max"; then
	printf 'FAIL: dispatch-critical stage was deferred\n' >&2
	exit 1
fi

_pulse_defer_budget_priority_stage "dashboard_freshness_check"
grep -q 'pulse_graphql_budget_reserve_mode' "${TMP_DIR}/counters.log"
grep -q 'pulse_graphql_budget_stage_deferred_dashboard_freshness_check' "${TMP_DIR}/counters.log"
grep -q 'budget-priority: deferred deferrable stage' "$LOGFILE"

export GH_GRAPHQL_REMAINING=3000
_pulse_set_graphql_budget_priority
[[ "${AIDEVOPS_PULSE_GRAPHQL_BUDGET_CLASS}" == "normal" ]]
if _pulse_should_defer_budget_priority_stage "dashboard_freshness_check"; then
	printf 'FAIL: optional stage deferred with healthy budget\n' >&2
	exit 1
fi

[[ "$(_pulse_stage_priority_class "dashboard_freshness_check")" == "deferrable" ]]
[[ "$(_pulse_stage_priority_class "preflight_prefetch_and_scope")" == "deferrable" ]]
[[ "$(_pulse_stage_priority_class "preflight_label_maintenance")" == "deferrable" ]]
[[ "$(_pulse_stage_priority_class "preflight_trusted_nmr_reconcile")" == "deferrable" ]]
[[ "$(_pulse_stage_priority_class "stale_blocked_reconcile")" == "deferrable" ]]
[[ "$(_pulse_stage_priority_class "sync_todo_refs_all_repos")" == "deferrable" ]]
[[ "$(_pulse_stage_priority_class "build_dependency_graph_cache")" == "deferrable" ]]
[[ "$(_pulse_stage_priority_class "refresh_blocked_status_from_graph")" == "deferrable" ]]
[[ "$(_pulse_stage_priority_class "approval_merge_trigger")" == "progress" ]]
[[ "$(_pulse_stage_priority_class "deterministic_merge_pass")" == "progress" ]]
[[ "$(_pulse_stage_priority_class "preflight_early_dispatch")" == "progress" ]]
[[ "$(_pulse_stage_priority_class "preflight_post_label_refill")" == "progress" ]]
[[ "$(_pulse_stage_priority_class "reap_orphan_workers")" == "critical" ]]

export GH_REST_CORE_REMAINING=400
rm -f "${HOME}/.aidevops/cache/pulse-rest-core.json"
_pulse_set_rest_core_budget_priority
[[ "${AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS}" == "reserve" ]]
_pulse_should_defer_budget_priority_stage "dashboard_freshness_check"
_pulse_should_defer_budget_priority_stage "preflight_label_maintenance"
_pulse_should_defer_budget_priority_stage "build_dependency_graph_cache"
_pulse_should_defer_budget_priority_stage "stale_blocked_reconcile"
export AIDEVOPS_SKIP_PULSE_PREFETCH_BUDGET_GATE=1
_pulse_should_defer_budget_priority_stage "preflight_prefetch_and_scope"
unset AIDEVOPS_SKIP_PULSE_PREFETCH_BUDGET_GATE
if _pulse_should_defer_budget_priority_stage "deterministic_merge_pass"; then
	printf 'FAIL: progress stage deferred above REST launch floor\n' >&2
	exit 1
fi
if _pulse_should_defer_budget_priority_stage "approval_merge_trigger"; then
	printf 'FAIL: approval-trigger merge deferred above REST launch floor\n' >&2
	exit 1
fi
if _pulse_should_defer_budget_priority_stage "reap_orphan_workers"; then
	printf 'FAIL: critical stage deferred in REST reserve mode\n' >&2
	exit 1
fi
grep -q '_pulse_run_budget_priority_stage "stale_blocked_reconcile" _pulse_reconcile_stale_blocked_if_due' "${TEST_SCRIPT_DIR}/../pulse-wrapper.sh"
grep -q '_pulse_run_budget_priority_stage "approval_merge_trigger" _drain_merge_trigger_file_if_present' "${TEST_SCRIPT_DIR}/../pulse-wrapper.sh"
_pulse_defer_budget_priority_stage "dashboard_freshness_check"
grep -q 'pulse_rest_core_budget_reserve_mode' "${TMP_DIR}/counters.log"
grep -q 'pulse_rest_core_budget_stage_deferred_dashboard_freshness_check' "${TMP_DIR}/counters.log"

export GH_REST_CORE_RESET="$(($(date +%s) + 60))"
export GH_REST_CORE_REMAINING=350
rm -f "${HOME}/.aidevops/cache/pulse-rest-core.json"
_pulse_set_rest_core_budget_priority
[[ "${AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS}" == "normal" ]]
if ! _pulse_should_defer_budget_priority_stage "deterministic_merge_pass"; then
	printf 'FAIL: progress stage was admitted at REST launch floor\n' >&2
	exit 1
fi
_pulse_defer_budget_priority_stage "deterministic_merge_pass"
grep -q 'progress_start_floor=350' "$LOGFILE"
if _pulse_should_defer_budget_priority_stage "reap_orphan_workers"; then
	printf 'FAIL: critical stage deferred at REST launch floor\n' >&2
	exit 1
fi

export GH_REST_CORE_REMAINING=351
rm -f "${HOME}/.aidevops/cache/pulse-rest-core.json"
if _pulse_should_defer_budget_priority_stage "deterministic_merge_pass"; then
	printf 'FAIL: progress stage deferred above REST launch floor\n' >&2
	exit 1
fi
export GH_REST_CORE_RESET="$(($(date +%s) + 3600))"

export GH_REST_CORE_REMAINING=100
rm -f "${HOME}/.aidevops/cache/pulse-rest-core.json"
_pulse_set_rest_core_budget_priority
_pulse_cycle_state_set_blocker none
_pulse_run_budget_priority_stage dashboard_freshness_check false
[[ "$_PULSE_CYCLE_BLOCKER_KIND" == "none" ]]
_pulse_run_budget_priority_stage dispatch_max false
[[ "$_PULSE_BUDGET_STAGE_DEFERRED" == "1" ]]
[[ "$_PULSE_CYCLE_BLOCKER_KIND" == "rest-core-quota" ]]
quota_fingerprint="$_PULSE_CYCLE_BLOCKER_FINGERPRINT"
_pulse_cycle_state_set_blocker none
_pulse_run_budget_priority_stage deterministic_merge_pass false
[[ "$_PULSE_CYCLE_BLOCKER_FINGERPRINT" == "$quota_fingerprint" ]]
[[ "${AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS}" == "emergency" ]]
_pulse_should_defer_budget_priority_stage "deterministic_merge_pass"
_pulse_should_defer_budget_priority_stage "approval_merge_trigger"
_pulse_should_defer_budget_priority_stage "dashboard_freshness_check"
if _pulse_should_defer_budget_priority_stage "reap_orphan_workers"; then
	printf 'FAIL: critical stage deferred at REST hard floor\n' >&2
	exit 1
fi

export GH_REST_CORE_UNKNOWN=1
rm -f "${HOME}/.aidevops/cache/pulse-rest-core.json"
_pulse_set_rest_core_budget_priority
[[ "${AIDEVOPS_PULSE_REST_CORE_BUDGET_CLASS}" == "unknown" ]]
_pulse_should_defer_budget_priority_stage "deterministic_merge_pass"
_pulse_should_defer_budget_priority_stage "dashboard_freshness_check"
if _pulse_should_defer_budget_priority_stage "reap_orphan_workers"; then
	printf 'FAIL: critical stage deferred with unknown REST evidence\n' >&2
	exit 1
fi

unset GH_REST_CORE_UNKNOWN
export GH_REST_CORE_REMAINING=5000
rm -f "${HOME}/.aidevops/cache/pulse-rest-core.json"
_pulse_cycle_state_set_blocker none
_pulse_run_budget_priority_stage dispatch_max true
[[ "$_PULSE_BUDGET_STAGE_DEFERRED" == "0" ]]
[[ "$_PULSE_CYCLE_BLOCKER_KIND" == "none" ]]

unset -f _cb_rate_limit_json
TIMEOUT_CALL_LOG="${TMP_DIR}/timeout-calls.log"
_gh_with_timeout() {
	local op_class="$1"
	shift
	printf '_gh_with_timeout %s %s\n' "$op_class" "$*" >>"$TIMEOUT_CALL_LOG"
	if [[ "$op_class" == "read" && "$*" == "gh api rate_limit" ]]; then
		printf '{"resources":{"graphql":{"remaining":4000,"limit":5000}}}\n'
		return 0
	fi
	return 1
}
decision="$(_pulse_graphql_budget_priority_decision)"
if [[ "$decision" != "normal 4000 5000 1250" ]]; then
	printf 'FAIL: fallback budget decision did not use bounded gh read: %s\n' "$decision" >&2
	exit 1
fi
if ! grep -q '_gh_with_timeout read gh api rate_limit' "$TIMEOUT_CALL_LOG"; then
	printf 'FAIL: pulse-wrapper fallback did not call _gh_with_timeout read gh api rate_limit\n' >&2
	exit 1
fi

printf 'PASS pulse-graphql-budget-priority\n'
