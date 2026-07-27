#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Watchdog — Command Implementations
# =============================================================================
# CLI command handlers for worker-watchdog.sh:
#   cmd_check     — scan all workers and apply detection signals
#   cmd_status    — show current worker and scheduler state
#   cmd_install   — install launchd/systemd/cron scheduler
#   cmd_uninstall — remove scheduler and state files
#   cmd_help      — print usage
#
# Internal helpers for the check loop, status display, and scheduler install:
#   _check_single_worker,
#   _cleanup_stale_tracking_files, _status_print_*, _install_launchd,
#   _install_cron, _install_systemd
#
# Usage: source "${SCRIPT_DIR}/worker-watchdog-cmd.sh"
#
# Dependencies:
#   - shared-constants.sh (sourced by orchestrator)
#   - worker-lifecycle-common.sh (_get_process_tree_cpu, _format_duration,
#       _sanitize_log_field, _compute_struggle_ratio, _is_process_alive_and_matches,
#       _extract_session_title)
#   - worker-watchdog-detect.sh (find_workers, extract_issue_number,
#       extract_repo_slug, extract_provider_from_cmd)
#   - worker-watchdog-checks.sh (check_provider_backoff, check_idle,
#       check_progress_stall, check_zero_commit_thrashing,
#       transcript_allows_intervention)
#   - worker-watchdog-kill.sh (kill_worker)
#   - Globals: IDLE_STATE_DIR, PLIST_PATH, LAUNCHD_LABEL, CRON_MARKER,
#       SYSTEMD_SERVICE_NAME, SYSTEMD_SERVICE_DIR, LOG_FILE, SCRIPT_NAME,
#       WORKER_PROCESS_PATTERN, WORKER_MAX_RUNTIME, WORKER_THRASH_*,
#       WORKER_IDLE_CPU_THRESHOLD, WORKER_IDLE_TIMEOUT, WORKER_PROGRESS_TIMEOUT,
#       HEADLESS_RUNTIME_DB, WORKER_DRY_RUN, WORKER_WATCHDOG_NOTIFY
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKER_WATCHDOG_CMD_LOADED:-}" ]] && return 0
_WORKER_WATCHDOG_CMD_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Check Loop Helpers
# =============================================================================

#######################################
# Apply all detection signals to a single worker
#
# Arguments:
#   $1 - PID
#   $2 - elapsed seconds
#   $3 - command line
# Returns: 0 if worker was killed, 1 if worker was spared
#######################################
_check_single_worker() {
	local pid="$1"
	local elapsed_seconds="$2"
	local cmd="$3"

	local tree_cpu
	tree_cpu=$(_get_process_tree_cpu "$pid")

	local duration
	duration=$(_format_duration "$elapsed_seconds")

	# Check 1: Provider backoff stall (GH#5650) — kill immediately, no transcript gate.
	# A worker whose provider is backed off will never make progress. The transcript
	# gate is irrelevant — the provider won't respond regardless of what the transcript says.
	if check_provider_backoff "$pid" "$cmd" "$elapsed_seconds"; then
		local backoff_evidence="provider=${BACKOFF_PROVIDER} reason=${BACKOFF_REASON} retry_after=${BACKOFF_RETRY_AFTER}"
		log_msg "PROVIDER BACKOFF: PID=${pid} elapsed=${duration} ${backoff_evidence}"
		kill_worker "$pid" "backoff" "$cmd" "$elapsed_seconds" "$backoff_evidence"
		return 0
	fi

	# Check 2: Runtime ceiling advisory. Quiet/long-running workers may be doing
	# legitimate wait work for hours or days, so runtime never kills by itself.
	if [[ "$WORKER_MAX_RUNTIME" -gt 0 && "$elapsed_seconds" -ge "$WORKER_MAX_RUNTIME" ]]; then
		log_msg "RUNTIME ADVISORY: PID=${pid} elapsed=${duration} (max=$(_format_duration "$WORKER_MAX_RUNTIME"))"
	fi

	# Check 3: zero-commit high-message thrash advisory. This is useful evidence
	# for humans, but it is not explicit fatal evidence and must not kill workers.
	if check_zero_commit_thrashing "$pid" "$cmd" "$elapsed_seconds"; then
		log_msg "THRASH ADVISORY: PID=${pid} elapsed=${duration} commits=${THRASH_COMMITS} messages=${THRASH_MESSAGES} ratio=${THRASH_RATIO}"
	fi

	# Check 4: CPU idle advisory. Low CPU is normal while waiting on provider,
	# network, tools, or file IO; never kill solely because the worker is quiet.
	if check_idle "$pid" "$tree_cpu"; then
		log_msg "IDLE ADVISORY: PID=${pid} cpu=${tree_cpu}% elapsed=${duration} action=defer"
	fi

	# Check 5: Progress stall advisory. Transcript/session growth can lag or be
	# absent while real work is happening, so a stall is not a kill reason.
	if check_progress_stall "$pid" "$cmd" "$elapsed_seconds"; then
		local sanitized_evidence=""
		if [[ -n "$STALL_EVIDENCE_SUMMARY" ]]; then
			sanitized_evidence=$(_sanitize_log_field "$STALL_EVIDENCE_SUMMARY")
		fi
		log_msg "PROGRESS STALL ADVISORY: PID=${pid} elapsed=${duration}${sanitized_evidence:+ evidence=${sanitized_evidence}} action=defer"
	fi

	return 1
}

#######################################
# Remove tracking files for PIDs that no longer exist
#######################################
_cleanup_stale_tracking_files() {
	local tracking_file
	for tracking_file in "${IDLE_STATE_DIR}"/idle-* "${IDLE_STATE_DIR}"/stall-* "${IDLE_STATE_DIR}"/stall-grace-*; do
		[[ -f "$tracking_file" ]] || continue
		local tracked_pid
		tracked_pid=$(basename "$tracking_file" | sed 's/^idle-//;s/^stall-//;s/^grace-//')
		# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
		if [[ "$tracked_pid" =~ ^[0-9]+$ ]] && ! _is_process_alive_and_matches "$tracked_pid" "${WORKER_PROCESS_PATTERN:-}"; then
			rm -f "$tracking_file" 2>/dev/null || true
		fi
	done
	return 0
}

# =============================================================================
# cmd_check
# =============================================================================

#######################################
# Main check: scan all workers and apply detection signals
#######################################
cmd_check() {
	ensure_dirs

	local workers
	workers=$(find_workers)

	if [[ -z "$workers" ]]; then
		# No workers running — clean up stale tracking files
		rm -f "${IDLE_STATE_DIR}"/idle-* "${IDLE_STATE_DIR}"/stall-* "${IDLE_STATE_DIR}"/stall-grace-* 2>/dev/null || true
		return 0
	fi

	local worker_count=0
	local killed_count=0

	while IFS='|' read -r pid elapsed_seconds cmd; do
		[[ -z "$pid" ]] && continue
		worker_count=$((worker_count + 1))
		if _check_single_worker "$pid" "$elapsed_seconds" "$cmd"; then
			killed_count=$((killed_count + 1))
		fi
	done <<<"$workers"

	if [[ "$killed_count" -gt 0 ]]; then
		log_msg "Check complete: ${worker_count} workers scanned, ${killed_count} killed"
	fi

	_cleanup_stale_tracking_files

	return 0
}

# =============================================================================
# cmd_status Helpers
# =============================================================================

#######################################
# Print the configuration section of --status
#######################################
_status_print_config() {
	echo "--- Configuration ---"
	echo ""
	echo "  Idle timeout:        $(_format_duration "$WORKER_IDLE_TIMEOUT") (CPU < ${WORKER_IDLE_CPU_THRESHOLD}%)"
	echo "  Progress timeout:    $(_format_duration "$WORKER_PROGRESS_TIMEOUT")"
	echo "  Runtime ceiling:     $(_format_duration "$WORKER_MAX_RUNTIME")"
	echo "  Thrash guardrail:    elapsed >= $(_format_duration "$WORKER_THRASH_ELAPSED_THRESHOLD"), messages >= ${WORKER_THRASH_MESSAGE_THRESHOLD}, commits = 0"
	echo "  Thrash (time-wt):    elapsed >= $(_format_duration "$WORKER_THRASH_RATIO_ELAPSED"), ratio >= ${WORKER_THRASH_RATIO_THRESHOLD}, commits = 0 (GH#5650)"
	echo "  Provider backoff:    DB=${HEADLESS_RUNTIME_DB}"
	echo "  Dry run:             ${WORKER_DRY_RUN}"
	echo "  Notifications:       ${WORKER_WATCHDOG_NOTIFY}"
	return 0
}

#######################################
# Print idle/stall/grace tracking state for a worker in --status output
#
# Arguments:
#   $1 - PID
#######################################
_status_print_worker_tracking() {
	local pid="$1"
	local now
	now=$(date +%s)

	if [[ -f "${IDLE_STATE_DIR}/idle-${pid}" ]]; then
		local idle_since
		idle_since=$(cat "${IDLE_STATE_DIR}/idle-${pid}" 2>/dev/null || echo "0")
		local idle_for=$((now - idle_since))
		echo "    Idle for: $(_format_duration "$idle_for") / $(_format_duration "$WORKER_IDLE_TIMEOUT")"
	fi

	if [[ -f "${IDLE_STATE_DIR}/stall-${pid}" ]]; then
		local stall_since
		stall_since=$(cat "${IDLE_STATE_DIR}/stall-${pid}" 2>/dev/null || echo "0")
		local stall_for=$((now - stall_since))
		echo "    Stalled:  $(_format_duration "$stall_for") / $(_format_duration "$WORKER_PROGRESS_TIMEOUT")"
	fi

	if [[ -f "${IDLE_STATE_DIR}/stall-grace-${pid}" ]]; then
		local grace_since
		grace_since=$(cat "${IDLE_STATE_DIR}/stall-grace-${pid}" 2>/dev/null || echo "0")
		local grace_for=$((now - grace_since))
		echo "    Grace:    $(_format_duration "$grace_for") / $(_format_duration "$WORKER_PROGRESS_TIMEOUT")"
	fi

	return 0
}

#######################################
# Print details for a single worker in --status output
#
# Arguments:
#   $1 - worker index (display number)
#   $2 - PID
#   $3 - elapsed seconds
#   $4 - command line
#######################################
_status_print_worker() {
	local count="$1"
	local pid="$2"
	local elapsed_seconds="$3"
	local cmd="$4"

	local tree_cpu
	tree_cpu=$(_get_process_tree_cpu "$pid")
	local duration
	duration=$(_format_duration "$elapsed_seconds")
	local issue_number
	issue_number=$(extract_issue_number "$cmd")
	local repo_slug
	repo_slug=$(extract_repo_slug "$cmd")

	echo "  Worker #${count}:"
	echo "    PID:      ${pid}"
	echo "    Runtime:  ${duration}"
	echo "    Tree CPU: ${tree_cpu}%"
	[[ -n "$issue_number" ]] && echo "    Issue:    ${repo_slug:-unknown}#${issue_number}"

	_status_print_worker_tracking "$pid"

	# Struggle ratio
	local sr_result
	sr_result=$(_compute_struggle_ratio "$pid" "$elapsed_seconds" "$cmd")
	local sr_ratio sr_commits sr_messages sr_flag
	IFS='|' read -r sr_ratio sr_commits sr_messages sr_flag <<<"$sr_result"
	if [[ "$sr_ratio" != "n/a" ]]; then
		echo "    Struggle: ratio=${sr_ratio} commits=${sr_commits} messages=${sr_messages} ${sr_flag:+[${sr_flag}]}"
	fi

	# Provider backoff state
	local status_provider
	status_provider=$(extract_provider_from_cmd "$cmd")
	if [[ -n "$status_provider" ]]; then
		if check_provider_backoff "$pid" "$cmd" 300; then
			echo "    Backoff:  ACTIVE provider=${BACKOFF_PROVIDER} reason=${BACKOFF_REASON} retry_after=${BACKOFF_RETRY_AFTER}"
		else
			echo "    Backoff:  none (provider=${status_provider})"
		fi
	fi

	echo ""
	return 0
}

#######################################
# Print the scheduler section of --status
#
# Arguments:
#   $1 - backend ("launchd", "systemd", "cron", or "unsupported")
#######################################
_status_print_scheduler() {
	local backend="$1"

	echo "--- Scheduler (${backend}) ---"
	echo ""
	if [[ "$backend" == "launchd" ]]; then
		if [[ -f "${PLIST_PATH}" ]]; then
			# Capture output to avoid SIGPIPE under set -o pipefail
			local launchctl_out
			launchctl_out=$(launchctl list 2>/dev/null) || true
			if echo "$launchctl_out" | grep -q "${LAUNCHD_LABEL}"; then
				echo "  Status: installed and loaded"
			else
				echo "  Status: installed but NOT loaded"
			fi
		else
			echo "  Status: not installed (run --install)"
		fi
	elif [[ "$backend" == "systemd" ]]; then
		local timer_state
		timer_state=$(systemctl --user is-active "${SYSTEMD_SERVICE_NAME}.timer" 2>/dev/null) || true
		local timer_enabled
		timer_enabled=$(systemctl --user is-enabled "${SYSTEMD_SERVICE_NAME}.timer" 2>/dev/null) || true
		if [[ "$timer_state" == "active" ]]; then
			echo "  Status: installed and active"
			echo "  Timer:  ${SYSTEMD_SERVICE_NAME}.timer (${timer_enabled})"
			local next_trigger
			next_trigger=$(systemctl --user show "${SYSTEMD_SERVICE_NAME}.timer" --property=NextElapseUSecRealtime --value 2>/dev/null) || true
			if [[ -n "$next_trigger" && "$next_trigger" != "n/a" ]]; then
				echo "  Next:   ${next_trigger}"
			fi
		elif [[ "$timer_enabled" == "enabled" ]]; then
			echo "  Status: enabled but NOT active"
		elif [[ -f "${SYSTEMD_SERVICE_DIR}/${SYSTEMD_SERVICE_NAME}.timer" ]]; then
			echo "  Status: unit files exist but timer is not enabled"
		else
			echo "  Status: not installed (run --install)"
		fi
	elif [[ "$backend" == "cron" ]]; then
		# Linux without systemd: check cron (single crontab -l call)
		if ! _has_crontab; then
			echo "  Status: crontab unavailable"
		else
			local cron_entry
			cron_entry=$(crontab -l 2>/dev/null | grep -F "$CRON_MARKER") || true
			if [[ -n "$cron_entry" ]]; then
				echo "  Status: installed"
				echo "  Entry:  ${cron_entry}"
			else
				echo "  Status: not installed (run --install)"
			fi
		fi
	else
		echo "  Status: unsupported OS ($(uname -s))"
	fi
	return 0
}

# =============================================================================
# cmd_status
# =============================================================================

#######################################
# Status: show current worker state
#######################################
cmd_status() {
	ensure_dirs

	echo "=== Worker Watchdog Status ==="
	echo ""
	_status_print_config
	echo ""
	echo "--- Active Workers ---"
	echo ""

	local workers
	workers=$(find_workers)

	if [[ -z "$workers" ]]; then
		echo "  No headless workers running"
	else
		local count=0
		while IFS='|' read -r pid elapsed_seconds cmd; do
			[[ -z "$pid" ]] && continue
			count=$((count + 1))
			_status_print_worker "$count" "$pid" "$elapsed_seconds" "$cmd"
		done <<<"$workers"
		echo "  Total: ${count} worker(s)"
	fi

	local backend
	backend="$(_get_scheduler_backend)"

	echo ""
	_status_print_scheduler "$backend"

	echo ""
	return 0
}

# =============================================================================
# cmd_install and scheduler backends
# =============================================================================

#######################################
# Install scheduler (launchd on macOS, systemd/cron on Linux)
#######################################
cmd_install() {
	local script_path
	script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	local installed_path="${HOME}/.aidevops/agents/scripts/${SCRIPT_NAME}.sh"
	if [[ -x "${installed_path}" ]]; then
		script_path="${installed_path}"
	fi

	ensure_dirs

	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "unsupported" ]]; then
		echo "Unsupported OS: $(uname -s). Supported backends: macOS (launchd), Linux (systemd/cron)." >&2
		return 1
	fi

	if [[ "$backend" == "launchd" ]]; then
		_install_launchd "$script_path"
	elif [[ "$backend" == "systemd" ]]; then
		_install_systemd "$script_path"
	else
		_install_cron "$script_path"
	fi

	return 0
}

#######################################
# Install launchd plist (macOS)
# Arguments:
#   $1 - script path
#######################################
_install_launchd() {
	local script_path="$1"
	local home_escaped="${HOME}"

	mkdir -p "$(dirname "${PLIST_PATH}")"

	cat >"${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${script_path}</string>
		<string>--check</string>
	</array>
	<key>StartInterval</key>
	<integer>120</integer>
	<key>StandardOutPath</key>
	<string>${home_escaped}/.aidevops/logs/worker-watchdog-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${home_escaped}/.aidevops/logs/worker-watchdog-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
		<key>HOME</key>
		<string>${home_escaped}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
EOF

	launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
	# shell-portability: ignore next — worker-watchdog macOS launchd installer (GH#18787)
	launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"

	echo "Installed and loaded: ${LAUNCHD_LABEL}"
	echo "Plist: ${PLIST_PATH}"
	echo "Log: ${LOG_FILE}"
	echo "Check interval: 120 seconds"
	return 0
}

#######################################
# Install cron entry (Linux)
# Arguments:
#   $1 - script path
#######################################
_install_cron() {
	local script_path="$1"
	_require_crontab || return 1
	local cron_line="*/2 * * * * /bin/bash ${script_path} --check >> ${LOG_FILE} 2>&1 ${CRON_MARKER}"

	# Remove any existing watchdog entry, then add the new one (pipe to crontab -)
	# Note: || true guards against set -e + pipefail when crontab -l has no entries
	(
		crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" || true
		echo "$cron_line"
	) | crontab -

	echo "Installed cron entry for worker-watchdog"
	echo "Schedule: every 2 minutes"
	echo "Log: ${LOG_FILE}"
	echo ""
	echo "  Uninstall with: ${SCRIPT_NAME}.sh --uninstall"
	return 0
}

#######################################
# Install systemd user timer (Linux with systemd)
# Arguments:
#   $1 - script path
# Modelled on .agents/scripts/setup/modules/schedulers.sh:_install_scheduler_systemd()
#######################################
_install_systemd() {
	local script_path="$1"
	local service_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_SERVICE_NAME}.service"
	local timer_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_SERVICE_NAME}.timer"

	mkdir -p "${SYSTEMD_SERVICE_DIR}"

	printf '%s' "[Unit]
Description=aidevops worker-watchdog
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc '${script_path} --check'
TimeoutStartSec=120
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
" >"$service_file"

	printf '%s' "[Unit]
Description=aidevops worker-watchdog Timer

[Timer]
OnBootSec=120
OnUnitActiveSec=120
Persistent=true

[Install]
WantedBy=timers.target
" >"$timer_file"

	systemctl --user daemon-reload 2>/dev/null || true
	if ! systemctl --user enable --now "${SYSTEMD_SERVICE_NAME}.timer" 2>/dev/null; then
		echo "Failed to enable systemd timer. Falling back to cron." >&2
		_install_cron "$script_path"
		return 0
	fi

	echo "Installed systemd user timer: ${SYSTEMD_SERVICE_NAME}.timer"
	echo "Service: ${service_file}"
	echo "Timer: ${timer_file}"
	echo "Interval: 120 seconds"
	echo "Log: ${LOG_FILE}"
	echo ""
	echo "  Status: systemctl --user status ${SYSTEMD_SERVICE_NAME}.timer"
	echo "  Uninstall with: ${SCRIPT_NAME}.sh --uninstall"
	return 0
}

# =============================================================================
# cmd_uninstall
# =============================================================================

#######################################
# Uninstall scheduler (launchd on macOS, systemd/cron on Linux)
#######################################
cmd_uninstall() {
	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "unsupported" ]]; then
		echo "Unsupported OS: $(uname -s). Supported backends: macOS (launchd), Linux (systemd/cron)." >&2
		return 1
	fi

	if [[ "$backend" == "launchd" ]]; then
		if [[ -f "${PLIST_PATH}" ]]; then
			launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
			rm -f "${PLIST_PATH}"
			echo "Uninstalled: ${LAUNCHD_LABEL}"
		else
			echo "Not installed (launchd)"
		fi
	elif [[ "$backend" == "systemd" ]]; then
		local service_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_SERVICE_NAME}.service"
		local timer_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_SERVICE_NAME}.timer"
		if systemctl --user is-enabled "${SYSTEMD_SERVICE_NAME}.timer" >/dev/null 2>&1 ||
			[[ -f "$timer_file" ]]; then
			systemctl --user stop "${SYSTEMD_SERVICE_NAME}.timer" 2>/dev/null || true
			systemctl --user disable "${SYSTEMD_SERVICE_NAME}.timer" 2>/dev/null || true
			rm -f "$service_file" "$timer_file"
			systemctl --user daemon-reload 2>/dev/null || true
			echo "Uninstalled systemd timer: ${SYSTEMD_SERVICE_NAME}.timer"
		else
			echo "Not installed (systemd)"
		fi
		# Also clean up any leftover cron entry from before systemd migration
		if command -v crontab >/dev/null 2>&1; then
			local current_crontab
			current_crontab=$(crontab -l 2>/dev/null) || true
			if echo "$current_crontab" | grep -qF "$CRON_MARKER"; then
				echo "$current_crontab" | grep -vF "$CRON_MARKER" | crontab -
				echo "Also removed leftover cron entry"
			fi
		fi
	else
		# Linux without systemd: remove cron entry (single crontab -l call)
		_require_crontab || return 1
		local current_crontab
		current_crontab=$(crontab -l 2>/dev/null) || true
		if echo "$current_crontab" | grep -qF "$CRON_MARKER"; then
			echo "$current_crontab" | grep -vF "$CRON_MARKER" | crontab -
			echo "Uninstalled cron entry for worker-watchdog"
		else
			echo "Not installed (cron)"
		fi
	fi

	# Clean up state files
	rm -rf "${IDLE_STATE_DIR}" 2>/dev/null || true
	echo "Cleaned up state files"
	return 0
}

# =============================================================================
# cmd_help
# =============================================================================

#######################################
# Help
#######################################
cmd_help() {
	cat <<HELP
Usage: ${SCRIPT_NAME}.sh [COMMAND]

Commands:
  --check, -c       Single check (default, for scheduler)
  --status, -s      Show current worker state
  --install, -i     Install scheduler (launchd on macOS, systemd/cron on Linux)
  --uninstall, -u   Remove scheduler entry and state files
  --help, -h        Show this help

Detection signals:
  Provider backoff: Worker's provider is backed off in headless-runtime DB — kill immediately (GH#5650)
  Zero-commit thrash: elapsed >= $(_format_duration "$WORKER_THRASH_ELAPSED_THRESHOLD"), commits = 0, messages >= ${WORKER_THRASH_MESSAGE_THRESHOLD}
  Thrash (time-wt): elapsed >= $(_format_duration "$WORKER_THRASH_RATIO_ELAPSED"), commits = 0, ratio >= ${WORKER_THRASH_RATIO_THRESHOLD} (GH#5650)
  CPU idle:         Tree CPU < ${WORKER_IDLE_CPU_THRESHOLD}% for $(_format_duration "$WORKER_IDLE_TIMEOUT")
  Progress stall:   No session messages for $(_format_duration "$WORKER_PROGRESS_TIMEOUT"), then inspect transcript tail evidence
  Runtime ceiling:  Hard kill after $(_format_duration "$WORKER_MAX_RUNTIME")

On kill:
  - Posts comment on associated GitHub issue
  - Removes status:in-progress label
  - Adds status:blocked for zero-commit thrash kills
  - Adds status:available for all other kill reasons (including backoff)
  - Logs to ${LOG_FILE}

Environment variables:
  WORKER_IDLE_TIMEOUT              Idle detection window (default: 300s)
  WORKER_IDLE_CPU_THRESHOLD        CPU% idle threshold (default: 5)
  WORKER_PROGRESS_TIMEOUT          Stall detection window (default: 600s)
  WORKER_THRASH_ELAPSED_THRESHOLD  Minimum runtime for thrash guardrail (default: 3600s)
  WORKER_THRASH_MESSAGE_THRESHOLD  Minimum messages for thrash guardrail (default: 120)
  WORKER_THRASH_RATIO_THRESHOLD    Struggle ratio threshold for time-weighted check (default: 10)
  WORKER_THRASH_RATIO_ELAPSED      Minimum elapsed for ratio-only thrash (default: 25200s = 7h)
  WORKER_MAX_RUNTIME               Hard runtime ceiling (default: 10800s = 3h)
  WORKER_DRY_RUN                   Log but don't kill (default: false)
  WORKER_WATCHDOG_NOTIFY           macOS notifications (default: true)
  WORKER_PROCESS_PATTERN           CLI name to match (default: opencode)
  HEADLESS_RUNTIME_DB              Path to headless-runtime state.db (auto-detected)
HELP
	return 0
}
