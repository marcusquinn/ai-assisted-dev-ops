#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Provider classification, canary, sandbox, and credential-scope tests.

# This file is sourced by test-headless-runtime-helper.sh after the shared test
# harness and headless runtime helper have been initialized.
[[ -n "${_TEST_HEADLESS_RUNTIME_PROVIDER_TESTS_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_PROVIDER_TESTS_LOADED=1

test_does_not_double_append() {
	local prompt='/full-loop Continue issue #14964

[HEADLESS_CONTINUATION_CONTRACT_V9]
This worker run is unattended.'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "does not double-append existing contract" 0
		return 0
	fi

	print_result "does not double-append existing contract" 1 "Existing contract was modified"
	return 0
}

test_extract_session_id_from_output_returns_latest_session_id() {
	local output_file="${TEST_ROOT}/opencode-output.jsonl"
	cat >"$output_file" <<'EOF'
not-json
{"type":"message","sessionID":"ses_early"}
{"type":"tool_use","part":{"sessionID":"ses_latest"}}
EOF

	local session_id
	session_id=$(extract_session_id_from_output "$output_file")
	if [[ "$session_id" == "ses_latest" ]]; then
		print_result "extract_session_id_from_output returns latest session id" 0
		return 0
	fi
	print_result "extract_session_id_from_output returns latest session id" 1 "Expected ses_latest, got ${session_id:-<empty>}"
	return 0
}

test_provider_sessions_scope_issue_keys_by_repo_slug() {
	local provider="openai"
	local model="openai/gpt-5.5"
	local old_repo_slug="${WORKER_REPO_SLUG:-}"
	export WORKER_REPO_SLUG="owner/one"
	store_session_id "$provider" "issue-47" "ses_one" "$model"
	export WORKER_REPO_SLUG="Owner/Two"
	store_session_id "$provider" "issue-47" "ses_two" "$model"

	local first_session="" second_session="" unscoped_count=""
	export WORKER_REPO_SLUG="owner/one"
	first_session=$(get_session_id "$provider" "issue-47")
	export WORKER_REPO_SLUG="owner/two"
	second_session=$(get_session_id "$provider" "issue-47")
	unscoped_count=$(db_query "SELECT count(*) FROM provider_sessions WHERE provider = 'openai' AND session_key = 'issue-47';")
	if [[ -n "$old_repo_slug" ]]; then
		export WORKER_REPO_SLUG="$old_repo_slug"
	else
		unset WORKER_REPO_SLUG
	fi

	if [[ "$first_session" == "ses_one" && "$second_session" == "ses_two" && "$unscoped_count" == "0" ]]; then
		print_result "provider_sessions scope issue keys by repo slug" 0
		return 0
	fi

	print_result "provider_sessions scope issue keys by repo slug" 1 \
		"first=${first_session:-<empty>} second=${second_session:-<empty>} unscoped_count=${unscoped_count:-<empty>}"
	return 0
}

test_provider_sessions_keep_pulse_unscoped() {
	local provider="openai"
	local model="openai/gpt-5.5"
	local old_repo_slug="${WORKER_REPO_SLUG:-}"
	export WORKER_REPO_SLUG="owner/one"
	store_session_id "$provider" "pulse" "ses_pulse" "$model"
	local pulse_session="" pulse_count=""
	pulse_session=$(get_session_id "$provider" "pulse")
	pulse_count=$(db_query "SELECT count(*) FROM provider_sessions WHERE provider = 'openai' AND session_key = 'pulse';")
	if [[ -n "$old_repo_slug" ]]; then
		export WORKER_REPO_SLUG="$old_repo_slug"
	else
		unset WORKER_REPO_SLUG
	fi

	if [[ "$pulse_session" == "ses_pulse" && "$pulse_count" == "1" ]]; then
		print_result "provider_sessions keep pulse sessions unscoped" 0
		return 0
	fi

	print_result "provider_sessions keep pulse sessions unscoped" 1 \
		"pulse=${pulse_session:-<empty>} count=${pulse_count:-<empty>}"
	return 0
}

test_blocked_completion_records_blocked_label() {
	local output_file="${TEST_ROOT}/blocked-output.jsonl"
	printf '%s\n' '{"type":"text","sessionID":"ses_blocked","text":"BLOCKED: missing dependency credentials"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	[[ "$rc" -eq 83 && "${_run_result_label:-}" == "blocked" && "${_run_failure_reason:-}" == "blocked" && "${_run_classification_source:-}" == "model_blocked_signal" && "${_run_classification_pattern:-}" == "terminal_blocked" ]] && {
		print_result "generic BLOCKED signal remains terminal without capability escalation" 0
		return 0
	}
	print_result "generic BLOCKED signal remains terminal without capability escalation" 1 \
		"rc=$rc label=${_run_result_label:-<unset>} reason=${_run_failure_reason:-<unset>} source=${_run_classification_source:-<unset>} pattern=${_run_classification_pattern:-<unset>}"
	return 0
}

test_capability_escalation_ladder_is_bounded_and_exact() {
	local result=0
	local route_output=""
	local route_output_file="${TEST_ROOT}/capability-escalation-route-output.txt"
	local _capability_escalation_tier=""
	local _capability_escalation_model=""
	local _capability_escalation_variant=""
	local _capability_escalation_label=""
	(
		model_tier_next() {
			local current_tier="$1"
			case "$current_tier" in
			simple) printf '%s\n' "standard" ;;
			standard) printf '%s\n' "thinking" ;;
			*) return 1 ;;
			esac
			return 0
		}
		choose_model() {
			local role_name="$1"
			local explicit_model="$2"
			local tier_name="$3"
			: "$role_name" "$explicit_model"
			case "$tier_name" in
			standard) printf '%s\n' "openai/gpt-5.6-terra" ;;
			thinking) printf '%s\n' "openai/gpt-5.6-sol" ;;
			*) return 1 ;;
			esac
			return 0
		}
		resolve_headless_variant() {
			local role_name="$1"
			local tier_name="$2"
			local model_name="$3"
			: "$role_name" "$model_name"
			case "$tier_name" in
			standard) printf '%s\n' "high" ;;
			thinking) printf '%s\n' "medium" ;;
			*) return 1 ;;
			esac
			return 0
		}
		_resolve_capability_escalation "worker" "simple" || exit 1
		printf '%s|%s|%s\n' "$_capability_escalation_tier" "$_capability_escalation_model" "$_capability_escalation_variant"
		_resolve_capability_escalation "worker" "standard" || exit 1
		printf '%s|%s|%s\n' "$_capability_escalation_tier" "$_capability_escalation_model" "$_capability_escalation_variant"
		if _resolve_capability_escalation "worker" "thinking" ||
			_resolve_capability_escalation "pulse" "simple"; then
			exit 1
		fi
	) >"$route_output_file" || result=1
	[[ -f "$route_output_file" ]] && route_output=$(<"$route_output_file")
	local expected_output=$'standard|openai/gpt-5.6-terra|high\nthinking|openai/gpt-5.6-sol|medium'
	[[ "$route_output" == "$expected_output" ]] || result=1
	print_result "Capability escalation follows the bounded configured tier order" "$result"
	return 0
}

test_post_pr_handoff_completion_signal_is_exact() {
	local exact_file="${TEST_ROOT}/post-pr-handoff-exact.jsonl"
	local prose_file="${TEST_ROOT}/post-pr-handoff-prose.jsonl"
	printf '%s\n' '{"type":"text","text":"POST_PR_HANDOFF"}' >"$exact_file"
	printf '%s\n' '{"type":"text","text":"I will mention POST_PR_HANDOFF after more work."}' >"$prose_file"

	local result=0
	output_has_post_pr_handoff_signal "$exact_file" || result=1
	output_has_completion_signal "$exact_file" || result=1
	if output_has_post_pr_handoff_signal "$prose_file" || output_has_completion_signal "$prose_file"; then
		result=1
	fi
	print_result "POST_PR_HANDOFF is accepted only as an exact model-text line" "$result"
	return 0
}

test_post_pr_handoff_records_distinct_result_label() {
	local output_file="${TEST_ROOT}/post-pr-handoff-result.jsonl"
	printf '%s\n' '{"type":"text","sessionID":"ses_handoff","text":"POST_PR_HANDOFF"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	if [[ "$rc" -eq 0 && "${_run_result_label:-}" == "post_pr_handoff" ]]; then
		print_result "POST_PR_HANDOFF remains distinct from raw process success" 0
		return 0
	fi
	print_result "POST_PR_HANDOFF remains distinct from raw process success" 1 \
		"rc=${rc} label=${_run_result_label:-<unset>}"
	return 0
}

test_missing_context_blocked_requests_brief_recovery() {
	local output_file="${TEST_ROOT}/missing-context-blocked-output.jsonl"
	printf '%s\n' '{"type":"text","sessionID":"ses_blocked","text":"BLOCKED: missing implementation context"}' >"$output_file"
	local rc=0
	_handle_run_result 0 "$output_file" "worker" "openai" "issue-456" "openai/gpt-5.5" || rc=$?
	[[ "$rc" -eq 82 && "${_run_result_label:-}" == "brief_recovery" && "${_run_failure_reason:-}" == "missing_implementation_context" && "${_run_classification_pattern:-}" == "missing_implementation_context" ]] && {
		print_result "missing-context BLOCKED requests brief recovery" 0
		return 0
	}
	print_result "missing-context BLOCKED requests brief recovery" 1 \
		"rc=$rc label=${_run_result_label:-<unset>} reason=${_run_failure_reason:-<unset>} pattern=${_run_classification_pattern:-<unset>}"
	return 0
}

test_headless_activity_timeout_default_matches_watchdog() {
	local expected="600"
	local actual="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-}"

	if [[ "$actual" == "$expected" ]]; then
		print_result "HEADLESS_ACTIVITY_TIMEOUT_SECONDS default matches watchdog default" 0
		return 0
	fi

	print_result "HEADLESS_ACTIVITY_TIMEOUT_SECONDS default matches watchdog default" 1 \
		"Expected ${expected}s to avoid GPT-5.x no-output false kills; got '${actual:-<unset>}'"
	return 0
}

test_headless_sandbox_timeout_budget() {
	local explicit_timeout=""
	local capped_timeout=""
	local invalid_timeout=""
	explicit_timeout=$(
		AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT=14400 \
			bash -c 'source "$1" help >/dev/null 2>&1; printf "%s" "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT"' _ "$HELPER_SCRIPT"
	)
	capped_timeout=$(
		AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT=86400 \
			bash -c 'source "$1" help >/dev/null 2>&1; printf "%s" "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT"' _ "$HELPER_SCRIPT"
	)
	invalid_timeout=$(
		AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT=invalid \
			bash -c 'source "$1" help >/dev/null 2>&1; printf "%s" "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT"' _ "$HELPER_SCRIPT"
	)

	if [[ "$HEADLESS_SANDBOX_TIMEOUT_BASE_DEFAULT" == "10800" &&
		"$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" == "10800" &&
		"$HEADLESS_SANDBOX_TIMEOUT_MAX" == "21600" &&
		"$explicit_timeout" == "14400" &&
		"$capped_timeout" == "21600" &&
		"$invalid_timeout" == "10800" ]]; then
		print_result "headless sandbox timeout exceeds checkpoint budget and remains bounded" 0
		return 0
	fi

	print_result "headless sandbox timeout exceeds checkpoint budget and remains bounded" 1 \
		"base=$HEADLESS_SANDBOX_TIMEOUT_BASE_DEFAULT resolved=$HEADLESS_SANDBOX_TIMEOUT_DEFAULT max=$HEADLESS_SANDBOX_TIMEOUT_MAX explicit=$explicit_timeout capped=$capped_timeout invalid=$invalid_timeout"
	return 0
}

test_public_triage_egress_mode_is_capability_aware() {
	local absent_mode=""
	local configured_mode=""
	local required_mode=""
	local off_mode=""
	local invalid_status=0

	absent_mode=$(_resolve_public_triage_egress_mode "auto" "")
	configured_mode=$(_resolve_public_triage_egress_mode "auto" "/configured/backend")
	required_mode=$(_resolve_public_triage_egress_mode "required" "")
	off_mode=$(_resolve_public_triage_egress_mode "off" "")
	_resolve_public_triage_egress_mode "invalid" "" >/dev/null 2>&1 || invalid_status=$?

	if [[ "$absent_mode" == "auto" && "$configured_mode" == "required" &&
		"$required_mode" == "required" && "$off_mode" == "auto" &&
		"$invalid_status" -ne 0 ]]; then
		print_result "public triage egress is capability-aware and cannot be disabled" 0
		return 0
	fi

	print_result "public triage egress is capability-aware and cannot be disabled" 1 \
		"absent=$absent_mode configured=$configured_mode required=$required_mode off=$off_mode invalid=$invalid_status"
	return 0
}

test_public_triage_always_requires_isolated_sandbox() {
	local failures=0

	_headless_opencode_sandbox_required "triage" "0" "auto" || failures=$((failures + 1))
	_headless_opencode_sandbox_required "worker" "0" "required" || failures=$((failures + 1))
	_headless_opencode_sandbox_required "worker" "1" "auto" || failures=$((failures + 1))
	if _headless_opencode_sandbox_required "worker" "0" "auto"; then
		failures=$((failures + 1))
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "public triage retains the mandatory isolated sandbox" 0
		return 0
	fi

	print_result "public triage retains the mandatory isolated sandbox" 1 \
		"sandbox policy mismatches=${failures}"
	return 0
}

test_claude_bare_paths_use_resolved_sandbox_timeout() {
	local timeout_log="${TEST_ROOT}/claude-bare-timeout.log"
	local direct_output="${TEST_ROOT}/claude-bare-direct.out"
	local direct_exit="${TEST_ROOT}/claude-bare-direct.exit"
	local stdin_output="${TEST_ROOT}/claude-bare-stdin.out"
	local stdin_exit="${TEST_ROOT}/claude-bare-stdin.exit"
	local stdin_file="${TEST_ROOT}/claude-bare.stdin"
	local AIDEVOPS_HEADLESS_SANDBOX_DISABLED="1"
	local AIDEVOPS_WORKER_EGRESS_MODE="off"

	timeout() {
		local timeout_seconds="$1"
		shift
		printf '%s\n' "$timeout_seconds" >>"$timeout_log"
		"$@"
		return $?
	}

	_HEADLESS_CLAUDE_STDIN_FILE=""
	_invoke_claude "$direct_output" "$direct_exit" "" bash -c 'printf "direct-output\n"' >/dev/null 2>&1
	printf 'stdin-output\n' >"$stdin_file"
	_HEADLESS_CLAUDE_STDIN_FILE="$stdin_file"
	# shellcheck disable=SC2016 # The nested bash expands $line after reading stdin.
	_invoke_claude "$stdin_output" "$stdin_exit" "" bash -c 'IFS= read -r line; printf "%s\n" "$line"' >/dev/null 2>&1

	local timeout_values=""
	local direct_status=""
	local stdin_status=""
	local direct_value=""
	local stdin_value=""
	timeout_values=$(<"$timeout_log")
	direct_status=$(<"$direct_exit")
	stdin_status=$(<"$stdin_exit")
	direct_value=$(<"$direct_output")
	stdin_value=$(<"$stdin_output")
	unset -f timeout
	unset _HEADLESS_CLAUDE_STDIN_FILE

	if [[ "$timeout_values" == $'10800\n10800' &&
		"$direct_status" == "0" && "$stdin_status" == "0" &&
		"$direct_value" == "direct-output" && "$stdin_value" == "stdin-output" ]]; then
		print_result "Claude bare execution paths use the resolved headless timeout" 0
		return 0
	fi

	print_result "Claude bare execution paths use the resolved headless timeout" 1 \
		"timeouts=${timeout_values//$'\n'/,} direct_status=$direct_status stdin_status=$stdin_status direct=$direct_value stdin=$stdin_value"
	return 0
}

test_activity_watchdog_classifiers_detect_rate_limit_and_ci_wait() {
	local output_file="${TEST_ROOT}/activity-classifier.out"

	printf 'OpenAI error: HTTP 429 rate limit exceeded\n' >"$output_file"
	if _activity_output_has_provider_rate_limit "$output_file"; then
		print_result "activity watchdog detects provider rate-limit marker" 0
	else
		print_result "activity watchdog detects provider rate-limit marker" 1
	fi

	printf 'waiting for CI checks to finish before merge\n' >"$output_file"
	if _activity_output_has_ci_wait "$output_file"; then
		print_result "activity watchdog detects CI-wait marker" 0
	else
		print_result "activity watchdog detects CI-wait marker" 1
	fi

	return 0
}

test_failure_classifier_records_provenance() {
	local output_file="${TEST_ROOT}/failure-classifier.out"
	local reason_file="${TEST_ROOT}/failure-classifier.reason"
	printf 'Provider returned HTTP 429: Too Many Requests\n' >"$output_file"

	local reason
	classify_failure_reason "$output_file" >"$reason_file"
	reason=$(<"$reason_file")

	if [[ "$reason" == "rate_limit" ]] &&
		[[ "${_failure_provider_error_type:-}" == "rate_limit" ]] &&
		[[ "${_failure_provider_status:-}" == "429" ]] &&
		[[ "${_failure_classification_source:-}" == "trusted_provider" ]] &&
		[[ "${_failure_classification_pattern:-}" == *"too_many_requests"* ]]; then
		print_result "failure classifier records provider provenance" 0
		return 0
	fi

	print_result "failure classifier records provider provenance" 1 \
		"reason=$reason type=${_failure_provider_error_type:-} status=${_failure_provider_status:-} source=${_failure_classification_source:-} pattern=${_failure_classification_pattern:-}"
	return 0
}

test_failure_classifier_distinguishes_quota_exhaustion() {
	local output_file="${TEST_ROOT}/failure-classifier-quota.out"
	local reason_file="${TEST_ROOT}/failure-classifier-quota.reason"
	printf 'OpenAI provider error HTTP 429: {"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}}\n' >"$output_file"

	local reason
	classify_failure_reason "$output_file" >"$reason_file"
	reason=$(<"$reason_file")

	if [[ "$reason" == "quota_exceeded" ]] &&
		[[ "${_failure_provider_error_type:-}" == "quota_exceeded" ]] &&
		[[ "${_failure_provider_status:-}" == "429" ]] &&
		[[ "${_failure_classification_source:-}" == "trusted_provider" ]]; then
		print_result "failure classifier distinguishes OpenAI quota exhaustion" 0
		return 0
	fi

	print_result "failure classifier distinguishes OpenAI quota exhaustion" 1 \
		"reason=$reason type=${_failure_provider_error_type:-} status=${_failure_provider_status:-} source=${_failure_classification_source:-} pattern=${_failure_classification_pattern:-}"
	return 0
}

test_failure_classifier_distinguishes_anthropic_credit_exhaustion() {
	local output_file="${TEST_ROOT}/failure-classifier-anthropic-quota.out"
	local reason_file="${TEST_ROOT}/failure-classifier-anthropic-quota.reason"
	printf 'Anthropic provider error HTTP 429: {"error":{"type":"credit_exhausted","message":"You have exhausted your credit"}}\n' >"$output_file"

	local reason
	classify_failure_reason "$output_file" >"$reason_file"
	reason=$(<"$reason_file")

	if [[ "$reason" == "quota_exceeded" ]] &&
		[[ "${_failure_provider_error_type:-}" == "quota_exceeded" ]] &&
		[[ "${_failure_provider_status:-}" == "429" ]] &&
		[[ "${_failure_classification_source:-}" == "trusted_provider" ]] &&
		[[ "${_failure_classification_pattern:-}" == *"credit_exhausted"* ]]; then
		print_result "failure classifier distinguishes Anthropic credit exhaustion" 0
		return 0
	fi

	print_result "failure classifier distinguishes Anthropic credit exhaustion" 1 \
		"reason=$reason type=${_failure_provider_error_type:-} status=${_failure_provider_status:-} source=${_failure_classification_source:-} pattern=${_failure_classification_pattern:-}"
	return 0
}

test_service_interruption_candidate_uses_separate_path() {
	local output_file="${TEST_ROOT}/service-interruption.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_23037","text":"editing files"}' 'OpenAI 503 service unavailable after tool activity' >"$output_file"
	_run_result_label=""
	_run_failure_reason=""
	_run_should_retry=0

	local status=0
	_handle_run_result 1 "$output_file" "worker" "openai" "issue-23037" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 81 && "$_run_result_label" == "service_interruption_continue" && -f "$output_file" ]]; then
		print_result "service interruption uses dedicated continuation path" 0
	else
		print_result "service interruption uses dedicated continuation path" 1 \
			"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} output_exists=$([[ -f "$output_file" ]] && printf yes || printf no)"
	fi

	local local_output_file="${TEST_ROOT}/service-interruption-local.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_local","text":"editing files"}' 'worker received SIGTERM after tool activity' >"$local_output_file"
	_run_result_label=""
	_run_failure_reason=""
	status=0
	_handle_run_result 143 "$local_output_file" "worker" "openai" "issue-23037" "openai/gpt-5.5" || status=$?

	if [[ "$status" -eq 78 && "$_run_result_label" == "signal_terminated_continue" && "$_run_runtime_error_type" == "sigterm" && ! -f "$local_output_file" ]]; then
		print_result "SIGTERM uses signal-specific continuation path" 0
	else
		print_result "SIGTERM uses signal-specific continuation path" 1 \
			"status=$status label=${_run_result_label:-<empty>} runtime=${_run_runtime_error_type:-<empty>} output_exists=$([[ -f "$local_output_file" ]] && printf yes || printf no)"
	fi

	if ! service_interruption_continue_candidate "rate_limit" "1" "1" "" "rate_limit"; then
		print_result "rate limits do not consume service interruption budget" 0
	else
		print_result "rate limits do not consume service interruption budget" 1
	fi

	if service_interruption_continue_candidate "auth_error" "1" "1" "" "auth_error"; then
		print_result "auth errors with activity consume service interruption budget" 0
	else
		print_result "auth errors with activity consume service interruption budget" 1
	fi

	if ! service_interruption_continue_candidate "auth_error" "1" "0" "" "auth_error"; then
		print_result "startup auth errors do not consume service interruption budget" 0
	else
		print_result "startup auth errors do not consume service interruption budget" 1
	fi

	local auth_refresh_output_file="${TEST_ROOT}/service-interruption-auth-refresh.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_auth","text":"editing files"}' 'Token refresh failed: 401' >"$auth_refresh_output_file"
	_run_result_label=""
	_run_failure_reason=""
	status=0
	_handle_run_result 1 "$auth_refresh_output_file" "worker" "anthropic" "issue-23037" "anthropic/claude-sonnet-4-6" || status=$?

	if [[ "$status" -eq 81 && "$_run_result_label" == "service_interruption_continue" && "$_run_failure_reason" == "auth_error" && -f "$auth_refresh_output_file" ]]; then
		print_result "token refresh 401 with session evidence resumes as service interruption" 0
	else
		print_result "token refresh 401 with session evidence resumes as service interruption" 1 \
			"status=$status label=${_run_result_label:-<empty>} reason=${_run_failure_reason:-<empty>} output_exists=$([[ -f "$auth_refresh_output_file" ]] && printf yes || printf no)"
	fi

	if service_interruption_continue_candidate "local_error" "137" "1" "" ""; then
		print_result "SIGKILL with activity can resume as interruption" 0
	else
		print_result "SIGKILL with activity can resume as interruption" 1
	fi

	if ! service_interruption_continue_candidate "local_error" "143" "1" "" ""; then
		print_result "SIGTERM does not consume service interruption budget" 0
	else
		print_result "SIGTERM does not consume service interruption budget" 1
	fi

	local terminated_tail_file="${TEST_ROOT}/terminated-tail.out"
	printf '%s\n' '{"type":"text","sessionID":"ses_tail","text":"editing files"}' 'terminated' >"$terminated_tail_file"
	if runtime_signal_terminated_candidate "$terminated_tail_file" "1" "1"; then
		print_result "terminated tail classifies as signal termination" 0
	else
		print_result "terminated tail classifies as signal termination" 1
	fi

	return 0
}

test_service_interruption_exhausted_metric_preserves_context() {
	local captured_file="${TEST_ROOT}/service-interruption-exhausted.args"
	append_runtime_metric() {
		printf '%s\n' "$@" >"$captured_file"
		return 0
	}
	local WORKER_ISSUE_NUMBER="24099"
	local DISPATCH_REPO_SLUG="owner/repo"
	local _run_provider_error_type=""
	local _run_provider_status=""
	local _run_runtime_error_type=""
	local _run_classification_source="default_local"
	local _run_classification_pattern="default_local"
	local _metric_kill_reason="unknown"

	_append_service_interruption_exhausted_metric \
		"worker" "issue-24099" "openai/gpt-5.5" \
		"${TEST_ROOT}/worktree" "local_error" \
		"${TEST_ROOT}/excerpt.log" "ses_context"

	local captured
	captured=$(<"$captured_file")
	if [[ "$captured" == *$'service_interruption_exhausted\n81\nlocal_error\n1\n0\n24099\nowner/repo\n'* ]] &&
		[[ "$captured" == *$'excerpt.log\nses_context\n'* ]] &&
		[[ "$captured" == *$'mid_session_interruption\nunknown\nresume_existing_session'* ]]; then
		print_result "service interruption exhausted metric preserves diagnostics context" 0
	else
		print_result "service interruption exhausted metric preserves diagnostics context" 1 "$captured"
	fi
	unset -f append_runtime_metric 2>/dev/null || true
	return 0
}

test_canary_pins_vanilla_agent_with_isolated_plugin_config() {
	local canary_root="${TEST_ROOT}/canary-agent"
	local fake_bin_dir="${canary_root}/bin"
	local plugin_dir="${canary_root}/plugin path"
	local plugin_path="${plugin_dir}/index.mjs"
	local args_file="${canary_root}/args.txt"
	local env_file="${canary_root}/env.txt"
	mkdir -p "$fake_bin_dir" "$plugin_dir"
	printf '%s\n' 'export default {};' >"$plugin_path"

	cat >"${fake_bin_dir}/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
	printf '1.14.31\n'
	exit 0
fi
if [[ -n "${AIDEVOPS_OPENCODE_SESSION_ID:-}${OPENCODE_SESSION_ID:-}${OPENCODE_PID:-}${OPENCODE_RUN_ID:-}${OPENCODE_PROCESS_ROLE:-}${OPENCODE:-}${OPENCODE_SERVER_PASSWORD:-}" ]]; then
	printf 'leaked session env\n' >"$AIDEVOPS_CANARY_ENV_FILE"
	exit 42
fi
printf '%s\n' "$*" >"$AIDEVOPS_CANARY_ARGS_FILE"
printf 'OPENCODE_BIN=%s\nOPENCODE_DB=%s\nAIDEVOPS_HEADLESS=%s\n' \
	"${OPENCODE_BIN:-}" "${OPENCODE_DB:-}" "${AIDEVOPS_HEADLESS:-}" >"$AIDEVOPS_CANARY_ENV_FILE"
if [[ -f "${XDG_CONFIG_HOME:-}/opencode/opencode.json" ]]; then
	printf 'CONFIG=%s\n' "$(<"${XDG_CONFIG_HOME}/opencode/opencode.json")" >>"$AIDEVOPS_CANARY_ENV_FILE"
fi
printf 'The answer is Four.\n'
exit 0
EOF
	chmod +x "${fake_bin_dir}/opencode"

	local output
	if output=$(
		PATH="${fake_bin_dir}:$PATH" \
			HOME="${canary_root}/home" \
			OPENCODE_BIN="${fake_bin_dir}/opencode" \
			OPENCODE_DB="${canary_root}/opencode.db" \
			AIDEVOPS_OPENCODE_SESSION_ID="ses_parent" \
			OPENCODE_SESSION_ID="ses_parent" \
			OPENCODE_PID="12345" \
			OPENCODE_RUN_ID="run_parent" \
			OPENCODE_PROCESS_ROLE="tui" \
			OPENCODE="1" \
			OPENCODE_SERVER_PASSWORD="session-password" \
			AIDEVOPS_PLUGIN_INDEX="$plugin_path" \
			AIDEVOPS_CANARY_ARGS_FILE="$args_file" \
			AIDEVOPS_CANARY_ENV_FILE="$env_file" \
			AIDEVOPS_HEADLESS_RUNTIME_DIR="${canary_root}/runtime" \
			CANARY_CACHE_TTL_SECONDS=0 \
			CANARY_TIMEOUT_SECONDS=5 \
			bash -c 'source "$1" help >/dev/null 2>&1; _run_canary_test "anthropic/claude-sonnet-4-6"' _ "$HELPER_SCRIPT"
	) && [[ -f "$args_file" && -f "$env_file" ]]; then
		local args
		args=$(<"$args_file")
		local env_output
		env_output=$(<"$env_file")
		local expected_plugin_url
		expected_plugin_url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).absolute().as_uri())' "$plugin_path")
		if [[ "$args" == *'What is two plus two?'* && "$args" != *'--pure'* && "$args" == *'--agent build'* ]] &&
			[[ "$env_output" == *"OPENCODE_BIN=${fake_bin_dir}/opencode"* ]] &&
			[[ "$env_output" == *"OPENCODE_DB=${canary_root}/opencode.db"* ]] &&
			[[ "$env_output" == *"AIDEVOPS_HEADLESS=1"* ]] &&
			[[ "$env_output" == *"$expected_plugin_url"* ]]; then
			print_result "canary pins vanilla agent with isolated plugin config" 0
			return 0
		fi
		print_result "canary pins vanilla agent with isolated plugin config" 1 \
			"Expected benign prompt, no --pure, but with --agent build, headless env, plugin config, and preserved OpenCode config env; got args: ${args}; env: ${env_output}"
		return 0
	fi

	print_result "canary pins vanilla agent with isolated plugin config" 1 \
		"Canary stub did not run successfully: ${output:-<empty>}"
	return 0
}

test_opencode_session_env_wrapper_strips_session_vars_only() {
	local output
	# shellcheck disable=SC2016 # Inner bash expands these after env stripping.
	output=$(
		AIDEVOPS_OPENCODE_SESSION_ID="ses_parent" \
			OPENCODE_SESSION_ID="ses_parent" \
			OPENCODE_PID="12345" \
			OPENCODE_RUN_ID="run_parent" \
			OPENCODE_PROCESS_ROLE="tui" \
			OPENCODE="1" \
			OPENCODE_SERVER_PASSWORD="session-password" \
			OPENCODE_BIN="opencode" \
			OPENCODE_DB="/tmp/opencode.db" \
			run_without_opencode_session_env bash -c '
			printf "%s|%s|%s|%s|%s|%s|%s|%s|%s" \
				"${AIDEVOPS_OPENCODE_SESSION_ID:-}" "${OPENCODE_SESSION_ID:-}" "${OPENCODE_PID:-}" "${OPENCODE_RUN_ID:-}" \
				"${OPENCODE_PROCESS_ROLE:-}" "${OPENCODE:-}" "${OPENCODE_SERVER_PASSWORD:-}" \
				"${OPENCODE_BIN:-}" "${OPENCODE_DB:-}"
		'
	)

	if [[ "$output" == "|||||||opencode|/tmp/opencode.db" ]]; then
		print_result "OpenCode session env wrapper strips only session-bound vars" 0
		return 0
	fi

	print_result "OpenCode session env wrapper strips only session-bound vars" 1 \
		"Expected session vars stripped and config env preserved, got: ${output}"
	return 0
}

test_worker_opencode_exec_paths_strip_session_env() {
	local invoke_helper="${SCRIPT_DIR}/headless-runtime-invoke.sh"
	# shellcheck disable=SC2016 # Match literal caller-scoped variables in source.
	if grep -Fq 'run_without_opencode_session_env "$SANDBOX_EXEC_HELPER" "${sandbox_args[@]}"' "$invoke_helper" &&
		grep -Fq 'run_without_opencode_session_env timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT"' "$invoke_helper"; then
		print_result "worker OpenCode exec paths strip session env" 0
		return 0
	fi

	print_result "worker OpenCode exec paths strip session env" 1 \
		"Expected sandbox and bare-timeout OpenCode exec paths to use run_without_opencode_session_env"
	return 0
}

test_worker_opencode_invocation_seeds_continuation_session() {
	local invoke_helper="${SCRIPT_DIR}/headless-runtime-invoke.sh"
	# shellcheck disable=SC2016 # Match literal continuation variables in source.
	if grep -Fq '_seed_worker_db_session_context "$isolated_data_dir" "$_invoke_persisted_session"' "$invoke_helper" &&
		grep -Fq '[lifecycle] db_seeded session=$_invoke_persisted_session' "$invoke_helper"; then
		print_result "worker OpenCode invocation seeds persisted continuation session" 0
		return 0
	fi

	print_result "worker OpenCode invocation seeds persisted continuation session" 1 \
		"Expected persisted session seeding before opencode continuation launch"
	return 0
}

test_sandbox_passthrough_scopes_provider_env() {
	local csv
	csv=$(
		OPENAI_API_KEY='openai-test' \
			ANTHROPIC_API_KEY='anthropic-test' \
			GOOGLE_API_KEY='google-test' \
			OPENCODE_BIN='opencode' \
			OPENCODE_DB='/tmp/opencode.db' \
			AIDEVOPS_OPENCODE_SESSION_ID='ses_parent' \
			OPENCODE_SESSION_ID='ses_parent' \
			OPENCODE_PID='12345' \
			OPENCODE_RUN_ID='run_parent' \
			OPENCODE_PROCESS_ROLE='tui' \
			OPENCODE='1' \
			OPENCODE_SERVER_PASSWORD='session-password' \
			build_sandbox_passthrough_csv "openai"
	)

	if [[ "$csv" == *"OPENAI_API_KEY"* ]] &&
		[[ "$csv" != *"ANTHROPIC_API_KEY"* ]] &&
		[[ "$csv" != *"GOOGLE_API_KEY"* ]] &&
		[[ "$csv" == *"OPENCODE_BIN"* ]] &&
		[[ "$csv" == *"OPENCODE_DB"* ]] &&
		[[ "$csv" != *"AIDEVOPS_OPENCODE_SESSION_ID"* ]] &&
		[[ "$csv" != *"OPENCODE_SESSION_ID"* ]] &&
		[[ "$csv" != *"OPENCODE_PID"* ]] &&
		[[ "$csv" != *"OPENCODE_RUN_ID"* ]] &&
		[[ "$csv" != *"OPENCODE_PROCESS_ROLE"* ]] &&
		[[ "$csv" != *"OPENCODE_SERVER_PASSWORD"* ]] &&
		[[ ",$csv," != *",OPENCODE,"* ]]; then
		print_result "sandbox passthrough scopes env to selected provider" 0
		return 0
	fi

	print_result "sandbox passthrough scopes env to selected provider" 1 \
		"Expected OpenAI env only, got: ${csv}"
	return 0
}

test_sandbox_passthrough_rejects_unvalidated_git_config() {
	local csv=""
	csv=$(
		GIT_CONFIG_COUNT=1 \
			GIT_CONFIG_KEY_0='http.extraHeader' \
			GIT_CONFIG_VALUE_0='unrelated' \
			build_sandbox_passthrough_csv "openai" "worker"
	)
	if [[ ",$csv," != *",GIT_CONFIG_COUNT,"* && ",$csv," != *",GIT_CONFIG_KEY_0,"* &&
		",$csv," != *",GIT_CONFIG_VALUE_0,"* ]]; then
		print_result "sandbox passthrough rejects unvalidated ambient Git configuration" 0
		return 0
	fi
	print_result "sandbox passthrough rejects unvalidated ambient Git configuration" 1 "$csv"
	return 0
}

test_triage_sandbox_passthrough_excludes_github_and_worker_authority() {
	local csv=""
	csv=$(
		OPENAI_API_KEY='openai-test' \
			OPENAI_ADMIN_KEY='openai-admin-test' \
			OPENAI_BASE_URL='https://openai-endpoint.example.invalid' \
			ANTHROPIC_API_KEY='anthropic-test' \
			CLAUDE_CODE_OAUTH_TOKEN='anthropic-oauth-test' \
			GOOGLE_OAUTH_ACCESS_TOKEN='google-oauth-test' \
			GH_TOKEN='github-test' \
			GITHUB_TOKEN='github-test' \
			WORKER_ISSUE_NUMBER='28705' \
			AIDEVOPS_PERMISSION_GRANT_FILE='/tmp/grant.json' \
			AIDEVOPS_HEADLESS='1' \
			AIDEVOPS_HEADLESS_AUTH_ISOLATION='1' \
			AIDEVOPS_SESSION_ORIGIN='triage' \
			XDG_CACHE_HOME='/tmp/triage-cache' \
			XDG_CONFIG_HOME='/tmp/triage-config' \
			XDG_DATA_HOME='/tmp/triage-data' \
			XDG_STATE_HOME='/tmp/triage-state' \
			OPENCODE_PURE=1 \
			OPENCODE_DISABLE_DEFAULT_PLUGINS=1 \
			OPENCODE_DISABLE_EXTERNAL_SKILLS=1 \
			OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
			OTEL_EXPORTER_OTLP_ENDPOINT='https://telemetry.example.invalid' \
			build_sandbox_passthrough_csv "openai" "triage" 1
	)
	local env_auth_csv=""
	env_auth_csv=$(OPENAI_API_KEY='openai-test' build_sandbox_passthrough_csv "openai" "triage" 0)

	if [[ ",$csv," != *",OPENAI_API_KEY,"* && ",$env_auth_csv," == *",OPENAI_API_KEY,"* &&
		",$csv," != *",OPENAI_ADMIN_KEY,"* &&
		",$csv," != *",OPENAI_BASE_URL,"* && ",$csv," != *",ANTHROPIC_API_KEY,"* &&
		",$csv," != *",CLAUDE_CODE_OAUTH_TOKEN,"* &&
		",$csv," != *",GOOGLE_OAUTH_ACCESS_TOKEN,"* &&
		",$csv," != *",GH_TOKEN,"* && ",$csv," != *",GITHUB_TOKEN,"* &&
		",$csv," != *",WORKER_ISSUE_NUMBER,"* && ",$csv," != *",AIDEVOPS_PERMISSION_GRANT_FILE,"* &&
		",$csv," != *",OTEL_EXPORTER_OTLP_ENDPOINT,"* && ",$csv," == *",AIDEVOPS_HEADLESS,"* &&
		",$csv," == *",XDG_DATA_HOME,"* && ",$csv," == *",OPENCODE_PURE,"* &&
		",$csv," != *",OPENCODE_DISABLE_DEFAULT_PLUGINS,"* &&
		",$csv," == *",OPENCODE_DISABLE_EXTERNAL_SKILLS,"* &&
		",$csv," == *",OPENCODE_DISABLE_CLAUDE_CODE_SKILLS,"* ]]; then
		print_result "triage sandbox passthrough excludes GitHub and worker authority" 0
		return 0
	fi

	print_result "triage sandbox passthrough excludes GitHub and worker authority" 1 \
		"Unexpected triage passthrough names: ${csv}"
	return 0
}

test_strict_scoped_auth_rejects_malformed_source() {
	local auth_root="${TEST_ROOT}/strict-scoped-auth"
	local source_auth="${auth_root}/source.json"
	local dest_auth="${auth_root}/dest/opencode/auth.json"
	mkdir -p "$auth_root"
	printf '%s\n' '{malformed' >"$source_auth"
	local status=0
	copy_scoped_opencode_auth "$source_auth" "$dest_auth" "openai" true || status=$?
	if [[ "$status" -ne 0 && ! -e "$dest_auth" ]]; then
		print_result "strict scoped auth fails closed on malformed source" 0
		return 0
	fi

	print_result "strict scoped auth fails closed on malformed source" 1 \
		"status=${status} destination_exists=$([[ -e "$dest_auth" ]] && printf yes || printf no)"
	return 0
}

test_triage_runtime_directory_is_framework_owned_and_empty() {
	local runtime_dir=""
	local managed_root="${TEST_ROOT}/managed-triage-runtime"
	local triage_agent=""
	if ! AIDEVOPS_SENSITIVE_TEMP_DIR="$managed_root" \
		_prepare_triage_runtime_directory "runtime_dir"; then
		print_result "triage runtime directory is isolated from target repository" 1 \
			"runtime directory preparation failed"
		return 0
	fi
	managed_root=$(cd "$managed_root" && pwd -P) || return 1

	local runtime_config="${runtime_dir}/.opencode/opencode.json"
	triage_agent="${runtime_dir}/.opencode/agent/triage-review.md"
	if [[ "$runtime_dir" == "$managed_root"/aidevops-headless-triage.* &&
		-f "$triage_agent" &&
		-f "$runtime_config" && ! -e "${runtime_dir}/.git" &&
		$(jq -r '(.default_agent == "triage-review") and (.permission["*"] == "deny") and (.tools["*"] == false) and (.mcp == {}) and (.formatter == false) and (.lsp == false) and (.share == "disabled") and (.subagent_depth == 0)' "$runtime_config") == true ]] &&
		grep -q '^mode: primary$' "$triage_agent" &&
		grep -q '^  "\*": deny$' "$triage_agent"; then
		print_result "triage runtime directory is isolated from target repository" 0
	else
		print_result "triage runtime directory is isolated from target repository" 1 \
			"Unexpected runtime directory: ${runtime_dir:-<empty>}"
	fi
	rm -rf "$runtime_dir" 2>/dev/null || true
	_HEADLESS_RUNTIME_TEMP_PATHS=""
	return 0
}

test_private_sandbox_passthrough_excludes_parent_credentials() {
	local AIDEVOPS_PRIVATE_WORKLOAD=1
	local csv=""
	csv=$(
		OPENAI_API_KEY='openai-test' \
			GH_TOKEN='github-test' \
			OPENCODE_CONFIG='/tmp/untrusted-opencode.json' \
			OPENCODE_BIN='opencode' \
			XDG_CACHE_HOME='/tmp/private-cache' \
			XDG_CONFIG_HOME='/tmp/private-config' \
			XDG_DATA_HOME='/tmp/private-data' \
			XDG_STATE_HOME='/tmp/private-state' \
			build_sandbox_passthrough_csv "openai"
	)
	local item_count=0
	item_count=$(printf '%s\n' "$csv" | tr ',' '\n' | wc -l | tr -d ' ')

	if [[ "$item_count" -eq 4 && ",${csv}," == *",XDG_CACHE_HOME,"* &&
		",${csv}," == *",XDG_CONFIG_HOME,"* && ",${csv}," == *",XDG_DATA_HOME,"* &&
		",${csv}," == *",XDG_STATE_HOME,"* ]]; then
		print_result "private sandbox passthrough excludes parent credentials and config overrides" 0
		return 0
	fi

	print_result "private sandbox passthrough excludes parent credentials and config overrides" 1 \
		"Expected isolated XDG paths only, got: ${csv}"
	return 0
}

test_copy_scoped_opencode_auth_keeps_selected_provider_only() {
	local auth_root="${TEST_ROOT}/scoped-auth"
	local source_auth="${auth_root}/source.json"
	local dest_auth="${auth_root}/dest/opencode/auth.json"
	mkdir -p "$auth_root"
	cat >"$source_auth" <<'EOF'
{
  "openai": {"type": "oauth", "access": "openai-token"},
  "anthropic": {"type": "oauth", "access": "anthropic-token"}
}
EOF

	copy_scoped_opencode_auth "$source_auth" "$dest_auth" "openai"

	local has_openai has_anthropic
	has_openai=$(jq -r 'has("openai")' "$dest_auth")
	has_anthropic=$(jq -r 'has("anthropic")' "$dest_auth")
	if [[ "$has_openai" == "true" && "$has_anthropic" == "false" ]]; then
		print_result "copy_scoped_opencode_auth keeps selected provider only" 0
		return 0
	fi

	print_result "copy_scoped_opencode_auth keeps selected provider only" 1 \
		"Expected only openai auth entry in ${dest_auth}"
	return 0
}
