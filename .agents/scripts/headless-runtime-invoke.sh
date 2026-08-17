#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime OpenCode Invocation Helpers
# =============================================================================
# Focused phases used by headless-runtime-helper.sh::_invoke_opencode. The
# public orchestrator remains in the original file to preserve its complexity
# identity key; these helpers rely on Bash's established caller-scoped locals.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-invoke.sh"
# Part of aidevops framework: https://aidevops.sh

# These phases intentionally use caller-scoped orchestration locals.
# shellcheck disable=SC2154

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_HEADLESS_RUNTIME_INVOKE_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_INVOKE_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_invoke_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_invoke_lib_path" == "${BASH_SOURCE[0]}" ]] && _invoke_lib_path="."
	SCRIPT_DIR="$(cd "$_invoke_lib_path" && pwd)"
	unset _invoke_lib_path
fi

# Validate the invocation boundary and classify its trust mode.
# Uses caller-scoped output_file, exit_code_file, runtime_role, and mode flags.
_invoke_opencode_validate_context() {
	if _headless_private_workload_enabled; then
		private_workload=1
		if [[ ! -f "$PRIVATE_OUTPUT_FILTER" ]] || ! command -v python3 >/dev/null 2>&1; then
			print_error "Private workload output filter is unavailable"
			printf '%s' "86" >"$exit_code_file"
			return 1
		fi
		if [[ ! -x "$SANDBOX_EXEC_HELPER" || "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
			print_error "Private workloads require the sandbox launcher"
			printf '%s' "86" >"$exit_code_file"
			return 1
		fi
	fi
	if [[ "$runtime_role" == "$HEADLESS_ROLE_TRIAGE" && "$private_workload" -ne 1 ]]; then
		public_triage=1
	fi
	_WORKER_EXIT_CODE_FILE="$exit_code_file"
	return 0
}

# Create and register the isolated OpenCode data directory.
_invoke_opencode_create_isolated_data() {
	[[ "${AIDEVOPS_HEADLESS_AUTH_ISOLATION:-1}" == "1" ]] || return 0
	if [[ -n "${AIDEVOPS_WORKER_PREWARM_DIR:-}" && -d "${AIDEVOPS_WORKER_PREWARM_DIR:-}" ]]; then
		isolated_data_dir="$AIDEVOPS_WORKER_PREWARM_DIR"
		isolated_data_precreated=1
		print_info "[lifecycle] opencode_warm_done dir=$isolated_data_dir (reusing pre-warmed dir) pid=$$"
	else
		isolated_data_dir=$(_create_headless_runtime_temp_dir "auth")
	fi
	if [[ -z "$isolated_data_dir" ]]; then
		print_error "Headless auth isolation could not create crash-resilient storage"
		printf '%s' "86" >"$exit_code_file"
		return 1
	fi
	if [[ "$isolated_data_precreated" -eq 1 ]]; then
		_register_headless_runtime_temp_path "$isolated_data_dir"
	elif ! _register_headless_runtime_sensitive_temp_path "$isolated_data_dir"; then
		print_error "Headless auth isolation could not register crash-resilient cleanup"
		printf '%s' "86" >"$exit_code_file"
		return 1
	fi
	mkdir -p "${isolated_data_dir}/opencode"
	return 0
}

# Copy only the selected credential into the isolated data directory.
_invoke_opencode_copy_isolated_auth() {
	[[ -n "$isolated_data_dir" ]] || return 0
	if [[ -f "$OPENCODE_AUTH_FILE" ]]; then
		if ! copy_scoped_opencode_auth "$OPENCODE_AUTH_FILE" \
			"${isolated_data_dir}/opencode/auth.json" "${_invoke_provider:-}" \
			"$([[ "$public_triage" -eq 1 ]] && printf true || printf false)"; then
			print_error "Public triage could not isolate the selected provider credential"
			printf '%s' "86" >"$exit_code_file"
			return 1
		fi
		if [[ "$public_triage" -eq 1 && -n "${_invoke_provider:-}" ]] && \
			jq -e --arg provider "$_invoke_provider" 'has($provider)' \
			"${isolated_data_dir}/opencode/auth.json" >/dev/null 2>&1; then
			public_triage_auth_ready=1
		fi
	fi
	return 0
}

# Export isolated runtime paths and prepare continuation state.
_invoke_opencode_discard_failed_continuation() {
	local arg=""
	local skip_session_value=0
	local -a fresh_cmd=()

	for arg in "${cmd[@]}"; do
		if [[ "$skip_session_value" -eq 1 ]]; then
			skip_session_value=0
			continue
		fi
		case "$arg" in
		--session)
			skip_session_value=1
			;;
		--continue)
			;;
		*)
			fresh_cmd+=("$arg")
			;;
		esac
	done
	cmd=("${fresh_cmd[@]}")
	clear_session_id "${_invoke_provider:-}" "${_invoke_session_key:-}"
	persisted_session=""
	_invoke_persisted_session=""
	_WORKER_PERSISTED_SESSION_ID=""
	return 0
}

_invoke_opencode_export_isolation() {
	[[ -n "$isolated_data_dir" ]] || return 0
	export XDG_DATA_HOME="$isolated_data_dir"
	if [[ "$public_triage" -eq 1 ]]; then
		isolated_home_dir="${isolated_data_dir}/home"
		export XDG_CACHE_HOME="${isolated_data_dir}/cache"
		export XDG_CONFIG_HOME="${isolated_data_dir}/config"
		export XDG_STATE_HOME="${isolated_data_dir}/state"
		export OPENCODE_PURE=1
		export OPENCODE_DISABLE_EXTERNAL_SKILLS=1
		export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1
		mkdir -p "$isolated_home_dir" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
		chmod 700 "$isolated_home_dir" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
	fi
	if [[ "$private_workload" -eq 1 ]]; then
		export XDG_CACHE_HOME="${isolated_data_dir}/cache"
		export XDG_CONFIG_HOME="${isolated_data_dir}/config"
		export XDG_STATE_HOME="${isolated_data_dir}/state"
		mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
		chmod 700 "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
	fi
	_WORKER_ISOLATED_DB_PATH="${isolated_data_dir}/opencode/opencode.db"
	print_info "[lifecycle] db_isolated dir=$isolated_data_dir pid=$$"
	if ! _headless_run_is_ephemeral "$runtime_role" && [[ ! -f "$_WORKER_ISOLATED_DB_PATH" ]]; then
		if ! _initialize_worker_db_from_shared_schema "$_WORKER_ISOLATED_DB_PATH" "${HOME}/.local/share/opencode/opencode.db"; then
			print_error "Worker database could not initialise from the shared OpenCode schema"
			printf '%s' "86" >"$exit_code_file"
			return 1
		fi
		print_info "[lifecycle] db_schema_initialized dir=$isolated_data_dir pid=$$"
	else
		_sync_worker_db_migration_metadata "$isolated_data_dir"
	fi
	if [[ -n "${_invoke_persisted_session:-}" ]]; then
		if _seed_worker_db_session_context "$isolated_data_dir" "$_invoke_persisted_session" "${_invoke_work_dir:-}"; then
			print_info "[lifecycle] db_seeded session=$_invoke_persisted_session pid=$$"
		else
			print_warning "[lifecycle] db_seed_failed session=$_invoke_persisted_session pid=$$"
			_invoke_opencode_discard_failed_continuation
			print_info "[lifecycle] db_seed_failed_fresh_session pid=$$"
		fi
	fi
	if [[ -f "${isolated_data_dir}/opencode/auth.json" ]]; then
		_maybe_rotate_isolated_auth "${isolated_data_dir}/opencode/auth.json" "${_invoke_provider:-anthropic}"
	fi
	return 0
}

_invoke_opencode_prepare_isolation() {
	_invoke_opencode_create_isolated_data || return 1
	_invoke_opencode_copy_isolated_auth || return 1
	_invoke_opencode_export_isolation || return 1
	return 0
}

# Build the child command and public-triage egress policy inside the subprocess.
_invoke_opencode_prepare_child_command() {
	if [[ "$public_triage" -eq 1 ]]; then
		if [[ -z "${_invoke_provider:-}" || -z "$isolated_home_dir" ]]; then
			print_error "Public triage requires a selected provider and isolated HOME"
			printf '%s' "126" >"$exit_code_file"
			return 126
		fi
		local requested_egress_mode="$egress_mode"
		if ! egress_mode="$(_resolve_public_triage_egress_mode \
			"$requested_egress_mode" "${AIDEVOPS_WORKER_EGRESS_BACKEND:-}")"; then
			print_error "Invalid public triage egress mode '${requested_egress_mode}'"
			printf '%s' "126" >"$exit_code_file"
			return 126
		fi
		if [[ "$requested_egress_mode" == "off" ]]; then
			print_warning "Public triage ignores egress mode off; effective mode=${egress_mode}"
		elif [[ "$egress_mode" == "$HEADLESS_EGRESS_MODE_AUTO" ]]; then
			print_warning "Public triage whole-process egress backend unavailable; continuing with the no-tools isolated runtime (egress=logical-isolation)"
		fi
		egress_policy_profile="provider:${_invoke_provider}"
		sandbox_home_args=(--home-dir "$isolated_home_dir")
	fi
	_oc_cmd=("${cmd[@]}")
	if [[ "${HEADLESS:-}" == "1" && "$private_workload" -ne 1 ]]; then
		local -a new_cmd=()
		local inserted=0
		local arg=""
		for arg in "${_oc_cmd[@]}"; do
			new_cmd+=("$arg")
			if [[ "$arg" == "run" && "$inserted" -eq 0 ]]; then
				new_cmd+=("--print-logs" "--log-level" "WARN")
				inserted=1
			fi
		done
		_oc_cmd=("${new_cmd[@]}")
	fi
	return 0
}

# Execute one sandboxed command while preserving the child's pipeline status.
_invoke_opencode_run_sandboxed() {
	local passthrough_csv=""
	if ! prepare_headless_signing_sandbox_env "$runtime_role"; then
		print_error "Headless signing configuration could not be safely isolated for the sandbox"
		printf '%s' "87" >"$exit_code_file"
		return 87
	fi
	passthrough_csv="$(build_sandbox_passthrough_csv \
		"${_invoke_provider:-}" "$runtime_role" "$public_triage_auth_ready")"
	local -a sandbox_args=(run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io)
	if [[ "$private_workload" -eq 1 ]]; then
		sandbox_args+=(--private-output)
	else
		sandbox_args+=(--stream-stdout)
	fi
	sandbox_args+=(--egress-mode "$egress_mode" --egress-policy-profile "$egress_policy_profile" --worker-id "$egress_worker_id")
	sandbox_args+=("${sandbox_home_args[@]}")
	[[ -z "$passthrough_csv" ]] || sandbox_args+=(--passthrough "$passthrough_csv")
	sandbox_args+=(-- "${_oc_cmd[@]}")
	if [[ "$private_workload" -eq 1 ]]; then
		run_without_opencode_session_env "$SANDBOX_EXEC_HELPER" "${sandbox_args[@]}" 2>&1 |
			python3 "$PRIVATE_OUTPUT_FILTER" >"$output_file" 2>/dev/null
		local -a private_pipeline_status=("${PIPESTATUS[@]}")
		if [[ "${private_pipeline_status[1]:-1}" -ne 0 ]]; then
			printf '%s' "86" >"$exit_code_file"
		else
			printf '%s' "${private_pipeline_status[0]:-1}" >"$exit_code_file"
		fi
	else
		run_without_opencode_session_env "$SANDBOX_EXEC_HELPER" "${sandbox_args[@]}" 2>&1 | tee "$output_file"
		printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
	fi
	return 0
}

# Execute without privilege isolation only when the policy permits it.
_invoke_opencode_run_bare() {
	if [[ "$private_workload" -eq 1 ]]; then
		print_error "Private workload sandbox became unavailable before launch"
		printf '%s' "86" >"$exit_code_file"
		return 86
	fi
	if _headless_opencode_sandbox_required "$runtime_role" "$private_workload" "$egress_mode"; then
		if [[ "$public_triage" -eq 1 ]]; then
			print_error "Public triage requires the sandbox launcher for its isolated runtime"
		else
			print_error "Whole-process worker egress is required, but the sandbox launcher is disabled or unavailable"
		fi
		printf '%s' "126" >"$exit_code_file"
		return 126
	fi
	if [[ "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
		print_info "AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 — using bare timeout (no privilege isolation) (GH#20146 audit)"
	fi
	run_without_opencode_session_env timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" "${_oc_cmd[@]}" 2>&1 | tee "$output_file"
	printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
	return 0
}

# Start the runtime subprocess and publish its PID to the caller scope.
_invoke_opencode_launch_worker() {
	(
		set +e
		local egress_mode="${AIDEVOPS_WORKER_EGRESS_MODE:-auto}"
		local egress_worker_id="${AIDEVOPS_WORKER_ID:-${_invoke_session_key:-headless}}"
		local egress_policy_profile="default"
		local -a sandbox_home_args=()
		local -a _oc_cmd=()
		local prepare_status=0
		_invoke_opencode_prepare_child_command || prepare_status=$?
		[[ "$prepare_status" -eq 0 ]] || exit "$prepare_status"
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			_invoke_opencode_run_sandboxed
		else
			local bare_status=0
			_invoke_opencode_run_bare || bare_status=$?
			[[ "$bare_status" -eq 0 ]] || exit "$bare_status"
		fi
		exit 0
	) &
	worker_pid=$!
	return 0
}

# Start the standalone activity watchdog and fast rate-limit monitor.
_invoke_opencode_start_monitors() {
	local watchdog_script="${SCRIPT_DIR}/worker-activity-watchdog.sh"
	local stall_timeout="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-600}"
	[[ "$stall_timeout" =~ ^[0-9]+$ ]] || stall_timeout=600
	local phase1_timeout="${HEADLESS_PHASE1_TIMEOUT_SECONDS:-180}"
	[[ "$phase1_timeout" =~ ^[0-9]+$ ]] || phase1_timeout=180
	if [[ -x "$watchdog_script" ]]; then
		nohup "$watchdog_script" \
			--output-file "$output_file" --worker-pid "$worker_pid" \
			--exit-code-file "$exit_code_file" --session-key "${_invoke_session_key:-}" \
			--repo-slug "${DISPATCH_REPO_SLUG:-}" --worktree-path "${_WORKER_WORKTREE_PATH:-}" \
			--stall-timeout "$stall_timeout" --phase1-timeout "$phase1_timeout" \
			</dev/null >/dev/null 2>&1 &
		watchdog_pid=$!
		print_info "[lifecycle] activity_watchdog_started pid=$watchdog_pid worker=$worker_pid stall_timeout=${stall_timeout}s"
	else
		print_warning "[lifecycle] standalone watchdog not found at $watchdog_script — falling back to inline"
		_run_activity_watchdog "$output_file" "$worker_pid" "$exit_code_file" "$_invoke_session_key" &
		watchdog_pid=$!
	fi
	local rate_limit_window="${HEADLESS_RATE_LIMIT_DETECT_SECONDS:-30}"
	if [[ "$rate_limit_window" =~ ^[0-9]+$ && "$rate_limit_window" -gt 0 ]]; then
		_rl_monitor_pid=$(_launch_rate_limit_fast_monitor "$output_file" "$worker_pid" "$exit_code_file" "$rate_limit_window")
		print_info "[lifecycle] rate_limit_fast_monitor_started pid=${_rl_monitor_pid:-none} worker=$worker_pid window=${rate_limit_window}s"
	fi
	return 0
}

# Stop and reap both monitoring processes without allowing a stuck watchdog to
# hold the worker wrapper indefinitely.
_invoke_opencode_cleanup_monitors() {
	if [[ -n "$watchdog_pid" ]]; then
		kill "$watchdog_pid" 2>/dev/null || true
		local watchdog_wait_start watchdog_wait_elapsed
		watchdog_wait_start=$(date +%s)
		while kill -0 "$watchdog_pid" 2>/dev/null; do
			watchdog_wait_elapsed=$(($(date +%s) - watchdog_wait_start))
			if [[ "$watchdog_wait_elapsed" -gt 30 ]]; then
				print_warning "[lifecycle] watchdog_wait_timeout pid=$watchdog_pid elapsed=${watchdog_wait_elapsed}s — sending SIGKILL"
				kill -9 "$watchdog_pid" 2>/dev/null || true
				break
			fi
			sleep 1
		done
		wait "$watchdog_pid" 2>/dev/null || true
	fi
	print_info "[lifecycle] watchdog_cleaned pid=$watchdog_pid"
	if [[ -n "${_rl_monitor_pid:-}" ]]; then
		kill "$_rl_monitor_pid" 2>/dev/null || true
		wait "$_rl_monitor_pid" 2>/dev/null || true
	fi
	return 0
}

# Merge or discard isolated state and clear process-global trap context.
_invoke_opencode_finalize_data() {
	if [[ -n "$isolated_data_dir" && -d "$isolated_data_dir" ]]; then
		if ! _finalize_isolated_runtime_data "$isolated_data_dir" "$runtime_role"; then
			print_error "Isolated runtime data cleanup failed for role=$runtime_role"
			if _headless_run_is_ephemeral "$runtime_role"; then
				printf '%s' "86" >"$exit_code_file"
			fi
		fi
	fi
	_WORKER_EXIT_CODE_FILE=""
	print_info "[lifecycle] invoke_opencode_returning pid=$$"
	return 0
}
