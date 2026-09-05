#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# MCP Config Adapter — Universal MCP Definition → Per-Runtime Config
#
# Transforms a universal MCP server definition (JSON: command, args, env) into
# the config format required by each AI coding assistant runtime.
#
# Supported formats:
#   opencode     — JSON (.mcp key, command array, "environment")
#   claude       — CLI (claude mcp add-json NAME --scope user 'JSON')
#   codex        — TOML ([mcp_servers.NAME] in ~/.codex/config.toml)
#   cursor       — JSON (mcpServers in ~/.cursor/mcp.json)
#   windsurf     — JSON (mcpServers in ~/.codeium/windsurf/mcp_config.json)
#   gemini       — JSON (mcpServers in ~/.gemini/settings.json)
#   kilo         — JSON (mcpServers in ~/.kilo/mcp.json)
#   kiro         — JSON (mcpServers in ~/.kiro/mcp.json)
#   droid        — CLI (droid mcp add NAME ...)
#   continue     — JSON array (mcpServers array in ~/.continue/config.json)
#   aider        — YAML (mcpServers in ~/.aider.conf.yml)
#
# Universal MCP definition format (JSON):
#   {
#     "command": "npx",
#     "args": ["-y", "@example/mcp@latest"],
#     "env": {"API_KEY": "your-key"},
#     "transport": "stdio",
#     "enabled": true
#   }
#
# Usage:
#   mcp-config-adapter.sh register <runtime> <name> '<json>'
#   mcp-config-adapter.sh register-all <name> '<json>'
#   mcp-config-adapter.sh list-runtimes
#   mcp-config-adapter.sh help
#
# Can also be sourced as a library:
#   source mcp-config-adapter.sh
#   register_mcp_for_runtime "opencode" "my-mcp" '{"command":"echo","args":["hi"]}'
#
# Part of t1665 (Runtime abstraction layer), subtask t1665.2.
# Depends on: json_set_nested / json_append_to_array from ai-cli-config.sh
# Stubs: detect_installed_runtimes (will be replaced by runtime-registry.sh from t1665.1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Source shared constants for print_info/print_warning/print_success/print_error
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Source JSON helpers from ai-cli-config.sh (json_set_nested, json_append_to_array)
# shellcheck source=ai-cli-config.sh
source "${SCRIPT_DIR}/ai-cli-config.sh"

_mcp_adapter_kill_timeout_target() {
	local child_pid="$1"
	local child_pgid="$2"
	local kill_after_seconds="$3"
	local self_pgid=""
	local signal_target="$child_pid"
	[[ -n "$child_pid" ]] || return 0

	self_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')" || true
	if [[ -n "$child_pgid" && -n "$self_pgid" && "$child_pgid" != "$self_pgid" ]]; then
		signal_target="-${child_pgid}"
	fi

	if ! kill -0 -- "$signal_target" 2>/dev/null; then
		return 0
	fi

	kill -TERM -- "$signal_target" 2>/dev/null || true
	sleep "$kill_after_seconds"
	if kill -0 -- "$signal_target" 2>/dev/null; then
		kill -KILL -- "$signal_target" 2>/dev/null || true
	fi
	return 0
}

_mcp_adapter_timeout_watchdog() {
	local timeout_seconds="$1"
	local child_pid="$2"
	local child_pgid="$3"
	local kill_after_seconds="$4"
	local timeout_marker="$5"

	sleep "$timeout_seconds"
	if kill -0 "$child_pid" 2>/dev/null; then
		printf 'timed-out\n' >"$timeout_marker"
		_mcp_adapter_kill_timeout_target "$child_pid" "$child_pgid" "$kill_after_seconds"
	fi
	return 0
}

_mcp_adapter_timeout_cleanup() {
	local watchdog_pid="$1"
	local child_pid="$2"
	local child_pgid="$3"
	local kill_after_seconds="$4"
	local timeout_marker="$5"

	if [[ -n "$watchdog_pid" ]]; then
		kill "$watchdog_pid" 2>/dev/null || true
		wait "$watchdog_pid" 2>/dev/null || true
	fi
	_mcp_adapter_kill_timeout_target "$child_pid" "$child_pgid" "$kill_after_seconds"
	wait "$child_pid" 2>/dev/null || true
	rm -f "$timeout_marker"
	return 0
}

_mcp_adapter_run_with_timeout() (
	local timeout_seconds="$1"
	shift
	local kill_after_seconds="${AIDEVOPS_MCP_TIMEOUT_KILL_AFTER_SECONDS:-2}"
	local timeout_marker=""
	local child_pid=""
	local child_pgid=""
	local watchdog_pid=""
	local command_status=0
	local monitor_was_enabled=false

	timeout_marker="$(mktemp "${TMPDIR:-/tmp}/aidevops-mcp-timeout.XXXXXX")"
	trap '_mcp_adapter_timeout_cleanup "$watchdog_pid" "$child_pid" "$child_pgid" "$kill_after_seconds" "$timeout_marker"' EXIT

	if command -v setsid >/dev/null 2>&1; then
		setsid "$@" &
		child_pid=$!
		child_pgid="$child_pid"
	else
		# Bash job control gives a background command its own process group on
		# macOS systems where setsid is unavailable. Restore the caller's mode
		# immediately after launch so sourcing this adapter has no lasting effect.
		[[ $- == *m* ]] && monitor_was_enabled=true
		set -m
		"$@" &
		child_pid=$!
		child_pgid="$child_pid"
		$monitor_was_enabled && set -m || set +m
	fi

	_mcp_adapter_timeout_watchdog "$timeout_seconds" "$child_pid" "$child_pgid" "$kill_after_seconds" "$timeout_marker" &
	watchdog_pid=$!

	if wait "$child_pid"; then
		command_status=0
	else
		command_status=$?
	fi

	if [[ -s "$timeout_marker" ]]; then
		wait "$watchdog_pid" 2>/dev/null || true
		return 124
	fi

	kill "$watchdog_pid" 2>/dev/null || true
	wait "$watchdog_pid" 2>/dev/null || true
	return "$command_status"
)

_MCP_ADAPTER_CLAUDE_EXISTING_CACHE=""
_MCP_ADAPTER_CLAUDE_LIST_STATUS_CACHE=""
_MCP_ADAPTER_CLAUDE_LIST_READY=false

_mcp_adapter_reset_claude_registration_cache() {
	_MCP_ADAPTER_CLAUDE_EXISTING_CACHE=""
	_MCP_ADAPTER_CLAUDE_LIST_STATUS_CACHE=""
	_MCP_ADAPTER_CLAUDE_LIST_READY=false
	return 0
}

_mcp_adapter_prepare_claude_registration() {
	local claude_timeout_seconds="$1"
	local existing=""
	local list_status=0

	if [[ "${_MCP_ADAPTER_CLAUDE_LIST_READY:-false}" == true ]]; then
		return 0
	fi

	existing=$(_mcp_adapter_run_with_timeout "$claude_timeout_seconds" claude mcp list 2>/dev/null) || list_status=$?
	_MCP_ADAPTER_CLAUDE_EXISTING_CACHE="$existing"
	_MCP_ADAPTER_CLAUDE_LIST_STATUS_CACHE="$list_status"
	_MCP_ADAPTER_CLAUDE_LIST_READY=true

	if [[ "$list_status" -ne 0 ]]; then
		print_warning "Claude Code MCP list timed out or failed — skipping Claude MCP registration pass"
	fi
	return 0
}

_mcp_adapter_claude_existing_contains() {
	local mcp_name="$1"
	local existing="$2"
	local line

	while IFS= read -r line; do
		if [[ "${line%%:*}" == "$mcp_name" ]]; then
			return 0
		fi
	done <<<"$existing"
	return 1
}

_mcp_adapter_claude_cache_mark_registered() {
	local mcp_name="$1"

	if [[ -z "${_MCP_ADAPTER_CLAUDE_EXISTING_CACHE:-}" ]]; then
		_MCP_ADAPTER_CLAUDE_EXISTING_CACHE="${mcp_name}:"
	else
		_MCP_ADAPTER_CLAUDE_EXISTING_CACHE+=$'\n'"${mcp_name}:"
	fi
	return 0
}

# =============================================================================
# Runtime Detection Stub (t1665.1 — will be replaced by runtime-registry.sh)
# =============================================================================
# These stubs provide the minimal interface this adapter needs from the runtime
# registry. Only defined if runtime-registry.sh hasn't been sourced yet.

# When runtime-registry.sh is loaded, define thin wrappers so the adapter's
# public API (detect_installed_runtimes, get_runtime_display_name) is always
# available. When standalone, define self-contained stubs.
if declare -f rt_detect_installed >/dev/null 2>&1; then
	# Registry loaded — bridge adapter API → registry API
	# shellcheck disable=SC2120
	detect_installed_runtimes() { rt_detect_installed; }
	get_runtime_display_name() { rt_display_name "$@"; }
else
	# No registry — self-contained stubs
	detect_installed_runtimes() {
		# OpenCode
		if [[ -d "$HOME/.config/opencode" ]] || command -v opencode >/dev/null 2>&1; then
			echo "opencode"
		fi
		# Claude Code (ID: claude-code, binary: claude)
		if command -v claude >/dev/null 2>&1; then
			echo "claude-code"
		fi
		# Codex
		if [[ -d "${CODEX_HOME:-$HOME/.codex}" ]] || command -v codex >/dev/null 2>&1; then
			echo "codex"
		fi
		# Cursor
		if [[ -d "$HOME/.cursor" ]] || command -v cursor >/dev/null 2>&1; then
			echo "cursor"
		fi
		# Windsurf
		if [[ -d "$HOME/.codeium/windsurf" ]] || command -v windsurf >/dev/null 2>&1; then
			echo "windsurf"
		fi
		# Gemini CLI (ID: gemini-cli, binary: gemini)
		if [[ -d "$HOME/.gemini" ]] || command -v gemini >/dev/null 2>&1; then
			echo "gemini-cli"
		fi
		# Kilo Code
		if [[ -d "$HOME/.kilo" ]]; then
			echo "kilo"
		fi
		# Kiro
		if [[ -d "$HOME/.kiro" ]]; then
			echo "kiro"
		fi
		# Droid (Factory.AI)
		if command -v droid >/dev/null 2>&1; then
			echo "droid"
		fi
		# Continue.dev — 'continue' is a bash builtin, use type -P for filesystem search
		if [[ -d "$HOME/.continue" ]] || type -P continue >/dev/null 2>&1; then
			echo "continue"
		fi
		# Aider
		if command -v aider >/dev/null 2>&1 || [[ -f "$HOME/.aider.conf.yml" ]]; then
			echo "aider"
		fi
		return 0
	}

	get_runtime_display_name() {
		local runtime_id="$1"
		case "$runtime_id" in
		opencode) echo "OpenCode" ;;
		claude-code) echo "Claude Code" ;;
		codex) echo "Codex CLI" ;;
		cursor) echo "Cursor" ;;
		windsurf) echo "Windsurf" ;;
		gemini-cli) echo "Gemini CLI" ;;
		kilo) echo "Kilo Code" ;;
		kiro) echo "Kiro" ;;
		droid) echo "Droid (Factory.AI)" ;;
		continue) echo "Continue.dev" ;;
		aider) echo "Aider" ;;
		*) echo "$runtime_id" ;;
		esac
		return 0
	}
fi

# =============================================================================
# Command Validation
# =============================================================================

# Validate that the command binary exists on the system.
# Returns 0 if valid, 1 if missing.
validate_mcp_command() {
	local mcp_json="$1"
	local cmd

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — skipping command validation"
		return 0
	fi

	# URL-based (remote) MCPs have no command to validate
	local url
	url=$(echo "$mcp_json" | jq -r '.url // empty')
	if [[ -n "$url" ]]; then
		return 0
	fi

	cmd=$(echo "$mcp_json" | jq -r '.command // empty')
	if [[ -z "$cmd" ]]; then
		print_warning "No command or url specified in MCP definition"
		return 1
	fi

	# For npx/bunx/uvx, the command itself is the runner — always available if installed
	case "$cmd" in
	npx | bunx | uvx | node | bun | python3 | python | uv)
		if ! command -v "$cmd" >/dev/null 2>&1; then
			return 1
		fi
		return 0
		;;
	esac

	# For direct commands, check if the binary exists
	if ! command -v "$cmd" >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

# =============================================================================
# Per-Format Adapter Functions
# =============================================================================

# OpenCode: JSON with .mcp key, command as array, env → environment
# Config: ~/.config/opencode/opencode.json
_register_mcp_opencode() {
	local mcp_name="$1"
	local mcp_json="$2"
	local opencode_config="$HOME/.config/opencode/opencode.json"

	mkdir -p "$HOME/.config/opencode"

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — cannot configure OpenCode"
		return 0
	fi

	# Detect remote (URL-based) vs local (command-based) MCP
	local url
	url=$(echo "$mcp_json" | jq -r '.url // empty')

	# Default: disabled. MCPs activate on-demand via subagents.
	# Pass "enabled":true in mcp_json to override for always-on MCPs.
	local opencode_entry
	if [[ -n "$url" ]]; then
		# Remote MCP: use type "remote" with url field
		opencode_entry=$(echo "$mcp_json" | jq -c '{
            type: "remote",
            url: .url,
            enabled: (.enabled // false)
        }')
	else
		# Local MCP: merge command + args into a single "command" array
		# Rename "env" → "environment"
		opencode_entry=$(echo "$mcp_json" | jq -c '{
            type: "local",
            command: ([.command] + (.args // [])),
            environment: (.env // {}),
            enabled: (.enabled // false)
        }')
	fi

	json_set_nested "$opencode_config" "mcp" "$mcp_name" "$opencode_entry"
	return 0
}

# Claude Code: CLI command (claude mcp add-json NAME --scope user 'JSON')
_register_mcp_claude() {
	local mcp_name="$1"
	local mcp_json="$2"
	local claude_timeout_seconds="${AIDEVOPS_MCP_CLAUDE_TIMEOUT_SECONDS:-20}"

	if ! command -v claude >/dev/null 2>&1; then
		print_info "Claude Code CLI not found — skipping"
		return 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — cannot configure Claude Code"
		return 0
	fi

	# Check if already registered. The list call can trigger MCP health checks, so
	# cache it once per registration pass instead of once per server.
	_mcp_adapter_prepare_claude_registration "$claude_timeout_seconds"
	if [[ "${_MCP_ADAPTER_CLAUDE_LIST_STATUS_CACHE:-1}" -ne 0 ]]; then
		return 0
	fi
	if _mcp_adapter_claude_existing_contains "$mcp_name" "${_MCP_ADAPTER_CLAUDE_EXISTING_CACHE:-}"; then
		print_info "$mcp_name already registered in Claude Code — skipping"
		return 0
	fi

	# Detect remote (URL-based) vs local (command-based) MCP
	local url
	url=$(echo "$mcp_json" | jq -r '.url // empty')

	local claude_entry
	if [[ -n "$url" ]]; then
		# Remote MCP: use SSE transport with url
		claude_entry=$(echo "$mcp_json" | jq -c '{
            type: "sse",
            url: .url
        }')
	else
		# Local MCP: stdio transport with command + args
		claude_entry=$(echo "$mcp_json" | jq -c '{
            type: (.transport // "stdio"),
            command: .command,
            args: (.args // []),
            env: (.env // {})
        }')
	fi

	if _mcp_adapter_run_with_timeout "$claude_timeout_seconds" claude mcp add-json "$mcp_name" --scope user "$claude_entry" 2>/dev/null; then
		_mcp_adapter_claude_cache_mark_registered "$mcp_name"
		print_success "Registered $mcp_name in Claude Code"
	else
		print_warning "Failed or timed out registering $mcp_name in Claude Code"
	fi
	return 0
}

# Codex: TOML format ([mcp_servers.NAME] in ~/.codex/config.toml)
_register_mcp_codex() {
	local mcp_name="$1"
	local mcp_json="$2"
	local codex_config="${CODEX_HOME:-$HOME/.codex}/config.toml"

	mkdir -p "${CODEX_HOME:-$HOME/.codex}"

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — cannot configure Codex"
		return 0
	fi

	# Check if section already exists (idempotent)
	if [[ -f "$codex_config" ]] && grep -q "^\\[mcp_servers\\.${mcp_name}\\]" "$codex_config" 2>/dev/null; then
		print_info "$mcp_name already configured in $codex_config — skipping"
		return 0
	fi

	# Extract fields from universal JSON
	local cmd args_json env_json
	cmd=$(echo "$mcp_json" | jq -r '.command // empty')
	args_json=$(echo "$mcp_json" | jq -c '.args // []')
	env_json=$(echo "$mcp_json" | jq -c '.env // {}')

	# Build TOML section
	{
		printf '\n[mcp_servers.%s]\n' "$mcp_name"
		printf "command = '%s'\n" "$cmd"

		# Convert JSON args array to TOML array: ["a","b"] → ['a', 'b']
		local toml_args
		toml_args=$(echo "$args_json" | jq -r '[.[] | "'"'"'" + . + "'"'"'"] | join(", ")')
		printf 'args = [%s]\n' "$toml_args"

		# Convert JSON env object to TOML inline table if non-empty
		local env_count
		env_count=$(echo "$env_json" | jq 'length')
		if [[ "$env_count" -gt 0 ]]; then
			printf '\n[mcp_servers.%s.env]\n' "$mcp_name"
			# Write each env var as key = 'value'
			local env_keys
			env_keys=$(echo "$env_json" | jq -r 'keys[]')
			local key
			while IFS= read -r key; do
				local val
				val=$(echo "$env_json" | jq -r --arg k "$key" '.[$k]')
				printf "%s = '%s'\n" "$key" "$val"
			done <<<"$env_keys"
		fi
	} >>"$codex_config"

	print_success "Added $mcp_name to $codex_config"
	return 0
}

# Generic mcpServers JSON format — used by Cursor, Windsurf, Gemini, Kilo, Kiro
# Config path varies by runtime.
_register_mcp_mcpservers() {
	local runtime_id="$1"
	local mcp_name="$2"
	local mcp_json="$3"

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — cannot configure $(get_runtime_display_name "$runtime_id")"
		return 0
	fi

	# Determine config path per runtime
	local config_path=""

	case "$runtime_id" in
	cursor)
		config_path="$HOME/.cursor/mcp.json"
		mkdir -p "$HOME/.cursor"
		;;
	windsurf)
		config_path="$HOME/.codeium/windsurf/mcp_config.json"
		mkdir -p "$HOME/.codeium/windsurf"
		;;
	gemini | gemini-cli)
		config_path="$HOME/.gemini/settings.json"
		mkdir -p "$HOME/.gemini"
		;;
	kilo)
		config_path="$HOME/.kilo/mcp.json"
		mkdir -p "$HOME/.kilo"
		;;
	kiro)
		config_path="$HOME/.kiro/settings/mcp.json"
		mkdir -p "$HOME/.kiro/settings"
		;;
	amp)
		config_path="$HOME/.amp/settings.json"
		mkdir -p "$HOME/.amp"
		;;
	*)
		print_warning "Unknown mcpServers runtime: $runtime_id"
		return 0
		;;
	esac

	# Detect remote (URL-based) vs local (command-based) MCP
	local url
	url=$(echo "$mcp_json" | jq -r '.url // empty')

	local entry
	if [[ -n "$url" ]]; then
		# Remote MCP: use url field (mcpServers format supports this)
		entry=$(echo "$mcp_json" | jq -c '{
			url: .url
		}')
	else
		# Local MCP: command + args + env
		entry=$(echo "$mcp_json" | jq -c '{
			command: .command,
			args: (.args // []),
			env: (.env // {})
		}')
	fi

	json_set_nested "$config_path" "mcpServers" "$mcp_name" "$entry"
	return 0
}

# Droid (Factory.AI): CLI command (droid mcp add NAME ...)
_register_mcp_droid() {
	local mcp_name="$1"
	local mcp_json="$2"

	if ! command -v droid >/dev/null 2>&1; then
		print_info "Droid CLI not found — skipping"
		return 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — cannot configure Droid"
		return 0
	fi

	# Check if already registered
	local existing
	existing=$(droid mcp list 2>/dev/null || echo "")
	if echo "$existing" | grep -q "$mcp_name" 2>/dev/null; then
		print_info "$mcp_name already registered in Droid — skipping"
		return 0
	fi

	local cmd args_raw
	cmd=$(echo "$mcp_json" | jq -r '.command // empty')
	args_raw=$(echo "$mcp_json" | jq -r '.args // [] | .[]')

	# Build the droid mcp add command
	# droid mcp add NAME COMMAND [ARGS...]
	local droid_args
	droid_args=("$mcp_name" "$cmd")
	while IFS= read -r arg; do
		[[ -n "$arg" ]] && droid_args+=("$arg")
	done <<<"$args_raw"

	# Add env vars if present
	local env_keys
	env_keys=$(echo "$mcp_json" | jq -r '.env // {} | keys[]' 2>/dev/null || echo "")
	local key
	while IFS= read -r key; do
		if [[ -n "$key" ]]; then
			local val
			val=$(echo "$mcp_json" | jq -r --arg k "$key" '.env[$k]')
			droid_args+=("--env" "${key}=${val}")
		fi
	done <<<"$env_keys"

	if droid mcp add "${droid_args[@]}" 2>/dev/null; then
		print_success "Registered $mcp_name in Droid"
	else
		print_warning "Failed to register $mcp_name in Droid"
	fi
	return 0
}

# Continue.dev: JSON array format (mcpServers array in ~/.continue/config.json)
_register_mcp_continue() {
	local mcp_name="$1"
	local mcp_json="$2"
	local continue_config="$HOME/.continue/config.json"

	mkdir -p "$HOME/.continue"

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — cannot configure Continue.dev"
		return 0
	fi

	# Transform universal format → Continue.dev format:
	# { name: "...", transport: { type: "stdio", command: "...", args: [...] } }
	local continue_entry
	continue_entry=$(echo "$mcp_json" | jq -c --arg name "$mcp_name" '{
        name: $name,
        transport: {
            type: (.transport // "stdio"),
            command: .command,
            args: (.args // [])
        },
        env: (.env // {})
    }')

	json_append_to_array "$continue_config" "mcpServers" "$continue_entry" "name" "$mcp_name"
	return 0
}

# Aider: YAML format (mcpServers in ~/.aider.conf.yml)
_register_mcp_aider() {
	local mcp_name="$1"
	local mcp_json="$2"
	local aider_config="$HOME/.aider.conf.yml"

	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — cannot configure Aider"
		return 0
	fi

	# Check if already configured (idempotent)
	if [[ -f "$aider_config" ]] && grep -q "^  ${mcp_name}:" "$aider_config" 2>/dev/null; then
		print_info "$mcp_name already configured in $aider_config — skipping"
		return 0
	fi

	# Extract fields
	local cmd args_json env_json
	cmd=$(echo "$mcp_json" | jq -r '.command // empty')
	args_json=$(echo "$mcp_json" | jq -c '.args // []')
	env_json=$(echo "$mcp_json" | jq -c '.env // {}')

	# Ensure mcpServers section exists
	if [[ ! -f "$aider_config" ]]; then
		printf 'mcpServers:\n' >"$aider_config"
	elif ! grep -q '^mcpServers:' "$aider_config" 2>/dev/null; then
		printf '\nmcpServers:\n' >>"$aider_config"
	fi

	# Build YAML entry (escape embedded quotes and backslashes for YAML safety)
	{
		printf '  %s:\n' "$mcp_name"
		# Quote command if it contains YAML-special characters
		local safe_cmd="${cmd//\\/\\\\}"
		safe_cmd="${safe_cmd//\"/\\\"}"
		printf '    command: "%s"\n' "$safe_cmd"

		# Args as YAML list
		local arg_count
		arg_count=$(echo "$args_json" | jq 'length')
		if [[ "$arg_count" -gt 0 ]]; then
			printf '    args:\n'
			local i
			for ((i = 0; i < arg_count; i++)); do
				local arg_val
				arg_val=$(echo "$args_json" | jq -r ".[$i]")
				# Escape embedded quotes and backslashes
				arg_val="${arg_val//\\/\\\\}"
				arg_val="${arg_val//\"/\\\"}"
				printf '      - "%s"\n' "$arg_val"
			done
		fi

		# Env as YAML map
		local env_count
		env_count=$(echo "$env_json" | jq 'length')
		if [[ "$env_count" -gt 0 ]]; then
			printf '    env:\n'
			local env_keys
			env_keys=$(echo "$env_json" | jq -r 'keys[]')
			local key
			while IFS= read -r key; do
				local val
				val=$(echo "$env_json" | jq -r --arg k "$key" '.[$k]')
				# Escape embedded quotes and backslashes
				val="${val//\\/\\\\}"
				val="${val//\"/\\\"}"
				printf '      %s: "%s"\n' "$key" "$val"
			done <<<"$env_keys"
		fi
	} >>"$aider_config"

	print_success "Added $mcp_name to $aider_config"
	return 0
}

# =============================================================================
# Core Registration Functions
# =============================================================================

# Register an MCP server for a specific runtime.
# Usage: register_mcp_for_runtime <runtime_id> <mcp_name> <mcp_json>
register_mcp_for_runtime() {
	local runtime_id="$1"
	local mcp_name="$2"
	local mcp_json="$3"
	local display_name

	display_name=$(get_runtime_display_name "$runtime_id")

	# Validate command exists (skip if binary missing)
	if ! validate_mcp_command "$mcp_json"; then
		local cmd
		cmd=$(echo "$mcp_json" | jq -r '.command // "unknown"' 2>/dev/null || echo "unknown")
		print_warning "Skipping $mcp_name for ${display_name}: '$cmd' not found"
		return 0
	fi

	# Dispatch to per-format adapter
	case "$runtime_id" in
	opencode)
		_register_mcp_opencode "$mcp_name" "$mcp_json"
		;;
	claude | claude-code)
		_register_mcp_claude "$mcp_name" "$mcp_json"
		;;
	codex)
		_register_mcp_codex "$mcp_name" "$mcp_json"
		;;
	cursor | windsurf | gemini | gemini-cli | kilo | kiro | amp)
		_register_mcp_mcpservers "$runtime_id" "$mcp_name" "$mcp_json"
		;;
	droid)
		_register_mcp_droid "$mcp_name" "$mcp_json"
		;;
	continue)
		_register_mcp_continue "$mcp_name" "$mcp_json"
		;;
	aider)
		_register_mcp_aider "$mcp_name" "$mcp_json"
		;;
	*)
		print_warning "Unknown runtime '$runtime_id' — skipping $mcp_name"
		;;
	esac
	return 0
}

# Register an MCP server for all installed runtimes.
# Usage: register_mcp_for_all_runtimes <mcp_name> <mcp_json>
register_mcp_for_all_runtimes() {
	local mcp_name="$1"
	local mcp_json="$2"
	local runtime_id
	local count=0

	print_info "Registering $mcp_name for all installed runtimes..."

	while IFS= read -r runtime_id; do
		[[ -z "$runtime_id" ]] && continue
		register_mcp_for_runtime "$runtime_id" "$mcp_name" "$mcp_json"
		count=$((count + 1))
	done < <(detect_installed_runtimes)

	if [[ "$count" -eq 0 ]]; then
		print_warning "No runtimes detected — $mcp_name not registered anywhere"
	else
		print_success "Processed $mcp_name for $count runtime(s)"
	fi
	return 0
}

# =============================================================================
# CLI Interface
# =============================================================================

usage() {
	local script_name
	script_name="$(basename "$0")"
	cat <<EOF
Usage: ${script_name} <command> [options]

Transform universal MCP definitions into per-runtime config formats.

Commands:
  register <runtime> <name> '<json>'   Register MCP server for a specific runtime
  register-all <name> '<json>'         Register MCP server for all installed runtimes
  list-runtimes                        List detected runtimes
  help                                 Show this help

Runtimes:
  opencode, claude, codex, cursor, windsurf, gemini, kilo, kiro, droid, continue, aider

Universal MCP JSON format:
  {"command":"npx","args":["-y","@example/mcp"],"env":{"KEY":"val"}}

Examples:
  ${script_name} register opencode my-mcp '{"command":"echo","args":["hello"]}'
  ${script_name} register codex my-mcp '{"command":"npx","args":["-y","@foo/mcp"]}'
  ${script_name} register-all my-mcp '{"command":"echo","args":["hello"]}'
  ${script_name} list-runtimes

Library usage (source in other scripts):
  source mcp-config-adapter.sh
  register_mcp_for_runtime "opencode" "my-mcp" '{"command":"echo","args":["hi"]}'
  register_mcp_for_all_runtimes "my-mcp" '{"command":"echo","args":["hi"]}'
EOF
	return 0
}

main() {
	local cmd="${1:-help}"
	shift 2>/dev/null || true

	case "$cmd" in
	register)
		if [[ $# -lt 3 ]]; then
			print_error "Usage: register <runtime> <name> '<json>'"
			return 1
		fi
		local runtime="$1"
		local name="$2"
		local json="$3"
		register_mcp_for_runtime "$runtime" "$name" "$json"
		;;
	register-all)
		if [[ $# -lt 2 ]]; then
			print_error "Usage: register-all <name> '<json>'"
			return 1
		fi
		local name="$1"
		local json="$2"
		register_mcp_for_all_runtimes "$name" "$json"
		;;
	list-runtimes)
		print_info "Detected runtimes:"
		local rt
		while IFS= read -r rt; do
			[[ -z "$rt" ]] && continue
			local display
			display=$(get_runtime_display_name "$rt")
			printf "  %-12s  %s\n" "$rt" "$display"
		done < <(detect_installed_runtimes)
		;;
	help | --help | -h)
		usage
		;;
	*)
		print_error "Unknown command: $cmd"
		usage
		return 1
		;;
	esac
	return 0
}

# Allow sourcing without executing main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
