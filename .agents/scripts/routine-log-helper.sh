#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# routine-log-helper.sh — Update routine tracking issue descriptions with
# living summary metrics after execution. Notable events as comments.
# Script-only shows $0 cost. Detailed logs stay local. (t1926)
#
# Usage:
#   routine-log-helper.sh update <routine-id> --status queued|claimed|running|success|failure|deferred|cancelled [--duration SECONDS] [--tokens N] [--cost AMOUNT] [--job-id ID] [--session-key KEY]
#   routine-log-helper.sh notable <routine-id> --event "description"
#   routine-log-helper.sh create-issue <routine-id> --repo SLUG --title "rNNN: Title" [--schedule EXPR] [--type TYPE]
#   routine-log-helper.sh status
#   routine-log-helper.sh help
#
# State file: ~/.aidevops/.agent-workspace/cron/<routine-id>/routine-state.json
# Local logs: ~/.aidevops/.agent-workspace/cron/<routine-id>/

set -euo pipefail

# PATH normalisation for launchd/MCP environments
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

CRON_BASE="${HOME}/.aidevops/.agent-workspace/cron"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
PERIOD_DAYS=7

# =============================================================================
# Logging
# =============================================================================

_log_info() {
	local msg="$1"
	echo -e "${BLUE}[INFO]${NC} ${msg}" >&2
	return 0
}

_log_warn() {
	local msg="$1"
	echo -e "${YELLOW}[WARN]${NC} ${msg}" >&2
	return 0
}

_log_error() {
	local msg="$1"
	echo -e "${RED}[ERROR]${NC} ${msg}" >&2
	return 0
}

_log_success() {
	local msg="$1"
	echo -e "${GREEN}[OK]${NC} ${msg}" >&2
	return 0
}

# =============================================================================
# Prerequisites
# =============================================================================

_check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		_log_error "gh CLI not found. Install from https://cli.github.com/"
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		_log_error "jq not found. Install with: brew install jq / apt install jq"
		return 1
	fi
	return 0
}

# =============================================================================
# State management
# =============================================================================

_state_dir() {
	local routine_id="$1"
	echo "${CRON_BASE}/${routine_id}"
}

_state_file() {
	local routine_id="$1"
	echo "$(_state_dir "$routine_id")/routine-state.json"
}

_ensure_state_dir() {
	local routine_id="$1"
	local dir
	dir="$(_state_dir "$routine_id")"
	mkdir -p "$dir"
	return 0
}

_read_state() {
	local routine_id="$1"
	local state_file
	state_file="$(_state_file "$routine_id")"
	if [[ -f "$state_file" ]]; then
		cat "$state_file"
	else
		echo '{}'
	fi
	return 0
}

_write_state() {
	local routine_id="$1"
	local state_json="$2"
	local state_file
	state_file="$(_state_file "$routine_id")"
	_ensure_state_dir "$routine_id"
	echo "$state_json" >"$state_file"
	return 0
}

_get_state_field() {
	local routine_id="$1"
	local field="$2"
	local default="${3:-}"
	local value
	value=$(_read_state "$routine_id" | jq -r ".${field} // empty")
	if [[ -z "$value" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

# =============================================================================
# Local log management
# =============================================================================

_append_local_log() {
	local routine_id="$1"
	local status="$2"
	local duration="$3"
	local tokens="${4:-0}"
	local cost="${5:-0.00}"
	local log_dir
	log_dir="$(_state_dir "$routine_id")/logs"
	mkdir -p "$log_dir"

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local log_entry
	log_entry=$(jq -n \
		--arg ts "$timestamp" \
		--arg st "$status" \
		--argjson dur "$duration" \
		--argjson tok "$tokens" \
		--arg cost "$cost" \
		'{timestamp: $ts, status: $st, duration: $dur, tokens: $tok, cost: $cost}')

	echo "$log_entry" >>"${log_dir}/executions.jsonl"
	return 0
}

_compute_period_summary() {
	local routine_id="$1"
	local log_file
	log_file="$(_state_dir "$routine_id")/logs/executions.jsonl"

	if [[ ! -f "$log_file" ]]; then
		echo '{"total":0,"successes":0,"failures":0,"total_cost":"0.00","avg_duration":0,"period_start":"","period_end":""}'
		return 0
	fi

	local cutoff_ts
	cutoff_ts=$(date -u -d "${PERIOD_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -v-${PERIOD_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		echo "1970-01-01T00:00:00Z")

	local period_start
	period_start=$(date -u -d "${PERIOD_DAYS} days ago" +%Y-%m-%d 2>/dev/null ||
		date -u -v-${PERIOD_DAYS}d +%Y-%m-%d 2>/dev/null ||
		echo "unknown")
	local period_end
	period_end=$(date -u +%Y-%m-%d)

	# Filter entries within period and compute aggregates
	local result
	result=$(jq -s --arg cutoff "$cutoff_ts" '
        [.[] | select(.timestamp >= $cutoff)] |
        {
            total: length,
            successes: [.[] | select(.status == "success")] | length,
            failures: [.[] | select(.status == "failure")] | length,
            total_cost: ([.[] | .cost | tonumber] | add // 0 | . * 100 | round / 100 | tostring),
            avg_duration: (if length > 0 then ([.[] | .duration] | add / length | round) else 0 end)
        }
    ' "$log_file" 2>/dev/null || echo '{"total":0,"successes":0,"failures":0,"total_cost":"0.00","avg_duration":0}')

	# Add period dates
	result=$(echo "$result" | jq --arg ps "$period_start" --arg pe "$period_end" \
		'. + {period_start: $ps, period_end: $pe}')

	echo "$result"
	return 0
}

# =============================================================================
# Duration formatting
# =============================================================================

_format_duration() {
	local seconds="$1"
	local mins=$((seconds / 60))
	local secs=$((seconds % 60))
	if [[ "$mins" -gt 0 ]]; then
		echo "${mins}m ${secs}s"
	else
		echo "${secs}s"
	fi
	return 0
}

# =============================================================================
# Streak tracking
# =============================================================================

_update_streak() {
	local routine_id="$1"
	local new_status="$2"
	local current_streak_count
	current_streak_count=$(_get_state_field "$routine_id" "streak_count" "0")
	local current_streak_type
	current_streak_type=$(_get_state_field "$routine_id" "streak_type" "")

	local streak_broke="false"

	if [[ "$current_streak_type" == "$new_status" ]]; then
		current_streak_count=$((current_streak_count + 1))
	else
		if [[ -n "$current_streak_type" ]] && [[ "$current_streak_count" -ge 3 ]]; then
			streak_broke="true"
		fi
		current_streak_count=1
		current_streak_type="$new_status"
	fi

	# Update state
	local state
	state=$(_read_state "$routine_id")
	state=$(echo "$state" | jq \
		--argjson count "$current_streak_count" \
		--arg type "$current_streak_type" \
		'.streak_count = $count | .streak_type = $type')
	_write_state "$routine_id" "$state"

	echo "$streak_broke"
	return 0
}

# =============================================================================
# Next run computation
# =============================================================================

_compute_next_run() {
	local schedule="$1"
	local now_ts
	now_ts=$(date -u +%s)

	# Parse schedule expressions
	case "$schedule" in
	daily\(@*\))
		local time_part
		time_part=$(echo "$schedule" | sed -E 's/daily\(@([0-9:]+)\)/\1/')
		local hour minute
		hour=$(echo "$time_part" | cut -d: -f1)
		minute=$(echo "$time_part" | cut -d: -f2)
		# Next occurrence: tomorrow at that time
		local tomorrow
		tomorrow=$(date -u -d "tomorrow ${hour}:${minute}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
			date -u -v+1d -v"${hour}"H -v"${minute}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
			echo "unknown")
		echo "$tomorrow"
		;;
	weekly\(*\))
		echo "~7 days"
		;;
	monthly\(*\))
		echo "~30 days"
		;;
	cron\(*\))
		echo "per cron schedule"
		;;
	*)
		echo "unknown"
		;;
	esac
	return 0
}

# =============================================================================
# Issue body template
# =============================================================================

_routing_feedback_for_session() {
	local session_key="$1"
	[[ -n "$session_key" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	local helper="${AIDEVOPS_ROUTING_FEEDBACK_HELPER:-${SCRIPT_DIR}/routing-feedback.mjs}"
	[[ -r "$helper" ]] || return 0
	node "$helper" --session-key "$session_key" --format markdown --heading-level 3 2>/dev/null || true
	return 0
}

_build_issue_body() {
	local routine_id="$1"
	local title="$2"
	local schedule="$3"
	local routine_type="$4"
	local status_label="$5"
	local last_run="$6"
	local last_result="$7"
	local last_duration="$8"
	local next_run="$9"
	local streak_count="${10}"
	local streak_type="${11}"
	local total_cost="${12}"
	local period_summary="${13}"
	local routing_feedback="${14:-}"

	local formatted_duration
	formatted_duration=$(_format_duration "$last_duration")

	local streak_label
	if [[ "$streak_count" -gt 0 ]] && [[ -n "$streak_type" ]]; then
		local plural="successes"
		[[ "$streak_type" == "failure" ]] && plural="failures"
		streak_label="${streak_count} consecutive ${plural}"
	else
		streak_label="—"
	fi

	# Parse period summary
	local p_total p_successes p_cost p_avg_dur p_start p_end
	p_total=$(echo "$period_summary" | jq -r '.total')
	p_successes=$(echo "$period_summary" | jq -r '.successes')
	p_cost=$(echo "$period_summary" | jq -r '.total_cost')
	p_avg_dur=$(echo "$period_summary" | jq -r '.avg_duration')
	p_start=$(echo "$period_summary" | jq -r '.period_start')
	p_end=$(echo "$period_summary" | jq -r '.period_end')

	local p_avg_formatted
	p_avg_formatted=$(_format_duration "$p_avg_dur")

	local last_result_display
	if [[ "$last_result" == "none" ]] || [[ -z "$last_result" ]]; then
		last_result_display="—"
	else
		last_result_display="${last_result} (${formatted_duration})"
	fi

	local last_run_display
	if [[ "$last_run" == "never" ]] || [[ -z "$last_run" ]]; then
		last_run_display="—"
	else
		last_run_display="$last_run"
	fi

	# Read optional description and management sections from state
	local description=""
	local management=""
	local state_dir="${CRON_BASE}/${routine_id}"
	if [[ -f "${state_dir}/routine-state.json" ]]; then
		description=$(jq -r '.description // ""' "${state_dir}/routine-state.json" 2>/dev/null || echo "")
		management=$(jq -r '.management // ""' "${state_dir}/routine-state.json" 2>/dev/null || echo "")
	fi

	cat <<EOF
## ${title}

| Field | Value |
|-------|-------|
| Schedule | ${schedule} |
| Type | ${routine_type} |
| Status | ${status_label} |
| Last run | ${last_run_display} |
| Last result | ${last_result_display} |
| Next run | ${next_run} |
| Streak | ${streak_label} |
| Total cost | \$${total_cost} |

### Latest Period (${p_start} — ${p_end})
${p_successes}/${p_total} runs succeeded. Total cost: \$${p_cost}. Avg duration: ${p_avg_formatted}.

**Detailed logs**: \`~/.aidevops/.agent-workspace/cron/${routine_id}/\`
EOF

	if [[ -n "$routing_feedback" ]]; then
		printf '\n%s\n' "$routing_feedback"
	fi

	# Append description if present
	if [[ -n "$description" ]]; then
		cat <<EOF

---

### What this routine does

${description}
EOF
	fi

	# Append management instructions if present
	if [[ -n "$management" ]]; then
		cat <<EOF

---

${management}
EOF
	fi

	return 0
}

# =============================================================================
# Subcommand: update — helpers
# =============================================================================

# Parse and validate arguments for the update subcommand.
# Sets module-scope _UPDATE_* variables for the caller.
# Returns 1 on invalid input.
_parse_update_args() {
	if [[ $# -lt 1 ]]; then
		_log_error "Usage: routine-log-helper.sh update <routine-id> --status queued|claimed|running|success|failure|deferred|cancelled [--duration SECONDS] [--tokens N] [--cost AMOUNT] [--job-id ID] [--session-key KEY]"
		return 1
	fi
	# shellcheck disable=SC2034
	_UPDATE_ROUTINE_ID="$1"
	shift

	_UPDATE_STATUS=""
	_UPDATE_DURATION=""
	_UPDATE_TOKENS="0"
	_UPDATE_COST="0.00"
	_UPDATE_JOB_ID=""
	_UPDATE_SESSION_KEY=""
	_UPDATE_OUTCOME=""

	while [[ $# -gt 0 ]]; do
		local option="$1"
		if [[ "$option" == --* && $# -lt 2 ]]; then
			_log_error "$option requires a value"
			return 1
		fi
		case "$option" in
		--status)
			_UPDATE_STATUS="$2"
			shift 2
			;;
		--duration)
			_UPDATE_DURATION="$2"
			shift 2
			;;
		--tokens)
			_UPDATE_TOKENS="$2"
			shift 2
			;;
		--cost)
			_UPDATE_COST="$2"
			shift 2
			;;
		--job-id)
			_UPDATE_JOB_ID="$2"
			shift 2
			;;
		--session-key)
			_UPDATE_SESSION_KEY="$2"
			shift 2
			;;
		--outcome)
			_UPDATE_OUTCOME="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $option"
			return 1
			;;
		esac
	done

	if [[ -z "$_UPDATE_STATUS" ]]; then
		_log_error "--status is required"
		return 1
	fi

	case "$_UPDATE_STATUS" in
	queued | claimed | running | success | failure | deferred | cancelled) ;;
	*)
		_log_error "Status must be queued, claimed, running, success, failure, deferred, or cancelled"
		return 1
		;;
	esac

	if [[ "$_UPDATE_STATUS" == "success" || "$_UPDATE_STATUS" == "failure" ]]; then
		if [[ -z "$_UPDATE_DURATION" ]]; then
			_log_error "--duration is required for success and failure"
			return 1
		fi
	elif [[ -z "$_UPDATE_DURATION" ]]; then
		_UPDATE_DURATION="0"
	fi
	if [[ ! "$_UPDATE_DURATION" =~ ^[0-9]+$ ]] || [[ ! "$_UPDATE_TOKENS" =~ ^[0-9]+$ ]] ||
		[[ ! "$_UPDATE_COST" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		_log_error "Duration and tokens must be non-negative integers; cost must be numeric"
		return 1
	fi

	return 0
}

_append_lifecycle_log() {
	local routine_id="$1"
	local status="$2"
	local duration="$3"
	local tokens="$4"
	local cost="$5"
	local job_id="$6"
	local session_key="$7"
	local outcome="$8"
	local timestamp=""
	local lifecycle_file=""
	local record=""
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	lifecycle_file="$(_state_dir "$routine_id")/lifecycle.jsonl"
	record=$(jq -cn \
		--arg timestamp "$timestamp" --arg status "$status" \
		--argjson duration "$duration" --argjson tokens "$tokens" \
		--arg cost "$cost" --arg job_id "$job_id" \
		--arg session_key "$session_key" --arg outcome "$outcome" \
		'{timestamp:$timestamp,status:$status,duration_seconds:$duration,tokens:$tokens,cost:$cost,
		  job_id:(if $job_id == "" then null else $job_id end),
		  session_key:(if $session_key == "" then null else $session_key end),
		  outcome:(if $outcome == "" then null else $outcome end)}') || return 1
	printf '%s\n' "$record" >>"$lifecycle_file"
	chmod 600 "$lifecycle_file"
	return 0
}

# Load routine state and extract common fields needed by update.
# Validates that a tracking issue exists. Outputs JSON state to stdout.
# Returns 1 if no tracking issue is configured.
_load_routine_state() {
	local routine_id="$1"
	local state
	state=$(_read_state "$routine_id")
	local issue_number
	issue_number=$(echo "$state" | jq -r '.issue_number // empty')
	local repo_slug
	repo_slug=$(echo "$state" | jq -r '.repo_slug // empty')

	if [[ -z "$issue_number" ]] || [[ -z "$repo_slug" ]]; then
		_log_error "No tracking issue found for ${routine_id}. Run 'create-issue' first."
		return 1
	fi

	echo "$state"
	return 0
}

# Update state JSON with latest run metrics and persist to disk.
# Args: routine_id, state_json, status, duration, cost, schedule, session_key
# Outputs the new total_cost to stdout.
_update_state_after_run() {
	local routine_id="$1"
	local state="$2"
	local status="$3"
	local duration="$4"
	local cost="$5"
	local schedule="$6"
	local session_key="${7:-}"

	local now_ts
	now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Accumulate total cost
	local prev_total_cost
	prev_total_cost=$(echo "$state" | jq -r '.total_cost // "0.00"')
	local new_total_cost
	new_total_cost=$(echo "$prev_total_cost $cost" | awk '{printf "%.2f", $1 + $2}')

	# Compute next run
	local next_run
	next_run=$(_compute_next_run "$schedule")

	# Save updated state
	state=$(echo "$state" | jq \
		--arg lr "$now_ts" \
		--arg ls "$status" \
		--argjson ld "$duration" \
		--arg nr "$next_run" \
		--arg tc "$new_total_cost" \
		--arg sk "$session_key" \
		'.last_run = $lr | .last_status = $ls | .last_duration = $ld | .next_run = $nr | .total_cost = $tc
		 | .last_session_key = (if $sk == "" then (.last_session_key // null) else $sk end)')
	_write_state "$routine_id" "$state"

	echo "$new_total_cost"
	return 0
}

# Build the updated issue body and push it to GitHub.
# Args: routine_id, issue_number, repo_slug, title, schedule, routine_type,
#       status_label, now_ts, status, duration, next_run, streak_count,
#       streak_type, total_cost, session_key
_update_tracking_issue() {
	local routine_id="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local title="$4"
	local schedule="$5"
	local routine_type="$6"
	local status_label="$7"
	local now_ts="$8"
	local status="$9"
	local duration="${10}"
	local next_run="${11}"
	local streak_count="${12}"
	local streak_type="${13}"
	local total_cost="${14}"
	local session_key="${15:-}"

	# Compute period summary
	local period_summary
	period_summary=$(_compute_period_summary "$routine_id")
	local routing_feedback=""
	routing_feedback=$(_routing_feedback_for_session "$session_key")

	# Build new issue body
	local new_body
	new_body=$(_build_issue_body \
		"$routine_id" \
		"$title" \
		"$schedule" \
		"$routine_type" \
		"$status_label" \
		"$now_ts" \
		"$status" \
		"$duration" \
		"$next_run" \
		"$streak_count" \
		"$streak_type" \
		"$total_cost" \
		"$period_summary" \
		"$routing_feedback")

	# Update issue description
	if gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --body "$new_body" &>/dev/null; then
		_log_success "Updated issue #${issue_number} for ${routine_id} (${status}, ${duration}s)"
	else
		_log_error "Failed to update issue #${issue_number} for ${routine_id}"
		return 1
	fi

	return 0
}

# =============================================================================
# Subcommand: update
# =============================================================================

cmd_update() {
	_parse_update_args "$@" || return 1

	local routine_id="$_UPDATE_ROUTINE_ID"
	local status="$_UPDATE_STATUS"
	local duration="$_UPDATE_DURATION"
	local tokens="$_UPDATE_TOKENS"
	local cost="$_UPDATE_COST"
	local job_id="$_UPDATE_JOB_ID"
	local session_key="$_UPDATE_SESSION_KEY"
	local outcome="$_UPDATE_OUTCOME"

	if ! command -v jq &>/dev/null; then
		_log_error "jq not found"
		return 1
	fi
	_ensure_state_dir "$routine_id"
	chmod 700 "$(_state_dir "$routine_id")"
	_append_lifecycle_log "$routine_id" "$status" "$duration" "$tokens" "$cost" "$job_id" "$session_key" "$outcome" || return 1

	# Launch and cancellation records are lifecycle evidence only. They must not
	# increment totals, streaks, costs, or completed-run summaries.
	if [[ "$status" != "success" && "$status" != "failure" ]]; then
		_log_success "Recorded ${status} lifecycle for ${routine_id}"
		return 0
	fi

	_check_prerequisites || return 1

	# Load and validate state
	local state
	state=$(_load_routine_state "$routine_id") || return 1
	local issue_number
	issue_number=$(echo "$state" | jq -r '.issue_number // empty')
	local repo_slug
	repo_slug=$(echo "$state" | jq -r '.repo_slug // empty')
	local title
	title=$(echo "$state" | jq -r '.title // "Untitled Routine"')
	local schedule
	schedule=$(echo "$state" | jq -r '.schedule // "unknown"')
	local routine_type
	routine_type=$(echo "$state" | jq -r '.routine_type // "unknown"')
	local status_label
	status_label=$(echo "$state" | jq -r '.status_label // "active"')

	# Determine cost: run: routines always show $0.00
	if [[ "$routine_type" == script* ]]; then
		cost="0.00"
		tokens="0"
	fi

	# Append to local log
	_append_local_log "$routine_id" "$status" "$duration" "$tokens" "$cost"

	# Update streak
	local streak_broke
	streak_broke=$(_update_streak "$routine_id" "$status")

	# Re-read state after streak update
	state=$(_read_state "$routine_id")
	local streak_count
	streak_count=$(echo "$state" | jq -r '.streak_count // 0')
	local streak_type
	streak_type=$(echo "$state" | jq -r '.streak_type // ""')

	# Update state with run metrics
	local now_ts
	now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local new_total_cost
	new_total_cost=$(_update_state_after_run "$routine_id" "$state" "$status" "$duration" "$cost" "$schedule" "$session_key")

	local next_run
	next_run=$(_compute_next_run "$schedule")

	# Update the tracking issue on GitHub
	_update_tracking_issue \
		"$routine_id" "$issue_number" "$repo_slug" "$title" "$schedule" \
		"$routine_type" "$status_label" "$now_ts" "$status" "$duration" \
		"$next_run" "$streak_count" "$streak_type" "$new_total_cost" "$session_key" || return 1

	# Post notable event if streak broke
	if [[ "$streak_broke" == "true" ]]; then
		cmd_notable "$routine_id" --event "Streak broken: was ${streak_count} consecutive, now ${status}"
	fi

	return 0
}

# =============================================================================
# Subcommand: refresh-description
# =============================================================================

# Rebuild and push the GitHub issue body for an existing routine using the
# current state and stored description data, without recording a new run entry.
# Use this when routine description or management text has been updated and
# the GitHub issue body should reflect the changes (GH#18616).
# Args: <routine-id>
cmd_refresh_description() {
	local routine_id=""

	if [[ $# -lt 1 ]]; then
		_log_error "Usage: routine-log-helper.sh refresh-description <routine-id>"
		return 1
	fi
	routine_id="$1"

	_check_prerequisites || return 1
	_ensure_state_dir "$routine_id"

	# Load and validate state — must have a tracking issue already
	local state
	state=$(_load_routine_state "$routine_id") || return 1

	local issue_number
	issue_number=$(echo "$state" | jq -r '.issue_number // empty')
	local repo_slug
	repo_slug=$(echo "$state" | jq -r '.repo_slug // empty')
	local title
	title=$(echo "$state" | jq -r '.title // "Untitled Routine"')
	local schedule
	schedule=$(echo "$state" | jq -r '.schedule // "unknown"')
	local routine_type
	routine_type=$(echo "$state" | jq -r '.routine_type // "unknown"')
	local status_label
	status_label=$(echo "$state" | jq -r '.status_label // "active"')
	local last_run
	last_run=$(echo "$state" | jq -r '.last_run // "never"')
	local last_status
	last_status=$(echo "$state" | jq -r '.last_status // "none"')
	local last_duration
	last_duration=$(echo "$state" | jq -r '.last_duration // 0')
	local next_run
	next_run=$(echo "$state" | jq -r '.next_run // "pending first run"')
	local streak_count
	streak_count=$(echo "$state" | jq -r '.streak_count // 0')
	local streak_type
	streak_type=$(echo "$state" | jq -r '.streak_type // ""')
	local total_cost
	total_cost=$(echo "$state" | jq -r '.total_cost // "0.00"')

	# Compute period summary from existing log — no new entry added
	local period_summary
	period_summary=$(_compute_period_summary "$routine_id")

	# Build issue body using current state; no metrics are modified
	local new_body
	new_body=$(_build_issue_body \
		"$routine_id" \
		"$title" \
		"$schedule" \
		"$routine_type" \
		"$status_label" \
		"$last_run" \
		"$last_status" \
		"$last_duration" \
		"$next_run" \
		"$streak_count" \
		"$streak_type" \
		"$total_cost" \
		"$period_summary")

	# Push updated body to GitHub
	if gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --body "$new_body" &>/dev/null; then
		_log_success "Refreshed description for issue #${issue_number} (${routine_id}) — no run entry recorded"
	else
		_log_error "Failed to refresh issue #${issue_number} for ${routine_id}"
		return 1
	fi

	return 0
}

# =============================================================================
# Subcommand: notable
# =============================================================================

cmd_notable() {
	local routine_id=""
	local event=""

	if [[ $# -lt 1 ]]; then
		_log_error "Usage: routine-log-helper.sh notable <routine-id> --event \"description\""
		return 1
	fi
	routine_id="$1"
	shift

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--event)
			event="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$event" ]]; then
		_log_error "--event is required"
		return 1
	fi

	_check_prerequisites || return 1

	local state
	state=$(_read_state "$routine_id")
	local issue_number
	issue_number=$(echo "$state" | jq -r '.issue_number // empty')
	local repo_slug
	repo_slug=$(echo "$state" | jq -r '.repo_slug // empty')

	if [[ -z "$issue_number" ]] || [[ -z "$repo_slug" ]]; then
		_log_error "No tracking issue found for ${routine_id}. Run 'create-issue' first."
		return 1
	fi

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Build comment body
	local comment_body
	comment_body="### Notable Event

**Routine:** ${routine_id}
**Time:** ${timestamp}
**Event:** ${event}"

	# Append signature footer if available
	local footer=""
	if [[ -x "${SCRIPT_DIR}/gh-signature-helper.sh" ]]; then
		footer=$("${SCRIPT_DIR}/gh-signature-helper.sh" footer 2>/dev/null || true)
	fi
	if [[ -n "$footer" ]]; then
		comment_body="${comment_body}

${footer}"
	fi

	if gh_issue_comment "$issue_number" --repo "$repo_slug" --body "$comment_body" &>/dev/null; then
		_log_success "Posted notable event on issue #${issue_number}: ${event}"
	else
		_log_error "Failed to post notable event on issue #${issue_number}"
		return 1
	fi

	return 0
}

# =============================================================================
# Subcommand: create-issue — helpers
# =============================================================================

# Parse and validate arguments for the create-issue subcommand.
# Sets _CI_* variables in caller scope.
# Returns 1 on invalid input.
_parse_create_issue_args() {
	if [[ $# -lt 1 ]]; then
		_log_error "Usage: routine-log-helper.sh create-issue <routine-id> --repo SLUG --title \"rNNN: Title\" [--schedule EXPR] [--type TYPE]"
		return 1
	fi
	_CI_ROUTINE_ID="$1"
	shift

	_CI_REPO_SLUG=""
	_CI_TITLE=""
	_CI_SCHEDULE=""
	_CI_ROUTINE_TYPE=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			_CI_REPO_SLUG="$2"
			shift 2
			;;
		--title)
			_CI_TITLE="$2"
			shift 2
			;;
		--schedule)
			_CI_SCHEDULE="$2"
			shift 2
			;;
		--type)
			_CI_ROUTINE_TYPE="$2"
			shift 2
			;;
		*)
			_log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$_CI_REPO_SLUG" ]] || [[ -z "$_CI_TITLE" ]]; then
		_log_error "--repo and --title are required"
		return 1
	fi

	# Set defaults
	[[ -z "$_CI_SCHEDULE" ]] && _CI_SCHEDULE="unknown"
	[[ -z "$_CI_ROUTINE_TYPE" ]] && _CI_ROUTINE_TYPE="unknown"

	return 0
}

# Create a GitHub issue and extract the issue number from the returned URL.
# Args: repo_slug, title, body
# Outputs the issue number to stdout. Returns 1 on failure.
_create_github_issue() {
	local repo_slug="$1"
	local title="$2"
	local body="$3"

	local issue_url
	# t2115: Use gh_create_issue wrapper for origin label + signature auto-append.
	if ! issue_url=$(gh_create_issue --repo "$repo_slug" --title "$title" --body "$body" \
		--label "routines" --label "routine-tracking" 2>&1); then
		_log_error "Failed to create issue: ${issue_url}"
		return 1
	fi

	local issue_number
	issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')

	if [[ -z "$issue_number" ]]; then
		_log_error "Could not extract issue number from: ${issue_url}"
		return 1
	fi

	echo "$issue_number"
	return 0
}

# Persist initial routine state after issue creation.
# Args: routine_id, issue_number, repo_slug, title, schedule, routine_type
_save_initial_state() {
	local routine_id="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local title="$4"
	local schedule="$5"
	local routine_type="$6"

	local state
	state=$(_read_state "$routine_id")
	state=$(echo "$state" | jq \
		--arg in "$issue_number" \
		--arg rs "$repo_slug" \
		--arg t "$title" \
		--arg s "$schedule" \
		--arg rt "$routine_type" \
		--arg sl "active" \
		--arg tc "0.00" \
		'.issue_number = $in | .repo_slug = $rs | .title = $t | .schedule = $s | .routine_type = $rt | .status_label = $sl | .total_cost = $tc')
	_write_state "$routine_id" "$state"
	return 0
}

# =============================================================================
# Subcommand: create-issue
# =============================================================================

cmd_create_issue() {
	_parse_create_issue_args "$@" || return 1

	local routine_id="$_CI_ROUTINE_ID"
	local repo_slug="$_CI_REPO_SLUG"
	local title="$_CI_TITLE"
	local schedule="$_CI_SCHEDULE"
	local routine_type="$_CI_ROUTINE_TYPE"

	_check_prerequisites || return 1
	_ensure_state_dir "$routine_id"

	# Check if issue already exists
	local existing_issue
	existing_issue=$(_get_state_field "$routine_id" "issue_number" "")
	if [[ -n "$existing_issue" ]]; then
		_log_warn "Issue #${existing_issue} already exists for ${routine_id}"
		echo "$existing_issue"
		return 0
	fi

	# Build initial issue body
	local initial_body
	initial_body=$(_build_issue_body \
		"$routine_id" \
		"$title" \
		"$schedule" \
		"$routine_type" \
		"active" \
		"never" \
		"none" \
		"0" \
		"pending first run" \
		"0" \
		"" \
		"0.00" \
		'{"total":0,"successes":0,"failures":0,"total_cost":"0.00","avg_duration":0,"period_start":"—","period_end":"—"}')

	# Create the issue on GitHub
	local issue_number
	issue_number=$(_create_github_issue "$repo_slug" "$title" "$initial_body") || return 1

	# Save state
	_save_initial_state "$routine_id" "$issue_number" "$repo_slug" "$title" "$schedule" "$routine_type"

	_log_success "Created issue #${issue_number} for ${routine_id} in ${repo_slug}"
	echo "$issue_number"
	return 0
}

# =============================================================================
# Subcommand: status
# =============================================================================

cmd_status() {
	_check_prerequisites || return 1

	# Find all routine state files
	local found=0

	printf "%-10s %-8s %-20s %-10s %-8s %-12s %s\n" \
		"ROUTINE" "ISSUE" "LAST RUN" "RESULT" "STREAK" "COST" "REPO"
	printf "%-10s %-8s %-20s %-10s %-8s %-12s %s\n" \
		"-------" "-----" "--------" "------" "------" "----" "----"

	if [[ -d "$CRON_BASE" ]]; then
		local dir
		for dir in "${CRON_BASE}"/*/; do
			[[ -d "$dir" ]] || continue
			local rid
			rid=$(basename "$dir")
			local state_file="${dir}routine-state.json"
			[[ -f "$state_file" ]] || continue

			local state
			state=$(cat "$state_file")
			local issue_number
			issue_number=$(echo "$state" | jq -r '.issue_number // "—"')
			local last_run
			last_run=$(echo "$state" | jq -r '.last_run // "never"')
			local last_status
			last_status=$(echo "$state" | jq -r '.last_status // "—"')
			local streak_count
			streak_count=$(echo "$state" | jq -r '.streak_count // 0')
			local streak_type
			streak_type=$(echo "$state" | jq -r '.streak_type // ""')
			local total_cost
			total_cost=$(echo "$state" | jq -r '.total_cost // "0.00"')
			local repo_slug
			repo_slug=$(echo "$state" | jq -r '.repo_slug // "—"')

			# Format last_run to short form
			local last_run_short
			if [[ "$last_run" == "never" ]]; then
				last_run_short="never"
			else
				last_run_short=$(echo "$last_run" | cut -c1-16 | tr 'T' ' ')
			fi

			local streak_display="${streak_count}${streak_type:0:1}"

			printf "%-10s %-8s %-20s %-10s %-8s %-12s %s\n" \
				"$rid" "#${issue_number}" "$last_run_short" "$last_status" "$streak_display" "\$${total_cost}" "$repo_slug"

			found=$((found + 1))
		done
	fi

	if [[ "$found" -eq 0 ]]; then
		echo "(no routines tracked yet)"
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'HELP'
routine-log-helper.sh — Routine execution tracking via GitHub issue descriptions

Usage:
  routine-log-helper.sh update <routine-id> --status queued|claimed|running|success|failure|deferred|cancelled [options]
    Append lifecycle evidence locally. Only success and failure update execution
    metrics, the tracking issue, streaks, and cost totals.
    Script-only routines (run:) always show $0.00 cost.

  routine-log-helper.sh notable <routine-id> --event "description"
    Post a comment on the tracking issue for notable events only.
    Examples: streak breaks, budget thresholds, configuration changes.

  routine-log-helper.sh create-issue <routine-id> --repo SLUG --title "rNNN: Title" [--schedule EXPR] [--type TYPE]
    Create the initial tracking issue with template description.
    Returns the issue number. Stores mapping in routine-state.json.

  routine-log-helper.sh refresh-description <routine-id>
    Rebuild and push the GitHub issue body using current state and stored
    description data. Does NOT record a new run entry or modify metrics.
    Use after init-routines-helper.sh refreshes a description for an
    existing routine.

  routine-log-helper.sh status
    Print summary table of all tracked routines.

  routine-log-helper.sh help
    Show this help message.

Options:
  --status STATUS             Lifecycle state (required for update)
  --duration SECONDS          Required for success/failure; defaults to 0 otherwise
  --tokens N                  Token count (optional, default 0)
  --cost AMOUNT               Cost in dollars (optional, default 0.00)
  --job-id ID                 Optional deferred-job correlation ID
  --session-key KEY           Optional headless runtime session key
  --outcome OUTCOME           Optional structured terminal outcome
  --event "description"       Notable event description (required for notable)
  --repo SLUG                 GitHub repo slug owner/repo (required for create-issue)
  --title "rNNN: Title"       Issue title (required for create-issue)
  --schedule EXPR             Schedule expression e.g. daily(@06:00) (optional)
  --type TYPE                 Routine type e.g. script or agent (optional)

Examples:
  # After a successful script execution
  routine-log-helper.sh update r001 --status success --duration 108

  # After an agent execution with cost
  routine-log-helper.sh update r002 --status success --duration 300 --tokens 5000 --cost 0.15

  # Post a notable event
  routine-log-helper.sh notable r001 --event "5 consecutive failures — check cron config"

  # Create tracking issue for a new routine
  routine-log-helper.sh create-issue r001 --repo owner/repo --title "r001: Daily Pulse" --schedule "daily(@06:00)" --type "script (scripts/pulse-wrapper.sh)"

  # View all routine statuses
  routine-log-helper.sh status

State:
  Local logs:  ~/.aidevops/.agent-workspace/cron/<routine-id>/logs/executions.jsonl
  Lifecycle:   ~/.aidevops/.agent-workspace/cron/<routine-id>/lifecycle.jsonl
  State file:  ~/.aidevops/.agent-workspace/cron/<routine-id>/routine-state.json
HELP
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	if [[ $# -lt 1 ]]; then
		cmd_help
		return 0
	fi

	local command="$1"
	shift

	case "$command" in
	update)
		cmd_update "$@"
		;;
	notable)
		cmd_notable "$@"
		;;
	refresh-description)
		cmd_refresh_description "$@"
		;;
	create-issue)
		cmd_create_issue "$@"
		;;
	status)
		cmd_status "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		_log_error "Unknown command: ${command}"
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
