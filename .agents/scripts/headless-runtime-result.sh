#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Result Classification Helpers
# =============================================================================
# Focused phases used by headless-runtime-helper.sh::_handle_run_result. The
# original function remains a small orchestrator so its scanner identity is
# preserved while classifications stay independently testable.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-result.sh"
# Part of aidevops framework: https://aidevops.sh

# Result phases intentionally share the orchestrator's locals.
# shellcheck disable=SC2154

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_HEADLESS_RUNTIME_RESULT_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_RESULT_LOADED=1

_RUN_RESULT_ROLE_WORKER="worker"
_RUN_RESULT_ROLE_PULSE="pulse"
_RUN_RESULT_RATE_LIMIT="rate_limit"

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_result_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_result_lib_path" == "${BASH_SOURCE[0]}" ]] && _result_lib_path="."
	SCRIPT_DIR="$(cd "$_result_lib_path" && pwd)"
	unset _result_lib_path
fi

_initialize_run_result() {
	if [[ ! "${exit_code:-}" =~ ^[0-9]+$ ]]; then
		exit_code=1
	fi
	discovered_session=$(extract_session_id_from_output "$output_file")
	activity_detected=$(output_has_activity "$output_file")
	_run_activity_detected="$activity_detected"
	_run_result_label="failed"
	_run_provider_error_type=""
	_run_provider_status=""
	_run_runtime_error_type=""
	_run_classification_source=""
	_run_classification_pattern=""
	return 0
}

_run_result_has_permission_event() {
	if [[ "$role" == "$_RUN_RESULT_ROLE_WORKER" && -n "${_run_permission_request_file:-}" &&
		-f "${_run_permission_request_file}" ]]; then
		return 0
	fi
	return 1
}

_handle_run_result_permission_event() {
	if [[ -n "$discovered_session" ]]; then
		_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session" "$selected_model" "$role"
	fi
	local completion_evidence=""
	if completion_evidence=$(_hrw_post_merge_permission_completion_evidence \
		"$session_key" "$discovered_session" "$work_dir"); then
		local completed_pr="" cleanup_receipt="" cleanup_state="" executor_state="" cleanup_owner_session=""
		IFS=$'\t' read -r completed_pr cleanup_receipt cleanup_state executor_state cleanup_owner_session <<<"$completion_evidence"
		_run_result_label="$_HRW_STATUS_POST_MERGE_CLEANUP"
		_run_failure_reason=""
		_run_classification_source="merged_pr_cleanup_receipt"
		_run_classification_pattern="permission.asked_after_merged_objective"
		print_info "[lifecycle] post_merge_permission_reconciled session=${session_key} pr=${completed_pr} implementation=completed cleanup=${cleanup_state} executor=${executor_state} cleanup_authority=guarded-supervisor owner_session=${cleanup_owner_session} receipt=${cleanup_receipt} verify='full-loop-helper.sh status --json'"
		return 0
	fi
	_run_result_label="permission_required"
	_run_failure_reason="$_run_result_label"
	_run_classification_source="opencode_permission_event"
	_run_classification_pattern="permission.asked"
	print_warning "$selected_model requested a capability outside the worker permission boundary — pausing for maintainer approval"
	return 84
}

_handle_run_result_no_activity() {
	_run_result_label="no_activity"
	if [[ "$suppress_persistent_output" -eq 1 ]]; then
		rm -f "$output_file" 2>/dev/null || true
		print_warning "$selected_model returned exit 0 without any model activity (ephemeral output discarded)"
	else
		_preserve_no_activity_output "$output_file" "$session_key" "$selected_model"
		print_warning "$selected_model returned exit 0 without any model activity (no backoff recorded — forensic copy preserved via t2119)"
	fi
	return 75
}

_handle_run_result_success_output() {
	if _headless_private_workload_enabled && ! _private_output_has_task_complete "$output_file"; then
		_run_result_label="private_incomplete"
		_run_failure_reason="$_run_result_label"
		rm -f "$output_file" 2>/dev/null || true
		print_warning "$selected_model private workload exited without TASK_COMPLETE"
		return 77
	fi
	if [[ "$role" != "$_RUN_RESULT_ROLE_PULSE" && -n "$discovered_session" ]]; then
		_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session" "$selected_model" "$role"
	fi
	if [[ "$role" == "$_RUN_RESULT_ROLE_WORKER" && "$session_key" == issue-* ]]; then
		if ! output_has_completion_signal "$output_file"; then
			_log_empty_result_gaps "$output_file" "$selected_model" "$session_key"
			_run_result_label="premature_exit"
			rm -f "$output_file"
			print_warning "$selected_model worker exited with activity but no completion signal (premature exit — will attempt continuation)"
			return 77
		fi
		if output_has_post_pr_handoff_signal "$output_file"; then
			_run_result_label="post_pr_handoff"
			rm -f "$output_file"
			return 0
		fi
		if output_has_missing_context_blocked_signal "$output_file"; then
			_run_result_label="brief_recovery"
			_run_failure_reason="missing_implementation_context"
			_run_classification_source="model_blocked_signal"
			_run_classification_pattern="missing_implementation_context"
			rm -f "$output_file"
			print_warning "$selected_model worker reported missing implementation context — attempting one brief-recovery continuation"
			return 82
		fi
		if output_has_blocked_signal "$output_file"; then
			_run_result_label="blocked"
			_run_failure_reason="blocked"
			_run_classification_source="model_blocked_signal"
			rm -f "$output_file"
			print_warning "$selected_model worker reported BLOCKED terminal state — evaluating bounded capability escalation"
			return 83
		fi
	fi
	_run_result_label="success"
	rm -f "$output_file"
	return 0
}

# Classify exit 124. Sets failure_reason and optional _run_result_handled_exit.
_classify_watchdog_run_result() {
	failure_reason=$(classify_failure_reason "$output_file")
	if [[ "$failure_reason" == "$_RUN_RESULT_RATE_LIMIT" ]]; then
		print_warning "$selected_model watchdog saw provider/rate-limit marker — classifying as rate_limit for rotation"
		return 0
	fi
	if [[ "$activity_detected" == "1" ]]; then
		local continue_session=""
		continue_session=$(extract_session_id_from_output "$output_file")
		if [[ "$role" != "$_RUN_RESULT_ROLE_PULSE" && -n "$continue_session" ]]; then
			_store_headless_session_if_allowed "$provider" "$session_key" "$continue_session" "$selected_model" "$role"
		fi
		if [[ "${_run_watchdog_hard_killed:-0}" -eq 1 ]]; then
			local hard_kill_label="watchdog_stall_killed"
			_run_result_label="$hard_kill_label"
			_run_failure_reason="$hard_kill_label"
			rm -f "$output_file"
			print_warning "$selected_model watchdog hard-kill (elapsed ≥ WORKER_STALL_HARD_KILL_SECONDS) — slot freed for re-dispatch (no continuation)"
			_run_result_handled_exit=79
			return 0
		fi
		_run_result_label="watchdog_stall_continue"
		rm -f "$output_file"
		print_warning "$selected_model watchdog stall with prior activity — will attempt session continuation"
		_run_result_handled_exit=78
		return 0
	fi
	if [[ -s "$output_file" && "$role" != "$_RUN_RESULT_ROLE_PULSE" ]]; then
		_run_result_label="watchdog_startup_continue"
		_run_failure_reason="startup_no_model_activity"
		rm -f "$output_file"
		print_warning "$selected_model watchdog startup stall without model activity — will attempt bounded continuation before provider backoff"
		_run_result_handled_exit=78
		return 0
	fi
	failure_reason="$_RUN_RESULT_RATE_LIMIT"
	_failure_provider_error_type="$_RUN_RESULT_RATE_LIMIT"
	_failure_provider_status="429"
	_failure_classification_source="watchdog_no_activity"
	_failure_classification_pattern="watchdog_timeout_no_activity"
	print_warning "$selected_model activity watchdog timeout (no activity) — classifying as rate_limit for rotation"
	return 0
}

# Classify non-watchdog signal exits before generic provider parsing.
_classify_signal_run_result() {
	local local_kill_reason="${_metric_kill_reason:-}"
	if [[ "$role" == "$_RUN_RESULT_ROLE_WORKER" && "$session_key" == issue-* ]] &&
		[[ "${exit_code:-}" == "137" || "${exit_code:-}" == "143" ]] &&
		[[ -n "$local_kill_reason" && "$local_kill_reason" != "natural" && "$local_kill_reason" != "unknown" ]]; then
		_run_result_label="local_kill"
		_run_failure_reason="$local_kill_reason"
		if [[ "${exit_code:-}" == "143" ]]; then
			_run_runtime_error_type="sigterm"
		else
			_run_runtime_error_type="sigkill"
		fi
		_run_classification_source="worker_kill_reason_sentinel"
		_run_classification_pattern="$local_kill_reason"
		rm -f "$output_file"
		print_warning "$selected_model worker was terminated by local kill source ${local_kill_reason} — not attempting provider/runtime continuation"
		_run_result_handled_exit=83
		return 0
	fi
	if [[ "${exit_code:-}" == "137" && "$activity_detected" == "1" ]]; then
		local signal_session=""
		signal_session=$(extract_session_id_from_output "$output_file")
		if [[ "$role" != "$_RUN_RESULT_ROLE_PULSE" && -n "$signal_session" ]]; then
			_store_headless_session_if_allowed "$provider" "$session_key" "$signal_session" "$selected_model" "$role"
		fi
		_run_result_label="signal_killed_continue"
		_run_failure_reason="signal_killed_continue"
		_run_runtime_error_type="sigkill"
		_run_classification_source="worker_exit_diagnostics"
		_run_classification_pattern="exit_137_with_activity"
		rm -f "$output_file"
		print_warning "$selected_model worker exited with SIGKILL after activity — will attempt session continuation"
		_run_result_handled_exit=78
		return 0
	fi
	failure_reason=$(classify_failure_reason "$output_file")
	return 0
}

_copy_run_failure_classification() {
	_run_result_label="$failure_reason"
	_run_provider_error_type="${_failure_provider_error_type:-}"
	_run_provider_status="${_failure_provider_status:-}"
	_run_runtime_error_type="${_failure_runtime_error_type:-}"
	_run_classification_source="${_failure_classification_source:-}"
	_run_classification_pattern="${_failure_classification_pattern:-}"
	return 0
}

# Route interruptions with durable session evidence to dedicated continuations.
_handle_transient_run_result() {
	if [[ "$role" == "$_RUN_RESULT_ROLE_WORKER" && "$session_key" == issue-* ]] &&
		runtime_signal_terminated_candidate "$output_file" "$exit_code" "$activity_detected"; then
		if [[ -n "$discovered_session" ]]; then
			_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session" "$selected_model" "$role"
		fi
		_run_result_label="signal_terminated_continue"
		_run_failure_reason="signal_terminated_continue"
		_run_runtime_error_type="sigterm"
		_run_classification_source="worker_exit_diagnostics"
		_run_classification_pattern="sigterm_or_terminated_tail"
		rm -f "$output_file"
		print_warning "$selected_model worker received SIGTERM after activity — will attempt session continuation"
		_run_result_handled_exit=78
		return 0
	fi
	if [[ "$role" == "$_RUN_RESULT_ROLE_WORKER" && "$session_key" == issue-* ]] &&
		service_interruption_continue_candidate \
			"$failure_reason" "$exit_code" "$activity_detected" "$discovered_session" \
			"${_failure_provider_error_type:-}"; then
		if [[ -n "$discovered_session" ]]; then
			_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session" "$selected_model" "$role"
		fi
		local interruption_label="service_interruption_continue"
		_run_result_label="$interruption_label"
		_run_failure_reason="$failure_reason"
		print_warning "$selected_model service interruption after activity/session evidence — will attempt session continuation"
		_run_result_handled_exit=81
	fi
	return 0
}

_finish_failed_run_result() {
	if attempt_pool_recovery "$provider" "$failure_reason" "$output_file"; then
		_run_should_retry=1
		rm -f "$output_file"
		_run_failure_reason="$failure_reason"
		return 76
	fi
	if [[ "$role" == "$_RUN_RESULT_ROLE_PULSE" ]]; then
		record_provider_backoff "$provider" "$failure_reason" "$output_file" "${_RUN_RESULT_ROLE_PULSE}/${selected_model}" "$suppress_persistent_output"
	else
		record_provider_backoff "$provider" "$failure_reason" "$output_file" "$selected_model" "$suppress_persistent_output"
	fi
	rm -f "$output_file"
	_run_failure_reason="$failure_reason"
	_run_should_retry=0
	return "$exit_code"
}
