#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# foss-contribution-helper.sh — FOSS contribution budget enforcement and scanning (t1697)
#
# Manages FOSS contribution targets in repos.json with app_type classification
# and budget/etiquette controls. Enforces daily token budgets and per-repo
# rate limits before dispatching contribution workers.
#
# Architecture:
#   - repos.json: per-repo foss fields (foss, app_type, foss_config)
#   - config.jsonc: global foss budget (foss.enabled, foss.max_daily_tokens, etc.)
#   - State file: ~/.aidevops/cache/foss-contribution-state.json
#
# Usage:
#   foss-contribution-helper.sh scan [--dry-run]         Scan FOSS repos for contribution opportunities
#   foss-contribution-helper.sh check <slug>             Check if a repo is eligible for contribution
#   foss-contribution-helper.sh budget                   Show current daily token usage vs ceiling
#   foss-contribution-helper.sh record <slug> <tokens>   Record token usage for a contribution attempt
#   foss-contribution-helper.sh reset                    Reset daily token counter (for testing)
#   foss-contribution-helper.sh status                   Show all FOSS repos and their config
#   foss-contribution-helper.sh help                     Show usage
#
# State file: ~/.aidevops/cache/foss-contribution-state.json
# Config: ~/.config/aidevops/config.jsonc (foss section)
# Repos: ~/.config/aidevops/repos.json (foss fields per repo)

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

REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
CONFIG_JSONC="${HOME}/.config/aidevops/config.jsonc"
STATE_FILE="${HOME}/.aidevops/cache/foss-contribution-state.json"
LOGFILE="${HOME}/.aidevops/logs/foss-contribution.log"

# Global defaults (overridden by config.jsonc foss section)
DEFAULT_FOSS_ENABLED="true"
DEFAULT_MAX_DAILY_TOKENS=200000
DEFAULT_MAX_CONCURRENT=2

# Per-repo defaults (overridden by repos.json foss_config)
DEFAULT_MAX_PRS_PER_WEEK=2
DEFAULT_TOKEN_BUDGET_PER_ISSUE=10000
DEFAULT_DISCLOSURE=true

# Valid app_type values
VALID_APP_TYPES="wordpress-plugin php-composer node python go macos-app browser-extension cli-tool electron cloudron-package generic"

# =============================================================================
# Logging
# =============================================================================

_log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
	echo "[${timestamp}] [${level}] ${msg}" >>"$LOGFILE"
	return 0
}

_log_info() {
	_log "INFO" "$@"
	return 0
}

_log_warn() {
	_log "WARN" "$@"
	return 0
}

_log_error() {
	_log "ERROR" "$@"
	return 0
}

# =============================================================================
# Prerequisites
# =============================================================================

_check_prerequisites() {
	if ! command -v jq &>/dev/null; then
		echo -e "${RED}Error: jq not found. Install with: brew install jq${NC}" >&2
		return 1
	fi
	if [[ ! -f "$REPOS_JSON" ]]; then
		echo -e "${RED}Error: repos.json not found at ${REPOS_JSON}${NC}" >&2
		return 1
	fi
	return 0
}

# =============================================================================
# Config helpers
# =============================================================================

# Read a value from config.jsonc foss section (strips JSONC comments first)
_get_foss_config() {
	local key="$1"
	local default="$2"
	if [[ ! -f "$CONFIG_JSONC" ]]; then
		echo "$default"
		return 0
	fi
	# Strip // comments and /* */ block comments, then parse JSON
	local value
	value=$(sed 's|//.*||g; s|/\*.*\*/||g' "$CONFIG_JSONC" 2>/dev/null |
		jq -r --arg key "$key" '.foss[$key] // empty' 2>/dev/null) || value=""
	if [[ -z "$value" || "$value" == "null" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

_is_foss_enabled() {
	local enabled
	enabled=$(_get_foss_config "enabled" "$DEFAULT_FOSS_ENABLED")
	[[ "$enabled" == "true" ]]
	return $?
}

_get_max_daily_tokens() {
	_get_foss_config "max_daily_tokens" "$DEFAULT_MAX_DAILY_TOKENS"
	return 0
}

_get_max_concurrent() {
	_get_foss_config "max_concurrent_contributions" "$DEFAULT_MAX_CONCURRENT"
	return 0
}

# =============================================================================
# State file management
# =============================================================================

_ensure_state_file() {
	local state_dir
	state_dir=$(dirname "$STATE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true

	if [[ ! -f "$STATE_FILE" ]]; then
		local today
		today=$(date -u +%Y-%m-%d)
		echo "{\"date\":\"${today}\",\"daily_tokens_used\":0,\"contributions\":{}}" >"$STATE_FILE"
		_log_info "Created new state file: $STATE_FILE"
	fi
	return 0
}

_read_state() {
	_ensure_state_file
	cat "$STATE_FILE"
	return 0
}

_write_state() {
	local state="$1"
	_ensure_state_file
	echo "$state" | jq '.' >"$STATE_FILE" 2>/dev/null || {
		_log_error "Failed to write state file (invalid JSON)"
		return 1
	}
	return 0
}

# Roll over daily counter if date has changed
_ensure_daily_reset() {
	local state
	state=$(_read_state)
	local stored_date
	stored_date=$(echo "$state" | jq -r '.date // ""')
	local today
	today=$(date -u +%Y-%m-%d)

	if [[ "$stored_date" != "$today" ]]; then
		_log_info "New day detected (${stored_date} → ${today}), resetting daily token counter"
		local new_state
		new_state=$(echo "$state" | jq --arg today "$today" '.date = $today | .daily_tokens_used = 0')
		_write_state "$new_state"
	fi
	return 0
}

_get_daily_tokens_used() {
	_ensure_daily_reset
	local state
	state=$(_read_state)
	echo "$state" | jq -r '.daily_tokens_used // 0'
	return 0
}

# =============================================================================
# repos.json helpers
# =============================================================================

_get_foss_repos() {
	jq -r '.initialized_repos[] | select(.maintenance != false and (.local_only // false) == false and .foss == true) | .slug' "$REPOS_JSON" 2>/dev/null || true
	return 0
}

_get_repo_field() {
	local slug="$1"
	local field="$2"
	local default="${3:-}"
	local value
	value=$(jq -r --arg slug "$slug" --arg field "$field" \
		'.initialized_repos[] | select(.slug == $slug) | .[$field] // empty' \
		"$REPOS_JSON" 2>/dev/null) || value=""
	if [[ -z "$value" || "$value" == "null" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

_get_foss_config_field() {
	local slug="$1"
	local field="$2"
	local default="${3:-}"
	local value
	value=$(jq -r --arg slug "$slug" --arg field "$field" \
		'.initialized_repos[] | select(.slug == $slug) | .foss_config[$field] // empty' \
		"$REPOS_JSON" 2>/dev/null) || value=""
	if [[ -z "$value" || "$value" == "null" ]]; then
		echo "$default"
	else
		echo "$value"
	fi
	return 0
}

_is_blocklisted() {
	local slug="$1"
	local blocklist
	blocklist=$(_get_foss_config_field "$slug" "blocklist" "false")
	[[ "$blocklist" == "true" ]]
	return $?
}

_get_labels_filter() {
	local slug="$1"
	jq -r --arg slug "$slug" \
		'.initialized_repos[] | select(.slug == $slug) | .foss_config.labels_filter // ["help wanted", "good first issue", "bug"] | .[]' \
		"$REPOS_JSON" 2>/dev/null || echo "help wanted"
	return 0
}

# =============================================================================
# Budget enforcement
# =============================================================================

# Check if daily token budget allows a new contribution attempt
# Returns 0 (allowed) or 1 (budget exceeded)
_check_daily_budget() {
	local requested_tokens="${1:-0}"
	local max_daily
	max_daily=$(_get_max_daily_tokens)
	local used
	used=$(_get_daily_tokens_used)
	local remaining=$((max_daily - used))

	if [[ $((used + requested_tokens)) -gt $max_daily ]]; then
		_log_warn "Daily token budget exceeded: used=${used}, requested=${requested_tokens}, max=${max_daily}"
		echo -e "${YELLOW}Budget ceiling reached: ${used}/${max_daily} tokens used today.${NC}" >&2
		return 1
	fi

	_log_info "Budget check passed: used=${used}, requested=${requested_tokens}, remaining=${remaining}, max=${max_daily}"
	return 0
}

# Check per-repo weekly PR rate limit
# Returns 0 (allowed) or 1 (rate limit exceeded)
_check_weekly_pr_limit() {
	local slug="$1"
	local max_prs
	max_prs=$(_get_foss_config_field "$slug" "max_prs_per_week" "$DEFAULT_MAX_PRS_PER_WEEK")

	local state
	state=$(_read_state)
	local week_start
	week_start=$(date -u +%Y-%W)

	local prs_this_week
	prs_this_week=$(echo "$state" | jq -r --arg slug "$slug" --arg week "$week_start" \
		'.contributions[$slug].prs_by_week[$week] // 0' 2>/dev/null) || prs_this_week=0

	if [[ "$prs_this_week" -ge "$max_prs" ]]; then
		_log_warn "Weekly PR limit reached for ${slug}: ${prs_this_week}/${max_prs}"
		echo -e "${YELLOW}Weekly PR limit reached for ${slug}: ${prs_this_week}/${max_prs} PRs this week.${NC}" >&2
		return 1
	fi

	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_check() {
	local slug="$1"
	local requested_tokens="${2:-$DEFAULT_TOKEN_BUDGET_PER_ISSUE}"

	_check_prerequisites || return 1

	echo -e "${BLUE}Checking eligibility for: ${slug}${NC}"

	# 1. Is foss globally enabled?
	if ! _is_foss_enabled; then
		echo -e "${RED}BLOCKED: FOSS contributions are disabled globally (config.jsonc foss.enabled = false)${NC}"
		_log_warn "check ${slug}: foss globally disabled"
		return 1
	fi

	# 2. Is this repo registered as foss: true?
	local is_foss
	is_foss=$(_get_repo_field "$slug" "foss" "false")
	if [[ "$is_foss" != "true" ]]; then
		echo -e "${RED}BLOCKED: ${slug} is not registered as a FOSS contribution target (foss: true required)${NC}"
		_log_warn "check ${slug}: not a foss repo"
		return 1
	fi

	# 3. Is repo blocklisted?
	if _is_blocklisted "$slug"; then
		echo -e "${RED}BLOCKED: ${slug} is blocklisted (maintainer asked us to stop)${NC}"
		_log_warn "check ${slug}: blocklisted"
		return 1
	fi

	# 4. Daily token budget
	if ! _check_daily_budget "$requested_tokens"; then
		return 1
	fi

	# 5. Weekly PR rate limit
	if ! _check_weekly_pr_limit "$slug"; then
		return 1
	fi

	local app_type
	app_type=$(_get_repo_field "$slug" "app_type" "generic")
	local disclosure
	disclosure=$(_get_foss_config_field "$slug" "disclosure" "$DEFAULT_DISCLOSURE")
	local token_budget
	token_budget=$(_get_foss_config_field "$slug" "token_budget_per_issue" "$DEFAULT_TOKEN_BUDGET_PER_ISSUE")
	local max_prs
	max_prs=$(_get_foss_config_field "$slug" "max_prs_per_week" "$DEFAULT_MAX_PRS_PER_WEEK")

	echo -e "${GREEN}ELIGIBLE: ${slug}${NC}"
	echo "  app_type:              ${app_type}"
	echo "  token_budget_per_issue: ${token_budget}"
	echo "  max_prs_per_week:      ${max_prs}"
	echo "  disclosure:            ${disclosure}"
	_log_info "check ${slug}: eligible (app_type=${app_type}, budget=${token_budget})"
	return 0
}

cmd_scan() {
	local dry_run="${1:-}"
	_check_prerequisites || return 1

	if ! _is_foss_enabled; then
		echo -e "${YELLOW}FOSS contributions are disabled globally. Enable with: aidevops config set foss.enabled true${NC}"
		return 0
	fi

	local foss_repos
	foss_repos=$(_get_foss_repos)

	if [[ -z "$foss_repos" ]]; then
		echo -e "${YELLOW}No FOSS contribution targets found in repos.json (add foss: true to a repo entry)${NC}"
		return 0
	fi

	echo -e "${BLUE}Scanning FOSS contribution targets...${NC}"
	echo ""

	local eligible_count=0
	local blocked_count=0

	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue

		# Skip blocklisted repos
		if _is_blocklisted "$slug"; then
			echo -e "  ${YELLOW}SKIP${NC} ${slug} (blocklisted)"
			((blocked_count++)) || true
			continue
		fi

		local app_type
		app_type=$(_get_repo_field "$slug" "app_type" "generic")
		local labels_filter
		labels_filter=$(_get_labels_filter "$slug" | tr '\n' ',' | sed 's/,$//')
		local token_budget
		token_budget=$(_get_foss_config_field "$slug" "token_budget_per_issue" "$DEFAULT_TOKEN_BUDGET_PER_ISSUE")

		# Check budget eligibility
		if ! _check_daily_budget "$token_budget" 2>/dev/null; then
			echo -e "  ${YELLOW}SKIP${NC} ${slug} (daily budget ceiling reached)"
			((blocked_count++)) || true
			continue
		fi

		# Check weekly PR limit
		if ! _check_weekly_pr_limit "$slug" 2>/dev/null; then
			echo -e "  ${YELLOW}SKIP${NC} ${slug} (weekly PR limit reached)"
			((blocked_count++)) || true
			continue
		fi

		if [[ "$dry_run" == "--dry-run" ]]; then
			echo -e "  ${GREEN}ELIGIBLE${NC} ${slug} (app_type=${app_type}, labels=[${labels_filter}], budget=${token_budget})"
		else
			echo -e "  ${GREEN}ELIGIBLE${NC} ${slug} (app_type=${app_type}, labels=[${labels_filter}], budget=${token_budget})"
			_log_info "scan: eligible ${slug} (app_type=${app_type})"
		fi
		((eligible_count++)) || true
	done <<<"$foss_repos"

	echo ""
	echo "Summary: ${eligible_count} eligible, ${blocked_count} skipped"

	if [[ "$dry_run" == "--dry-run" ]]; then
		echo -e "${CYAN}(dry-run: no contributions dispatched)${NC}"
	fi

	return 0
}

cmd_budget() {
	_check_prerequisites || return 1
	_ensure_daily_reset

	local max_daily
	max_daily=$(_get_max_daily_tokens)
	local used
	used=$(_get_daily_tokens_used)
	local remaining=$((max_daily - used))
	local pct=0
	[[ $max_daily -gt 0 ]] && pct=$((used * 100 / max_daily))

	local enabled
	enabled=$(_get_foss_config "enabled" "$DEFAULT_FOSS_ENABLED")
	local max_concurrent
	max_concurrent=$(_get_max_concurrent)

	echo -e "${BLUE}FOSS Contribution Budget${NC}"
	echo "  Enabled:              ${enabled}"
	echo "  Max daily tokens:     ${max_daily}"
	echo "  Used today:           ${used} (${pct}%)"
	echo "  Remaining:            ${remaining}"
	echo "  Max concurrent:       ${max_concurrent}"
	echo ""

	if [[ $pct -ge 100 ]]; then
		echo -e "${RED}Budget ceiling reached — no new contributions today.${NC}"
	elif [[ $pct -ge 80 ]]; then
		echo -e "${YELLOW}Budget at ${pct}% — approaching ceiling.${NC}"
	else
		echo -e "${GREEN}Budget available.${NC}"
	fi

	return 0
}

cmd_record() {
	local slug="$1"
	local tokens="${2:-0}"

	_check_prerequisites || return 1
	_ensure_daily_reset

	local state
	state=$(_read_state)
	local today
	today=$(date -u +%Y-%m-%d)
	local week_start
	week_start=$(date -u +%Y-%W)
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# Update daily token total
	local new_state
	new_state=$(echo "$state" | jq \
		--arg slug "$slug" \
		--argjson tokens "$tokens" \
		--arg today "$today" \
		--arg week "$week_start" \
		--arg now "$now" \
		'
		.daily_tokens_used += $tokens |
		.contributions[$slug] //= {} |
		.contributions[$slug].last_attempt = $now |
		.contributions[$slug].total_tokens = ((.contributions[$slug].total_tokens // 0) + $tokens) |
		.contributions[$slug].prs_by_week //= {} |
		.contributions[$slug].prs_by_week[$week] = ((.contributions[$slug].prs_by_week[$week] // 0) + 1)
		')

	_write_state "$new_state"
	_log_info "record ${slug}: +${tokens} tokens (PR counted for week ${week_start})"
	echo -e "${GREEN}Recorded: ${tokens} tokens for ${slug}${NC}"
	return 0
}

cmd_reset() {
	_ensure_state_file
	local today
	today=$(date -u +%Y-%m-%d)
	local new_state="{\"date\":\"${today}\",\"daily_tokens_used\":0,\"contributions\":{}}"
	_write_state "$new_state"
	_log_info "reset: daily token counter cleared"
	echo -e "${GREEN}Daily token counter reset.${NC}"
	return 0
}

cmd_status() {
	_check_prerequisites || return 1
	_ensure_daily_reset

	local foss_repos
	foss_repos=$(_get_foss_repos)

	if [[ -z "$foss_repos" ]]; then
		echo -e "${YELLOW}No FOSS contribution targets registered in repos.json${NC}"
		echo ""
		echo "To register a FOSS repo, add to repos.json:"
		echo '  { "slug": "owner/repo", "foss": true, "app_type": "node", "foss_config": { ... } }'
		return 0
	fi

	local state
	state=$(_read_state)
	local used
	used=$(echo "$state" | jq -r '.daily_tokens_used // 0')
	local max_daily
	max_daily=$(_get_max_daily_tokens)

	echo -e "${BLUE}FOSS Contribution Targets${NC}"
	echo "Daily budget: ${used}/${max_daily} tokens used"
	echo ""
	printf "%-40s %-20s %-10s %-8s %-10s %s\n" "SLUG" "APP_TYPE" "BLOCKLIST" "MAX_PRS" "BUDGET" "LABELS"
	printf "%-40s %-20s %-10s %-8s %-10s %s\n" "----" "--------" "---------" "-------" "------" "------"

	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		local app_type
		app_type=$(_get_repo_field "$slug" "app_type" "generic")
		local blocklist
		blocklist=$(_get_foss_config_field "$slug" "blocklist" "false")
		local max_prs
		max_prs=$(_get_foss_config_field "$slug" "max_prs_per_week" "$DEFAULT_MAX_PRS_PER_WEEK")
		local token_budget
		token_budget=$(_get_foss_config_field "$slug" "token_budget_per_issue" "$DEFAULT_TOKEN_BUDGET_PER_ISSUE")
		local labels
		labels=$(_get_labels_filter "$slug" | tr '\n' ',' | sed 's/,$//')

		local status_icon="${GREEN}OK${NC}"
		[[ "$blocklist" == "true" ]] && status_icon="${RED}BLOCKED${NC}"

		printf "%-40s %-20s " "$slug" "$app_type"
		echo -ne "${status_icon}"
		printf "     %-8s %-10s %s\n" "$max_prs" "$token_budget" "$labels"
	done <<<"$foss_repos"

	return 0
}

cmd_help() {
	cat <<'EOF'
foss-contribution-helper.sh — FOSS contribution budget enforcement (t1697)

Usage:
  foss-contribution-helper.sh scan [--dry-run]         Scan FOSS repos for contribution opportunities
  foss-contribution-helper.sh check <slug> [tokens]    Check if a repo is eligible for contribution
  foss-contribution-helper.sh budget                   Show current daily token usage vs ceiling
  foss-contribution-helper.sh record <slug> <tokens>   Record token usage for a contribution attempt
  foss-contribution-helper.sh reset                    Reset daily token counter (for testing)
  foss-contribution-helper.sh status                   Show all FOSS repos and their config
  foss-contribution-helper.sh help                     Show this help

repos.json FOSS fields:
  foss: true                      Mark repo as a FOSS contribution target
  app_type: <type>                App type (see below)
  foss_config:
    max_prs_per_week: 2           Max PRs to open per week (default: 2)
    token_budget_per_issue: 10000 Max tokens per contribution attempt (default: 10000)
    blocklist: false              Set true if maintainer asked us to stop
    disclosure: true              Include AI assistance note in PRs (default: true)
    labels_filter: [...]          Labels to scan for (default: ["help wanted", "good first issue", "bug"])

Valid app_type values:
  wordpress-plugin  php-composer  node  python  go
  macos-app  browser-extension  cli-tool  electron
  cloudron-package  generic

Global config (config.jsonc foss section):
  foss.enabled: true                    Enable/disable all FOSS contributions
  foss.max_daily_tokens: 200000         Daily token ceiling across all repos
  foss.max_concurrent_contributions: 2  Max simultaneous contribution workers

Examples:
  foss-contribution-helper.sh scan --dry-run
  foss-contribution-helper.sh check owner/repo 8000
  foss-contribution-helper.sh budget
  foss-contribution-helper.sh record owner/repo 7500
  foss-contribution-helper.sh status
EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	scan)
		cmd_scan "${1:-}"
		;;
	check)
		if [[ -z "${1:-}" ]]; then
			echo -e "${RED}Error: slug required. Usage: foss-contribution-helper.sh check <slug> [tokens]${NC}" >&2
			return 1
		fi
		cmd_check "$1" "${2:-$DEFAULT_TOKEN_BUDGET_PER_ISSUE}"
		;;
	budget)
		cmd_budget
		;;
	record)
		if [[ -z "${1:-}" || -z "${2:-}" ]]; then
			echo -e "${RED}Error: Usage: foss-contribution-helper.sh record <slug> <tokens>${NC}" >&2
			return 1
		fi
		cmd_record "$1" "$2"
		;;
	reset)
		cmd_reset
		;;
	status)
		cmd_status
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo -e "${RED}Unknown command: ${cmd}${NC}" >&2
		cmd_help >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
