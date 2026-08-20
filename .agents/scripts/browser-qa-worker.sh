#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# browser-qa-worker.sh - Playwright-based visual QA for milestone validation
# Part of aidevops framework: https://aidevops.sh
#
# Launches headless Playwright, navigates pages, screenshots key views,
# checks for broken links, console errors, missing content, and empty pages.
# Can be invoked standalone or from milestone-validation-worker.sh.
#
# Usage:
#   browser-qa-worker.sh --url <base-url> [options]
#
# Required:
#   --url <url>            Base URL of the application to test
#
# Options:
#   --output-dir <dir>     Screenshot/report directory (default: managed aidevops temp workspace)
#   --flows <json>         JSON array of URLs or {url, name} objects to visit
#   --flows-file <path>    File containing flows JSON (one per line or JSON array)
#   --mission-file <path>  Read acceptance criteria from mission file for flow generation
#   --milestone <n>        Milestone number (used with --mission-file)
#   --timeout <ms>         Page load timeout in ms (default: 30000)
#   --viewport <WxH>       Viewport size (default: 1280x720)
#   --no-check-links       Disable broken link checking
#   --max-links <n>        Max links to check per page (default: 50)
#   --format <type>        Output format: json, summary (default: summary)
#   --verbose              Verbose output
#   --help                 Show this help message
#
# Exit codes:
#   0 - All QA checks passed
#   1 - QA checks failed (issues found)
#   2 - Configuration error (missing args, Playwright not installed)
#
# Examples:
#   browser-qa-worker.sh --url http://localhost:3000
#   browser-qa-worker.sh --url http://localhost:3000 --flows '["/about","/contact","/login"]'
#   browser-qa-worker.sh --url http://localhost:8080 --mission-file mission.md --milestone 1
#   browser-qa-worker.sh --url http://localhost:3000 --output-dir ./qa-results --format json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Logging
# =============================================================================

# Colors (RED, GREEN, YELLOW, BLUE, NC) provided by shared-constants.sh

_bqa_timestamp() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
	return 0
}

log_info() {
	local msg="$1"
	echo -e "[$(_bqa_timestamp)] [INFO] ${msg}"
	return 0
}

log_error() {
	local msg="$1"
	echo -e "[$(_bqa_timestamp)] ${RED}[ERROR]${NC} ${msg}" >&2
	return 0
}

log_success() {
	local msg="$1"
	echo -e "[$(_bqa_timestamp)] ${GREEN}[OK]${NC} ${msg}"
	return 0
}

log_warn() {
	local msg="$1"
	echo -e "[$(_bqa_timestamp)] ${YELLOW}[WARN]${NC} ${msg}"
	return 0
}

log_verbose() {
	local msg="$1"
	if [[ "$VERBOSE" == "true" ]]; then
		log_info "$msg"
	fi
	return 0
}

# =============================================================================
# Configuration
# =============================================================================

BASE_URL=""
OUTPUT_DIR=""
FLOWS_JSON=""
FLOWS_FILE=""
MISSION_FILE=""
MILESTONE_NUM=""
TIMEOUT=30000
VIEWPORT="1280x720"
CHECK_LINKS=true
MAX_LINKS=50
FORMAT="summary"
VERBOSE=false

# =============================================================================
# Help
# =============================================================================

show_help() {
	grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
	return 0
}

# =============================================================================
# Argument Parsing
# =============================================================================

require_value() {
	local flag="$1"
	local value="${2-}"
	if [[ -z "$value" || "$value" == --* ]]; then
		log_error "$flag requires a value"
		return 2
	fi
	return 0
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--url)
			require_value "$arg" "${2-}" || return 2
			BASE_URL="$2"
			shift 2
			;;
		--output-dir)
			require_value "$arg" "${2-}" || return 2
			OUTPUT_DIR="$2"
			shift 2
			;;
		--flows)
			require_value "$arg" "${2-}" || return 2
			FLOWS_JSON="$2"
			shift 2
			;;
		--flows-file)
			require_value "$arg" "${2-}" || return 2
			FLOWS_FILE="$2"
			shift 2
			;;
		--mission-file)
			require_value "$arg" "${2-}" || return 2
			MISSION_FILE="$2"
			shift 2
			;;
		--milestone)
			require_value "$arg" "${2-}" || return 2
			MILESTONE_NUM="$2"
			shift 2
			;;
		--timeout)
			require_value "$arg" "${2-}" || return 2
			TIMEOUT="$2"
			shift 2
			;;
		--viewport)
			require_value "$arg" "${2-}" || return 2
			VIEWPORT="$2"
			shift 2
			;;
		--no-check-links)
			CHECK_LINKS=false
			shift
			;;
		--max-links)
			require_value "$arg" "${2-}" || return 2
			MAX_LINKS="$2"
			shift 2
			;;
		--format)
			require_value "$arg" "${2-}" || return 2
			FORMAT="$2"
			shift 2
			;;
		--verbose)
			VERBOSE=true
			shift
			;;
		--help | -h)
			show_help
			exit 0
			;;
		*)
			log_error "Unknown option: $arg"
			show_help
			return 2
			;;
		esac
	done

	# Validate required args
	if [[ -z "$BASE_URL" ]]; then
		log_error "Missing required argument: --url <base-url>"
		show_help
		return 2
	fi

	# Set default output dir if not specified
	if [[ -z "$OUTPUT_DIR" ]]; then
		OUTPUT_DIR="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/browser-qa-$(date +%Y%m%d-%H%M%S)"
	fi

	return 0
}

# =============================================================================
# Prerequisites
# =============================================================================

check_prerequisites() {
	# Check for Node.js
	if ! command -v node >/dev/null 2>&1; then
		log_error "Node.js is required but not installed"
		return 2
	fi

	local runtime_script="${SCRIPT_DIR}/playwright-runtime.mjs"
	if [[ ! -f "$runtime_script" ]]; then
		log_error "Playwright runtime resolver not found: ${runtime_script}"
		return 2
	fi

	local resolved_module
	if ! resolved_module=$(node "$runtime_script" check); then
		log_error "Browser QA requires an importable Playwright package and browser binary"
		return 2
	fi
	export AIDEVOPS_PLAYWRIGHT_MODULE="$resolved_module"

	return 0
}

# =============================================================================
# Flow Generation from Mission File
# =============================================================================

# Extract flow URLs from mission file acceptance criteria.
# Looks for URLs, route patterns, and page references in the milestone section.
extract_mission_flows() {
	local mission_file="$1"
	local milestone_num="$2"
	local base_url="$3"

	if [[ ! -f "$mission_file" ]]; then
		log_warn "Mission file not found: $mission_file"
		echo "[]"
		return 0
	fi

	# Extract the milestone section and look for URL-like patterns
	local milestone_section
	milestone_section=$(awk -v mnum="$milestone_num" '
		$0 ~ "^### (Milestone |M)" mnum "[: ]" { found=1; next }
		found && /^### / { exit }
		found { print }
	' "$mission_file" 2>/dev/null || echo "")

	if [[ -z "$milestone_section" ]]; then
		log_verbose "No milestone $milestone_num section found in mission file"
		echo "[]"
		return 0
	fi

	# Extract route patterns like /about, /login, /dashboard, /api/health
	local routes
	routes=$(echo "$milestone_section" | grep -oE '(\/[a-zA-Z0-9_/-]+)' | sort -u | head -20 || echo "")

	if [[ -z "$routes" ]]; then
		log_verbose "No route patterns found in milestone section"
		echo "[]"
		return 0
	fi

	# Build JSON array of flows
	local json="["
	local first=true
	while IFS= read -r route; do
		# Skip common non-page routes
		case "$route" in
		/api/* | /node_modules/* | /.git/* | /tmp/* | /usr/* | /bin/*)
			continue
			;;
		esac
		if [[ "$first" == "true" ]]; then
			first=false
		else
			json+=","
		fi
		json+="\"$route\""
	done <<<"$routes"
	json+="]"

	echo "$json"
	return 0
}

# =============================================================================
# Main Execution
# =============================================================================

run_browser_qa() {
	local qa_script="${SCRIPT_DIR}/browser-qa/browser-qa.mjs"

	if [[ ! -f "$qa_script" ]]; then
		log_error "Browser QA script not found: $qa_script"
		return 2
	fi

	# Build the node command arguments
	local node_args=()
	node_args+=("$qa_script")
	node_args+=("$BASE_URL")
	node_args+=("--output-dir" "$OUTPUT_DIR")
	node_args+=("--timeout" "$TIMEOUT")
	node_args+=("--viewport" "$VIEWPORT")
	node_args+=("--format" "$FORMAT")
	node_args+=("--max-links" "$MAX_LINKS")

	if [[ "$CHECK_LINKS" == "false" ]]; then
		node_args+=("--no-check-links")
	fi

	# Determine flows
	local flows_arg=""

	if [[ -n "$FLOWS_JSON" ]]; then
		flows_arg="$FLOWS_JSON"
	elif [[ -n "$FLOWS_FILE" ]]; then
		if [[ ! -f "$FLOWS_FILE" ]]; then
			log_error "Flows file not found: $FLOWS_FILE"
			return 2
		fi
		flows_arg=$(cat "$FLOWS_FILE")
	elif [[ -n "$MISSION_FILE" && -n "$MILESTONE_NUM" ]]; then
		flows_arg=$(extract_mission_flows "$MISSION_FILE" "$MILESTONE_NUM" "$BASE_URL")
		if [[ "$flows_arg" == "[]" ]]; then
			log_info "No flows extracted from mission file — using default (homepage only)"
			flows_arg=""
		else
			log_info "Extracted flows from mission file: $flows_arg"
		fi
	fi

	if [[ -n "$flows_arg" ]]; then
		node_args+=("--flows" "$flows_arg")
	fi

	# Create output directory
	mkdir -p "$OUTPUT_DIR"

	log_info "Starting browser QA..."
	log_info "URL: $BASE_URL"
	log_info "Output: $OUTPUT_DIR"
	log_verbose "Viewport: $VIEWPORT"
	log_verbose "Timeout: ${TIMEOUT}ms"
	log_verbose "Check links: $CHECK_LINKS"

	# Run the Playwright QA script
	local qa_exit=0
	AIDEVOPS_PLAYWRIGHT_MODULE="$AIDEVOPS_PLAYWRIGHT_MODULE" node "${node_args[@]}" || qa_exit=$?

	case $qa_exit in
	0)
		log_success "Browser QA passed"
		;;
	1)
		log_error "Browser QA failed — issues detected"
		;;
	2)
		log_error "Browser QA configuration error"
		;;
	*)
		log_error "Browser QA exited with unexpected code: $qa_exit"
		;;
	esac

	return $qa_exit
}

# =============================================================================
# Entry Point
# =============================================================================

main() {
	local parse_exit=0
	parse_args "$@" || parse_exit=$?
	if [[ $parse_exit -ne 0 ]]; then
		return $parse_exit
	fi

	local prereq_exit=0
	check_prerequisites || prereq_exit=$?
	if [[ $prereq_exit -ne 0 ]]; then
		return $prereq_exit
	fi

	local qa_exit=0
	run_browser_qa || qa_exit=$?
	return $qa_exit
}

main "$@"
