#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Runtime Config Generator -- MCP, Prompts, and Parity Sub-Library
# =============================================================================
# MCP server registration, system prompt deployment, and output parity
# verification for all supported runtimes.
#
# Usage: source "${SCRIPT_DIR}/generate-runtime-config-mcp.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - runtime-registry.sh (rt_display_name, rt_command_dir)
#   - mcp-config-adapter.sh (register_mcp_for_runtime)
#   - prompt-injection-adapter.sh (deploy_prompts_for_runtime)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_GENERATE_RUNTIME_CONFIG_MCP_LIB_LOADED:-}" ]] && return 0
_GENERATE_RUNTIME_CONFIG_MCP_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Phase 2c: MCP Registration -- Per-Runtime
# =============================================================================

_generate_mcp_for_runtime() {
	local runtime_id="$1"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	print_info "Registering MCP servers for $display_name..."

	if [[ "$runtime_id" == "claude" || "$runtime_id" == "claude-code" ]]; then
		if declare -f _mcp_adapter_reset_claude_registration_cache >/dev/null 2>&1; then
			_mcp_adapter_reset_claude_registration_cache
		fi
	fi

	# Codex has a preserving TOML reconciler; keep generic generation on it.
	if [[ "$runtime_id" == "codex" ]]; then
		python3 "${SCRIPT_DIR}/codex-mcp-config.py" || return 1
		return 0
	fi

	local mcp_count=0

	# Shared MCP definitions -- defined once, registered for each runtime
	# Format: register_mcp_for_runtime <runtime_id> <name> '<json>'

	# context7 (library docs -- remote endpoint, zero install)
	register_mcp_for_runtime "$runtime_id" "context7" \
		'{"url":"https://mcp.context7.com/mcp"}'
	mcp_count=$((mcp_count + 1))

	# Playwright MCP (correct package: @playwright/mcp, not @anthropic-ai/mcp-server-playwright)
	register_mcp_for_runtime "$runtime_id" "playwright" \
		'{"command":"npx","args":["-y","@playwright/mcp@0.0.79","--headless","--isolated"]}'
	mcp_count=$((mcp_count + 1))

	# shadcn UI
	register_mcp_for_runtime "$runtime_id" "shadcn" \
		'{"command":"npx","args":["shadcn@latest","mcp"]}'
	mcp_count=$((mcp_count + 1))

	# OpenAPI Search (remote, zero install)
	# Skip for OpenCode -- it uses a remote URL setup in _generate_agents_opencode
	if [[ "$runtime_id" != "opencode" ]]; then
		register_mcp_for_runtime "$runtime_id" "openapi-search" \
			'{"command":"npx","args":["-y","openapi-mcp-server"]}'
		mcp_count=$((mcp_count + 1))
	fi

	# macOS Automator (macOS only)
	if [[ "$(uname -s)" == "Darwin" ]]; then
		register_mcp_for_runtime "$runtime_id" "macos-automator" \
			'{"command":"npx","args":["-y","@steipete/macos-automator-mcp@latest"]}'
		mcp_count=$((mcp_count + 1))
	fi

	# Cloudflare API (remote MCP endpoint -- no local install needed)
	register_mcp_for_runtime "$runtime_id" "cloudflare-api" \
		'{"url":"https://mcp.cloudflare.com/mcp"}'
	mcp_count=$((mcp_count + 1))

	# Shopify Dev MCP (disabled by default; enabled per-agent via @shopify)
	# Requires: Node 18+, Shopify CLI 3.93.0+ (npm install -g @shopify/cli@latest)
	# TODO(permission-migration): when anomalyco/opencode#6892 is resolved, the
	# per-agent tools: entry can be replaced with permission: shopify-dev-mcp: allow
	register_mcp_for_runtime "$runtime_id" "shopify-dev-mcp" \
		'{"command":"npx","args":["-y","@shopify/dev-mcp@latest"]}'
	mcp_count=$((mcp_count + 1))

	print_success "$display_name: $mcp_count MCP servers processed"
	return 0
}

# =============================================================================
# Phase 2d: System Prompt Deployment
# =============================================================================

_generate_prompts_for_runtime() {
	local runtime_id="$1"
	deploy_prompts_for_runtime "$runtime_id"
	return $?
}

# =============================================================================
# Phase 3: Verification
# =============================================================================

_verify_parity() {
	print_info "Verifying output parity with old generators..."

	local errors=0

	# Check OpenCode config exists and has agents
	local opencode_config="$HOME/.config/opencode/opencode.json"
	if [[ -f "$opencode_config" ]]; then
		local agent_count
		agent_count=$(python3 -c "
import json
with open('$opencode_config') as f:
    config = json.load(f)
agents = config.get('agent', {})
print(len([k for k, v in agents.items() if not v.get('disable', False)]))
" 2>/dev/null || echo "0")
		if [[ "$agent_count" -gt 0 ]]; then
			print_success "OpenCode: $agent_count active agents configured"
		else
			print_warning "OpenCode: no active agents found"
			errors=$((errors + 1))
		fi

		# Check instructions field
		local has_instructions
		has_instructions=$(python3 -c "
import json
with open('$opencode_config') as f:
    config = json.load(f)
print('yes' if config.get('instructions') else 'no')
" 2>/dev/null || echo "no")
		if [[ "$has_instructions" == "yes" ]]; then
			print_success "OpenCode: instructions field set"
		else
			print_warning "OpenCode: instructions field missing"
			errors=$((errors + 1))
		fi
	else
		print_warning "OpenCode config not found at $opencode_config"
	fi

	# Check Claude Code settings
	local claude_settings="$HOME/.claude/settings.json"
	if [[ -f "$claude_settings" ]]; then
		local has_hooks
		has_hooks=$(python3 -c "
import json
with open('$claude_settings') as f:
    settings = json.load(f)
hooks = settings.get('hooks', {}).get('PreToolUse', [])
print('yes' if hooks else 'no')
" 2>/dev/null || echo "no")
		if [[ "$has_hooks" == "yes" ]]; then
			print_success "Claude Code: PreToolUse hooks configured"
		else
			print_warning "Claude Code: PreToolUse hooks missing"
			errors=$((errors + 1))
		fi
	fi

	# Check command directories
	local opencode_cmd_dir
	opencode_cmd_dir=$(rt_command_dir "opencode") || opencode_cmd_dir=""
	if [[ -n "$opencode_cmd_dir" && -d "$opencode_cmd_dir" ]]; then
		local oc_cmd_count
		oc_cmd_count=$(find "$opencode_cmd_dir" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		print_success "OpenCode: $oc_cmd_count commands in $opencode_cmd_dir"
	fi

	local claude_cmd_dir
	claude_cmd_dir=$(rt_command_dir "claude-code") || claude_cmd_dir=""
	if [[ -n "$claude_cmd_dir" && -d "$claude_cmd_dir" ]]; then
		local cc_cmd_count
		cc_cmd_count=$(find "$claude_cmd_dir" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		print_success "Claude Code: $cc_cmd_count commands in $claude_cmd_dir"
	fi

	if [[ $errors -gt 0 ]]; then
		print_warning "Parity check: $errors issue(s) found"
		return 1
	fi

	print_success "Parity check passed"
	return 0
}
