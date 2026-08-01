#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Attempt Helpers
# =============================================================================
# Focused setup, retry, diagnostics, and metric phases used by
# headless-runtime-helper.sh::_execute_run_attempt.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-attempt.sh"
# Part of aidevops framework: https://aidevops.sh

# Attempt phases intentionally share the orchestrator's locals and arrays.
# shellcheck disable=SC2154

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_HEADLESS_RUNTIME_ATTEMPT_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_ATTEMPT_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_attempt_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_attempt_lib_path" == "${BASH_SOURCE[0]}" ]] && _attempt_lib_path="."
	SCRIPT_DIR="$(cd "$_attempt_lib_path" && pwd)"
	unset _attempt_lib_path
fi

# Resolve prompt transport, provider/session state, and the runtime command.
_prepare_run_attempt_command() {
	_recover_deleted_cwd_before_launch "$work_dir" "execute_run_attempt" || return 1
	runtime="${headless_runtime:-opencode}"
	if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" && "$runtime" != "opencode" ]] && ! _headless_private_workload_enabled; then
		print_error "Public triage supports only the isolated OpenCode runtime"
		return 126
	fi
	if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" ]] && ! _headless_private_workload_enabled; then
		force_file_transport=1
	fi
	if ! _prepare_runtime_prompt_transport "$runtime" "$prompt" "$force_file_transport"; then
		print_error "Public triage could not prepare protected prompt transport"
		return 126
	fi
	prompt_arg="$_HEADLESS_RUN_PROMPT_ARG"
	prompt_file_arg="$_HEADLESS_RUN_PROMPT_FILE"
	claude_stdin_file="$_HEADLESS_CLAUDE_STDIN_FILE"
	[[ -z "$prompt_file_arg" ]] || extra_args+=(--file "$prompt_file_arg")
	_HEADLESS_CLAUDE_STDIN_FILE="$claude_stdin_file"
	provider=$(extract_provider "$selected_model")
	metric_work_dir="$work_dir"
	if _headless_run_is_ephemeral "$role"; then
		metric_work_dir=""
		clear_session_id "$provider" "$session_key"
	elif [[ "$role" == "pulse" ]]; then
		clear_session_id "$provider" "$session_key"
	else
		persisted_session=$(get_session_id "$provider" "$session_key")
	fi
	case "$runtime" in
	claude)
		if ! type -P claude >/dev/null 2>&1; then
			print_error "Claude CLI not found in PATH (requested via --runtime claude)"
			return 1
		fi
		while IFS= read -r -d '' arg; do cmd+=("$arg"); done < <(
			_build_claude_cmd "$selected_model" "$work_dir" "$prompt_arg" "$title" \
				"$agent_name" "${extra_args[@]+"${extra_args[@]}"}"
		)
		;;
	opencode | *)
		while IFS= read -r -d '' arg; do cmd+=("$arg"); done < <(
			_build_run_cmd "$selected_model" "$work_dir" "$prompt_arg" "$title" \
				"$variant_override" "$agent_name" "$persisted_session" "${extra_args[@]+"${extra_args[@]}"}"
		)
		;;
	esac
	return 0
}

# Create and register all per-attempt files before arming the runtime boundary.
_create_run_attempt_files() {
	start_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	output_file=$(_create_headless_runtime_temp_file) || return 1
	if ! _register_headless_runtime_output_temp_path "$role" "$output_file"; then
		rm -f "$output_file" 2>/dev/null || true
		return 1
	fi
	permission_request_file=$(_create_headless_runtime_temp_file) || {
		rm -f "$output_file"
		return 1
	}
	_register_headless_runtime_temp_path "$permission_request_file"
	rm -f "$permission_request_file" 2>/dev/null || true
	export AIDEVOPS_PERMISSION_REQUEST_FILE="$permission_request_file"
	_run_permission_request_file="$permission_request_file"
	exit_code_file=$(_create_headless_runtime_temp_file) || {
		rm -f "$output_file" "$permission_request_file"
		return 1
	}
	_register_headless_runtime_temp_path "$exit_code_file"
	resource_stop_file=$(_create_headless_runtime_temp_file) || {
		rm -f "$output_file" "$exit_code_file"
		return 1
	}
	_register_headless_runtime_temp_path "$resource_stop_file"
	resource_result_file=$(_create_headless_runtime_temp_file) || {
		rm -f "$output_file" "$exit_code_file" "$resource_stop_file"
		return 1
	}
	_register_headless_runtime_temp_path "$resource_result_file"
	rm -f "$resource_stop_file" "$resource_result_file" 2>/dev/null || true
	exit_code=0
	return 0
}

# Publish invocation globals and run the fix-the-fixer preflight.
_configure_run_attempt_context() {
	_invoke_session_key="$session_key"
	_invoke_provider="$provider"
	_invoke_role="$role"
	_invoke_persisted_session="$persisted_session"
	_invoke_work_dir="$work_dir"
	export WORKER_SESSION_KEY="$session_key"
	_t3077_setup_fix_the_fixer_observability "${WORKER_ISSUE_NUMBER:-}" "${DISPATCH_REPO_SLUG:-}" || true
	if ! _t3077_write_preflight_sentinel; then
		print_error "[lifecycle] preflight_abort reason=sentinel_write_blocked pid=$$ session=$session_key"
		printf '11' >"$exit_code_file" 2>/dev/null || true
		exit_code=11
		return 11
	fi
	return 0
}

# Start resource and verbose-lifecycle observers after ownership is verified.
_start_run_attempt_observers() {
	if [[ -x "$RESOURCE_METRICS_HELPER" ]]; then
		"$RESOURCE_METRICS_HELPER" sample \
			--pid "$$" --role "$role" --session-key "$session_key" \
			--repo "${DISPATCH_REPO_SLUG:-}" --issue "${WORKER_ISSUE_NUMBER:-}" \
			--result-file "$resource_result_file" --out "$RESOURCE_METRICS_FILE" \
			--stop-file "$resource_stop_file" \
			--interval "${AIDEVOPS_RESOURCE_SAMPLE_INTERVAL_SECONDS:-30}" >/dev/null 2>&1 &
		resource_sampler_pid="$!"
	fi
	_t3077_watcher_pid=$(_start_verbose_lifecycle_watcher "$output_file" "$$" 2>/dev/null) || true
	if [[ -n "$_t3077_watcher_pid" ]]; then
		print_info "[lifecycle] verbose_watcher_started pid=${_t3077_watcher_pid} worker=$$ log=${output_file}"
	fi
	return 0
}

# Read and normalize the first runtime process result.
_complete_run_attempt_invocation() {
	_cleanup_verbose_lifecycle_watcher "$$" 2>/dev/null || true
	print_info "[lifecycle] invoke_returned session=$session_key pid=$$ exit_code_file_exists=$(test -f "$exit_code_file" && echo yes || echo no)"
	exit_code=$(cat "$exit_code_file" 2>/dev/null) || exit_code=1
	print_info "[lifecycle] exit_code_read session=$session_key exit_code=$exit_code"
	_normalized_exit_info=$(_normalize_worker_exit_code_and_kill_reason "$exit_code_file" "$exit_code")
	IFS=$'\t' read -r exit_code _metric_kill_reason <<<"$_normalized_exit_info"
	_run_watchdog_hard_killed=0
	_stall_killed_marker="${exit_code_file}.watchdog_stall_killed"
	if [[ -f "$_stall_killed_marker" ]]; then
		_run_watchdog_hard_killed=1
		rm -f "$_stall_killed_marker"
	fi
	_rl_fast_sentinel="${exit_code_file}.rate_limit_fast"
	rm -f "$exit_code_file"
	return 0
}

# Retry a corrupt prewarmed OpenCode database once with fresh scratch state.
_retry_run_attempt_fresh_database() {
	if [[ "$runtime" == "claude" ]] || ! _opencode_project_table_migration_replay_detected "$exit_code" "$output_file"; then
		return 0
	fi
	print_warning "OpenCode worker DB migration replay detected for ${session_key}; retrying once with fresh isolated DB (GH#25541)"
	unset AIDEVOPS_WORKER_PREWARM_DIR
	rm -f "$output_file" 2>/dev/null || true
	output_file=$(_create_headless_runtime_temp_file) || return 1
	_register_headless_runtime_output_temp_path "$role" "$output_file" || return 1
	exit_code_file=$(_create_headless_runtime_temp_file) || {
		rm -f "$output_file"
		return 1
	}
	_register_headless_runtime_temp_path "$exit_code_file"
	exit_code=0
	_begin_worker_runtime_run
	_invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}"
	if ! read -r exit_code <"$exit_code_file" 2>/dev/null; then exit_code=1; fi
	_normalized_exit_info=$(_normalize_worker_exit_code_and_kill_reason "$exit_code_file" "$exit_code")
	IFS=$'\t' read -r exit_code _metric_kill_reason <<<"$_normalized_exit_info"
	local retry_stall_marker="${exit_code_file}.watchdog_stall_killed"
	if [[ -f "$retry_stall_marker" ]]; then
		_run_watchdog_hard_killed=1
		rm -f "$retry_stall_marker"
	fi
	_rl_fast_sentinel="${exit_code_file}.rate_limit_fast"
	rm -f "$exit_code_file"
	return 0
}

# Retry once without a stale persisted OpenCode session ID.
_retry_run_attempt_without_stale_session() {
	[[ "$exit_code" != "0" && "$runtime" != "claude" && -n "$persisted_session" ]] || return 0
	local output_text=""
	output_text=$(cat "$output_file" 2>/dev/null || true)
	[[ "$output_text" == *"Session not found"* ]] || return 0
	print_warning "Stale session ID detected for ${session_key} — clearing and retrying without --session (GH#16978)"
	clear_session_id "$provider" "$session_key"
	persisted_session=""
	rm -f "$output_file"
	output_file=$(_create_headless_runtime_temp_file) || return 1
	_register_headless_runtime_output_temp_path "$role" "$output_file" || return 1
	exit_code_file=$(_create_headless_runtime_temp_file) || {
		rm -f "$output_file"
		return 1
	}
	_register_headless_runtime_temp_path "$exit_code_file"
	exit_code=0
	cmd=()
	while IFS= read -r -d '' arg; do cmd+=("$arg"); done < <(
		_build_run_cmd "$selected_model" "$work_dir" "$prompt_arg" "$title" \
			"$variant_override" "$agent_name" "$persisted_session" "${extra_args[@]+"${extra_args[@]}"}"
	)
	_begin_worker_runtime_run
	_invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}"
	exit_code=$(cat "$exit_code_file" 2>/dev/null) || exit_code=1
	_normalized_exit_info=$(_normalize_worker_exit_code_and_kill_reason "$exit_code_file" "$exit_code")
	IFS=$'\t' read -r exit_code _metric_kill_reason <<<"$_normalized_exit_info"
	local retry_stall_marker="${exit_code_file}.watchdog_stall_killed"
	if [[ -f "$retry_stall_marker" ]]; then
		_run_watchdog_hard_killed=1
		rm -f "$retry_stall_marker"
	fi
	rm -f "$exit_code_file"
	return 0
}

# Record the fast rate-limit sentinel as a terminal attempt metric.
_finish_run_attempt_rate_limit_fast() {
	local metric_output_file="" metric_session_id=""
	if [[ -f "$output_file" ]] && ! _headless_run_is_ephemeral "$role"; then
		metric_session_id=$(extract_session_id_from_output "$output_file" 2>/dev/null || true)
		metric_output_file=$(_metric_failure_excerpt_path "$output_file" "$session_key")
	fi
	_run_result_label="rate_limit_fast"
	_hrw_reconcile_session_permission_blockers "$session_key" "$_run_result_label"
	rm -f "$_rl_fast_sentinel" "$output_file" "$permission_request_file" 2>/dev/null || true
	_run_permission_request_file=""
	unset AIDEVOPS_PERMISSION_REQUEST_FILE
	_run_failure_reason="$_run_result_label"
	_run_provider_error_type="rate_limit"
	_run_provider_status="429"
	_run_runtime_error_type=""
	_run_classification_source="rate_limit_fast_monitor"
	_run_classification_pattern="rate_limit_fast_sentinel"
	local rate_limit_end_ms
	rate_limit_end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	local rate_limit_duration_ms=0
	if [[ "$rate_limit_end_ms" =~ ^[0-9]+$ && "$start_ms" =~ ^[0-9]+$ && "$rate_limit_end_ms" -ge "$start_ms" ]]; then
		rate_limit_duration_ms=$((rate_limit_end_ms - start_ms))
	fi
	print_info "[lifecycle] rate_limit_fast_exit session=$session_key model=$selected_model duration_ms=${rate_limit_duration_ms}"
	_stop_run_attempt_resource_sampler "$_run_result_label"
	append_runtime_metric "$role" "$session_key" "$selected_model" "$provider" "$_run_result_label" "0" "$_run_failure_reason" "0" "$rate_limit_duration_ms" \
		"${WORKER_ISSUE_NUMBER:-}" "${DISPATCH_REPO_SLUG:-}" "$metric_work_dir" "$metric_output_file" "$metric_session_id" \
		"${_run_provider_error_type:-}" "${_run_provider_status:-}" "${_run_runtime_error_type:-}" "${_run_classification_source:-}" "${_run_classification_pattern:-}" \
		"provider_rate_limited" "${_metric_kill_reason}" "rotate_provider_or_wait_for_reset"
	return 80
}

_stop_run_attempt_resource_sampler() {
	local result_label="$1"
	if [[ -n "$resource_sampler_pid" ]]; then
		printf '%s\n' "$result_label" >"$resource_result_file" 2>/dev/null || true
		printf 'done\n' >"$resource_stop_file" 2>/dev/null || true
		wait "$resource_sampler_pid" 2>/dev/null || true
		rm -f "$resource_stop_file" "$resource_result_file" 2>/dev/null || true
	fi
	return 0
}

# Add process diagnostics and capture metric evidence paths before classification.
_append_run_attempt_diagnostics() {
	local diag_session_id="" diag_incomplete_msgs="0"
	if [[ -f "$output_file" ]] && ! _headless_run_is_ephemeral "$role"; then
		_metric_session_id=$(extract_session_id_from_output "$output_file" 2>/dev/null || true)
	fi
	if [[ "$exit_code" == "0" && -n "$_metric_session_id" ]]; then
		diag_session_id="$_metric_session_id"
		diag_incomplete_msgs=$(sqlite3 ~/.local/share/opencode/opencode.db \
			"SELECT count(*) FROM message WHERE session_id='${diag_session_id}' AND json_extract(data, '$.role')='assistant' AND json_extract(data, '$.time.completed') IS NULL" 2>/dev/null || echo "0")
	fi
	{
		printf '\n[WORKER_EXIT_DIAGNOSTICS] exit_code=%s model=%s role=%s session_key=%s\n' "$exit_code" "$selected_model" "$role" "$session_key"
		printf '[WORKER_EXIT_DIAGNOSTICS] structured exit_code=%s kill_reason=%s session_key=%s\n' "$exit_code" "${_metric_kill_reason:-unknown}" "$session_key"
		case "$exit_code" in
		124) printf '[WORKER_EXIT_DIAGNOSTICS] cause=watchdog_kill (no LLM activity within timeout)\n' ;;
		137) printf '[WORKER_EXIT_DIAGNOSTICS] cause=SIGKILL (OOM or external kill)\n' ;;
		143) printf '[WORKER_EXIT_DIAGNOSTICS] cause=SIGTERM (graceful termination)\n' ;;
		0) [[ "$diag_incomplete_msgs" -le 0 ]] || printf '[WORKER_EXIT_DIAGNOSTICS] cause=mid_turn_death (session %s has %s incomplete assistant messages — API likely dropped)\n' "$diag_session_id" "$diag_incomplete_msgs" ;;
		*) printf '[WORKER_EXIT_DIAGNOSTICS] cause=unknown (exit_code=%s)\n' "$exit_code" ;;
		esac
	} >>"$output_file" 2>/dev/null || true
	print_info "[lifecycle] calling_handle_run_result session=$session_key exit_code=$exit_code output_size=$(wc -c <"$output_file" 2>/dev/null || echo 0)"
	if ! _headless_run_is_ephemeral "$role"; then
		_metric_excerpt_candidate=$(_metric_failure_excerpt_candidate_path "$output_file" "$session_key")
	fi
	return 0
}

# Classify the output, clean transient files, and append the terminal metric.
_finish_run_attempt_result() {
	local handle_exit=0
	if _handle_run_result "$exit_code" "$output_file" "$role" "$provider" "$session_key" "$selected_model" "$work_dir"; then
		handle_exit=0
	else
		handle_exit=$?
	fi
	if [[ "$handle_exit" -ne 84 ]]; then
		_hrw_reconcile_session_permission_blockers "$session_key" "${_run_result_label:-headless_session_exit}"
		rm -f "$permission_request_file" 2>/dev/null || true
		_run_permission_request_file=""
		unset AIDEVOPS_PERMISSION_REQUEST_FILE
	fi
	if _headless_run_is_ephemeral "$role"; then
		rm -f "$output_file" "$permission_request_file" 2>/dev/null || true
		_metric_output_file=""
		_metric_session_id=""
	fi
	_run_metric_output_file="$_metric_output_file"
	_run_metric_session_id="$_metric_session_id"
	print_info "[lifecycle] handle_run_result_returned session=$session_key handle_exit=$handle_exit result_label=${_run_result_label:-unknown}"
	end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	if [[ "$end_ms" =~ ^[0-9]+$ && "$start_ms" =~ ^[0-9]+$ && "$end_ms" -ge "$start_ms" ]]; then
		duration_ms=$((end_ms - start_ms))
	else
		duration_ms=0
	fi
	_stop_run_attempt_resource_sampler "${_run_result_label:-failed}"
	local metric_result_label="${_run_result_label:-failed}"
	if ! _headless_run_is_ephemeral "$role"; then
		_metric_output_file=$(_metric_failure_excerpt_for_result "$metric_result_label" "$_metric_excerpt_candidate" "$session_key")
	fi
	[[ -z "$_metric_excerpt_candidate" ]] || rm -f "$_metric_excerpt_candidate"
	local launch_failure_cause="" next_action="" evidence_fields=""
	evidence_fields=$(_derive_worker_failure_evidence "$metric_result_label" "$exit_code" \
		"${_run_activity_detected:-0}" "${_metric_kill_reason:-}" "${_run_failure_reason:-}")
	launch_failure_cause="${evidence_fields%%$'\t'*}"
	next_action="${evidence_fields#*$'\t'}"
	if [[ "$metric_result_label" == "watchdog_stall_killed" ]] && _worker_post_pr_handoff_confirmed "$session_key" "$work_dir"; then
		launch_failure_cause="post_pr_pending_ci_handoff"
		next_action="monitor_open_pr"
	fi
	print_info "[lifecycle] worker_failure_evidence session=$session_key result=$metric_result_label exit_code=$exit_code kill_reason=${_metric_kill_reason:-unknown} launch_failure_cause=${launch_failure_cause:-none} next_action=${next_action:-none}"
	append_runtime_metric "$role" "$session_key" "$selected_model" "$provider" "$metric_result_label" "$handle_exit" "${_run_failure_reason:-}" "${_run_activity_detected:-0}" "$duration_ms" \
		"${WORKER_ISSUE_NUMBER:-}" "${DISPATCH_REPO_SLUG:-}" "$metric_work_dir" "$_metric_output_file" "$_metric_session_id" \
		"${_run_provider_error_type:-}" "${_run_provider_status:-}" "${_run_runtime_error_type:-}" "${_run_classification_source:-}" "${_run_classification_pattern:-}" \
		"$launch_failure_cause" "${_metric_kill_reason:-}" "$next_action"
	return "$handle_exit"
}
