#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Wrapper Cycle Helpers -- Per-cycle execution helpers
# =============================================================================
# Repo refresh, pulse runner, LLM supervisor wrapper, cache priming, TODO
# ref sync, and the sourced-detection helper. Extracted from
# pulse-wrapper.sh (GH#21311 / t2936-child) to bring the orchestrator
# below the 1500-line file-size-debt threshold. No behavioural changes.
#
# Usage: source "${SCRIPT_DIR}/pulse-wrapper-cycle.sh"
#
# Dependencies:
#   - shared-constants.sh (logging primitives via worker-lifecycle-common.sh)
#   - pulse-todo-sync-workspace.sh (owned isolated-clone lifecycle)
#   - pulse-wrapper-config.sh (LOGFILE, WRAPPER_LOGFILE, PULSE_DIR, PIDFILE,
#     LOCKDIR, STATE_FILE, HEADLESS_RUNTIME_HELPER, PULSE_MODEL,
#     PULSE_COLD_START_TIMEOUT[_UNDERFILLED], _PULSE_REFRESHED_THIS_CYCLE
#     associative array)
#   - pulse-watchdog.sh (_run_pulse_watchdog)
#   - pulse-instance-lock.sh (release_instance_lock, _handle_stale_llm_lock)
#   - pulse-capacity.sh (_compute_initial_underfill, _run_early_exit_recycle_loop)
#   - pulse-canonical-recovery.sh (pulse_canonical_recover, optional)
#   - pulse-cache-prime.sh (companion script invoked at runtime)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_WRAPPER_CYCLE_LIB_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_CYCLE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if [[ -f "${SCRIPT_DIR}/pulse-todo-sync-workspace.sh" ]]; then
	# shellcheck source=pulse-todo-sync-workspace.sh
	source "${SCRIPT_DIR}/pulse-todo-sync-workspace.sh"
fi

#######################################
# t2433/GH#20071: Refresh a repo from remote before the large-file gate
# measures it. Without this, stale local checkouts (post-split-PR) cause
# the gate to fire on pre-split line counts, creating spurious file-size-debt
# issues every cycle until a worker dispatch triggers a pull independently.
#
# Idempotent within a process: uses _PULSE_REFRESHED_THIS_CYCLE (associative
# array declared in pulse-wrapper-config.sh) as a cycle-scoped sentinel
# keyed by repo_path. The first call for a given path diagnoses remote drift;
# subsequent calls in the same process are no-ops. The
# array is inherited empty by every subshell (dispatch subshell,
# run_stage_with_timeout fork) so each independent context starts fresh
# — this is intentional: each context needs at most one diagnostic per repo.
#
# Canonical automation remains read-only: ls-remote compares the remote tip
# without mutating the checkout, and the audited recovery helper owns repairs.
#
# GH#17584 context preserved: the original motivation for pulling before
# worker dispatch (workers close issues as "Invalid — file does not exist"
# on stale checkouts) is covered here at the EARLIER point — before any
# gate evaluation — rather than the later worker-launch point.
#
# Arguments:
#   $1 - repo_path: absolute path to the git working tree to refresh
# Returns: always 0 (failures are logged but never fatal — callers proceed
#   with current checkout, same as the previous git pull || { warn; } pattern)
#######################################
_pulse_refresh_default_branch() {
	local repo_path="$1"
	local default_branch=""

	if declare -F _get_default_branch_for_repo >/dev/null 2>&1; then
		default_branch=$(_get_default_branch_for_repo "$repo_path" 2>/dev/null) || default_branch=""
	else
		default_branch=$(git -C "$repo_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || default_branch=""
		default_branch="${default_branch#origin/}"
	fi

	[[ -n "$default_branch" ]] || return 1
	printf '%s\n' "$default_branch"
	return 0
}

_pulse_refresh_should_skip_repo() {
	local repo_path="$1"
	local default_branch=""
	local current_branch=""
	local upstream_ref=""
	local upstream_remote=""
	local upstream_branch=""

	default_branch=$(_pulse_refresh_default_branch "$repo_path") || default_branch=""

	if [[ -z "$default_branch" ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: refresh skipped: noncanonical or missing upstream for ${repo_path} — no origin/HEAD set" >>"$LOGFILE"
		return 0
	fi

	current_branch=$(git -C "$repo_path" symbolic-ref --quiet --short HEAD 2>/dev/null) || current_branch=""
	if [[ -z "$current_branch" ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: refresh skipped: noncanonical or missing upstream for ${repo_path} — detached HEAD" >>"$LOGFILE"
		return 0
	fi

	if [[ "$current_branch" != "$default_branch" ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: refresh skipped: noncanonical or missing upstream for ${repo_path} — on ${current_branch}, expected ${default_branch}" >>"$LOGFILE"
		return 0
	fi

	upstream_ref=$(git -C "$repo_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || upstream_ref=""
	if [[ -z "$upstream_ref" || "$upstream_ref" != */* ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: refresh skipped: noncanonical or missing upstream for ${repo_path} — upstream is not configured" >>"$LOGFILE"
		return 0
	fi

	upstream_remote="${upstream_ref%%/*}"
	upstream_branch="${upstream_ref#*/}"
	if [[ "$upstream_remote" != "origin" || "$upstream_branch" != "$default_branch" ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: refresh skipped: noncanonical or missing upstream for ${repo_path} — upstream ${upstream_ref} is not origin/${default_branch}" >>"$LOGFILE"
		return 0
	fi

	local ls_remote_exit=0
	git -C "$repo_path" ls-remote --exit-code "$upstream_remote" "refs/heads/${upstream_branch}" >/dev/null 2>&1 || ls_remote_exit=$?
	if [[ "$ls_remote_exit" -eq 2 ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: refresh skipped: noncanonical or missing upstream for ${repo_path} — upstream ${upstream_ref} does not exist" >>"$LOGFILE"
		return 0
	fi
	if [[ "$ls_remote_exit" -ne 0 ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: refresh skipped: could not verify upstream ${upstream_ref} for ${repo_path} — git ls-remote exited ${ls_remote_exit}" >>"$LOGFILE"
		return 0
	fi

	return 1
}

_pulse_refresh_repo() {
	local repo_path="$1"
	[[ -n "$repo_path" ]] || return 0

	# Sentinel: already refreshed this repo in this process context.
	if [[ "${_PULSE_REFRESHED_THIS_CYCLE[$repo_path]+_}" ]]; then
		return 0
	fi
	# Mark immediately so concurrent callers in the same process don't duplicate diagnostics.
	_PULSE_REFRESHED_THIS_CYCLE[$repo_path]=1

	if ! git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "[pulse-wrapper] _pulse_refresh_repo: ${repo_path} is not a git work-tree — skipping" >>"$LOGFILE"
		return 0
	fi
	if _pulse_refresh_should_skip_repo "$repo_path"; then
		return 0
	fi

	local default_branch="" remote_sha="" local_sha=""
	default_branch=$(_pulse_refresh_default_branch "$repo_path") || default_branch=""
	if [[ -n "$default_branch" ]]; then
		remote_sha=$(git -C "$repo_path" ls-remote origin "refs/heads/${default_branch}" 2>/dev/null | awk 'NR == 1 {print $1}') || remote_sha=""
	fi
	local_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)
	if [[ -z "$remote_sha" ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: remote diagnostic failed for ${repo_path} — canonical checkout unchanged" >>"$LOGFILE"
	elif [[ "$local_sha" != "$remote_sha" ]]; then
		echo "[pulse-wrapper] _pulse_refresh_repo: diagnostic: ${repo_path} differs from origin/${default_branch}; canonical checkout unchanged" >>"$LOGFILE"
	fi
	if declare -F pulse_canonical_recover >/dev/null 2>&1; then
		pulse_canonical_recover "$repo_path" >>"$LOGFILE" 2>&1 || true
	fi
	return 0
}

_pulse_supervisor_prompt() {
	local pulse_command="$1"
	local state_file="$2"
	local prompt="$pulse_command"

	prompt="${pulse_command}

Runtime sandbox rule: supervisor-pulse is launched from the aidevops agent workspace. Do not run Bash tool calls with workdir set to managed repository paths or any other directory outside that workspace. Use the pre-fetched state file and wrapper/helper functions from the current workspace instead. If repo/worktree data is missing, record a diagnostic and exit cleanly rather than requesting external_directory permission."
	if [[ -f "$state_file" ]]; then
		prompt="${prompt}

Pre-fetched state file: ${state_file}
Read this file before proceeding — it contains the current repo/PR/issue state
gathered by pulse-wrapper.sh BEFORE this session started."
	fi

	printf '%s\n' "$prompt"
	return 0
}

run_pulse() {
	local underfilled_mode="${1:-0}"
	local underfill_pct="${2:-0}"
	# trigger_mode: "daily_sweep" uses /pulse-sweep (full edge-case agent);
	# "stall" and "first_run" use /pulse (lightweight dispatch+merge agent).
	local trigger_mode="${3:-stall}"
	local effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT"
	if [[ "$underfilled_mode" == "1" ]]; then
		effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT_UNDERFILLED"
	fi
	[[ "$underfill_pct" =~ ^[0-9]+$ ]] || underfill_pct=0
	if [[ "$effective_cold_start_timeout" -gt "$PULSE_COLD_START_TIMEOUT" ]]; then
		effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT"
	fi

	local start_epoch
	start_epoch=$(date +%s)
	echo "[pulse-wrapper] Starting pulse at $(date -u +%Y-%m-%dT%H:%M:%SZ) (trigger=${trigger_mode})" >>"$WRAPPER_LOGFILE"
	echo "[pulse-wrapper] Watchdog cold-start timeout: ${effective_cold_start_timeout}s (underfilled_mode=${underfilled_mode}, underfill_pct=${underfill_pct})" >>"$LOGFILE"

	# Select agent prompt based on trigger mode:
	#   daily_sweep → /pulse-sweep (full edge-case triage, quality review, mission awareness)
	#   stall / first_run → /pulse (lightweight dispatch+merge, unblocks the stall faster)
	# The state is NOT inlined into the prompt — on Linux, execve() enforces
	# MAX_ARG_STRLEN (128KB per argument) and the state routinely exceeds this,
	# causing "Argument list too long" on every pulse invocation. The agent
	# reads the file via its Read tool instead. See: #4257
	local pulse_command="/pulse"
	if [[ "$trigger_mode" == "daily_sweep" ]]; then
		pulse_command="/pulse-sweep"
	fi
	local prompt
	prompt=$(_pulse_supervisor_prompt "$pulse_command" "$STATE_FILE")

	# Run the provider-aware headless wrapper in background.
	local -a pulse_cmd=("$HEADLESS_RUNTIME_HELPER" run --role pulse --session-key supervisor-pulse --dir "$PULSE_DIR" --title "Supervisor Pulse" --agent Automate --prompt "$prompt" --tier standard)
	if [[ -n "$PULSE_MODEL" ]]; then
		pulse_cmd+=(--model "$PULSE_MODEL")
	fi
	# t3053: Route supervisor stdout to /dev/null to prevent OpenCode's
	# --format json event stream from contaminating pulse.log. The JSON
	# events from the supervisor were flowing: opencode --format json →
	# tee "$output_file" → stdout → >>"$LOGFILE", polluting pulse.log
	# with multi-KB tool_use JSON blobs that break line-oriented log
	# analysis (grep, pulse-diagnose-helper.sh). Diagnostic messages from
	# headless-runtime-helper.sh still reach pulse.log via stderr (2>>),
	# and worker dispatch log lines continue to write via explicit
	# >>"$LOGFILE" calls. The watchdog's progress detection is unaffected
	# because worker dispatches (echo "[dispatch_with_dedup] Dispatched
	# worker..." >>"$LOGFILE") keep pulse.log growing during active cycles.
	"${pulse_cmd[@]}" >/dev/null 2>>"$LOGFILE" &

	local opencode_pid=$!
	echo "$opencode_pid" >"$PIDFILE"

	echo "[pulse-wrapper] opencode PID: $opencode_pid" >>"$LOGFILE"

	# Run the watchdog loop (checks stale/idle/progress, guards children)
	_run_pulse_watchdog "$opencode_pid" "$start_epoch" "$effective_cold_start_timeout"

	# Write IDLE sentinel — never delete the PID file (GH#4324).
	echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"

	local end_epoch
	end_epoch=$(date +%s)
	local duration=$((end_epoch - start_epoch))
	echo "[pulse-wrapper] Pulse completed at $(date -u +%Y-%m-%dT%H:%M:%SZ) (ran ${duration}s)" >>"$LOGFILE"
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_maybe_run_llm_supervisor
#
# Guarded LLM supervisor invocation. When _should_run_llm_supervisor signals
# the deterministic backlog is stalled or the daily sweep is due (or
# PULSE_FORCE_LLM=1 overrides), acquires the LLM lock (separate from the
# instance lock so deterministic 2-min cycles aren't blocked) and invokes
# run_pulse() with the appropriate trigger_mode. Records the run epoch and
# kicks off the early-exit recycle loop on completion.
# ---------------------------------------------------------------------------
_PULSE_LLM_LOCKDIR_OWNED="${_PULSE_LLM_LOCKDIR_OWNED:-}"

_pulse_release_llm_lock() {
	local llm_lockdir="${_PULSE_LLM_LOCKDIR_OWNED:-}"
	local lock_pid=""
	[[ -n "$llm_lockdir" ]] || return 0
	_PULSE_LLM_LOCKDIR_OWNED=""
	if [[ -f "${llm_lockdir}/pid" ]]; then
		read -r lock_pid <"${llm_lockdir}/pid" || lock_pid=""
	fi
	if [[ "$lock_pid" != "$$" ]]; then
		printf '[pulse-wrapper] LLM lock cleanup skipped: owner changed from PID %s to %s\n' \
			"$$" "${lock_pid:-unknown}" >>"${WRAPPER_LOGFILE:-/dev/null}"
		return 0
	fi
	rm -rf "$llm_lockdir" 2>/dev/null || true
	return 0
}

_pulse_record_llm_attempt() {
	local trigger_mode="$1"
	local attempt_epoch
	attempt_epoch=$(date +%s)
	printf '%s\n' "$attempt_epoch" >"${PULSE_DIR}/last_llm_attempt_epoch" 2>/dev/null || return 1
	printf '%s\n' "$trigger_mode" >"${PULSE_DIR}/last_llm_attempt_mode" 2>/dev/null || true
	echo "[pulse-wrapper] LLM supervisor attempt started (trigger=${trigger_mode}, epoch=${attempt_epoch})" >>"$LOGFILE"
	return 0
}

_pulse_record_llm_success() {
	local trigger_mode="$1"
	local success_epoch
	success_epoch=$(date +%s)
	printf '%s\n' "$success_epoch" >"${PULSE_DIR}/last_llm_success_epoch" 2>/dev/null || return 1
	# Keep the legacy file as successful-completion state for older helpers.
	printf '%s\n' "$success_epoch" >"${PULSE_DIR}/last_llm_run_epoch" 2>/dev/null || return 1
	printf '%s\n' "$trigger_mode" >"${PULSE_DIR}/last_llm_success_mode" 2>/dev/null || true
	echo "[pulse-wrapper] LLM supervisor completed successfully (trigger=${trigger_mode}, epoch=${success_epoch})" >>"$LOGFILE"
	return 0
}

_pulse_record_llm_failure() {
	local trigger_mode="$1"
	local exit_code="$2"
	echo "[pulse-wrapper] LLM supervisor failed (trigger=${trigger_mode}, rc=${exit_code}); success timestamp unchanged" >>"$LOGFILE"
	return 0
}

_pulse_maybe_run_llm_supervisor() {
	local skip_llm=false
	local llm_trigger_mode="stall"
	local llm_lockdir="${LOCKDIR}.llm"
	local _llm_lock_acquired=0
	local _llm_lock_checked=0
	if [[ "${PULSE_FORCE_LLM:-0}" != "1" ]] && ! _should_run_llm_supervisor; then
		skip_llm=true
		echo "[pulse-wrapper] Skipping LLM supervisor (backlog progressing, daily sweep not due)" >>"$LOGFILE"
	else
		if [[ -f "${PULSE_DIR}/llm_trigger_mode" ]]; then
			llm_trigger_mode=$(cat "${PULSE_DIR}/llm_trigger_mode" 2>/dev/null) || llm_trigger_mode="stall"
		fi
		if [[ "${PULSE_FORCE_LLM:-0}" == "1" && "$llm_trigger_mode" == "stall" ]]; then
			llm_trigger_mode="daily_sweep"
		fi
	fi

	if [[ -d "$llm_lockdir" ]]; then
		_llm_lock_checked=1
		if _handle_stale_llm_lock "$llm_lockdir"; then
			# GH#20613/GH#26550: stale lock reclaimed — we now own it.
			_llm_lock_acquired=1
		fi
	fi
	if [[ "$_llm_lock_acquired" -eq 1 ]]; then
		_PULSE_LLM_LOCKDIR_OWNED="$llm_lockdir"
		printf '%s\n' "$$" >"${llm_lockdir}/pid" 2>/dev/null || true
	fi

	if [[ "$skip_llm" == "true" ]]; then
		if [[ "$_llm_lock_acquired" -eq 1 ]]; then
			# GH#26550: skip cycles only perform cleanup. _handle_stale_llm_lock
			# re-acquires after clearing, so release the reclaimed LLM lock instead
			# of leaving a self-created lock behind until the next eligible cycle.
			_pulse_release_llm_lock
		fi
		return 0
	fi

	# Use a separate LLM lock so only one LLM session runs at a time,
	# without blocking the deterministic 2-min cycle.
	if [[ "$_llm_lock_acquired" -ne 1 ]]; then
		if mkdir "$llm_lockdir" 2>/dev/null; then
			_llm_lock_acquired=1
		elif [[ "$_llm_lock_checked" -ne 1 && -d "$llm_lockdir" ]] && _handle_stale_llm_lock "$llm_lockdir"; then
			# GH#20613: stale lock reclaimed — we now own it
			_llm_lock_acquired=1
		fi
	fi

	if [[ "$_llm_lock_acquired" -eq 1 ]]; then
		_PULSE_LLM_LOCKDIR_OWNED="$llm_lockdir"
		printf '%s\n' "$$" >"${llm_lockdir}/pid" 2>/dev/null || true

		local underfill_output
		underfill_output=$(_compute_initial_underfill)
		local initial_underfilled_mode="" initial_underfill_pct=""
		initial_underfilled_mode=$(echo "$underfill_output" | sed -n '1p')
		initial_underfill_pct=$(echo "$underfill_output" | sed -n '2p')

		local pulse_start_epoch="" pulse_rc=""
		pulse_start_epoch=$(date +%s)
		_pulse_record_llm_attempt "$llm_trigger_mode" || true
		pulse_rc=0
		run_pulse "$initial_underfilled_mode" "$initial_underfill_pct" "$llm_trigger_mode" || pulse_rc=$?
		local pulse_end_epoch
		pulse_end_epoch=$(date +%s)
		local pulse_duration=$((pulse_end_epoch - pulse_start_epoch))

		if [[ "$pulse_rc" -eq 0 ]]; then
			_pulse_record_llm_success "$llm_trigger_mode" || true
			_run_early_exit_recycle_loop "$pulse_duration"
		else
			_pulse_record_llm_failure "$llm_trigger_mode" "$pulse_rc"
		fi
		_pulse_release_llm_lock
	fi
	return 0
}

# t2994: cache priming with staleness gate. Called from main() once per
# launchd invocation, but only fires if the sentinel is missing or older
# than $_prime_max_age seconds (default 1800 = 30 min, override via
# AIDEVOPS_PULSE_PRIME_MAX_AGE). Steady-state launchd respawns (every 120s)
# hit a fresh sentinel and skip — prefetch_state inside the cycle keeps
# caches warm naturally. Post-deploy first invocations and long quiet
# periods trigger an actual prime. Non-fatal — a prime failure must not
# abort the cycle. Honours AIDEVOPS_SKIP_CACHE_PRIME=1 for debug.
#
# Moved here from pulse-lifecycle-helper.sh::_start (t2992) because
# launchd's KeepAlive bypasses the helper — auto-respawn within the
# helper's stop→sleep→start window means _start's _is_running early-return
# skips priming entirely, and the original t2992 hook never fired during
# launchd-managed restarts (the canonical path on macOS).
_pulse_prime_caches_if_stale() {
	[[ "${AIDEVOPS_SKIP_CACHE_PRIME:-0}" == "1" ]] && return 0

	local _prime_helper=""
	local _prime_sentinel=""
	local _prime_max_age=""
	_prime_helper="${SCRIPT_DIR}/pulse-cache-prime.sh"
	_prime_sentinel="${HOME}/.aidevops/cache/pulse-cache-prime-last-run"
	_prime_max_age="${AIDEVOPS_PULSE_PRIME_MAX_AGE:-1800}"
	[[ "$_prime_max_age" =~ ^[0-9]+$ ]] || _prime_max_age=1800

	mkdir -p "$(dirname "$_prime_sentinel")"
	[[ ! -x "$_prime_helper" ]] && return 0

	local _should_prime=0
	if [[ ! -f "$_prime_sentinel" ]]; then
		_should_prime=1
	else
		local _now_epoch="" _stamp_epoch="" _age_s=""
		_now_epoch=$(date +%s 2>/dev/null)
		_stamp_epoch=$(_file_mtime_epoch "$_prime_sentinel")
		_age_s=$((${_now_epoch:-0} - ${_stamp_epoch:-0}))
		[[ "$_age_s" -gt "$_prime_max_age" ]] && _should_prime=1
	fi

	if [[ "$_should_prime" == "1" ]]; then
		printf '[pulse-wrapper] Pre-warming pulse caches (t2992 + t2994 stale-gate)...\n' >&2
		"$_prime_helper" >/dev/null 2>&1 || printf '[pulse-wrapper] WARN: cache prime returned non-zero (non-fatal — first cycle may be slow)\n' >&2
	fi
	return 0
}

#######################################
# _pulse_check_runaway_log — sentinel-gated runaway-log detector (GH#21756)
#
# Calls pulse-log-runaway-detector.sh check-and-heal every 5 minutes
# (configurable via PULSE_RUNAWAY_LOG_CHECK_INTERVAL). Catches wrapper
# log growing at MB/s from tight error loops before disk fills.
# Modelled on _pulse_prime_caches_if_stale (t2994).
#
# Fail-open: any internal error returns 0. Never blocks the pulse cycle.
#######################################
_pulse_check_runaway_log() {
	[[ "${AIDEVOPS_SKIP_RUNAWAY_LOG_CHECK:-0}" == "1" ]] && return 0

	local _detector_helper=""
	local _detector_sentinel=""
	local _detector_max_age=""
	_detector_helper="${SCRIPT_DIR}/pulse-log-runaway-detector.sh"
	_detector_sentinel="${HOME}/.aidevops/cache/pulse-runaway-log-check-last-run"
	_detector_max_age="${PULSE_RUNAWAY_LOG_CHECK_INTERVAL:-300}"
	[[ "$_detector_max_age" =~ ^[0-9]+$ ]] || _detector_max_age=300

	mkdir -p "$(dirname "$_detector_sentinel")" 2>/dev/null || return 0
	[[ ! -x "$_detector_helper" ]] && return 0

	local _should_check=0
	if [[ ! -f "$_detector_sentinel" ]]; then
		_should_check=1
	else
		local _now_epoch="" _stamp_epoch="" _age_s=""
		_now_epoch=$(date +%s 2>/dev/null)
		_stamp_epoch=$(_file_mtime_epoch "$_detector_sentinel")
		_age_s=$((${_now_epoch:-0} - ${_stamp_epoch:-0}))
		[[ "$_age_s" -gt "$_detector_max_age" ]] && _should_check=1
	fi

	if [[ "$_should_check" == "1" ]]; then
		"$_detector_helper" check-and-heal 2>>"$WRAPPER_LOGFILE" || true
		# Touch sentinel regardless of outcome (fail-open)
		touch "$_detector_sentinel" 2>/dev/null || true
	fi
	return 0
}

_pulse_reconcile_stale_blocked_if_due() {
	[[ "${AIDEVOPS_SKIP_STALE_BLOCKED_RECONCILE:-0}" == "1" ]] && return 0
	local sentinel="${HOME}/.aidevops/cache/pulse-stale-blocked-reconcile-last-run"
	local interval="${PULSE_STALE_BLOCKED_RECONCILE_INTERVAL:-1800}"
	local now_epoch="" stamp_epoch="" age_s="" repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local repo_slug="" failures=0
	[[ "$interval" =~ ^[0-9]+$ ]] || interval=1800
	[[ -f "$repos_json" ]] || return 0
	if [[ -f "$sentinel" ]]; then
		now_epoch=$(date +%s 2>/dev/null) || return 0
		stamp_epoch=$(_file_mtime_epoch "$sentinel")
		age_s=$((now_epoch - ${stamp_epoch:-0}))
		[[ "$age_s" -ge "$interval" ]] || return 0
	fi
	mkdir -p "${sentinel%/*}" 2>/dev/null || return 0
	while IFS= read -r repo_slug; do
		[[ -n "$repo_slug" ]] || continue
		reconcile_stale_blocked_issues "$repo_slug" 2>>"$LOGFILE" || failures=$((failures + 1))
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null || true)
	touch "$sentinel" 2>/dev/null || true
	echo "[pulse-wrapper] stale-blocked reconciliation completed failures=${failures} cadence=${interval}s" >>"$LOGFILE"
	return 0
}

#######################################
# _pulse_create_todo_sync_workspace
#
# Clone the current remote default branch into an isolated automation
# workspace. The registered human checkout is used only to resolve origin.
#######################################
_pulse_create_todo_sync_workspace() {
	local repo_path="$1"
	local repo_slug="$2"
	local remote_url=""
	: "$repo_slug"
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
	[[ -n "$remote_url" ]] || return 1
	declare -F _ptsw_create_workspace >/dev/null 2>&1 || return 1
	_ptsw_create_workspace "$remote_url"
	return $?
}

_pulse_todo_sync_exit_cleanup() {
	local original_rc="$1"
	local workspace_root="$2"
	local repo_slug="$3"
	local lifecycle_stage="$4"
	local owner_pid="$5"
	local owner_start="$6"
	local workspace_identity=""
	[[ -n "$workspace_root" ]] || return "$original_rc"
	workspace_identity=$(_ptsw_safe_identity "$workspace_root")
	if _ptsw_remove_owned_workspace "$workspace_root" "$owner_pid" "$owner_start"; then
		printf '[pulse-wrapper] TODO ref sync workspace cleanup outcome=removed stage=%s repo=%s workspace=%s\n' \
			"$lifecycle_stage" "$repo_slug" "$workspace_identity" >>"$WRAPPER_LOGFILE"
	else
		printf '[pulse-wrapper] TODO ref sync workspace cleanup outcome=failure stage=%s repo=%s workspace=%s\n' \
			"$lifecycle_stage" "$repo_slug" "$workspace_identity" >>"$WRAPPER_LOGFILE"
	fi
	return "$original_rc"
}

_pulse_run_issue_sync_stage() {
	local script_dir="$1"
	local stage="$2"
	local repo_slug="$3"
	local workspace="$4"
	"$BASH" "${script_dir}/issue-sync-helper.sh" "$stage" \
		--repo "$repo_slug" --project-root "$workspace" 2>&1
	return $?
}

#######################################
# sync_todo_refs_for_repo
#
# Pull issue→TODO refs, close completed entries, and reopen entries whose
# linked issue reopened. Reconciliation runs from a fresh remote clone and
# publishes allowlisted planning paths through the fenced publisher. Failures
# are logged and returned so the caller can continue other repositories while
# preserving retryable evidence.
#######################################
sync_todo_refs_for_repo() (
	local repo_slug="$1"
	local repo_path="$2"
	local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
	local workspace="" base_sha="" branch_name="" changed_paths=""
	local stage="" sync_failed=0 publication_rc=0
	local lifecycle_stage="workspace"
	local _pulse_todo_sync_exit_rc=0
	_PULSE_TODO_SYNC_WORKSPACE=""
	_PULSE_TODO_SYNC_WORKSPACE_ROOT=""
	_PULSE_TODO_SYNC_OWNER_PID=""
	_PULSE_TODO_SYNC_OWNER_START=""
	trap '_pulse_todo_sync_exit_cleanup "$?" "$_PULSE_TODO_SYNC_WORKSPACE_ROOT" "$repo_slug" "$lifecycle_stage" "$_PULSE_TODO_SYNC_OWNER_PID" "$_PULSE_TODO_SYNC_OWNER_START"; _pulse_todo_sync_exit_rc=$?; trap - EXIT; exit "$_pulse_todo_sync_exit_rc"' EXIT
	trap 'exit 143' TERM
	trap 'exit 130' INT
	trap 'exit 129' HUP

	lifecycle_stage="clone"
	_pulse_create_todo_sync_workspace "$repo_path" "$repo_slug" || {
		printf '[pulse-wrapper] TODO ref sync status=retryable_failure stage=workspace repo=%s\n' \
			"$repo_slug" >>"$WRAPPER_LOGFILE"
		return 1
	}
	workspace="$_PULSE_TODO_SYNC_WORKSPACE"
	lifecycle_stage="metadata"
	base_sha=$(git -C "$workspace" rev-parse HEAD 2>/dev/null) || {
		return 1
	}
	branch_name=$(git -C "$workspace" symbolic-ref --short HEAD 2>/dev/null) || {
		return 1
	}

	printf '[pulse-wrapper] Syncing TODO refs: repo=%s root=automation base=%s\n' \
		"$repo_slug" "${base_sha:0:12}" >>"$WRAPPER_LOGFILE"
	for stage in pull close reopen; do
		lifecycle_stage="$stage"
		if ! _pulse_run_issue_sync_stage "$script_dir" "$stage" "$repo_slug" "$workspace"; then
			printf '[pulse-wrapper] TODO ref sync status=retryable_failure stage=%s repo=%s\n' \
				"$stage" "$repo_slug" >>"$WRAPPER_LOGFILE"
			sync_failed=1
		fi
	done
	# Materialize TODO dependency edges before the graph and dispatch stages.
	# Failures remain retryable and the relationship helper moves affected
	# available issues to blocked rather than exposing an unverified ordering.
	lifecycle_stage="relationships"
	if ! _pulse_run_issue_sync_stage "$script_dir" relationships "$repo_slug" "$workspace"; then
		printf '[pulse-wrapper] TODO ref sync status=retryable_failure stage=relationships repo=%s\n' \
			"$repo_slug" >>"$WRAPPER_LOGFILE"
		sync_failed=1
	fi
	if [[ "$sync_failed" -ne 0 ]]; then
		return 1
	fi

	if ! declare -F planning_publish >/dev/null 2>&1; then
		[[ -f "${script_dir}/planning-publisher.sh" ]] || {
			return 1
		}
		# shellcheck source=planning-publisher.sh
		source "${script_dir}/planning-publisher.sh"
	fi
	changed_paths=$(_planning_publish_changed_paths "$workspace")
	PLANNING_PUBLISH_RESULT=""
	PLANNING_PUBLICATION_ID=""
	PLANNING_PUBLISHED_COMMIT=""
	lifecycle_stage="publication"
	TMPDIR="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}" \
		AIDEVOPS_PLANNING_BASE_SHA="$base_sha" \
		planning_publish "$workspace" "chore: sync GitHub issue refs to TODO.md [skip ci]" \
		origin "$branch_name" "$changed_paths" || publication_rc=$?
	case "$publication_rc" in
	0) printf '[pulse-wrapper] TODO ref sync status=%s repo=%s commit=%s\n' \
		"${PLANNING_PUBLISH_RESULT:-noop}" "$repo_slug" "${PLANNING_PUBLISHED_COMMIT:0:12}" >>"$WRAPPER_LOGFILE" ;;
	2) printf '[pulse-wrapper] TODO ref sync status=retryable_conflict repo=%s base=%s\n' \
		"$repo_slug" "${base_sha:0:12}" >>"$WRAPPER_LOGFILE" ;;
	*) printf '[pulse-wrapper] TODO ref sync status=retryable_failure stage=publication repo=%s rc=%s\n' \
		"$repo_slug" "$publication_rc" >>"$WRAPPER_LOGFILE" ;;
	esac
	if [[ "$publication_rc" -eq 0 ]]; then
		lifecycle_stage="complete"
	fi
	return "$publication_rc"
)

_pulse_todo_sync_parallelism() {
	local parallelism="${PULSE_TODO_SYNC_PARALLELISM:-4}"
	[[ "$parallelism" =~ ^[1-9][0-9]*$ ]] || parallelism=4
	if [[ "$parallelism" -gt 8 ]]; then
		parallelism=8
	fi
	printf '%s\n' "$parallelism"
	return 0
}

_pulse_todo_sync_repo_timeout() {
	local stage_timeout="${PRE_RUN_STAGE_TIMEOUT:-600}"
	local repo_timeout="${PULSE_TODO_SYNC_REPO_TIMEOUT:-600}"
	[[ "$stage_timeout" =~ ^[1-9][0-9]*$ ]] || stage_timeout=600
	[[ "$repo_timeout" =~ ^[1-9][0-9]*$ ]] || repo_timeout=600
	if [[ "$repo_timeout" -gt "$stage_timeout" ]]; then
		repo_timeout="$stage_timeout"
	fi
	printf '%s\n' "$repo_timeout"
	return 0
}

_pulse_sync_todo_repo_bounded() {
	local repo_slug="$1"
	local repo_path="$2"
	local repo_timeout="$3"
	local job_index="$4"
	_pulse_refresh_repo "$repo_path" || true
	if declare -F run_stage_with_timeout >/dev/null 2>&1; then
		run_stage_with_timeout "sync_todo_refs_repo_${job_index}" "$repo_timeout" \
			sync_todo_refs_for_repo "$repo_slug" "$repo_path"
		return $?
	fi
	sync_todo_refs_for_repo "$repo_slug" "$repo_path"
	return $?
}

#######################################
# sync_todo_refs_all_repos
#
# Refresh local TODO.md state for every pulse-enabled repo before dependency
# graph construction. This keeps closed GitHub blockers from being interpreted
# through stale local task ledgers during the same pulse cycle.
#######################################
sync_todo_refs_all_repos() {
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local repo_slug="" repo_path="" pid="" job_rc=0
	local parallelism="" repo_timeout="" scheduled=0 sync_failures=0
	local -a active_pids=()

	[[ -f "$repos_json" ]] || return 0
	parallelism=$(_pulse_todo_sync_parallelism)
	repo_timeout=$(_pulse_todo_sync_repo_timeout)
	while IFS='|' read -r repo_slug repo_path; do
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue
		repo_path="${repo_path/#\~/$HOME}"
		[[ -d "$repo_path" ]] || continue
		scheduled=$((scheduled + 1))
		_pulse_sync_todo_repo_bounded "$repo_slug" "$repo_path" "$repo_timeout" "$scheduled" &
		active_pids+=("$!")
		if [[ "${#active_pids[@]}" -ge "$parallelism" ]]; then
			pid="${active_pids[0]}"
			job_rc=0
			wait "$pid" || job_rc=$?
			[[ "$job_rc" -eq 0 ]] || sync_failures=$((sync_failures + 1))
			active_pids=("${active_pids[@]:1}")
		fi
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | [.slug, .path] | join("|")' "$repos_json" 2>/dev/null || true)
	for pid in "${active_pids[@]}"; do
		job_rc=0
		wait "$pid" || job_rc=$?
		[[ "$job_rc" -eq 0 ]] || sync_failures=$((sync_failures + 1))
	done
	echo "[pulse-wrapper] TODO ref sync batch completed scheduled=${scheduled} failures=${sync_failures} parallelism=${parallelism} per_repo_timeout=${repo_timeout}s" >>"$WRAPPER_LOGFILE"
	[[ "$sync_failures" -eq 0 ]]
	return $?
}

# Only run main when executed directly, not when sourced.
# The pulse agent sources this file to access helper functions
# (check_external_contributor_pr, check_permission_failure_pr)
# without triggering the full pulse lifecycle.
#
# Shell-portable source detection (GH#3931):
#   bash: BASH_SOURCE[0] differs from $0 when sourced
#   zsh:  BASH_SOURCE is undefined; use ZSH_EVAL_CONTEXT instead
#         (contains "file" when sourced, "toplevel" when executed)
_pulse_is_sourced() {
	if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" != "${0}" ]]
	elif [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
		[[ ":${ZSH_EVAL_CONTEXT}:" == *":file:"* ]]
	else
		return 1
	fi
}
