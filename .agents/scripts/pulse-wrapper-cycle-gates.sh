#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Wrapper Cycle Gates -- idle/backoff, prefetch, and cycle outcome helpers
# =============================================================================
# Focused helper library for pulse-wrapper.sh. The parent wrapper keeps the
# large, identity-key-sensitive functions in place while this module holds the
# smaller cycle gate and health-counter helpers used by main cycle orchestration.
#
# Usage: source "${SCRIPT_DIR}/pulse-wrapper-cycle-gates.sh"
#
# Dependencies:
#   - pulse-wrapper-config.sh globals (LOGFILE, WRAPPER_LOGFILE, SCOPE_FILE,
#     REPOS_JSON, _PULSE_HEALTH_* counters, _file_mtime_epoch)
#   - timeout_sec (shared-constants.sh), gh, jq, tr, date, mkdir, touch, rm
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_WRAPPER_CYCLE_GATES_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_CYCLE_GATES_LOADED=1

# Resolve SCRIPT_DIR defensively for tests/direct sourcing.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_PULSE_EFFICIENCY_CYCLE_STARTED=0
_PULSE_EFFICIENCY_CYCLE_START_MS=0
_PULSE_EFFICIENCY_CYCLE_OUTCOME=idle
_PULSE_EFFICIENCY_CONTRACT_VERSION=2
_PULSE_EFFICIENCY_COVERAGE_GENERATION=2
_PULSE_LEGACY_CYCLE_OUTCOME_PENDING=0

_pulse_efficiency_record() {
	local name="$1"
	local value="${2:-1}"
	local recorded_at="${3:-}"
	if declare -F gh_record_efficiency_evidence >/dev/null 2>&1; then
		gh_record_efficiency_evidence "$name" "$value" "$recorded_at" 2>/dev/null || true
	fi
	return 0
}

_pulse_efficiency_now_seconds() {
	date +%s 2>/dev/null || printf '0\n'
	return 0
}

_pulse_efficiency_now_ms() {
	local now_seconds=""
	if declare -F _gh_now_ms >/dev/null 2>&1; then
		_gh_now_ms || return 1
		return 0
	fi
	now_seconds=$(_pulse_efficiency_now_seconds)
	[[ "$now_seconds" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$((now_seconds * 1000))"
	return 0
}

_pulse_efficiency_coverage_start_seconds() {
	local now_seconds="$1"
	local state_file="${AIDEVOPS_GH_API_EVIDENCE_COVERAGE_START_FILE:-${AIDEVOPS_STATE_DIR:-${HOME}/.aidevops/state}/github-api-efficiency-contract-v${_PULSE_EFFICIENCY_CONTRACT_VERSION}-coverage-${_PULSE_EFFICIENCY_COVERAGE_GENERATION}.started-at}"
	local state_dir="${state_file%/*}"
	local existing=""
	local temporary=""
	[[ "$state_dir" != "$state_file" ]] || state_dir="."
	if [[ -f "$state_file" && ! -L "$state_file" ]]; then
		IFS= read -r existing <"$state_file" || existing=""
		if [[ "$existing" =~ ^[0-9]+$ && "$existing" -gt 0 \
			&& "$existing" -le "$now_seconds" ]]; then
			printf '%s\n' "$existing"
			return 0
		fi
	fi
	mkdir -p "$state_dir" 2>/dev/null || {
		printf '%s\n' "$now_seconds"
		return 0
	}
	temporary=$(mktemp "${state_dir}/.github-api-efficiency-coverage.XXXXXX" 2>/dev/null) || {
		printf '%s\n' "$now_seconds"
		return 0
	}
	chmod 0600 "$temporary" 2>/dev/null || true
	if ! printf '%s\n' "$now_seconds" >"$temporary"; then
		rm -f "$temporary"
		printf '%s\n' "$now_seconds"
		return 0
	fi
	if [[ -e "$state_file" || -L "$state_file" ]]; then
		rm -f "$temporary"
	else
		mv "$temporary" "$state_file" 2>/dev/null || rm -f "$temporary"
	fi
	if [[ -f "$state_file" && ! -L "$state_file" ]]; then
		IFS= read -r existing <"$state_file" || existing=""
	fi
	if [[ "$existing" =~ ^[0-9]+$ && "$existing" -gt 0 \
		&& "$existing" -le "$now_seconds" ]]; then
		printf '%s\n' "$existing"
	else
		printf '%s\n' "$now_seconds"
	fi
	return 0
}

_pulse_efficiency_cycle_start() {
	local now_seconds=""
	local now_ms=""
	local coverage_start=""
	local group=""
	unset AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID
	now_seconds=$(_pulse_efficiency_now_seconds)
	now_ms=$(_pulse_efficiency_now_ms) || now_ms=""
	[[ "$now_seconds" =~ ^[0-9]+$ && "$now_seconds" -gt 0 ]] || return 0
	[[ "$now_ms" =~ ^[0-9]+$ ]] || now_ms=$((now_seconds * 1000))
	coverage_start=$(_pulse_efficiency_coverage_start_seconds "$now_seconds")
	[[ "$coverage_start" =~ ^[0-9]+$ ]] || coverage_start="$now_seconds"
	_PULSE_EFFICIENCY_CYCLE_STARTED=1
	_PULSE_EFFICIENCY_CYCLE_START_MS="$now_ms"
	_PULSE_EFFICIENCY_CYCLE_OUTCOME=idle
	AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID="$now_seconds"
	export AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID
	_pulse_efficiency_record contract "$_PULSE_EFFICIENCY_CONTRACT_VERSION"
	_pulse_efficiency_record coverage-start "$coverage_start"
	for group in population latency cache single_flight webhook guardrails path_budgets; do
		_pulse_efficiency_record "coverage.${group}" "$_PULSE_EFFICIENCY_CONTRACT_VERSION"
	done
	return 0
}

_pulse_efficiency_cycle_finish() {
	local outcome="${1:-${_PULSE_EFFICIENCY_CYCLE_OUTCOME:-idle}}"
	local now_seconds=""
	local now_ms=""
	local elapsed_ms=0
	if [[ "${_PULSE_EFFICIENCY_CYCLE_STARTED:-0}" != "1" ]]; then
		unset AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID
		return 0
	fi
	now_seconds=$(_pulse_efficiency_now_seconds)
	now_ms=$(_pulse_efficiency_now_ms) || now_ms=""
	[[ "$now_seconds" =~ ^[0-9]+$ && "$now_seconds" -gt 0 ]] || now_seconds=0
	if [[ "$now_ms" =~ ^[0-9]+$ && "${_PULSE_EFFICIENCY_CYCLE_START_MS:-0}" =~ ^[0-9]+$ \
		&& "$now_ms" -ge "${_PULSE_EFFICIENCY_CYCLE_START_MS:-0}" ]]; then
		elapsed_ms=$((now_ms - _PULSE_EFFICIENCY_CYCLE_START_MS))
	fi
	_pulse_efficiency_record population.pulse_cycles 1
	if [[ "$outcome" == "active" ]]; then
		_pulse_efficiency_record latency.completed_action_ms "$elapsed_ms"
	else
		_pulse_efficiency_record population.unchanged_cycles 1
	fi
	# Use the completed-cycle cutoff for both the marker value and its outer
	# record timestamp. A second rollover inside the recorder must not place the
	# marker outside the exact inclusive aggregate it bounds (GH#28493).
	[[ "$now_seconds" -gt 0 ]] && _pulse_efficiency_record coverage-end "$now_seconds" "$now_seconds"
	if declare -F gh_aggregate_calls >/dev/null 2>&1; then
		if [[ "$now_seconds" -gt 0 ]]; then
			gh_aggregate_calls "${GH_API_REPORT:-}" 86400 "$now_seconds" 2>/dev/null || true
		else
			gh_aggregate_calls 2>/dev/null || true
		fi
	fi
	if declare -F gh_trim_log >/dev/null 2>&1; then
		gh_trim_log 2>/dev/null || true
	fi
	_PULSE_EFFICIENCY_CYCLE_STARTED=0
	unset AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID
	return 0
}

_pulse_scope_repos_for_available_work_gate() {
	local _scope="${PULSE_SCOPE_REPOS:-}"
	if [[ -z "$_scope" && -f "${SCOPE_FILE:-}" ]]; then
		read -r _scope <"${SCOPE_FILE:-}" || [[ -n "$_scope" ]] || _scope=""
	fi
	if [[ -z "$_scope" && -f "${REPOS_JSON:-}" ]]; then
		_scope=$(jq -r '[.initialized_repos[]? | select(.maintenance != false and .pulse == true and (.local_only // false) == false and (.slug // "") != "") | .slug] | join(",")' "${REPOS_JSON:-}") || _scope=""
	fi
	local _slug=""
	while IFS= read -r _slug; do
		_slug="${_slug// /}"
		[[ -n "$_slug" ]] || continue
		printf '%s\n' "$_slug"
	done < <(printf '%s\n' "$_scope" | tr ',' '\n')
	return 0
}

_pulse_available_auto_dispatch_work_exists() {
	[[ "${AIDEVOPS_SKIP_PULSE_IDLE_AVAILABLE_WORK_CHECK:-0}" == "1" ]] && return 1
	local _timeout_secs="${AIDEVOPS_PULSE_IDLE_AVAILABLE_WORK_TIMEOUT:-30}"
	[[ "$_timeout_secs" =~ ^[1-9][0-9]*$ ]] || _timeout_secs=30
	if ! declare -F timeout_sec >/dev/null 2>&1; then
		printf '[pulse-wrapper] Idle available-work check has no timeout helper; proceeding without idle backoff (GH#27769)\n' \
			>>"${WRAPPER_LOGFILE:-/dev/null}"
		return 124
	fi

	local _deadline=$((SECONDS + _timeout_secs))
	local _slug="" _count="" _query_rc=0 _remaining=0
	while IFS= read -r _slug; do
		[[ -n "$_slug" ]] || continue
		_remaining=$((_deadline - SECONDS))
		if [[ "$_remaining" -lt 1 ]]; then
			printf '[pulse-wrapper] Idle available-work check timed out after %ss; proceeding without idle backoff (GH#27769)\n' \
				"$_timeout_secs" >>"${WRAPPER_LOGFILE:-/dev/null}"
			return 124
		fi
		_count=""
		_query_rc=0
		_count=$(timeout_sec "$_remaining" gh api -X GET search/issues \
			-f "q=repo:${_slug} is:issue is:open label:auto-dispatch label:status:available -label:publication:pending -label:needs-maintainer-review -label:needs-maintainer-permissions -label:infrastructure no:assignee" \
			-f per_page=1 \
			--jq '.total_count // 0' 2>/dev/null) || _query_rc=$?
		if [[ "$_query_rc" -eq 124 ]]; then
			printf '[pulse-wrapper] Idle available-work check timed out after %ss; proceeding without idle backoff (GH#27769)\n' \
				"$_timeout_secs" >>"${WRAPPER_LOGFILE:-/dev/null}"
			return 124
		fi
		[[ "$_count" =~ ^[0-9]+$ ]] || _count=0
		if [[ "$_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Idle backoff bypass: eligible auto-dispatch work is visible in ${_slug} (GH#22631)" >>"$WRAPPER_LOGFILE"
			return 0
		fi
	done < <(_pulse_scope_repos_for_available_work_gate)
	return 1
}

_pulse_check_idle_backoff_gate() {
	local _ib_helper="${SCRIPT_DIR}/pulse-idle-backoff-helper.sh"
	[[ -x "$_ib_helper" ]] || return 0
	local _ib_available_work=0
	local _ib_available_work_rc=0
	if _pulse_available_auto_dispatch_work_exists; then
		_ib_available_work=1
	else
		_ib_available_work_rc=$?
		# Unknown work state must not suppress the watchdog-protected cycle.
		[[ "$_ib_available_work_rc" -eq 124 ]] && return 0
	fi
	local _ib_ts_file="${HOME}/.aidevops/logs/pulse-wrapper-last-run.ts"
	local _ib_last=0
	if [[ -f "$_ib_ts_file" ]]; then
		read -r _ib_last <"$_ib_ts_file" || [[ -n "$_ib_last" ]] || _ib_last=0
		[[ "$_ib_last" =~ ^[0-9]+$ ]] || _ib_last=0
	fi
	# Helper convention: exit 0 = "skip this cycle", exit 1 = "proceed".
	# Mirrors should-skip semantics so the helper composes naturally with
	# `if helper should-skip; then return; fi` at the call site.
	if AIDEVOPS_PULSE_IDLE_AVAILABLE_WORK="$_ib_available_work" "$_ib_helper" should-skip "$_ib_last" >/dev/null 2>&1; then
		local _ib_state="" _ib_count="" _ib_interval=""
		_ib_state=$("$_ib_helper" state 2>/dev/null || echo '{}')
		_ib_count=$(echo "$_ib_state" | jq -r '.consecutive_idle // 0' 2>/dev/null || echo "0")
		_ib_interval=$(echo "$_ib_state" | jq -r '.current_effective_interval_s // 90' 2>/dev/null || echo "90")
		echo "[pulse-wrapper] Idle backoff: skipping cycle (consecutive_idle=${_ib_count}, effective_interval=${_ib_interval}s) (t3027)" >>"$WRAPPER_LOGFILE"
		_PULSE_HEALTH_IDLE_CYCLE_SKIPPED=$((${_PULSE_HEALTH_IDLE_CYCLE_SKIPPED:-0} + 1))
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_idle_cycle_skipped" 2>/dev/null || true
		fi
		return 1
	fi
	return 0
}

_pulse_refresh_supervisor_circuit_breaker() {
	local _cb_helper="${SCRIPT_DIR}/circuit-breaker-helper.sh"
	[[ -x "$_cb_helper" ]] || return 0
	local _cb_rc=0
	"$_cb_helper" check >/dev/null 2>>"$WRAPPER_LOGFILE" || _cb_rc=$?
	if [[ "$_cb_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] Supervisor circuit breaker check passed or auto-reset completed (GH#22631)" >>"$WRAPPER_LOGFILE"
		return 0
	fi
	echo "[pulse-wrapper] Supervisor circuit breaker remains open after check (rc=${_cb_rc}) (GH#22631)" >>"$WRAPPER_LOGFILE"
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_drain_prefetch_counters (t3027 / GH#21584)
#
# Drains the prefetch counter temp file written by pulse-prefetch.sh::
# _prefetch_batch_refresh and accumulates into the cycle-scoped
# _PULSE_HEALTH_* vars. Required because prefetch_state runs inside a
# run_stage_with_timeout subshell — direct shell-var updates are lost
# at subshell exit. Counterpart: pulse-prefetch.sh:246-264 (writer).
#
# File format (single line, 7 space-separated integers, fixed positional
# order — DO NOT change without updating the writer):
#   search_calls cache_hits tickle_fresh tickle_stale conditional_304 conditional_refreshes conditional_misses
# ---------------------------------------------------------------------------
_pulse_drain_prefetch_counters() {
	local _pf_file="${TMPDIR:-/tmp}/pulse-health-prefetch-$$.tmp"
	[[ -f "$_pf_file" ]] || return 0
	local _pf_search=0 _pf_hits=0 _pf_fresh=0 _pf_stale=0
	local _pf_cond_304=0 _pf_cond_refreshes=0 _pf_cond_misses=0
	read -r _pf_search _pf_hits _pf_fresh _pf_stale _pf_cond_304 _pf_cond_refreshes _pf_cond_misses <"$_pf_file" || true
	[[ "$_pf_search" =~ ^[0-9]+$ ]] || _pf_search=0
	[[ "$_pf_hits" =~ ^[0-9]+$ ]] || _pf_hits=0
	[[ "$_pf_fresh" =~ ^[0-9]+$ ]] || _pf_fresh=0
	[[ "$_pf_stale" =~ ^[0-9]+$ ]] || _pf_stale=0
	[[ "$_pf_cond_304" =~ ^[0-9]+$ ]] || _pf_cond_304=0
	[[ "$_pf_cond_refreshes" =~ ^[0-9]+$ ]] || _pf_cond_refreshes=0
	[[ "$_pf_cond_misses" =~ ^[0-9]+$ ]] || _pf_cond_misses=0
	# Replace rather than add: prefetch_state writes its own running totals
	# (cumulative within the call), and these vars were 0-initialised at
	# cycle start with prefetch_state as the sole writer this cycle.
	_PULSE_HEALTH_BATCH_SEARCH_CALLS="$_pf_search"
	_PULSE_HEALTH_BATCH_CACHE_HITS="$_pf_hits"
	_PULSE_HEALTH_EVENTS_TICKLE_FRESH="$_pf_fresh"
	_PULSE_HEALTH_EVENTS_TICKLE_STALE="$_pf_stale"
	_PULSE_HEALTH_CONDITIONAL_304="$_pf_cond_304"
	_PULSE_HEALTH_CONDITIONAL_REFRESHES="$_pf_cond_refreshes"
	_PULSE_HEALTH_CONDITIONAL_MISSES="$_pf_cond_misses"
	rm -f "$_pf_file" || true
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_run_fix_the_fixer_detector_if_stale (t3077)
#
# Sentinel-gated invocation of pulse-fix-the-fixer-detector.sh. The detector
# uses a haiku LLM call to classify whether each new auto-dispatch issue
# modifies the worker dispatch system itself; when YES it applies the
# `fix-the-fixer` label so headless-runtime-helper.sh can enable verbose
# lifecycle, tighten the watchdog, and write a preflight sentinel.
#
# Sentinel: ~/.aidevops/cache/pulse-fix-the-fixer-last-run (mtime).
# Default cadence: 3600s (1 hour). Override via env:
#   AIDEVOPS_PULSE_FIX_THE_FIXER_MAX_AGE  — staleness threshold in seconds
#   AIDEVOPS_SKIP_FIX_THE_FIXER_DETECTOR  — set to 1 to short-circuit
#
# Modelled on _pulse_prime_caches_if_stale (t2994) and _pulse_check_runaway_log
# (GH#21756). Fail-open everywhere — a detector failure must never break the
# pulse cycle.
# ---------------------------------------------------------------------------
_pulse_run_fix_the_fixer_detector_if_stale() {
	[[ "${AIDEVOPS_SKIP_FIX_THE_FIXER_DETECTOR:-0}" == "1" ]] && return 0

	local _ftf_helper=""
	local _ftf_sentinel=""
	local _ftf_max_age=""
	_ftf_helper="${SCRIPT_DIR}/pulse-fix-the-fixer-detector.sh"
	_ftf_sentinel="${HOME}/.aidevops/cache/pulse-fix-the-fixer-last-run"
	_ftf_max_age="${AIDEVOPS_PULSE_FIX_THE_FIXER_MAX_AGE:-3600}"
	[[ "$_ftf_max_age" =~ ^[0-9]+$ ]] || _ftf_max_age=3600

	mkdir -p "$(dirname "$_ftf_sentinel")" 2>/dev/null || return 0
	[[ ! -x "$_ftf_helper" ]] && return 0

	local _should_run=0
	if [[ ! -f "$_ftf_sentinel" ]]; then
		_should_run=1
	else
		local _now_epoch="" _stamp_epoch="" _age_s=""
		_now_epoch=$(date +%s 2>/dev/null)
		[[ "$_now_epoch" =~ ^[0-9]+$ ]] || _now_epoch=0
		_stamp_epoch=$(_file_mtime_epoch "$_ftf_sentinel")
		[[ "$_stamp_epoch" =~ ^[0-9]+$ ]] || _stamp_epoch=0
		_age_s=$((_now_epoch - _stamp_epoch))
		[[ "$_age_s" -gt "$_ftf_max_age" ]] && _should_run=1
	fi

	if [[ "$_should_run" == "1" ]]; then
		"$_ftf_helper" run 2>>"${WRAPPER_LOGFILE:-/dev/null}" || true
		# Touch sentinel regardless of outcome (fail-open).
		touch "$_ftf_sentinel" 2>/dev/null || true
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_record_cycle_outcome (t3027 / GH#21584 / GH#28361)
#
# Computes one typed terminal outcome from durable queue-changing evidence and
# stages its legacy active/idle projection. The projection is committed only
# while this cycle still owns current state. Heartbeats never participate.
#
# Active definition (any one suffices):
#   - merged ≥ 1 PR (_PULSE_HEALTH_PRS_MERGED)
#   - closed ≥ 1 conflicting PR (_PULSE_HEALTH_PRS_CLOSED_CONFLICTING)
#   - dispatched ≥ 1 new worker (cumulative registrations increased)
#
# Workers completing without new dispatches counts as IDLE — bookkeeping
# alone is not "useful work".
#
# Arguments:
#   $1 — cumulative dispatch registrations before (captured at cycle start)
# ---------------------------------------------------------------------------
_pulse_record_cycle_outcome() {
	local _dispatch_before="${1:-0}"
	[[ "$_dispatch_before" =~ ^[0-9]+$ ]] || _dispatch_before=0
	local _dispatch_after=0
	local _dispatch_delta=0
	local _merged="${_PULSE_HEALTH_PRS_MERGED:-0}"
	local _closed="${_PULSE_HEALTH_PRS_CLOSED_CONFLICTING:-0}"
	local _progress_kinds="[]"
	local _typed_outcome="idle"
	local _legacy_outcome="idle"
	[[ "$_merged" =~ ^[0-9]+$ ]] || _merged=0
	[[ "$_closed" =~ ^[0-9]+$ ]] || _closed=0
	_dispatch_after=$(_pulse_capture_dispatch_total)
	[[ "$_dispatch_after" =~ ^[0-9]+$ ]] || _dispatch_after=0
	if [[ "$_dispatch_after" -gt "$_dispatch_before" ]]; then
		_dispatch_delta=$((_dispatch_after - _dispatch_before))
	fi
	_progress_kinds=$(jq -cn \
		--argjson merged "$_merged" \
		--argjson closed "$_closed" \
		--argjson dispatched "$_dispatch_delta" '
		[
			if $merged > 0 then "pr-merged" else empty end,
			if $closed > 0 then "pr-closed-conflicting" else empty end,
			if $dispatched > 0 then "worker-dispatched" else empty end
		]') || _progress_kinds="[]"
	if [[ "$(printf '%s' "$_progress_kinds" | jq 'length' 2>/dev/null || printf '0')" -gt 0 ]]; then
		_typed_outcome="progressed"
		_legacy_outcome="active"
	elif [[ "${_PULSE_CYCLE_BLOCKER_KIND:-none}" != "none" ]]; then
		_typed_outcome="blocked"
	fi
	_PULSE_TYPED_CYCLE_OUTCOME="$_typed_outcome"
	_PULSE_EFFICIENCY_CYCLE_OUTCOME="$_legacy_outcome"
	_PULSE_LEGACY_CYCLE_OUTCOME_PENDING=1
	if declare -F _pulse_cycle_state_finalize >/dev/null 2>&1; then
		_pulse_cycle_state_finalize "$_typed_outcome" "$_progress_kinds" || true
	fi
	echo "[pulse-wrapper] Cycle outcome: typed=${_typed_outcome} legacy=${_legacy_outcome} (merged=${_merged} closed=${_closed} dispatch_registrations=${_dispatch_before}→${_dispatch_after}) (GH#28361)" >>"${LOGFILE:-/dev/null}"
	return 0
}

_pulse_commit_legacy_cycle_outcome() {
	local _ib_helper="${SCRIPT_DIR}/pulse-idle-backoff-helper.sh"
	local _legacy_outcome="${_PULSE_EFFICIENCY_CYCLE_OUTCOME:-idle}"
	[[ "${_PULSE_LEGACY_CYCLE_OUTCOME_PENDING:-0}" == "1" ]] || return 0
	_PULSE_LEGACY_CYCLE_OUTCOME_PENDING=0
	if [[ -x "$_ib_helper" ]]; then
		"$_ib_helper" record-cycle "$_legacy_outcome" >/dev/null 2>&1 || true
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_capture_dispatch_total (GH#28361)
#
# Returns the cumulative number of successful worker registrations. Unlike the
# live ledger count, this monotonic projection still detects a new dispatch
# when another worker completes during the same cycle.
# ---------------------------------------------------------------------------
_pulse_capture_dispatch_total() {
	local _ledger_file="${AIDEVOPS_DISPATCH_LEDGER_FILE:-${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-ledger.jsonl}"
	local _total=0
	if [[ -s "$_ledger_file" ]]; then
		_total=$(jq -Rsc '[split("\n")[] | fromjson? | select(.lease_phase == "prelaunch" and (.dispatched_at // "") != "")] | length' \
			"$_ledger_file" 2>/dev/null) || _total=0
	fi
	[[ "$_total" =~ ^[0-9]+$ ]] || _total=0
	printf '%s\n' "$_total"
	return 0
}
