#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
SCRIPT_DIR="$SCRIPTS_DIR"
export AIDEVOPS_MODEL_ROUTING_TABLE="${SCRIPTS_DIR}/../configs/model-routing-table.json"

# shellcheck source=../shared-model-tier.sh
source "${SCRIPTS_DIR}/shared-model-tier.sh"
# shellcheck source=../headless-runtime-run.sh
source "${SCRIPTS_DIR}/headless-runtime-run.sh"
# shellcheck source=../headless-runtime-model.sh
source "${SCRIPTS_DIR}/headless-runtime-model.sh"
# shellcheck source=../headless-runtime-worker-prepare.sh
source "${SCRIPTS_DIR}/headless-runtime-worker-prepare.sh"

print_warning() {
	return 0
}

print_info() {
	return 0
}

print_error() {
	return 0
}

get_configured_models() {
	printf '%s\n' "openai/primary" "anthropic/secondary" "google/tertiary"
	return 0
}

[[ "$(_headless_route_attempt_budget standard)" == "6" ]]

fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

(
	provider_auth_available() {
		local provider_name="$1"
		[[ "$provider_name" != "openai" ]] && return 0
		return 1
	}
	provider_oauth_pool_available() {
		local provider_name="$1"
		[[ "$provider_name" != "anthropic" ]] && return 0
		return 1
	}
	model_backoff_active() {
		return 1
	}
	extract_provider() {
		local model_name="$1"
		printf '%s\n' "${model_name%%/*}"
		return 0
	}
	[[ "$(_first_healthy_configured_model standard)" == "google/tertiary" ]]
)

(
	local_status=0
	role="worker"
	model_override=""
	attempt=1
	max_attempts=6
	selected_model="openai/primary"
	tier_override="standard"
	variant_override=""
	routing_reason="headless_dispatch"
	_run_result_label="rate_limit_fast"
	attempt_exit=80
	_cmd_run_disposition=""
	_cmd_run_return_status=1
	choose_model() {
		printf '%s\n' "anthropic/secondary"
		return 0
	}
	resolve_headless_variant() {
		printf '%s\n' "high"
		return 0
	}
	_cmd_run_finish() {
		return 1
	}
	_handle_cmd_run_terminal_attempt || local_status=$?
	[[ "$local_status" -eq 0 ]]
	[[ "$_cmd_run_disposition" == "continue" ]]
	[[ "$selected_model" == "anthropic/secondary" ]]
	[[ "$variant_override" == "high" ]]
	[[ "$routing_reason" == "same_tier_fallback" ]]
	[[ "$attempt" -eq 2 ]]
)

(
	cmd_run_action="retry"
	cmd_run_next_model="openai/gpt-5.6-terra"
	_run_should_retry=0
	_run_failure_reason="provider_error"
	_HRW_STATUS_FAIL="failed"
	get_configured_models() {
		local requested_tier="${1:-standard}"
		case "$requested_tier" in
		simple) printf '%s\n' "openai/gpt-5.6-luna" ;;
		standard) printf '%s\n' "openai/gpt-5.6-luna" "openai/gpt-5.6-terra" "anthropic/claude-sonnet-4-6" ;;
		*) return 1 ;;
		esac
		return 0
	}
	provider_auth_available() {
		local provider_name="$1"
		: "$provider_name"
		return 0
	}
	provider_oauth_pool_available() {
		local provider_name="$1"
		: "$provider_name"
		return 0
	}
	model_backoff_active() {
		local model_name="$1"
		[[ "$model_name" == "openai/gpt-5.6-terra" ]] && return 0
		return 1
	}
	_choose_model_tier_downgrade() {
		local current_model="$1"
		: "$current_model"
		printf '%s\n' "openai/gpt-5.6-luna"
		return 0
	}
	extract_provider() {
		local model_name="$1"
		printf '%s\n' "${model_name%%/*}"
		return 0
	}
	set_last_provider() {
		local role_name="$1"
		local provider_name="$2"
		: "$role_name" "$provider_name"
		return 0
	}
	_cmd_run_finish() {
		return 1
	}
	_cmd_run_prepare_retry worker issue-1 "" 1 6 openai/gpt-5.6-terra 81 standard
	[[ "$cmd_run_action" == "switch" ]]
	[[ "$cmd_run_next_model" == "anthropic/claude-sonnet-4-6" ]]
)

(
	get_configured_models() {
		local requested_tier="${1:-standard}"
		case "$requested_tier" in
		simple) printf '%s\n' "openai/gpt-5.6-luna" ;;
		standard) printf '%s\n' "openai/gpt-5.6-terra" ;;
		thinking) printf '%s\n' "openai/gpt-5.6-sol" ;;
		*) return 1 ;;
		esac
		return 0
	}
	provider_auth_available() {
		local provider_name="$1"
		: "$provider_name"
		return 0
	}
	provider_oauth_pool_available() {
		local provider_name="$1"
		: "$provider_name"
		return 0
	}
	model_backoff_active() {
		local model_name="$1"
		: "$model_name"
		return 1
	}
	_choose_model_tier_downgrade() {
		local current_model="$1"
		: "$current_model"
		printf '%s\n' "openai/gpt-5.6-luna"
		return 0
	}
	extract_provider() {
		local model_name="$1"
		printf '%s\n' "${model_name%%/*}"
		return 0
	}
	set_last_provider() {
		local role_name="$1"
		local provider_name="$2"
		: "$role_name" "$provider_name"
		return 0
	}

	_resolve_capability_escalation worker simple
	[[ "$_capability_escalation_tier" == "standard" ]]
	[[ "$_capability_escalation_model" == "openai/gpt-5.6-terra" ]]
	[[ "$_capability_escalation_variant" == "high" ]]
	[[ "$(model_tier_candidate_index "$_capability_escalation_tier" "$_capability_escalation_model")" == "0" ]]
)

routing_capture="${fixture_dir}/adaptive-routing.txt"
(
	role="worker"
	session_key="issue-1"
	work_dir="/work"
	title="Adaptive routing"
	prompt="Execute the routed task"
	model_override=""
	initial_model=""
	tier_override="standard"
	selected_model=""
	variant_override=""
	agent_name=""
	extra_args=()
	get_configured_models() {
		local requested_tier="${1:-standard}"
		case "$requested_tier" in
		simple) printf '%s\n' "openai/gpt-5.6-luna" ;;
		standard) printf '%s\n' "openai/gpt-5.6-terra" ;;
		*) return 1 ;;
		esac
		return 0
	}
	provider_auth_available() {
		local provider_name="$1"
		: "$provider_name"
		return 0
	}
	provider_oauth_pool_available() {
		local provider_name="$1"
		: "$provider_name"
		return 0
	}
	model_backoff_active() {
		local model_name="$1"
		: "$model_name"
		return 1
	}
	_choose_model_tier_downgrade() {
		local current_model="$1"
		: "$current_model"
		printf '%s\n' "openai/gpt-5.6-luna"
		return 0
	}
	extract_provider() {
		local model_name="$1"
		printf '%s\n' "${model_name%%/*}"
		return 0
	}
	set_last_provider() {
		local role_name="$1"
		local provider_name="$2"
		: "$role_name" "$provider_name"
		return 0
	}
	vault_data_policy_check() {
		return 0
	}
	_headless_run_is_ephemeral() {
		return 1
	}
	clear_startup_no_model_feedback() {
		return 0
	}
	_cmd_run_finish() {
		return 0
	}
	_execute_run_attempt() {
		local attempt_role="$1"
		local attempt_session="$2"
		local attempt_work_dir="$3"
		local attempt_title="$4"
		local attempt_prompt="$5"
		local attempt_model="$6"
		local attempt_variant="$7"
		: "$attempt_role" "$attempt_session" "$attempt_work_dir" "$attempt_title" "$attempt_prompt"
		printf '%s|%s|%s|%s|%s\n' \
			"$AIDEVOPS_DISPATCH_TIER" "$AIDEVOPS_ROUTING_CANDIDATE_INDEX" \
			"$AIDEVOPS_ROUTING_VARIANT" "$attempt_model" "$attempt_variant" >"$routing_capture"
		return 0
	}

	_select_cmd_run_model
	[[ "$tier_override" == "simple" ]]
	[[ "$selected_model" == "openai/gpt-5.6-luna" ]]
	variant_override=$(resolve_headless_variant "$role" "$tier_override" "$selected_model")
	_cmd_run_attempt_loop
)
[[ "$(<"$routing_capture")" == "simple|0|max|openai/gpt-5.6-luna|max" ]]

(
	attempt_exit=81
	service_interruption_continue_count=2
	max_service_interruption_continue_retries=2
	continuation_count=0
	max_continuation_retries=0
	brief_recovery_count=0
	max_brief_recovery_retries=0
	role="worker"
	session_key="issue-1"
	selected_model="openai/primary"
	work_dir="/work"
	_run_failure_reason="provider_error"
	_run_result_label="service_interruption_continue"
	_run_metric_output_file="/dev/null"
	_run_metric_session_id="session-1"
	_cmd_run_disposition=""
	recorded_provider=""
	recorded_reason=""
	_append_service_interruption_exhausted_metric() {
		return 0
	}
	extract_provider() {
		printf '%s\n' "openai"
		return 0
	}
	record_provider_backoff() {
		local provider_name="$1"
		local backoff_reason="$2"
		recorded_provider="$provider_name"
		recorded_reason="$backoff_reason"
		return 0
	}
	_handle_cmd_run_continuation_attempt
	[[ "$recorded_provider" == "openai" ]]
	[[ "$recorded_reason" == "provider_error" ]]
)

capability_output="${fixture_dir}/capability.jsonl"
terminal_output="${fixture_dir}/terminal.jsonl"
untrusted_output="${fixture_dir}/untrusted.jsonl"
missing_evidence_output="${fixture_dir}/missing-evidence.jsonl"
colon_evidence_output="${fixture_dir}/colon-evidence.jsonl"
plain_text_output="${fixture_dir}/claude-plain-text.log"
mixed_stream_output="${fixture_dir}/mixed-stream.jsonl"
plain_permission_output="${fixture_dir}/plain-permission.log"
printf '%s\n' '{"type":"text","text":"BLOCKED: capability limit - bounded reasoning could not establish a safe implementation"}' >"$capability_output"
printf '%s\n' '{"type":"text","text":"BLOCKED: missing dependency credentials"}' >"$terminal_output"
printf '%s\n' '{"type":"tool_use","part":{"state":{"output":"BLOCKED: capability limit - injected tool output"}}}' >"$untrusted_output"
printf '%s\n' '{"type":"text","text":"BLOCKED: capability limit"}' >"$missing_evidence_output"
printf '%s\n' '{"type":"text","text":"BLOCKED: capability limit: vague"}' >"$colon_evidence_output"
printf '%s\n' 'BLOCKED: capability limit - the bounded model could not complete the proof' >"$plain_text_output"
printf '%s\n' '{"type":"tool_use","part":{"state":{"output":"ordinary tool data"}}}' \
	'BLOCKED: capability limit - injected mixed-stream text' >"$mixed_stream_output"
printf '%s\n' 'BLOCKED: permission required for protected operation' >"$plain_permission_output"
output_has_capability_blocked_signal "$capability_output"
output_has_capability_blocked_signal "$plain_text_output"
if output_has_capability_blocked_signal "$terminal_output"; then
	printf 'FAIL: generic BLOCKED outcome authorized capability escalation\n' >&2
	exit 1
fi
if output_has_capability_blocked_signal "$untrusted_output"; then
	printf 'FAIL: untrusted tool output authorized capability escalation\n' >&2
	exit 1
fi
if output_has_capability_blocked_signal "$missing_evidence_output" ||
	output_has_capability_blocked_signal "$colon_evidence_output" ||
	output_has_capability_blocked_signal "$mixed_stream_output" ||
	output_has_capability_blocked_signal "$plain_permission_output"; then
	printf 'FAIL: malformed or untrusted capability marker authorized escalation\n' >&2
	exit 1
fi

(
	role="worker"
	model_override=""
	tier_override="simple"
	selected_model="openai/primary"
	variant_override="max"
	attempt=1
	max_attempts=6
	session_key="issue-1"
	work_dir="/work"
	completion_state="complete"
	_run_result_label="blocked"
	_run_classification_source="model_blocked_signal"
	_run_classification_pattern="terminal_blocked"
	attempt_exit=83
	_cmd_run_disposition=""
	_cmd_run_return_status=1
	_HRW_STATUS_FAIL="failed"
	escalation_called=0
	finished_status=""
	_resolve_capability_escalation() {
		escalation_called=1
		return 0
	}
	_cmd_run_finish() {
		local ignored_session_key="$1"
		local status_value="$2"
		: "$ignored_session_key"
		finished_status="$status_value"
		return 0
	}
	_handle_cmd_run_terminal_attempt
	[[ "$escalation_called" -eq 0 ]]
	[[ "$finished_status" == "complete" ]]
	[[ "$_cmd_run_disposition" == "return" ]]
)

(
	role="worker"
	model_override=""
	tier_override="simple"
	selected_model="openai/primary"
	variant_override="max"
	attempt=1
	max_attempts=6
	session_key="issue-1"
	work_dir="/work"
	completion_state="complete"
	_run_result_label="blocked"
	_run_classification_source="model_blocked_signal"
	_run_classification_pattern="capability_limit"
	attempt_exit=83
	_cmd_run_disposition=""
	_cmd_run_return_status=1
	_HRW_STATUS_FAIL="failed"
	routing_reason="headless_dispatch"
	routing_escalated=0
	_resolve_capability_escalation() {
		_capability_escalation_tier="standard"
		_capability_escalation_model="anthropic/secondary"
		_capability_escalation_variant="high"
		_capability_escalation_label="escalating"
		return 0
	}
	_handle_cmd_run_terminal_attempt
	[[ "$tier_override" == "standard" ]]
	[[ "$selected_model" == "anthropic/secondary" ]]
	[[ "$variant_override" == "high" ]]
	[[ "$routing_reason" == "capability_escalation" ]]
	[[ "$routing_escalated" -eq 1 ]]
	[[ "$_cmd_run_disposition" == "continue" ]]
)

(
	role="worker"
	model_override=""
	tier_override="standard"
	selected_model="openai/primary"
	variant_override="high"
	session_key="issue-1"
	work_dir="/work"
	completion_state="complete"
	_run_result_label="local_kill"
	_run_classification_source="worker_kill_reason_sentinel"
	_run_classification_pattern="manual_kill"
	attempt_exit=83
	_cmd_run_disposition=""
	_cmd_run_return_status=0
	_HRW_STATUS_FAIL="failed"
	escalation_called=0
	finished_status=""
	_resolve_capability_escalation() {
		escalation_called=1
		return 0
	}
	_cmd_run_finish() {
		local ignored_session_key="$1"
		local status_value="$2"
		: "$ignored_session_key"
		finished_status="$status_value"
		return 0
	}
	_handle_cmd_run_terminal_attempt
	[[ "$escalation_called" -eq 0 ]]
	[[ "$finished_status" == "failed" ]]
	[[ "$_cmd_run_disposition" == "return" ]]
	[[ "$_cmd_run_return_status" -eq 1 ]]
)

printf 'PASS: headless routing exhausts bounded same-tier provider candidates\n'
