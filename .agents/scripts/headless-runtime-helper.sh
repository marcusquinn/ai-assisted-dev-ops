#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# headless-runtime-helper.sh - Model-aware OpenCode wrapper for pulse/workers
#
# Features:
#   - Alternates between configured headless providers/models
#   - Persists OpenCode session IDs per provider + session key
#   - Records backoff state per model (rate limits) or per provider (auth errors)
#   - Clears backoff automatically when auth changes or retry windows expire
#   - NOTE: opencode/* gateway models are NOT used (per-token billing, too expensive)
#
# Stable utility functions (state DB, provider auth, backoff, output parsing,
# metrics, sandbox, contract, watchdog, model choice, cmd builders) live in
# headless-runtime-lib.sh — sourced below. This file is the thin orchestrator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
# shellcheck source=./runtime-bundle-lease.sh
source "${SCRIPT_DIR}/runtime-bundle-lease.sh"
if ! aidevops_runtime_bundle_lease_acquire "${SCRIPT_DIR%/scripts}"; then
	printf "[headless-runtime] FATAL: could not acquire runtime bundle lease for %s\n" "${SCRIPT_DIR%/scripts}" >&2
	exit 1
fi
trap 'aidevops_runtime_bundle_lease_release' EXIT
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./worker-lifecycle-common.sh
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"
# Worker failure excerpts own their capped write and duplicate-evidence
# retention contract in a focused module.
# shellcheck source=./worker-failure-evidence.sh
source "${SCRIPT_DIR}/worker-failure-evidence.sh"

# SSH agent integration for commit signing (t1882)
# Source persisted agent.env so workers can sign commits without passphrase prompts.
if [[ -f "$HOME/.ssh/agent.env" ]]; then
	# shellcheck source=/dev/null
	. "$HOME/.ssh/agent.env" >/dev/null 2>&1 || true
fi

# Absolute fallback when both pool and routing table are unavailable (GH#17769)
readonly DEFAULT_HEADLESS_MODELS="anthropic/claude-sonnet-4-6"
readonly STATE_DIR="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
readonly STATE_DB="${STATE_DIR}/state.db"
readonly OPENCODE_BIN_DEFAULT="${OPENCODE_BIN:-opencode}"
# Linux headless dispatch may bind this to an aidevops-managed exact-version
# runtime without mutating the general/interactive OpenCode installation.
HEADLESS_OPENCODE_BIN="$OPENCODE_BIN_DEFAULT"
readonly SANDBOX_EXEC_HELPER="${SCRIPT_DIR}/sandbox-exec-helper.sh"
readonly DISPATCH_LEDGER_HELPER="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
readonly OAUTH_POOL_HELPER="${SCRIPT_DIR}/oauth-pool-helper.sh"
# Full-loop workers checkpoint after 120 minutes. The three-hour default leaves
# one hour for a graceful handoff, while the six-hour cap stays aligned with the
# detached lifecycle observer's final safety fuse.
readonly HEADLESS_SANDBOX_TIMEOUT_BASE_DEFAULT=10800
readonly HEADLESS_SANDBOX_TIMEOUT_MAX=21600
_headless_sandbox_timeout_resolved="${AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT:-$HEADLESS_SANDBOX_TIMEOUT_BASE_DEFAULT}"
if [[ ! "$_headless_sandbox_timeout_resolved" =~ ^[1-9][0-9]*$ ]]; then
	_headless_sandbox_timeout_resolved="$HEADLESS_SANDBOX_TIMEOUT_BASE_DEFAULT"
elif ((_headless_sandbox_timeout_resolved > HEADLESS_SANDBOX_TIMEOUT_MAX)); then
	_headless_sandbox_timeout_resolved="$HEADLESS_SANDBOX_TIMEOUT_MAX"
fi
readonly HEADLESS_SANDBOX_TIMEOUT_DEFAULT="$_headless_sandbox_timeout_resolved"
unset _headless_sandbox_timeout_resolved
readonly OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"
readonly LOCK_DIR="${STATE_DIR}/locks"
readonly METRICS_DIR="${HOME}/.aidevops/logs"
readonly METRICS_FILE="${AIDEVOPS_HEADLESS_METRICS_FILE:-${METRICS_DIR}/headless-runtime-metrics.jsonl}"
readonly RESOURCE_METRICS_HELPER="${SCRIPT_DIR}/resource-metrics-helper.sh"
readonly RESOURCE_METRICS_FILE="${AIDEVOPS_RESOURCE_METRICS_FILE:-${METRICS_DIR}/resource-metrics.jsonl}"
readonly PRIVATE_OUTPUT_FILTER="${SCRIPT_DIR}/headless-private-output-filter.py"
readonly HEADLESS_ROLE_TRIAGE="triage"
readonly HEADLESS_ROLE_MODEL_REPLAY="model-replay"
readonly HEADLESS_EGRESS_MODE_AUTO="auto"
readonly HEADLESS_EGRESS_MODE_REQUIRED="required"

# Resolve the public-triage whole-process egress posture. Triage always uses at
# least auto mode: a configured backend becomes fail-closed required mode, while
# an absent backend retains the no-tools, isolated-runtime boundary. Operators
# can require a backend globally with AIDEVOPS_WORKER_EGRESS_MODE=required;
# setting the generic mode to off never disables triage's capability probe.
# Arguments: $1=requested mode, $2=configured backend path (possibly empty).
# Output: auto|required. Returns 1 for an invalid requested mode.
_resolve_public_triage_egress_mode() {
	local requested_mode="$1"
	local configured_backend="$2"

	case "$requested_mode" in
	required)
		printf '%s' "$HEADLESS_EGRESS_MODE_REQUIRED"
		return 0
		;;
	auto | off)
		if [[ -n "$configured_backend" ]]; then
			printf '%s' "$HEADLESS_EGRESS_MODE_REQUIRED"
		else
			printf '%s' "$HEADLESS_EGRESS_MODE_AUTO"
		fi
		return 0
		;;
	*) return 1 ;;
	esac
}

# The clean environment and isolated HOME remain mandatory for public triage
# even when whole-process egress runs in capability-aware auto mode.
# Arguments: $1=runtime role, $2=private-workload flag, $3=egress mode.
# Returns 0 when the sandbox launcher is mandatory, 1 otherwise.
_headless_opencode_sandbox_required() {
	local runtime_role="$1"
	local private_workload="$2"
	local egress_mode="$3"

	if [[ "$private_workload" -eq 1 || "$runtime_role" == "$HEADLESS_ROLE_TRIAGE" ||
		"$runtime_role" == "$HEADLESS_ROLE_MODEL_REPLAY" ||
		"$egress_mode" == "$HEADLESS_EGRESS_MODE_REQUIRED" ]]; then
		return 0
	fi
	return 1
}

# Launch preparation helpers (prompt transport, argument parsing, worker-env
# validation, deleted-cwd recovery, and recoverable OpenCode startup errors).
# shellcheck source=./headless-runtime-launch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-launch.sh"

# Source the stable utility library (t2013 split).
# All state DB, provider auth, backoff, output parsing, metrics, sandbox,
# worker contract, watchdog, DB merge, dispatch ledger, failure reporting,
# canary, model choice, and cmd builder functions live here.
# shellcheck source=./headless-runtime-lib.sh
source "${SCRIPT_DIR}/headless-runtime-lib.sh"

# CLI subcommand handlers (cmd_select, cmd_backoff, cmd_session, cmd_metrics).
# Extracted to reduce orchestrator line count below the file-size-debt threshold.
# shellcheck source=./headless-runtime-helper-cmds.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-helper-cmds.sh"

# Orphan-recovery helpers: _attempt_orphan_recovery_pr used by _handle_worker_branch_orphan
# shellcheck source=./shared-claim-lifecycle.sh
source "${SCRIPT_DIR}/shared-claim-lifecycle.sh"

# Worker lifecycle helpers (auth rotation, rate-limit monitor, Claude invocation,
# output preservation, orphan recovery, run prepare/finish, detach, stall cap).
# Extracted to keep this orchestrator below the file-size-debt threshold.
# shellcheck source=./headless-runtime-worker.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker.sh"
# shellcheck source=./vault-data-policy-helper.sh
source "${SCRIPT_DIR}/vault-data-policy-helper.sh"

# Focused OpenCode invocation phases used by _invoke_opencode below.
# shellcheck source=./headless-runtime-invoke.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-invoke.sh"

# Focused result-classification phases used by _handle_run_result below.
# shellcheck source=./headless-runtime-result.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-result.sh"

# Focused setup, retry, diagnostics, and metric phases for run attempts.
# shellcheck source=./headless-runtime-attempt.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-attempt.sh"

# Focused environment, dispatch, continuation, and retry phases for cmd_run.
# shellcheck source=./headless-runtime-run.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-run.sh"

# Activity watchdog timeout — used by _invoke_opencode and the inline watchdog fallback.
# Keep this aligned with worker-activity-watchdog.sh and headless-runtime-lib.sh.
# OpenAI/GPT-5.x workers can spend several minutes reasoning without emitting
# additional JSON/log output; 300s caused false no-output kills before workers
# reached implementation/PR creation (GH#22248).
HEADLESS_ACTIVITY_TIMEOUT_SECONDS="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-600}"

# =============================================================================
# Runtime invocation — OpenCode and Claude CLI
# =============================================================================

# Finalize one isolated OpenCode data directory. Public triage and protected
# private workloads discard the complete session graph; ordinary workers keep
# the established verified merge/recovery lifecycle.
_finalize_isolated_runtime_data() {
	local isolated_data_dir="$1"
	local runtime_role="$2"
	local ephemeral_run=0
	[[ -n "$isolated_data_dir" && -d "$isolated_data_dir" ]] || return 0
	if _headless_run_is_ephemeral "$runtime_role"; then
		ephemeral_run=1
		print_info "[lifecycle] ephemeral_db_discarded role=$runtime_role pid=$$"
	else
		if ! _replay_preserved_worker_dbs; then
			print_warning "[lifecycle] db_merge_recovery_replay_incomplete pid=$$"
		fi
		if _merge_worker_db "$isolated_data_dir"; then
			print_info "[lifecycle] db_merged dir=$isolated_data_dir pid=$$"
		else
			print_warning "[lifecycle] db_merge_failed dir=$isolated_data_dir pid=$$"
			if ! _preserve_failed_worker_db "$isolated_data_dir"; then
				print_warning "[lifecycle] db_merge_recovery_failed dir=$isolated_data_dir pid=$$"
			fi
		fi
	fi
	local cleanup_failed=0
	rm -rf "$isolated_data_dir" 2>/dev/null || cleanup_failed=1
	[[ ! -e "$isolated_data_dir" ]] || cleanup_failed=1
	unset XDG_DATA_HOME
	if [[ "$ephemeral_run" -eq 1 ]]; then
		unset XDG_CACHE_HOME XDG_CONFIG_HOME XDG_STATE_HOME
		unset OPENCODE_DISABLE_DEFAULT_PLUGINS OPENCODE_PURE
		unset OPENCODE_DISABLE_EXTERNAL_SKILLS
		unset OPENCODE_DISABLE_CLAUDE_CODE_SKILLS
	fi
	_WORKER_ISOLATED_DB_PATH=""
	if [[ "$cleanup_failed" -ne 0 ]]; then
		print_warning "[lifecycle] db_cleanup_failed dir=$isolated_data_dir pid=$$ guardian=retained"
		return 1
	fi
	print_info "[lifecycle] db_cleanup dir=$isolated_data_dir pid=$$"
	return 0
}

# _invoke_opencode: run the opencode command (with or without sandbox) and capture output.
# Args: output_file exit_code_file cmd_args (null-delimited, read from stdin via process sub)
# Caller passes the cmd array elements as positional args after the two file args.
# Returns: 0 always (exit code written to exit_code_file).
#
# Includes an activity watchdog. The timeout is a recovery backstop, not a
# success/failure policy: output-active, CPU-active, and CI-wait states are
# allowed to continue; the hard elapsed threshold applies only after a confirmed
# output stall. Explicit provider failures still recover promptly. Default is
# 600s because OpenAI/GPT-5.x
# workers can spend several minutes reasoning before emitting more JSON/log
# output; 300s caused false no-output kills before implementation/PR creation.
_invoke_opencode() {
	local output_file="$1"
	local exit_code_file="$2"
	shift 2
	local -a cmd=("$@")
	local private_workload=0
	local runtime_role="${_invoke_role:-worker}"
	local public_triage=0
	local public_triage_auth_ready=0
	local isolated_data_dir=""
	local isolated_home_dir=""
	local isolated_data_precreated=0
	_invoke_opencode_validate_context || return 0
	_invoke_opencode_prepare_isolation || return 0

	local worker_pid=""
	local watchdog_pid=""
	local _rl_monitor_pid=""
	_invoke_opencode_launch_worker
	_invoke_opencode_start_monitors
	print_info "[lifecycle] waiting_for_worker pid=$worker_pid watchdog=$watchdog_pid"
	local _wait_status=0
	wait "$worker_pid" 2>/dev/null || _wait_status=$?
	if [[ -n "${exit_code_file:-}" ]]; then
		printf '%s' "$_wait_status" >"${exit_code_file}.wait_status" 2>/dev/null || true
	fi
	local _kill_reason
	_kill_reason=$(classify_worker_kill_reason "$exit_code_file" "$_wait_status")
	print_info "[lifecycle] worker_exited pid=$worker_pid wait_status=$_wait_status kill_reason=$_kill_reason"
	_invoke_opencode_cleanup_monitors
	_invoke_opencode_finalize_data
	return 0
}

# =============================================================================
# Result handling and run execution
# =============================================================================

# _handle_run_result: process output_file after opencode exits.
# Args: exit_code output_file role provider session_key selected_model
# Sets caller variable _run_failure_reason on failure.
# Returns: 0 success, 75 no-activity backoff, 77 premature exit, non-zero on failure.
_store_headless_session_if_allowed() {
	local provider="$1"
	local session_key="$2"
	local session_id="$3"
	local selected_model="$4"
	local role="$5"
	if _headless_run_is_ephemeral "$role"; then
		return 0
	fi
	store_session_id "$provider" "$session_key" "$session_id" "$selected_model"
	return $?
}

_private_output_has_task_complete() {
	local output_file="$1"
	if [[ -f "$output_file" ]] && grep -qF '"text":"TASK_COMPLETE"' "$output_file"; then
		return 0
	fi
	return 1
}

_private_workload_exit_trap() {
	local session_key="$1"
	local workload_lock_key="${2:-}"
	local cleanup_status=0
	if declare -F _cleanup_headless_runtime_temp_paths >/dev/null 2>&1; then
		_cleanup_headless_runtime_temp_paths || cleanup_status=$?
	fi
	_release_session_lock "$session_key" || true
	if [[ -n "$workload_lock_key" ]]; then
		_release_private_workload_lock "$workload_lock_key" || true
	fi
	_PRIVATE_WORKLOAD_LOCK_KEY=""
	if declare -F aidevops_runtime_bundle_lease_release >/dev/null 2>&1; then
		aidevops_runtime_bundle_lease_release || true
	fi
	trap - EXIT
	return "$cleanup_status"
}

_handle_run_result() {
	local exit_code="$1"
	local output_file="$2"
	local role="$3"
	local provider="$4"
	local session_key="$5"
	local selected_model="$6"
	local work_dir="${7:-${_WORKER_WORKTREE_PATH:-}}"
	local suppress_persistent_output=0
	if _headless_run_is_ephemeral "$role"; then
		suppress_persistent_output=1
	fi
	local discovered_session="" activity_detected=""
	_initialize_run_result
	local result_status=0
	if _run_result_has_permission_event; then
		_handle_run_result_permission_event || result_status=$?
		return "$result_status"
	fi
	if [[ "$exit_code" == "0" ]]; then
		if [[ "$activity_detected" != "1" ]]; then
			_handle_run_result_no_activity || result_status=$?
		else
			_handle_run_result_success_output || result_status=$?
		fi
		return "$result_status"
	fi

	local failure_reason=""
	local _run_result_handled_exit=""
	if [[ "$exit_code" == "124" ]]; then
		_classify_watchdog_run_result
	else
		_classify_signal_run_result
	fi
	[[ -z "$_run_result_handled_exit" ]] || return "$_run_result_handled_exit"
	_copy_run_failure_classification
	_handle_transient_run_result
	[[ -z "$_run_result_handled_exit" ]] || return "$_run_result_handled_exit"
	_finish_failed_run_result || result_status=$?
	return "$result_status"
}

# t3077: module-level marker — set to "1" by
# _t3077_setup_fix_the_fixer_observability when the linked issue carries the
# `fix-the-fixer` label. Read by the worker_started lifecycle emit so the
# checkpoint records whether extra observability was applied for this run.
_T3077_FIX_THE_FIXER="${_T3077_FIX_THE_FIXER:-0}"

#######################################
# t3077 — _t3077_setup_fix_the_fixer_observability
#
# Detect the `fix-the-fixer` label on the linked issue and, when present,
# enable extra observability for this worker dispatch:
#   - AIDEVOPS_VERBOSE_LIFECYCLE=1     — extra checkpoint emits in worker log
#   - AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1 — fail-fast preflight check
#   - HEADLESS_ACTIVITY_TIMEOUT_SECONDS=180 — tighter watchdog (vs 600s)
#
# Detection runs once at worker start (one extra REST hit, ~50ms). Fail-open
# everywhere — missing args / API failure / unlabeled issue all fall through
# without modifying the worker's environment. The deterministic t2819
# detector (tier:thinking elevation) remains the primary safety net.
#
# Args:
#   $1 - issue number (from WORKER_ISSUE_NUMBER env, may be empty)
#   $2 - repo slug (from DISPATCH_REPO_SLUG env, may be empty)
# Returns: 0 always (fail-open contract)
#######################################
_t3077_setup_fix_the_fixer_observability() {
	local issue_number="$1"
	local repo_slug="$2"

	# Fail-open guard: missing args = no detection, no observability changes.
	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 0
	fi
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 0
	fi

	# Best-effort label probe via dispatch-dedup-helper.sh (defined above).
	# The helper itself is fail-conservative — its stdout is `labeled` on a
	# match and any other token (or empty) on miss / API failure. We compare
	# only against the positive token to keep the literal usage minimal
	# (codebase ratchet flags repeated string literals).
	local _t3077_match_token="labeled"
	local label_state=""
	if command -v dispatch-dedup-helper.sh >/dev/null 2>&1; then
		label_state=$(dispatch-dedup-helper.sh has-fix-the-fixer-label \
			"$issue_number" "$repo_slug" 2>/dev/null) || label_state=""
	elif [[ -x "${SCRIPT_DIR}/dispatch-dedup-helper.sh" ]]; then
		label_state=$("${SCRIPT_DIR}/dispatch-dedup-helper.sh" has-fix-the-fixer-label \
			"$issue_number" "$repo_slug" 2>/dev/null) || label_state=""
	fi

	if [[ "$label_state" != "$_t3077_match_token" ]]; then
		return 0
	fi

	# Label present — apply the observability triple.
	export AIDEVOPS_VERBOSE_LIFECYCLE=1
	export AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1
	export HEADLESS_ACTIVITY_TIMEOUT_SECONDS=180
	_T3077_FIX_THE_FIXER=1

	print_info "[lifecycle] fix_the_fixer_observability_enabled issue=#${issue_number} repo=${repo_slug} watchdog=180s pid=$$"
	return 0
}

#######################################
# t3077 — _t3077_write_preflight_sentinel
#
# When AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1, write a sentinel file before
# the model is invoked. Verifies that the worker's filesystem is writable —
# a sandbox/FD-broken environment that fails this write would otherwise
# burn tokens on a session that cannot persist work.
#
# Sentinel path: ~/.aidevops/cache/worker-preflight/<pid>.txt
# On write failure, returns 1 — caller aborts dispatch with exit code 11.
# When AIDEVOPS_WORKER_PREFLIGHT_SENTINEL is unset/empty, returns 0 (no-op).
#
# Returns: 0 success or no-op, 1 on write failure (caller aborts)
#######################################
_t3077_write_preflight_sentinel() {
	if [[ "${AIDEVOPS_WORKER_PREFLIGHT_SENTINEL:-}" != "1" ]]; then
		return 0
	fi

	local sentinel_dir="${HOME}/.aidevops/cache/worker-preflight"
	local sentinel_path="${sentinel_dir}/$$.txt"

	if ! mkdir -p "$sentinel_dir" 2>/dev/null; then
		return 1
	fi

	if ! printf 'pid=%s\nstarted_at=%s\nissue=%s\nrepo=%s\n' \
		"$$" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')" \
		"${WORKER_ISSUE_NUMBER:-unknown}" \
		"${DISPATCH_REPO_SLUG:-unknown}" \
		>"$sentinel_path" 2>/dev/null; then
		return 1
	fi

	# Verify the write actually persisted (catches silent FD failures).
	[[ -s "$sentinel_path" ]] || return 1
	return 0
}

#######################################
# Derive structured, secret-free worker failure evidence fields.
#
# Args:
#   $1 - result label
#   $2 - exit code
#   $3 - activity flag (1/0)
#   $4 - kill reason
#   $5 - failure reason
# stdout: tab-delimited launch_failure_cause and next_action
# Returns: 0 always
#######################################
_derive_worker_failure_evidence() {
	local result_label="$1"
	local exit_code="$2"
	local activity="$3"
	local kill_reason="$4"
	local failure_reason="$5"
	local launch_failure_cause=""
	local next_action="inspect_failure_excerpt"

	if declare -F _worker_failure_reason_is_completion_infrastructure >/dev/null 2>&1 &&
		_worker_failure_reason_is_completion_infrastructure "$failure_reason"; then
		launch_failure_cause="$failure_reason"
		next_action="resume_session_with_completion_contract"
		printf '%s\t%s\n' "$launch_failure_cause" "$next_action"
		return 0
	fi

	case "$result_label" in
	no_activity | watchdog_startup_continue)
		launch_failure_cause="startup_no_model_activity"
		next_action="retry_fresh_or_inspect_local_runtime"
		;;
	premature_exit)
		launch_failure_cause="model_stopped_before_completion"
		next_action="resume_session_with_completion_contract"
		;;
	watchdog_stall_continue | service_interruption_continue | service_interruption_exhausted | signal_killed_continue)
		launch_failure_cause="mid_session_interruption"
		next_action="resume_existing_session"
		;;
	local_kill)
		launch_failure_cause="local_kill"
		next_action="inspect_local_kill_source"
		;;
	signal_terminated_continue)
		launch_failure_cause="signal_terminated"
		next_action="resume_existing_session"
		;;
	watchdog_stall_killed)
		launch_failure_cause="stall_hard_killed"
		next_action="redispatch_worker"
		;;
	rate_limit | rate_limit_fast)
		launch_failure_cause="provider_rate_limited"
		next_action="rotate_provider_or_wait_for_reset"
		;;
	access_denied)
		launch_failure_cause="provider_access_denied"
		next_action="switch_provider_or_check_access"
		;;
	blocked | brief_recovery)
		launch_failure_cause="model_reported_blocker"
		next_action="recover_brief_or_escalate_with_evidence"
		;;
	success)
		launch_failure_cause=""
		next_action="none"
		;;
	*)
		if [[ "${exit_code:-}" == "124" ]]; then
			launch_failure_cause="watchdog_timeout"
			next_action="inspect_watchdog_and_runtime_logs"
		elif [[ "${exit_code:-}" == "137" || "${exit_code:-}" == "143" ]]; then
			launch_failure_cause="signal_terminated"
			next_action="inspect_host_or_watchdog_kill_source"
		elif [[ "${exit_code:-}" != "0" ]]; then
			launch_failure_cause="local_runtime_error"
			next_action="inspect_failure_excerpt_and_retry_if_transient"
		fi
		;;
	esac

	if [[ -n "$kill_reason" && "$kill_reason" != "natural" && "$kill_reason" != "unknown" ]]; then
		launch_failure_cause="${launch_failure_cause:-$kill_reason}"
	fi
	if [[ -z "$launch_failure_cause" && -n "$failure_reason" ]]; then
		launch_failure_cause="$failure_reason"
	fi
	if [[ "$activity" != "1" && -z "$launch_failure_cause" && "$result_label" != "success" ]]; then
		launch_failure_cause="no_activity_before_exit"
	fi

	printf '%s\t%s' "$launch_failure_cause" "$next_action"
	return 0
}

#######################################
# Return success when a hard-killed worker already handed off an open PR.
#
# This guards worker-failure metrics before the later claim-release recovery path
# runs. A watchdog hard-kill after PR creation is a monitoring handoff when the
# canonical lifecycle classifier confirms the exact-head durable PR. CI state
# determines later monitoring/repair; it does not redefine handoff existence.
#
# Args:
#   $1 - session key
#   $2 - work dir
# Returns: 0 when an exact-head, non-draft open PR has a merge summary.
#######################################
_worker_post_pr_handoff_confirmed() {
	local session_key="$1"
	local work_dir="$2"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local branch_name
	local local_head
	local issue_number="${session_key#issue-}"

	[[ "$session_key" == issue-* ]] || return 1
	[[ -n "$repo_slug" ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1
	if [[ -n "$work_dir" && -d "$work_dir" ]]; then
		branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
		local_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || true)
		[[ "$branch_name" == "HEAD" ]] && branch_name=""
	fi

	[[ -n "$branch_name" && -n "$local_head" ]] || return 1
	local handoff_state=""
	handoff_state=$(_pr_handoff_state_for_branch_or_issue \
		"$branch_name" "$issue_number" "$repo_slug" "head-only" "$local_head" "1") || return 1
	[[ "${handoff_state%%|*}" == "ready" ]]
	return $?
}

#######################################
# Append a context-rich metric when service-interruption continuation budget is exhausted.
#
# Args:
#   $1 - role
#   $2 - session key
#   $3 - selected model
#   $4 - work dir
#   $5 - failure reason
#   $6 - output excerpt path
#   $7 - session id
# Returns: 0 always (observability must fail open)
#######################################
_append_service_interruption_exhausted_metric() {
	local role="$1"
	local session_key="$2"
	local selected_model="$3"
	local work_dir="$4"
	local failure_reason="$5"
	local output_file="$6"
	local session_id="$7"
	local result_label="service_interruption_exhausted"
	local provider
	provider=$(extract_provider "$selected_model")
	local evidence_fields launch_failure_cause next_action
	evidence_fields=$(_derive_worker_failure_evidence "$result_label" "81" "1" "" "$failure_reason")
	launch_failure_cause="${evidence_fields%%$'\t'*}"
	next_action="${evidence_fields#*$'\t'}"
	append_runtime_metric "$role" "$session_key" "$selected_model" \
		"$provider" \
		"$result_label" "81" "${failure_reason:-provider_error}" "1" "0" \
		"${WORKER_ISSUE_NUMBER:-}" "${DISPATCH_REPO_SLUG:-}" "$work_dir" "$output_file" "$session_id" \
		"${_run_provider_error_type:-}" "${_run_provider_status:-}" "${_run_runtime_error_type:-}" "${_run_classification_source:-}" "${_run_classification_pattern:-}" \
		"$launch_failure_cause" "${_metric_kill_reason:-}" "$next_action"
	return 0
}

#######################################
# Normalize a worker exit code and its metric kill reason.
#
# Args:
#   $1 - exit code file path
#   $2 - exit code read from the runtime process
# stdout: tab-delimited normalized exit code and kill reason
# Returns: 0 always (diagnostics must fail open)
#######################################
_normalize_worker_exit_code_and_kill_reason() {
	local exit_code_file="$1"
	local exit_code="$2"
	local metric_kill_reason=""
	if [[ ! "${exit_code:-}" =~ ^[0-9]+$ ]]; then
		exit_code=1
	fi

	metric_kill_reason=$(classify_worker_kill_reason "$exit_code_file" "$exit_code" 2>/dev/null || true)
	if [[ -f "${exit_code_file}.watchdog_killed" ]]; then
		exit_code=124
		rm -f "${exit_code_file}.watchdog_killed"
	fi
	if [[ "${exit_code:-}" == "0" && "$metric_kill_reason" != "natural" ]]; then
		exit_code=124
	fi

	printf '%s\t%s' "$exit_code" "$metric_kill_reason"
	return 0
}

# _execute_run_attempt: run one headless invocation and handle the result.
# Dispatches to OpenCode (default) or Claude CLI (when --runtime claude specified).
# Args: role session_key work_dir title prompt selected_model variant_override agent_name
#       extra_args (array passed as remaining positional args after the named ones)
# Reads caller variable headless_runtime (set by _parse_run_args --runtime flag).
# Prints the discovered session ID to stdout on success (may be empty).
# Returns: 0 success, 75 no-activity backoff, non-zero on failure.
# Sets caller variable _run_failure_reason on failure.
_execute_run_attempt() {
	local role="$1"
	local session_key="$2"
	local work_dir="$3"
	local title="$4"
	local prompt="$5"
	local selected_model="$6"
	local variant_override="$7"
	local agent_name="$8"
	shift 8
	local -a extra_args=("$@")
	_begin_worker_runtime_run
	local runtime=""
	local prompt_arg="$prompt" prompt_file_arg="" claude_stdin_file="" force_file_transport=0
	local provider="" persisted_session="" metric_work_dir=""
	local -a cmd=()
	local prepare_status=0
	_prepare_run_attempt_command || prepare_status=$?
	[[ "$prepare_status" -eq 0 ]] || return "$prepare_status"

	# GH#17549: Claim guard — verify a DISPATCH_CLAIM exists for this runner
	# before launching a worker for an issue. This prevents pulse LLMs from
	# bypassing dispatch_with_dedup() by calling headless-runtime-helper directly.
	# GH#17549: Export repo slug for _release_dispatch_claim on failure.
	# The claim guard was removed — it checked for DISPATCH_CLAIM nonce= comments
	# but dispatch_with_dedup posts "Dispatching worker" comments instead (GH#15317).
	# The mismatch caused the guard to reject every legitimate dispatch, creating
	# a claim→reject→release→reclaim loop. dispatch_with_dedup is the authoritative
	# dedup layer; a second check here adds no safety and causes false rejections.
	# GH#20542: DISPATCH_REPO_SLUG export moved to _cmd_run_prepare (called
	# before the EXIT trap is armed) so _release_dispatch_claim always has a
	# non-empty slug. The role+session_key guard here is no longer needed —
	# _cmd_run_prepare sets the slug for all roles unconditionally.

	local output_file="" exit_code_file="" exit_code=0 permission_request_file=""
	local start_ms=0 end_ms=0 duration_ms=0
	local resource_stop_file="" resource_result_file="" resource_sampler_pid=""
	local _metric_kill_reason=""
	local _t3077_watcher_pid="" _normalized_exit_info=""
	local _run_watchdog_hard_killed=0 _stall_killed_marker="" _rl_fast_sentinel=""
	prepare_status=0
	_create_run_attempt_files || prepare_status=$?
	[[ "$prepare_status" -eq 0 ]] || return "$prepare_status"
	prepare_status=0
	_configure_run_attempt_context || prepare_status=$?
	[[ "$prepare_status" -eq 0 ]] || return "$prepare_status"
	if [[ "$role" == "worker" ]] && ! _hrw_verify_dispatch_ownership; then
		_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_OWNERSHIP_LOST"
		print_error "[lifecycle] runtime ownership fence stopped session=${session_key} before model invocation"
		return 85
	fi
	_start_run_attempt_observers
	_hrw_mark_runtime_launch_started "$session_key" "$runtime"
	_emit_verbose_checkpoint worker_started \
		"model=${selected_model} runtime=${runtime} fix_the_fixer=${_T3077_FIX_THE_FIXER:-0}"
	print_info "[lifecycle] worker_start session=$session_key model=$selected_model runtime=$runtime pid=$$"
	case "$runtime" in
	claude) _invoke_claude "$output_file" "$exit_code_file" "$work_dir" "${cmd[@]}" ;;
	*) _invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}" ;;
	esac
	_complete_run_attempt_invocation

	_retry_run_attempt_fresh_database || return $?

	_retry_run_attempt_without_stale_session || return $?

	if [[ -f "$_rl_fast_sentinel" ]]; then
		local rate_limit_status=0
		_finish_run_attempt_rate_limit_fast || rate_limit_status=$?
		return "$rate_limit_status"
	fi

	local _metric_session_id="" _metric_output_file="" _metric_excerpt_candidate=""
	_append_run_attempt_diagnostics
	local handle_status=0
	_finish_run_attempt_result || handle_status=$?
	return "$handle_status"
}

# =============================================================================
# Run lifecycle — prepare, finish, retry, detach
# =============================================================================

#######################################
# _discover_actual_worktree_dir — find the worktree a worker actually used (t2982)
#
# Scans git worktree list --porcelain from the repo root of <work_dir> for a
# worktree whose branch ref matches gh-?<issue_number>. Used to fix Mode B/C
# worker misclassification (work_dir stuck on main after worker moved to own
# worktree or merged its PR).
#
# Args: $1=work_dir  $2=issue_number
# Echoes the discovered path if found and it is a directory; nothing otherwise.
# Always returns 0 — caller falls back to work_dir on empty output.
#######################################
_discover_actual_worktree_dir() {
	local work_dir="$1"
	local issue_n="$2"
	if [[ -z "$work_dir" || -z "$issue_n" ]]; then
		return 0
	fi
	local repo_root=""
	repo_root=$(git -C "$work_dir" rev-parse --show-toplevel 2>/dev/null) || repo_root="$work_dir"
	local found_path=""
	# Single-line awk keeps $2 refs inside the single-quote on the same line,
	# preventing the positional-param ratchet from flagging awk field refs.
	# shellcheck disable=SC2016
	found_path=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null |
		awk -v n="$issue_n" '/^worktree / { p=$2 } /^branch / && $2 ~ "gh-?" n { print p; exit }')
	if [[ -n "$found_path" && -d "$found_path" ]]; then
		printf '%s' "$found_path"
	fi
	return 0
}

# =============================================================================
# Stall cap helper (GH#20681)
# =============================================================================

# =============================================================================
# Main run orchestrator
# =============================================================================

_run_role_safe_canary() {
	local role="$1"
	local selected_model="$2"
	if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" || "$role" == "$HEADLESS_ROLE_MODEL_REPLAY" ]] &&
		! _headless_private_workload_enabled; then
		print_info "[lifecycle] generic_canary_skipped role=$role boundary=public-triage pid=$$"
		return 0
	fi
	_run_canary_test "$selected_model"
	return $?
}

cmd_run() {
	local role="worker"
	local session_key=""
	local work_dir=""
	local title=""
	local prompt=""
	local prompt_file=""
	local model_override=""
	local initial_model=""
	local tier_override=""
	local variant_override=""
	local agent_name=""
	local headless_runtime=""
	local detach=0
	local private_workload="${AIDEVOPS_PRIVATE_WORKLOAD:-0}"
	local private_profile_sha256=""
	local -a extra_args=()

	_parse_run_args "$@" || return 1
	_validate_run_args || return 1
	_validate_private_workload_args || return 1
	_validate_model_replay_args || return 1
	local _cmd_run_stop=0 _cmd_run_return_status=1
	_prepare_cmd_run_environment "$@" || return $?
	[[ "$_cmd_run_stop" -eq 0 ]] || return "$_cmd_run_return_status"
	# Dynamically scoped into _cmd_run_finish for role-safe cleanup.
	local _CMD_RUN_ROLE="$role"
	if [[ "$role" == "worker" ]]; then
		# GH#23520: caller-local exports survive every extracted phase without
		# leaking worker authority after cmd_run returns.
		local _worker_session_origin
		_worker_session_origin="${AIDEVOPS_SESSION_ORIGIN:-worker}"
		local AIDEVOPS_SESSION_ORIGIN
		AIDEVOPS_SESSION_ORIGIN="$_worker_session_origin"
		export AIDEVOPS_SESSION_ORIGIN
		local _worker_headless_marker
		_worker_headless_marker="${AIDEVOPS_HEADLESS:-true}"
		local AIDEVOPS_HEADLESS
		AIDEVOPS_HEADLESS="$_worker_headless_marker"
		export AIDEVOPS_HEADLESS
	fi
	_prepare_cmd_run_worker_identity || return $?
	local selected_model=""
	_select_cmd_run_model || return $?

	_prepare_cmd_run_dispatch || return $?
	[[ "$_cmd_run_stop" -eq 0 ]] || return "$_cmd_run_return_status"
	_cmd_run_attempt_loop
	return $?
}

cmd_canary() {
	local role="worker"
	local model_override=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--role)
			role="${2:-}"
			shift 2
			;;
		--model)
			model_override="${2:-}"
			shift 2
			;;
		--tier)
			# Accepted for call-site clarity; the dispatcher resolves the
			# concrete model before invoking this preflight.
			shift 2
			;;
		*)
			print_error "Unknown option for canary: $arg"
			return 1
			;;
		esac
	done
	if [[ "$role" == "$HEADLESS_ROLE_MODEL_REPLAY" ]]; then
		print_error "The model-replay role is supported only by the run command"
		return 1
	fi

	local selected_model
	selected_model=$(choose_model "$role" "$model_override") || return $?
	_enforce_opencode_version_pin || return $?
	_run_canary_test "$selected_model"
	return $?
}

# =============================================================================
# Help and main entry point
# =============================================================================

show_help() {
	cat <<'EOF'
headless-runtime-helper.sh - Model-aware headless runtime (OpenCode default, Claude CLI opt-in)

Usage:
  headless-runtime-helper.sh select [--role pulse|worker|triage] [--model provider/model]
  headless-runtime-helper.sh canary [--role pulse|worker|triage] [--model provider/model] [--tier simple|standard|thinking]
  headless-runtime-helper.sh run --role pulse|worker|triage|model-replay --session-key KEY --dir PATH --title TITLE (--prompt TEXT | --prompt-file FILE) [--model provider/model | --initial-model provider/model] [--tier simple|standard|thinking] [--variant NAME] [--agent NAME] [--runtime opencode|claude] [--opencode-arg ARG] [--private-workload --private-profile-sha256 HASH] [--detach]
  headless-runtime-helper.sh backoff [status|set MODEL-OR-PROVIDER REASON [SECONDS]|clear MODEL-OR-PROVIDER]
  headless-runtime-helper.sh session [status|clear PROVIDER SESSION_KEY]
  headless-runtime-helper.sh metrics [--role pulse|worker|triage] [--hours N] [--model SUBSTRING] [--fast-threshold N]
  headless-runtime-helper.sh help

Runtime selection:
  Default runtime is OpenCode. Use --runtime claude to dispatch via Claude CLI.
  Claude CLI headless uses `claude -p` with --agent build-plus (auto-detected).

Private workloads:
  --private-workload is a fail-closed OpenCode mode for provider-approved protected data.
  It requires --role triage, explicit --model and --agent values, an exact
  --private-profile-sha256, and exactly one --opencode-arg --pure. The model
  provider must also appear in AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST. It forbids
  detach and variants, requires the sandbox, prevents concurrent runs in the same
  private directory, suppresses transcript streaming and diagnostic excerpts,
  sanitizes activity evidence, and discards the isolated OpenCode session database
  after exit.

Backoff granularity:
  Rate limits and provider errors are recorded per model (e.g. anthropic/claude-sonnet-4-6).
  Auth errors are recorded per provider (e.g. anthropic) since credentials are shared.
  This allows fallback from sonnet to opus when only sonnet is rate-limited.

Dedup guard (GH#6538):
  Each 'run' invocation acquires a PID lock file keyed by --session-key.
  If a live process already holds the lock, the second invocation exits
  immediately (exit 0) without spawning a worker. Stale locks (dead PIDs)
  are cleaned up automatically. Lock files: $STATE_DIR/locks/<key>.pid

Defaults:
  Model list is derived from routing table + auth availability (GH#17769).
  Fallback: anthropic/claude-sonnet-4-6 if routing resolution fails.
  AIDEVOPS_HEADLESS_MODELS is deprecated — respected as override for one release cycle.
  AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST can restrict selection to providers like: openai
  AIDEVOPS_HEADLESS_VARIANT_STANDARD / AIDEVOPS_HEADLESS_VARIANT_THINKING can set tier defaults.
  GPT-5.5 standard-tier worker dispatch omits env-derived variants so OpenCode sends no explicit thinking override.
  AIDEVOPS_HEADLESS_VARIANT sets an OpenCode model variant (for example: high, xhigh).
  AIDEVOPS_HEADLESS_PULSE_VARIANT / AIDEVOPS_HEADLESS_WORKER_VARIANT override by role.
  AIDEVOPS_HEADLESS_APPEND_CONTRACT=0 disables worker /full-loop contract injection
  Public triage uses capability-aware egress: a configured backend is required;
  without one, the mandatory no-tools isolated sandbox runs with explicit degraded telemetry.
  Set AIDEVOPS_WORKER_EGRESS_MODE=required to require a backend for every triage run.
  NOTE: opencode/* gateway models are NOT used — per-token billing is too expensive.
EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	init_state_db
	case "$command" in
	select)
		cmd_select "$@"
		return $?
		;;
	run)
		cmd_run "$@"
		return $?
		;;
	canary)
		cmd_canary "$@"
		return $?
		;;
	backoff)
		cmd_backoff "$@"
		return $?
		;;
	session)
		cmd_session "$@"
		return $?
		;;
	metrics)
		cmd_metrics "$@"
		return $?
		;;
	passthrough-csv)
		# Print the sandbox passthrough CSV to stdout. Used by tests and
		# diagnostics to verify which env vars are included/excluded.
		build_sandbox_passthrough_csv
		return 0
		;;
	help | --help | -h)
		show_help
		return 0
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
