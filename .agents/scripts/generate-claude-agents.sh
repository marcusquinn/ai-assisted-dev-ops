#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016 # $ARGUMENTS is a Claude Code template placeholder written literally to .md files
# =============================================================================
# DEPRECATED: Use generate-runtime-config.sh instead (t1665.4)
# This script is kept for one release cycle as a fallback.
# .agents/scripts/setup/modules/config.sh will use generate-runtime-config.sh when available.
# =============================================================================
# Generate Claude Code Configuration
# =============================================================================
# Achieves config parity between OpenCode and Claude Code by:
#   1. Slash commands: Generated in ~/.claude/commands/ (project-level)
#   2. MCP servers: Registered via `claude mcp add-json` (user scope)
#   3. Settings: Enhanced ~/.claude/settings.json (hooks, permissions)
#
# Architecture mirrors generate-opencode-agents.sh / generate-opencode-commands.sh
# but targets Claude Code's native configuration system.
#
# Prerequisites: none (if `claude` is missing, MCP registration is skipped)
# Called by: setup.sh update_claude_config()
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	echo "Error: shared-constants.sh not found at ${SCRIPT_DIR}/shared-constants.sh" >&2
	exit 1
fi

set -euo pipefail

CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo -e "${BLUE}Generating Claude Code configuration...${NC}"

# =============================================================================
# PHASE 1: SLASH COMMANDS
# =============================================================================
# Claude Code uses ~/.claude/commands/*.md for custom slash commands.
# Each file becomes a /command-name available in the CLI.
# Frontmatter format:
#   ---
#   description: Short description
#   allowed-tools: tool1, tool2 (optional)
#   ---
#
# $ARGUMENTS is replaced with user input after the command name.
# =============================================================================

echo -e "${BLUE}Generating Claude Code slash commands...${NC}"

mkdir -p "$CLAUDE_COMMANDS_DIR"

command_count=0

# Helper: write a slash command file
# Args: $1=name, $2=description, $3=body (heredoc content)
write_command() {
	local name="$1"
	local description="$2"
	local body="$3"

	cat >"$CLAUDE_COMMANDS_DIR/$name.md" <<EOF
---
description: $description
---

$body
EOF
	((++command_count))
	echo -e "  ${GREEN}+${NC} /$name"
	return 0
}

# Load command definitions from extracted helper file
source "${SCRIPT_DIR}/claude-command-defs.bash"

# --- Auto-discover commands from scripts/commands/ ---
auto_discover_commands() {
	local commands_src_dir="$HOME/.aidevops/agents/scripts/commands"

	[[ -d "$commands_src_dir" ]] || return 0

	local cmd_file cmd_name
	for cmd_file in "$commands_src_dir"/*.md; do
		[[ -f "$cmd_file" ]] || continue

		cmd_name=$(basename "$cmd_file" .md)

		# Skip non-commands
		[[ "$cmd_name" == "SKILL" ]] && continue

		# Skip already manually defined
		[[ -f "$CLAUDE_COMMANDS_DIR/$cmd_name.md" ]] && continue

		# Copy command file (adapt frontmatter for Claude Code format)
		# Strip OpenCode-specific frontmatter fields (agent, subtask)
		sed -E '/^---$/,/^---$/{/^(agent|subtask):/d;}' "$cmd_file" \
			>"$CLAUDE_COMMANDS_DIR/$cmd_name.md"

		((++command_count))
		echo -e "  ${GREEN}+${NC} /$cmd_name (auto-discovered)"
	done
	return 0
}

auto_discover_commands

echo -e "  ${GREEN}Done${NC} — $command_count slash commands in $CLAUDE_COMMANDS_DIR"

# =============================================================================
# PHASE 2: MCP SERVER REGISTRATION
# =============================================================================
# Uses `claude mcp add-json <name> '<json>' -s user` for persistent registration.
# Only adds servers not already registered (idempotent).
# =============================================================================

mcp_count=0

# Helper: register an MCP server if not already present
# Args: $1=name, $2=json_config
# Requires: $existing_mcps variable from caller
register_mcp() {
	local name="$1"
	local json_config="$2"

	# Check if already registered
	if echo "$existing_mcps" | grep -qx "$name" 2>/dev/null; then
		echo -e "  ${BLUE}=${NC} $name (already registered)"
		return 0
	fi

	if claude mcp add-json "$name" "$json_config" -s user 2>/dev/null; then
		((++mcp_count))
		echo -e "  ${GREEN}+${NC} $name"
	else
		echo -e "  ${YELLOW}!${NC} $name (registration failed)"
	fi
	return 0
}

register_all_mcp_servers() {
	echo -e "${BLUE}Registering MCP servers with Claude Code...${NC}"

	# Get currently registered MCP servers (parse names from `claude mcp list`)
	existing_mcps=""
	if claude mcp list &>/dev/null; then
		existing_mcps=$(claude mcp list 2>/dev/null | grep -oE '^[a-zA-Z0-9_-]+:' | tr -d ':' || true)
	fi

	# --- context7 (library docs) ---
	register_mcp "context7" "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@upstash/context7-mcp@latest\"]}"

	# --- Playwright MCP (correct package: @playwright/mcp) ---
	register_mcp "playwright" "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@playwright/mcp@0.0.79\",\"--headless\",\"--isolated\"]}"

	# --- shadcn UI ---
	register_mcp "shadcn" "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"shadcn@latest\",\"mcp\"]}"

	# --- OpenAPI Search (remote, zero install) ---
	register_mcp "openapi-search" "{\"type\":\"sse\",\"url\":\"https://openapi-mcp.openapisearch.com/mcp\"}"

	# --- macOS Automator (macOS only) ---
	if [[ "$(uname -s)" == "Darwin" ]]; then
		register_mcp "macos-automator" "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@steipete/macos-automator-mcp@latest\"]}"
	fi

	# --- Cloudflare API (remote) ---
	register_mcp "cloudflare-api" "{\"type\":\"sse\",\"url\":\"https://mcp.cloudflare.com/mcp\"}"

	echo -e "  ${GREEN}Done${NC} — $mcp_count new MCP servers registered"
	return 0
}

if command -v claude &>/dev/null; then
	register_all_mcp_servers
else
	echo -e "${YELLOW}[SKIP]${NC} Claude CLI not found — skipping MCP registration"
fi

# =============================================================================
# PHASE 3: SETTINGS.JSON
# =============================================================================
# Manages ~/.claude/settings.json via external Python script.
# See update-claude-settings.py for details.
# =============================================================================

echo -e "${BLUE}Updating Claude Code settings...${NC}"

# Ensure directory exists
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

# Create minimal settings if file doesn't exist
if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
	echo '{}' >"$CLAUDE_SETTINGS"
	chmod 600 "$CLAUDE_SETTINGS"
	echo -e "  ${GREEN}+${NC} Created $CLAUDE_SETTINGS"
fi

# Run extracted Python settings updater
python3 "${SCRIPT_DIR}/update-claude-settings.py"

echo -e "  ${GREEN}Done${NC} — settings.json updated"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}Claude Code configuration complete!${NC}"
echo "  Slash commands: $command_count in $CLAUDE_COMMANDS_DIR"
echo "  MCP servers: $mcp_count newly registered (user scope)"
echo "  Settings: $CLAUDE_SETTINGS (hooks, plugins, tool permissions)"
echo ""
echo "Available slash commands (subset):"
echo "  /onboarding       - Interactive setup wizard"
echo "  /full-loop        - End-to-end development loop"
echo "  /preflight        - Quality checks before release"
echo "  /create-pr        - Create PR from current branch"
echo "  /release          - Full release workflow"
echo "  /remember         - Store cross-session memory"
echo "  /recall           - Search previous memories"
echo ""
echo "Run 'claude /help' to see all available commands."
