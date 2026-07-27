#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Schedulers Linux Sub-Library -- systemd/cron scheduler installation and
# uninstall functions for Linux (and macOS uninstall path).
# =============================================================================
# This sub-library is sourced by .agents/scripts/setup/modules/schedulers.sh (the orchestrator).
# It covers:
#   - systemd user service availability check
#   - systemd value escaping
#   - Building systemd Environment= and cron env prefix lines
#   - Generic systemd timer installation
#   - Generic cron entry installation
#   - Linux dispatcher (systemd preferred, cron fallback)
#   - Generic scheduler uninstall (launchd/systemd/cron)
#   - Supervisor pulse uninstall
#
# Usage: source "${SCRIPT_DIR}/schedulers-linux.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, print_warning)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SCHEDULERS_LINUX_LIB_LOADED:-}" ]] && return 0
_SCHEDULERS_LINUX_LIB_LOADED=1

# SCRIPT_DIR fallback — needed when sourced from test harnesses that don't set it.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_sched_linux_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_sched_linux_lib_path" == "${BASH_SOURCE[0]}" ]] && _sched_linux_lib_path="."
	SCRIPT_DIR="$(cd "$_sched_linux_lib_path" && pwd)"
	unset _sched_linux_lib_path
fi

# --- Functions ---

# Check if systemd user services are available on this Linux system.
# Returns 0 if systemd --user is functional, 1 otherwise.
_systemd_user_available() {
	command -v systemctl >/dev/null 2>&1 || return 1
	systemctl --user status >/dev/null 2>&1 || return 1
	return 0
}

# Escape a value for safe embedding in a systemd unit Environment= or ExecStart=
# directive. systemd interprets % as specifiers (%h, %n, %t, etc.) and spaces
# as key-value separators. This helper:
#   1. Escapes \ → \\ (must be first to avoid double-escaping)
#   2. Doubles % → %% (escape specifiers)
#   3. Escapes embedded " → \"
#   4. Wraps the result in "..." (handles spaces and other shell metacharacters)
# Usage: escaped=$(_systemd_escape "$value")
#
# WARNING: Do NOT use for StandardOutput= or StandardError= directives.
# systemd does not strip outer quotes from those values — "append:/path" is
# treated as a literal filename with quote characters, failing silently.
# Use bare values for StandardOutput=/StandardError=:
#   StandardOutput=append:${log_file}  ← correct
#   StandardOutput=$(_systemd_escape "append:${log_file}")  ← WRONG
_systemd_escape() {
	local _val="$1"
	# Step 1: escape backslashes
	_val="${_val//\\/\\\\}"
	# Step 2: escape % specifiers
	_val="${_val//%/%%}"
	# Step 3: escape embedded double-quotes
	_val="${_val//\"/\\\"}"
	# Step 4: wrap in double-quotes
	printf '"%s"' "$_val"
	return 0
}

# Build systemd Environment= lines from newline-separated KEY=VALUE pairs.
# Always appends HOME and PATH for parity with launchd and cron execution.
_scheduler_systemd_env_lines() {
	local env_vars="$1"
	local _env_lines=""
	local _has_path=0

	if [[ -n "$env_vars" ]]; then
		while IFS= read -r _kv; do
			[[ -z "$_kv" ]] && continue
			local _key="${_kv%%=*}"
			local _raw_val="${_kv#*=}"
			local _escaped_val
			_escaped_val=$(_systemd_escape "$_raw_val")
			_env_lines+="Environment=${_key}=${_escaped_val}"$'\n'
			[[ "$_key" == "PATH" ]] && _has_path=1
		done <<<"$env_vars"
	fi

	_env_lines+="Environment=HOME=$(_systemd_escape "$HOME")"$'\n'
	if [[ "$_has_path" -eq 0 ]]; then
		_env_lines+="Environment=PATH=$(_systemd_escape "$PATH")"$'\n'
	fi
	printf '%s' "$_env_lines"
	return 0
}

# Build inline cron environment assignments from newline-separated KEY=VALUE pairs.
_scheduler_cron_env_prefix() {
	local env_vars="$1"
	local _env_prefix=""

	if [[ -n "$env_vars" ]]; then
		while IFS= read -r _kv; do
			[[ -z "$_kv" ]] && continue
			local _key="${_kv%%=*}"
			local _raw_val="${_kv#*=}"
			local _escaped_val
			_escaped_val=$(_cron_escape "$_raw_val")
			_env_prefix+="${_key}=${_escaped_val} "
		done <<<"$env_vars"
	fi

	printf '%s' "$_env_prefix"
	return 0
}

# Install a generic scheduler via systemd user timer (Linux with systemd).
# Args:
#   $1 = service_name    (e.g. "aidevops-stats-wrapper")
#   $2 = exec_command    (shell command run via /bin/bash -lc)
#   $3 = interval_sec    (OnUnitActiveSec interval in seconds; may be empty for calendar-only)
#   $4 = log_file        (absolute path to log file)
#   $5 = env_vars        (newline-separated KEY=VALUE pairs, may be empty)
#   $6 = run_at_load     ("true" or "false")
#   $7 = low_priority    ("true" or "false")
#   $8 = on_calendar     (optional systemd OnCalendar spec)
#   $9 = timeout_sec     (optional TimeoutStartSec; defaults to interval_sec)
# Returns 0 on success, 1 if systemd enable fails (caller should fall back to cron).
_install_scheduler_systemd() {
	local service_name="$1"
	local exec_command="$2"
	local interval_sec="$3"
	local log_file="$4"
	local env_vars="$5"
	local run_at_load="$6"
	local low_priority="$7"
	local on_calendar="$8"
	local timeout_sec="$9"
	local service_dir="$HOME/.config/systemd/user"
	local service_file="${service_dir}/${service_name}.service"
	local timer_file="${service_dir}/${service_name}.timer"

	mkdir -p "$service_dir"

	# GH#18439 Bug 1: command substitution strips trailing newlines, which
	# would run the final Environment=PATH=... into the following
	# StandardOutput=... directive on the same line. Use a sentinel ('x')
	# to preserve the trailing newline that _scheduler_systemd_env_lines
	# always emits.
	local _env_lines
	_env_lines=$(
		_scheduler_systemd_env_lines "$env_vars"
		printf 'x'
	)
	_env_lines="${_env_lines%x}"

	if [[ -z "$timeout_sec" ]]; then
		timeout_sec="$interval_sec"
	fi
	if [[ -z "$timeout_sec" ]]; then
		timeout_sec="3600"
	fi

	local _service_extra=""
	if [[ "$service_name" == "aidevops-supervisor-pulse" ]]; then
		_service_extra+="TimeoutStopSec=30"$'\n'
		_service_extra+="SendSIGKILL=yes"$'\n'
	fi
	if [[ "$low_priority" == "true" ]]; then
		_service_extra+="Nice=10"$'\n'
		_service_extra+="IOSchedulingClass=idle"$'\n'
	fi

	printf '%s' "[Unit]
Description=aidevops ${service_name}
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc $(_systemd_escape "$exec_command")
TimeoutStartSec=${timeout_sec}
${_service_extra}${_env_lines}StandardOutput=append:${log_file}
StandardError=append:${log_file}
" >"$service_file"

	local _timer_lines=""
	if [[ "$run_at_load" == "true" ]]; then
		_timer_lines+="OnActiveSec=10s"$'\n'
	fi
	if [[ -n "$interval_sec" ]]; then
		_timer_lines+="OnBootSec=${interval_sec}"$'\n'
		_timer_lines+="OnUnitActiveSec=${interval_sec}"$'\n'
	fi
	if [[ -n "$on_calendar" ]]; then
		_timer_lines+="OnCalendar=${on_calendar}"$'\n'
	fi

	printf '%s' "[Unit]
Description=aidevops ${service_name} Timer

[Timer]
${_timer_lines}Persistent=true

[Install]
WantedBy=timers.target
" >"$timer_file"

	systemctl --user daemon-reload 2>/dev/null || true
	if systemctl --user enable --now "${service_name}.timer" 2>/dev/null; then
		return 0
	fi
	return 1
}

# Install a generic cron entry.
# Args: $1=cron_tag, $2=cron_schedule, $3=exec_command, $4=log_file, $5=env_vars
_install_scheduler_cron() {
	local cron_tag="$1"
	local cron_schedule="$2"
	local exec_command="$3"
	local log_file="$4"
	local env_vars="$5"
	local _cron_exec
	local _cron_log
	local _env_prefix

	_env_prefix=$(_scheduler_cron_env_prefix "$env_vars")
	_cron_exec=$(_cron_escape "$exec_command")
	_cron_log=$(_cron_escape "$log_file")

	(
		crontab -l 2>/dev/null | grep -vF "${cron_tag}" || true
		echo "${cron_schedule} ${_env_prefix}/bin/bash -lc ${_cron_exec} >> ${_cron_log} 2>&1 # ${cron_tag}"
	) | crontab - 2>/dev/null || true
	return 0
}

# Detect whether a systemd user timer exists for a scheduler routine.
# Args: $1=service_name (without .timer suffix)
_scheduler_systemd_timer_present() {
	local service_name="$1"
	local timer_name="${service_name}.timer"
	local timer_file="$HOME/.config/systemd/user/${timer_name}"

	if command -v systemctl >/dev/null 2>&1; then
		if systemctl --user is-enabled "$timer_name" >/dev/null 2>&1; then
			return 0
		fi
		if systemctl --user is-active "$timer_name" >/dev/null 2>&1; then
			return 0
		fi
	fi

	[[ -f "$timer_file" ]] && return 0
	return 1
}

# Remove cron entries matching a scheduler tag while preserving unrelated jobs.
# Args: $1=cron_tag, $2=routine_label, $3=current_cron(optional), $4=defer_write(optional)
_scheduler_remove_cron_tag() {
	local cron_tag="$1"
	local routine_label="$2"
	local provided_cron="${3-}"
	local defer_write="${4:-false}"
	local current_cron=""
	local filtered_cron=""
	local temp_cron=""

	command -v crontab >/dev/null 2>&1 || return 1
	if [[ "$#" -ge 3 ]]; then
		current_cron="$provided_cron"
	else
		current_cron=$(crontab -l 2>/dev/null) || current_cron=""
	fi
	[[ -n "$current_cron" ]] || return 1
	printf '%s\n' "$current_cron" | grep -qF "$cron_tag" || return 1

	filtered_cron=$(printf '%s\n' "$current_cron" | grep -vF "$cron_tag" || true)
	_SCHEDULER_RECONCILED_CRON_RESULT="$filtered_cron"
	_SCHEDULER_RECONCILED_CRON_CHANGED=true
	if [[ "$defer_write" == "true" ]]; then
		_SCHEDULER_RECONCILED_LABELS="${_SCHEDULER_RECONCILED_LABELS}${routine_label}
"
		return 0
	fi

	if [[ -n "$filtered_cron" ]]; then
		temp_cron=$(mktemp)
		printf '%s\n' "$filtered_cron" >"$temp_cron"
		crontab "$temp_cron" 2>/dev/null || true
		rm -f "$temp_cron"
	else
		crontab -r 2>/dev/null || true
	fi

	print_info "Removed duplicate cron entry for ${routine_label}; kept systemd user timer"
	return 0
}

# Reconcile one Linux scheduler routine so systemd and cron are not both active.
# Systemd user timers are canonical when present; cron-only jobs are preserved.
# Args: $1=service_name, $2=cron_tag, $3=routine_label, $4=current_cron(optional), $5=defer_write(optional)
_reconcile_linux_scheduler_duplicate() {
	local service_name="$1"
	local cron_tag="$2"
	local routine_label="$3"
	local provided_cron="${4-}"
	local defer_write="${5:-false}"
	local current_cron=""
	local has_cron=false

	if command -v crontab >/dev/null 2>&1; then
		if [[ "$#" -ge 4 ]]; then
			current_cron="$provided_cron"
		else
			current_cron=$(crontab -l 2>/dev/null) || current_cron=""
		fi
		if [[ -n "$current_cron" ]] && printf '%s\n' "$current_cron" | grep -qF "$cron_tag"; then
			has_cron=true
		fi
	else
		return 0
	fi

	if _scheduler_systemd_timer_present "$service_name"; then
		if [[ "$has_cron" == "true" ]]; then
			_scheduler_remove_cron_tag "$cron_tag" "$routine_label" "$current_cron" "$defer_write" || true
		fi
		return 0
	fi

	return 0
}

# Reconcile known Linux aidevops routines that may have migrated from cron to systemd.
_reconcile_linux_scheduler_duplicates() {
	local current_cron=""
	local reconciled_cron=""
	local routine_label=""
	local temp_cron=""
	local changed=false

	command -v crontab >/dev/null 2>&1 || return 0
	current_cron=$(crontab -l 2>/dev/null) || current_cron=""
	_SCHEDULER_RECONCILED_LABELS=""

	_SCHEDULER_RECONCILED_CRON_RESULT=""
	_SCHEDULER_RECONCILED_CRON_CHANGED=false
	_reconcile_linux_scheduler_duplicate \
		"aidevops-auto-update" \
		"# aidevops-auto-update" \
		"auto-update" \
		"$current_cron" \
		true
	if [[ "$_SCHEDULER_RECONCILED_CRON_CHANGED" == "true" ]]; then
		current_cron="$_SCHEDULER_RECONCILED_CRON_RESULT"
		changed=true
	fi

	_SCHEDULER_RECONCILED_CRON_RESULT=""
	_SCHEDULER_RECONCILED_CRON_CHANGED=false
	_reconcile_linux_scheduler_duplicate \
		"aidevops-pulse-merge" \
		"aidevops: pulse-merge-routine" \
		"pulse merge" \
		"$current_cron" \
		true
	if [[ "$_SCHEDULER_RECONCILED_CRON_CHANGED" == "true" ]]; then
		current_cron="$_SCHEDULER_RECONCILED_CRON_RESULT"
		changed=true
	fi

	_SCHEDULER_RECONCILED_CRON_RESULT=""
	_SCHEDULER_RECONCILED_CRON_CHANGED=false
	_reconcile_linux_scheduler_duplicate \
		"aidevops-supervisor-pulse" \
		"aidevops: supervisor-pulse" \
		"supervisor pulse" \
		"$current_cron" \
		true
	if [[ "$_SCHEDULER_RECONCILED_CRON_CHANGED" == "true" ]]; then
		current_cron="$_SCHEDULER_RECONCILED_CRON_RESULT"
		changed=true
	fi

	_SCHEDULER_RECONCILED_CRON_RESULT=""
	_SCHEDULER_RECONCILED_CRON_CHANGED=false
	_reconcile_linux_scheduler_duplicate \
		"aidevops-stats-wrapper" \
		"aidevops: stats-wrapper" \
		"stats wrapper" \
		"$current_cron" \
		true
	if [[ "$_SCHEDULER_RECONCILED_CRON_CHANGED" == "true" ]]; then
		current_cron="$_SCHEDULER_RECONCILED_CRON_RESULT"
		changed=true
	fi

	if [[ "$changed" != "true" ]]; then
		return 0
	fi

	if [[ -n "$current_cron" ]]; then
		temp_cron=$(mktemp)
		printf '%s\n' "$current_cron" >"$temp_cron"
		crontab "$temp_cron" 2>/dev/null || true
		rm -f "$temp_cron"
	else
		crontab -r 2>/dev/null || true
	fi

	reconciled_cron="$_SCHEDULER_RECONCILED_LABELS"
	while IFS= read -r routine_label; do
		[[ -n "$routine_label" ]] || continue
		print_info "Removed duplicate cron entry for ${routine_label}; kept systemd user timer"
	done <<<"$reconciled_cron"
	return 0
}

# Dispatcher: install a scheduler on Linux, preferring systemd over cron.
# Args:
#   $1 = service_name   (systemd service name, e.g. "aidevops-stats-wrapper")
#   $2 = cron_tag       (comment tag for cron line, e.g. "aidevops: stats-wrapper")
#   $3 = cron_schedule  (cron schedule expression, e.g. "*/15 * * * *")
#   $4 = exec_command   (shell command run via /bin/bash -lc)
#   $5 = interval_sec   (systemd OnUnitActiveSec in seconds; may be empty for calendar-only)
#   $6 = log_file       (absolute path to log file)
#   $7 = env_vars       (newline-separated KEY=VALUE pairs for systemd/cron, may be empty)
#   $8 = success_msg    (message to print on success)
#   $9 = fail_msg       (message to print on failure)
#   $10 = run_at_load   ("true" or "false")
#   $11 = low_priority  ("true" or "false")
#   $12 = on_calendar   (optional systemd OnCalendar spec)
#   $13 = timeout_sec   (optional TimeoutStartSec)
# Returns 0 always (failures are warnings, not fatal).
_install_scheduler_linux() {
	local service_name="$1"
	local cron_tag="$2"
	local cron_schedule="$3"
	local exec_command="$4"
	local interval_sec="$5"
	local log_file="$6"
	local env_vars="$7"
	local success_msg="$8"
	local fail_msg="$9"
	local run_at_load="${10}"
	local low_priority="${11}"
	local on_calendar="${12:-}"
	local timeout_sec="${13:-}"

	if _systemd_user_available; then
		if _install_scheduler_systemd \
			"$service_name" \
			"$exec_command" \
			"$interval_sec" \
			"$log_file" \
			"$env_vars" \
			"$run_at_load" \
			"$low_priority" \
			"$on_calendar" \
			"$timeout_sec"; then
			print_info "${success_msg} (systemd user timer)"
			# After systemd install succeeds, remove any pre-existing cron entry
			# to prevent dual-execution (GH#17695 Finding A)
			_reconcile_linux_scheduler_duplicate "$service_name" "$cron_tag" "$cron_tag"
		else
			print_warning "systemd enable failed for ${service_name} — falling back to cron"
			_install_scheduler_cron "$cron_tag" "$cron_schedule" "$exec_command" "$log_file" "$env_vars"
			if crontab -l 2>/dev/null | grep -qF "${cron_tag}" 2>/dev/null; then
				print_info "${success_msg} (cron fallback)"
			else
				print_warning "${fail_msg}"
			fi
		fi
	else
		_install_scheduler_cron "$cron_tag" "$cron_schedule" "$exec_command" "$log_file" "$env_vars"
		if crontab -l 2>/dev/null | grep -qF "${cron_tag}" 2>/dev/null; then
			print_info "${success_msg} (cron)"
		else
			print_warning "${fail_msg}"
		fi
	fi
	return 0
}

# Uninstall a scheduler across all backends (launchd/systemd/cron).
# Args:
#   $1 = os            (output of uname -s)
#   $2 = launchd_label (e.g. "sh.aidevops.stats-wrapper")
#   $3 = systemd_name  (e.g. "aidevops-stats-wrapper")
#   $4 = cron_tag      (grep pattern for cron line, e.g. "aidevops: stats-wrapper")
#   $5 = success_msg   (message to print on removal)
# Returns 0 always.
_uninstall_scheduler() {
	local _os="$1"
	local launchd_label="$2"
	local systemd_name="$3"
	local cron_tag="$4"
	local success_msg="$5"

	if [[ "$_os" == "Darwin" ]]; then
		local _plist="$HOME/Library/LaunchAgents/${launchd_label}.plist"
		if _launchd_has_agent "$launchd_label"; then
			launchctl unload "$_plist" 2>/dev/null || true
			rm -f "$_plist"
			print_info "${success_msg} (launchd agent removed)"
		fi
	else
		# Check and remove from ALL backends sequentially, not just the first
		# match. Prevents orphan entries when migrating between systemd and cron
		# (GH#17695 Finding A).
		if _systemd_user_available && systemctl --user is-enabled "${systemd_name}.timer" >/dev/null 2>&1; then
			systemctl --user disable --now "${systemd_name}.timer" 2>/dev/null || true
			rm -f "$HOME/.config/systemd/user/${systemd_name}.service"
			rm -f "$HOME/.config/systemd/user/${systemd_name}.timer"
			systemctl --user daemon-reload 2>/dev/null || true
			print_info "${success_msg} (systemd timer removed)"
		fi
		if command -v crontab >/dev/null 2>&1; then
			local current_cron
			current_cron=$(crontab -l 2>/dev/null) || current_cron=""
			if [[ -n "$current_cron" ]] && echo "$current_cron" | grep -qF "${cron_tag}"; then
				echo "$current_cron" | grep -vF "${cron_tag}" | crontab - 2>/dev/null || true
				print_info "${success_msg} (cron entry removed)"
			fi
		fi
	fi
	return 0
}

# Uninstall supervisor pulse (user explicitly disabled)
_uninstall_pulse() {
	local _os="$1"
	local pulse_label="$2"
	if [[ "$_os" == "Darwin" ]]; then
		local pulse_plist="$HOME/Library/LaunchAgents/${pulse_label}.plist"
		if _launchd_has_agent "$pulse_label"; then
			launchctl unload "$pulse_plist" || true
			rm -f "$pulse_plist"
			pkill -f 'Supervisor Pulse' 2>/dev/null || true
			print_info "Supervisor pulse disabled (launchd agent removed per config)"
		fi
	elif _systemd_user_available; then
		local service_name="aidevops-supervisor-pulse"
		if systemctl --user is-enabled "${service_name}.timer" >/dev/null 2>&1; then
			systemctl --user disable --now "${service_name}.timer" 2>/dev/null || true
			rm -f "$HOME/.config/systemd/user/${service_name}.service"
			rm -f "$HOME/.config/systemd/user/${service_name}.timer"
			systemctl --user daemon-reload 2>/dev/null || true
			print_info "Supervisor pulse disabled (systemd timer removed per config)"
		fi
	else
		if crontab -l 2>/dev/null | grep -qF "pulse-wrapper"; then
			crontab -l 2>/dev/null | grep -v 'aidevops: supervisor-pulse' | crontab - || true
			print_info "Supervisor pulse disabled (cron entry removed per config)"
		fi
	fi
	return 0
}
