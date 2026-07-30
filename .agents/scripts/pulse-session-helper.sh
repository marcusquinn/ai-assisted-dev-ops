#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-session-helper.sh - Pulse consent and session control
#
# Controls the supervisor pulse via a layered consent model:
#   1. Stop flag  (~/.aidevops/logs/pulse-session.stop)  — highest priority, pauses pulse
#   2. Session flag (~/.aidevops/logs/pulse-session.flag) — explicit start, doesn't survive reboots
#   3. Config consent (orchestration.supervisor_pulse=true) — persistent, survives reboots
#
# Usage:
#   pulse-session-helper.sh start    # Clear stop flag, create session flag
#   pulse-session-helper.sh stop     # Create stop flag, remove session flag, wait for workers
#   pulse-session-helper.sh status   # Show consent layers, workers, repos
#   pulse-session-helper.sh help     # Show usage
#
# The scheduler (launchd on macOS, cron on Linux) stays loaded —
# pulse-wrapper.sh checks these consent layers on each cycle and skips
# if none grant permission.

set -euo pipefail

_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

# Source config-helper for _jsonc_get (shared JSONC config reader)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true

# Configuration
readonly SESSION_FLAG="${HOME}/.aidevops/logs/pulse-session.flag"
readonly STOP_FLAG="${HOME}/.aidevops/logs/pulse-session.stop"
readonly LOGFILE="${HOME}/.aidevops/logs/pulse.log"
readonly WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
readonly WRAPPER_LAST_RUN_FILE="${HOME}/.aidevops/logs/pulse-wrapper-last-run.ts"
readonly PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
readonly MAX_WORKERS_FILE="${HOME}/.aidevops/logs/pulse-max-workers"
readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"
readonly STOP_GRACE_PERIOD="${PULSE_STOP_GRACE_SECONDS:-300}" # 5 min default

# Colors — shared-constants.sh (via config-helper.sh) may have already set these
# as readonly. Only define if not already present to avoid readonly collisions.
[[ -z "${GREEN+x}" ]] && readonly GREEN='\033[0;32m'
[[ -z "${BLUE+x}" ]] && readonly BLUE='\033[0;34m'
[[ -z "${YELLOW+x}" ]] && readonly YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && readonly RED='\033[0;31m'
[[ -z "${BOLD+x}" ]] && readonly BOLD='\033[1m'
[[ -z "${NC+x}" ]] && readonly NC='\033[0m'

# Ensure log directory exists
mkdir -p "$(dirname "$SESSION_FLAG")"

#######################################
# Print helpers
#######################################
print_info() {
	echo -e "${BLUE}[INFO]${NC} $1"
	return 0
}
print_success() {
	echo -e "${GREEN}[OK]${NC} $1"
	return 0
}
print_warning() {
	echo -e "${YELLOW}[WARN]${NC} $1"
	return 0
}
print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
	return 0
}

#######################################
# Check if pulse session is active
# Returns: 0 if active, 1 if not
#######################################
is_session_active() {
	if [[ -f "$SESSION_FLAG" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Count active worker processes
# Returns: count via stdout
#######################################
count_workers() {
	local count
	count=$(ps axwwo command | grep '[/]full-loop' | grep -c '\.opencode') || count=0
	echo "$count"
	return 0
}

#######################################
# Check if a pulse process is currently running
# Handles SETUP:/IDLE: sentinels from pulse-wrapper.sh (GH#4575)
# Returns: 0 if running, 1 if not
#######################################
is_pulse_running() {
	if [[ -f "$PIDFILE" ]]; then
		local pid_content
		pid_content=$(cat "$PIDFILE" || echo "")

		# IDLE sentinel or empty — not running
		if [[ -z "$pid_content" ]] || [[ "$pid_content" == IDLE:* ]]; then
			return 1
		fi

		# SETUP sentinel — extract numeric PID
		local pid="$pid_content"
		if [[ "$pid_content" == SETUP:* ]]; then
			pid="${pid_content#SETUP:}"
		fi

		# Validate numeric and check process
		if [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" >/dev/null 2>&1; then
			return 0
		fi
	fi
	return 1
}

#######################################
# Check if config consent is enabled
# Delegates to config_enabled from config-helper.sh (sourced above),
# which handles: env var override (AIDEVOPS_SUPERVISOR_PULSE) >
# user JSONC config > defaults JSONC config. Single canonical
# implementation shared with pulse-wrapper.sh via shared-constants.sh.
# Returns: 0 if enabled, 1 if not
#######################################
is_config_consent_enabled() {
	if type config_enabled &>/dev/null; then
		config_enabled "orchestration.supervisor_pulse"
		return $?
	fi
	# Fallback if config-helper.sh failed to load entirely
	return 1
}

#######################################
# Get pulse-enabled repo count
#######################################
get_pulse_repo_count() {
	if [[ -f "$REPOS_JSON" ]] && command -v jq &>/dev/null; then
		jq '[.initialized_repos[] | select(.maintenance != false and .pulse == true)] | length' "$REPOS_JSON" || echo "0"
	else
		echo "?"
	fi
	return 0
}

#######################################
# Get OS-appropriate scheduler name
# Returns: "launchd" on macOS, "systemd" or "cron" on Linux
#######################################
get_scheduler_name() {
	local os_type
	os_type=$(uname -s)
	case "$os_type" in
	Darwin) echo "launchd" ;;
	*)
		# Detect systemd user services (GH#17369)
		if command -v systemctl >/dev/null 2>&1 &&
			systemctl --user status >/dev/null 2>&1; then
			echo "systemd"
		else
			echo "cron"
		fi
		;;
	esac
	return 0
}

#######################################
# Check if the pulse scheduler is installed
# On macOS: checks for launchd plist
# On Linux: checks for cron entry
# Returns: 0 if installed, 1 if not
#######################################
is_scheduler_installed() {
	local os_type
	os_type=$(uname -s)
	case "$os_type" in
	Darwin)
		# Check for launchd plist (both old and new label formats)
		if launchctl list 2>/dev/null | grep -qF "com.aidevops.aidevops-supervisor-pulse"; then
			return 0
		fi
		if launchctl list 2>/dev/null | grep -qF "com.aidevops.supervisor-pulse"; then
			return 0
		fi
		return 1
		;;
	*)
		# Check for systemd user timer first (GH#17369)
		if command -v systemctl >/dev/null 2>&1 &&
			systemctl --user is-enabled aidevops-supervisor-pulse.timer >/dev/null 2>&1; then
			return 0
		fi
		# Fall back to cron entry check
		if crontab -l 2>/dev/null | grep -qF "aidevops-supervisor-pulse"; then
			return 0
		fi
		return 1
		;;
	esac
}

#######################################
# Get the install command for the pulse scheduler
# Returns: the appropriate install command string
#######################################
get_scheduler_install_cmd() {
	local setup_script="${SCRIPT_DIR}/../../setup.sh"
	if [[ -f "$setup_script" ]]; then
		echo "$setup_script"
	else
		echo "aidevops update"
	fi
	return 0
}

#######################################
# Convert a Unix epoch to an ISO 8601 UTC timestamp on GNU and BSD date.
#######################################
_pulse_epoch_to_iso() {
	local epoch="$1"
	local iso=""

	iso=$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || true
	if [[ -z "$iso" ]]; then
		iso=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || true
	fi
	if [[ -z "$iso" ]]; then
		return 1
	fi
	printf '%s\n' "$iso"
	return 0
}

#######################################
# Get the last admitted deterministic Pulse timestamp. Fall back to the
# historical optional LLM-cycle log marker for installations that predate the
# wrapper marker file.
#######################################
get_last_pulse_time() {
	local marker_epoch=""
	local marker_iso=""
	if [[ -f "$WRAPPER_LAST_RUN_FILE" ]]; then
		IFS= read -r marker_epoch <"$WRAPPER_LAST_RUN_FILE" || true
		if [[ "$marker_epoch" =~ ^[1-9][0-9]*$ ]]; then
			marker_iso=$(_pulse_epoch_to_iso "$marker_epoch") || marker_iso=""
			if [[ -n "$marker_iso" ]]; then
				printf '%s\n' "$marker_iso"
				return 0
			fi
		fi
	fi

	local candidate_log="" last_line="" timestamp=""
	for candidate_log in "$WRAPPER_LOGFILE" "$LOGFILE"; do
		if [[ -f "$candidate_log" ]]; then
			last_line=$(grep 'Starting pulse at' "$candidate_log" | tail -1 || true)
			if [[ -n "$last_line" ]]; then
				timestamp=$(printf '%s\n' "$last_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' | tail -1 || true)
				if [[ -n "$timestamp" ]]; then
					printf '%s\n' "$timestamp"
					return 0
				fi
			fi
		fi
	done
	printf '%s\n' "never"
	return 0
}

#######################################
# Start pulse session
#######################################
cmd_start() {
	# Remove stop flag if present (user is explicitly resuming)
	rm -f "$STOP_FLAG"

	if is_session_active; then
		local started_at
		started_at=$(grep '^started_at=' "$SESSION_FLAG" | cut -d= -f2 | tr -cd '[:alnum:]T:Z.+-')
		print_warning "Pulse session already active (started: ${started_at:-unknown})"
		echo ""
		echo "  To restart: aidevops pulse stop && aidevops pulse start"
		return 0
	fi

	# Create session flag
	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local user
	user=$(whoami)

	cat >"$SESSION_FLAG" <<EOF
started_at=${now_iso}
started_by=${user}
EOF

	echo "[pulse-session] Session started at ${now_iso} by ${user}" >>"$LOGFILE"

	local repo_count
	repo_count=$(get_pulse_repo_count)
	local max_workers="?"
	if [[ -f "$MAX_WORKERS_FILE" ]]; then
		max_workers=$(cat "$MAX_WORKERS_FILE" || echo "?")
	fi

	local scheduler_name
	scheduler_name=$(get_scheduler_name)

	print_success "Pulse session started"
	echo ""
	echo "  Repos in scope: ${repo_count}"
	echo "  Max workers:    ${max_workers}"
	echo "  Pulse interval: every 2 minutes (via ${scheduler_name})"
	echo ""

	# Warn if no scheduler entry is installed (GH#5085)
	if ! is_scheduler_installed; then
		local install_cmd
		install_cmd=$(get_scheduler_install_cmd)
		print_warning "No ${scheduler_name} scheduler entry found — the pulse will not fire automatically"
		echo ""
		echo "  Install the scheduler with:"
		echo "    ${install_cmd}"
		echo ""
		echo "  Without the scheduler, the pulse only runs when manually triggered."
	else
		echo "  The pulse will run on the next ${scheduler_name} cycle."
	fi

	echo "  Stop with: aidevops pulse stop"
	return 0
}

#######################################
# Parse --force/-f flag from stop arguments
# Outputs: "true" if force, "false" otherwise
#######################################
_stop_parse_force() {
	local force=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force | -f)
			force=true
			shift
			;;
		*)
			shift
			;;
		esac
	done
	echo "$force"
	return 0
}

#######################################
# Early-exit guard for cmd_stop
# Returns: 0 to continue, 1 to exit (already stopped / not enabled)
# Args: $1 = force ("true"/"false")
#######################################
_stop_check_preconditions() {
	local force="$1"

	# Check if already stopped — but allow --force through so it can kill workers
	if [[ -f "$STOP_FLAG" ]] && ! is_session_active; then
		local worker_count_check
		worker_count_check=$(count_workers)
		if [[ "$force" != "true" ]] && [[ "$worker_count_check" -eq 0 ]] && ! is_pulse_running; then
			print_info "Pulse is already stopped"
			return 1
		fi
	fi

	# If no session flag and no config consent, nothing to stop
	if ! is_session_active && ! is_config_consent_enabled; then
		print_info "Pulse is not enabled (no session flag, no config consent)"
		return 1
	fi

	return 0
}

#######################################
# Write stop flag, remove session flag, log the event
# Outputs: started_at value (may be empty)
#######################################
_stop_write_flags() {
	local started_at=""
	if is_session_active; then
		started_at=$(grep '^started_at=' "$SESSION_FLAG" | cut -d= -f2 | tr -cd '[:alnum:]T:Z.+-')
	fi

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local user
	user=$(whoami)
	cat >"$STOP_FLAG" <<EOF
stopped_at=${now_iso}
stopped_by=${user}
EOF

	rm -f "$SESSION_FLAG"
	echo "[pulse-session] Session stopped at ${now_iso} (was started: ${started_at:-unknown})" >>"$LOGFILE"
	echo "$started_at"
	return 0
}

#######################################
# Force-kill all worker processes via SIGTERM
# Args: $1 = worker_count
#######################################
_stop_force_kill_workers() {
	local worker_count="$1"

	print_warning "Force mode: sending SIGTERM to all workers..."
	local killed=0
	while IFS= read -r line; do
		local pid
		pid=$(echo "$line" | awk '{print $1}')
		if [[ -n "$pid" ]]; then
			kill "$pid" 2>/dev/null || true
			killed=$((killed + 1))
		fi
	done < <(ps axwwo pid,command | grep '[/]full-loop' | grep '\.opencode')

	if [[ "$killed" -gt 0 ]]; then
		print_info "Sent SIGTERM to ${killed} worker(s)"
		sleep 3

		local remaining
		remaining=$(count_workers)
		if [[ "$remaining" -gt 0 ]]; then
			print_warning "${remaining} worker(s) still running after SIGTERM"
			echo "  They will finish their current operation and exit."
			echo "  Force kill with: kill -9 \$(ps axwwo pid,command | grep '[/]full-loop' | grep '\\.opencode' | awk '{print \$1}')"
		else
			print_success "All workers stopped"
		fi
	fi
	return 0
}

#######################################
# Wait gracefully for workers to finish (up to grace period)
# Args: $1 = initial worker_count
#######################################
_stop_wait_for_workers() {
	local worker_count="$1"

	echo "  Workers will complete their current PR/commit cycle."
	echo "  No new work will be dispatched."
	echo ""
	echo "  Waiting up to ${STOP_GRACE_PERIOD}s for workers to finish..."
	echo "  (Ctrl+C to stop waiting — workers will continue in background)"
	echo "  (Use --force to send SIGTERM immediately)"
	echo ""

	local elapsed=0
	local poll_interval=10
	while [[ "$elapsed" -lt "$STOP_GRACE_PERIOD" ]]; do
		worker_count=$(count_workers)
		if [[ "$worker_count" -eq 0 ]]; then
			print_success "All workers finished — clean shutdown"
			return 0
		fi
		printf "\r  %d worker(s) still running... (%ds/%ds)" "$worker_count" "$elapsed" "$STOP_GRACE_PERIOD"
		sleep "$poll_interval"
		elapsed=$((elapsed + poll_interval))
	done

	echo ""
	worker_count=$(count_workers)
	if [[ "$worker_count" -gt 0 ]]; then
		print_warning "${worker_count} worker(s) still running after grace period"
		echo "  They will continue in the background until they finish."
		echo "  No new work will be dispatched."
		echo "  Force stop: aidevops pulse stop --force"
	else
		print_success "All workers finished — clean shutdown"
	fi
	return 0
}

#######################################
# Stop pulse session (graceful)
#
# 1. Create stop flag (overrides all consent layers)
# 2. Remove the session flag
# 3. Wait for in-flight workers to finish (up to grace period)
# 4. Optionally kill remaining workers if --force is passed
#######################################
cmd_stop() {
	local force
	force=$(_stop_parse_force "$@")

	_stop_check_preconditions "$force" || return 0

	_stop_write_flags >/dev/null

	print_success "Pulse stopped (no new pulse cycles will start)"

	local worker_count
	worker_count=$(count_workers)

	if [[ "$worker_count" -eq 0 ]]; then
		print_success "No active workers — clean shutdown"
		return 0
	fi

	echo ""
	print_info "${worker_count} worker(s) still running"

	if [[ "$force" == "true" ]]; then
		_stop_force_kill_workers "$worker_count"
		return 0
	fi

	_stop_wait_for_workers "$worker_count"
	return 0
}

#######################################
# Resolve effective consent state for status display
# Outputs four lines: effective_state, effective_reason,
#   has_stop_flag (true/false), has_session_flag (true/false),
#   has_config_consent (true/false)
#######################################
_status_resolve_consent() {
	local has_stop_flag=false
	local has_session_flag=false
	local has_config_consent=false
	local effective_state="disabled"
	local effective_reason="no consent layer active"

	[[ -f "$STOP_FLAG" ]] && has_stop_flag=true
	is_session_active && has_session_flag=true
	is_config_consent_enabled && has_config_consent=true

	if [[ "$has_stop_flag" == "true" ]]; then
		effective_state="stopped"
		effective_reason="stop flag (aidevops pulse stop)"
	elif [[ "$has_session_flag" == "true" ]]; then
		effective_state="enabled"
		effective_reason="session flag (aidevops pulse start)"
	elif [[ "$has_config_consent" == "true" ]]; then
		effective_state="enabled"
		effective_reason="config consent (orchestration.supervisor_pulse=true)"
	fi

	printf '%s\n%s\n%s\n%s\n%s\n' \
		"$effective_state" "$effective_reason" \
		"$has_stop_flag" "$has_session_flag" "$has_config_consent"
	return 0
}

#######################################
# Print effective pulse state line
# Args: $1=effective_state, $2=effective_reason
#######################################
_status_print_effective_state() {
	local effective_state="$1"
	local effective_reason="$2"

	if [[ "$effective_state" == "enabled" ]]; then
		echo -e "  Pulse:       ${GREEN}enabled${NC} via ${effective_reason}"
	elif [[ "$effective_state" == "stopped" ]]; then
		echo -e "  Pulse:       ${RED}stopped${NC} via ${effective_reason}"
	else
		echo -e "  Pulse:       ${YELLOW}disabled${NC} (${effective_reason})"
	fi
	return 0
}

#######################################
# Print consent layer details
# Args: $1=has_stop_flag, $2=has_session_flag, $3=has_config_consent
#######################################
_status_print_consent_layers() {
	local has_stop_flag="$1"
	local has_session_flag="$2"
	local has_config_consent="$3"

	# Sanitize values from flag files to prevent terminal escape injection
	echo ""
	echo -e "  ${BOLD}Consent layers:${NC}"

	if [[ "$has_stop_flag" == "true" ]]; then
		local stopped_at
		stopped_at=$(grep '^stopped_at=' "$STOP_FLAG" | cut -d= -f2 | tr -cd '[:alnum:]T:Z.+-')
		echo -e "    Stop flag:      ${RED}set${NC} (${stopped_at:-unknown})"
	else
		echo -e "    Stop flag:      ${GREEN}clear${NC}"
	fi

	if [[ "$has_session_flag" == "true" ]]; then
		local started_at started_by
		started_at=$(grep '^started_at=' "$SESSION_FLAG" | cut -d= -f2 | tr -cd '[:alnum:]T:Z.+-')
		started_by=$(grep '^started_by=' "$SESSION_FLAG" | cut -d= -f2 | tr -cd '[:alnum:]._-')
		echo -e "    Session flag:   ${GREEN}active${NC} (${started_at:-unknown} by ${started_by:-unknown})"
	else
		echo -e "    Session flag:   ${YELLOW}inactive${NC}"
	fi

	if [[ "$has_config_consent" == "true" ]]; then
		echo -e "    Config consent: ${GREEN}enabled${NC}"
	else
		echo -e "    Config consent: ${YELLOW}disabled${NC}"
	fi
	return 0
}

#######################################
# Print pulse process status line
#######################################
_status_print_process() {
	if is_pulse_running; then
		local pulse_pid_content pulse_display_pid
		pulse_pid_content=$(cat "$PIDFILE" || echo "?")
		if [[ "$pulse_pid_content" == SETUP:* ]]; then
			pulse_display_pid="${pulse_pid_content#SETUP:}"
			echo -e "  Process:     ${YELLOW}setup${NC} (PID ${pulse_display_pid}, pre-flight stages)"
		else
			pulse_display_pid="$pulse_pid_content"
			echo -e "  Process:     ${GREEN}running${NC} (PID ${pulse_display_pid})"
		fi
	else
		local idle_scheduler_name
		idle_scheduler_name=$(get_scheduler_name)
		if is_scheduler_installed; then
			echo -e "  Process:     ${BLUE}idle${NC} (waiting for next ${idle_scheduler_name} cycle)"
		else
			echo -e "  Process:     ${RED}idle${NC} (scheduler: NOT INSTALLED)"
			local install_cmd
			install_cmd=$(get_scheduler_install_cmd)
			echo -e "               Install with: ${install_cmd}"
		fi
	fi
	return 0
}

#######################################
# Print workers, max workers, repos, last pulse summary
# Args: $1 = worker_count (pre-computed to avoid double ps call)
#######################################
_status_print_workers_summary() {
	local worker_count="$1"

	if [[ "$worker_count" -gt 0 ]]; then
		echo -e "  Workers:     ${GREEN}${worker_count} active${NC}"
	else
		echo "  Workers:     0"
	fi

	local max_workers="?"
	if [[ -f "$MAX_WORKERS_FILE" ]]; then
		max_workers=$(cat "$MAX_WORKERS_FILE" || echo "?")
	fi
	echo "  Max workers: ${max_workers}"

	local repo_count
	repo_count=$(get_pulse_repo_count)
	echo "  Repos:       ${repo_count} pulse-enabled"

	local last_pulse
	last_pulse=$(get_last_pulse_time)
	echo "  Last pulse:  ${last_pulse}"
	return 0
}

#######################################
# Print active worker process details
# Args: $1 = worker_count
#######################################
_status_print_worker_details() {
	local worker_count="$1"

	if [[ "$worker_count" -gt 0 ]]; then
		echo ""
		echo -e "${BOLD}Active Workers${NC}"
		echo "──────────────"
		echo ""
		ps axwwo pid,etime,command | grep '[/]full-loop' | grep '\.opencode' | while IFS= read -r line; do
			local w_pid w_etime w_cmd
			read -r w_pid w_etime w_cmd <<<"$line"

			# Extract title
			local w_title="untitled"
			if [[ "$w_cmd" =~ --title[[:space:]]+\"([^\"]+)\" ]] || [[ "$w_cmd" =~ --title[[:space:]]+([^[:space:]]+) ]]; then
				w_title="${BASH_REMATCH[1]}"
			fi

			echo "  PID ${w_pid} (${w_etime}): ${w_title}"
		done
		echo ""
	fi
	return 0
}

#######################################
# Print action hints based on effective state
# Args: $1 = effective_state
#######################################
_status_print_hints() {
	local effective_state="$1"

	if [[ "$effective_state" == "enabled" ]]; then
		echo "  Stop:  aidevops pulse stop"
		echo "  Force: aidevops pulse stop --force"
	elif [[ "$effective_state" == "stopped" ]]; then
		echo "  Resume: aidevops pulse start"
	else
		echo "  Start:  aidevops pulse start"
		echo "  Or set: orchestration.supervisor_pulse=true in config.jsonc"
	fi
	return 0
}

#######################################
# Show pulse session status
#######################################
cmd_status() {
	echo -e "${BOLD}Pulse Status${NC}"
	echo "────────────"
	echo ""

	# Resolve consent layers (5-line output: state, reason, stop, session, config)
	local consent_output effective_state effective_reason has_stop_flag has_session_flag has_config_consent
	consent_output=$(_status_resolve_consent)
	effective_state=$(echo "$consent_output" | sed -n '1p')
	effective_reason=$(echo "$consent_output" | sed -n '2p')
	has_stop_flag=$(echo "$consent_output" | sed -n '3p')
	has_session_flag=$(echo "$consent_output" | sed -n '4p')
	has_config_consent=$(echo "$consent_output" | sed -n '5p')

	_status_print_effective_state "$effective_state" "$effective_reason"
	_status_print_consent_layers "$has_stop_flag" "$has_session_flag" "$has_config_consent"
	echo ""

	_status_print_process

	local worker_count
	worker_count=$(count_workers)
	_status_print_workers_summary "$worker_count"
	echo ""

	_status_print_worker_details "$worker_count"
	_status_print_hints "$effective_state"
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
pulse-session-helper.sh - Pulse consent and session control

USAGE:
    aidevops pulse <command> [options]

COMMANDS:
    start              Enable the pulse (clears stop flag, creates session flag)
    stop [--force]     Stop the pulse (creates stop flag, removes session flag)
    status             Show consent layers, workers, repos

STOP OPTIONS:
    --force, -f        Send SIGTERM to workers immediately instead of waiting

ENVIRONMENT:
    PULSE_STOP_GRACE_SECONDS   Grace period for workers on stop (default: 300)
    AIDEVOPS_SUPERVISOR_PULSE  Override config consent (true/false)

HOW IT WORKS:
    The supervisor pulse runs every 2 minutes via launchd/cron. Whether it
    actually does work depends on a layered consent model (checked in order):

    1. Stop flag (~/.aidevops/logs/pulse-session.stop)
       Highest priority. If present, pulse is paused regardless of other
       layers. Created by 'aidevops pulse stop', cleared by 'start'.

    2. Session flag (~/.aidevops/logs/pulse-session.flag)
       Explicit user action. Created by 'aidevops pulse start'.
       Does NOT survive reboots — use for bounded work sessions.

    3. Config consent (orchestration.supervisor_pulse=true)
       Persistent setting in ~/.config/aidevops/config.jsonc.
       Survives reboots — the pulse runs unattended after reboot.
       Set during 'aidevops init' or manually in config.

    If none of the above are set, the pulse skips (no-op).

    For unattended operation: set config consent and don't use start/stop.
    For bounded sessions: use 'aidevops pulse start' and 'stop'.
    To pause temporarily: 'aidevops pulse stop' (overrides config consent).

EXAMPLES:
    aidevops pulse start           # Enable pulse for this session
    aidevops pulse status          # Show consent layers and workers
    aidevops pulse stop            # Graceful stop (wait for workers)
    aidevops pulse stop --force    # Stop immediately

EOF
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	start) cmd_start ;;
	stop) cmd_stop "$@" ;;
	status | s) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		echo "Run 'aidevops pulse help' for usage."
		return 1
		;;
	esac
}

main "$@"
