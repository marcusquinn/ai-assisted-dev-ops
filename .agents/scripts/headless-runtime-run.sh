#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Run-Orchestration Helpers
# =============================================================================
# Focused environment, dispatch, continuation, and retry phases used by
# headless-runtime-helper.sh::cmd_run.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-run.sh"
# Part of aidevops framework: https://aidevops.sh

# Run phases intentionally share cmd_run's caller-scoped state.
# shellcheck disable=SC2154

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_HEADLESS_RUNTIME_RUN_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_RUN_LOADED=1

_CMD_RUN_DISPOSITION_RETURN="return"
_CMD_RUN_DISPOSITION_CONTINUE="continue"
_CMD_RUN_ROLE_WORKER="worker"
_CMD_RUN_AI_RESEARCH_ORIGIN="ai-research"
_CMD_RUN_AI_RESEARCH_AGENT="research-only"

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_run_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_run_lib_path" == "${BASH_SOURCE[0]}" ]] && _run_lib_path="."
	SCRIPT_DIR="$(cd "$_run_lib_path" && pwd)"
	unset _run_lib_path
fi

# Bound provider/model retries to the configured same-tier candidate count.
# One extra attempt per candidate allows an OAuth pool account rotation without
# consuming the opportunity to try every configured provider candidate.
_headless_route_attempt_budget() {
	local tier="${1:-standard}"
	local candidate=""
	local candidate_count=0
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		candidate_count=$((candidate_count + 1))
	done < <(get_configured_models "$tier" 2>/dev/null || true)

	local budget=$((candidate_count * 2))
	[[ "$budget" -ge 3 ]] || budget=3
	[[ "$budget" -le 12 ]] || budget=12
	printf '%s\n' "$budget"
	return 0
}

# This tuple only selects a stricter no-tools profile. The triage role remains
# authoritative for credential isolation, provider egress, and sandboxing.
_headless_ai_research_contract_is_valid() {
	local requested_origin="$1"
	local requested_tool_ceiling="$2"
	local requested_agent="$3"
	if [[ "$requested_origin" == "$_CMD_RUN_AI_RESEARCH_ORIGIN" && \
		"$requested_tool_ceiling" == "1" && \
		"$requested_agent" == "$_CMD_RUN_AI_RESEARCH_AGENT" ]]; then
		return 0
	fi
	return 1
}

# Establish the role/private boundary and initialize process-local workspace.
_prepare_cmd_run_environment() {
	_hrff_capture_external_outcome_contract
	local requested_session_origin="${AIDEVOPS_SESSION_ORIGIN:-}"
	local requested_ai_research_ceiling="${AIDEVOPS_AI_RESEARCH_TOOL_CEILING:-}"
	local requested_attempt_state_root="${AIDEVOPS_ATTEMPT_STATE_ROOT:-}"
	local requested_attempt_state_file="${AIDEVOPS_ATTEMPT_STATE_FILE:-}"
	if [[ "$role" != "$_CMD_RUN_ROLE_WORKER" ]]; then
		_hrw_prepare_role_context "$role" "$work_dir" || return 1
		if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" || "$role" == "$HEADLESS_ROLE_MODEL_REPLAY" ]]; then
			export AIDEVOPS_HEADLESS=1
			export AIDEVOPS_HEADLESS_AUTH_ISOLATION=1
			if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" ]] && _headless_ai_research_contract_is_valid \
				"$requested_session_origin" "$requested_ai_research_ceiling" \
				"${agent_name:-}"; then
				export AIDEVOPS_SESSION_ORIGIN="$_CMD_RUN_AI_RESEARCH_ORIGIN"
			else
				export AIDEVOPS_SESSION_ORIGIN="$role"
				unset AIDEVOPS_AI_RESEARCH_TOOL_CEILING
			fi
		fi
	fi
	if [[ "$private_workload" -eq 1 ]]; then
		export AIDEVOPS_PRIVATE_WORKLOAD=1
		export AIDEVOPS_HEADLESS_AUTH_ISOLATION=1
		export WORKER_NO_EXIT_PUSH=1
		unset AIDEVOPS_WORKER_PREWARM_DIR
		unset AIDEVOPS_ATTEMPT_ID AIDEVOPS_ATTEMPT_STARTED_AT AIDEVOPS_CORRELATION_ID
		unset AIDEVOPS_ATTEMPT_STATE_ROOT AIDEVOPS_ATTEMPT_STATE_FILE
		unset AIDEVOPS_DISPATCH_LEASE_DEVICE AIDEVOPS_DISPATCH_LEASE_TOKEN
		unset AIDEVOPS_PARENT_WORKER_ID AIDEVOPS_ROOT_WORKER_ID AIDEVOPS_RUN_ID
		unset AIDEVOPS_VERBOSE_LIFECYCLE AIDEVOPS_WORKER_ID AIDEVOPS_WORKER_PREFLIGHT_SENTINEL
		unset DISPATCH_REPO_SLUG WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_TARGET_BRANCH
		unset WORKER_WORKTREE_PATH _WORKER_WORKTREE_PATH
	fi
	# PRRTS uses its outcome generation as the canonical worker-attempt identity.
	# Restore it after private-workload sanitization so prelaunch failures, runtime
	# lifecycle state, and the terminal outcome retain one safe join key.
	if [[ "$role" == "$_CMD_RUN_ROLE_WORKER" && \
		"${_WORKER_EXTERNAL_OUTCOME_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
		AIDEVOPS_ATTEMPT_ID="$_WORKER_EXTERNAL_OUTCOME_ID"
		export AIDEVOPS_ATTEMPT_ID
		if [[ "$private_workload" -eq 1 ]] &&
			worker_attempt_observability_state_matches_identity \
				"$requested_attempt_state_root" "$requested_attempt_state_file" \
				"$AIDEVOPS_ATTEMPT_ID"; then
			AIDEVOPS_ATTEMPT_STATE_ROOT="$requested_attempt_state_root"
			AIDEVOPS_ATTEMPT_STATE_FILE="$requested_attempt_state_file"
			export AIDEVOPS_ATTEMPT_STATE_ROOT AIDEVOPS_ATTEMPT_STATE_FILE
		fi
	fi
	if ! prepare_headless_git_auth_sandbox_env "$role"; then
		print_error "Repository-bound worker Git authentication failed prelaunch validation"
		return 1
	fi
	# Manual dispatch runs this identical consumer gate before spawning. Return
	# before detach, model selection, ownership transfer, or credential cleanup:
	# the dispatcher retains the token until readiness transfers it to the worker.
	if [[ "${AIDEVOPS_GIT_AUTH_PREFLIGHT_ONLY:-0}" == "1" ]]; then
		_cmd_run_stop=1
		_cmd_run_return_status=0
		return 0
	fi
	_ensure_valid_launch_cwd "$work_dir" || return 1
	_validate_issue_worker_env_contract "$role" "$session_key" "$work_dir" "$title" "$prompt" || return 1
	_recover_deleted_cwd_before_launch "$work_dir" "cmd_run" || return 1
	aidevops_init_temp_workspace || {
		print_error "Could not initialize aidevops temporary workspace"
		return 1
	}
	if [[ "$detach" -eq 1 ]]; then
		_detach_worker "$session_key" "$@"
		_cmd_run_stop=1
		_cmd_run_return_status=0
	fi
	return 0
}

# Publish worker lineage and renew the prelaunch lease.
_prepare_cmd_run_worker_identity() {
	[[ "$role" == "$_CMD_RUN_ROLE_WORKER" ]] || return 0
	_ensure_worker_lineage "$session_key"
	_ensure_worker_attempt_identity
	print_info "[lifecycle] prelaunch_lease_renew_start session=$session_key pid=$$"
	if ! _hrw_renew_dispatch_prelaunch_lease "$session_key"; then
		print_warning "Dispatch prelaunch lease expired before worker startup — deferring session $session_key"
		_hrw_record_terminal_outcome "$session_key" "$_HRW_TELEMETRY_DEFERRED" "prelaunch_lease_renewal_failed"
		_hrff_write_external_outcome "$session_key" "prelaunch_lease_renewal_failed" "0" "$_HRFF_RETRY_CLASS_INFRASTRUCTURE" || true
		return 1
	fi
	print_info "[lifecycle] prelaunch_lease_renew_done session=$session_key pid=$$"
	return 0
}

# Select a model and enforce the protected-data policy.
_select_cmd_run_model() {
	tier_override=$(_normalize_headless_tier "${tier_override:-standard}")
	print_info "[lifecycle] pre_model_select session=$session_key role=$role tier=${tier_override:-auto} pid=$$"
	local choose_exit=0
	selected_model=$(choose_model "$role" "$model_override" "$tier_override" "adaptive" "$initial_model") || {
		choose_exit=$?
		_hrff_write_external_outcome "$session_key" "model_selection_failed" "0" "$_HRFF_RETRY_CLASS_INFRASTRUCTURE" || true
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		return "$choose_exit"
	}
	if [[ -z "${model_override:-$initial_model}" ]]; then
		local selected_tier=""
		selected_tier=$(model_tier_for_model "$selected_model" 2>/dev/null || true)
		if [[ -n "$selected_tier" && "$selected_tier" != "$tier_override" ]]; then
			print_info "[routing] adaptive tier selection ${tier_override}->${selected_tier} model=$selected_model"
			tier_override="$selected_tier"
		fi
	fi
	print_info "[lifecycle] post_model_select session=$session_key model=$selected_model pid=$$"
	if ! vault_data_policy_check "$selected_model" "$title" "$prompt"; then
		_hrff_write_external_outcome "$session_key" "protected_data_policy_blocked" "0" "$_HRFF_RETRY_CLASS_MAINTAINER_GATE" || true
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		return 64
	fi
	return 0
}

# Run version/canary gates, prepare lifecycle ownership, and resolve variant.
_prepare_cmd_run_dispatch() {
	if ! _enforce_opencode_version_pin; then
		print_error "OpenCode version pin enforcement failed — aborting dispatch for session $session_key"
		_hrw_record_terminal_outcome "$session_key" "$_HRW_TELEMETRY_DEFERRED" "opencode_version_pin_failed"
		_hrff_write_external_outcome "$session_key" "opencode_version_pin_failed" "0" "$_HRFF_RETRY_CLASS_INFRASTRUCTURE" || true
		return 1
	fi
	print_info "[lifecycle] pre_canary session=$session_key model=$selected_model pid=$$"
	if ! _run_role_safe_canary "$role" "$selected_model"; then
		print_warning "Canary failed — aborting dispatch for session $session_key (no claim posted)"
		_hrw_record_terminal_outcome "$session_key" "deferred" "canary_failed"
		_hrff_write_external_outcome "$session_key" "canary_failed" "0" "$_HRFF_RETRY_CLASS_INFRASTRUCTURE" || true
		return 1
	fi
	print_info "[lifecycle] post_canary session=$session_key model=$selected_model pid=$$"
	if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" ]] && ! _headless_private_workload_enabled; then
		local triage_runtime_dir=""
		if ! _prepare_triage_runtime_directory "triage_runtime_dir"; then
			print_error "Public triage runtime isolation setup failed"
			return 1
		fi
		work_dir="$triage_runtime_dir"
	fi
	[[ "$role" != "$_CMD_RUN_ROLE_WORKER" ]] || prompt=$(append_worker_headless_contract "$prompt")
	local prepare_exit=0 lifecycle_work_dir="$work_dir"
	if _headless_private_workload_enabled; then
		lifecycle_work_dir="[private]"
	fi
	print_info "[lifecycle] pre_worker_prepare session=$session_key work_dir=$lifecycle_work_dir pid=$$"
	_cmd_run_prepare "$session_key" "$work_dir" "$role" || prepare_exit=$?
	if [[ "$prepare_exit" -eq 2 ]]; then
		_hrw_record_terminal_outcome "$session_key" "deferred" "duplicate_session"
		_hrff_write_external_outcome "$session_key" "duplicate_session" "0" "$_HRFF_RETRY_CLASS_INFRASTRUCTURE" || true
		_cmd_run_stop=1
		_cmd_run_return_status=0
		return 0
	fi
	if [[ "$prepare_exit" -ne 0 ]]; then
		_hrw_record_terminal_outcome "$session_key" "failed" "worker_prepare_failed"
		_hrff_write_external_outcome "$session_key" "worker_prepare_failed" "0" "$_HRFF_RETRY_CLASS_INFRASTRUCTURE" || true
		return "$prepare_exit"
	fi
	print_info "[lifecycle] post_worker_prepare session=$session_key work_dir=$lifecycle_work_dir pid=$$"
	if [[ -z "$variant_override" ]] && ! _headless_private_workload_enabled; then
		variant_override=$(resolve_headless_variant "$role" "$tier_override" "$selected_model")
	fi
	return 0
}

_resolve_capability_escalation() {
	local role="$1"
	local current_tier="$2"
	local current_model="${3:-}"
	local current_variant="${4:-}"
	_capability_escalation_model=""
	_capability_escalation_variant=""
	_capability_escalation_label=""
	_capability_escalation_tier=""
	[[ "$role" == "worker" ]] || return 1
	if [[ -n "$current_model" && -n "$current_variant" ]] &&
		_capability_escalation_variant=$(model_tier_next_variant "$current_tier" "$current_model" "$current_variant"); then
		_capability_escalation_tier="$current_tier"
		_capability_escalation_model="$current_model"
		_capability_escalation_label="${current_tier} capability limit — increasing ${current_model} reasoning from ${current_variant} to ${_capability_escalation_variant}"
		return 0
	fi
	_capability_escalation_tier=$(model_tier_next "$current_tier" 2>/dev/null) || return 1
	_capability_escalation_model=$(choose_model "$role" "" "$_capability_escalation_tier" "exact-tier") || return 1
	_capability_escalation_variant=$(resolve_headless_variant "$role" "$_capability_escalation_tier" "$_capability_escalation_model")
	_capability_escalation_label="${current_tier} tier reported BLOCKED — escalating to ${_capability_escalation_tier} (${_capability_escalation_model}${_capability_escalation_variant:+ ${_capability_escalation_variant}})"
	return 0
}

# Handle attempt results that always terminate or immediately escalate.
_handle_cmd_run_terminal_attempt() {
	local finish_status=0
	local signing_unavailable_result="worker_signing_unavailable"
	case "$attempt_exit" in
	0)
		clear_startup_no_model_feedback "$selected_model"
		_cmd_run_finish "$session_key" "$completion_state" "$work_dir" || finish_status=$?
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status="$finish_status"
		;;
	85)
		_run_failure_reason="$_HRW_REASON_OWNERSHIP_LOST"
		_run_result_label="$_HRW_REASON_OWNERSHIP_LOST"
		_hrw_record_terminal_outcome "$session_key" "$_HRW_TELEMETRY_FAILED" "$_HRW_REASON_OWNERSHIP_LOST"
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL" "$work_dir"
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status=1
		;;
	87)
		_run_failure_reason="$signing_unavailable_result"
		_run_result_label="$signing_unavailable_result"
		_hrw_record_terminal_outcome "$session_key" "$_HRW_TELEMETRY_FAILED" "$signing_unavailable_result"
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status=1
		;;
	80)
		print_warning "$selected_model rate_limit_fast — API 429/overload within first ${HEADLESS_RATE_LIMIT_DETECT_SECONDS:-30}s"
		if [[ "$role" == "$_CMD_RUN_ROLE_WORKER" && -z "$model_override" && "$attempt" -lt "$max_attempts" ]]; then
			local alternate_model=""
			alternate_model=$(choose_model "$role" "" "$tier_override" "exact-tier" 2>/dev/null) || alternate_model=""
			if [[ -n "$alternate_model" && "$alternate_model" != "$selected_model" ]]; then
				selected_model="$alternate_model"
				variant_override=$(resolve_headless_variant "$role" "$tier_override" "$selected_model")
				routing_reason="same_tier_fallback"
				attempt=$((attempt + 1))
				print_warning "Retrying with same-tier candidate $selected_model"
				_cmd_run_disposition="$_CMD_RUN_DISPOSITION_CONTINUE"
				return 0
			fi
		fi
		_cmd_run_finish "$session_key" "$_run_result_label"
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status=0
		;;
	84)
		_cmd_run_finish "$session_key" "$_run_result_label" "$work_dir" || finish_status=$?
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status="$finish_status"
		;;
	83)
		local capability_blocked=0
		if [[ "${_run_result_label:-}" == "blocked" &&
			"${_run_classification_source:-}" == "model_blocked_signal" &&
			"${_run_classification_pattern:-}" == "capability_limit" ]]; then
			capability_blocked=1
		fi
		if [[ "$capability_blocked" -eq 1 && -z "$model_override" ]] &&
			_resolve_capability_escalation "$role" "$tier_override" "$selected_model" "$variant_override"; then
			# Same-tier reasoning consumes the existing route budget: availability
			# fallback may revisit a model at its default effort, never reset retries.
			if [[ "$tier_override" == "$_capability_escalation_tier" ]]; then
				attempt=$((attempt + 1))
			else
				attempt=1
				max_attempts=$(_headless_route_attempt_budget "$_capability_escalation_tier")
			fi
			tier_override="$_capability_escalation_tier"
			selected_model="$_capability_escalation_model"
			variant_override="$_capability_escalation_variant"
			routing_reason="capability_escalation"
			routing_escalated=1
			prompt="The previous attempt reported a model capability limit after working on the task. Resume the existing session and worktree at the next authorized capability tier or reasoning level (${tier_override}: ${selected_model}${variant_override:+ ${variant_override}}), challenge the blocker using the accumulated evidence, and continue autonomously through implementation and verification. Do not request broader permissions or bypass policy, authentication, trust, or secret-handling boundaries. If model capability remains the only blocker, emit the exact marker BLOCKED: capability limit - <evidence> so runtime routing can evaluate the next configured tier or reasoning level. Use generic BLOCKED only for concrete terminal non-capability blockers. Stop at FULL_LOOP_COMPLETE or a supported BLOCKED outcome."
			print_warning "$_capability_escalation_label"
			_cmd_run_disposition="$_CMD_RUN_DISPOSITION_CONTINUE"
		else
			local terminal_status="$completion_state"
			if [[ "${_run_result_label:-}" == "local_kill" ]]; then
				terminal_status="$_HRW_STATUS_FAIL"
			fi
			_cmd_run_finish "$session_key" "$terminal_status" "$work_dir" || finish_status=$?
			_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
			if [[ "$terminal_status" == "$_HRW_STATUS_FAIL" ]]; then
				_cmd_run_return_status=1
			else
				_cmd_run_return_status="$finish_status"
			fi
		fi
		;;
	esac
	return 0
}

# Handle service, premature-exit, and brief-recovery continuation budgets.
_handle_cmd_run_continuation_attempt() {
	if [[ "$attempt_exit" -eq 81 ]]; then
		if [[ "$service_interruption_continue_count" -lt "$max_service_interruption_continue_retries" ]]; then
			service_interruption_continue_count=$((service_interruption_continue_count + 1))
			routing_reason="service_interruption_retry"
			print_warning "service_interruption_continue attempt=${service_interruption_continue_count}/${max_service_interruption_continue_retries} — resuming existing session/worktree"
			prompt="A transient provider/service interruption stopped the previous run after work had begun. Resume the existing session and worktree; do not restart exploration. Check git status, existing todos, and prior changes, then continue through implementation, verification, commit, PR, merge summary, review, merge, release, closing comments, deploy, and cleanup. Do not stop until FULL_LOOP_COMPLETE or BLOCKED with evidence."
			_cmd_run_disposition="$_CMD_RUN_DISPOSITION_CONTINUE"
			return 0
		fi
		local exhausted_label="service_interruption_exhausted"
		_run_result_label="$exhausted_label"
		_append_service_interruption_exhausted_metric "$role" "$session_key" "$selected_model" "$work_dir" \
			"${_run_failure_reason:-provider_error}" "${_run_metric_output_file:-}" "${_run_metric_session_id:-}"
		local interrupted_provider="" interruption_details="${_run_metric_output_file:-/dev/null}"
		interrupted_provider=$(extract_provider "$selected_model" 2>/dev/null || true)
		[[ -f "$interruption_details" ]] || interruption_details="/dev/null"
		if [[ -n "$interrupted_provider" ]]; then
			record_provider_backoff "$interrupted_provider" "${_run_failure_reason:-provider_error}" \
				"$interruption_details" "$selected_model" || true
		fi
		print_warning "Exhausted ${max_service_interruption_continue_retries} service-interruption continuations — falling through to normal failure handling"
	fi
	if [[ "$attempt_exit" -eq 77 && "$continuation_count" -lt "$max_continuation_retries" ]]; then
		continuation_count=$((continuation_count + 1))
		routing_reason="continuation_retry"
		print_warning "Premature exit detected — sending continuation prompt (attempt ${continuation_count}/${max_continuation_retries})"
		prompt="Continue through to completion. This is a headless session — no user is present and no user input is available to assist. You have set up the environment but have not yet completed the task. Check your todo list, implement the required code changes, commit, push, and create a PR. After PR creation, you MUST post the MERGE_SUMMARY comment (full-loop step 4.2.1) — the merge pass needs it for closing comments. Then continue through review, merge, and closing comments. Do not stop until the outcome is FULL_LOOP_COMPLETE or BLOCKED with evidence."
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_CONTINUE"
		return 0
	fi
	if [[ "$attempt_exit" -eq 77 ]]; then
		_run_failure_reason="premature_exit"
		_run_result_label="premature_exit"
		print_warning "Exhausted ${max_continuation_retries} continuation retries — recording as premature_exit failure"
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status=1
		return 0
	fi
	if [[ "$attempt_exit" -eq 82 && "$brief_recovery_count" -lt "$max_brief_recovery_retries" ]]; then
		brief_recovery_count=$((brief_recovery_count + 1))
		routing_reason="brief_recovery_retry"
		print_warning "Missing implementation context detected — sending brief-recovery continuation (attempt ${brief_recovery_count}/${max_brief_recovery_retries})"
		prompt="The previous run ended with BLOCKED: missing implementation context. Before giving up, perform the GH#23225 brief-recovery routine once. Verify the linked issue number is \${WORKER_ISSUE_NUMBER}; read that issue body; keep discovery narrow using its title/body keywords, exact file search, and 2-3 likely target files/tests; then update only that linked issue body using --body-file with a Worker Guidance or How section containing Goal, files to inspect first, implementation steps, verification commands, runtime testing risk/expectation, existing reproduction context, and the aidevops signature footer. Mark in the issue body that brief recovery was attempted to avoid loops. After repairing the brief, re-run the full-loop implementation from the improved context and continue through implementation, verification, commit, PR, MERGE_SUMMARY, review, merge, closing comments, deploy, and cleanup. If narrow discovery still cannot produce concrete files and steps, emit BLOCKED: missing implementation context with evidence."
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_CONTINUE"
		return 0
	fi
	if [[ "$attempt_exit" -eq 82 ]]; then
		_run_result_label="block""ed"
		_run_failure_reason="$_run_result_label"
		_run_classification_source="model_blocked""_signal"
		_run_classification_pattern="missing_implementation_context_recovery_exhausted"
		print_warning "Missing implementation context persisted after brief-recovery continuation — recording blocked"
		_cmd_run_finish "$session_key" "$completion_state" "$work_dir"
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status=0
	fi
	return 0
}

# Handle watchdog hard kills, session caps, and bounded stall continuations.
_handle_cmd_run_watchdog_attempt() {
	if [[ "$attempt_exit" -eq 79 ]]; then
		_session_stall_count=$((_session_stall_count + 1))
		_session_stall_cumulative_s=$((_session_stall_cumulative_s + _stall_timeout_s))
		print_warning "Watchdog hard-kill — recording watchdog_stall_killed (per-attempt elapsed cap, slot freed for re-dispatch)"
		local ledger_fail="$_HRW_STATUS_FAIL"
		_cmd_run_finish "$session_key" "$ledger_fail"
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status=1
		return 0
	fi
	[[ "$attempt_exit" -eq 78 ]] || return 0
	if _worker_external_terminal_complete "$session_key" "$work_dir"; then
		print_info "[lifecycle] exit-78 continuation skipped — external terminal state already complete"
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL" "$work_dir" "1"
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status=0
		return 0
	fi
	if [[ "${_run_failure_reason:-}" == "startup_no_model_activity" ]]; then
		record_startup_no_model_feedback "$selected_model"
	fi
	_session_stall_count=$((_session_stall_count + 1))
	_session_stall_cumulative_s=$((_session_stall_cumulative_s + _stall_timeout_s))
	if _stall_session_cap_exceeded "$_session_stall_count" "$_session_stall_cumulative_s" \
		"$_stall_continue_max" "$_stall_cumulative_max_s"; then
		print_warning "Watchdog stall cap exceeded (stalls=${_session_stall_count}/${_stall_continue_max}, cumulative=${_session_stall_cumulative_s}s/${_stall_cumulative_max_s}s) — recording watchdog_stall_killed"
		local hard_kill_label="watchdog_stall_killed"
		_run_result_label="$hard_kill_label"
		_run_failure_reason="$hard_kill_label"
		append_runtime_metric "$role" "$session_key" "$selected_model" "$(extract_provider "$selected_model")" \
			"$_run_result_label" "143" "$_run_failure_reason" "1" "0"
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_RETURN"
		_cmd_run_return_status=1
		return 0
	fi
	if [[ "$watchdog_continue_count" -lt "$max_watchdog_continue_retries" ]]; then
		watchdog_continue_count=$((watchdog_continue_count + 1))
		routing_reason="watchdog_retry"
		print_warning "Watchdog stall with activity — resuming session (attempt ${watchdog_continue_count}/${max_watchdog_continue_retries}, session stalls=${_session_stall_count}/${_stall_continue_max})"
		prompt="Your previous connection dropped mid-session and the process was restarted. All your prior work (worktree, file changes, commits) is still on disk. Resume where you left off — check git status, your todo list, and continue through to completion. Do not restart from scratch. Do not stop until the outcome is FULL_LOOP_COMPLETE or BLOCKED with evidence."
		_cmd_run_disposition="$_CMD_RUN_DISPOSITION_CONTINUE"
		return 0
	fi
	print_warning "Exhausted ${max_watchdog_continue_retries} watchdog continuation retries — falling through to provider rotation (session stalls=${_session_stall_count}/${_stall_continue_max})"
	return 0
}

# Execute bounded attempts and route each result through focused policies.
_cmd_run_attempt_loop() {
	local max_continuation_retries="${HEADLESS_CONTINUATION_MAX_RETRIES:-10}" continuation_count=0
	local max_watchdog_continue_retries="${HEADLESS_WATCHDOG_CONTINUE_MAX_RETRIES:-2}" watchdog_continue_count=0
	local max_service_interruption_continue_retries="${HEADLESS_SERVICE_INTERRUPTION_CONTINUE_MAX_RETRIES:-2}" service_interruption_continue_count=0
	local max_brief_recovery_retries="${HEADLESS_BRIEF_RECOVERY_MAX_RETRIES:-1}" brief_recovery_count=0
	if _headless_run_is_ephemeral "$role"; then
		max_continuation_retries=0 max_watchdog_continue_retries=0
		max_service_interruption_continue_retries=0 max_brief_recovery_retries=0
	fi
	local _stall_timeout_s="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-600}"
	[[ "$_stall_timeout_s" =~ ^[0-9]+$ ]] || _stall_timeout_s=600
	local _stall_continue_max="${WORKER_STALL_CONTINUE_MAX:-3}"
	[[ "$_stall_continue_max" =~ ^[0-9]+$ ]] || _stall_continue_max=3
	local _stall_cumulative_max_s="${WORKER_STALL_CUMULATIVE_MAX_S:-1800}"
	[[ "$_stall_cumulative_max_s" =~ ^[0-9]+$ ]] || _stall_cumulative_max_s=1800
	local _session_stall_count=0 _session_stall_cumulative_s=0
	local attempt=1 max_attempts=3
	if _headless_run_is_ephemeral "$role"; then
		max_attempts=1
	else
		max_attempts=$(_headless_route_attempt_budget "$tier_override")
	fi
	local cmd_run_action="retry" cmd_run_next_model="$selected_model"
	local _run_failure_reason="" _run_should_retry=0 _run_result_label="failed" _run_activity_detected="0"
	local _run_metric_output_file="" _run_metric_session_id="" completion_state="complete"
	local _cmd_run_disposition="" _cmd_run_return_status=1
	local routing_attempt=0 routing_reason="headless_dispatch" routing_escalated=0 routing_candidate_index=-1
	while [[ "$attempt" -le "$max_attempts" ]]; do
		routing_attempt=$((routing_attempt + 1))
		routing_candidate_index=$(model_tier_candidate_index "$tier_override" "$selected_model" 2>/dev/null) || routing_candidate_index=-1
		export AIDEVOPS_DISPATCH_TIER="$tier_override"
		export AIDEVOPS_ROUTING_CANDIDATE_INDEX="$routing_candidate_index"
		export AIDEVOPS_ROUTING_ATTEMPT="$routing_attempt"
		export AIDEVOPS_ROUTING_REASON="$routing_reason"
		export AIDEVOPS_ROUTING_ESCALATED="$routing_escalated"
		export AIDEVOPS_ROUTING_VARIANT="$variant_override"
		_run_failure_reason="" _run_should_retry=0 _run_result_label="failed" _run_activity_detected="0"
		local attempt_exit=0
		if _execute_run_attempt "$role" "$session_key" "$work_dir" "$title" "$prompt" \
			"$selected_model" "$variant_override" "$agent_name" "${extra_args[@]+"${extra_args[@]}"}"; then
			attempt_exit=0
		else
			attempt_exit=$?
		fi
		_cmd_run_disposition=""
		_handle_cmd_run_terminal_attempt
		case "$_cmd_run_disposition" in "$_CMD_RUN_DISPOSITION_RETURN") return "$_cmd_run_return_status" ;; "$_CMD_RUN_DISPOSITION_CONTINUE") continue ;; esac
		_handle_cmd_run_continuation_attempt
		case "$_cmd_run_disposition" in "$_CMD_RUN_DISPOSITION_RETURN") return "$_cmd_run_return_status" ;; "$_CMD_RUN_DISPOSITION_CONTINUE") continue ;; esac
		_handle_cmd_run_watchdog_attempt
		case "$_cmd_run_disposition" in "$_CMD_RUN_DISPOSITION_RETURN") return "$_cmd_run_return_status" ;; "$_CMD_RUN_DISPOSITION_CONTINUE") continue ;; esac
		_cmd_run_prepare_retry "$role" "$session_key" "$model_override" "$attempt" \
			"$max_attempts" "$selected_model" "$attempt_exit" "$tier_override" || return $?
		if [[ "$cmd_run_action" == "switch" ]]; then
			selected_model="$cmd_run_next_model"
			variant_override=$(resolve_headless_variant "$role" "$tier_override" "$selected_model")
			routing_reason="same_tier_fallback"
		else
			routing_reason="retry"
		fi
		attempt=$((attempt + 1))
	done
	_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
	return 1
}
