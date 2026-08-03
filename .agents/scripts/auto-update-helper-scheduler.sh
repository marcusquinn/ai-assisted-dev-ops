#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Auto-Update Scheduler Sub-Library -- Platform-aware enable/disable for
# launchd (macOS), systemd (Linux), and cron (fallback).
# =============================================================================
# Extracted from auto-update-helper.sh to keep the orchestrator under the
# 1500-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/auto-update-helper-scheduler.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, GREEN,
#     YELLOW, NC, get_feature_toggle, is_feature_enabled)
#   - auto-update-helper-check.sh (get_local_version, update_state)
#   - Orchestrator constants: LAUNCHD_LABEL, LAUNCHD_DIR, LAUNCHD_PLIST,
#     SYSTEMD_SERVICE_DIR, SYSTEMD_UNIT_NAME, CRON_MARKER, LOG_FILE,
#     DEFAULT_INTERVAL, INSTALL_DIR, SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AUTO_UPDATE_SCHEDULER_LIB_LOADED:-}" ]] && return 0
_AUTO_UPDATE_SCHEDULER_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

_auto_update_scheduler_dir="${BASH_SOURCE[0]%/*}"
[[ "$_auto_update_scheduler_dir" == "${BASH_SOURCE[0]}" ]] && _auto_update_scheduler_dir="."
# shellcheck source=plist-env-overrides-lib.sh
source "${_auto_update_scheduler_dir}/plist-env-overrides-lib.sh"
unset _auto_update_scheduler_dir

# --- Functions ---

#######################################
# Detect scheduler backend for current platform
# Sources platform-detect.sh for accurate detection (GH#17695 Finding C).
# Returns: "launchd" on macOS, "systemd" or "cron" on Linux
#######################################
_get_scheduler_backend() {
	# Source platform-detect.sh if AIDEVOPS_SCHEDULER is not already set
	if [[ -z "${AIDEVOPS_SCHEDULER:-}" ]]; then
		local _pd_path
		_pd_path="$(dirname "${BASH_SOURCE[0]}")/platform-detect.sh"
		if [[ -f "$_pd_path" ]]; then
			# shellcheck source=platform-detect.sh
			source "$_pd_path"
		fi
	fi
	# Fall back to simple uname check if platform-detect.sh unavailable
	if [[ -n "${AIDEVOPS_SCHEDULER:-}" ]]; then
		echo "$AIDEVOPS_SCHEDULER"
	elif [[ "$(uname)" == "Darwin" ]]; then
		echo "launchd"
	else
		echo "cron"
	fi
	return 0
}

#######################################
# Check if the auto-update LaunchAgent is loaded
# Returns: 0 if loaded, 1 if not
#######################################
_launchd_is_loaded() {
	# Use a variable to avoid SIGPIPE (141) when grep -q exits early
	# under set -o pipefail (t1265)
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$LAUNCHD_LABEL"
	return $?
}

#######################################
# Generate auto-update LaunchAgent plist content
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#   $3 - env_path
#######################################
_generate_auto_update_plist() {
	local script_path="$1"
	local interval_seconds="$2"
	local env_path="$3"
	env_path=$(aidevops_launchd_sanitized_path "$env_path")
	local env_overrides_xml
	env_overrides_xml=$(_build_plist_env_overrides_xml "$LAUNCHD_LABEL")

	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${script_path}</string>
		<string>check</string>
	</array>
	<key>StartInterval</key>
	<integer>${interval_seconds}</integer>
	<key>StandardOutPath</key>
	<string>${LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${env_path}</string>
${env_overrides_xml}	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
EOF
	return 0
}

#######################################
# Migrate existing cron entry to launchd (macOS only)
# Called automatically when cmd_enable runs on macOS
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#######################################
_migrate_cron_to_launchd() {
	local script_path="$1"
	local interval_seconds="$2"

	# Check if cron entry exists
	if ! crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
		return 0
	fi

	# Skip migration if launchd agent already loaded (t1265)
	if _launchd_is_loaded; then
		log_info "LaunchAgent already loaded — removing stale cron entry only"
	else
		log_info "Migrating auto-update from cron to launchd..."

		# Generate and write plist
		mkdir -p "$LAUNCHD_DIR"
		_generate_auto_update_plist "$script_path" "$interval_seconds" "${PATH}" >"$LAUNCHD_PLIST"

		# Load into launchd
		if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
			log_info "LaunchAgent loaded: $LAUNCHD_LABEL"
		else
			log_error "Failed to load LaunchAgent during migration"
			return 1
		fi
	fi

	# Remove old cron entry
	local temp_cron
	temp_cron=$(mktemp)
	if crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron"; then
		crontab "$temp_cron"
	else
		crontab -r 2>/dev/null || true
	fi
	rm -f "$temp_cron"

	log_info "Migration complete: auto-update now managed by launchd"
	return 0
}

#######################################
# Install auto-update as a macOS LaunchAgent
# Args: $1 = script_path, $2 = interval (minutes)
# Returns: 0 on success, 1 on failure
#######################################
_cmd_enable_launchd() {
	local script_path="$1"
	local interval="$2"
	local interval_seconds=$((interval * 60))

	# Migrate from old label if present (t1260)
	local old_label="com.aidevops.auto-update"
	local old_plist="${LAUNCHD_DIR}/${old_label}.plist"
	if launchctl list 2>/dev/null | grep -qF "$old_label"; then
		launchctl unload -w "$old_plist" 2>/dev/null || true
		log_info "Unloaded old LaunchAgent: $old_label"
	fi
	rm -f "$old_plist"

	# Auto-migrate existing cron entry if present
	_migrate_cron_to_launchd "$script_path" "$interval_seconds"

	mkdir -p "$LAUNCHD_DIR"

	# Create named symlink so macOS System Settings shows "aidevops-auto-update"
	# instead of the raw script name (t1260). Preserve an already-correct link
	# so recurring enable checks do not register a new background item.
	local bin_dir="$HOME/.aidevops/bin"
	mkdir -p "$bin_dir"
	local display_link="$bin_dir/aidevops-auto-update"
	aidevops_ensure_symlink_target "$script_path" "$display_link" || return 1

	# Generate plist content and compare to existing (t1265)
	local new_content
	new_content=$(_generate_auto_update_plist "$display_link" "$interval_seconds" "${PATH}")

	# Skip if already loaded with identical config (avoids macOS notification)
	if _launchd_is_loaded && [[ -f "$LAUNCHD_PLIST" ]]; then
		local existing_content
		existing_content=$(cat "$LAUNCHD_PLIST" 2>/dev/null) || existing_content=""
		if [[ "$existing_content" == "$new_content" ]]; then
			print_info "Auto-update LaunchAgent already installed with identical config ($LAUNCHD_LABEL)"
			update_state "enable" "$(get_local_version)" "enabled"
			return 0
		fi
		# Loaded but config differs — don't overwrite while running
		print_info "Auto-update LaunchAgent already loaded ($LAUNCHD_LABEL)"
		update_state "enable" "$(get_local_version)" "enabled"
		return 0
	fi

	echo "$new_content" >"$LAUNCHD_PLIST"

	if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
		update_state "enable" "$(get_local_version)" "enabled"
		print_success "Auto-update enabled (every ${interval} minutes)"
		echo ""
		echo "  Scheduler: launchd (macOS LaunchAgent)"
		echo "  Label:     $LAUNCHD_LABEL"
		echo "  Plist:     $LAUNCHD_PLIST"
		echo "  Script:    $script_path"
		echo "  Logs:      $LOG_FILE"
		echo ""
		echo "  Disable with: aidevops auto-update disable"
		echo "  Check now:    aidevops auto-update check"
	else
		print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
		return 1
	fi
	return 0
}

#######################################
# Install auto-update as a Linux systemd user timer
# Args: $1 = script_path, $2 = interval (minutes)
# Returns: 0 on success, falls back to cron on failure
# Modelled on worker-watchdog.sh:_install_systemd() (GH#17691)
#######################################
_cmd_enable_systemd() {
	local script_path="$1"
	local interval="$2"
	local service_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.service"
	local timer_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.timer"
	local interval_sec
	interval_sec=$((interval * 60))

	mkdir -p "${SYSTEMD_SERVICE_DIR}"

	# shellcheck disable=SC1078,SC1079  # multi-line printf with single quotes inside a double-quoted string; ${script_path} kept inside outer double quotes for safe expansion
	# Set WorkingDirectory to the canonical agents dir so skill writes land in
	# ~/.aidevops/agents/ not $HOME when the unit is started by systemd (#21542).
	local agents_dir
	agents_dir="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
	printf '%s' "[Unit]
Description=aidevops auto-update
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc '${script_path} check'
WorkingDirectory=${agents_dir}
TimeoutStartSec=120
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
" >"$service_file"

	printf '%s' "[Unit]
Description=aidevops auto-update Timer

[Timer]
OnBootSec=${interval_sec}
OnUnitActiveSec=${interval_sec}
Persistent=true

[Install]
WantedBy=timers.target
" >"$timer_file"

	systemctl --user daemon-reload 2>/dev/null || true
	if ! systemctl --user enable --now "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null; then
		print_error "Failed to enable systemd timer — falling back to cron" >&2
		_cmd_enable_cron "$script_path" "$interval"
		return $?
	fi

	update_state "enable" "$(get_local_version)" "enabled"

	print_success "Auto-update enabled (every ${interval} minutes)"
	echo ""
	echo "  Scheduler: systemd user timer"
	echo "  Unit:      ${SYSTEMD_UNIT_NAME}.timer"
	echo "  Service:   ${service_file}"
	echo "  Timer:     ${timer_file}"
	echo "  Logs:      ${LOG_FILE}"
	echo ""
	echo "  Disable with: aidevops auto-update disable"
	echo "  Check now:    aidevops auto-update check"
	echo ""
	# Check linger state so the timer survives logout on headless/server Linux hosts.
	_print_linger_status
	return 0
}

#######################################
# Disable auto-update systemd user timer
# Returns: 0 on success
#######################################
_cmd_disable_systemd() {
	local had_entry=false

	if systemctl --user is-enabled "${SYSTEMD_UNIT_NAME}.timer" >/dev/null 2>&1; then
		had_entry=true
		systemctl --user disable --now "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null || true
	fi

	local service_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.service"
	local timer_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.timer"
	if [[ -f "$timer_file" ]]; then
		had_entry=true
		rm -f "$timer_file"
	fi
	if [[ -f "$service_file" ]]; then
		rm -f "$service_file"
	fi
	systemctl --user daemon-reload 2>/dev/null || true

	# Also remove any lingering cron entry
	if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
		local temp_cron
		temp_cron=$(mktemp)
		crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron" || true
		crontab "$temp_cron"
		rm -f "$temp_cron"
		had_entry=true
	fi

	update_state "disable" "$(get_local_version)" "disabled"

	if [[ "$had_entry" == "true" ]]; then
		print_success "Auto-update disabled"
	else
		print_info "Auto-update was not enabled"
	fi
	return 0
}

#######################################
# Install auto-update as a Linux cron entry
# Args: $1 = script_path, $2 = interval (minutes)
# Returns: 0 on success
#######################################
_cmd_enable_cron() {
	local script_path="$1"
	local interval="$2"

	# Build cron expression
	local cron_expr="*/${interval} * * * *"
	local cron_line="$cron_expr $script_path check >> $LOG_FILE 2>&1 $CRON_MARKER"

	# Get existing crontab (excluding our entry)
	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true

	# Add our entry and install
	echo "$cron_line" >>"$temp_cron"
	crontab "$temp_cron"
	rm -f "$temp_cron"

	update_state "enable" "$(get_local_version)" "enabled"

	print_success "Auto-update enabled (every ${interval} minutes)"
	echo ""
	echo "  Schedule: $cron_expr"
	echo "  Script:   $script_path"
	echo "  Logs:     $LOG_FILE"
	echo ""
	echo "  Disable with: aidevops auto-update disable"
	echo "  Check now:    aidevops auto-update check"
	return 0
}

#######################################
# Enable auto-update scheduler (platform-aware)
# On macOS: installs LaunchAgent plist
# On Linux: installs crontab entry
#######################################
cmd_enable() {
	ensure_dirs

	# Parse flags (t2898): --idempotent skips the install when already loaded.
	# Existing callers retain the same behaviour because no flag = legacy path.
	local idempotent=0
	local _arg
	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
		--idempotent)
			idempotent=1
			shift
			;;
		--)
			shift
			break
			;;
		*)
			# Forward unknown args to platform installers (none today).
			break
			;;
		esac
	done

	# Idempotent fast-path: if the daemon is already loaded (regardless of
	# state-file freshness), this is a no-op. setup.sh calls this on every
	# release so the daemon self-heals — but the existing user state must
	# survive (custom intervals, env vars). "Loaded but stalled" is also a
	# no-op here; the caller follows up with `health-check` to surface it.
	if [[ "$idempotent" -eq 1 ]] && _daemon_is_loaded; then
		log_info "auto-update daemon already loaded (idempotent enable — no-op)"
		return 0
	fi

	# Read from JSONC config (handles env var > user config > defaults priority)
	local interval
	interval=$(get_feature_toggle update_interval "$DEFAULT_INTERVAL")
	# Validate interval is a positive integer
	if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -eq 0 ]]; then
		log_warn "updates.update_interval_minutes='${interval}' is not a positive integer — using default (${DEFAULT_INTERVAL}m)"
		interval="$DEFAULT_INTERVAL"
	fi
	local script_path="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"

	# Verify the script exists at the deployed location
	if [[ ! -x "$script_path" ]]; then
		# Fall back to repo location
		script_path="$INSTALL_DIR/.agents/scripts/auto-update-helper.sh"
		if [[ ! -x "$script_path" ]]; then
			print_error "auto-update-helper.sh not found"
			return 1
		fi
	fi

	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		_cmd_enable_launchd "$script_path" "$interval"
		return $?
	elif [[ "$backend" == "systemd" ]]; then
		_cmd_enable_systemd "$script_path" "$interval"
		return $?
	fi

	_cmd_enable_cron "$script_path" "$interval"
	return $?
}

#######################################
# Disable auto-update scheduler (platform-aware)
# On macOS: unloads and removes LaunchAgent plist
# On Linux: removes crontab entry or systemd timer
#######################################
cmd_disable() {
	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		local had_entry=false

		if _launchd_is_loaded; then
			had_entry=true
			launchctl unload -w "$LAUNCHD_PLIST" 2>/dev/null || true
		fi

		if [[ -f "$LAUNCHD_PLIST" ]]; then
			had_entry=true
			rm -f "$LAUNCHD_PLIST"
		fi

		# Also remove any lingering cron entry (migration cleanup)
		if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
			local temp_cron
			temp_cron=$(mktemp)
			crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron" || true
			crontab "$temp_cron"
			rm -f "$temp_cron"
			had_entry=true
		fi

		update_state "disable" "$(get_local_version)" "disabled"

		if [[ "$had_entry" == "true" ]]; then
			print_success "Auto-update disabled"
		else
			print_info "Auto-update was not enabled"
		fi
		return 0
	elif [[ "$backend" == "systemd" ]]; then
		_cmd_disable_systemd
		return $?
	fi

	# Linux: cron backend
	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	local had_entry=false
	if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
		had_entry=true
	fi

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true
	crontab "$temp_cron"
	rm -f "$temp_cron"

	update_state "disable" "$(get_local_version)" "disabled"

	if [[ "$had_entry" == "true" ]]; then
		print_success "Auto-update disabled"
	else
		print_info "Auto-update was not enabled"
	fi
	return 0
}

#######################################
# Print linger status row for systemd user timer.
# Linger allows the user manager to keep running after logout.
# Skips silently when loginctl is absent (containers) or when user is root.
# Args: none. Reads $USER from environment.
# Returns: 0
#######################################
_print_linger_status() {
	[[ "${USER:-}" == "root" ]] && return 0
	command -v loginctl &>/dev/null || return 0
	local _linger_state _linger_cmd
	_linger_state=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)
	_linger_cmd="sudo loginctl enable-linger $USER"
	if [[ "$_linger_state" == "yes" ]]; then
		echo -e "  Linger:    ${GREEN}yes${NC}"
	elif [[ "$_linger_state" == "no" ]]; then
		echo -e "  Linger:    ${YELLOW}no${NC} — timer stops on logout; fix: ${_linger_cmd}"
	else
		echo -e "  Linger:    ${YELLOW}unknown${NC} — run: ${_linger_cmd}"
	fi
	return 0
}

#######################################
# Daemon-loaded check (platform-aware) — t2898.
# Returns 0 if the auto-update daemon is loaded/installed under the active
# scheduler backend, 1 otherwise. Mirrors the platform detection in
# `_cmd_status_scheduler` but without the human-readable output.
#
# This is a "is the unit registered" check, not a "did it run recently"
# check. For freshness, see `cmd_health_check` which combines both.
#######################################
_daemon_is_loaded() {
	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		_launchd_is_loaded
		return $?
	fi

	if [[ "$backend" == "systemd" ]]; then
		# `is-active --quiet` is true when the timer is running (loaded AND
		# enabled in this session). Falls back to `is-enabled` for the case
		# where the timer is registered but the user just hasn't started it
		# yet (e.g. fresh setup before logout/login). Either is fine for
		# "the daemon is registered with the scheduler".
		if command -v systemctl &>/dev/null; then
			systemctl --user is-active --quiet "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null && return 0
			systemctl --user is-enabled --quiet "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null && return 0
		fi
		return 1
	fi

	# cron fallback (Linux without systemctl)
	local crontab_output
	crontab_output=$(crontab -l 2>/dev/null) || true
	echo "$crontab_output" | grep -qF "$CRON_MARKER"
	return $?
}
