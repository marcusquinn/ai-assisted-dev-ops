#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Schedulers Platform Sub-Library -- Platform scheduler setup for contribution
# watch, complexity scan, pulse merge routine, profile README, OAuth token
# refresh, OpenCode DB maintenance, repo sync, repo health, and peer
# productivity monitor.
# =============================================================================
# This sub-library is sourced by .agents/scripts/setup/modules/schedulers.sh (the orchestrator).
# It covers:
#   - Contribution watch (t1554): passive monitoring of external issues/PRs
#   - Complexity scan (t2903): decoupled weekly complexity scan
#   - Pulse merge routine (t2862, GH#20919): fast 120s merge pass
#   - Draft responses (t1555): private repo + local draft storage
#   - Profile README: auto-create and scheduled update
#   - OAuth token refresh: launchd/systemd/cron/schtasks
#   - OpenCode DB archive (GH#25136): daily archive/VACUUM scheduler
#   - OpenCode DB maintenance (r913, t2183): weekly checkpoint/vacuum
#   - Repo sync: daily fast-forward pull
#   - Repo aidevops health (r914): daily drift keeper
#   - Peer productivity monitor (t2932): adaptive cross-runner coordination
#
# Usage: source "${SCRIPT_DIR}/schedulers-platform.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, print_warning, print_error)
#   - schedulers-linux.sh (_install_scheduler_linux, _uninstall_scheduler)
#   - schedulers-pulse.sh (_resolve_modern_bash)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SCHEDULERS_PLATFORM_LIB_LOADED:-}" ]] && return 0
_SCHEDULERS_PLATFORM_LIB_LOADED=1

# SCRIPT_DIR fallback — needed when sourced from test harnesses that don't set it.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_sched_platform_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_sched_platform_lib_path" == "${BASH_SOURCE[0]}" ]] && _sched_platform_lib_path="."
	SCRIPT_DIR="$(cd "$_sched_platform_lib_path" && pwd)"
	unset _sched_platform_lib_path
fi

# --- Functions ---

# Resolve and validate the log directory from config for contribution watch.
# Delegates resolution to _resolve_log_dir (shared-constants.sh), then applies
# install-time character validation (safe for shell paths and cron lines).
# Prints the resolved absolute path. Returns 1 on invalid characters.
_resolve_cw_log_dir() {
	local _cw_log_dir
	_cw_log_dir=$(_resolve_log_dir)
	# Whitelist: only allow characters safe in shell paths and cron lines.
	# Reject anything outside [A-Za-z0-9_./ -] (tilde already expanded by _resolve_log_dir).
	# Store regex in variable — bash [[ =~ ]] requires unquoted RHS for regex,
	# and a variable avoids quoting issues with special chars in the pattern.
	local _cw_log_dir_re='^[A-Za-z0-9_./ -]+$'
	if ! [[ "$_cw_log_dir" =~ $_cw_log_dir_re ]]; then
		# Redirect to stderr so $() captures only the path result
		print_error "Invalid characters in paths.log_dir (only [A-Za-z0-9_./ -] allowed): $_cw_log_dir" >&2
		return 1
	fi
	printf '%s' "$_cw_log_dir"
	return 0
}

# Install contribution watch via launchd (macOS).
# Args: $1=label, $2=script path, $3=log dir
_install_cw_launchd() {
	local cw_label="$1"
	local cw_script="$2"
	local _cw_log_dir="$3"
	local cw_plist="$HOME/Library/LaunchAgents/${cw_label}.plist"

	local _xml_cw_script _xml_cw_home _xml_cw_log_dir
	_xml_cw_script=$(_xml_escape "$cw_script")
	_xml_cw_home=$(_xml_escape "$HOME")
	_xml_cw_log_dir=$(_xml_escape "$_cw_log_dir")

	local cw_plist_content
	cw_plist_content=$(
		cat <<CW_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${cw_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_cw_script}</string>
		<string>scan</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_cw_log_dir}/contribution-watch.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_cw_log_dir}/contribution-watch.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_cw_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
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
CW_PLIST
	)

	if _launchd_install_if_changed "$cw_label" "$cw_plist" "$cw_plist_content"; then
		print_info "Contribution watch enabled (launchd, hourly scan)"
	else
		print_warning "Failed to load contribution watch LaunchAgent"
	fi
	return 0
}

# Install contribution watch via systemd or cron (Linux).
# Args: $1=script path, $2=log dir
_install_cw_linux() {
	local cw_script="$1"
	local _cw_log_dir="$2"
	local cw_systemd="aidevops-contribution-watch"
	_install_scheduler_linux \
		"$cw_systemd" \
		"aidevops: contribution-watch" \
		"$CRON_HOURLY" \
		"\"${cw_script}\" scan" \
		"3600" \
		"${_cw_log_dir}/contribution-watch.log" \
		"" \
		"Contribution watch enabled (hourly scan)" \
		"Failed to install contribution watch scheduler" \
		"false" \
		"true"
	return 0
}

# Setup contribution watch — monitors external issues/PRs for new activity (t1554).
# Auto-seeds on first run (discovers authored/commented issues/PRs), then installs
# a launchd/systemd/cron job to scan periodically. Requires gh CLI authenticated.
# No consent needed — this is passive monitoring (read-only notifications API),
# not autonomous action. Comment bodies are never processed by LLM in automated context.
# Respects config: aidevops config set orchestration.contribution_watch false
setup_contribution_watch() {
	local cw_script="$HOME/.aidevops/agents/scripts/contribution-watch-helper.sh"
	local cw_label="sh.aidevops.contribution-watch"
	local cw_state="$HOME/.aidevops/cache/contribution-watch.json"
	if ! [[ -x "$cw_script" ]] || ! is_feature_enabled orchestration.contribution_watch 2>/dev/null || ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
		return 0
	fi

	# Resolve and validate log directory
	local _cw_log_dir
	_cw_log_dir=$(_resolve_cw_log_dir) || return 1
	mkdir -p "$HOME/.aidevops/cache" "$_cw_log_dir"

	# Auto-seed on first run (populates state file with existing contributions)
	if [[ ! -f "$cw_state" ]]; then
		print_info "Discovering external contributions for contribution watch..."
		if bash "$cw_script" seed >/dev/null 2>&1; then
			print_info "Contribution watch seeded (external issues/PRs discovered)"
		else
			print_warning "Contribution watch seed failed (non-fatal, will retry on next run)"
		fi
	fi

	# Install/update scheduled scanner
	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_cw_launchd "$cw_label" "$cw_script" "$_cw_log_dir"
	else
		_install_cw_linux "$cw_script" "$_cw_log_dir"
	fi
	return 0
}

# Install complexity scan via launchd (macOS).
# Args: $1=label, $2=script path, $3=log dir
# (t2903) Extracted from pulse dispatch preflight — independent schedule so
# the 200-470s scan never starves dispatch or downstream scanners.
_install_complexity_scan_launchd() {
	local cs_label="$1"
	local cs_script="$2"
	local _cs_log_dir="$3"
	local cs_plist="$HOME/Library/LaunchAgents/${cs_label}.plist"

	local _xml_cs_script _xml_cs_home _xml_cs_log_dir
	_xml_cs_script=$(_xml_escape "$cs_script")
	_xml_cs_home=$(_xml_escape "$HOME")
	_xml_cs_log_dir=$(_xml_escape "$_cs_log_dir")

	local cs_plist_content
	cs_plist_content=$(
		cat <<CS_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${cs_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_cs_script}</string>
		<string>run</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_cs_log_dir}/complexity-scan-runner.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_cs_log_dir}/complexity-scan-runner.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_cs_home}</string>
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
CS_PLIST
	)

	if [[ -f "$cs_plist" ]] && [[ "$(<"$cs_plist")" == "$cs_plist_content" ]] && _launchd_has_agent "$cs_label"; then
		# Best-effort hourly job already registered. Avoid forcing launchd recovery
		# during every setup run; long-running background jobs can transiently report
		# xpcproxy even while launchd will continue the scheduled interval normally.
		print_info "Complexity scan enabled (launchd, hourly run)"
	elif _launchd_install_if_changed "$cs_label" "$cs_plist" "$cs_plist_content"; then
		print_info "Complexity scan enabled (launchd, hourly run)"
	else
		print_warning "Failed to load complexity scan LaunchAgent"
	fi
	return 0
}

# Install complexity scan via systemd or cron (Linux).
# Args: $1=script path, $2=log dir
_install_complexity_scan_linux() {
	local cs_script="$1"
	local _cs_log_dir="$2"
	local cs_systemd="aidevops-complexity-scan"
	_install_scheduler_linux \
		"$cs_systemd" \
		"aidevops: complexity-scan" \
		"$CRON_HOURLY" \
		"\"${cs_script}\" run" \
		"3600" \
		"${_cs_log_dir}/complexity-scan-runner.log" \
		"" \
		"Complexity scan enabled (hourly run)" \
		"Failed to install complexity scan scheduler" \
		"true" \
		"true"
	return 0
}

# Setup complexity scan (t2903) — extracts the weekly complexity scan from
# pulse dispatch preflight into its own launchd/cron schedule. The scan was
# observed consuming 200-470s per pulse cycle (26%+ of the 1800s pulse stale
# ceiling), starving downstream scanners. Promoting it to its own schedule
# decouples it from dispatch entirely. The runner reuses run_weekly_complexity_scan
# from pulse-simplification.sh, which has internal 15-min cadence gating
# (COMPLEXITY_SCAN_INTERVAL=900) so hourly launchd ticks are always safe.
setup_complexity_scan() {
	local cs_script="$HOME/.aidevops/agents/scripts/complexity-scan-runner.sh"
	local cs_label="sh.aidevops.complexity-scan"
	if ! [[ -x "$cs_script" ]]; then
		return 0
	fi

	# Reuse contribution-watch's log-dir resolver (same logic, same config key).
	local _cs_log_dir
	_cs_log_dir=$(_resolve_cw_log_dir) || return 1
	mkdir -p "$_cs_log_dir"

	# Install/update scheduled runner
	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_complexity_scan_launchd "$cs_label" "$cs_script" "$_cs_log_dir"
	else
		_install_complexity_scan_linux "$cs_script" "$_cs_log_dir"
	fi
	return 0
}

# Install the dedicated merge-pass launchd plist (macOS).
# Uses the timeout-protected pulse-merge-routine.sh path (t3378). The older
# t21247 pulse-wrapper.sh --merge-only path had no hard ceiling; a hung merge
# pass could leave green PRs unmerged until manual intervention.
# Supersedes the t2862 sh.aidevops.pulse-merge-routine label while keeping the
# timeout-protected helper implementation:
#   - Label: com.aidevops.aidevops-supervisor-merge
#   - Script: pulse-merge-routine.sh run
#   - Interval: 60s (down from 120s) — targets <=90s PR-green-to-merged latency
#   - Log: pulse-merge.log (isolated from main pulse log)
#
# Args: $1=label $2=wrapper_script $3=log_dir
_install_pulse_merge_routine_launchd() {
	local pmr_label="$1"
	local pmr_script="$2"
	local _pmr_log_dir="$3"
	local pmr_plist="$HOME/Library/LaunchAgents/${pmr_label}.plist"

	# One-time migration: unload and remove the legacy sh.aidevops.pulse-merge-routine
	# plist (installed by t2862) to avoid running two merge passes simultaneously.
	local _legacy_pmr_label="sh.aidevops.pulse-merge-routine"
	local _legacy_pmr_plist="$HOME/Library/LaunchAgents/${_legacy_pmr_label}.plist"
	if [[ -f "$_legacy_pmr_plist" ]]; then
		launchctl unload "$_legacy_pmr_plist" 2>/dev/null || true
		rm -f "$_legacy_pmr_plist"
		print_info "Removed legacy pulse-merge-routine plist (superseded by ${pmr_label})"
	fi

	local _xml_pmr_script _xml_pmr_home _xml_pmr_log_dir _xml_bash_bin
	_xml_pmr_script=$(_xml_escape "$pmr_script")
	_xml_pmr_home=$(_xml_escape "$HOME")
	_xml_pmr_log_dir=$(_xml_escape "$_pmr_log_dir")
	_xml_bash_bin=$(_xml_escape "$(_resolve_modern_bash)")

	local pmr_plist_content
	pmr_plist_content=$(
		cat <<PMR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${pmr_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${_xml_bash_bin}</string>
		<string>${_xml_pmr_script}</string>
		<string>run</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>StandardOutPath</key>
	<string>${_xml_pmr_log_dir}/pulse-merge.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_pmr_log_dir}/pulse-merge.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_pmr_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
	<key>SoftResourceLimits</key>
	<dict>
		<key>NumberOfFiles</key>
		<integer>4096</integer>
	</dict>
</dict>
</plist>
PMR_PLIST
	)

	if _launchd_install_if_changed "$pmr_label" "$pmr_plist" "$pmr_plist_content"; then
		print_info "Pulse merge pass enabled (launchd, every 60s via pulse-merge-routine.sh)"
	else
		print_warning "Failed to load pulse merge pass LaunchAgent"
	fi
	return 0
}

# Install the dedicated merge-pass scheduler via systemd or cron (Linux).
# Uses timeout-protected pulse-merge-routine.sh (t3378).
#   - Command: pulse-merge-routine.sh run
#   - Interval: every 60s (cron * * * * *, systemd OnUnitActiveSec=60)
#   - Log: pulse-merge.log
# Args: $1=wrapper_script $2=log_dir
_install_pulse_merge_routine_linux() {
	local pmr_script="$1"
	local _pmr_log_dir="$2"
	local pmr_systemd="aidevops-pulse-merge"
	# Keep systemd above pulse-merge-routine.sh's default 600s watchdog so
	# the script reaches its own timeout/cleanup path before systemd stops it.
	local pmr_timeout_sec="660"

	# One-time migration: remove legacy systemd/cron entry for aidevops-pulse-merge-routine.
	if _systemd_user_available 2>/dev/null; then
		systemctl --user disable --now "aidevops-pulse-merge-routine.timer" 2>/dev/null || true
		rm -f "$HOME/.config/systemd/user/aidevops-pulse-merge-routine.service" 2>/dev/null || true
		rm -f "$HOME/.config/systemd/user/aidevops-pulse-merge-routine.timer" 2>/dev/null || true
		systemctl --user daemon-reload 2>/dev/null || true
	fi
	if crontab -l 2>/dev/null | grep -qF "pulse-merge-routine"; then
		crontab -l 2>/dev/null | grep -v 'aidevops: pulse-merge-routine' | crontab - 2>/dev/null || true
	fi

	_install_scheduler_linux \
		"$pmr_systemd" \
		"aidevops: pulse-merge-routine" \
		"* * * * *" \
		"\"${pmr_script}\" run" \
		"60" \
		"${_pmr_log_dir}/pulse-merge.log" \
		"" \
		"Pulse merge pass enabled (every 60s via pulse-merge-routine.sh)" \
		"Failed to install pulse merge pass scheduler" \
		"true" \
		"true" \
		"" \
		"${pmr_timeout_sec}"
	return 0
}

# Setup the dedicated merge-pass scheduler (t21247, GH#21247).
#
# Supersedes t2862/GH#20919's legacy label/120s interval. The current
# approach runs pulse-merge-routine.sh every 60s so green PRs merge
# within <=90s of CI completion regardless of dispatch-cycle length (~23 min
# average). The routine has its own hard timeout and lockdir so a hung merge
# pass cannot starve the backlog.
#
# Requires: pulse-merge-routine.sh must be installed and executable.
# The in-cycle merge pass in pulse-wrapper.sh is kept as defense-in-depth —
# it short-circuits when a merge pass ran within the last 60s.
setup_pulse_merge_routine() {
	local pmr_wrapper="$HOME/.aidevops/agents/scripts/pulse-merge-routine.sh"
	local pmr_label="com.aidevops.aidevops-supervisor-merge"
	local legacy_pmr_label="sh.aidevops.pulse-merge-routine"
	local pmr_installed=false
	local pin_scheduler_rc=0
	if ! [[ -x "$pmr_wrapper" ]]; then
		return 0
	fi
	if _launchd_has_agent "$pmr_label" || _launchd_has_agent "$legacy_pmr_label"; then
		pmr_installed=true
	elif command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "pulse-merge-routine"; then
		pmr_installed=true
	elif command -v systemctl >/dev/null 2>&1 && systemctl --user is-enabled "aidevops-pulse-merge.timer" >/dev/null 2>&1; then
		pmr_installed=true
	fi
	_pulse_runtime_pin_preserves_scheduler "$pmr_installed" || pin_scheduler_rc=$?
	if [[ "$pin_scheduler_rc" -eq 0 ]]; then
		print_info "Pulse merge scheduler preserved while its bounded runtime pin is active"
		return 0
	elif [[ "$pin_scheduler_rc" -ne 1 ]]; then
		print_error "Pulse merge scheduler refused an invalid runtime pin"
		return 1
	fi

	# Reuse contribution-watch's log-dir resolver (same logic, same config key).
	local _pmr_log_dir
	_pmr_log_dir=$(_resolve_cw_log_dir) || return 1
	mkdir -p "$_pmr_log_dir"

	# Install/update scheduled runner
	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_pulse_merge_routine_launchd "$pmr_label" "$pmr_wrapper" "$_pmr_log_dir"
	else
		_install_pulse_merge_routine_linux "$pmr_wrapper" "$_pmr_log_dir"
	fi
	return 0
}

# Setup draft responses — private repo + local draft storage for reviewing
# AI-drafted replies to external contributions (t1555).
# Respects config: aidevops config set orchestration.draft_responses false
setup_draft_responses() {
	local dr_script="$HOME/.aidevops/agents/scripts/draft-response-helper.sh"
	if [[ -x "$dr_script" ]] && is_feature_enabled orchestration.draft_responses 2>/dev/null && is_feature_enabled orchestration.contribution_watch 2>/dev/null && command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
		mkdir -p "$HOME/.aidevops/.agent-workspace/draft-responses"
		if bash "$dr_script" init >/dev/null 2>&1; then
			print_info "Draft responses ready (private repo + local drafts)"
		else
			print_warning "Draft responses repo setup failed (non-fatal, local drafts still work)"
		fi
	fi
	return 0
}

# Setup profile README — auto-create repo and seed README if not already set up.
# Requires gh CLI authenticated. Creates username/username repo, seeds README
# with stat markers, registers in repos.json with priority: "profile".
_profile_readme_ready() {
	local pr_script="$1"
	if ! [[ -x "$pr_script" ]]; then
		return 1
	fi
	if ! command -v gh &>/dev/null; then
		return 1
	fi
	if ! gh auth status &>/dev/null; then
		return 1
	fi
	return 0
}

_run_profile_readme_init() {
	local pr_script="$1"
	print_info "Checking GitHub profile README..."
	if bash "$pr_script" init; then
		print_info "Profile README ready."
	else
		print_warning "Profile README setup failed (non-fatal, skipping)"
	fi
	return 0
}

_core_routine_shell_quote() {
	local value="$1"
	local sq="'"
	printf "'%s'" "${value//$sq/$sq\\$sq$sq}"
	return 0
}

_core_routine_logged_command() {
	local routine_id="$1"
	local exec_command="$2"
	local log_helper="\$HOME/.aidevops/agents/scripts/routine-log-helper.sh"
	# shellcheck disable=SC2016 # command string is expanded by the generated scheduler shell.
	printf 'start_epoch=$(date +%%s); status=success; %s; rc=$?; end_epoch=$(date +%%s); duration=$(( ${end_epoch:-0} - ${start_epoch:-0} )); if [ "$rc" -ne 0 ]; then status=failure; fi; if [ -x "%s" ]; then "%s" update "%s" --status "$status" --duration "$duration" >/dev/null 2>&1 || true; fi; exit "$rc"' \
		"$exec_command" \
		"$log_helper" \
		"$log_helper" \
		"$routine_id"
	return 0
}

_install_profile_readme_launchd() {
	local pr_label="$1"
	local pr_script="$2"
	local pr_plist="$HOME/Library/LaunchAgents/${pr_label}.plist"
	local _xml_pr_script _xml_pr_home
	local pr_command
	pr_command=$(_core_routine_logged_command "r908" "$(_core_routine_shell_quote "$pr_script") update")
	_xml_pr_script=$(_xml_escape "$pr_command")
	_xml_pr_home=$(_xml_escape "$HOME")

	local pr_plist_content
	pr_plist_content=$(
		cat <<PR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${pr_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>-lc</string>
		<string>${_xml_pr_script}</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
	<key>StandardOutPath</key>
	<string>${_xml_pr_home}/.aidevops/.agent-workspace/logs/profile-readme-update.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_pr_home}/.aidevops/.agent-workspace/logs/profile-readme-update.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_pr_home}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
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
PR_PLIST
	)

	if [[ -f "$pr_plist" ]] && [[ "$(<"$pr_plist")" == "$pr_plist_content" ]] && _launchd_has_agent "$pr_label"; then
		# Best-effort hourly job already registered. Avoid forcing launchd recovery
		# during every setup run; on some macOS sessions launchd reports this
		# StartInterval-only job as xpcproxy while still running it on schedule.
		print_info "Profile README update enabled (launchd, hourly)"
	elif _launchd_install_if_changed "$pr_label" "$pr_plist" "$pr_plist_content"; then
		# Do not kickstart this hourly best-effort job during setup. The profile
		# README has already been initialised above, and forced kickstarts can leave
		# launchd reporting a persistent xpcproxy state even though the scheduled
		# StartInterval job is installed correctly. Treat successful load/install as
		# the setup-time verification signal and let launchd run the next interval.
		print_info "Profile README update enabled (launchd, hourly)"
	else
		print_warning "Failed to load profile README update LaunchAgent"
	fi
	return 0
}

_install_profile_readme_scheduler() {
	local pr_label="$1"
	local pr_systemd="$2"
	local pr_script="$3"
	local pr_log="$4"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_profile_readme_launchd "$pr_label" "$pr_script"
		return 0
	fi

	_install_scheduler_linux \
		"$pr_systemd" \
		"aidevops: profile-readme-update" \
		"$CRON_HOURLY" \
		"$(_core_routine_logged_command "r908" "\"${pr_script}\" update")" \
		"3600" \
		"$pr_log" \
		"" \
		"Profile README update enabled (hourly)" \
		"Failed to install profile README update scheduler" \
		"false" \
		"true"
	return 0
}

setup_profile_readme() {
	local pr_script="$HOME/.aidevops/agents/scripts/profile-readme-helper.sh"
	local pr_label="sh.aidevops.profile-readme-update"
	if ! _profile_readme_ready "$pr_script"; then
		return 0
	fi

	# Initialize profile repo if not already set up.
	# Always run init — it's idempotent and handles:
	#   - Fresh installs (no profile repo)
	#   - Missing markers (injects them into existing README)
	#   - Diverged history (repo deleted and recreated on GitHub)
	#   - Already-initialized repos (returns early with no changes)
	_run_profile_readme_init "$pr_script"

	# Profile README auto-update scheduled job.
	# Installed whenever gh CLI is available — the update script self-heals
	# (discovers/creates the profile repo on first run via _resolve_profile_repo).
	# macOS: launchd plist (hourly) | Linux: systemd timer or cron (hourly)
	local pr_systemd="aidevops-profile-readme-update"
	local pr_log="$HOME/.aidevops/.agent-workspace/logs/profile-readme-update.log"
	mkdir -p "$HOME/.aidevops/.agent-workspace/logs"

	_install_profile_readme_scheduler "$pr_label" "$pr_systemd" "$pr_script" "$pr_log"
	return 0
}

# Detect Windows Git Bash / MINGW64 / MSYS2 environment.
# WSL reports "Linux" from uname -s and uses the cron path — correct behaviour.
# Returns 0 (true) on Windows Git Bash/MINGW/MSYS/Cygwin, 1 otherwise.
_is_windows() {
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Install OAuth token refresh via Windows Task Scheduler (schtasks).
# Args: $1=tr_script (Unix path), $2=log_dir (Unix path)
# Runs every 30 minutes, matching macOS launchd and Linux cron behaviour.
# Uses bash.exe from Git for Windows to execute the shell script.
_install_token_refresh_schtasks() {
	local tr_script="$1"
	local log_dir="$2"
	local task_name="aidevops-token-refresh"

	# Resolve bash.exe — Git for Windows ships it alongside git.exe
	local bash_exe
	bash_exe=$(command -v bash.exe 2>/dev/null || command -v bash 2>/dev/null || echo "bash")

	# Convert Unix paths to Windows paths for schtasks (requires cygpath from Git Bash)
	local tr_script_win log_dir_win bash_exe_win
	if command -v cygpath &>/dev/null; then
		tr_script_win=$(cygpath -w "$tr_script")
		log_dir_win=$(cygpath -w "$log_dir")
		bash_exe_win=$(cygpath -w "$bash_exe")
	else
		# Fallback: manual conversion (replace /c/ with C:\, forward to backslash)
		tr_script_win=$(echo "$tr_script" | sed 's|^/\([a-zA-Z]\)/|\1:\\|; s|/|\\|g')
		log_dir_win=$(echo "$log_dir" | sed 's|^/\([a-zA-Z]\)/|\1:\\|; s|/|\\|g')
		bash_exe_win="bash.exe"
	fi

	# Remove existing task (idempotent — ignore error if not present)
	schtasks /Delete /TN "$task_name" /F >/dev/null 2>&1 || true

	# Create scheduled task: every 30 minutes, run at logon, run whether logged on or not
	# /SC MINUTE /MO 30 = every 30 minutes
	# /RL HIGHEST = run with highest available privileges (needed for token writes)
	# /F = force creation (overwrite if exists)
	# The action runs bash.exe with -c to chain both refresh calls
	local action_cmd
	action_cmd="\"${bash_exe_win}\" -c \"'${tr_script_win}' refresh anthropic >> '${log_dir_win}\\token-refresh.log' 2>&1; '${tr_script_win}' refresh openai >> '${log_dir_win}\\token-refresh.log' 2>&1\""

	if schtasks /Create \
		/TN "$task_name" \
		/TR "$action_cmd" \
		/SC MINUTE \
		/MO 30 \
		/RL HIGHEST \
		/F \
		>/dev/null 2>&1; then
		print_info "OAuth token refresh enabled (schtasks, every 30 min)"
		# Run immediately to refresh any expired tokens
		schtasks /Run /TN "$task_name" >/dev/null 2>&1 || true
	else
		print_warning "Failed to create token refresh scheduled task. Run manually: schtasks /Create /TN aidevops-token-refresh /TR \"bash '${tr_script_win}' refresh anthropic\" /SC MINUTE /MO 30"
	fi
	return 0
}

# Remove OAuth token refresh Windows scheduled task (uninstall path).
_uninstall_token_refresh_schtasks() {
	local task_name="aidevops-token-refresh"
	if schtasks /Query /TN "$task_name" >/dev/null 2>&1; then
		schtasks /Delete /TN "$task_name" /F >/dev/null 2>&1 || true
		print_info "OAuth token refresh disabled (schtasks task removed)"
	fi
	return 0
}

# Setup OAuth token refresh scheduled job.
# Refreshes expired/expiring tokens every 30 min so sessions never hit
# "invalid x-api-key". Also runs at load to catch tokens that expired
# while the machine was off.
# macOS: launchd plist | Linux/WSL: systemd timer or cron | Windows Git Bash: schtasks
_oauth_token_refresh_ready() {
	local tr_script="$1"
	if ! [[ -x "$tr_script" ]]; then
		return 1
	fi
	if ! [[ -f "$HOME/.aidevops/oauth-pool.json" ]]; then
		return 1
	fi
	return 0
}

_install_token_refresh_launchd() {
	local tr_label="$1"
	local tr_script="$2"
	local tr_plist="$HOME/Library/LaunchAgents/${tr_label}.plist"
	local _xml_tr_script _xml_tr_home
	_xml_tr_script=$(_xml_escape "$tr_script")
	_xml_tr_home=$(_xml_escape "$HOME")

	local tr_plist_content
	tr_plist_content=$(
		cat <<TR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${tr_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>-c</string>
		<string>&quot;${_xml_tr_script}&quot; refresh anthropic; &quot;${_xml_tr_script}&quot; refresh openai</string>
	</array>
	<key>StartInterval</key>
	<integer>1800</integer>
	<key>StandardOutPath</key>
	<string>${_xml_tr_home}/.aidevops/.agent-workspace/logs/token-refresh.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_tr_home}/.aidevops/.agent-workspace/logs/token-refresh.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_tr_home}</string>
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
TR_PLIST
	)

	if [[ -f "$tr_plist" ]] && [[ "$(<"$tr_plist")" == "$tr_plist_content" ]] && _launchd_has_agent "$tr_label"; then
		# An interval job that is already registered does not need launchd recovery
		# during every setup run. In particular, transient xpcproxy state at the
		# instant setup runs does not mean that launchd lost the schedule.
		print_info "OAuth token refresh enabled (launchd, every 30 min)"
	elif _launchd_install_if_changed "$tr_label" "$tr_plist" "$tr_plist_content"; then
		print_info "OAuth token refresh enabled (launchd, every 30 min)"
	else
		# shell-portability: ignore next -- recovery text is emitted only from the macOS installer
		print_warning "Failed to load token refresh LaunchAgent (${tr_label}); retry with: launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/${tr_label}.plist"
	fi
	return 0
}

setup_oauth_token_refresh() {
	local tr_script="$HOME/.aidevops/agents/scripts/oauth-pool-helper.sh"
	local tr_label="sh.aidevops.token-refresh"
	if ! _oauth_token_refresh_ready "$tr_script"; then
		return 0
	fi

	local tr_log_dir="$HOME/.aidevops/.agent-workspace/logs"
	mkdir -p "$tr_log_dir"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_token_refresh_launchd "$tr_label" "$tr_script"
	elif _is_windows; then
		# Windows Git Bash / MINGW64 / MSYS2: use Task Scheduler (schtasks)
		_install_token_refresh_schtasks "$tr_script" "$tr_log_dir"
	else
		# Linux / WSL without systemd: systemd timer or cron fallback
		_install_scheduler_linux \
			"aidevops-token-refresh" \
			"aidevops: token-refresh" \
			"*/30 * * * *" \
			"\"${tr_script}\" refresh anthropic; \"${tr_script}\" refresh openai" \
			"1800" \
			"${tr_log_dir}/token-refresh.log" \
			"" \
			"OAuth token refresh enabled (every 30 min)" \
			"Failed to install token refresh scheduler" \
			"true" \
			"true"
	fi
	return 0
}

# Setup opencode DB maintenance scheduler (r913, t2183).
# Runs weekly (Sun 04:00 local by default) to checkpoint/optimize/vacuum opencode.db.
# The helper self-noops on missing DB, so installing unconditionally is safe —
# a non-opencode machine wakes up weekly, sees no DB, exits 0 silently.
#
# Platform split (mirrors the pattern for token-refresh):
#   macOS    — helper owns its plist generation via cmd_install (Approach B).
#   Linux    — _install_scheduler_linux with cron `0 4 * * 0` + systemd
#              OnCalendar `Sun *-*-* 04:00:00` for accurate wall-clock firing.
#   Windows  — TODO(t2183-followup): opencode on Windows is rare and the
#              helper self-noops on missing DB, so leaving unscheduled is
#              low-risk for this iteration.
setup_opencode_db_maintenance() {
	local ocdbm_script="$HOME/.aidevops/agents/scripts/opencode-db-maintenance-helper.sh"
	if ! [[ -x "$ocdbm_script" ]]; then
		return 0
	fi

	local ocdbm_log_dir="$HOME/.aidevops/.agent-workspace/logs"
	local ocdbm_hour="${OPENCODE_DB_MAINTENANCE_HOUR:-4}"
	local ocdbm_minute="${OPENCODE_DB_MAINTENANCE_MINUTE:-0}"
	local ocdbm_mode="${OPENCODE_DB_MAINTENANCE_MODE:-auto}"
	local ocdbm_command="\"${ocdbm_script}\" auto"
	if [[ "$ocdbm_mode" == "maintenance-window" ]]; then
		ocdbm_command="\"${ocdbm_script}\" maintenance-window --force-opencode"
	fi
	mkdir -p "$ocdbm_log_dir"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		# Helper owns its own plist generation (Approach B, like repo-sync).
		# Quiet the helper's multi-line output and emit one consolidated line
		# to match the style of setup_profile_readme / setup_oauth_token_refresh.
		if OPENCODE_DB_MAINTENANCE_HOUR="$ocdbm_hour" OPENCODE_DB_MAINTENANCE_MINUTE="$ocdbm_minute" OPENCODE_DB_MAINTENANCE_MODE="$ocdbm_mode" bash "$ocdbm_script" install >/dev/null 2>&1; then
			print_info "OpenCode DB maintenance enabled (launchd, weekly Sun ${ocdbm_hour}:${ocdbm_minute})"
		else
			print_warning "Failed to install opencode DB maintenance LaunchAgent"
		fi
	elif _is_windows; then
		# Windows scheduling deferred — helper self-noops on missing DB so
		# the cost of leaving unscheduled is ~0 until opencode lands on
		# Windows in quantity.
		return 0
	else
		# Linux / WSL: prefer systemd user timer, fall back to cron.
		# Weekly Sunday local time — cron: `${minute} ${hour} * * 0`; systemd OnCalendar
		# ensures wall-clock firing even across suspends/reboots.
		_install_scheduler_linux \
			"aidevops-opencode-db-maintenance" \
			"aidevops: opencode-db-maintenance" \
			"${ocdbm_minute} ${ocdbm_hour} * * 0" \
			"${ocdbm_command}" \
			"604800" \
			"${ocdbm_log_dir}/opencode-db-maintenance.log" \
			"" \
			"OpenCode DB maintenance enabled (weekly Sun ${ocdbm_hour}:${ocdbm_minute})" \
			"Failed to install opencode DB maintenance scheduler" \
			"false" \
			"true" \
			"Sun *-*-* ${ocdbm_hour}:${ocdbm_minute}:00"
	fi
	return 0
}

# Setup opencode DB archive scheduler (GH#25136).
# Runs independently from pulse preflight so archive/VACUUM work does not track
# dispatch-loop cadence. The async helper keeps its single-runner lock and
# last-run observability while this scheduler supplies the daily cadence.
setup_opencode_db_archive() {
	local archive_home="${HOME:-}"
	if [[ -z "$archive_home" ]]; then
		print_warning "Skipping opencode DB archive scheduler: HOME is unset"
		return 0
	fi

	local archive_script="$archive_home/.aidevops/agents/scripts/opencode-db-archive-async-helper.sh"
	if ! [[ -x "$archive_script" ]]; then
		return 0
	fi

	local archive_log_dir="$archive_home/.aidevops/logs"
	local archive_hour="${OPENCODE_DB_ARCHIVE_HOUR:-5}"
	local archive_minute="${OPENCODE_DB_ARCHIVE_MINUTE:-0}"
	local archive_budget_sec="${OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC:-60}"
	local archive_env="OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC=${archive_budget_sec}"
	mkdir -p "$archive_log_dir"

	if [[ "$(uname -s)" == "Darwin" ]]; then
		local archive_label="sh.aidevops.opencode-db-archive"
		local archive_plist="$archive_home/Library/LaunchAgents/${archive_label}.plist"
		local _xml_archive_script _xml_archive_home _xml_archive_log _xml_archive_path
		_xml_archive_script=$(_xml_escape "$archive_script")
		_xml_archive_home=$(_xml_escape "$archive_home")
		_xml_archive_log=$(_xml_escape "${archive_log_dir}/opencode-db-archive.log")
		_xml_archive_path=$(_xml_escape "$(aidevops_launchd_sanitized_path "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin${PATH:+:${PATH}}")")

		local archive_plist_content
		archive_plist_content=$(cat <<ARCHIVE_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${archive_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_archive_script}</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>${archive_hour}</integer>
		<key>Minute</key>
		<integer>${archive_minute}</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>${_xml_archive_log}</string>
	<key>StandardErrorPath</key>
	<string>${_xml_archive_log}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>${_xml_archive_home}</string>
		<key>PATH</key>
		<string>${_xml_archive_path}</string>
		<key>OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC</key>
		<string>${archive_budget_sec}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
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
ARCHIVE_PLIST
		)
		if _launchd_install_if_changed "$archive_label" "$archive_plist" "$archive_plist_content"; then
			print_info "OpenCode DB archive enabled (launchd, daily ${archive_hour}:${archive_minute})"
		else
			print_warning "Failed to install opencode DB archive LaunchAgent"
		fi
	elif _is_windows; then
		return 0
	else
		_install_scheduler_linux \
			"aidevops-opencode-db-archive" \
			"aidevops: opencode-db-archive" \
			"${archive_minute} ${archive_hour} * * *" \
			"\"${archive_script}\"" \
			"86400" \
			"${archive_log_dir}/opencode-db-archive.log" \
			"${archive_env}" \
			"OpenCode DB archive enabled (daily ${archive_hour}:${archive_minute})" \
			"Failed to install opencode DB archive scheduler" \
			"false" \
			"true" \
			"*-*-* ${archive_hour}:${archive_minute}:00" \
			"3600"
	fi
	return 0
}

# Setup repo-sync scheduler if not already installed.
# Keeps local git repos up to date with daily ff-only pulls.
# Respects config: aidevops config set orchestration.repo_sync false
setup_repo_sync() {
	local repo_sync_script="$HOME/.aidevops/agents/scripts/repo-sync-helper.sh"
	if ! [[ -x "$repo_sync_script" ]] || ! is_feature_enabled repo_sync 2>/dev/null; then
		return 0
	fi

	local _repo_sync_installed=false
	if _launchd_has_agent "com.aidevops.aidevops-repo-sync"; then
		_repo_sync_installed=true
	elif _launchd_has_agent "sh.aidevops.repo-sync"; then
		_repo_sync_installed=true
	elif crontab -l 2>/dev/null | grep -qF "aidevops-repo-sync"; then
		_repo_sync_installed=true
	elif command -v systemctl >/dev/null 2>&1 &&
		systemctl --user is-enabled "aidevops-repo-sync.timer" >/dev/null 2>&1; then
		_repo_sync_installed=true
	fi
	if [[ "$_repo_sync_installed" == "false" ]]; then
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			bash "$repo_sync_script" enable >/dev/null 2>&1 || true
			print_info "Repo sync enabled (daily). Disable: aidevops repo-sync disable"
		else
			echo ""
			echo "Repo sync reports remote drift daily without modifying"
			echo "human canonical checkouts."
			echo ""
			setup_prompt enable_repo_sync "Enable daily repo sync? [Y/n]: " "Y"
			if [[ "$enable_repo_sync" =~ ^[Yy]?$ || -z "$enable_repo_sync" ]]; then
				bash "$repo_sync_script" enable
			else
				print_info "Skipped. Enable later: aidevops repo-sync enable"
			fi
		fi
	fi
	return 0
}

# Setup r914 repo-aidevops-health scheduler if not already installed.
# Daily drift keeper for repos.json: bumps stale .aidevops.json versions
# and surfaces missing-folder / no-init drift for human triage.
# Respects config: aidevops config set orchestration.repo_aidevops_health false
setup_repo_aidevops_health() {
	local repo_health_script="$HOME/.aidevops/agents/scripts/repo-aidevops-health-helper.sh"
	if ! [[ -x "$repo_health_script" ]] || ! is_feature_enabled repo_aidevops_health 2>/dev/null; then
		return 0
	fi

	local _repo_health_installed=false
	if _launchd_has_agent "sh.aidevops.repo-aidevops-health"; then
		_repo_health_installed=true
	elif crontab -l 2>/dev/null | grep -qF "aidevops-repo-aidevops-health"; then
		_repo_health_installed=true
	elif command -v systemctl >/dev/null 2>&1 &&
		systemctl --user is-enabled "aidevops-repo-aidevops-health.timer" >/dev/null 2>&1; then
		_repo_health_installed=true
	fi
	if [[ "$_repo_health_installed" == "false" ]]; then
		if [[ "$NON_INTERACTIVE" == "true" ]]; then
			bash "$repo_health_script" enable >/dev/null 2>&1 || true
			print_info "r914 repo-aidevops-health enabled (daily @03:30). Disable: aidevops repo-aidevops-health disable"
		else
			echo ""
			echo "r914 keeps \`.aidevops.json\` versions current across all registered"
			echo "repos and surfaces registry drift (missing folders, unregistered git"
			echo "repos) for human triage. Runs daily at 03:30."
			echo ""
			setup_prompt enable_repo_health "Enable daily r914 repo-aidevops-health? [Y/n]: " "Y"
			if [[ "$enable_repo_health" =~ ^[Yy]?$ || -z "$enable_repo_health" ]]; then
				bash "$repo_health_script" enable
			else
				print_info "Skipped. Enable later: aidevops repo-aidevops-health enable"
			fi
		fi
	fi
	return 0
}

# ============================================================================
# Peer productivity monitor (t2932)
# ============================================================================
#
# Adaptive cross-runner dispatch coordination: observes peer GitHub activity
# every 30 min and updates ~/.config/aidevops/dispatch-override.conf to
# `ignore` peers whose pulse is broken (claims issues but never PRs) and
# back to `honour` when they recover. Self-healing across the ecosystem —
# each runner observes peers independently, no central coordinator needed.
# Manual entries in dispatch-override.conf above the auto-managed marker
# always take precedence.

# Install peer-productivity-monitor launchd plist (macOS).
# Args: $1=label $2=script $3=log_dir
_install_peer_productivity_monitor_launchd() {
	local ppm_label="$1"
	local ppm_script="$2"
	local _ppm_log_dir="$3"
	local ppm_plist="$HOME/Library/LaunchAgents/${ppm_label}.plist"

	local _xml_ppm_script _xml_ppm_home _xml_ppm_log_dir
	_xml_ppm_script=$(_xml_escape "$ppm_script")
	_xml_ppm_home=$(_xml_escape "$HOME")
	_xml_ppm_log_dir=$(_xml_escape "$_ppm_log_dir")

	local ppm_plist_content
	ppm_plist_content=$(
		cat <<PPM_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${ppm_label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(_xml_escape "$(_resolve_modern_bash)")</string>
		<string>${_xml_ppm_script}</string>
		<string>observe</string>
	</array>
	<key>StartInterval</key>
	<integer>1800</integer>
	<key>StandardOutPath</key>
	<string>${_xml_ppm_log_dir}/peer-productivity-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${_xml_ppm_log_dir}/peer-productivity-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$(aidevops_launchd_sanitized_path)</string>
		<key>HOME</key>
		<string>${_xml_ppm_home}</string>
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
PPM_PLIST
	)

	if [[ -f "$ppm_plist" ]] && [[ "$(<"$ppm_plist")" == "$ppm_plist_content" ]] && _launchd_has_agent "$ppm_label"; then
		# Best-effort interval job already registered. Avoid forcing setup-time
		# launchd recovery for transient xpcproxy states; the monitor remains
		# scheduled and any real install/update failure is still surfaced below.
		print_info "Peer productivity monitor enabled (launchd, every 30 min)"
	elif _launchd_install_if_changed "$ppm_label" "$ppm_plist" "$ppm_plist_content"; then
		print_info "Peer productivity monitor enabled (launchd, every 30 min)"
	else
		print_warning "Failed to load peer-productivity-monitor LaunchAgent"
	fi
	return 0
}

# Install peer-productivity-monitor via systemd or cron (Linux).
# Args: $1=script path, $2=log dir
_install_peer_productivity_monitor_linux() {
	local ppm_script="$1"
	local _ppm_log_dir="$2"
	local ppm_systemd="aidevops-peer-productivity-monitor"
	_install_scheduler_linux \
		"$ppm_systemd" \
		"aidevops: peer-productivity-monitor" \
		"*/30 * * * *" \
		"\"${ppm_script}\" observe" \
		"1800" \
		"${_ppm_log_dir}/peer-productivity-launchd.log" \
		"" \
		"Peer productivity monitor enabled (every 30 min)" \
		"Failed to install peer-productivity-monitor scheduler" \
		"true" \
		"true"
	return 0
}

# Setup peer-productivity-monitor (t2932) — observes peer GitHub activity
# every 30 min and updates ~/.config/aidevops/dispatch-override.conf so the
# local pulse competes with broken peers and collaborates with healthy ones.
# Manual entries in dispatch-override.conf above the auto-managed marker
# always take precedence.
setup_peer_productivity_monitor() {
	local ppm_script="$HOME/.aidevops/agents/scripts/peer-productivity-monitor.sh"
	local ppm_label="sh.aidevops.peer-productivity-monitor"
	if ! [[ -x "$ppm_script" ]]; then
		return 0
	fi

	# Reuse contribution-watch's log-dir resolver (same logic, same config key).
	local _ppm_log_dir
	_ppm_log_dir=$(_resolve_cw_log_dir) || return 1
	mkdir -p "$_ppm_log_dir"

	# Install/update scheduled runner
	if [[ "$(uname -s)" == "Darwin" ]]; then
		_install_peer_productivity_monitor_launchd "$ppm_label" "$ppm_script" "$_ppm_log_dir"
	else
		_install_peer_productivity_monitor_linux "$ppm_script" "$_ppm_log_dir"
	fi
	return 0
}
