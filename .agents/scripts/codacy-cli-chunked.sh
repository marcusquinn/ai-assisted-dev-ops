#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2015,SC2034,SC2086,SC2155,SC2317
set -euo pipefail

# Codacy CLI v2 Chunked Analysis Script
# Breaks down long-running analysis into manageable chunks with progress feedback
#
# Usage: ./codacy-cli-chunked.sh [command] [options]
# Commands:
#   quick       - Fast analysis with essential tools only
#   chunked     - Full analysis in chunks with progress feedback
#   tools       - List available tools and their estimated runtimes
#   analyze     - Run specific tool analysis
#   status      - Check analysis status
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Common constants
# Configuration
readonly CODACY_CONFIG_DIR=".codacy"
readonly CODACY_CONFIG_FILE="$CODACY_CONFIG_DIR/codacy.yaml"
readonly CHUNK_SIZE=5 # Number of files/tools per chunk
readonly TIMEOUT=120  # Timeout per chunk in seconds

# Tool categories with estimated runtimes
# Tool categories with estimated runtimes
TOOL_CATEGORIES_fast="shellcheck pylint pycodestyle flake8"

# Progress tracking
PROGRESS_FILE=".agents/tmp/codacy-progress.log"
TIMESTAMP_FILE=".agents/tmp/codacy-timestamp.log"

# Print functions
print_header() {
	local message="$1"
	echo -e "${PURPLE}🔍 $message${NC}"
	return 0
}

print_progress() {
	local current="$1"
	local total="$2"
	local message="${3:-Processing}"

	# Calculate percentage
	local percentage
	percentage=$((current * 100 / total))
	local bar_length=30
	local filled_length
	filled_length=$((percentage * bar_length / 100))

	# Create progress bar
	local bar=""
	for ((i = 0; i < filled_length; i++)); do
		bar+="█"
	done
	for ((i = filled_length; i < bar_length; i++)); do
		bar+="░"
	done

	echo -e "${CYAN}📊 [$bar] $percentage% - $message ($current/$total)${NC}"
	return 0
}

# Initialize progress tracking
init_progress() {
	mkdir -p "$(dirname "$PROGRESS_FILE")"
	echo "$(date -Iseconds) - Starting chunked Codacy analysis" >"$PROGRESS_FILE"
	echo "$(date -Iseconds) - Chunked analysis initiated" >"$TIMESTAMP_FILE"
	return 0
}

# Update progress
update_progress() {
	local message="$1"
	echo "$(date -Iseconds) - $message" >>"$PROGRESS_FILE"
	return 0
}

# Show current progress
show_progress() {
	if [[ -f "$PROGRESS_FILE" ]]; then
		print_header "Analysis Progress"
		cat "$PROGRESS_FILE"
		return 0
	else
		print_warning "No progress file found"
		return 1
	fi
	return 0
}

# Check if Codacy CLI is ready
check_codacy_ready() {
	if ! command -v codacy-cli &>/dev/null; then
		print_error "Codacy CLI not installed"
		return 1
	fi

	if [[ ! -f "$CODACY_CONFIG_FILE" ]]; then
		print_error "Codacy configuration not found"
		print_info "Run: bash .agents/scripts/codacy-cli.sh init"
		return 1
	fi

	# Load API key from environment (set via credentials.sh, sourced by .zshrc)
	# CODACY_PROJECT_TOKEN is the standard env var name
	if [[ -z "${CODACY_API_TOKEN:-}" && -n "${CODACY_PROJECT_TOKEN:-}" ]]; then
		export CODACY_API_TOKEN="$CODACY_PROJECT_TOKEN"
	fi

	return 0
}

# Get list of configured tools
get_configured_tools() {
	if ! command -v yq &>/dev/null; then
		print_error "yq not found. Please install: pip install yq or brew install yq"
		return 1
	fi

	local tools
	tools=$(yq eval '.tools[] | select(.) | .name' "$CODACY_CONFIG_FILE" 2>/dev/null | grep -v null)
	echo "$tools"
	return 0
}

# List available tools with categories
list_tools() {
	print_header "Available Codacy Tools"

	local tools
	tools=$(get_configured_tools)

	if [[ -z "$tools" ]]; then
		print_error "No tools configured or unable to read configuration"
		return 1
	fi

	local total_tools
	total_tools=$(echo "$tools" | wc -l | tr -d ' ')

	print_info "Total configured tools: $total_tools"
	echo ""

	# Display by categories
	local categories=("fast")
	for category in "${categories[@]}"; do
		echo "${PURPLE}📂 $category category:${NC}"
		local category_tools="$TOOL_CATEGORIES_fast"
		local found_tools=""

		while IFS= read -r tool; do
			if [[ "$category_tools" == *"$tool"* ]]; then
				found_tools="$found_tools $tool"
				print_info "  ✓ $tool"
			fi
		done <<<"$tools"

		if [[ -z "$found_tools" ]]; then
			print_warning "  (No tools from this category configured)"
		fi
		echo ""
	done

	echo "${CYAN}⏱️  Estimated runtimes:${NC}"
	print_info "  Fast tools: ~30 seconds per 100 files"
	print_info "  Medium tools: ~2 minutes per 100 files"
	print_info "  Slow tools: ~5+ minutes per 100 files"

	return 0
}

# Quick analysis with fast tools only
run_quick_analysis() {
	print_header "Running Quick Analysis (Fast Tools Only)"
	init_progress

	local fast_tools="$TOOL_CATEGORIES_fast"
	local total_tools=0
	local completed_tools=0

	# Count tools
	for tool in $fast_tools; do
		if get_configured_tools | grep -q "^$tool$"; then
			((++total_tools))
		fi
	done

	if [[ $total_tools -eq 0 ]]; then
		print_warning "No fast tools configured"
		return 1
	fi

	print_info "Running $total_tools fast tools..."

	local start_time
	start_time=$(date +%s)
	local results_file=".agents/tmp/codacy-quick-results.sarif"

	for tool in $fast_tools; do
		if get_configured_tools | grep -q "^$tool$"; then
			((++completed_tools))
			print_progress $completed_tools $total_tools "$tool"

			print_info "Running: $tool"
			update_progress "Running $tool analysis"

			local tool_start
			tool_start=$(date +%s)
			local cmd="codacy-cli analyze --tool $tool --format sarif --output .agents/tmp/codacy-$tool.sarif"

			# Run with timeout
			timeout $TIMEOUT bash -c "$cmd" 2>/dev/null
			local exit_code=$?

			local tool_end
			tool_end=$(date +%s)
			local tool_duration
			tool_duration=$((tool_end - tool_start))

			if [[ $exit_code -eq 124 ]]; then
				print_warning "⏰ $tool timed out after ${tool_duration}s"
				update_progress "$tool timed out after ${tool_duration}s"
			elif [[ $exit_code -eq 0 ]]; then
				print_success "✓ $tool completed in ${tool_duration}s"
				update_progress "$tool completed successfully in ${tool_duration}s"

				# Merge results if file exists
				if [[ -f ".agents/tmp/codacy-$tool.sarif" ]]; then
					if [[ ! -f "$results_file" ]]; then
						cp ".agents/tmp/codacy-$tool.sarif" "$results_file"
					else
						# Simple merge (in production, use proper SARIF merge)
						cat ".agents/tmp/codacy-$tool.sarif" >>"$results_file"
					fi
				fi
			else
				print_error "✗ $tool failed after ${tool_duration}s"
				update_progress "$tool failed after ${tool_duration}s"
			fi
		fi
	done

	local end_time
	end_time=$(date +%s)
	local total_duration
	total_duration=$((end_time - start_time))

	print_success "Quick analysis completed in ${total_duration}s ($completed_tools/$total_tools tools)"
	update_progress "Quick analysis completed: $completed_tools/$total_tools tools in ${total_duration}s"

	if [[ -f "$results_file" ]]; then
		print_info "Results saved to: $results_file"
		print_info "Issues found: $(grep -c '\"ruleId"' "$results_file" 2>/dev/null || echo "unknown")"
	fi

	return 0
}

# Process a single chunk of tools and merge results into the combined results file
_process_chunk() {
	local chunk_num="$1"
	local chunk_start="$2"
	local chunk_end="$3"
	local total_tools="$4"
	local results_file="$5"
	shift 5
	local tool_array=("$@")

	print_progress "$chunk_start" "$total_tools" "Processing chunk $chunk_num"
	update_progress "Starting chunk $chunk_num (tools $chunk_start-$chunk_end)"

	local chunk_tools=""
	local j
	for ((j = chunk_start - 1; j < chunk_end; j++)); do
		chunk_tools="$chunk_tools ${tool_array[j]}"
	done

	print_info "Chunk $chunk_num: Running ${tool_array[chunk_start - 1]} to ${tool_array[chunk_end - 1]}..."

	local chunk_start_time
	chunk_start_time=$(date +%s)
	local chunk_result_file=".agents/tmp/codacy-chunk-$chunk_num.sarif"

	# Run chunk with extended timeout
	local cmd="codacy-cli analyze --tools $(echo $chunk_tools | tr ' ' ',') --format sarif --output $chunk_result_file"
	print_info "Executing: $(echo $chunk_tools | wc -w | tr -d ' ') tools"

	timeout $((TIMEOUT * 2)) bash -c "$cmd" 2>/dev/null
	local exit_code=$?

	local chunk_end_time
	chunk_end_time=$(date +%s)
	local chunk_duration
	chunk_duration=$((chunk_end_time - chunk_start_time))

	if [[ $exit_code -eq 124 ]]; then
		print_warning "⏰ Chunk $chunk_num timed out after ${chunk_duration}s"
		update_progress "Chunk $chunk_num timed out"
	elif [[ $exit_code -eq 0 ]]; then
		print_success "✓ Chunk $chunk_num completed in ${chunk_duration}s"
		update_progress "Chunk $chunk_num completed in ${chunk_duration}s"
		# Merge chunk results
		if [[ -f "$chunk_result_file" ]]; then
			if [[ ! -f "$results_file" ]]; then
				cp "$chunk_result_file" "$results_file"
			else
				cat "$chunk_result_file" >>"$results_file"
			fi
		fi
	else
		print_error "✗ Chunk $chunk_num failed after ${chunk_duration}s"
		update_progress "Chunk $chunk_num failed"
	fi
	return 0
}

# Report final results summary for chunked analysis
_report_chunked_results() {
	local results_file="$1"
	local completed_tools="$2"
	local total_tools="$3"
	local total_duration="$4"

	print_success "Chunked analysis completed in ${total_duration}s ($completed_tools/$total_tools tools)"
	update_progress "Chunked analysis completed: $completed_tools/$total_tools tools in ${total_duration}s"

	if [[ -f "$results_file" ]]; then
		print_info "Results saved to: $results_file"
		local issues_count
		issues_count=$(grep -c '"ruleId"' "$results_file" 2>/dev/null || echo "unknown")
		print_info "Total issues found: $issues_count"
	fi
	return 0
}

# Chunked full analysis
run_chunked_analysis() {
	print_header "Running Chunked Full Analysis"
	init_progress

	local tools
	tools=$(get_configured_tools)

	if [[ -z "$tools" ]]; then
		print_error "No tools configured"
		return 1
	fi

	local total_tools
	total_tools=$(echo "$tools" | wc -l | tr -d ' ')
	local completed_tools=0

	print_info "Running $total_tools tools in chunks of $CHUNK_SIZE..."

	local start_time
	start_time=$(date +%s)
	local results_file=".agents/tmp/codacy-chunked-results.sarif"
	local chunk_num=1

	# Build tool array
	local tool_array=()
	while IFS= read -r tool; do
		tool_array+=("$tool")
	done <<<"$tools"

	local i
	for ((i = 0; i < ${#tool_array[@]}; i += CHUNK_SIZE)); do
		local chunk_start=$((i + 1))
		local chunk_end=$((i + CHUNK_SIZE))
		if [[ $chunk_end -gt ${#tool_array[@]} ]]; then
			chunk_end=${#tool_array[@]}
		fi

		_process_chunk "$chunk_num" "$chunk_start" "$chunk_end" \
			"$total_tools" "$results_file" "${tool_array[@]}"

		completed_tools=$chunk_end
		((++chunk_num))

		# Brief pause between chunks
		if [[ $chunk_end -lt ${#tool_array[@]} ]]; then
			print_info "Pausing briefly before next chunk..."
			sleep 2
		fi
	done

	local end_time
	end_time=$(date +%s)
	local total_duration=$((end_time - start_time))

	_report_chunked_results "$results_file" "$completed_tools" "$total_tools" "$total_duration"
	return 0
}

# Run single tool analysis
run_tool_analysis() {
	local tool="$1"

	if [[ -z "$tool" ]]; then
		print_error "Tool name required"
		print_info "Available tools:"
		get_configured_tools
		return 1
	fi

	print_header "Running Single Tool Analysis: $tool"

	if ! get_configured_tools | grep -q "^$tool$"; then
		print_error "Tool '$tool' not configured"
		return 1
	fi

	init_progress
	update_progress "Starting $tool analysis"

	local start_time
	start_time=$(date +%s)
	local result_file=".agents/tmp/codacy-$tool-single.sarif"

	local cmd="codacy-cli analyze --tool $tool --format sarif --output $result_file"
	print_info "Executing: $cmd"

	timeout $TIMEOUT bash -c "$cmd" 2>/dev/null
	local exit_code=$?

	local end_time
	end_time=$(date +%s)
	local duration
	duration=$((end_time - start_time))

	if [[ $exit_code -eq 124 ]]; then
		print_error "Analysis timed out after ${duration}s"
		update_progress "$tool analysis timed out"
		return 1
	elif [[ $exit_code -eq 0 ]]; then
		print_success "$tool analysis completed in ${duration}s"
		update_progress "$tool analysis completed successfully in ${duration}s"

		if [[ -f "$result_file" ]]; then
			print_info "Results saved to: $result_file"
			local issues
			issues=$(safe_grep_count '"ruleId"' "$result_file")
			print_info "Issues found: $issues"
		fi
		return 0
	else
		print_error "$tool analysis failed after ${duration}s"
		update_progress "$tool analysis failed"
		return 1
	fi
	return 0
}

# Show analysis status
show_status() {
	print_header "Codacy Chunked Analysis Status"

	# Show progress
	show_progress

	echo ""
	print_info "Recent Analysis Files:"
	find .agents/tmp -name "codacy-*.sarif" -newer "$TIMESTAMP_FILE" 2>/dev/null | head -5 | while read -r file; do
		local age
		age=$(find "$file" -mmin +1 2>/dev/null || echo "0")
		local size
		size=$(du -h "$file" 2>/dev/null | cut -f1 || echo "unknown")
		print_info "  $(basename "$file") (size: $size)"
	done

	echo ""
	print_info "System Status:"
	check_codacy_ready && print_success "Codacy CLI: Ready" || print_warning "Codacy CLI: Not ready"

	return 0
}

# Clean up temporary files
cleanup() {
	print_info "Cleaning up temporary files..."
	rm -f .agents/tmp/codacy-*.sarif
	rm -f "$PROGRESS_FILE" "$TIMESTAMP_FILE"
	print_success "Cleanup completed"
	return 0
}

# Show help
show_help() {
	print_header "Codacy CLI Chunked Analysis Help"
	echo ""
	echo "Usage: $0 [command] [options]"
	echo ""
	echo "Commands:"
	echo "  quick           - Fast analysis with essential tools only (~30s-2m)"
	echo "  chunked        - Full analysis in chunks with progress (~5-15m)"
	echo "  tools           - List available tools and their categories"
	echo "  analyze <tool> - Run analysis with specific tool"
	echo "  status          - Show analysis status and progress"
	echo "  cleanup         - Clean up temporary files"
	echo "  help            - Show this help message"
	echo ""
	echo "Examples:"
	echo "  $0 quick                    # Fast analysis for quick feedback"
	echo "  $0 chunked                  # Full analysis in manageable chunks"
	echo "  $0 analyze shellcheck       # Run single tool analysis"
	echo "  $0 status                   # Check progress"
	echo ""
	echo "Features:"
	echo "  • Progress tracking with timestamps"
	echo "  • Timeout protection for long-running tools"
	echo "  • Categorized tool execution"
	echo "  • Chunked processing for large repositories"
	echo "  • Detailed progress feedback"
	echo ""
	return 0
}

# Main function
main() {
	local _arg2="${2:-}"
	local command="${1:-help}"

	# Ensure temp directory exists
	mkdir -p .agents/tmp

	case "$command" in
	"quick")
		if check_codacy_ready; then
			run_quick_analysis
		else
			return 1
		fi
		;;
	"chunked")
		if check_codacy_ready; then
			run_chunked_analysis
		else
			return 1
		fi
		;;
	"tools")
		list_tools
		;;
	"analyze")
		run_tool_analysis "$_arg2"
		;;
	"status")
		show_status
		;;
	"cleanup")
		cleanup
		;;
	"help" | "--help" | "-h")
		show_help
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		show_help
		return 1
		;;
	esac
	return 0
}

# Execute main function with all arguments
main "$@"
