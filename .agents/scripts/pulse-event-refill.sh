#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-event-refill.sh — Coalesced worker-exit signals and lock-safe Pulse refill.

if [[ -n "${_PULSE_EVENT_REFILL_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_PULSE_EVENT_REFILL_LOADED=1

_pulse_event_refill_source_dir="${BASH_SOURCE[0]%/*}"
_PULSE_EVENT_REFILL_SCRIPT_DIR=$(cd "$_pulse_event_refill_source_dir" 2>/dev/null && pwd) || _PULSE_EVENT_REFILL_SCRIPT_DIR="$_pulse_event_refill_source_dir"
unset _pulse_event_refill_source_dir

pulse_event_refill_is_enabled() {
	local enabled_value="${AIDEVOPS_PULSE_EVENT_REFILL_ENABLED:-1}"
	case "$enabled_value" in
	1 | true | TRUE | yes | YES | on | ON) return 0 ;;
	esac
	return 1
}

pulse_event_refill_log() {
	local message="$1"
	local logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	local timestamp=""
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	mkdir -p "${logfile%/*}" 2>/dev/null || true
	printf '[%s] [pulse-event-refill] %s\n' "$timestamp" "$message" >>"$logfile" 2>/dev/null || true
	return 0
}

pulse_event_refill_counter() {
	local counter_name="$1"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "$counter_name" 2>/dev/null || true
	fi
	return 0
}

pulse_event_refill_write_trigger() {
	local issue_number="$1"
	local worker_pid="$2"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${AIDEVOPS_PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}}"
	local trigger_dir="${trigger_file%/*}"
	local temporary_file=""
	local timestamp=""

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	mkdir -p "$trigger_dir" 2>/dev/null || return 1
	temporary_file="${trigger_file}.tmp.$$.${RANDOM:-0}"
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	if ! printf 'issue=%s worker_pid=%s ts=%s\n' "$issue_number" "$worker_pid" "$timestamp" >"$temporary_file"; then
		rm -f "$temporary_file" 2>/dev/null || true
		return 1
	fi
	if ! mv -f "$temporary_file" "$trigger_file" 2>/dev/null; then
		rm -f "$temporary_file" 2>/dev/null || true
		return 1
	fi
	pulse_event_refill_log "action=trigger_recorded issue=${issue_number} worker_pid=${worker_pid}"
	return 0
}

_pulse_event_refill_acquire_wake_lock() {
	local wake_lock="$1"
	local self_pid="${BASHPID:-$$}"
	local owner_token="${self_pid}:${RANDOM}"
	local recorded_owner=""
	local owner_pid=""
	local grace_attempt=0

	[[ "$wake_lock" == *.wake.lock ]] || return 1
	if ! mkdir "$wake_lock" 2>/dev/null; then
		while ((grace_attempt < 5)); do
			if [[ -f "${wake_lock}/pid" ]]; then
				read -r recorded_owner <"${wake_lock}/pid" 2>/dev/null || recorded_owner=""
			fi
			[[ -n "$recorded_owner" ]] && break
			sleep 0.1 2>/dev/null || sleep 1
			grace_attempt=$((grace_attempt + 1))
		done
		owner_pid="${recorded_owner%%:*}"
		if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
			return 1
		fi
		rm -rf "$wake_lock" 2>/dev/null || true
		mkdir "$wake_lock" 2>/dev/null || return 1
	fi
	printf '%s\n' "$owner_token" >"${wake_lock}/pid" 2>/dev/null || {
		rm -rf "$wake_lock" 2>/dev/null || true
		return 1
	}
	read -r recorded_owner <"${wake_lock}/pid" 2>/dev/null || recorded_owner=""
	[[ "$recorded_owner" == "$owner_token" ]] || return 1
	_PULSE_EVENT_REFILL_WAKE_OWNER_TOKEN="$owner_token"
	return 0
}

_pulse_event_refill_release_wake_lock() {
	local wake_lock="$1"
	local recorded_owner=""
	local owner_token="${_PULSE_EVENT_REFILL_WAKE_OWNER_TOKEN:-}"
	[[ "$wake_lock" == *.wake.lock ]] || return 1
	if [[ -f "${wake_lock}/pid" ]]; then
		read -r recorded_owner <"${wake_lock}/pid" 2>/dev/null || recorded_owner=""
	fi
	if [[ -n "$owner_token" && "$recorded_owner" == "$owner_token" ]]; then
		rm -rf "$wake_lock" 2>/dev/null || true
	fi
	_PULSE_EVENT_REFILL_WAKE_OWNER_TOKEN=""
	return 0
}

_pulse_event_refill_wrapper_supports_mode() {
	local wrapper="$1"
	[[ -r "$wrapper" ]] || return 1
	grep -q -- '--refill-only' "$wrapper" 2>/dev/null
	return $?
}

pulse_event_refill_signal() {
	local issue_number="$1"
	local worker_pid="$2"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${AIDEVOPS_PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}}"
	local wake_lock="${trigger_file}.wake.lock"
	local wrapper="${PULSE_EVENT_REFILL_WRAPPER:-${AIDEVOPS_PULSE_EVENT_REFILL_WRAPPER:-${_PULSE_EVENT_REFILL_SCRIPT_DIR}/pulse-wrapper.sh}}"
	local wake_pass=0
	local max_wake_passes="${PULSE_EVENT_REFILL_WAKE_PASSES:-2}"

	if ! pulse_event_refill_write_trigger "$issue_number" "$worker_pid"; then
		pulse_event_refill_log "action=trigger_failed issue=${issue_number} worker_pid=${worker_pid}"
		return 0
	fi
	if ! pulse_event_refill_is_enabled; then
		pulse_event_refill_log "action=disabled trigger=retained issue=${issue_number}"
		return 0
	fi
	if ! _pulse_event_refill_wrapper_supports_mode "$wrapper"; then
		pulse_event_refill_log "action=wrapper_unsupported trigger=retained wrapper=${wrapper}"
		return 0
	fi
	if ! _pulse_event_refill_acquire_wake_lock "$wake_lock"; then
		pulse_event_refill_log "action=wake_coalesced issue=${issue_number} worker_pid=${worker_pid}"
		return 0
	fi
	[[ "$max_wake_passes" =~ ^[0-9]+$ ]] || max_wake_passes=2
	((max_wake_passes > 0)) || max_wake_passes=1
	while [[ -f "$trigger_file" && "$wake_pass" -lt "$max_wake_passes" ]]; do
		wake_pass=$((wake_pass + 1))
		pulse_event_refill_log "action=wake_started issue=${issue_number} worker_pid=${worker_pid} pass=${wake_pass}"
		AIDEVOPS_PULSE_EVENT_REFILL_ENABLED=1 \
			PULSE_EVENT_REFILL_TRIGGER_FILE="$trigger_file" \
			PULSE_EVENT_REFILL_WRAPPER="$wrapper" \
			bash "$wrapper" --refill-only --refill-source=worker-exit || true
		if [[ -f "$trigger_file" && "$wake_pass" -lt "$max_wake_passes" ]]; then
			sleep 1
		fi
	done
	_pulse_event_refill_release_wake_lock "$wake_lock"
	return 0
}

_pulse_setup_refill_only_mode() {
	local refill_argument=""
	local refill_source="${PULSE_REFILL_SOURCE:-event}"
	for refill_argument in "$@"; do
		case "$refill_argument" in
		--refill-only) export PULSE_REFILL_ONLY=1 ;;
		--refill-source=*) refill_source="${refill_argument#*=}" ;;
		esac
	done
	case "$refill_source" in
	*[!A-Za-z0-9:_-]*) refill_source="unknown" ;;
	esac
	export PULSE_REFILL_SOURCE="$refill_source"
	return 0
}

_pulse_event_refill_cleanup() {
	if declare -F release_instance_lock >/dev/null 2>&1; then
		release_instance_lock || true
	fi
	if declare -F aidevops_runtime_bundle_lease_release >/dev/null 2>&1; then
		aidevops_runtime_bundle_lease_release || true
	fi
	return 0
}

_pulse_event_refill_wait_for_instance_lock() {
	local wait_seconds="${PULSE_EVENT_REFILL_WAIT_SECONDS:-20}"
	local poll_seconds="${PULSE_EVENT_REFILL_POLL_SECONDS:-1}"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	local started_epoch=""
	local now_epoch=""

	[[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds=20
	[[ "$poll_seconds" =~ ^[0-9]+$ ]] || poll_seconds=1
	((poll_seconds > 0)) || poll_seconds=1
	started_epoch=$(date +%s)
	while [[ -f "$trigger_file" ]]; do
		if acquire_instance_lock; then
			return 0
		fi
		now_epoch=$(date +%s)
		if ((now_epoch - started_epoch >= wait_seconds)); then
			return 1
		fi
		sleep "$poll_seconds"
	done
	return 1
}

pulse_event_refill_recover_processing() {
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	local processing_file=""
	for processing_file in "${trigger_file}.processing."*; do
		[[ -f "$processing_file" ]] || continue
		if [[ -f "$trigger_file" ]]; then
			rm -f "$processing_file" 2>/dev/null || true
		else
			mv -f "$processing_file" "$trigger_file" 2>/dev/null || true
		fi
	done
	return 0
}

pulse_event_refill_github_available() {
	command -v gh >/dev/null 2>&1 || return 1
	gh api user --jq '.login' >/dev/null 2>&1
	return $?
}

_pulse_event_refill_dispatch_gate() {
	if [[ -f "${STOP_FLAG:-${HOME}/.aidevops/logs/pulse-session.stop}" ]]; then
		pulse_event_refill_log "action=blocked reason=stop_flag trigger=retained"
		pulse_event_refill_counter "pulse_event_refill_blocked_stop"
		return 1
	fi
	if ! pulse_event_refill_github_available; then
		pulse_event_refill_log "action=blocked reason=github_unavailable trigger=retained"
		pulse_event_refill_counter "pulse_event_refill_blocked_github"
		return 1
	fi
	if declare -F is_graphql_budget_sufficient >/dev/null 2>&1; then
		local graphql_budget_rc=0
		is_graphql_budget_sufficient || graphql_budget_rc=$?
		if [[ "$graphql_budget_rc" -eq 1 ]]; then
			pulse_event_refill_log "action=blocked reason=graphql_circuit trigger=retained"
			pulse_event_refill_counter "pulse_event_refill_blocked_graphql"
			return 1
		fi
	fi
	if declare -F is_no_work_rate_acceptable >/dev/null 2>&1; then
		local no_work_rc=0
		is_no_work_rate_acceptable || no_work_rc=$?
		if [[ "$no_work_rc" -eq 1 ]]; then
			pulse_event_refill_log "action=blocked reason=no_work_circuit trigger=retained"
			pulse_event_refill_counter "pulse_event_refill_blocked_no_work"
			return 1
		fi
	fi
	local runner_health_helper="${SCRIPT_DIR:-${_PULSE_EVENT_REFILL_SCRIPT_DIR}}/pulse-runner-health-helper.sh"
	if [[ -x "$runner_health_helper" ]] && "$runner_health_helper" is-paused >/dev/null 2>&1; then
		pulse_event_refill_log "action=blocked reason=runner_health trigger=retained"
		pulse_event_refill_counter "pulse_event_refill_blocked_runner_health"
		return 1
	fi
	return 0
}

_pulse_event_refill_restore_processing() {
	local processing_file="$1"
	local trigger_file="$2"
	if [[ -f "$trigger_file" ]]; then
		rm -f "$processing_file" 2>/dev/null || true
	else
		mv -f "$processing_file" "$trigger_file" 2>/dev/null || true
	fi
	return 0
}

pulse_event_refill_drain() {
	local source_name="${1:-cycle}"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	local processing_file=""
	local pass=0
	local max_passes="${PULSE_EVENT_REFILL_MAX_PASSES:-2}"
	case "$source_name" in
	*[!A-Za-z0-9:_-]*) source_name="unknown" ;;
	esac
	if ! pulse_event_refill_is_enabled; then
		[[ -f "$trigger_file" ]] && pulse_event_refill_log "action=disabled trigger=retained source=${source_name}"
		return 0
	fi
	[[ "$max_passes" =~ ^[0-9]+$ ]] || max_passes=2
	((max_passes > 0)) || max_passes=1
	pulse_event_refill_recover_processing
	if ! declare -F apply_dispatch_max >/dev/null 2>&1; then
		pulse_event_refill_log "action=blocked reason=dispatch_unavailable trigger=retained source=${source_name}"
		return 0
	fi
	while [[ -f "$trigger_file" && "$pass" -lt "$max_passes" ]]; do
		if ! _pulse_event_refill_dispatch_gate; then
			return 0
		fi
		processing_file="${trigger_file}.processing.$$"
		if ! mv -f "$trigger_file" "$processing_file" 2>/dev/null; then
			return 0
		fi
		if ! _pulse_event_refill_dispatch_gate; then
			_pulse_event_refill_restore_processing "$processing_file" "$trigger_file"
			return 0
		fi
		pass=$((pass + 1))
		pulse_event_refill_log "action=drain_started source=${source_name} pass=${pass}"
		if ! apply_dispatch_max; then
			_pulse_event_refill_restore_processing "$processing_file" "$trigger_file"
			pulse_event_refill_log "action=drain_failed source=${source_name} pass=${pass} trigger=retained"
			pulse_event_refill_counter "pulse_event_refill_failed"
			return 0
		fi
		rm -f "$processing_file" 2>/dev/null || true
		pulse_event_refill_log "action=drain_completed source=${source_name} pass=${pass}"
		pulse_event_refill_counter "pulse_event_refill_completed"
	done
	if [[ -f "$trigger_file" ]]; then
		pulse_event_refill_log "action=pass_limit trigger=retained source=${source_name} passes=${pass}"
	fi
	return 0
}

_pulse_run_refill_only() {
	local source_name="${PULSE_REFILL_SOURCE:-event}"
	local trigger_file="${PULSE_EVENT_REFILL_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-event-refill.trigger}"
	[[ -f "$trigger_file" ]] || return 0
	if ! pulse_event_refill_is_enabled; then
		pulse_event_refill_log "action=disabled trigger=retained source=${source_name}"
		return 0
	fi
	if ! _pulse_event_refill_wait_for_instance_lock; then
		[[ -f "$trigger_file" ]] && pulse_event_refill_log "action=lock_busy trigger=retained source=${source_name}"
		pulse_event_refill_counter "pulse_event_refill_lock_busy"
		return 0
	fi
	trap '_pulse_event_refill_cleanup' EXIT
	if ! check_session_gate; then
		pulse_event_refill_log "action=blocked reason=session_gate trigger=retained source=${source_name}"
		release_instance_lock
		return 0
	fi
	if [[ "${AIDEVOPS_PULSE_REST_FIRST_READS:-1}" == "1" ]]; then
		export AIDEVOPS_GH_REST_FIRST_READS=1
	fi
	if declare -F _pulse_set_graphql_budget_priority >/dev/null 2>&1; then
		_pulse_set_graphql_budget_priority
	fi
	if declare -F _dispatch_invalidate_candidate_snapshot >/dev/null 2>&1; then
		_dispatch_invalidate_candidate_snapshot "event_refill" || true
	fi
	pulse_event_refill_drain "$source_name"
	release_instance_lock
	return 0
}

_pulse_event_refill_main() {
	local command_name="${1:-}"
	case "$command_name" in
	signal)
		shift
		local issue_number="${1:-}"
		local worker_pid="${2:-}"
		pulse_event_refill_signal "$issue_number" "$worker_pid"
		return $?
		;;
	*)
		printf 'Usage: %s signal <issue-number> <worker-pid>\n' "$0" >&2
		return 2
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	_pulse_event_refill_main "$@"
	exit $?
fi
