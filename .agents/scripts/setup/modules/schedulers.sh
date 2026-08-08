#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Scheduler setup orchestrator: sources sub-libraries and provides the
# monitoring-tier setup functions (stats wrapper, failure miner, process
# guard, memory pressure monitor, screen time snapshot).
# Part of aidevops setup.sh modularization (GH#5793)
#
# Split from a 2754-line monolith (GH#21052) into three focused sub-libraries:
#   - schedulers-pulse.sh    (pulse resolution, supervisor, plist, watchdog)
#   - schedulers-linux.sh    (systemd/cron scheduler install/uninstall)
#   - schedulers-platform.sh (contribution watch, complexity scan, profile
#                             README, token refresh, DB maintenance, repo
#                             health, peer productivity monitor)
#
# Functions that remain here (setup_failure_miner is >100 lines; identity-key
# rule from reference/large-file-split.md §3 requires it stays in this file):
#   setup_stats_wrapper, setup_failure_miner, setup_process_guard,
#   setup_memory_pressure_monitor, setup_screen_time_snapshot

# Keep pulse workers alive long enough for thinking-tier dispatches.
PULSE_STALE_THRESHOLD_SECONDS=1800

# Cron expression: top of every hour. Shared by stats-wrapper,
# contribution-watch, and profile-readme schedulers — keep DRY so a
# future cadence shift only touches one place.
CRON_HOURLY="0 * * * *"

# Cron expression: every minute. Shared by process-guard, memory-pressure
# monitor, and pulse-watchdog schedulers (cron's minimum granularity).
# Kept DRY for the same reason as CRON_HOURLY.
CRON_EVERY_MINUTE="* * * * *"

# Direct unit tests source this module without setup.sh's later
# shared-constants.sh load. Provide a small fallback; the shared helper
# overwrites this when setup.sh sources shared-constants.sh.
if ! declare -F aidevops_launchd_sanitized_path >/dev/null 2>&1; then
	aidevops_launchd_sanitized_path() {
		local input_path="${1:-${PATH:-}}"
		local stable_path=""
		if [[ -n "${HOME:-}" ]]; then
			stable_path="${HOME}/.bun/bin:${HOME}/.local/bin:${HOME}/.aidevops/agents/scripts:${HOME}/.aidevops/bin"
		fi
		local default_path="${stable_path:+${stable_path}:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
		local result=""
		local seen=""
		local dir=""
		local IFS=':'
		for dir in $default_path:$input_path; do
			[[ -n "$dir" ]] || continue
			case "$dir" in
			*/.aidevops/runtime-bundles/*) continue ;;
			esac
			[[ -d "$dir" ]] || continue
			case ":$seen:" in
			*":${dir}:"*) continue ;;
			esac
			seen="${seen:+${seen}:}${dir}"
			result="${result:+${result}:}${dir}"
		done
		printf '%s' "$result"
		return 0
	}
fi

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# SCRIPT_DIR — resolves to the setup modules directory so sub-library
# source calls work regardless of the caller's working directory or any
# inherited SCRIPT_DIR from parent scripts. Always derive from ${BASH_SOURCE[0]}
# to ensure sub-libraries load from the correct location.
_sched_orch_lib_path="${BASH_SOURCE[0]%/*}"
[[ "$_sched_orch_lib_path" == "${BASH_SOURCE[0]}" ]] && _sched_orch_lib_path="."
SCRIPT_DIR="$(cd "$_sched_orch_lib_path" && pwd)"
unset _sched_orch_lib_path

# Source sub-libraries. Each carries its own include guard so double-sourcing
# is safe. SC1091 suppressed per reference/large-file-split.md §5.1 — paths
# are computed at runtime via $SCRIPT_DIR and cannot be statically resolved.

# shellcheck source=./schedulers-pulse.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/schedulers-pulse.sh"

# shellcheck source=./schedulers-linux.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/schedulers-linux.sh"

# shellcheck source=./schedulers-platform.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/schedulers-platform.sh"

# Setup stats-wrapper scheduler — runs quality sweep and health issue updates
# separately from the pulse (t1429). Only installed when the supervisor
# pulse is enabled (stats are useless without it).
# macOS: launchd plist (hourly) | Linux: systemd timer or cron (hourly)
# t2744: interval raised from 15 min → hourly. Stats UI is not realtime,
# the four-times-an-hour cadence drove ~200-400 GraphQL points/hr of pure
# overhead on multi-repo setups.
setup_stats_wrapper() {
	local _pulse_lower="$1"
	# Use effective pulse state (PULSE_ENABLED) if available; fall back to consent string.
	# PULSE_ENABLED reflects the actual install decision (e.g., false when wrapper is missing).
	local _pulse_effective="${PULSE_ENABLED:-$_pulse_lower}"
	local stats_script="$HOME/.aidevops/agents/scripts/stats-wrapper.sh"
	local stats_label="com.aidevops.aidevops-stats-wrapper"
	local stats_systemd="aidevops-stats-wrapper"
	local stats_log="$HOME/.aidevops/logs/stats.log"
	if [[ -x "$stats_script" ]] && [[ "$_pulse_effective" == "true" ]]; then
		# Always regenerate to pick up config/format changes (matches pulse behavior)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			local stats_plist="$HOME/Library/LaunchAgents/${stats_label}.plist"

			local _xml_stats_script _xml_stats_home _xml_stats_path
			_xml_stats_script=$(_xml_escape "$stats_script")
			_xml_stats_home=$(_xml_escape "$HOME")
			_xml_stats_path=$(_xml_escape "$(aidevops_launchd_sanitized_path "$PATH")")
			local stats_plist_content
			stats_plist_content=$(
				cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${stats_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_stats_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_stats_home}/.aidevops/logs/stats.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_stats_home}/.aidevops/logs/stats.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_stats_path}</string>
		<key>HOME</key>
		<string>${_xml_stats_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
PLIST
			)
			if _launchd_install_if_changed "$stats_label" "$stats_plist" "$stats_plist_content"; then
				print_info "Stats wrapper enabled (launchd, every hour)"
			else
				print_warning "Failed to load stats wrapper LaunchAgent"
			fi
		else
			_install_scheduler_linux \
				"$stats_systemd" \
				"aidevops: stats-wrapper" \
				"$CRON_HOURLY" \
				"\"${stats_script}\"" \
				"3600" \
				"$stats_log" \
				"" \
				"Stats wrapper enabled (every hour)" \
				"Failed to install stats wrapper scheduler" \
				"true" \
				"false"
		fi
	elif [[ "$_pulse_effective" == "false" ]]; then
		# Remove stats scheduler if pulse is disabled
		_uninstall_scheduler \
			"$(uname -s)" \
			"$stats_label" \
			"$stats_systemd" \
			"aidevops: stats-wrapper" \
			"Stats wrapper disabled (pulse is off)"
	fi
	return 0
}

# Setup failure miner — mines GitHub CI failure notifications for systemic patterns
# and auto-files root-cause issues. Runs as a pure bash script (no LLM needed).
# Installed when pulse is enabled and the helper script exists.
# macOS: launchd plist (hourly at :15) | Linux: systemd timer or cron (hourly at :15)
#
# NOTE: This function is 105 lines and must remain in this file (schedulers.sh) to
# preserve its (file, fname) identity key for the function-complexity CI scanner.
# Moving it to a sub-library would register it as a new violation.
# See reference/large-file-split.md §3 "Identity-Key Preservation Rules".
setup_failure_miner() {
	local _pulse_lower="$1"
	local _pulse_effective="${PULSE_ENABLED:-$_pulse_lower}"
	local miner_script="$HOME/.aidevops/agents/scripts/gh-failure-miner-helper.sh"
	local miner_label="sh.aidevops.routine-gh-failure-miner"
	local miner_systemd="aidevops-gh-failure-miner"
	local miner_log="$HOME/.aidevops/logs/routine-gh-failure-miner.log"
	if [[ ! -x "$miner_script" ]] || [[ "$_pulse_effective" != "true" ]]; then
		# Remove scheduler if pulse is disabled or script missing
		_uninstall_scheduler \
			"$(uname -s)" \
			"$miner_label" \
			"$miner_systemd" \
			"aidevops: gh-failure-miner" \
			"Failure miner disabled (pulse is off or script missing)"
		return 0
	fi

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local miner_plist="$HOME/Library/LaunchAgents/${miner_label}.plist"

		local _xml_miner_script _xml_miner_home _xml_miner_path _xml_miner_log
		_xml_miner_script=$(_xml_escape "$miner_script")
		_xml_miner_home=$(_xml_escape "$HOME")
		_xml_miner_path=$(_xml_escape "$(aidevops_launchd_sanitized_path "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}")")
		_xml_miner_log=$(_xml_escape "$miner_log")

		local miner_plist_content
		miner_plist_content=$(
			cat <<MINER_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${miner_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_miner_script}</string>
		<string>create-issues</string>
		<string>--since-hours</string>
		<string>24</string>
		<string>--pulse-repos</string>
		<string>--systemic-threshold</string>
		<string>2</string>
		<string>--max-issues</string>
		<string>3</string>
		<string>--label</string>
		<string>auto-dispatch</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>${_xml_miner_home}</string>
		<key>PATH</key>
		<string>${_xml_miner_path}</string>
	</dict>
	<key>StartCalendarInterval</key>
	<array>
		<dict>
			<key>Minute</key>
			<integer>15</integer>
		</dict>
	</array>
	<key>StandardOutPath</key>
	<string>${_xml_miner_log}</string>
	<key>StandardErrorPath</key>
	<string>${_xml_miner_log}</string>
	<key>RunAtLoad</key>
	<false/>
</dict>
</plist>
MINER_PLIST
		)

		if _launchd_install_if_changed "$miner_label" "$miner_plist" "$miner_plist_content"; then
			print_info "Failure miner enabled (launchd, hourly at :15)"
		else
			print_warning "Failed to load failure miner LaunchAgent"
		fi
	else
		_install_scheduler_linux \
			"$miner_systemd" \
			"aidevops: gh-failure-miner" \
			"15 * * * *" \
			"\"${miner_script}\" create-issues --since-hours 24 --pulse-repos --systemic-threshold 2 --max-issues 3 --label auto-dispatch" \
			"3600" \
			"$miner_log" \
			"" \
			"Failure miner enabled (hourly at :15)" \
			"Failed to install failure miner scheduler" \
			"false" \
			"false" \
			"*-*-* *:15:00"
	fi
	return 0
}

# Setup process guard — kills runaway AI processes (ShellCheck bloat, stuck workers)
# before they exhaust memory and cause kernel panics. Always installed when the
# script exists; no consent needed (safety net, not autonomous action).
# macOS: launchd plist (30s interval, RunAtLoad=true) | Linux: systemd timer or cron (every minute)
setup_process_guard() {
	local guard_script="$HOME/.aidevops/agents/scripts/process-guard-helper.sh"
	local guard_label="sh.aidevops.process-guard"
	local guard_systemd="aidevops-process-guard"
	local guard_log="$HOME/.aidevops/logs/process-guard.log"
	if [[ ! -x "$guard_script" ]]; then
		return 0
	fi

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local guard_plist="$HOME/Library/LaunchAgents/${guard_label}.plist"

		# XML-escape paths for safe plist embedding (prevents injection
		# if $HOME or paths contain &, <, > characters)
		local _xml_guard_script _xml_guard_home _xml_guard_path
		_xml_guard_script=$(_xml_escape "$guard_script")
		_xml_guard_home=$(_xml_escape "$HOME")
		_xml_guard_path=$(_xml_escape "$(aidevops_launchd_sanitized_path "$PATH")")

		local guard_plist_content
		guard_plist_content=$(
			cat <<GUARD_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${guard_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_guard_script}</string>
		<string>kill-runaways</string>
	</array>
	<key>StartInterval</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>${_xml_guard_home}/.aidevops/logs/process-guard.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_guard_home}/.aidevops/logs/process-guard.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${_xml_guard_path}</string>
		<key>HOME</key>
		<string>${_xml_guard_home}</string>
		<key>SHELLCHECK_RSS_LIMIT_KB</key>
		<string>524288</string>
		<key>SHELLCHECK_RUNTIME_LIMIT</key>
		<string>120</string>
		<key>CHILD_RSS_LIMIT_KB</key>
		<string>8388608</string>
		<key>CHILD_RUNTIME_LIMIT</key>
		<string>7200</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
GUARD_PLIST
		)

		if _launchd_install_if_changed "$guard_label" "$guard_plist" "$guard_plist_content"; then
			print_info "Process guard enabled (launchd, every 30s, survives reboot)"
		else
			print_warning "Failed to load process guard LaunchAgent"
		fi
	else
		# Linux: systemd timer (30s) or cron fallback (every minute — cron minimum granularity)
		_install_scheduler_linux \
			"$guard_systemd" \
			"aidevops: process-guard" \
			"$CRON_EVERY_MINUTE" \
			"\"${guard_script}\" kill-runaways" \
			"30" \
			"$guard_log" \
			"SHELLCHECK_RSS_LIMIT_KB=524288
SHELLCHECK_RUNTIME_LIMIT=120
CHILD_RSS_LIMIT_KB=8388608
CHILD_RUNTIME_LIMIT=7200" \
			"Process guard enabled (every 30s)" \
			"Failed to install process guard scheduler" \
			"true" \
			"false"
	fi
	return 0
}

# Setup memory pressure monitor — process-focused memory watchdog (t1398.5, GH#2915).
# Monitors individual process RSS, runtime, session count, and aggregate memory.
# Auto-kills runaway ShellCheck (language server respawns them). Always installed
# when the script exists; no consent needed (safety net, not autonomous action).
# macOS: launchd plist (60s interval, RunAtLoad=true) | Linux: systemd timer or cron (every minute)
setup_memory_pressure_monitor() {
	local monitor_script="$HOME/.aidevops/agents/scripts/memory-pressure-monitor.sh"
	local monitor_label="sh.aidevops.memory-pressure-monitor"
	local monitor_systemd="aidevops-memory-pressure-monitor"
	local monitor_log="$HOME/.aidevops/logs/memory-pressure-launchd.log"
	if [[ ! -x "$monitor_script" ]]; then
		return 0
	fi

	mkdir -p "$HOME/.aidevops/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local monitor_plist="$HOME/Library/LaunchAgents/${monitor_label}.plist"

		# XML-escape paths for safe plist embedding
		local _xml_monitor_script _xml_monitor_home
		_xml_monitor_script=$(_xml_escape "$monitor_script")
		_xml_monitor_home=$(_xml_escape "$HOME")

		local monitor_plist_content
		monitor_plist_content=$(
			cat <<MONITOR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${monitor_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_monitor_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>StandardOutPath</key>
	<string>${_xml_monitor_home}/.aidevops/logs/memory-pressure-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_monitor_home}/.aidevops/logs/memory-pressure-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_monitor_home}</string>
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
MONITOR_PLIST
		)

		if _launchd_install_if_changed "$monitor_label" "$monitor_plist" "$monitor_plist_content"; then
			print_info "Memory pressure monitor enabled (launchd, every 60s, survives reboot)"
		else
			print_warning "Failed to load memory pressure monitor LaunchAgent"
		fi
	else
		# Linux: systemd timer (60s) or cron fallback (every minute — cron minimum granularity)
		_install_scheduler_linux \
			"$monitor_systemd" \
			"aidevops: memory-pressure-monitor" \
			"$CRON_EVERY_MINUTE" \
			"\"${monitor_script}\"" \
			"60" \
			"$monitor_log" \
			"" \
			"Memory pressure monitor enabled (every 60s)" \
			"Failed to install memory pressure monitor scheduler" \
			"true" \
			"true"
	fi
	return 0
}

# Setup screen time snapshot — captures daily screen time for contributor stats.
# Accumulates data in screen-time.jsonl (macOS Knowledge DB retains only ~28 days).
# Always installed when the script exists; no consent needed (data collection only).
# macOS: launchd plist (every 6h, RunAtLoad=true) | Linux: systemd timer or cron (every 6h)
setup_screen_time_snapshot() {
	local st_script="$HOME/.aidevops/agents/scripts/screen-time-helper.sh"
	local st_label="sh.aidevops.screen-time-snapshot"
	local st_systemd="aidevops-screen-time-snapshot"
	local st_log="$HOME/.aidevops/.agent-workspace/logs/screen-time-snapshot.log"
	if [[ ! -x "$st_script" ]]; then
		return 0
	fi

	mkdir -p "$HOME/.aidevops/.agent-workspace/logs"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local st_plist="$HOME/Library/LaunchAgents/${st_label}.plist"

		# XML-escape paths for safe plist embedding
		local _xml_st_script _xml_st_home
		local st_command
		st_command=$(_core_routine_logged_command "r909" "$(_core_routine_shell_quote "$st_script") snapshot")
		_xml_st_script=$(_xml_escape "$st_command")
		_xml_st_home=$(_xml_escape "$HOME")

		local st_plist_content
		st_plist_content=$(
			cat <<ST_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${st_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>-lc</string>
		<string>${_xml_st_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>21600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_st_home}/.aidevops/.agent-workspace/logs/screen-time-snapshot.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_st_home}/.aidevops/.agent-workspace/logs/screen-time-snapshot.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_st_home}</string>
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
ST_PLIST
		)

		if _launchd_install_if_changed "$st_label" "$st_plist" "$st_plist_content"; then
			print_info "Screen time snapshot enabled (launchd, every 6h, survives reboot)"
		else
			print_warning "Failed to load screen time snapshot LaunchAgent"
		fi
	else
		# Linux: systemd timer (every 6h) or cron fallback
		_install_scheduler_linux \
			"$st_systemd" \
			"aidevops: screen-time-snapshot" \
			"0 */6 * * *" \
			"$(_core_routine_logged_command "r909" "\"${st_script}\" snapshot")" \
			"21600" \
			"$st_log" \
			"" \
			"Screen time snapshot enabled (every 6h)" \
			"Failed to install screen time snapshot scheduler" \
			"true" \
			"true"
	fi
	return 0
}
