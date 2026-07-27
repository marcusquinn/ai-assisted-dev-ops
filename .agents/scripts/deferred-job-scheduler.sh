#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# One scheduler owner for deferred-job due checks.

if [[ -n "${_AIDEVOPS_DEFERRED_JOB_SCHEDULER_LOADED:-}" ]]; then
	return 0
fi
_AIDEVOPS_DEFERRED_JOB_SCHEDULER_LOADED=1

_DJ_SCHEDULER_LABEL="sh.aidevops.deferred-jobs"
_DJ_SYSTEMD_NAME="aidevops-deferred-jobs"
_DJ_CRON_MARKER="aidevops: deferred-jobs"

_dj_scheduler_helper_path() {
	local deployed_helper="${HOME}/.aidevops/agents/scripts/deferred-job-helper.sh"
	local helper_path="${AIDEVOPS_DEFERRED_HELPER_PATH:-$deployed_helper}"
	if [[ ! -f "$helper_path" ]]; then
		helper_path="${SCRIPT_DIR}/deferred-job-helper.sh"
	fi
	printf '%s\n' "$helper_path"
	return 0
}

_dj_xml_escape() {
	local value="$1"
	value="${value//&/\&amp;}"
	value="${value//</\&lt;}"
	value="${value//>/\&gt;}"
	value="${value//\"/\&quot;}"
	value="${value//\'/\&apos;}"
	printf '%s' "$value"
	return 0
}

_dj_shell_quote() {
	local value="$1"
	printf "'%s'" "${value//\'/\'\\\'\'}"
	return 0
}

_dj_systemd_quote() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//%/%%}"
	printf '"%s"' "$value"
	return 0
}

_dj_render_launchd() {
	local helper_path=""
	local bash_path="${AIDEVOPS_DEFERRED_BASH_PATH:-/bin/bash}"
	local log_path="${_DJ_LOGS_DIR}/scheduler.log"
	local safe_path="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
	helper_path=$(_dj_scheduler_helper_path)
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_DJ_SCHEDULER_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(_dj_xml_escape "$bash_path")</string>
    <string>$(_dj_xml_escape "$helper_path")</string>
    <string>run-due</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$(_dj_xml_escape "$HOME")</string>
    <key>PATH</key>
    <string>${safe_path}</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$(_dj_xml_escape "$log_path")</string>
  <key>StandardErrorPath</key>
  <string>$(_dj_xml_escape "$log_path")</string>
</dict>
</plist>
EOF
	return 0
}

_dj_render_systemd_service() {
	local helper_path=""
	local log_path="${_DJ_LOGS_DIR}/scheduler.log"
	helper_path=$(_dj_scheduler_helper_path)
	cat <<EOF
[Unit]
Description=aidevops deferred job runner
After=network.target

[Service]
Type=oneshot
# Intentional exception: manual dispatch can hand a worker off beyond run-due.
# Killing this cgroup when the scheduler exits would terminate that worker.
KillMode=process
ExecStart=$(_dj_systemd_quote "/bin/bash") $(_dj_systemd_quote "$helper_path") run-due
TimeoutStartSec=infinity
Environment=HOME=$(_dj_systemd_quote "$HOME")
Environment=PATH=$(_dj_systemd_quote "$PATH")
StandardOutput=append:${log_path}
StandardError=append:${log_path}
EOF
	return 0
}

_dj_render_systemd_timer() {
	cat <<EOF
[Unit]
Description=aidevops deferred job runner timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Persistent=true

[Install]
WantedBy=timers.target
EOF
	return 0
}

_dj_render_cron() {
	local helper_path=""
	local log_path="${_DJ_LOGS_DIR}/scheduler.log"
	helper_path=$(_dj_scheduler_helper_path)
	printf '* * * * * /bin/bash %s run-due >> %s 2>&1 # %s\n' \
		"$(_dj_shell_quote "$helper_path")" "$(_dj_shell_quote "$log_path")" "$_DJ_CRON_MARKER"
	return 0
}

cmd_render_scheduler() {
	local backend="${1:-all}"
	case "$backend" in
	launchd)
		_dj_render_launchd
		;;
	systemd)
		printf '%s\n' '# aidevops-deferred-jobs.service'
		_dj_render_systemd_service
		printf '%s\n' '# aidevops-deferred-jobs.timer'
		_dj_render_systemd_timer
		;;
	cron)
		_dj_render_cron
		;;
	all)
		printf '%s\n' '# launchd'
		_dj_render_launchd
		printf '%s\n' '# systemd'
		_dj_render_systemd_service
		_dj_render_systemd_timer
		printf '%s\n' '# cron'
		_dj_render_cron
		;;
	*)
		printf 'ERROR: scheduler backend must be launchd, systemd, cron, or all\n' >&2
		return 2
		;;
	esac
	return 0
}

_dj_remove_cron_entry() {
	local current=""
	local filtered=""
	command -v crontab >/dev/null 2>&1 || return 0
	current=$(crontab -l 2>/dev/null || true)
	filtered=$(printf '%s\n' "$current" | grep -vF "$_DJ_CRON_MARKER" || true)
	if [[ "$filtered" != "$current" ]]; then
		printf '%s\n' "$filtered" | crontab -
	fi
	return 0
}

_dj_install_launchd() {
	local plist_dir="${HOME}/Library/LaunchAgents"
	local plist_file="${plist_dir}/${_DJ_SCHEDULER_LABEL}.plist"
	local domain=""
	domain="gui/$(id -u)"
	mkdir -p "$plist_dir"
	_dj_render_launchd >"$plist_file"
	chmod 600 "$plist_file"
	_dj_remove_cron_entry || true
	if command -v launchctl >/dev/null 2>&1; then
		launchctl bootout "${domain}/${_DJ_SCHEDULER_LABEL}" 2>/dev/null || true
		if ! launchctl bootstrap "$domain" "$plist_file" 2>/dev/null; then
			launchctl unload "$plist_file" 2>/dev/null || true
			launchctl load "$plist_file" 2>/dev/null || return 1
		fi
	fi
	printf 'Installed deferred-job scheduler: launchd\n'
	return 0
}

_dj_systemd_available() {
	command -v systemctl >/dev/null 2>&1 || return 1
	systemctl --user status >/dev/null 2>&1 || return 1
	return 0
}

_dj_install_systemd() {
	local unit_dir="${HOME}/.config/systemd/user"
	local service_file="${unit_dir}/${_DJ_SYSTEMD_NAME}.service"
	local timer_file="${unit_dir}/${_DJ_SYSTEMD_NAME}.timer"
	mkdir -p "$unit_dir"
	_dj_render_systemd_service >"$service_file"
	_dj_render_systemd_timer >"$timer_file"
	chmod 600 "$service_file" "$timer_file"
	systemctl --user daemon-reload >/dev/null 2>&1 || true
	if ! systemctl --user enable --now "${_DJ_SYSTEMD_NAME}.timer" >/dev/null 2>&1; then
		return 1
	fi
	_dj_remove_cron_entry || true
	printf 'Installed deferred-job scheduler: systemd\n'
	return 0
}

_dj_install_cron() {
	local current=""
	local entry=""
	command -v crontab >/dev/null 2>&1 || {
		printf 'ERROR: no supported scheduler backend found\n' >&2
		return 1
	}
	current=$(crontab -l 2>/dev/null || true)
	current=$(printf '%s\n' "$current" | grep -vF "$_DJ_CRON_MARKER" || true)
	entry=$(_dj_render_cron)
	{
		printf '%s\n' "$current"
		printf '%s\n' "$entry"
	} | crontab -
	printf 'Installed deferred-job scheduler: cron\n'
	return 0
}

cmd_install_scheduler() {
	local backend="${AIDEVOPS_DEFERRED_SCHEDULER_BACKEND:-auto}"
	_dj_init_storage || return 1
	if [[ "$backend" == "auto" ]]; then
		if [[ "$(uname -s)" == "Darwin" ]]; then
			backend="launchd"
		elif _dj_systemd_available; then
			backend="systemd"
		else
			backend="cron"
		fi
	fi
	case "$backend" in
	launchd) _dj_install_launchd ;;
	systemd) _dj_install_systemd || _dj_install_cron ;;
	cron) _dj_install_cron ;;
	*)
		printf 'ERROR: unsupported deferred scheduler backend: %s\n' "$backend" >&2
		return 2
		;;
	esac
	return $?
}

_dj_uninstall_launchd() {
	local plist_file="${HOME}/Library/LaunchAgents/${_DJ_SCHEDULER_LABEL}.plist"
	local domain=""
	domain="gui/$(id -u)"
	if command -v launchctl >/dev/null 2>&1; then
		launchctl bootout "${domain}/${_DJ_SCHEDULER_LABEL}" 2>/dev/null || true
		launchctl unload "$plist_file" 2>/dev/null || true
	fi
	rm -f "$plist_file"
	return 0
}

_dj_uninstall_systemd() {
	local unit_dir="${HOME}/.config/systemd/user"
	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user disable --now "${_DJ_SYSTEMD_NAME}.timer" >/dev/null 2>&1 || true
	fi
	rm -f "${unit_dir}/${_DJ_SYSTEMD_NAME}.service" "${unit_dir}/${_DJ_SYSTEMD_NAME}.timer"
	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user daemon-reload >/dev/null 2>&1 || true
	fi
	return 0
}

_dj_purge_storage() {
	local marker_value=""
	case "$DEFERRED_JOB_ROOT" in
	"" | "/" | "$HOME" | "${HOME}/.aidevops" | "${HOME}/.aidevops/.agent-workspace")
		printf 'ERROR: refusing unsafe deferred-job purge path\n' >&2
		return 1
		;;
	esac
	[[ -d "$DEFERRED_JOB_ROOT" ]] || return 0
	if [[ -L "$DEFERRED_JOB_ROOT" || -L "$_DJ_OWNER_MARKER" || ! -f "$_DJ_OWNER_MARKER" ]]; then
		printf 'ERROR: refusing to purge unowned deferred-job state root\n' >&2
		return 1
	fi
	IFS= read -r marker_value <"$_DJ_OWNER_MARKER" || marker_value=""
	if [[ "$marker_value" != "$_DJ_OWNER_MARKER_VALUE" ]]; then
		printf 'ERROR: refusing to purge deferred-job state with an unknown ownership marker\n' >&2
		return 1
	fi
	_dj_acquire_lock || return 1
	if ! rm -rf "$_DJ_JOBS_DIR" "$_DJ_PROMPTS_DIR" "$_DJ_LOGS_DIR"; then
		_dj_release_lock
		return 1
	fi
	_dj_release_lock
	rm -f "$_DJ_OWNER_MARKER" || return 1
	# Preserve an overridden root when it contains files not owned by aidevops.
	rmdir "$DEFERRED_JOB_ROOT" 2>/dev/null || true
	return 0
}

cmd_uninstall_scheduler() {
	local purge="false"
	local arg="${1:-}"
	if [[ $# -gt 1 ]]; then
		printf 'ERROR: uninstall accepts only --purge\n' >&2
		return 2
	fi
	if [[ -n "$arg" && "$arg" != "--purge" ]]; then
		printf 'ERROR: uninstall accepts only --purge\n' >&2
		return 2
	fi
	[[ "$arg" != "--purge" ]] || purge="true"
	_dj_uninstall_launchd
	_dj_uninstall_systemd
	_dj_remove_cron_entry
	if [[ "$purge" == "true" ]]; then
		_dj_purge_storage || return 1
		printf 'Uninstalled deferred-job scheduler and purged private state\n'
	else
		printf 'Uninstalled deferred-job scheduler; queued state preserved\n'
	fi
	return 0
}
