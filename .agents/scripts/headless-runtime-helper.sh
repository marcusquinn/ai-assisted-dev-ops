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
readonly METRICS_FILE="${METRICS_DIR}/headless-runtime-metrics.jsonl"
readonly RESOURCE_METRICS_HELPER="${SCRIPT_DIR}/resource-metrics-helper.sh"
readonly RESOURCE_METRICS_FILE="${METRICS_DIR}/resource-metrics.jsonl"
readonly PRIVATE_OUTPUT_FILTER="${SCRIPT_DIR}/headless-private-output-filter.py"
readonly HEADLESS_ROLE_TRIAGE="triage"

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
		unset OPENCODE_DISABLE_DEFAULT_PLUGINS
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
	if _headless_private_workload_enabled; then
		private_workload=1
		if [[ ! -f "$PRIVATE_OUTPUT_FILTER" ]] || ! command -v python3 >/dev/null 2>&1; then
			print_error "Private workload output filter is unavailable"
			printf '%s' "86" >"$exit_code_file"
			return 0
		fi
		if [[ ! -x "$SANDBOX_EXEC_HELPER" || "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
			print_error "Private workloads require the sandbox launcher"
			printf '%s' "86" >"$exit_code_file"
			return 0
		fi
	fi
	if [[ "$runtime_role" == "$HEADLESS_ROLE_TRIAGE" && "$private_workload" -ne 1 ]]; then
		public_triage=1
	fi
	# t3050: expose exit_code_file to the EXIT trap so it can read the
	# .wait_status sentinel persisted below. Pattern matches the existing
	# _WORKER_ISOLATED_DB_PATH global at line ~515. Cleared at function
	# end alongside _WORKER_ISOLATED_DB_PATH so a post-cleanup EXIT firing
	# does not see a stale path.
	_WORKER_EXIT_CODE_FILE="$exit_code_file"

	# Auth isolation for headless workers: each worker gets its own copy of
	# auth.json via XDG_DATA_HOME redirection. opencode uses
	# $XDG_DATA_HOME/opencode/auth.json for OAuth tokens. Without isolation,
	# headless workers share the interactive session's auth file — when ANY
	# worker's opencode process refreshes an expired access token, it writes
	# a new token to the shared file, invalidating the interactive session's
	# in-flight request and crashing it.
	#
	# IMPORTANT: XDG_DATA_HOME redirection moves the ENTIRE opencode data dir,
	# including the session database. Normal workers merge their isolated session
	# DB after exit. Public triage and private workloads discard it instead.
	#
	# The isolated dir is per-PID and cleaned up after the worker exits.
	local isolated_data_dir=""
	local isolated_home_dir=""
	local isolated_data_precreated=0
	if [[ "${AIDEVOPS_HEADLESS_AUTH_ISOLATION:-1}" == "1" ]]; then
		# t2758: Reuse pre-warmed isolated DB dir if the dispatcher already ran
		# opencode --version against it to trigger migration + skill-dedup.
		# Falls back to a fresh mktemp when pre-warming was skipped or failed.
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
			return 0
		fi
		if [[ "$isolated_data_precreated" -eq 1 ]]; then
			_register_headless_runtime_temp_path "$isolated_data_dir"
		elif ! _register_headless_runtime_sensitive_temp_path "$isolated_data_dir"; then
			print_error "Headless auth isolation could not register crash-resilient cleanup"
			printf '%s' "86" >"$exit_code_file"
			return 0
		fi
		mkdir -p "${isolated_data_dir}/opencode"
		# Copy the current auth.json so the worker has valid tokens at startup
		if [[ -f "$OPENCODE_AUTH_FILE" ]]; then
			if ! copy_scoped_opencode_auth "$OPENCODE_AUTH_FILE" \
				"${isolated_data_dir}/opencode/auth.json" "${_invoke_provider:-}" \
				"$([[ "$public_triage" -eq 1 ]] && printf true || printf false)"; then
				print_error "Public triage could not isolate the selected provider credential"
				printf '%s' "86" >"$exit_code_file"
				return 0
			fi
		fi
		# GH#17549: Each worker gets its OWN SQLite DB (no shared OPENCODE_DB).
		# Previously we set OPENCODE_DB back to the shared DB for session stats,
		# but concurrent workers with busy_timeout=0 cause SQLITE_BUSY which
		# silently kills streaming connections — workers stall at step_start
		# with zero API errors. Session stats are sacrificed for reliability.
		export XDG_DATA_HOME="$isolated_data_dir"
		if [[ "$public_triage" -eq 1 ]]; then
			isolated_home_dir="${isolated_data_dir}/home"
			export XDG_CACHE_HOME="${isolated_data_dir}/cache"
			export XDG_CONFIG_HOME="${isolated_data_dir}/config"
			export XDG_STATE_HOME="${isolated_data_dir}/state"
			export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
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
		# GH#20564: Expose isolated DB path to exit trap classifier so
		# classify_worker_exit can check for sessions even when the EXIT trap
		# fires while _invoke_opencode is still waiting for the worker.
		_WORKER_ISOLATED_DB_PATH="${isolated_data_dir}/opencode/opencode.db"
		print_info "[lifecycle] db_isolated dir=$isolated_data_dir pid=$$"
		_sync_worker_db_migration_metadata "$isolated_data_dir"
		if [[ -n "${_invoke_persisted_session:-}" ]]; then
			if _seed_worker_db_session_context "$isolated_data_dir" "$_invoke_persisted_session" "${_invoke_work_dir:-}"; then
				print_info "[lifecycle] db_seeded session=$_invoke_persisted_session pid=$$"
			else
				print_warning "[lifecycle] db_seed_failed session=$_invoke_persisted_session pid=$$"
			fi
		fi

		# t2249: Pre-dispatch OAuth pool check. If the account copied into the
		# isolated auth.json is in cooldown per shared pool metadata (recorded
		# by a prior worker's mark-failure), rotate the isolated file to a
		# healthy account BEFORE opencode spawns. Best-effort: failure here
		# must not block dispatch — opencode will then retry via its normal
		# backoff path. Only runs when isolation is active (XDG_DATA_HOME is
		# set above), so this cannot corrupt a shared interactive auth.json.
		#
		# Provider is resolved from the caller's selected_model (set on
		# _invoke_provider by _execute_run_attempt). Hardcoding "anthropic"
		# here would skip rotation for openai/google/cursor workers, so they
		# would still burn dispatches on cooldown-marked accounts in those
		# pools. Defaulting to "anthropic" keeps legacy callers (tests,
		# diagnostics) working when _invoke_provider is unset.
		if [[ -f "${isolated_data_dir}/opencode/auth.json" ]]; then
			_maybe_rotate_isolated_auth "${isolated_data_dir}/opencode/auth.json" "${_invoke_provider:-anthropic}"
		fi
	fi

	# Run in subshell to avoid fragile set +e/set -e toggling (GH#4225).
	# Subshell localises errexit so main shell state is never modified.
	# Exit code is written to a temp file — NOT captured via $() — because
	# tee stdout would contaminate the $() capture (bash 3.2 has no clean
	# way to separate tee output from the exit code in a single $()).
	(
		set +e
		local egress_mode="${AIDEVOPS_WORKER_EGRESS_MODE:-auto}"
		local egress_worker_id="${AIDEVOPS_WORKER_ID:-${_invoke_session_key:-headless}}"
		local egress_policy_profile="default"
		local -a sandbox_home_args=()
		if [[ "$public_triage" -eq 1 ]]; then
			if [[ -z "${_invoke_provider:-}" || -z "$isolated_home_dir" ]]; then
				print_error "Public triage requires a selected provider and isolated HOME"
				printf '%s' "126" >"$exit_code_file"
				exit 126
			fi
			egress_mode="required"
			egress_policy_profile="provider:${_invoke_provider}"
			sandbox_home_args=(--home-dir "$isolated_home_dir")
		fi
		# Inject --print-logs for headless workers so opencode's internal Go logs
		# (API errors, model resolution, DB writes) appear in the worker log.
		# This is critical for diagnosing silent exits — the JSON event stream
		# shows step_start then nothing, but the Go logs show the actual error.
		local -a _oc_cmd=("${cmd[@]}")
		if [[ "${HEADLESS:-}" == "1" && "$private_workload" -ne 1 ]]; then
			# Insert --print-logs after the 'run' subcommand
			local -a _new_cmd=()
			local _inserted=0
			for _arg in "${_oc_cmd[@]}"; do
				_new_cmd+=("$_arg")
				if [[ "$_arg" == "run" && "$_inserted" -eq 0 ]]; then
					_new_cmd+=("--print-logs" "--log-level" "WARN")
					_inserted=1
				fi
			done
			_oc_cmd=("${_new_cmd[@]}")
		fi
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			local passthrough_csv
			passthrough_csv="$(build_sandbox_passthrough_csv "${_invoke_provider:-}" "$runtime_role")"
			# --stream-stdout: let child stdout flow through the capture pipeline
			# so the activity watchdog can monitor output in real-time
			# (GH#15180 bug #4). Without this, the sandbox captures stdout to
			# a temp file and replays it after exit — the watchdog sees nothing
			# and kills every sandboxed worker at ~93s.
			if [[ -n "$passthrough_csv" ]]; then
				if [[ "$private_workload" -eq 1 ]]; then
					run_without_opencode_session_env "$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --private-output --egress-mode "$egress_mode" --egress-policy-profile "$egress_policy_profile" --worker-id "$egress_worker_id" "${sandbox_home_args[@]}" --passthrough "$passthrough_csv" -- "${_oc_cmd[@]}" 2>&1 | python3 "$PRIVATE_OUTPUT_FILTER" >"$output_file" 2>/dev/null
					local -a private_pipeline_status=("${PIPESTATUS[@]}")
					if [[ "${private_pipeline_status[1]:-1}" -ne 0 ]]; then
						printf '%s' "86" >"$exit_code_file"
					else
						printf '%s' "${private_pipeline_status[0]:-1}" >"$exit_code_file"
					fi
				else
					run_without_opencode_session_env "$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --stream-stdout --egress-mode "$egress_mode" --egress-policy-profile "$egress_policy_profile" --worker-id "$egress_worker_id" "${sandbox_home_args[@]}" --passthrough "$passthrough_csv" -- "${_oc_cmd[@]}" 2>&1 | tee "$output_file"
					printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
				fi
			else
				if [[ "$private_workload" -eq 1 ]]; then
					run_without_opencode_session_env "$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --private-output --egress-mode "$egress_mode" --egress-policy-profile "$egress_policy_profile" --worker-id "$egress_worker_id" "${sandbox_home_args[@]}" -- "${_oc_cmd[@]}" 2>&1 | python3 "$PRIVATE_OUTPUT_FILTER" >"$output_file" 2>/dev/null
					local -a private_pipeline_status=("${PIPESTATUS[@]}")
					if [[ "${private_pipeline_status[1]:-1}" -ne 0 ]]; then
						printf '%s' "86" >"$exit_code_file"
					else
						printf '%s' "${private_pipeline_status[0]:-1}" >"$exit_code_file"
					fi
				else
					run_without_opencode_session_env "$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --stream-stdout --egress-mode "$egress_mode" --egress-policy-profile "$egress_policy_profile" --worker-id "$egress_worker_id" "${sandbox_home_args[@]}" -- "${_oc_cmd[@]}" 2>&1 | tee "$output_file"
					printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
				fi
			fi
		else
			if [[ "$private_workload" -eq 1 ]]; then
				print_error "Private workload sandbox became unavailable before launch"
				printf '%s' "86" >"$exit_code_file"
				exit 86
			fi
			if [[ "$egress_mode" == "required" ]]; then
				print_error "Whole-process worker egress is required, but the sandbox launcher is disabled or unavailable"
				printf '%s' "126" >"$exit_code_file"
				exit 126
			fi
			if [[ "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
				print_info "AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 — using bare timeout (no privilege isolation) (GH#20146 audit)"
			fi
			run_without_opencode_session_env timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" "${_oc_cmd[@]}" 2>&1 | tee "$output_file"
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		fi
	) &
	local worker_pid=$!

	# Activity watchdog: monitor the output file for LLM activity.
	# If no activity appears within the timeout, the provider is likely
	# rate-limited and the worker will hang indefinitely. Kill it so the
	# retry loop in cmd_run can rotate to the next provider.
	#
	# GH#17648: Launch as a STANDALONE process via nohup, not a backgrounded
	# function. The previous `_run_activity_watchdog ... &` died silently when
	# nohup changed the subshell's process group — stalled workers sat forever.
	# The standalone script has its own process lifecycle, independent of the
	# worker subshell.
	local _watchdog_script="${SCRIPT_DIR}/worker-activity-watchdog.sh"
	local watchdog_pid=""
	local _stall_timeout="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-600}"
	[[ "$_stall_timeout" =~ ^[0-9]+$ ]] || _stall_timeout=600
	local _phase1_timeout="${HEADLESS_PHASE1_TIMEOUT_SECONDS:-180}"
	[[ "$_phase1_timeout" =~ ^[0-9]+$ ]] || _phase1_timeout=180

	if [[ -x "$_watchdog_script" ]]; then
		nohup "$_watchdog_script" \
			--output-file "$output_file" \
			--worker-pid "$worker_pid" \
			--exit-code-file "$exit_code_file" \
			--session-key "${_invoke_session_key:-}" \
			--repo-slug "${DISPATCH_REPO_SLUG:-}" \
			--worktree-path "${_WORKER_WORKTREE_PATH:-}" \
			--stall-timeout "$_stall_timeout" \
			--phase1-timeout "$_phase1_timeout" \
			</dev/null >/dev/null 2>&1 &
		watchdog_pid=$!
		print_info "[lifecycle] activity_watchdog_started pid=$watchdog_pid worker=$worker_pid stall_timeout=${_stall_timeout}s"
	else
		# Fallback: use inline function if standalone script is missing
		# (should not happen in normal deployment)
		print_warning "[lifecycle] standalone watchdog not found at $_watchdog_script — falling back to inline"
		_run_activity_watchdog "$output_file" "$worker_pid" "$exit_code_file" "$_invoke_session_key" &
		watchdog_pid=$!
	fi

	# GH#21578 / t3021: Rate-limit fast-exit monitor.
	# Detects 429/overload patterns within the first 30s and kills the worker
	# cleanly, preventing the 20-min zombie that forms when opencode silently
	# retries a first-call 429 for the full HEADLESS_SANDBOX_TIMEOUT lifetime.
	# Only fires when no LLM activity has been produced (dead-on-arrival pattern).
	local _rl_monitor_pid=""
	local _rl_window="${HEADLESS_RATE_LIMIT_DETECT_SECONDS:-30}"
	if [[ "$_rl_window" =~ ^[0-9]+$ && "$_rl_window" -gt 0 ]]; then
		_rl_monitor_pid=$(_launch_rate_limit_fast_monitor "$output_file" "$worker_pid" "$exit_code_file" "$_rl_window")
		print_info "[lifecycle] rate_limit_fast_monitor_started pid=${_rl_monitor_pid:-none} worker=$worker_pid window=${_rl_window}s"
	fi

	# Wait for the worker to finish (watchdog will kill it if stalled)
	print_info "[lifecycle] waiting_for_worker pid=$worker_pid watchdog=$watchdog_pid"
	local _wait_status=0
	wait "$worker_pid" 2>/dev/null || _wait_status=$?
	# t3050: persist worker wait_status so the EXIT trap can classify signal
	# kills correctly. Without this, the EXIT trap reads $? at script exit —
	# always 0 after the wrapper's clean post-wait cleanup — and emits
	# reason=clean for SIGTERM/SIGKILL'd workers (canonical: GH#21707).
	if [[ -n "${exit_code_file:-}" ]]; then
		printf '%s' "$_wait_status" >"${exit_code_file}.wait_status" 2>/dev/null || true
	fi
	# t3063: classify kill_reason on the same line as wait_status so Phase 2
	# log aggregation does not need to JOIN by PID across scripts. classifier
	# inspects sentinel files written next to exit_code_file by kill sites
	# (worker-activity-watchdog hard/soft kill, rate_limit_fast monitor) and
	# the forward-compatible .kill_reason sentinel for new kill paths.
	local _kill_reason
	_kill_reason=$(classify_worker_kill_reason "$exit_code_file" "$_wait_status")
	print_info "[lifecycle] worker_exited pid=$worker_pid wait_status=$_wait_status kill_reason=$_kill_reason"

	# Clean up the watchdog — it should exit on its own when it detects
	# the worker PID is gone, but kill it explicitly to be safe.
	if [[ -n "$watchdog_pid" ]]; then
		kill "$watchdog_pid" 2>/dev/null || true
		# Timeout the wait to prevent indefinite blocking if watchdog is stuck
		# on a network call (gh api for kill comment/unlock)
		local _watchdog_wait_start _watchdog_wait_elapsed
		_watchdog_wait_start=$(date +%s)
		while kill -0 "$watchdog_pid" 2>/dev/null; do
			_watchdog_wait_elapsed=$(($(date +%s) - _watchdog_wait_start))
			if [[ "$_watchdog_wait_elapsed" -gt 30 ]]; then
				print_warning "[lifecycle] watchdog_wait_timeout pid=$watchdog_pid elapsed=${_watchdog_wait_elapsed}s — sending SIGKILL"
				kill -9 "$watchdog_pid" 2>/dev/null || true
				break
			fi
			sleep 1
		done
		wait "$watchdog_pid" 2>/dev/null || true
	fi
	print_info "[lifecycle] watchdog_cleaned pid=$watchdog_pid"

	# Clean up the rate-limit fast-exit monitor (if launched).
	# The monitor exits on its own when it detects the worker PID is gone,
	# but kill it explicitly to avoid leaving orphans after a watchdog kill.
	if [[ -n "${_rl_monitor_pid:-}" ]]; then
		kill "$_rl_monitor_pid" 2>/dev/null || true
		wait "$_rl_monitor_pid" 2>/dev/null || true
	fi

	# Merge normal worker session data back to the shared DB, then clean up.
	# Public triage and private workloads are ephemeral trust boundaries: discard
	# their complete isolated session graph instead of retaining transcripts.
	if [[ -n "$isolated_data_dir" && -d "$isolated_data_dir" ]]; then
		if ! _finalize_isolated_runtime_data "$isolated_data_dir" "$runtime_role"; then
			print_error "Isolated runtime data cleanup failed for role=$runtime_role"
			if _headless_run_is_ephemeral "$runtime_role"; then
				printf '%s' "86" >"$exit_code_file"
			fi
		fi
	fi

	# t3050: Clear exit_code_file path so a post-cleanup EXIT trap firing
	# does not read a stale sentinel left over from a prior invocation.
	# The .wait_status sentinel itself is short-lived (read-once-and-deleted
	# by the EXIT trap), but the path variable is process-global until cleared.
	_WORKER_EXIT_CODE_FILE=""

	print_info "[lifecycle] invoke_opencode_returning pid=$$"
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

_should_retry_sol_at_max() {
	local role="$1"
	local selected_model="$2"
	local variant="$3"
	local retry_count="$4"
	if [[ "$role" == "worker" && "$selected_model" == "openai/gpt-5.6-sol" &&
		"$variant" == "high" && "$retry_count" -eq 0 ]]; then
		return 0
	fi
	return 1
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
	if [[ ! "${exit_code:-}" =~ ^[0-9]+$ ]]; then
		exit_code=1
	fi

	local discovered_session activity_detected
	discovered_session=$(extract_session_id_from_output "$output_file")
	activity_detected=$(output_has_activity "$output_file")
	_run_activity_detected="$activity_detected"
	_run_result_label="failed"
	_run_provider_error_type=""
	_run_provider_status=""
	_run_runtime_error_type=""
	_run_classification_source=""
	_run_classification_pattern=""

	# A headless OpenCode permission event is captured by the plugin and rejected
	# immediately so no worker slot waits for an interactive answer. Preserve the
	# session and route the attempt to the maintainer-permission lifecycle unless
	# the worker subsequently proved the full objective completed without it.
	if [[ "$role" == "worker" && -n "${_run_permission_request_file:-}" &&
		-f "${_run_permission_request_file}" ]]; then
		if [[ -n "$discovered_session" ]]; then
			_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session" "$selected_model" "$role"
		fi
		local completion_evidence=""
		if completion_evidence=$(_hrw_post_merge_permission_completion_evidence \
			"$session_key" "$discovered_session" "$work_dir"); then
			local completed_pr=""
			local cleanup_receipt=""
			local cleanup_state=""
			local executor_state=""
			local cleanup_owner_session=""
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
	fi

	if [[ "${exit_code:-}" == "0" ]]; then
		if [[ "$activity_detected" != "1" ]]; then
			_run_result_label="no_activity"
			# Do NOT record provider backoff for no_activity. Exit 0 with no LLM
			# output can be caused by local issues (bad prompt, sandbox problem,
			# opencode bug) — not the provider's fault. Recording provider_error
			# here falsely flags healthy providers as rate-limited, causing the
			# pre-dispatch check to skip them and starve the worker pool.
			# The activity watchdog (exit 124) handles genuine provider failures.
			#
			# t2119: preserve the output file for post-mortem forensics instead
			# of deleting it. Workers that die in setup with exit 0 + no JSON
			# events leave no other trace of WHY they died — not in observability
			# DB (never reached the model), not in pulse.log, not in the
			# session DB (never created one). The output file captured by tee is
			# the only place plugin/runtime stderr lands. Moving it to a
			# retention-capped diagnostics dir lets operators actually diagnose
			# the residual 30s no_activity failures that the t2116-session
			# plist-reload fix didn't fully resolve.
			if [[ "$suppress_persistent_output" -eq 1 ]]; then
				rm -f "$output_file" 2>/dev/null || true
				print_warning "$selected_model returned exit 0 without any model activity (ephemeral output discarded)"
			else
				_preserve_no_activity_output "$output_file" "$session_key" "$selected_model"
				print_warning "$selected_model returned exit 0 without any model activity (no backoff recorded — forensic copy preserved via t2119)"
			fi
			return 75
		fi
		if _headless_private_workload_enabled && ! _private_output_has_task_complete "$output_file"; then
			_run_result_label="private_incomplete"
			_run_failure_reason="$_run_result_label"
			rm -f "$output_file" 2>/dev/null || true
			print_warning "$selected_model private workload exited without TASK_COMPLETE"
			return 77
		fi
		# Store session ID for potential continuation (before deleting output)
		if [[ "$role" != "pulse" && -n "$discovered_session" ]]; then
			_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session" "$selected_model" "$role"
		fi

		# GH#17436: Check for premature exit — worker produced activity (tool
		# calls) but stopped without completing (no PR, no FULL_LOOP_COMPLETE,
		# no BLOCKED). This is the #1 GPT-5.4 failure mode: reads issue, creates
		# worktree, then exits without writing code. Previously classified as
		# "success" which prevented fast-fail escalation from ever triggering.
		#
		# Only check implementation workers (session_key=issue-*), not pulse
		# or triage sessions which don't produce PR completion signals.
		if [[ "$role" == "worker" && "$session_key" == issue-* ]]; then
			if ! output_has_completion_signal "$output_file"; then
				# Diagnose empty tool results that may have caused the model to stop.
				# Each is a closeable gap (wrong path, missing prefix, moved file).
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
				_run_classification_source="model_blocked""_signal"
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
	fi

	local failure_reason
	# Exit code 124 = activity watchdog timeout (stall or dead runtime).
	#
	# GH#17648: Distinguish "stall with prior activity" from "dead on arrival".
	# A mid-session stall (stream drop after the model was working) should try
	# continuation — the model may have created a worktree, written files, etc.
	# Killing and starting fresh wastes all that context.
	#
	# - 124 + activity + hard-kill sentinel → return 79 (watchdog_stall_killed)
	#   to skip continuation entirely. The watchdog escalated to a proactive
	#   kill because total elapsed ≥ WORKER_STALL_HARD_KILL_SECONDS — the slot
	#   should be freed for re-dispatch instead of held through more stalls.
	#   (t2956 / Issue #21231)
	# - 124 + activity → return 78 (watchdog_stall_continue) so the retry loop
	#   can resume the session with a continuation prompt before giving up.
	# - 124 + startup output but no activity → return 78 so the retry loop can
	#   try a bounded fresh continuation before provider backoff/rotation.
	# - 124 + no output or explicit provider marker → rate_limit as before.
	if [[ "${exit_code:-}" == "124" ]]; then
		failure_reason=$(classify_failure_reason "$output_file")
		if [[ "$failure_reason" == "rate_limit" ]]; then
			print_warning "$selected_model watchdog saw provider/rate-limit marker — classifying as rate_limit for rotation"
		else
			if [[ "$activity_detected" == "1" ]]; then
				# Worker was making progress, then stalled (stream drop, hung connection).
				# Store session ID for continuation before deleting output.
				local discovered_session_for_continue
				discovered_session_for_continue=$(extract_session_id_from_output "$output_file")
				if [[ "$role" != "pulse" && -n "$discovered_session_for_continue" ]]; then
					_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session_for_continue" "$selected_model" "$role"
				fi
				# t2956: Hard-kill path — proactive elapsed-time kill from the
				# watchdog. Skip continuation, free the slot. The flag is set in
				# _execute_run_attempt when the .watchdog_stall_killed sentinel
				# was present alongside .watchdog_killed.
				if [[ "${_run_watchdog_hard_killed:-0}" -eq 1 ]]; then
					# Local to avoid duplicating the literal across the file
					# (string-literal ratchet). The pre-existing per-session cap
					# branch below uses the same label string.
					local _hk_label="watchdog_stall_killed"
					_run_result_label="$_hk_label"
					_run_failure_reason="$_hk_label"
					rm -f "$output_file"
					print_warning "$selected_model watchdog hard-kill (elapsed ≥ WORKER_STALL_HARD_KILL_SECONDS) — slot freed for re-dispatch (no continuation)"
					return 79
				fi
				_run_result_label="watchdog_stall_continue"
				rm -f "$output_file"
				print_warning "$selected_model watchdog stall with prior activity — will attempt session continuation"
				return 78
			fi
			if [[ -s "$output_file" && "$role" != "pulse" ]]; then
				_run_result_label="watchdog_startup_continue"
				_run_failure_reason="startup_no_model_activity"
				rm -f "$output_file"
				print_warning "$selected_model watchdog startup stall without model activity — will attempt bounded continuation before provider backoff"
				return 78
			fi
			failure_reason="rate_limit"
			_failure_provider_error_type="rate_limit"
			_failure_provider_status="429"
			_failure_classification_source="watchdog_no_activity"
			_failure_classification_pattern="watchdog_timeout_no_activity"
			print_warning "$selected_model activity watchdog timeout (no activity) — classifying as rate_limit for rotation"
		fi
	else
		local local_kill_reason="${_metric_kill_reason:-}"
		local natural_kill_reason=natural
		local unknown_kill_reason=unknown
		if [[ "$role" == "worker" && "$session_key" == issue-* ]] &&
			[[ "${exit_code:-}" == "137" || "${exit_code:-}" == "143" ]] &&
			[[ -n "$local_kill_reason" && "$local_kill_reason" != "$natural_kill_reason" && "$local_kill_reason" != "$unknown_kill_reason" ]]; then
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
			return 83
		fi
		if [[ "${exit_code:-}" == "137" && "$activity_detected" == "1" ]]; then
			local discovered_session_for_signal_continue
			discovered_session_for_signal_continue=$(extract_session_id_from_output "$output_file")
			if [[ "$role" != "pulse" && -n "$discovered_session_for_signal_continue" ]]; then
				_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session_for_signal_continue" "$selected_model" "$role"
			fi
			_run_result_label="signal_killed_continue"
			_run_failure_reason="signal_killed_continue"
			_run_runtime_error_type="sigkill"
			_run_classification_source="worker_exit_diagnostics"
			_run_classification_pattern="exit_137_with_activity"
			rm -f "$output_file"
			print_warning "$selected_model worker exited with SIGKILL after activity — will attempt session continuation"
			return 78
		fi
		failure_reason=$(classify_failure_reason "$output_file")
	fi
	_run_result_label="$failure_reason"
	_run_provider_error_type="${_failure_provider_error_type:-}"
	_run_provider_status="${_failure_provider_status:-}"
	_run_runtime_error_type="${_failure_runtime_error_type:-}"
	_run_classification_source="${_failure_classification_source:-}"
	_run_classification_pattern="${_failure_classification_pattern:-}"

	# GH#23037: Transient provider/runtime interruptions after work has begun
	# should resume the existing session from disk instead of consuming the
	# premature-exit or watchdog-stall continuation budgets. Require activity or
	# session evidence so startup failures still follow normal backoff paths.
	if [[ "$role" == "worker" && "$session_key" == issue-* ]] &&
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
		return 78
	fi
	if [[ "$role" == "worker" && "$session_key" == issue-* ]] &&
		service_interruption_continue_candidate \
			"$failure_reason" "$exit_code" "$activity_detected" "$discovered_session" \
			"${_failure_provider_error_type:-}"; then
		if [[ -n "$discovered_session" ]]; then
			_store_headless_session_if_allowed "$provider" "$session_key" "$discovered_session" "$selected_model" "$role"
		fi
		local _sic_label="service_interruption_continue"
		_run_result_label="$_sic_label"
		_run_failure_reason="$failure_reason"
		# Preserve the attempt output for diagnostics if the dedicated
		# continuation budget is later exhausted in cmd_run.
		print_warning "$selected_model service interruption after activity/session evidence — will attempt session continuation"
		return 81
	fi

	if attempt_pool_recovery "$provider" "$failure_reason" "$output_file"; then
		_run_should_retry=1
		rm -f "$output_file"
		_run_failure_reason="$failure_reason"
		return 76
	fi

	# Pulse supervisor failures must NOT block worker dispatch. The supervisor
	# and workers may use different accounts (isolated auth) and the supervisor
	# hitting a rate limit doesn't mean the provider is down for workers.
	# Record pulse backoffs under a role-scoped key so the pre-dispatch check
	# (which queries the model key) doesn't see them.
	if [[ "$role" == "pulse" ]]; then
		record_provider_backoff "$provider" "$failure_reason" "$output_file" "pulse/${selected_model}" "$suppress_persistent_output"
	else
		record_provider_backoff "$provider" "$failure_reason" "$output_file" "$selected_model" "$suppress_persistent_output"
	fi
	rm -f "$output_file"
	_run_failure_reason="$failure_reason"
	_run_should_retry=0
	return "$exit_code"
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

	_recover_deleted_cwd_before_launch "$work_dir" "execute_run_attempt" || return 1

	local runtime="${headless_runtime:-opencode}"
	if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" && "$runtime" != "opencode" ]] && ! _headless_private_workload_enabled; then
		print_error "Public triage supports only the isolated OpenCode runtime"
		return 126
	fi
	local prompt_arg="$prompt" prompt_file_arg="" claude_stdin_file="" force_file_transport=0
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
	if [[ -n "$prompt_file_arg" ]]; then
		extra_args+=(--file "$prompt_file_arg")
	fi
	_HEADLESS_CLAUDE_STDIN_FILE="$claude_stdin_file"

	local provider persisted_session=""
	provider=$(extract_provider "$selected_model")
	local metric_work_dir="$work_dir"
	if _headless_run_is_ephemeral "$role"; then
		metric_work_dir=""
		clear_session_id "$provider" "$session_key"
	elif [[ "$role" == "pulse" ]]; then
		# Pulse runs must start from the current pre-fetched state each cycle.
		# Reusing a prior session contaminates later /pulse runs with stale
		# conversational context, which leads to idle watchdog kills and an
		# empty worker pool. Workers still keep session reuse.
		clear_session_id "$provider" "$session_key"
	else
		persisted_session=$(get_session_id "$provider" "$session_key")
	fi

	local -a cmd=()
	case "$runtime" in
	claude)
		if ! type -P claude >/dev/null 2>&1; then
			print_error "Claude CLI not found in PATH (requested via --runtime claude)"
			return 1
		fi
		while IFS= read -r -d '' arg; do
			cmd+=("$arg")
		done < <(_build_claude_cmd "$selected_model" "$work_dir" "$prompt_arg" "$title" \
			"$agent_name" "${extra_args[@]+"${extra_args[@]}"}")
		;;
	opencode | *)
		while IFS= read -r -d '' arg; do
			cmd+=("$arg")
		done < <(_build_run_cmd "$selected_model" "$work_dir" "$prompt_arg" "$title" \
			"$variant_override" "$agent_name" "$persisted_session" "${extra_args[@]+"${extra_args[@]}"}")
		;;
	esac

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

	local output_file exit_code_file exit_code permission_request_file
	local start_ms end_ms duration_ms
	local resource_stop_file resource_result_file resource_sampler_pid
	local _metric_kill_reason=""
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
	rm -f "$resource_stop_file" 2>/dev/null || true
	rm -f "$resource_result_file" 2>/dev/null || true
	resource_sampler_pid=""
	exit_code=0

	# GH#17549: expose session_key to _invoke_opencode → watchdog → _watchdog_kill
	# so claim release can identify the issue. Module-level var avoids changing
	# _invoke_opencode's interface which is shared with _invoke_claude.
	_invoke_session_key="$session_key"
	# t2249: expose provider to _invoke_opencode → _maybe_rotate_isolated_auth
	# so non-anthropic workers (openai/cursor/google) also benefit from pre-
	# dispatch rotation against their own pool entries. Same rationale as
	# _invoke_session_key above: keep _invoke_opencode's arg list stable.
	_invoke_provider="$provider"
	# Public triage uses this role at the final process boundary to select the
	# minimal environment, isolated HOME, and provider-only egress profile.
	_invoke_role="$role"
	# GH#23958: expose the persisted OpenCode session to _invoke_opencode so
	# isolated worker DBs can be seeded before --session <id> --continue runs.
	_invoke_persisted_session="$persisted_session"
	# GH#27560: persisted sessions retain their original worktree directory.
	# Expose the current worker directory so isolated DB seeding can rebind the
	# continuation without mutating the shared interactive session record.
	_invoke_work_dir="$work_dir"

	# t3077: expose session_key to the verbose lifecycle emitter via the
	# convention WORKER_SESSION_KEY (read by _emit_verbose_checkpoint).
	export WORKER_SESSION_KEY="$session_key"

	# t3077 — Fix-the-fixer detection + observability setup.
	#
	# When the linked issue carries the `fix-the-fixer` label (applied by
	# pulse-fix-the-fixer-detector.sh), enable extra observability for THIS
	# worker:
	#   - AIDEVOPS_VERBOSE_LIFECYCLE=1   — extra checkpoints in worker log
	#   - HEADLESS_ACTIVITY_TIMEOUT_SECONDS=180  — tighter watchdog (vs 600s)
	#   - AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1  — fail-fast preflight check
	#
	# Detection runs once at worker start. Best-effort gh API call (one
	# extra REST hit per worker, ~50ms). On failure, falls through with
	# default settings — the deterministic t2819 detector remains the
	# primary safety net.
	_t3077_setup_fix_the_fixer_observability "${WORKER_ISSUE_NUMBER:-}" "${DISPATCH_REPO_SLUG:-}" || true

	# t3077 — preflight sentinel write.
	# When AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1 (set by the helper above
	# when fix-the-fixer is labeled), write a sentinel file before the
	# model is invoked. If the write does not complete, abort the dispatch
	# immediately with exit code 11 — the worker would otherwise burn
	# tokens on a sandbox/FD-broken environment.
	if ! _t3077_write_preflight_sentinel; then
		print_error "[lifecycle] preflight_abort reason=sentinel_write_blocked pid=$$ session=$session_key"
		printf '11' >"$exit_code_file" 2>/dev/null || true
		exit_code=11
		return 11
	fi
	if [[ "$role" == "worker" ]] && ! _hrw_verify_dispatch_ownership; then
		_WORKER_PRELAUNCH_FAILURE_REASON="$_HRW_REASON_OWNERSHIP_LOST"
		print_error "[lifecycle] runtime ownership fence stopped session=${session_key} before model invocation"
		return 85
	fi

	if [[ -x "$RESOURCE_METRICS_HELPER" ]]; then
		"$RESOURCE_METRICS_HELPER" sample \
			--pid "$$" \
			--role "$role" \
			--session-key "$session_key" \
			--repo "${DISPATCH_REPO_SLUG:-}" \
			--issue "${WORKER_ISSUE_NUMBER:-}" \
			--result-file "$resource_result_file" \
			--out "$RESOURCE_METRICS_FILE" \
			--stop-file "$resource_stop_file" \
			--interval "${AIDEVOPS_RESOURCE_SAMPLE_INTERVAL_SECONDS:-30}" >/dev/null 2>&1 &
		resource_sampler_pid="$!"
	fi

	# t3077 — spawn the verbose lifecycle watcher (background subshell).
	# Fail-open: returns silently if AIDEVOPS_VERBOSE_LIFECYCLE != 1.
	local _t3077_watcher_pid=""
	_t3077_watcher_pid=$(_start_verbose_lifecycle_watcher "$output_file" "$$" 2>/dev/null) || true
	if [[ -n "$_t3077_watcher_pid" ]]; then
		print_info "[lifecycle] verbose_watcher_started pid=${_t3077_watcher_pid} worker=$$ log=${output_file}"
	fi

	# Publish readiness only at the runtime invocation boundary. The EXIT trap
	# uses the pre_runtime_launch marker to distinguish preparation failures
	# from legitimate post-launch zero-output exits.
	_hrw_mark_runtime_launch_started "$session_key" "$runtime"
	_emit_verbose_checkpoint worker_started \
		"model=${selected_model} runtime=${runtime} fix_the_fixer=${_T3077_FIX_THE_FIXER:-0}"
	print_info "[lifecycle] worker_start session=$session_key model=$selected_model runtime=$runtime pid=$$"
	case "$runtime" in
	claude) _invoke_claude "$output_file" "$exit_code_file" "$work_dir" "${cmd[@]}" ;;
	*) _invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}" ;;
	esac

	# t3077 — clean up the verbose lifecycle watcher (if any).
	_cleanup_verbose_lifecycle_watcher "$$" 2>/dev/null || true
	print_info "[lifecycle] invoke_returned session=$session_key pid=$$ exit_code_file_exists=$(test -f "$exit_code_file" && echo yes || echo no)"
	exit_code=$(cat "$exit_code_file" 2>/dev/null) || exit_code=1
	print_info "[lifecycle] exit_code_read session=$session_key exit_code=$exit_code"

	# Activity watchdog race fix: the watchdog writes a marker file when it
	# kills a stalled worker. The dying subshell may overwrite exit_code_file
	# with its own exit code (0 or 143), losing the watchdog's 124. The marker
	# file is authoritative — if it exists, this was a watchdog kill.
	local _normalized_exit_info=""
	_normalized_exit_info=$(_normalize_worker_exit_code_and_kill_reason "$exit_code_file" "$exit_code")
	IFS=$'\t' read -r exit_code _metric_kill_reason <<<"$_normalized_exit_info"
	# t2956 / Issue #21231: Hard-kill sentinel — set when the watchdog
	# escalated from passive (78 / continue) to proactive (79 / killed)
	# because the worker had been stalling for ≥ WORKER_STALL_HARD_KILL_SECONDS
	# total elapsed. _handle_run_result reads this flag (via the function-
	# scope variable) and returns 79 to short-circuit the continuation loop.
	_run_watchdog_hard_killed=0
	local _stall_killed_marker="${exit_code_file}.watchdog_stall_killed"
	if [[ -f "$_stall_killed_marker" ]]; then
		_run_watchdog_hard_killed=1
		rm -f "$_stall_killed_marker"
	fi
	# GH#21578 / t3021: Save rate_limit_fast sentinel path BEFORE deleting
	# exit_code_file — the sentinel lives at ${exit_code_file}.rate_limit_fast
	# and must be checked after the stale-session retry block.
	local _rl_fast_sentinel="${exit_code_file}.rate_limit_fast"
	rm -f "$exit_code_file"

	# GH#25541: A prewarmed isolated OpenCode DB can still reach `opencode run`
	# with user tables present but migration ledgers unusable/mismatched, causing
	# Drizzle to replay CREATE TABLE and abort with `table project already exists`
	# before the seed prompt/model activity. The DB is per-worker scratch state, so
	# retry once with a fresh isolated dir and no dispatcher prewarm dir instead of
	# releasing the claim as a model/worker failure.
	if [[ "$runtime" != "claude" ]] && _opencode_project_table_migration_replay_detected "$exit_code" "$output_file"; then
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
		if ! read -r exit_code <"$exit_code_file" 2>/dev/null; then
			exit_code=1
		fi
		_normalized_exit_info=$(_normalize_worker_exit_code_and_kill_reason "$exit_code_file" "$exit_code")
		IFS=$'\t' read -r exit_code _metric_kill_reason <<<"$_normalized_exit_info"
		local _project_retry_stall_killed_marker="${exit_code_file}.watchdog_stall_killed"
		if [[ -f "$_project_retry_stall_killed_marker" ]]; then
			_run_watchdog_hard_killed=1
			rm -f "$_project_retry_stall_killed_marker"
		fi
		_rl_fast_sentinel="${exit_code_file}.rate_limit_fast"
		rm -f "$exit_code_file"
	fi

	# GH#16978 Bug B: Stale session ID causes "Session not found" on OpenCode.
	# When a persisted session ID is stale (e.g., from a previous OpenCode version
	# or a different machine), OpenCode exits non-zero with "Session not found"
	# instead of creating a new session. Detect this, clear the stale ID, and
	# retry once without --session so a fresh session is created.
	if [[ "${exit_code:-}" != "0" && "$runtime" != "claude" && -n "$persisted_session" ]]; then
		local output_text=""
		output_text=$(cat "$output_file" 2>/dev/null || true)
		if [[ "$output_text" == *"Session not found"* ]]; then
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
			# Rebuild command without the stale --session flag
			cmd=()
			while IFS= read -r -d '' arg; do
				cmd+=("$arg")
			done < <(_build_run_cmd "$selected_model" "$work_dir" "$prompt_arg" "$title" \
				"$variant_override" "$agent_name" "$persisted_session" "${extra_args[@]+"${extra_args[@]}"}")
			_begin_worker_runtime_run
			_invoke_opencode "$output_file" "$exit_code_file" "${cmd[@]}"
			exit_code=$(cat "$exit_code_file" 2>/dev/null) || exit_code=1
			_normalized_exit_info=$(_normalize_worker_exit_code_and_kill_reason "$exit_code_file" "$exit_code")
			IFS=$'\t' read -r exit_code _metric_kill_reason <<<"$_normalized_exit_info"
			# t2956: Hard-kill sentinel must also be re-checked on the retry path.
			local _retry_stall_killed_marker="${exit_code_file}.watchdog_stall_killed"
			if [[ -f "$_retry_stall_killed_marker" ]]; then
				_run_watchdog_hard_killed=1
				rm -f "$_retry_stall_killed_marker"
			fi
			rm -f "$exit_code_file"
		fi
	fi

	# GH#21578 / t3021: Rate-limit fast-exit check.
	# _launch_rate_limit_fast_monitor writes this sentinel when it detects
	# 429/overload patterns within the first 30s and kills the worker cleanly.
	# Route as exit 80 so cmd_run can release the dispatch claim without
	# incrementing the fast-fail counter or triggering NMR backoff on the issue.
	if [[ -f "$_rl_fast_sentinel" ]]; then
		local _rl_metric_output_file="" _rl_metric_session_id=""
		if [[ -f "$output_file" ]] && ! _headless_run_is_ephemeral "$role"; then
			_rl_metric_session_id=$(extract_session_id_from_output "$output_file" 2>/dev/null || true)
			_rl_metric_output_file=$(_metric_failure_excerpt_path "$output_file" "$session_key")
		fi
		# One literal here; _cmd_run_finish elif is a second. Keeping total at 2
		# avoids the repeated-string-literal ratchet gate (threshold: >=3).
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
		local _rl_end_ms
		_rl_end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")
		local _rl_duration_ms=0
		if [[ "$_rl_end_ms" =~ ^[0-9]+$ && "$start_ms" =~ ^[0-9]+$ && "$_rl_end_ms" -ge "$start_ms" ]]; then
			_rl_duration_ms=$((_rl_end_ms - start_ms))
		fi
		print_info "[lifecycle] rate_limit_fast_exit session=$session_key model=$selected_model duration_ms=${_rl_duration_ms}"
		if [[ -n "$resource_sampler_pid" ]]; then
			printf '%s\n' "$_run_result_label" >"$resource_result_file" 2>/dev/null || true
			printf 'done\n' >"$resource_stop_file" 2>/dev/null || true
			wait "$resource_sampler_pid" 2>/dev/null || true
			rm -f "$resource_stop_file" "$resource_result_file" 2>/dev/null || true
		fi
		append_runtime_metric "$role" "$session_key" "$selected_model" "$provider" "$_run_result_label" "0" "$_run_failure_reason" "0" "$_rl_duration_ms" \
			"${WORKER_ISSUE_NUMBER:-}" "${DISPATCH_REPO_SLUG:-}" "$metric_work_dir" "$_rl_metric_output_file" "$_rl_metric_session_id" \
			"${_run_provider_error_type:-}" "${_run_provider_status:-}" "${_run_runtime_error_type:-}" "${_run_classification_source:-}" "${_run_classification_pattern:-}" \
			"provider_rate_limited" "${_metric_kill_reason}" "rotate_provider_or_wait_for_reset"
		return 80
	fi

	# GH#17549: Post-exit worker diagnostics — log exit code, signal, and
	# session state to the output file so the worker log captures it.
	# OpenCode exits silently on API errors; this is our only visibility.
	# Extract session ID BEFORE the append block to avoid SC2094 (read+write same file).
	local _diag_session_id="" _diag_incomplete_msgs="0" _metric_session_id="" _metric_output_file="" _metric_excerpt_candidate=""
	if [[ -f "$output_file" ]] && ! _headless_run_is_ephemeral "$role"; then
		_metric_session_id=$(extract_session_id_from_output "$output_file" 2>/dev/null || true)
	fi
	if [[ "${exit_code:-}" == "0" && -n "$_metric_session_id" ]]; then
		_diag_session_id="$_metric_session_id"
		if [[ -n "$_diag_session_id" ]]; then
			_diag_incomplete_msgs=$(sqlite3 ~/.local/share/opencode/opencode.db \
				"SELECT count(*) FROM message WHERE session_id='${_diag_session_id}' AND json_extract(data, '$.role')='assistant' AND json_extract(data, '$.time.completed') IS NULL" 2>/dev/null || echo "0")
		fi
	fi
	{
		printf '\n[WORKER_EXIT_DIAGNOSTICS] exit_code=%s model=%s role=%s session_key=%s\n' \
			"$exit_code" "$selected_model" "$role" "$session_key"
		printf '[WORKER_EXIT_DIAGNOSTICS] structured exit_code=%s kill_reason=%s session_key=%s\n' \
			"$exit_code" "${_metric_kill_reason:-unknown}" "$session_key"
		if [[ "${exit_code:-}" == "124" ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=watchdog_kill (no LLM activity within timeout)\n'
		elif [[ "${exit_code:-}" == "137" ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=SIGKILL (OOM or external kill)\n'
		elif [[ "${exit_code:-}" == "143" ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=SIGTERM (graceful termination)\n'
		elif [[ "${exit_code:-}" == "0" && "$_diag_incomplete_msgs" -gt 0 ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=mid_turn_death (session %s has %s incomplete assistant messages — API likely dropped)\n' \
				"$_diag_session_id" "$_diag_incomplete_msgs"
		elif [[ "${exit_code:-}" != "0" ]]; then
			printf '[WORKER_EXIT_DIAGNOSTICS] cause=unknown (exit_code=%s)\n' "$exit_code"
		fi
	} >>"$output_file" 2>/dev/null || true

	print_info "[lifecycle] calling_handle_run_result session=$session_key exit_code=$exit_code output_size=$(wc -c <"$output_file" 2>/dev/null || echo 0)"
	if ! _headless_run_is_ephemeral "$role"; then
		_metric_excerpt_candidate=$(_metric_failure_excerpt_candidate_path "$output_file" "$session_key")
	fi
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
	if [[ -n "$resource_sampler_pid" ]]; then
		printf '%s\n' "${_run_result_label:-failed}" >"$resource_result_file" 2>/dev/null || true
		printf 'done\n' >"$resource_stop_file" 2>/dev/null || true
		wait "$resource_sampler_pid" 2>/dev/null || true
		rm -f "$resource_stop_file" "$resource_result_file" 2>/dev/null || true
	fi
	local _metric_result_label="${_run_result_label:-fail""ed}"
	if ! _headless_run_is_ephemeral "$role"; then
		_metric_output_file=$(_metric_failure_excerpt_for_result "$_metric_result_label" "$_metric_excerpt_candidate" "$session_key")
	fi
	[[ -z "$_metric_excerpt_candidate" ]] || rm -f "$_metric_excerpt_candidate"
	local _launch_failure_cause="" _next_action=""
	local _evidence_fields
	_evidence_fields=$(_derive_worker_failure_evidence \
		"$_metric_result_label" "$exit_code" "${_run_activity_detected:-0}" \
		"${_metric_kill_reason:-}" "${_run_failure_reason:-}")
	_launch_failure_cause="${_evidence_fields%%$'\t'*}"
	_next_action="${_evidence_fields#*$'\t'}"
	if [[ "$_metric_result_label" == "watchdog_stall_killed" ]] &&
		_worker_post_pr_handoff_confirmed "$session_key" "$work_dir"; then
		_launch_failure_cause="post_pr_pending_ci_handoff"
		_next_action="monitor_open_pr"
	fi
	print_info "[lifecycle] worker_failure_evidence session=$session_key result=$_metric_result_label exit_code=$exit_code kill_reason=${_metric_kill_reason:-unknown} launch_failure_cause=${_launch_failure_cause:-none} next_action=${_next_action:-none}"
	append_runtime_metric "$role" "$session_key" "$selected_model" "$provider" "$_metric_result_label" "$handle_exit" "${_run_failure_reason:-}" "${_run_activity_detected:-0}" "$duration_ms" \
		"${WORKER_ISSUE_NUMBER:-}" "${DISPATCH_REPO_SLUG:-}" "$metric_work_dir" "$_metric_output_file" "$_metric_session_id" \
		"${_run_provider_error_type:-}" "${_run_provider_status:-}" "${_run_runtime_error_type:-}" "${_run_classification_source:-}" "${_run_classification_pattern:-}" \
		"$_launch_failure_cause" "${_metric_kill_reason:-}" "$_next_action"
	return "$handle_exit"
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
	if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" ]] && ! _headless_private_workload_enabled; then
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
	# Non-worker roles must shed inherited implementation-worker authority before
	# model selection, policy checks, canary execution, or detached launch. The
	# later prepare phase is intentionally after canary and is therefore too late
	# to establish this trust boundary.
	if [[ "$role" != "worker" ]]; then
		_hrw_prepare_role_context "$role" "$work_dir" || return 1
		if [[ "$role" == "$HEADLESS_ROLE_TRIAGE" ]]; then
			export AIDEVOPS_HEADLESS=1
			export AIDEVOPS_SESSION_ORIGIN="$HEADLESS_ROLE_TRIAGE"
			export AIDEVOPS_HEADLESS_AUTH_ISOLATION=1
		fi
	fi
	# Dynamically scoped into _cmd_run_finish so every exit path uses role-safe
	# cleanup without adding a role argument to the established finish contract.
	local _CMD_RUN_ROLE="$role"
	if [[ "$private_workload" -eq 1 ]]; then
		export AIDEVOPS_PRIVATE_WORKLOAD=1
		export AIDEVOPS_HEADLESS_AUTH_ISOLATION=1
		export WORKER_NO_EXIT_PUSH=1
		unset AIDEVOPS_WORKER_PREWARM_DIR
		unset AIDEVOPS_ATTEMPT_ID AIDEVOPS_ATTEMPT_STARTED_AT AIDEVOPS_CORRELATION_ID
		unset AIDEVOPS_DISPATCH_LEASE_DEVICE AIDEVOPS_DISPATCH_LEASE_TOKEN
		unset AIDEVOPS_PARENT_WORKER_ID AIDEVOPS_ROOT_WORKER_ID AIDEVOPS_RUN_ID
		unset AIDEVOPS_VERBOSE_LIFECYCLE AIDEVOPS_WORKER_ID AIDEVOPS_WORKER_PREFLIGHT_SENTINEL
		unset DISPATCH_REPO_SLUG WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_TARGET_BRANCH
		unset WORKER_WORKTREE_PATH _WORKER_WORKTREE_PATH
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
		return 0
	fi

	if [[ "$role" == "worker" ]]; then
		_ensure_worker_lineage "$session_key"
		_ensure_worker_attempt_identity
		# GH#23520: publish canonical worker-origin markers before canary,
		# sandbox passthrough, and downstream GitHub/signature helpers run.
		# The sandbox allowlist already forwards AIDEVOPS_*; legacy generic
		# HEADLESS/FULL_LOOP_HEADLESS markers are intentionally not required
		# past the clean-env boundary.
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
		print_info "[lifecycle] prelaunch_lease_renew_start session=$session_key pid=$$"
		if ! _hrw_renew_dispatch_prelaunch_lease "$session_key"; then
			print_warning "Dispatch prelaunch lease expired before worker startup — deferring session $session_key"
			_hrw_record_terminal_outcome "$session_key" "$_HRW_TELEMETRY_DEFERRED" "prelaunch_lease_renewal_failed"
			return 1
		fi
		print_info "[lifecycle] prelaunch_lease_renew_done session=$session_key pid=$$"
	fi

	print_info "[lifecycle] pre_model_select session=$session_key role=$role tier=${tier_override:-auto} pid=$$"
	local selected_model
	local choose_exit
	selected_model=$(choose_model "$role" "${model_override:-$initial_model}" "$tier_override") || {
		choose_exit=$?
		_cmd_run_finish "$session_key" "fail"
		return "$choose_exit"
	}
	print_info "[lifecycle] post_model_select session=$session_key model=$selected_model pid=$$"
	if ! vault_data_policy_check "$selected_model" "$title" "$prompt"; then
		_cmd_run_finish "$session_key" "fail"
		return 64
	fi

	# GH#17549: Version guard — runs on EVERY dispatch (not cached).
	# Something keeps upgrading opencode to 1.3.17 between canary checks.
	if ! _enforce_opencode_version_pin; then
		print_error "OpenCode version pin enforcement failed — aborting dispatch for session $session_key"
		_hrw_record_terminal_outcome "$session_key" "$_HRW_TELEMETRY_DEFERRED" "opencode_version_pin_failed"
		return 1
	fi
	# GH#17549: Canary smoke test — verify OpenCode can start and complete
	# an API call before committing to a full worker dispatch. Runs BEFORE
	# _cmd_run_prepare so a canary failure never posts a dispatch claim or
	# increments the fast-fail counter. Cached for CANARY_CACHE_TTL_SECONDS
	# (default 30 min) so it runs at most once per pulse cycle.
	print_info "[lifecycle] pre_canary session=$session_key model=$selected_model pid=$$"
	if ! _run_role_safe_canary "$role" "$selected_model"; then
		print_warning "Canary failed — aborting dispatch for session $session_key (no claim posted)"
		_hrw_record_terminal_outcome "$session_key" "deferred" "canary_failed"
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

	if [[ "$role" == "worker" ]]; then
		prompt=$(append_worker_headless_contract "$prompt")
	fi

	# GH#20542: DISPATCH_REPO_SLUG is now exported in _cmd_run_prepare (before
	# the EXIT trap is armed) so it is always available to _release_dispatch_claim.
	# _cmd_run_prepare is called immediately below; the export no longer needs to
	# live in _execute_run_attempt (which runs after the trap is already set).
	local prepare_exit
	prepare_exit=0
	local lifecycle_work_dir="$work_dir"
	if _headless_private_workload_enabled; then
		lifecycle_work_dir="[private]"
	fi
	print_info "[lifecycle] pre_worker_prepare session=$session_key work_dir=$lifecycle_work_dir pid=$$"
	_cmd_run_prepare "$session_key" "$work_dir" "$role" || prepare_exit=$?
	if [[ "$prepare_exit" -eq 2 ]]; then
		_hrw_record_terminal_outcome "$session_key" "deferred" "duplicate_session"
		return 0
	fi
	if [[ "$prepare_exit" -ne 0 ]]; then
		_hrw_record_terminal_outcome "$session_key" "failed" "worker_prepare_failed"
		return "$prepare_exit"
	fi
	print_info "[lifecycle] post_worker_prepare session=$session_key work_dir=$lifecycle_work_dir pid=$$"

	if [[ -z "$variant_override" ]] && ! _headless_private_workload_enabled; then
		variant_override=$(resolve_headless_variant "$role" "$tier_override" "$selected_model")
	fi

	# GH#17436: Continuation retry configuration.
	# When a worker exits prematurely (activity but no completion signal),
	# resume the session with a "continue" prompt instead of starting fresh.
	# This catches the GPT-5.4 failure mode of stopping after investigation/setup.
	local max_continuation_retries="${HEADLESS_CONTINUATION_MAX_RETRIES:-10}"
	local continuation_count=0
	local original_prompt="$prompt"

	# GH#17648: Watchdog stall continuation configuration.
	# When the watchdog kills a worker that was making progress (stream drop,
	# hung connection), try resuming the session before giving up. This
	# preserves all work done so far (worktree, files, partial implementation)
	# instead of starting fresh with a different provider.
	local max_watchdog_continue_retries="${HEADLESS_WATCHDOG_CONTINUE_MAX_RETRIES:-2}"
	local watchdog_continue_count=0
	local max_service_interruption_continue_retries="${HEADLESS_SERVICE_INTERRUPTION_CONTINUE_MAX_RETRIES:-2}"
	local service_interruption_continue_count=0
	local max_brief_recovery_retries="${HEADLESS_BRIEF_RECOVERY_MAX_RETRIES:-1}"
	local brief_recovery_count=0
	local max_reasoning_retry_count=0
	if _headless_run_is_ephemeral "$role"; then
		max_continuation_retries=0
		max_watchdog_continue_retries=0
		max_service_interruption_continue_retries=0
		max_brief_recovery_retries=0
	fi

	# GH#20681: Per-session stall caps — count and cumulative time.
	# Prevents unbounded token burn from repeated stall-continue events.
	# The stall_timeout_s is the watchdog's configured stall window, used to
	# approximate cumulative stall time (one STALL_TIMEOUT per stall event).
	local _stall_timeout_s="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-600}"
	[[ "$_stall_timeout_s" =~ ^[0-9]+$ ]] || _stall_timeout_s=600
	local _stall_continue_max="${WORKER_STALL_CONTINUE_MAX:-3}"
	[[ "$_stall_continue_max" =~ ^[0-9]+$ ]] || _stall_continue_max=3
	local _stall_cumulative_max_s="${WORKER_STALL_CUMULATIVE_MAX_S:-1800}"
	[[ "$_stall_cumulative_max_s" =~ ^[0-9]+$ ]] || _stall_cumulative_max_s=1800
	local _session_stall_count=0
	local _session_stall_cumulative_s=0

	local attempt=1
	local max_attempts=3
	if _headless_run_is_ephemeral "$role"; then
		max_attempts=1
	fi
	local cmd_run_action="retry"
	local cmd_run_next_model="$selected_model"
	local _run_failure_reason=""
	local _run_should_retry=0
	local _run_result_label="failed"
	local _run_activity_detected="0"
	local _run_metric_output_file=""
	local _run_metric_session_id=""
	local completion_state="complete"
	while [[ "$attempt" -le "$max_attempts" ]]; do
		_run_failure_reason=""
		_run_should_retry=0
		_run_result_label="failed"
		_run_activity_detected="0"
		local attempt_exit=0
		if _execute_run_attempt \
			"$role" "$session_key" "$work_dir" "$title" "$prompt" \
			"$selected_model" "$variant_override" "$agent_name" \
			"${extra_args[@]+"${extra_args[@]}"}"; then
			attempt_exit=0
		else
			attempt_exit=$?
		fi

		if [[ "$attempt_exit" -eq 0 ]]; then
			clear_startup_no_model_feedback "$selected_model"
			# GH#20721: Pass work_dir so _cmd_run_finish can detect no-op exits.
			_cmd_run_finish "$session_key" "$completion_state" "$work_dir"
			return $?
		fi
		if [[ "$attempt_exit" -eq 85 ]]; then
			_run_failure_reason="$_HRW_REASON_OWNERSHIP_LOST"
			_run_result_label="$_HRW_REASON_OWNERSHIP_LOST"
			_hrw_record_terminal_outcome "$session_key" "$_HRW_TELEMETRY_FAILED" "$_HRW_REASON_OWNERSHIP_LOST"
			_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL" "$work_dir"
			return 1
		fi

		# GH#21578 / t3021: Rate-limit fast-exit (exit 80).
		# _execute_run_attempt sets this when the 30s monitor detected a 429 or
		# provider-overload pattern before any LLM activity was produced.
		# Metric already recorded by _execute_run_attempt with result=rate_limit_fast.
		# Release the dispatch claim so the issue immediately re-queues on the
		# next pulse cycle. Do NOT call _cmd_run_finish "fail" — that would
		# increment the fast-fail counter and potentially apply NMR to the issue,
		# which is wrong for a transient API condition.
		if [[ "$attempt_exit" -eq 80 ]]; then
			print_warning "$selected_model rate_limit_fast — API 429/overload within first ${HEADLESS_RATE_LIMIT_DETECT_SECONDS:-30}s (transient, no NMR backoff)"
			# Pass _run_result_label (set to "rate_limit_fast" in _execute_run_attempt)
			# rather than repeating the literal here — keeps distinct-literal count at 2
			# (_execute_run_attempt assignment + _cmd_run_finish elif) and avoids the
			# repeated-string-literal ratchet gate (threshold: >=3 distinct occurrences).
			_cmd_run_finish "$session_key" "$_run_result_label"
			return 0
		fi

		if [[ "$attempt_exit" -eq 84 ]]; then
			_cmd_run_finish "$session_key" "$_run_result_label" "$work_dir"
			return $?
		fi

		# Issue #29088: a Sol high worker that reports a capability blocker gets
		# one direct retry at max reasoning. This is an internal terminal retry,
		# not a fourth authored workload tier. Other providers, variants, roles,
		# and non-capability failures keep their existing terminal behaviour.
		if [[ "$attempt_exit" -eq 83 ]]; then
			if _should_retry_sol_at_max \
				"$role" "$selected_model" "$variant_override" "$max_reasoning_retry_count"; then
				max_reasoning_retry_count=1
				variant_override="max"
				prompt="The previous Sol high attempt reported BLOCKED after working on the task. Retry the same objective once at maximum reasoning. Resume the existing session and worktree, challenge the blocker using the accumulated evidence, and continue autonomously through implementation and verification. Stop only at FULL_LOOP_COMPLETE or BLOCKED with concrete evidence that persists at max reasoning."
				print_warning "Sol high reported BLOCKED — retrying once at Sol max before accepting the blocker"
				continue
			fi

			_cmd_run_finish "$session_key" "$completion_state" "$work_dir"
			return $?
		fi

		# GH#23037: Handle transient service interruptions separately from
		# premature exits and watchdog stalls. The session/worktree evidence was
		# validated by _handle_run_result; resume the same session without
		# consuming provider-rotation attempts until this dedicated budget is spent.
		if [[ "$attempt_exit" -eq 81 ]]; then
			if [[ "$service_interruption_continue_count" -lt "$max_service_interruption_continue_retries" ]]; then
				service_interruption_continue_count=$((service_interruption_continue_count + 1))
				print_warning "service_interruption_continue attempt=${service_interruption_continue_count}/${max_service_interruption_continue_retries} — resuming existing session/worktree"
				prompt="A transient provider/service interruption stopped the previous run after work had begun. Resume the existing session and worktree; do not restart exploration. Check git status, existing todos, and prior changes, then continue through implementation, verification, commit, PR, merge summary, review, merge, release, closing comments, deploy, and cleanup. Do not stop until FULL_LOOP_COMPLETE or BLOCKED with evidence."
				continue
			fi

			local _sic_exhausted_label="service_interruption_exhausted"
			_run_result_label="$_sic_exhausted_label"
			_append_service_interruption_exhausted_metric \
				"$role" "$session_key" "$selected_model" "$work_dir" \
				"${_run_failure_reason:-provider_error}" \
				"${_run_metric_output_file:-}" "${_run_metric_session_id:-}"
			print_warning "Exhausted ${max_service_interruption_continue_retries} service-interruption continuations — falling through to normal failure handling"
		fi

		# GH#17436: Handle premature exit (exit 77) — worker had activity but
		# no completion signal. Resume the session with a continuation prompt
		# instead of recording a provider failure and rotating.
		if [[ "$attempt_exit" -eq 77 && "$continuation_count" -lt "$max_continuation_retries" ]]; then
			continuation_count=$((continuation_count + 1))
			print_warning "Premature exit detected — sending continuation prompt (attempt ${continuation_count}/${max_continuation_retries})"

			# Swap to a continuation prompt that reinforces headless completion.
			# The session ID is already stored; _execute_run_attempt will use
			# --session <id> --continue to resume the existing conversation.
			prompt="Continue through to completion. This is a headless session — no user is present and no user input is available to assist. You have set up the environment but have not yet completed the task. Check your todo list, implement the required code changes, commit, push, and create a PR. After PR creation, you MUST post the MERGE_SUMMARY comment (full-loop step 4.2.1) — the merge pass needs it for closing comments. Then continue through review, merge, and closing comments. Do not stop until the outcome is FULL_LOOP_COMPLETE or BLOCKED with evidence."

			# Continuation retries don't consume provider-rotation attempts
			# since the provider isn't at fault — the model stopped early.
			continue
		fi

		# If we exhausted continuation retries, classify as a real failure
		# so the fast-fail counter increments and tier escalation can trigger.
		if [[ "$attempt_exit" -eq 77 ]]; then
			_run_failure_reason="premature_exit"
			_run_result_label="premature_exit"
			print_warning "Exhausted ${max_continuation_retries} continuation retries — recording as premature_exit failure"
			_cmd_run_finish "$session_key" "fail"
			return 1
		fi

		# GH#23225: When a worker stops with BLOCKED: missing implementation
		# context, give the same session one chance to repair the linked issue
		# brief before the dispatcher records a terminal blocked outcome.
		if [[ "$attempt_exit" -eq 82 ]]; then
			if [[ "$brief_recovery_count" -lt "$max_brief_recovery_retries" ]]; then
				brief_recovery_count=$((brief_recovery_count + 1))
				print_warning "Missing implementation context detected — sending brief-recovery continuation (attempt ${brief_recovery_count}/${max_brief_recovery_retries})"

				prompt="The previous run ended with BLOCKED: missing implementation context. Before giving up, perform the GH#23225 brief-recovery routine once. Verify the linked issue number is \${WORKER_ISSUE_NUMBER}; read that issue body; keep discovery narrow using its title/body keywords, exact file search, and 2-3 likely target files/tests; then update only that linked issue body using --body-file with a Worker Guidance or How section containing Goal, files to inspect first, implementation steps, verification commands, runtime testing risk/expectation, existing reproduction context, and the aidevops signature footer. Mark in the issue body that brief recovery was attempted to avoid loops. After repairing the brief, re-run the full-loop implementation from the improved context and continue through implementation, verification, commit, PR, MERGE_SUMMARY, review, merge, closing comments, deploy, and cleanup. If narrow discovery still cannot produce concrete files and steps, emit BLOCKED: missing implementation context with evidence."
				continue
			fi

			_run_result_label="block""ed"
			_run_failure_reason="$_run_result_label"
			_run_classification_source="model_blocked""_signal"
			_run_classification_pattern="missing_implementation_context_recovery_exhausted"
			print_warning "Missing implementation context persisted after brief-recovery continuation — recording blocked"
			_cmd_run_finish "$session_key" "$completion_state" "$work_dir"
			return 0
		fi

		# t2956 / Issue #21231: Handle watchdog hard-kill (exit 79).
		# The watchdog escalated from passive (78 / continue) to proactive
		# (79 / killed) because total elapsed reached
		# WORKER_STALL_HARD_KILL_SECONDS while still stalled. Skip
		# continuation, skip provider rotation — record the
		# watchdog_stall_killed metric and free the slot for re-dispatch.
		# This is the per-attempt analogue of the existing per-session cap
		# (GH#20681) below: same outcome label, different trigger.
		if [[ "$attempt_exit" -eq 79 ]]; then
			# Accumulate per-session stall metrics so subsequent attempts
			# (if the dispatcher re-runs this issue) see prior cost.
			_session_stall_count=$((_session_stall_count + 1))
			_session_stall_cumulative_s=$((_session_stall_cumulative_s + _stall_timeout_s))
			print_warning "Watchdog hard-kill — recording watchdog_stall_killed (per-attempt elapsed cap, slot freed for re-dispatch)"
			# _run_result_label and _run_failure_reason were already set to
			# "watchdog_stall_killed" by _handle_run_result when it returned 79;
			# reuse them here instead of re-declaring the literal so the
			# repeated-string ratchet is not crossed.
			local _ledger_fail="fail"
			# _execute_run_attempt already emitted the context-rich terminal metric.
			# Do not append a second sparse row for the same hard-kill outcome.
			_cmd_run_finish "$session_key" "$_ledger_fail"
			return 1
		fi

		# GH#17648 / GH#20681: Handle watchdog stall with activity (exit 78).
		# The worker was making progress but the connection/stream dropped.
		# Track cumulative stall events per session and apply hard-kill caps
		# before retrying — unbounded stall-continue burns tokens indefinitely.
		if [[ "$attempt_exit" -eq 78 ]]; then
			# GH#27694: A worker can be killed after its PR merged and issue
			# closed. Confirm that external terminal state before any continuation
			# can seed another isolated database or launch another runtime. Unknown
			# or failed GitHub reads return non-zero and preserve normal recovery.
			if _worker_external_terminal_complete "$session_key" "$work_dir"; then
				print_info "[lifecycle] exit-78 continuation skipped — external terminal state already complete"
				_cmd_run_finish "$session_key" "fail" "$work_dir" "1"
				return 0
			fi
			if [[ "${_run_failure_reason:-}" == "startup_no_model_activity" ]]; then
				record_startup_no_model_feedback "$selected_model"
			fi
			# Accumulate per-session stall metrics (one stall = one STALL_TIMEOUT).
			_session_stall_count=$((_session_stall_count + 1))
			_session_stall_cumulative_s=$((_session_stall_cumulative_s + _stall_timeout_s))

			# GH#20681: Check session-level hard caps: count OR cumulative time.
			# Either trigger → record watchdog_stall_killed and stop the session.
			if _stall_session_cap_exceeded \
				"$_session_stall_count" "$_session_stall_cumulative_s" \
				"$_stall_continue_max" "$_stall_cumulative_max_s"; then
				print_warning "Watchdog stall cap exceeded (stalls=${_session_stall_count}/${_stall_continue_max}, cumulative=${_session_stall_cumulative_s}s/${_stall_cumulative_max_s}s) — recording watchdog_stall_killed"
				# t2956: Reuse the same local already declared earlier in this
				# block so the literal "watchdog_stall_killed" stays under the
				# repeated-string ratchet. The hard-kill (exit 79) and
				# session-cap (exit 78 cap-exceeded) branches both record the
				# same outcome label.
				local _hk_label="watchdog_stall_killed"
				_run_result_label="$_hk_label"
				_run_failure_reason="$_hk_label"
				append_runtime_metric "$role" "$session_key" "$selected_model" \
					"$(extract_provider "$selected_model")" \
					"$_run_result_label" "143" "$_run_failure_reason" "1" "0"
				_cmd_run_finish "$session_key" "fail"
				return 1
			fi

			# Within session cap: try per-attempt continuations first.
			if [[ "$watchdog_continue_count" -lt "$max_watchdog_continue_retries" ]]; then
				watchdog_continue_count=$((watchdog_continue_count + 1))
				print_warning "Watchdog stall with activity — resuming session (attempt ${watchdog_continue_count}/${max_watchdog_continue_retries}, session stalls=${_session_stall_count}/${_stall_continue_max})"

				# Resume with a prompt that explains the connection drop.
				# Session ID was stored by _handle_run_result before returning 78.
				prompt="Your previous connection dropped mid-session and the process was restarted. All your prior work (worktree, file changes, commits) is still on disk. Resume where you left off — check git status, your todo list, and continue through to completion. Do not restart from scratch. Do not stop until the outcome is FULL_LOOP_COMPLETE or BLOCKED with evidence."

				# Watchdog continuations don't consume provider-rotation attempts.
				continue
			fi

			# Exhausted per-attempt continuations — fall through to provider rotation.
			print_warning "Exhausted ${max_watchdog_continue_retries} watchdog continuation retries — falling through to provider rotation (session stalls=${_session_stall_count}/${_stall_continue_max})"
			# Don't return — let it fall through to _cmd_run_prepare_retry
			# which will rotate to a different provider/model.
		fi

		_cmd_run_prepare_retry \
			"$role" "$session_key" "$model_override" "$attempt" \
			"$max_attempts" "$selected_model" "$attempt_exit" "$tier_override" || return $?
		if [[ "$cmd_run_action" == "switch" ]]; then
			selected_model="$cmd_run_next_model"
		fi
		attempt=$((attempt + 1))
	done

	# Unreachable: loop always executes (attempt starts at 1, max_attempts=3)
	# and every path inside returns explicitly. Kept as defensive fallback.
	_cmd_run_finish "$session_key" "fail"
	return 1
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
  headless-runtime-helper.sh run --role pulse|worker|triage --session-key KEY --dir PATH --title TITLE (--prompt TEXT | --prompt-file FILE) [--model provider/model | --initial-model provider/model] [--tier simple|standard|thinking] [--variant NAME] [--agent NAME] [--runtime opencode|claude] [--opencode-arg ARG] [--private-workload --private-profile-sha256 HASH] [--detach]
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
