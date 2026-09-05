#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# MCP Registration Script for Claude Code
# Reads configs/mcp-templates/*.json and registers MCP servers via `claude mcp add-json`.
# Extracts claude_code_command / claude_code_manual / claude_code_cli / claude_code
# entries from template files, or auto-generates from mcpServers structure.
#
# Usage:
#   mcp-register-claude.sh [options] [template...]
#
# Options:
#   --dry-run       Show commands without executing
#   --scope <scope> Override scope (user, local, project). Default: user
#   --force         Re-register even if already registered
#   --list          List available templates and their registration status
#   --skip <name>   Skip specific template (repeatable)
#   --help          Show this help
#
# Examples:
#   mcp-register-claude.sh                    # Register all templates
#   mcp-register-claude.sh --dry-run          # Preview all commands
#   mcp-register-claude.sh --list             # Show status
#   mcp-register-claude.sh --skip quickfile   # Skip templates with placeholders

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit

source "${SCRIPT_DIR}/shared-constants.sh"

# Defaults
DRY_RUN=false
SCOPE="user"
FORCE=false
LIST_MODE=false
declare -a SKIP_LIST=()
declare -a TARGETS=()
TEMPLATE_DIR="${REPO_ROOT}/configs/mcp-templates"

# Templates to always skip (meta-configs, aggregates)
DEFAULT_SKIP=("complete-mcp-config")

# Counters
declare -i registered=0
declare -i skipped=0
declare -i failed=0
declare -i already=0

usage() {
	local script_name
	script_name="$(basename "$0")"
	cat <<EOF
Usage: ${script_name} [options] [template...]

Register MCP servers with Claude Code from configs/mcp-templates/ JSON files.

Options:
  --dry-run       Show commands without executing
  --scope <scope> Override scope (user, local, project). Default: user
  --force         Re-register even if already registered
  --list          List available templates and their registration status
  --skip <name>   Skip specific template (repeatable)
  --help          Show this help

Templates are matched by filename stem (e.g. 'context7' matches context7.json).
If no templates specified, all templates with claude_code_command entries are processed.
EOF
	return 0
}

# Parse arguments
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--scope)
			SCOPE="${2:-user}"
			shift 2
			;;
		--force)
			FORCE=true
			shift
			;;
		--list)
			LIST_MODE=true
			shift
			;;
		--skip)
			SKIP_LIST+=("${2:-}")
			shift 2
			;;
		--help | -h)
			usage
			exit 0
			;;
		-*)
			print_error "Unknown option: $1"
			usage
			exit 1
			;;
		*)
			TARGETS+=("$1")
			shift
			;;
		esac
	done
	return 0
}

# Check if claude CLI is available
check_claude_cli() {
	if ! command -v claude &>/dev/null; then
		print_error "claude CLI not found. Install Claude Code first."
		exit 1
	fi
	return 0
}

# Get list of currently registered MCP server names
get_registered_servers() {
	local servers
	# claude mcp list outputs lines like: "name: command - status"
	servers=$(claude mcp list | grep -oE '^\S+:' | sed 's/:$//' || true)
	echo "$servers"
	return 0
}

# Check if a server name is already registered
is_registered() {
	local name="$1"
	local registered_list="$2"
	echo "$registered_list" | grep -qx "$name"
	return $?
}

# Check if a template should be skipped
should_skip() {
	local template_stem="$1"
	# Check default skip list
	local skip_name
	for skip_name in "${DEFAULT_SKIP[@]}"; do
		if [[ "$template_stem" == "$skip_name" ]]; then
			return 0
		fi
	done
	# Check user skip list
	if [[ ${#SKIP_LIST[@]} -gt 0 ]]; then
		for skip_name in "${SKIP_LIST[@]}"; do
			if [[ "$template_stem" == *"$skip_name"* ]]; then
				return 0
			fi
		done
	fi
	return 1
}

# Check if template matches any target filter
matches_target() {
	local template_stem="$1"
	# No targets = match all
	if [[ ${#TARGETS[@]} -eq 0 ]]; then
		return 0
	fi
	local target
	for target in "${TARGETS[@]}"; do
		if [[ "$template_stem" == *"$target"* ]]; then
			return 0
		fi
	done
	return 1
}

# Extract claude_code_command string from a template JSON file.
# Checks keys: claude_code_command, claude_code_manual, claude_code_cli, claude_code (string only)
# Returns the command string or empty.
extract_command() {
	local template_file="$1"

	# Try each key variant in priority order
	local key
	for key in "claude_code_command" "claude_code_manual" "claude_code_cli" "claude_code"; do
		local value
		value=$(python3 -c "
import json, sys
with open('$template_file') as f:
    data = json.load(f)
val = data.get('$key', None)
if isinstance(val, str) and val.startswith('claude mcp'):
    print(val)
" || true)
		if [[ -n "$value" ]]; then
			echo "$value"
			return 0
		fi
	done

	return 1
}

# Auto-generate a claude mcp add-json command from mcpServers structure.
# Only works for simple stdio servers with command/args.
generate_command_from_mcpservers() {
	local template_file="$1"

	python3 -c "
import json, sys

with open('$template_file') as f:
    data = json.load(f)

servers = data.get('mcpServers', {})
if not servers:
    # Try claude_desktop.mcpServers
    cd = data.get('claude_desktop', {})
    servers = cd.get('mcpServers', {})

if not servers:
    sys.exit(1)

for name, config in servers.items():
    # Skip non-dict entries
    if not isinstance(config, dict):
        continue
    # Build stdio JSON
    cmd = config.get('command', '')
    args = config.get('args', [])
    env = config.get('env', {})
    url = config.get('url', '')

    if url:
        # HTTP/SSE server
        entry = {'type': 'http', 'url': url}
        print(f'claude mcp add-json {name} ' + \"'\" + json.dumps(entry, separators=(',', ':')) + \"'\")
    elif cmd:
        entry = {'type': 'stdio', 'command': cmd, 'args': args}
        if env:
            entry['env'] = env
        print(f'claude mcp add-json {name} ' + \"'\" + json.dumps(entry, separators=(',', ':')) + \"'\")
    # Only generate for the first server entry
    break
" || true
	return 0
}

# Extract the MCP server name from a command string.
# Handles: claude mcp add-json <name> ...
#           claude mcp add [--flag value]... <name> ...
extract_server_name() {
	local cmd="$1"

	# Strip everything from the first single-quote onward (JSON payload)
	local stripped="${cmd%%\'*}"

	# Split into words and find the name after add/add-json, skipping --flag value pairs
	local -a words
	read -ra words <<<"$stripped"

	# Known claude mcp flags that take a value argument
	local -a flags_with_value=("--scope" "--transport")

	local found_subcmd=false
	local skip_next=false
	local i=0
	while [[ $i -lt ${#words[@]} ]]; do
		local word="${words[$i]}"
		i=$((i + 1))
		if [[ "$found_subcmd" != true ]]; then
			if [[ "$word" == "add-json" ]] || [[ "$word" == "add" ]]; then
				found_subcmd=true
			fi
			continue
		fi
		# Skip value of a flag we consumed on the previous iteration
		if [[ "$skip_next" == true ]]; then
			skip_next=false
			continue
		fi
		# Handle --flag=value (skip entirely)
		if [[ "$word" == --*=* ]]; then
			continue
		fi
		# Handle --flag value (known flags with a value)
		if [[ "$word" == --* ]]; then
			local flag
			for flag in "${flags_with_value[@]}"; do
				if [[ "$word" == "$flag" ]]; then
					skip_next=true
					break
				fi
			done
			# Unknown flags (e.g. --force) are skipped without consuming next word
			continue
		fi
		# First non-flag word is the server name
		echo "$word"
		return 0
	done

	return 1
}

# Detect if a command contains placeholder values that need user customization
has_placeholders() {
	local cmd="$1"
	# Common placeholder patterns
	if [[ "$cmd" == *"/path/to/"* ]] ||
		[[ "$cmd" == *"your_"*"_here"* ]] ||
		[[ "$cmd" == *"your-"*"-here"* ]] ||
		[[ "$cmd" == *"YOUR_"* ]] ||
		[[ "$cmd" == *"/Users/YOU/"* ]]; then
		return 0
	fi
	return 1
}

# Normalize scope in a command to match the requested scope
normalize_scope() {
	local cmd="$1"
	local target_scope="$2"

	# If command already has --scope, replace it
	if [[ "$cmd" == *"--scope "* ]]; then
		cmd=$(echo "$cmd" | sed "s/--scope [a-z]*/--scope ${target_scope}/")
	# If it's an add-json command without --scope, add it
	elif [[ "$cmd" == *"add-json"* ]] && [[ "$cmd" != *"--scope"* ]]; then
		cmd=$(echo "$cmd" | sed "s/add-json \([^ ]*\)/add-json \1 --scope ${target_scope}/")
	fi

	echo "$cmd"
	return 0
}

# Execute or display a registration command
run_command() {
	local cmd="$1"
	local template_name="$2"

	if [[ "$DRY_RUN" == true ]]; then
		echo "  ${cmd}"
		((++registered))
		return 0
	fi

	# Split command into prefix args and JSON payload (avoiding eval for security)
	local prefix="${cmd%%\'*}"
	local json_payload="${cmd#*\'}"
	json_payload="${json_payload%\'*}" # Strip trailing quote

	local -a cmd_parts
	read -ra cmd_parts <<<"$prefix"

	if "${cmd_parts[@]}" "$json_payload"; then
		print_success "${template_name}: registered"
		((++registered))
	else
		print_error "${template_name}: registration failed"
		((++failed))
	fi
	return 0
}

# List mode: show all templates and their status
list_templates() {
	local registered_list
	registered_list=$(get_registered_servers)

	printf "%-35s %-20s %s\n" "TEMPLATE" "SERVER NAME" "STATUS"
	printf "%-35s %-20s %s\n" "--------" "-----------" "------"

	for template_file in "${TEMPLATE_DIR}"/*.json; do
		[[ -f "$template_file" ]] || continue
		local stem
		stem=$(basename "$template_file" .json)

		local cmd
		cmd=$(extract_command "$template_file" || true)
		if [[ -z "$cmd" ]]; then
			cmd=$(generate_command_from_mcpservers "$template_file" || true)
		fi

		if [[ -z "$cmd" ]]; then
			printf "%-35s %-20s %s\n" "$stem" "-" "no command"
			continue
		fi

		local server_name
		server_name=$(extract_server_name "$cmd" || true)
		[[ -z "$server_name" ]] && server_name="?"

		local status="not registered"
		if is_registered "$server_name" "$registered_list"; then
			status="registered"
		fi

		if has_placeholders "$cmd"; then
			status="${status} (has placeholders)"
		fi

		printf "%-35s %-20s %s\n" "$stem" "$server_name" "$status"
	done
	return 0
}

# Main registration logic
register_all() {
	local registered_list
	registered_list=$(get_registered_servers)

	if [[ "$DRY_RUN" == true ]]; then
		print_info "Dry run — commands will be shown but not executed"
		echo
	fi

	for template_file in "${TEMPLATE_DIR}"/*.json; do
		[[ -f "$template_file" ]] || continue
		local stem
		stem=$(basename "$template_file" .json)

		# Filter by target
		if ! matches_target "$stem"; then
			continue
		fi

		# Check skip list (includes default skips)
		if should_skip "$stem"; then
			((++skipped))
			continue
		fi

		# Extract command
		local cmd
		cmd=$(extract_command "$template_file" || true)
		if [[ -z "$cmd" ]]; then
			cmd=$(generate_command_from_mcpservers "$template_file" || true)
		fi

		if [[ -z "$cmd" ]]; then
			((++skipped))
			continue
		fi

		# Skip commands with placeholders (unless forced)
		if has_placeholders "$cmd" && [[ "$FORCE" != true ]]; then
			print_warning "${stem}: skipped (contains placeholders — use --force to override)"
			((++skipped))
			continue
		fi

		# Extract server name for duplicate check
		local server_name
		server_name=$(extract_server_name "$cmd" || true)

		# Check if already registered
		if [[ -n "$server_name" ]] && is_registered "$server_name" "$registered_list" && [[ "$FORCE" != true ]]; then
			print_info "${stem}: already registered as '${server_name}'"
			((++already))
			continue
		fi

		# Normalize scope
		cmd=$(normalize_scope "$cmd" "$SCOPE")

		# Execute
		run_command "$cmd" "$stem"
	done

	echo
	if [[ "$DRY_RUN" == true ]]; then
		print_info "Dry run summary: ${registered} would register, ${skipped} skipped, ${already} already registered"
	else
		print_info "Summary: ${registered} registered, ${skipped} skipped, ${already} already registered, ${failed} failed"
	fi
	return 0
}

main() {
	parse_args "$@"

	check_claude_cli

	if [[ ! -d "$TEMPLATE_DIR" ]]; then
		print_error "Template directory not found: ${TEMPLATE_DIR}"
		exit 1
	fi

	if [[ "$LIST_MODE" == true ]]; then
		list_templates
	else
		register_all
	fi

	return 0
}

main "$@"
