#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker Preparation -- Launch, retry, detach, and stall helpers
# =============================================================================
# Worker preparation helpers extracted from headless-runtime-worker.sh. The
# original worker library remains the public orchestrator and sources this file.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-worker-prepare.sh"
#
# Dependencies:
#   - headless-runtime-worker.sh module constants and lifecycle helpers
#   - headless-runtime-lib.sh provider and private-workload helpers
#   - shared-constants.sh print helpers
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_PREPARE_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_PREPARE_LIB_LOADED=1
: "${_HRW_ROLE_WORKER:=worker}"

# Defensive SCRIPT_DIR fallback (test harnesses may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_hrw_permission_pending_path() {
	local work_dir="$1"
	local git_dir=""
	git_dir=$(git -C "$work_dir" rev-parse --absolute-git-dir 2>/dev/null) || return 1
	printf '%s/aidevops-permission-pending\n' "$git_dir"
	return 0
}

_hrw_mark_runtime_launch_started() {
	local session_key="$1"
	local runtime="$2"
	_WORKER_RUNTIME_LAUNCH_STARTED=1
	print_info "[lifecycle] pre_runtime_launch session=${session_key} runtime=${runtime} pid=$$"
	return 0
}

#######################################
# Verify that a worker still owns its exact dispatch target. Issue and linked-
# issue PR-repair workers require the live issue assignment granted at dispatch.
# Direct PR-remediation workers instead require the exact open PR head selected
# by the scanner. This helper is read-only and fail-closed.
#######################################
_hrw_verify_dispatch_ownership() {
	local issue_number="${WORKER_ISSUE_NUMBER:-}"
	[[ -n "$issue_number" ]] || return 0
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local ownership_helper="${HEADLESS_RUNTIME_OWNERSHIP_HELPER:-${SCRIPT_DIR}/dispatch-claim-helper.sh}"
	if [[ -z "$repo_slug" || ! -x "$ownership_helper" ]]; then
		print_error "[ownership-fence] incomplete worker ownership contract issue=${issue_number} repo=${repo_slug:-missing} helper=$([[ -x "$ownership_helper" ]] && printf available || printf missing)"
		return 1
	fi

	local repair_pr_number="${AIDEVOPS_PR_REPAIR_NUMBER:-}"
	if [[ -n "$repair_pr_number" && "$repair_pr_number" == "$issue_number" ]]; then
		local expected_head_sha="${AIDEVOPS_PR_REPAIR_HEAD_SHA:-}"
		local expected_head_ref="${AIDEVOPS_PR_REPAIR_HEAD_REF:-}"
		if [[ -z "$expected_head_sha" || -z "$expected_head_ref" ]]; then
			print_error "[ownership-fence] incomplete direct PR repair contract pr=${repair_pr_number} repo=${repo_slug} head_sha=${expected_head_sha:-missing} head_ref=${expected_head_ref:-missing}"
			return 1
		fi
		local target_output=""
		local target_rc=0
		target_output=$("$ownership_helper" verify-pr-repair-target \
			"$repair_pr_number" "$repo_slug" "$expected_head_sha" "$expected_head_ref" 2>&1) || target_rc=$?
		if [[ "$target_rc" -eq 0 ]]; then
			print_info "[ownership-fence] ${target_output}"
			return 0
		fi
		print_warning "[ownership-fence] direct PR repair target unavailable pr=${repair_pr_number} repo=${repo_slug} rc=${target_rc}: ${target_output}"
		return 1
	fi

	local runner_login="${WORKER_GITHUB_LOGIN:-${AIDEVOPS_WORKER_GITHUB_LOGIN:-}}"
	if [[ -z "$runner_login" ]]; then
		print_error "[ownership-fence] incomplete worker ownership contract issue=${issue_number} repo=${repo_slug:-missing} runner=${runner_login:-missing}"
		return 1
	fi

	local ownership_output=""
	local ownership_rc=0
	ownership_output=$("$ownership_helper" verify-worker-ownership \
		"$issue_number" "$repo_slug" "$runner_login" 2>&1) || ownership_rc=$?
	if [[ "$ownership_rc" -eq 0 ]]; then
		print_info "[ownership-fence] ${ownership_output}"
		return 0
	fi
	print_warning "[ownership-fence] worker ownership unavailable issue=${issue_number} repo=${repo_slug} runner=${runner_login} rc=${ownership_rc}: ${ownership_output}"
	return 1
}

_private_workload_directory_lock_key() {
	local work_dir="$1"
	local resolved_work_dir=""
	local work_dir_hash=""
	resolved_work_dir=$(cd "$work_dir" 2>/dev/null && pwd -P) || return 1
	work_dir_hash=$(printf '%s' "$resolved_work_dir" | python3 -c \
		'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())') || return 1
	[[ "$work_dir_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
	printf 'private-workload-dir-%s\n' "$work_dir_hash"
	return 0
}

_hrw_prepare_private_workload() {
	local session_key="$1"
	local work_dir="$2"
	local expected_model="$3"
	local expected_agent="$4"
	local expected_profile_sha256="$5"
	local workload_lock_key=""
	_private_workload_session_key_is_opaque "$session_key" || return 1
	_WORKER_WORKTREE_PATH=""
	WORKER_TARGET_BRANCH=""
	export WORKER_NO_EXIT_PUSH=1
	_acquire_session_lock "$session_key" || return 2
	workload_lock_key=$(_private_workload_directory_lock_key "$work_dir") || {
		_release_session_lock "$session_key"
		return 1
	}
	if ! _acquire_private_workload_lock "$workload_lock_key"; then
		_release_session_lock "$session_key"
		return 2
	fi
	if ! _validate_private_workload_profile "$work_dir" "$expected_model" \
		"$expected_agent" "$expected_profile_sha256"; then
		_release_private_workload_lock "$workload_lock_key"
		_release_session_lock "$session_key"
		return 1
	fi
	_PRIVATE_WORKLOAD_LOCK_KEY="$workload_lock_key"
	_WORKER_START_EPOCH_MS=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	# shellcheck disable=SC2064
	trap "_private_workload_exit_trap '$session_key' '$workload_lock_key'" EXIT
	return 0
}

#######################################
# Finalize a non-worker runtime without touching implementation-worker claims
# or worktree ownership. Used by both normal completion and the EXIT trap.
#
# Arguments:
#   $1 - session key
#######################################
_hrw_cleanup_non_worker_run() {
	local session_key="$1"
	local cleanup_status=0

	_release_session_lock "$session_key"
	if declare -F _cleanup_headless_runtime_temp_paths >/dev/null 2>&1; then
		_cleanup_headless_runtime_temp_paths || cleanup_status=$?
	fi
	aidevops_runtime_bundle_lease_release || print_warning "Failed to release the runtime bundle lease"
	unset _WORKER_WORKTREE_PATH WORKER_TARGET_BRANCH 2>/dev/null || true
	trap - EXIT
	return "$cleanup_status"
}

_hrw_non_worker_exit_trap() {
	local session_key="$1"
	local cleanup_status=0
	_hrw_cleanup_non_worker_run "$session_key" || cleanup_status=$?
	if [[ "$cleanup_status" -ne 0 ]]; then
		print_warning "[lifecycle] non_worker_runtime_temp_cleanup_failed session=${session_key} guardian=retained"
		trap - EXIT
		exit 86
	fi
	return 0
}

#######################################
# Remove implementation-worker authority from non-worker roles or load the
# worker-only pending permission request for an implementation worker.
#
# Arguments:
#   $1 - runtime role
#   $2 - work directory
#######################################
_hrw_prepare_role_context() {
	local role="$1"
	local work_dir="$2"

	if [[ "$role" != "$_HRW_ROLE_WORKER" ]]; then
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH \
			WORKER_GITHUB_LOGIN WORKER_SESSION_KEY AIDEVOPS_WORKER_GITHUB_LOGIN \
			DISPATCH_REPO_SLUG AIDEVOPS_DISPATCH_LEASE_TOKEN \
			AIDEVOPS_DISPATCH_LEASE_DEVICE AIDEVOPS_ATTEMPT_ID \
			AIDEVOPS_PARENT_WORKER_ID AIDEVOPS_ROOT_WORKER_ID AIDEVOPS_WORKER_ID \
			AIDEVOPS_PERMISSION_GRANT_FILE AIDEVOPS_PERMISSION_REQUEST_ID \
			AIDEVOPS_WORKTREE_OWNER_PID AIDEVOPS_WORKTREE_OWNER_SESSION \
			AIDEVOPS_WORKTREE_OWNER_TASK AIDEVOPS_WORKTREE_OWNER_PATH \
			AIDEVOPS_WORKER_PREWARM_DIR \
			2>/dev/null || true
		return 0
	fi

	local permission_pending_file=""
	local permission_request_id=""
	# A pending marker carries scoped worker authority. Resume it only for the
	# exact issue and session that created it; retain mismatched markers on disk.
	unset AIDEVOPS_PERMISSION_GRANT_FILE AIDEVOPS_PERMISSION_REQUEST_ID 2>/dev/null || true
	permission_pending_file=$(_hrw_permission_pending_path "$work_dir" || true)
	if [[ -f "$permission_pending_file" ]] && permission_request_id=$(jq -er \
		--arg issue "${WORKER_ISSUE_NUMBER:-}" \
		--arg session "${WORKER_SESSION_KEY:-}" '
			select(($issue | test("^[1-9][0-9]*$")) and ($session | length > 0))
			| select(.issue == ($issue | tonumber) and .session == $session)
			| .request_id
			| select(type == "string" and length > 0)
		' "$permission_pending_file" 2>/dev/null); then
		export AIDEVOPS_PERMISSION_REQUEST_ID
		AIDEVOPS_PERMISSION_REQUEST_ID="$permission_request_id"
	fi
	return 0
}

_hrw_prepare_permission_grant_path() {
	local repo_slug="$1"
	local issue_number="${WORKER_ISSUE_NUMBER:-}"
	local permission_grant_slug=""
	unset AIDEVOPS_PERMISSION_GRANT_FILE 2>/dev/null || true
	[[ -n "${AIDEVOPS_PERMISSION_REQUEST_ID:-}" && -n "$issue_number" && -n "$repo_slug" ]] || return 0
	permission_grant_slug=$(printf '%s' "$repo_slug" | tr '/:' '__')
	export AIDEVOPS_PERMISSION_GRANT_FILE="${HOME}/.aidevops/permission-grants/${permission_grant_slug}/${issue_number}.json"
	return 0
}

_cmd_run_prepare() {
	local session_key="$1"
	local work_dir="$2"
	local role="${3:-$_HRW_ROLE_WORKER}"
	_WORKER_RUNTIME_LAUNCH_STARTED=0
	unset _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	if _headless_private_workload_enabled; then
		local private_prepare_status=0
		_hrw_prepare_private_workload "$session_key" "$work_dir" \
			"${model_override:-}" "${agent_name:-}" \
			"${private_profile_sha256:-}" || private_prepare_status=$?
		return "$private_prepare_status"
	fi

	_hrw_prepare_role_context "$role" "$work_dir"

	# t2983 Fix C: Worker-role guard — WORKER_WORKTREE_PATH must be set.
	# After GH#21353 (Fix A), the dispatcher never launches a worker when
	# pre-creation fails. If WORKER_WORKTREE_PATH is somehow unset here despite
	# WORKER_ISSUE_NUMBER being set, a dispatcher bug bypassed pre-creation.
	# Abort immediately rather than proceeding in the canonical repo on main.
	if [[ "$role" == "$_HRW_ROLE_WORKER" && -n "${WORKER_ISSUE_NUMBER:-}" && -z "${WORKER_WORKTREE_PATH:-}" ]]; then
		printf '[fatal] WORKER_WORKTREE_PATH unset — pre-creation skipped or failed silently; aborting per t2983 Fix C\n' >&2
		return 1
	fi
	if [[ "$role" == "$_HRW_ROLE_WORKER" ]]; then
		# GH#20542: Export DISPATCH_REPO_SLUG before arming the worker EXIT
		# trap so claim release always has the repository identity available.
		local _prepare_repo_slug=""
		_prepare_repo_slug=$(git -C "$work_dir" remote get-url origin 2>/dev/null |
			sed -E 's|.*github\.com[:/]||; s|\.git$||' || true)
		if [[ -n "$_prepare_repo_slug" ]]; then
			export DISPATCH_REPO_SLUG="$_prepare_repo_slug"
		fi
		_hrw_prepare_permission_grant_path "${DISPATCH_REPO_SLUG:-}"
	fi

	# GH#6538: Acquire a session-key lock to prevent duplicate workers.
	if ! _acquire_session_lock "$session_key"; then
		return 2
	fi
	# shellcheck disable=SC2064
	if [[ "$role" == "$_HRW_ROLE_WORKER" ]]; then
		trap "_exit_trap_handler '$session_key'; aidevops_runtime_bundle_lease_release" EXIT
	else
		trap "_hrw_non_worker_exit_trap '$session_key'" EXIT
	fi
	if ! aidevops_sensitive_temp_root >/dev/null; then
		if [[ "$role" == "$_HRW_ROLE_WORKER" ]]; then
			_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_SENSITIVE_TEMP_PREFLIGHT"
		fi
		print_error "[lifecycle] sensitive_temp_preflight_failed role=${role} before runtime invocation"
		return 86
	fi
	if [[ "$role" == "$_HRW_ROLE_WORKER" ]] && ! _hrw_verify_dispatch_ownership; then
		_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_OWNERSHIP_LOST"
		return 1
	fi

	_WORKER_START_EPOCH_MS=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
	if [[ "$role" == "$_HRW_ROLE_WORKER" ]]; then
		export _WORKER_WORKTREE_PATH="$work_dir"
		WORKER_TARGET_BRANCH=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
		export WORKER_TARGET_BRANCH
		_hrw_claim_worker_worktree "$session_key" "$work_dir" || return 1
	else
		unset _WORKER_WORKTREE_PATH WORKER_TARGET_BRANCH 2>/dev/null || true
	fi

	if [[ "$role" == "$_HRW_ROLE_WORKER" ]]; then
		_register_dispatch_ledger "$session_key" "$work_dir"
		if [[ -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" && -n "${WORKER_ISSUE_NUMBER:-}" && -n "${DISPATCH_REPO_SLUG:-}" ]]; then
			if ! "${SCRIPT_DIR}/dispatch-ledger-helper.sh" ready --session-key "$session_key" \
				--lease-token "$AIDEVOPS_DISPATCH_LEASE_TOKEN" 2>/dev/null; then
				_WORKER_PRELAUNCH_FAILURE_REASON="worker_ledger_ready_failed"
				return 1
			fi
			if ! "${SCRIPT_DIR}/dispatch-claim-helper.sh" transition ready "$WORKER_ISSUE_NUMBER" \
				"$DISPATCH_REPO_SLUG" "$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$session_key" \
				"${AIDEVOPS_DISPATCH_READY_LEASE_TTL:-7200}" 2>/dev/null; then
				_WORKER_PRELAUNCH_FAILURE_REASON="worker_claim_ready_transition_failed"
				return 1
			fi
		fi
	fi
	return 0
}

# shellcheck disable=SC2154 # _run_should_retry, _run_failure_reason set by caller in cmd_run loop
_cmd_run_prepare_retry() {
	local role="$1"
	local session_key="$2"
	local model_override="$3"
	local attempt="$4"
	local max_attempts="$5"
	local selected_model="$6"
	local attempt_exit="$7"
	local provider=""
	local next_model=""

	cmd_run_action="retry"
	cmd_run_next_model="$selected_model"

	if [[ -n "$model_override" || "$attempt" -ge "$max_attempts" ]]; then
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		return "$attempt_exit"
	fi

	if [[ "$_run_should_retry" == "1" ]]; then
		print_warning "Retrying ${selected_model} once after pool account rotation"
		return 0
	fi

	if [[ "$_run_failure_reason" != "auth_error" && "$_run_failure_reason" != "rate_limit" && "$_run_failure_reason" != "startup_no_model_activity" ]]; then
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		return "$attempt_exit"
	fi

	provider=$(extract_provider "$selected_model")
	next_model=$(choose_model "$role" "") || {
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		return "$attempt_exit"
	}
	print_warning "$provider $_run_failure_reason detected; retrying with alternate provider model $next_model"
	cmd_run_action="switch"
	cmd_run_next_model="$next_model"
	return 0
}

_detach_worker() {
	local session_key="$1"
	shift
	local log_file="/tmp/worker-${session_key}.log"
	print_info "Detaching worker (log: $log_file)"
	(
		exec </dev/null >"$log_file" 2>&1
		local -a filtered_args=()
		for arg in "$@"; do
			[[ "$arg" == "--detach" ]] && continue
			filtered_args+=("$arg")
		done
		"$0" run "${filtered_args[@]}"
	) &
	local child_pid=$!
	print_info "Dispatched PID: $child_pid"
	return 0
}

#######################################
# Check whether per-session watchdog stall caps are exceeded.
# Returns: 0 if cap exceeded (caller should kill), 1 if within cap.
#######################################
_stall_session_cap_exceeded() {
	local count="$1"
	local cumulative_s="$2"
	local max_count="${3:-3}"
	local max_cumulative_s="${4:-1800}"

	[[ "$count" -gt "$max_count" ]] && return 0
	[[ "$cumulative_s" -ge "$max_cumulative_s" ]] && return 0
	return 1
}
