#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2155

# Privacy Filter for Public PRs
# Mandatory filter before contributing to public repositories
#
# Usage: ./privacy-filter-helper.sh [command] [options]
# Commands:
#   scan [path]     - Scan for privacy-sensitive content
#   filter [path]   - Filter and redact sensitive content (dry-run)
#   apply [path]    - Apply redactions to files
#   patterns        - Show/edit custom privacy patterns
#   status          - Check filter configuration
#   help            - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" || true

# Colors for output (fallback if shared-constants.sh not loaded)
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${PURPLE+x}" ]] && PURPLE='\033[0;35m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'
readonly AIDEVOPS_DIR="${HOME}/.aidevops"
readonly CONFIG_DIR="${AIDEVOPS_DIR}/config"
readonly PATTERNS_FILE="${CONFIG_DIR}/privacy-patterns.txt"
readonly PROJECT_PATTERNS=".aidevops/privacy-patterns.txt"

# Default patterns to detect (regex)
readonly -a DEFAULT_PATTERNS=(
	# Email addresses
	'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
	# IP addresses (IPv4)
	'\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'
	# Local URLs with ports
	'localhost:[0-9]+'
	'127\.0\.0\.1:[0-9]+'
	'0\.0\.0\.0:[0-9]+'
	# Home directory paths
	'/Users/[a-zA-Z0-9_-]+'
	'/home/[a-zA-Z0-9_-]+'
	'C:\\Users\\[a-zA-Z0-9_-]+'
	# API keys (generic patterns)
	'sk-[a-zA-Z0-9]{20,}'
	'pk-[a-zA-Z0-9]{20,}'
	'api[_-]?key["\s:=]+[a-zA-Z0-9_-]{16,}'
	'api[_-]?secret["\s:=]+[a-zA-Z0-9_-]{16,}'
	# AWS keys
	'AKIA[0-9A-Z]{16}'
	# GitHub tokens
	'ghp_[a-zA-Z0-9]{36}'
	'gho_[a-zA-Z0-9]{36}'
	'ghu_[a-zA-Z0-9]{36}'
	'ghs_[a-zA-Z0-9]{36}'
	'ghr_[a-zA-Z0-9]{36}'
	# Private keys
	'-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'
	# Passwords in config
	'password["\s:=]+[^\s"]{8,}'
	'passwd["\s:=]+[^\s"]{8,}'
	# Bearer tokens
	'Bearer [a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'
	# JWT tokens
	'eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*'
	# Database connection strings
	'mongodb(\+srv)?://[^\s]+'
	'postgres(ql)?://[^\s]+'
	'mysql://[^\s]+'
	'redis://[^\s]+'
	# Slack tokens
	'xox[baprs]-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9-]*'
	# Discord tokens
	'[MN][A-Za-z\d]{23,}\.[\w-]{6}\.[\w-]{27}'
	# Stripe keys
	'sk_live_[0-9a-zA-Z]{24}'
	'pk_live_[0-9a-zA-Z]{24}'
	'sk_test_[0-9a-zA-Z]{24}'
	'pk_test_[0-9a-zA-Z]{24}'
	# Twilio
	'AC[a-zA-Z0-9]{32}'
	# SendGrid
	'SG\.[a-zA-Z0-9_-]{22}\.[a-zA-Z0-9_-]{43}'
)

print_success() {
	local message="$1"
	echo -e "${GREEN}[PASS]${NC} $message"
	return 0
}

print_info() {
	local message="$1"
	echo -e "${BLUE}[INFO]${NC} $message"
	return 0
}

print_warning() {
	local message="$1"
	echo -e "${YELLOW}[WARN]${NC} $message"
	return 0
}

print_error() {
	local message="$1"
	echo -e "${RED}[FAIL]${NC} $message" >&2
	return 0
}
print_header() {
	local message="$1"
	echo -e "${PURPLE}$message${NC}"
	return 0
}

print_finding() {
	local file="$1"
	local line="$2"
	local pattern="$3"
	local match="$4"
	echo -e "${CYAN}  $file:$line${NC} - $pattern"
	echo -e "    ${RED}$match${NC}"
	return 0
}

# Load custom patterns from file
load_custom_patterns() {
	local patterns_file="$1"
	local -a custom_patterns=()

	if [[ -f "$patterns_file" ]]; then
		while IFS= read -r line || [[ -n "$line" ]]; do
			# Skip comments and empty lines
			[[ "$line" =~ ^[[:space:]]*# ]] && continue
			[[ -z "${line// /}" ]] && continue
			custom_patterns+=("$line")
		done <"$patterns_file"
	fi

	printf '%s\n' "${custom_patterns[@]}"
	return 0
}

# Get all patterns (default + custom)
get_all_patterns() {
	local -a all_patterns=("${DEFAULT_PATTERNS[@]}")

	# Load global custom patterns
	if [[ -f "$PATTERNS_FILE" ]]; then
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] && all_patterns+=("$pattern")
		done < <(load_custom_patterns "$PATTERNS_FILE")
	fi

	# Load project-specific patterns
	if [[ -f "$PROJECT_PATTERNS" ]]; then
		while IFS= read -r pattern; do
			[[ -n "$pattern" ]] && all_patterns+=("$pattern")
		done < <(load_custom_patterns "$PROJECT_PATTERNS")
	fi

	printf '%s\n' "${all_patterns[@]}"
	return 0
}

# Run one Secretlint command while preserving its documented exit-status contract.
run_secretlint_command() {
	local target="$1"
	shift
	local output=""
	local status=0

	output=$("$@" "$target" 2>&1) || status=$?
	case "$status" in
	0)
		print_success "Secretlint: No secrets detected"
		return 0
		;;
	1)
		[[ -n "$output" ]] && printf '%s\n' "$output"
		print_error "Secretlint: Potential secrets found!"
		return 1
		;;
	*)
		print_warning "Secretlint unavailable: configuration or execution error (exit $status); continuing with privacy-pattern scan"
		return 0
		;;
	esac
}

# Run secretlint scan first.
run_secretlint() {
	local target="${1:-.}"

	print_header "Running Secretlint scan..."

	if command -v secretlint &>/dev/null; then
		run_secretlint_command "$target" secretlint
		return $?
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		run_secretlint_command "$target" ./node_modules/.bin/secretlint
		return $?
	fi

	# Preserve the existing on-demand fallback while applying the same exit contract.
	run_secretlint_command "$target" npx --yes secretlint
	return $?
}

# Scan for privacy-sensitive content
scan_privacy() {
	local target="${1:-.}"
	local findings=0
	local -a patterns

	print_header "Privacy Filter Scan"
	print_info "Target: $target"
	echo ""

	# First run secretlint
	if ! run_secretlint "$target"; then
		findings=$((findings + 1))
	fi
	echo ""

	# Load all patterns (bash 3.2 compatible — no mapfile)
	local patterns=()
	while IFS= read -r _line; do
		[[ -n "$_line" ]] && patterns+=("$_line")
	done < <(get_all_patterns)

	print_header "Scanning for privacy patterns..."
	print_info "Checking ${#patterns[@]} patterns"
	echo ""

	# Scan each pattern
	for pattern in "${patterns[@]}"; do
		local pattern_name="${pattern:0:40}..."

		if command -v rg &>/dev/null; then
			# Use ripgrep for pattern matching
			local matches
			matches=$(rg -n -e "$pattern" "$target" 2>/dev/null || true)

			if [[ -n "$matches" ]]; then
				print_warning "Pattern: $pattern_name"
				while IFS= read -r match; do
					local file line content
					file=$(echo "$match" | cut -d: -f1)
					line=$(echo "$match" | cut -d: -f2)
					content=$(echo "$match" | cut -d: -f3-)
					print_finding "$file" "$line" "$pattern_name" "${content:0:80}"
					findings=$((findings + 1))
				done <<<"$matches"
				echo ""
			fi
		else
			# Fallback to grep
			local matches
			matches=$(grep -rn -E "$pattern" "$target" 2>/dev/null || true)

			if [[ -n "$matches" ]]; then
				print_warning "Pattern: $pattern_name"
				while IFS= read -r match; do
					local file line content
					file=$(echo "$match" | cut -d: -f1)
					line=$(echo "$match" | cut -d: -f2)
					content=$(echo "$match" | cut -d: -f3-)
					print_finding "$file" "$line" "$pattern_name" "${content:0:80}"
					findings=$((findings + 1))
				done <<<"$matches"
				echo ""
			fi
		fi
	done

	echo ""
	print_header "Scan Summary"
	if [[ $findings -eq 0 ]]; then
		print_success "No privacy-sensitive content detected"
		return 0
	else
		print_error "Found $findings potential privacy issues"
		echo ""
		print_info "Review findings above and either:"
		print_info "  1. Remove sensitive content manually"
		print_info "  2. Add patterns to .aidevops/privacy-patterns.txt to customize"
		print_info "  3. Run 'privacy-filter-helper.sh filter' to see redaction preview"
		return 1
	fi
}

# Filter and show redactions (dry-run)
filter_preview() {
	local target="${1:-.}"
	local -a patterns

	print_header "Privacy Filter Preview (Dry Run)"
	print_info "Target: $target"
	echo ""

	# Load all patterns (bash 3.2 compatible — no mapfile)
	local patterns=()
	while IFS= read -r _line; do
		[[ -n "$_line" ]] && patterns+=("$_line")
	done < <(get_all_patterns)

	print_info "Showing what would be redacted..."
	echo ""

	# Find files with matches
	for pattern in "${patterns[@]}"; do
		local matches
		if command -v rg &>/dev/null; then
			matches=$(rg -l -e "$pattern" "$target" 2>/dev/null || true)
		else
			matches=$(grep -rl -E "$pattern" "$target" 2>/dev/null || true)
		fi

		if [[ -n "$matches" ]]; then
			while IFS= read -r file; do
				print_info "File: $file"

				# Show before/after for each match
				if command -v rg &>/dev/null; then
					rg -n -e "$pattern" "$file" 2>/dev/null | while IFS= read -r match; do
						local line content redacted
						line=$(echo "$match" | cut -d: -f1)
						content=$(echo "$match" | cut -d: -f2-)
						redacted=$(echo "$content" | sed -E "s/$pattern/[REDACTED]/g")
						echo -e "  Line $line:"
						echo -e "    ${RED}Before:${NC} ${content:0:80}"
						echo -e "    ${GREEN}After:${NC}  ${redacted:0:80}"
					done
				fi
				echo ""
			done <<<"$matches"
		fi
	done

	print_info "Run 'privacy-filter-helper.sh apply' to apply redactions"
	return 0
}

# Apply redactions to files
apply_redactions() {
	local target="${1:-.}"
	local -a patterns
	local changes=0

	print_header "Applying Privacy Redactions"
	print_warning "This will modify files in place!"
	echo ""

	read -p "Continue? [y/N] " -n 1 -r
	echo ""
	if [[ ! $REPLY =~ ^[Yy]$ ]]; then
		print_info "Aborted"
		return 1
	fi

	# Load all patterns (bash 3.2 compatible — no mapfile)
	local patterns=()
	while IFS= read -r _line; do
		[[ -n "$_line" ]] && patterns+=("$_line")
	done < <(get_all_patterns)

	# Apply redactions
	for pattern in "${patterns[@]}"; do
		local matches
		if command -v rg &>/dev/null; then
			matches=$(rg -l -e "$pattern" "$target" 2>/dev/null || true)
		else
			matches=$(grep -rl -E "$pattern" "$target" 2>/dev/null || true)
		fi

		if [[ -n "$matches" ]]; then
			while IFS= read -r file; do
				# Create backup
				cp "$file" "${file}.privacy-backup"

				# Apply redaction
				sed_inplace -E "s/$pattern/[REDACTED]/g" "$file"

				print_success "Redacted: $file"
				changes=$((changes + 1))
			done <<<"$matches"
		fi
	done

	echo ""
	if [[ $changes -eq 0 ]]; then
		print_info "No changes made"
	else
		print_success "Applied redactions to $changes files"
		print_info "Backup files created with .privacy-backup extension"
	fi
	return 0
}

# Show/edit patterns
manage_patterns() {
	local action="${1:-show}"

	case "$action" in
	show)
		print_header "Privacy Patterns"
		echo ""
		print_info "Default patterns (${#DEFAULT_PATTERNS[@]}):"
		for pattern in "${DEFAULT_PATTERNS[@]}"; do
			echo "  - ${pattern:0:60}..."
		done
		echo ""

		if [[ -f "$PATTERNS_FILE" ]]; then
			print_info "Global custom patterns ($PATTERNS_FILE):"
			cat "$PATTERNS_FILE"
		else
			print_info "No global custom patterns"
		fi
		echo ""

		if [[ -f "$PROJECT_PATTERNS" ]]; then
			print_info "Project patterns ($PROJECT_PATTERNS):"
			cat "$PROJECT_PATTERNS"
		else
			print_info "No project-specific patterns"
		fi
		;;
	add)
		local pattern="$2"
		if [[ -z "$pattern" ]]; then
			print_error "Usage: privacy-filter-helper.sh patterns add <pattern>"
			return 1
		fi

		mkdir -p "$CONFIG_DIR"
		echo "$pattern" >>"$PATTERNS_FILE"
		print_success "Added pattern to global config"
		;;
	add-project)
		local pattern="$2"
		if [[ -z "$pattern" ]]; then
			print_error "Usage: privacy-filter-helper.sh patterns add-project <pattern>"
			return 1
		fi

		mkdir -p "$(dirname "$PROJECT_PATTERNS")"
		echo "$pattern" >>"$PROJECT_PATTERNS"
		print_success "Added pattern to project config"
		;;
	edit)
		local editor="${EDITOR:-vim}"
		mkdir -p "$CONFIG_DIR"
		touch "$PATTERNS_FILE"
		"$editor" "$PATTERNS_FILE"
		;;
	edit-project)
		local editor="${EDITOR:-vim}"
		mkdir -p "$(dirname "$PROJECT_PATTERNS")"
		touch "$PROJECT_PATTERNS"
		"$editor" "$PROJECT_PATTERNS"
		;;
	*)
		print_error "Unknown patterns action: $action"
		print_info "Available: show, add, add-project, edit, edit-project"
		return 1
		;;
	esac
	return 0
}

# Check status
check_status() {
	print_header "Privacy Filter Status"
	echo ""

	# Check secretlint
	if command -v secretlint &>/dev/null; then
		print_success "Secretlint: installed ($(secretlint --version 2>/dev/null || echo 'unknown'))"
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		print_success "Secretlint: installed locally"
	else
		print_warning "Secretlint: not installed (will use npx)"
	fi

	# Check ripgrep
	if command -v rg &>/dev/null; then
		print_success "Ripgrep: installed (fast scanning)"
	else
		print_warning "Ripgrep: not installed (using grep fallback)"
	fi

	# Check patterns
	print_info "Default patterns: ${#DEFAULT_PATTERNS[@]}"

	if [[ -f "$PATTERNS_FILE" ]]; then
		local count
		count=$(safe_grep_count -v '^#' "$PATTERNS_FILE")
		print_info "Global custom patterns: $count ($PATTERNS_FILE)"
	else
		print_info "Global custom patterns: none"
	fi

	if [[ -f "$PROJECT_PATTERNS" ]]; then
		local count
		count=$(safe_grep_count -v '^#' "$PROJECT_PATTERNS")
		print_info "Project patterns: $count ($PROJECT_PATTERNS)"
	else
		print_info "Project patterns: none"
	fi

	return 0
}

# Show help
show_help() {
	cat <<'EOF'
Privacy Filter for Public PRs
==============================

Mandatory filter before contributing to public repositories.
Detects and optionally redacts privacy-sensitive content.

USAGE:
    privacy-filter-helper.sh [command] [options]

COMMANDS:
    scan [path]         Scan for privacy-sensitive content
    filter [path]       Preview redactions (dry-run)
    apply [path]        Apply redactions to files
    patterns [action]   Manage custom patterns
    status              Check filter configuration
    help                Show this help message

PATTERNS ACTIONS:
    show                Show all patterns (default)
    add <pattern>       Add pattern to global config
    add-project <pat>   Add pattern to project config
    edit                Edit global patterns file
    edit-project        Edit project patterns file

EXAMPLES:
    # Scan current directory
    privacy-filter-helper.sh scan

    # Scan specific path
    privacy-filter-helper.sh scan ./src

    # Preview what would be redacted
    privacy-filter-helper.sh filter

    # Add custom pattern
    privacy-filter-helper.sh patterns add 'mycompany\.internal'

    # Add project-specific pattern
    privacy-filter-helper.sh patterns add-project 'staging\.example\.com'

DETECTED PATTERNS:
    - Email addresses
    - IP addresses (IPv4)
    - Local URLs (localhost, 127.0.0.1)
    - Home directory paths (/Users/*, /home/*)
    - API keys (sk-*, pk-*, AKIA*, ghp_*, etc.)
    - Private keys (-----BEGIN PRIVATE KEY-----)
    - Passwords in config files
    - JWT/Bearer tokens
    - Database connection strings
    - Service-specific tokens (Slack, Discord, Stripe, etc.)

CONFIGURATION:
    Global patterns:  ~/.aidevops/config/privacy-patterns.txt
    Project patterns: .aidevops/privacy-patterns.txt

INTEGRATION:
    This filter is mandatory before creating PRs to public repositories.
    The self-improving agent system (t116) uses this filter in the PR phase.

EOF
	return 0
}

# Main entry point
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	scan)
		scan_privacy "$@"
		;;
	filter)
		filter_preview "$@"
		;;
	apply)
		apply_redactions "$@"
		;;
	patterns)
		manage_patterns "$@"
		;;
	status)
		check_status
		;;
	help | --help | -h)
		show_help
		;;
	*)
		print_error "Unknown command: $command"
		echo ""
		show_help
		return 1
		;;
	esac
}

main "$@"
