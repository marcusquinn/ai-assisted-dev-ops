#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# routine-helper.sh - Plan and install scheduled non-code routine runs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=setup/modules/schedulers-linux.sh
source "${SCRIPT_DIR}/setup/modules/schedulers-linux.sh"

readonly DEFAULT_AGENT="Build+"
readonly DEFAULT_TITLE="Scheduled routine"

print_usage() {
	cat <<'EOF'
routine-helper.sh - Plan and install scheduled headless routines

Usage:
  routine-helper.sh plan --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]
  routine-helper.sh install --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]
  routine-helper.sh install-launchd --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]
  routine-helper.sh install-cron --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]
  routine-helper.sh install-systemd --name NAME --schedule "CRON" --dir PATH --prompt "..." [options]

Subcommands:
  plan              Show what would be installed (dry run)
  install           Auto-detect scheduler (launchd/systemd/cron) and install
  install-launchd   Install as macOS launchd agent
  install-cron      Install as cron entry
  install-systemd   Install as systemd user timer (Linux)

Options:
  --name NAME       Routine name (used in labels/markers)
  --schedule CRON   Cron schedule expression (five fields)
  --dir PATH        Repository working directory for the headless run
  --prompt TEXT     Command/prompt to execute (non-code ops should NOT use /full-loop)
  --agent NAME      Agent name (default: Build+)
  --title TEXT      Session title (default: Scheduled routine)
  --model MODEL     Optional explicit model (default: runtime default)

Examples:
  routine-helper.sh plan --name seo-weekly --schedule "0 9 * * 1" \
    --dir ~/Git/aidev-ops-client-seo-reports --agent SEO \
    --title "Weekly rankings" --prompt "/seo-export --account client-a --format summary"

  routine-helper.sh install-cron --name seo-weekly --schedule "0 9 * * 1" \
    --dir ~/Git/aidev-ops-client-seo-reports --agent SEO \
    --title "Weekly rankings" --prompt "/seo-export --account client-a --format summary"

  routine-helper.sh install-systemd --name seo-weekly --schedule "0 9 * * 1" \
    --dir ~/Git/aidev-ops-client-seo-reports --agent SEO \
    --title "Weekly rankings" --prompt "/seo-export --account client-a --format summary"
EOF
	return 0
}

die() {
	local message="$1"
	printf '[ERROR] %s\n' "$message" >&2
	return 1
}

validate_cron_expression() {
	local schedule="$1"
	local fields
	fields=$(printf '%s' "$schedule" | awk '{print NF}')
	if [[ "$fields" -ne 5 ]]; then
		die "Schedule must have five cron fields: '$schedule'"
		return 1
	fi
	return 0
}

validate_required() {
	local value="$1"
	local flag_name="$2"
	if [[ -z "$value" ]]; then
		die "Missing required option: $flag_name"
		return 1
	fi
	return 0
}

validate_routine_name() {
	local routine_name="$1"
	if [[ ! "$routine_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
		die "Routine name must use only letters, digits, dot, underscore, or hyphen"
		return 1
	fi
	return 0
}

require_option_value() {
	local argc_remaining="$1"
	local flag_name="$2"
	if [[ "$argc_remaining" -lt 2 ]]; then
		die "$flag_name requires a value"
		return 1
	fi
	return 0
}

validate_routine_prompt() {
	local prompt="$1"
	if [[ "$prompt" == *"/full-loop"* ]]; then
		die "Prompt must not include /full-loop for routine-helper workflows"
		return 1
	fi
	return 0
}

xml_escape() {
	local value="$1"
	value="${value//&/\&amp;}"
	value="${value//</\&lt;}"
	value="${value//>/\&gt;}"
	value="${value//\"/\&quot;}"
	value="${value//\'/\&apos;}"
	printf '%s' "$value"
	return 0
}

shell_quote() {
	local value="$1"
	printf "'%s'" "${value//\'/\'\\\'\'}"
	return 0
}

routine_prompt_file_path() {
	local routine_name="$1"
	printf '%s/.aidevops/.agent-workspace/cron/scheduler-prompts/%s.prompt\n' "$HOME" "$routine_name"
	return 0
}

write_routine_prompt_file() {
	local routine_name="$1"
	local prompt="$2"
	local prompt_file=""
	prompt_file=$(routine_prompt_file_path "$routine_name")
	mkdir -p "${prompt_file%/*}"
	chmod 700 "${prompt_file%/*}"
	printf '%s\n' "$prompt" >"$prompt_file"
	chmod 600 "$prompt_file"
	return 0
}

build_headless_command() {
	local routine_name="$1"
	local dir="$2"
	local prompt_file="$3"
	local agent="$4"
	local title="$5"
	local model="$6"
	local helper_path="${HOME}/.aidevops/agents/scripts/headless-runtime-helper.sh"

	local cmd
	cmd="$(shell_quote "$helper_path") run --role worker --session-key $(shell_quote "routine-${routine_name}") --dir $(shell_quote "$dir")"
	if [[ -n "$agent" ]]; then
		cmd+=" --agent $(shell_quote "$agent")"
	fi
	if [[ -n "$title" ]]; then
		cmd+=" --title $(shell_quote "$title")"
	fi
	if [[ -n "$model" ]]; then
		cmd+=" --model $(shell_quote "$model")"
	fi
	cmd+=" --prompt-file $(shell_quote "$prompt_file")"

	printf '%s\n' "$cmd"
	return 0
}

parse_cron_to_launchd_xml() {
	local schedule="$1"
	local minute=""
	local hour=""
	local day_of_month=""
	local month=""
	local weekday=""

	read -r minute hour day_of_month month weekday <<<"$schedule"

	local -a fields=("$minute" "$hour" "$day_of_month" "$month" "$weekday")
	local value
	for value in "${fields[@]}"; do
		if [[ "$value" != "*" && ! "$value" =~ ^[0-9]+$ ]]; then
			die "launchd install supports only '*' or numeric cron fields"
			return 1
		fi
	done

	printf '  <key>StartCalendarInterval</key>\n'
	printf '  <array>\n'
	printf '    <dict>\n'
	if [[ "$minute" != "*" ]]; then
		printf '      <key>Minute</key>\n'
		printf '      <integer>%s</integer>\n' "$minute"
	fi
	if [[ "$hour" != "*" ]]; then
		printf '      <key>Hour</key>\n'
		printf '      <integer>%s</integer>\n' "$hour"
	fi
	if [[ "$day_of_month" != "*" ]]; then
		printf '      <key>Day</key>\n'
		printf '      <integer>%s</integer>\n' "$day_of_month"
	fi
	if [[ "$month" != "*" ]]; then
		printf '      <key>Month</key>\n'
		printf '      <integer>%s</integer>\n' "$month"
	fi
	if [[ "$weekday" != "*" ]]; then
		# cron weekday: 0-7 (Sun), launchd: 0-7 (Sun)
		printf '      <key>Weekday</key>\n'
		printf '      <integer>%s</integer>\n' "$weekday"
	fi
	printf '    </dict>\n'
	printf '  </array>\n'
	return 0
}

parse_cron_to_oncalendar() {
	local schedule="$1"
	local schedule_helper="${SCRIPT_DIR}/routine-schedule-helper.sh"
	"$schedule_helper" systemd-calendar "$schedule"
	return $?
}

parse_common_args() {
	ROUTINE_NAME=""
	ROUTINE_SCHEDULE=""
	ROUTINE_DIR=""
	ROUTINE_PROMPT=""
	ROUTINE_AGENT="$DEFAULT_AGENT"
	ROUTINE_TITLE="$DEFAULT_TITLE"
	ROUTINE_MODEL=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			require_option_value "$#" "$1" || return 1
			ROUTINE_NAME="$2"
			shift 2
			;;
		--schedule)
			require_option_value "$#" "$1" || return 1
			ROUTINE_SCHEDULE="$2"
			shift 2
			;;
		--dir)
			require_option_value "$#" "$1" || return 1
			ROUTINE_DIR="$2"
			shift 2
			;;
		--prompt)
			require_option_value "$#" "$1" || return 1
			ROUTINE_PROMPT="$2"
			shift 2
			;;
		--agent)
			require_option_value "$#" "$1" || return 1
			ROUTINE_AGENT="$2"
			shift 2
			;;
		--title)
			require_option_value "$#" "$1" || return 1
			ROUTINE_TITLE="$2"
			shift 2
			;;
		--model)
			require_option_value "$#" "$1" || return 1
			ROUTINE_MODEL="$2"
			shift 2
			;;
		--help | -h)
			print_usage
			return 2
			;;
		*)
			die "Unknown option: $1"
			return 1
			;;
		esac
	done

	validate_required "$ROUTINE_NAME" "--name" || return 1
	validate_required "$ROUTINE_SCHEDULE" "--schedule" || return 1
	validate_required "$ROUTINE_DIR" "--dir" || return 1
	validate_required "$ROUTINE_PROMPT" "--prompt" || return 1
	validate_routine_name "$ROUTINE_NAME" || return 1
	validate_cron_expression "$ROUTINE_SCHEDULE" || return 1
	validate_routine_prompt "$ROUTINE_PROMPT" || return 1

	return 0
}

cmd_plan() {
	parse_common_args "$@" || {
		local rc=$?
		[[ $rc -eq 2 ]] && return 0
		return 1
	}

	local command
	command=$(build_headless_command "$ROUTINE_NAME" "$ROUTINE_DIR" "$(routine_prompt_file_path "$ROUTINE_NAME")" "$ROUTINE_AGENT" "$ROUTINE_TITLE" "$ROUTINE_MODEL")

	local launchd_schedule_xml=""
	launchd_schedule_xml=$(parse_cron_to_launchd_xml "$ROUTINE_SCHEDULE" 2>/dev/null || true)

	printf 'Routine Name: %s\n' "$ROUTINE_NAME"
	printf 'Schedule: %s\n' "$ROUTINE_SCHEDULE"
	printf 'Command: %s\n\n' "$command"

	printf 'Cron entry:\n'
	printf "%s %s >> \$HOME/.aidevops/logs/routine-%s.log 2>&1 # aidevops: routine-%s\n\n" \
		"$ROUTINE_SCHEDULE" "$command" "$ROUTINE_NAME" "$ROUTINE_NAME"

	printf 'launchd label: sh.aidevops.routine-%s\n' "$ROUTINE_NAME"
	printf 'launchd plist: ~/Library/LaunchAgents/sh.aidevops.routine-%s.plist\n' "$ROUTINE_NAME"
	if [[ -n "$launchd_schedule_xml" ]]; then
		printf 'launchd schedule conversion: supported\n'
	else
		printf 'launchd schedule conversion: unsupported (use cron for this expression)\n'
	fi
	return 0
}

cmd_install_cron() {
	parse_common_args "$@" || {
		local rc=$?
		[[ $rc -eq 2 ]] && return 0
		return 1
	}

	local command
	command=$(build_headless_command "$ROUTINE_NAME" "$ROUTINE_DIR" "$(routine_prompt_file_path "$ROUTINE_NAME")" "$ROUTINE_AGENT" "$ROUTINE_TITLE" "$ROUTINE_MODEL")

	mkdir -p "$HOME/.aidevops/logs"
	local marker="# aidevops: routine-${ROUTINE_NAME}"
	local entry
	entry="$ROUTINE_SCHEDULE $command >> $HOME/.aidevops/logs/routine-${ROUTINE_NAME}.log 2>&1 $marker"

	local current
	current=$(crontab -l 2>/dev/null || true)
	if printf '%s\n' "$current" | grep -Fq "$marker"; then
		die "Cron entry already exists for routine '${ROUTINE_NAME}'"
		return 1
	fi
	write_routine_prompt_file "$ROUTINE_NAME" "$ROUTINE_PROMPT"

	(
		printf '%s\n' "$current"
		printf '%s\n' "$entry"
	) | crontab -
	printf '[OK] Installed cron routine: %s\n' "$ROUTINE_NAME"
	return 0
}

cmd_install_launchd() {
	parse_common_args "$@" || {
		local rc=$?
		[[ $rc -eq 2 ]] && return 0
		return 1
	}

	local command
	command=$(build_headless_command "$ROUTINE_NAME" "$ROUTINE_DIR" "$(routine_prompt_file_path "$ROUTINE_NAME")" "$ROUTINE_AGENT" "$ROUTINE_TITLE" "$ROUTINE_MODEL")

	local launchd_schedule_xml
	launchd_schedule_xml=$(parse_cron_to_launchd_xml "$ROUTINE_SCHEDULE") || return 1
	write_routine_prompt_file "$ROUTINE_NAME" "$ROUTINE_PROMPT"
	# launchd_schedule_xml is generated from validated numeric/* cron tokens only
	# and emits fixed XML tags, so this block is already XML-safe.

	local label_escaped
	label_escaped=$(xml_escape "sh.aidevops.routine-${ROUTINE_NAME}")
	local command_escaped
	command_escaped=$(xml_escape "$command")
	local home_escaped
	home_escaped=$(xml_escape "$HOME")
	local env_path_escaped
	env_path_escaped=$(xml_escape "$(aidevops_launchd_sanitized_path "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}")")
	local log_path_escaped
	log_path_escaped=$(xml_escape "${HOME}/.aidevops/logs/routine-${ROUTINE_NAME}.log")

	local plist_dir="$HOME/Library/LaunchAgents"
	local plist_name="sh.aidevops.routine-${ROUTINE_NAME}.plist"
	local plist_path="$plist_dir/$plist_name"

	mkdir -p "$plist_dir" "$HOME/.aidevops/logs"

	cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label_escaped}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${command_escaped}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${home_escaped}</string>
    <key>PATH</key>
    <string>${env_path_escaped}</string>
  </dict>
${launchd_schedule_xml}
  <key>StandardOutPath</key>
  <string>${log_path_escaped}</string>
  <key>StandardErrorPath</key>
  <string>${log_path_escaped}</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF

	printf '[OK] Wrote launchd plist: %s\n' "$plist_path"
	printf '[INFO] launchd schedule mapped from cron: %s\n' "$ROUTINE_SCHEDULE"
	# shell-portability: ignore next — launchctl is in a string (printf format), not a command
	printf '[INFO] Then load with: launchctl load %s\n' "$plist_path"
	return 0
}

cmd_install_systemd() {
	parse_common_args "$@" || {
		local rc=$?
		[[ $rc -eq 2 ]] && return 0
		return 1
	}

	local command
	command=$(build_headless_command "$ROUTINE_NAME" "$ROUTINE_DIR" "$(routine_prompt_file_path "$ROUTINE_NAME")" "$ROUTINE_AGENT" "$ROUTINE_TITLE" "$ROUTINE_MODEL")

	local on_calendar
	on_calendar=$(parse_cron_to_oncalendar "$ROUTINE_SCHEDULE") || return 1
	write_routine_prompt_file "$ROUTINE_NAME" "$ROUTINE_PROMPT"

	local service_name="sh.aidevops.routine-${ROUTINE_NAME}"
	local service_dir="$HOME/.config/systemd/user"
	local service_file="${service_dir}/${service_name}.service"
	local timer_file="${service_dir}/${service_name}.timer"
	local log_file="$HOME/.aidevops/logs/routine-${ROUTINE_NAME}.log"

	mkdir -p "$service_dir" "$HOME/.aidevops/logs"

	cat >"$service_file" <<EOF
[Unit]
Description=aidevops routine ${ROUTINE_NAME}
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc $(_systemd_escape "$command")
Environment=HOME=${HOME}
Environment=PATH=${PATH}
StandardOutput=append:${log_file}
StandardError=append:${log_file}
EOF

	cat >"$timer_file" <<EOF
[Unit]
Description=aidevops routine ${ROUTINE_NAME} Timer

[Timer]
OnCalendar=${on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

	systemctl --user daemon-reload 2>/dev/null || true
	if systemctl --user enable --now "${service_name}.timer" 2>/dev/null; then
		printf '[OK] Installed systemd timer: %s\n' "$service_name"
		printf '[INFO] OnCalendar=%s (from cron: %s)\n' "$on_calendar" "$ROUTINE_SCHEDULE"
	else
		printf '[OK] Wrote systemd units: %s\n' "$service_file"
		printf '[INFO] OnCalendar=%s (from cron: %s)\n' "$on_calendar" "$ROUTINE_SCHEDULE"
		printf '[INFO] Enable with: systemctl --user enable --now %s.timer\n' "$service_name"
	fi
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	plan)
		cmd_plan "$@"
		return $?
		;;
	install-cron)
		cmd_install_cron "$@"
		return $?
		;;
	install-launchd)
		cmd_install_launchd "$@"
		return $?
		;;
	install-systemd)
		cmd_install_systemd "$@"
		return $?
		;;
	install)
		# shellcheck source=platform-detect.sh
		# shellcheck disable=SC1091
		source "${SCRIPT_DIR}/platform-detect.sh" 2>/dev/null || true
		case "${AIDEVOPS_SCHEDULER:-cron}" in
		launchd) cmd_install_launchd "$@" ;;
		systemd) cmd_install_systemd "$@" ;;
		*) cmd_install_cron "$@" ;;
		esac
		return $?
		;;
	help | --help | -h)
		print_usage
		return 0
		;;
	*)
		die "Unknown command: $command"
		print_usage
		return 1
		;;
	esac
}

main "$@"
