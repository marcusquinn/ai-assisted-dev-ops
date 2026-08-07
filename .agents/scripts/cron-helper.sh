#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# cron-helper.sh - Manage cron jobs that dispatch AI agents via OpenCode server
#
# Usage:
#   cron-helper.sh list
#   cron-helper.sh add --schedule "0 9 * * *" --task "description" [--name name] [--notify mail|none] [--timeout 600]
#   cron-helper.sh remove <job-id> [--force]
#   cron-helper.sh pause <job-id>
#   cron-helper.sh resume <job-id>
#   cron-helper.sh logs [--job <id>] [--tail N] [--follow] [--since DATE]
#   cron-helper.sh debug <job-id>
#   cron-helper.sh status
#   cron-helper.sh run <job-id>  # Manual trigger for testing
#
# Configuration: ~/.config/aidevops/cron-jobs.json
# Logs: ~/.aidevops/.agent-workspace/cron/
#
# Security:
#   - Uses HTTPS by default for remote hosts (non-localhost)
#   - Supports basic auth via OPENCODE_SERVER_PASSWORD
#   - SSL verification enabled by default (disable with OPENCODE_INSECURE=1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aidevops"
readonly CONFIG_FILE="$CONFIG_DIR/cron-jobs.json"
readonly WORKSPACE_DIR="$HOME/.aidevops/.agent-workspace"
readonly CRON_LOG_DIR="$WORKSPACE_DIR/cron"
readonly SCRIPTS_DIR="$HOME/.aidevops/agents/scripts"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"
readonly OPENCODE_INSECURE="${OPENCODE_INSECURE:-}"
readonly DEFAULT_MODEL="standard"

# shellcheck disable=SC2034  # CYAN reserved for future use
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# Logging: uses shared log_* from shared-constants.sh with CRON prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="CRON"

#######################################
# Ensure directories and config exist
#######################################
ensure_setup() {
	mkdir -p "$CONFIG_DIR" "$CRON_LOG_DIR"

	if [[ ! -f "$CONFIG_FILE" ]]; then
		cat >"$CONFIG_FILE" <<'EOF'
{
  "version": "1.0",
  "jobs": []
}
EOF
		log_info "Created config file: $CONFIG_FILE"
	fi
}

#######################################
# Generate unique job ID
#######################################
generate_job_id() {
	local count
	count=$(jq '.jobs | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
	printf "job-%03d" $((count + 1))
}

#######################################
# Check if jq is available
#######################################
check_jq() {
	if ! command -v jq &>/dev/null; then
		log_error "jq is required but not installed. Install with: brew install jq"
		return 1
	fi
	return 0
}

#######################################
# Determine protocol based on host
# Localhost uses HTTP, remote uses HTTPS
#######################################
get_protocol() {
	local host="$1"
	# Use HTTP only for localhost/127.0.0.1, HTTPS for everything else
	if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
		echo "http"
	else
		echo "https"
	fi
}

#######################################
# Build curl arguments array for secure requests
# Arguments:
#   $1 - protocol (http|https), already resolved by caller
# Populates CURL_ARGS array with auth and SSL options
#######################################
build_curl_args() {
	local protocol="${1:-http}"
	CURL_ARGS=(-sf)

	# Add authentication if configured
	if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
		local user="${OPENCODE_SERVER_USERNAME:-admin}"
		CURL_ARGS+=(-u "${user}:${OPENCODE_SERVER_PASSWORD}")
	fi

	# Add SSL options for HTTPS
	if [[ "$protocol" == "https" ]] && [[ -n "$OPENCODE_INSECURE" ]]; then
		# Allow insecure connections (self-signed certs) - use with caution
		CURL_ARGS+=(-k)
		log_warn "WARNING: SSL verification disabled (OPENCODE_INSECURE=1)"
	fi
	return 0
}

#######################################
# Check OpenCode server health
#######################################
check_server() {
	local protocol
	protocol=$(get_protocol "$OPENCODE_HOST")
	local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/global/health"

	build_curl_args "$protocol"

	if curl "${CURL_ARGS[@]}" "$url" &>/dev/null; then
		return 0
	else
		return 1
	fi
}

#######################################
# Get job by ID
#######################################
get_job() {
	local job_id="$1"
	jq -r --arg id "$job_id" '.jobs[] | select(.id == $id)' "$CONFIG_FILE"
}

#######################################
# Update crontab with active jobs
#######################################
sync_crontab() {
	local temp_cron
	temp_cron=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_cron}'"

	# Get existing crontab (excluding our managed entries)
	crontab -l 2>/dev/null | grep -v "cron-dispatch.sh" >"$temp_cron" || true

	# Add active jobs
	local jobs
	jobs=$(jq -r '.jobs[] | select(.status == "active") | "\(.schedule) \(.id)"' "$CONFIG_FILE" 2>/dev/null || echo "")

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local schedule job_id
		schedule=$(echo "$line" | rev | cut -d' ' -f2- | rev)
		job_id=$(echo "$line" | awk '{print $NF}')
		echo "$schedule $SCRIPTS_DIR/cron-dispatch.sh $job_id >> $CRON_LOG_DIR/${job_id}.log 2>&1" >>"$temp_cron"
	done <<<"$jobs"

	# Install new crontab
	crontab "$temp_cron"
	rm -f "$temp_cron"
}

#######################################
# List all jobs
#######################################
cmd_list() {
	check_jq || return 1
	ensure_setup

	local jobs
	jobs=$(jq -r '.jobs | length' "$CONFIG_FILE")

	if [[ "$jobs" -eq 0 ]]; then
		log_info "No cron jobs configured"
		echo ""
		echo "Add a job with:"
		echo "  cron-helper.sh add --schedule \"0 9 * * *\" --task \"Your task description\""
		return 0
	fi

	printf "${BOLD}%-12s %-18s %-35s %s${NC}\n" "ID" "Schedule" "Name" "Status"
	printf "%-12s %-18s %-35s %s\n" "──────────" "────────────────" "─────────────────────────────────" "──────"

	jq -r '.jobs[] | "\(.id)|\(.schedule)|\(.name)|\(.status)"' "$CONFIG_FILE" | while IFS='|' read -r id schedule name status; do
		local status_color="$NC"
		case "$status" in
		active) status_color="$GREEN" ;;
		paused) status_color="$YELLOW" ;;
		failed) status_color="$RED" ;;
		esac
		printf "%-12s %-18s %-35s ${status_color}%s${NC}\n" "$id" "$schedule" "${name:0:35}" "$status"
	done
}

#######################################
# Parse arguments for cmd_add
# Sets variables in caller scope via eval.
# Arguments: all original "$@" from cmd_add
# Outputs (via eval): _add_schedule _add_task _add_name _add_notify
#                     _add_timeout _add_workdir _add_model _add_paused
#                     _add_provider
# Returns: 0 on success, 1 on parse error
#######################################
_parse_add_args() {
	_add_schedule=""
	_add_task=""
	_add_name=""
	_add_notify="none"
	_add_timeout="$DEFAULT_TIMEOUT"
	_add_workdir=""
	_add_model="$DEFAULT_MODEL"
	_add_paused=false
	_add_provider=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--schedule)
			[[ $# -lt 2 ]] && {
				log_error "--schedule requires a value"
				return 1
			}
			_add_schedule="$2"
			shift 2
			;;
		--task)
			[[ $# -lt 2 ]] && {
				log_error "--task requires a value"
				return 1
			}
			_add_task="$2"
			shift 2
			;;
		--name)
			[[ $# -lt 2 ]] && {
				log_error "--name requires a value"
				return 1
			}
			_add_name="$2"
			shift 2
			;;
		--notify)
			[[ $# -lt 2 ]] && {
				log_error "--notify requires a value"
				return 1
			}
			_add_notify="$2"
			shift 2
			;;
		--timeout)
			[[ $# -lt 2 ]] && {
				log_error "--timeout requires a value"
				return 1
			}
			_add_timeout="$2"
			shift 2
			;;
		--workdir)
			[[ $# -lt 2 ]] && {
				log_error "--workdir requires a value"
				return 1
			}
			_add_workdir="$2"
			shift 2
			;;
		--model)
			[[ $# -lt 2 ]] && {
				log_error "--model requires a value"
				return 1
			}
			_add_model="$2"
			shift 2
			;;
		--provider)
			[[ $# -lt 2 ]] && {
				log_error "--provider requires a value"
				return 1
			}
			_add_provider="$2"
			shift 2
			;;
		--paused)
			_add_paused=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

#######################################
# Write a new job entry to the config file
# Arguments:
#   $1 - job_id
#   $2 - name
#   $3 - schedule
#   $4 - task
#   $5 - workdir
#   $6 - timeout
#   $7 - notify
#   $8 - model
#   $9 - status
#   $10 - provider override
#   $11 - timestamp (ISO 8601)
# Returns: 0 on success, 1 on failure
#######################################
_write_job_to_config() {
	local job_id="$1"
	local name="$2"
	local schedule="$3"
	local task="$4"
	local workdir="$5"
	local timeout="$6"
	local notify="$7"
	local model="$8"
	local status="$9"
	local provider="${10}"
	local timestamp="${11}"

	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg id "$job_id" \
		--arg name "$name" \
		--arg schedule "$schedule" \
		--arg task "$task" \
		--arg workdir "$workdir" \
		--argjson timeout "$timeout" \
		--arg notify "$notify" \
		--arg model "$model" \
		--arg status "$status" \
		--arg provider "$provider" \
		--arg created "$timestamp" \
		'.jobs += [{
         id: $id,
         name: $name,
         schedule: $schedule,
         task: $task,
         workdir: $workdir,
         timeout: $timeout,
         notify: $notify,
         model: $model,
         model_tier:(if ($model == "simple" or $model == "standard" or $model == "thinking") then $model else null end),
         provider:(if $provider == "" then null else $provider end),
         status: $status,
         created: $created,
         lastRun: null,
         lastStatus: null
       }]' "$CONFIG_FILE" >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"
	return 0
}

#######################################
# Print success output after adding a job
# Arguments:
#   $1 - job_id
#   $2 - name
#   $3 - schedule
#   $4 - task
#   $5 - status
#######################################
_print_add_result() {
	local job_id="$1"
	local name="$2"
	local schedule="$3"
	local task="$4"
	local status="$5"

	log_success "Created job: $job_id ($name)"
	echo ""
	echo "Schedule: $schedule"
	echo "Task: $task"
	echo "Status: $status"

	if [[ "$status" == "active" ]]; then
		echo ""
		echo "Job will run according to schedule. Test with:"
		echo "  cron-helper.sh run $job_id"
	fi
	return 0
}

#######################################
# Add a new job
#######################################
cmd_add() {
	check_jq || return 1
	ensure_setup

	_parse_add_args "$@" || return 1

	# Validate required fields
	if [[ -z "$_add_schedule" ]]; then
		log_error "--schedule is required (e.g., \"0 9 * * *\")"
		return 1
	fi
	if [[ -z "$_add_task" ]]; then
		log_error "--task is required (description of what the AI should do)"
		return 1
	fi

	# Generate name if not provided
	if [[ -z "$_add_name" ]]; then
		_add_name=$(echo "$_add_task" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-30)
	fi

	# Set workdir to current if not specified
	if [[ -z "$_add_workdir" ]]; then
		_add_workdir="$(pwd)"
	fi

	local job_id timestamp status
	job_id=$(generate_job_id)
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	status="active"
	[[ "$_add_paused" == "true" ]] && status="paused"

	_write_job_to_config "$job_id" "$_add_name" "$_add_schedule" "$_add_task" \
		"$_add_workdir" "$_add_timeout" "$_add_notify" "$_add_model" \
		"$status" "$_add_provider" "$timestamp" || return 1

	sync_crontab

	_print_add_result "$job_id" "$_add_name" "$_add_schedule" "$_add_task" "$status"
	return 0
}

#######################################
# Remove a job
#######################################
cmd_remove() {
	check_jq || return 1
	ensure_setup

	local job_id="" force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			job_id="$1"
			shift
			;;
		esac
	done

	if [[ -z "$job_id" ]]; then
		log_error "Job ID required"
		return 1
	fi

	local job
	job=$(get_job "$job_id")
	if [[ -z "$job" ]]; then
		log_error "Job not found: $job_id"
		return 1
	fi

	local name
	name=$(echo "$job" | jq -r '.name')

	if [[ "$force" != "true" ]]; then
		echo -n "Remove job $job_id ($name)? [y/N] "
		read -r confirm
		if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
			log_info "Cancelled"
			return 0
		fi
	fi

	# Remove from config
	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg id "$job_id" '.jobs = [.jobs[] | select(.id != $id)]' "$CONFIG_FILE" >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"

	# Sync crontab
	sync_crontab

	log_success "Removed job: $job_id ($name)"
	return 0
}

#######################################
# Pause a job
#######################################
cmd_pause() {
	check_jq || return 1
	ensure_setup

	local job_id="$1"

	if [[ -z "$job_id" ]]; then
		log_error "Job ID required"
		return 1
	fi

	local job
	job=$(get_job "$job_id")
	if [[ -z "$job" ]]; then
		log_error "Job not found: $job_id"
		return 1
	fi

	# Update status
	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg id "$job_id" '(.jobs[] | select(.id == $id)).status = "paused"' "$CONFIG_FILE" >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"

	# Sync crontab
	sync_crontab

	local name
	name=$(echo "$job" | jq -r '.name')
	log_success "Paused job: $job_id ($name)"
	return 0
}

#######################################
# Resume a job
#######################################
cmd_resume() {
	check_jq || return 1
	ensure_setup

	local job_id="$1"

	if [[ -z "$job_id" ]]; then
		log_error "Job ID required"
		return 1
	fi

	local job
	job=$(get_job "$job_id")
	if [[ -z "$job" ]]; then
		log_error "Job not found: $job_id"
		return 1
	fi

	# Update status
	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	jq --arg id "$job_id" '(.jobs[] | select(.id == $id)).status = "active"' "$CONFIG_FILE" >"$temp_file"
	mv "$temp_file" "$CONFIG_FILE"

	# Sync crontab
	sync_crontab

	local name
	name=$(echo "$job" | jq -r '.name')
	log_success "Resumed job: $job_id ($name)"
	return 0
}

#######################################
# View logs
#######################################
cmd_logs() {
	ensure_setup

	local job_id="" tail_lines=50 follow=false
	local since="" # TODO: Implement --since date filtering

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--job)
			[[ $# -lt 2 ]] && {
				log_error "--job requires a value"
				return 1
			}
			job_id="$2"
			shift 2
			;;
		--tail)
			[[ $# -lt 2 ]] && {
				log_error "--tail requires a value"
				return 1
			}
			tail_lines="$2"
			shift 2
			;;
		--follow | -f)
			follow=true
			shift
			;;
		--since)
			[[ $# -lt 2 ]] && {
				log_error "--since requires a value"
				return 1
			}
			since="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Use since to suppress shellcheck warning (future: filter logs by date)
	: "${since:=}"

	if [[ -n "$job_id" ]]; then
		local log_file="$CRON_LOG_DIR/${job_id}.log"
		if [[ ! -f "$log_file" ]]; then
			log_info "No logs found for job: $job_id"
			return 0
		fi

		if [[ "$follow" == "true" ]]; then
			tail -f "$log_file"
		else
			tail -n "$tail_lines" "$log_file"
		fi
	else
		# Show combined logs from all jobs
		local log_files
		log_files=$(find "$CRON_LOG_DIR" -name "*.log" -type f 2>/dev/null | sort)

		if [[ -z "$log_files" ]]; then
			log_info "No logs found"
			return 0
		fi

		if [[ "$follow" == "true" ]]; then
			# shellcheck disable=SC2086
			tail -f $log_files
		else
			for log_file in $log_files; do
				local job_name
				job_name=$(basename "$log_file" .log)
				echo -e "${BOLD}=== $job_name ===${NC}"
				tail -n "$tail_lines" "$log_file"
				echo ""
			done
		fi
	fi

	return 0
}

#######################################
# Debug a job
#######################################
cmd_debug() {
	check_jq || return 1
	ensure_setup

	local job_id="$1"

	if [[ -z "$job_id" ]]; then
		log_error "Job ID required"
		return 1
	fi

	local job
	job=$(get_job "$job_id")
	if [[ -z "$job" ]]; then
		log_error "Job not found: $job_id"
		return 1
	fi

	local name schedule last_run last_status task
	name=$(echo "$job" | jq -r '.name')
	schedule=$(echo "$job" | jq -r '.schedule')
	last_run=$(echo "$job" | jq -r '.lastRun // "never"')
	last_status=$(echo "$job" | jq -r '.lastStatus // "unknown"')
	task=$(echo "$job" | jq -r '.task')

	echo -e "${BOLD}Job Debug: $job_id${NC}"
	echo "────────────────────────────────────"
	echo "Name: $name"
	echo "Schedule: $schedule"
	echo "Task: $task"
	echo ""
	echo "Last run: $last_run"
	echo "Last status: $last_status"
	echo ""

	# Check OpenCode server
	echo -e "${BOLD}OpenCode Server:${NC}"
	if check_server; then
		echo -e "  Status: ${GREEN}running${NC} (port $OPENCODE_PORT)"
	else
		echo -e "  Status: ${RED}not responding${NC}"
		echo ""
		echo -e "${YELLOW}Suggestions:${NC}"
		echo "  1. Start server: opencode serve --port $OPENCODE_PORT"
		echo "  2. Check if port is in use: lsof -i :$OPENCODE_PORT"
		echo "  3. View server logs: tail -f /tmp/opencode-server.log"
		return 1
	fi

	# Check log file
	local log_file="$CRON_LOG_DIR/${job_id}.log"
	echo ""
	echo -e "${BOLD}Recent Log Output:${NC}"
	if [[ -f "$log_file" ]]; then
		tail -n 20 "$log_file"
	else
		echo "  No log file found"
	fi

	# Check crontab entry
	echo ""
	echo -e "${BOLD}Crontab Entry:${NC}"
	local cron_entry
	cron_entry=$(crontab -l 2>/dev/null | grep "$job_id" || echo "")
	if [[ -n "$cron_entry" ]]; then
		echo "  $cron_entry"
	else
		echo -e "  ${YELLOW}Not found in crontab${NC}"
		echo "  Run: cron-helper.sh resume $job_id"
	fi

	return 0
}

#######################################
# Show status
#######################################
cmd_status() {
	check_jq || return 1
	ensure_setup

	local total active paused failed
	total=$(jq '.jobs | length' "$CONFIG_FILE")
	active=$(jq '[.jobs[] | select(.status == "active")] | length' "$CONFIG_FILE")
	paused=$(jq '[.jobs[] | select(.status == "paused")] | length' "$CONFIG_FILE")
	failed=$(jq '[.jobs[] | select(.lastStatus == "failed")] | length' "$CONFIG_FILE")

	echo -e "${BOLD}Cron Agent Status${NC}"
	echo "─────────────────────"
	echo "Jobs defined: $total"
	echo -e "Jobs active: ${GREEN}$active${NC}"
	echo -e "Jobs paused: ${YELLOW}$paused${NC}"
	echo ""

	# Check OpenCode server
	echo -n "OpenCode Server: "
	if check_server; then
		echo -e "${GREEN}running${NC} (port $OPENCODE_PORT)"
	else
		echo -e "${RED}not responding${NC}"
	fi

	# Recent failures
	if [[ "$failed" -gt 0 ]]; then
		echo ""
		echo -e "${RED}Failed jobs:${NC}"
		jq -r '.jobs[] | select(.lastStatus == "failed") | "  \(.id) (\(.name)) - last run: \(.lastRun)"' "$CONFIG_FILE"
	fi

	# Upcoming jobs (simplified - just show active jobs)
	if [[ "$active" -gt 0 ]]; then
		echo ""
		echo -e "${BOLD}Active jobs:${NC}"
		jq -r '.jobs[] | select(.status == "active") | "  \(.id) (\(.name)) - \(.schedule)"' "$CONFIG_FILE"
	fi

	return 0
}

#######################################
# Manually run a job (for testing)
#######################################
cmd_run() {
	check_jq || return 1
	ensure_setup

	local job_id="$1"

	if [[ -z "$job_id" ]]; then
		log_error "Job ID required"
		return 1
	fi

	local job
	job=$(get_job "$job_id")
	if [[ -z "$job" ]]; then
		log_error "Job not found: $job_id"
		return 1
	fi

	log_info "Manually triggering job: $job_id"

	# Call the dispatch script directly
	"$SCRIPTS_DIR/cron-dispatch.sh" "$job_id"

	return $?
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
cron-helper.sh - Manage cron jobs that dispatch AI agents

USAGE:
    cron-helper.sh <command> [options]

COMMANDS:
    list                    List all configured jobs
    add                     Add a new scheduled job
    remove <job-id>         Remove a job
    pause <job-id>          Pause a job (keeps config, removes from crontab)
    resume <job-id>         Resume a paused job
    logs                    View execution logs
    debug <job-id>          Debug a failing job
    status                  Show overall system status
    run <job-id>            Manually trigger a job (for testing)
    help                    Show this help

ADD OPTIONS:
    --schedule "CRON"       Cron expression (required)
    --task "DESCRIPTION"    Task for AI to execute (required)
    --name "NAME"           Human-readable name (optional)
    --notify mail|none      Notification method (default: none)
    --timeout SECONDS       Max execution time (default: 600)
    --workdir PATH          Working directory (default: current)
    --model TIER_OR_MODEL   Workload tier (simple/standard/thinking) or full provider/model
    --provider PROVIDER     Override provider (e.g., openrouter, google)
    --paused                Create in paused state

LOGS OPTIONS:
    --job <id>              Filter to specific job
    --tail N                Number of lines (default: 50)
    --follow, -f            Follow log output
    --since DATE            Show logs since date

EXAMPLES:
    # Add a daily report job
    cron-helper.sh add --schedule "0 9 * * *" --task "Generate daily SEO report"

    # Add a health check every 30 minutes
    cron-helper.sh add --schedule "*/30 * * * *" --task "Check server health" --timeout 120

    # View logs for a specific job
    cron-helper.sh logs --job job-001 --tail 100

    # Debug a failing job
    cron-helper.sh debug job-001

    # Manually test a job
    cron-helper.sh run job-001

CONFIGURATION:
    Jobs: ~/.config/aidevops/cron-jobs.json
    Logs: ~/.aidevops/.agent-workspace/cron/

REQUIREMENTS:
    - jq (brew install jq)
    - OpenCode server running (opencode serve --port 4096)

EOF
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	list) cmd_list "$@" ;;
	add) cmd_add "$@" ;;
	remove) cmd_remove "$@" ;;
	pause) cmd_pause "$@" ;;
	resume) cmd_resume "$@" ;;
	logs) cmd_logs "$@" ;;
	debug) cmd_debug "$@" ;;
	status) cmd_status "$@" ;;
	run) cmd_run "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	local command_status=$?
	return "$command_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
