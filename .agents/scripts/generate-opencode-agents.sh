#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# DEPRECATED: Use generate-runtime-config.sh instead (t1665.4)
# This script is kept for one release cycle as a fallback.
# .agents/scripts/setup/modules/config.sh will use generate-runtime-config.sh when available.
# =============================================================================
# Generate OpenCode Agent Configuration
# =============================================================================
# Architecture:
#   - Primary agents: Auto-discovered from root .md files in ~/.aidevops/agents/
#   - Subagents: Auto-discovered from subfolder .md files (@mentionable)
#   - AGENTS.md: At ~/.config/opencode/AGENTS.md (global context reference)
#
# Source: ~/.aidevops/agents/
#   - Root .md files = Primary agents (auto-discovered, Tab-switchable)
#   - Subfolder .md files = Subagents (auto-discovered, @mentionable)
#
# Agent Configuration:
#   - Frontmatter in .md files can specify: mode, tools, temperature
#   - Special handling for Plan+ (read-only) and agents with specific MCP needs
#   - Default: full build permissions with common context tools
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

AGENTS_DIR="$HOME/.aidevops/agents"
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_AGENT_DIR="$OPENCODE_CONFIG_DIR/agent"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"

echo -e "${BLUE}Generating OpenCode agent configuration...${NC}"

# Ensure directories exist
mkdir -p "$OPENCODE_AGENT_DIR"

# Always update AGENTS.md with version check (ensures updates get deployed)
cat >"$OPENCODE_CONFIG_DIR/AGENTS.md" <<'EOF'
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.

**Runtime**: You are running in OpenCode. Global config: `~/.config/opencode/opencode.json`.

## aidevops Framework Status

The opencode-aidevops plugin renders session-start framework status (version, environment, security advisories, pulse health, contribution count) as TUI toasts at session creation via `client.tui.showToast()`. Raw output is cached at `~/.aidevops/cache/session-greeting-opencode.txt`.

Do not re-run `aidevops-update-check.sh` or repeat toast content as a greeting — the user has already seen it. Respond directly to the user's message.

**Fallback for agents without a Bash tool** (the plugin only fires toasts when the host runtime exposes the TUI — subagents may not see them): read `~/.aidevops/cache/session-greeting-opencode.txt` if it exists; otherwise read `~/.aidevops/agents/VERSION` for `{version}` and greet with `"Hi!\n\nWe're running https://aidevops.sh v{version}.\n\nWhat would you like to work on?"`.

**Update available prompt**: the raw cached output may begin with `UPDATE_AVAILABLE|<current>|<latest>|<runtime>`. When present, inform the user: "Update available (current → latest). Run `aidevops update` in a terminal session, or type `!aidevops update` below and hit Enter." If the cached output also contains `AUTO_UPDATE_ENABLED`, replace the manual instruction with: "Auto-update is enabled and will apply this within ~10 minutes."

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
EOF
echo -e "  ${GREEN}✓${NC} Updated AGENTS.md with version check"

# Remove old primary agent markdown files (they're now in JSON, auto-discovered)
# This cleans up any legacy files from before auto-discovery
# Also removes demoted agents that are now subagents
# Plan+ and AI-DevOps consolidated into Build+ as of v2.50.0
legacy_files=(
	"Accounts.md" "Accounting.md" "accounting.md" "AI-DevOps.md" "Build+.md" "Content.md"
	"Health.md" "Legal.md" "Marketing.md" "Research.md" "Sales.md" "SEO.md" "WordPress.md"
	"Plan+.md" "Build-Agent.md" "Build-MCP.md" "build-agent.md" "build-mcp.md"
	"plan-plus.md" "aidevops.md" "Browser-Extension-Dev.md" "Mobile-App-Dev.md" "AGENTS.md"
)
for f in "${legacy_files[@]}"; do
	rm -f "$OPENCODE_AGENT_DIR/$f"
done

# Remove loop-state files that were incorrectly created as agents
# These are runtime state files, not agents
for f in ralph-loop.local.md quality-loop.local.md full-loop.local.md loop-state.md re-anchor.md postflight-loop.md; do
	rm -f "$OPENCODE_AGENT_DIR/$f"
done

# =============================================================================
# PRIMARY AGENTS - Defined in opencode.json for Tab order control
# =============================================================================

echo -e "${BLUE}Configuring primary agents in opencode.json...${NC}"

# Check if opencode.json exists
if [[ ! -f "$OPENCODE_CONFIG" ]]; then
	echo -e "${YELLOW}Warning: $OPENCODE_CONFIG not found. Creating minimal config.${NC}"
	# shellcheck disable=SC2016
	echo '{"$schema": "https://opencode.ai/config.json"}' >"$OPENCODE_CONFIG"
fi

# Use Python to auto-discover and configure primary agents
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/opencode-agent-discovery.py"

echo -e "  ${GREEN}✓${NC} Primary agents configured in opencode.json"

# =============================================================================
# SUBAGENTS - Generated as markdown files (@mentionable)
# =============================================================================

echo -e "${BLUE}Generating subagent markdown files...${NC}"

# Remove existing subagent files (regenerate fresh)
find "$OPENCODE_AGENT_DIR" -name "*.md" -type f -delete 2>/dev/null || true

# Generate SUBAGENT files from subfolders
# Some subagents need specific MCP tools enabled
# t1041: Use parallel processing to handle 907+ files efficiently

# Extract description from source file frontmatter (t255).
# Falls back to "Read <path>" if no description found in frontmatter.
_get_subagent_description() {
	local f="$1"
	local rel_path="$2"
	local src_desc
	src_desc=$(sed -n '/^---$/,/^---$/{ /^description:/{s/^description: *//p; q} }' "$f" 2>/dev/null)
	if [[ -z "$src_desc" ]]; then
		src_desc="Read ~/.aidevops/agents/${rel_path}"
	fi
	printf '%s' "$src_desc"
	return 0
}

# Determine additional MCP tool lines based on subagent name.
# Outputs the extra_tools string (may be empty) to stdout.
_get_extra_tools() {
	local name="$1"
	local extra_tools=""
	case "$name" in
	outscraper)
		extra_tools=$'  outscraper_*: true\n  webfetch: true'
		;;
	mainwp | localwp)
		extra_tools=$'  localwp_*: true'
		;;
	quickfile)
		extra_tools=$'  quickfile_*: true'
		;;
	google-search-console)
		extra_tools=$'  gsc_*: true'
		;;
	dataforseo)
		extra_tools=$'  dataforseo_*: true\n  webfetch: true'
		;;
	claude-code)
		extra_tools=$'  claude-code-mcp_*: true'
		;;
	# serper - REMOVED: Uses curl subagent now, no MCP tools
	openapi-search)
		extra_tools=$'  openapi-search_*: true\n  webfetch: true'
		;;
	aidevops)
		extra_tools=$'  openapi-search_*: true'
		;;
	playwriter)
		extra_tools=$'  playwriter_*: true'
		;;
	shadcn)
		extra_tools=$'  shadcn_*: true\n  write: true\n  edit: true'
		;;
	macos-automator | mac)
		# Only enable macos-automator tools on macOS
		if [[ "$(uname -s)" == "Darwin" ]]; then
			extra_tools=$'  macos-automator_*: true\n  webfetch: true'
		fi
		;;
	ios-simulator-mcp)
		# Only enable ios-simulator tools on macOS
		if [[ "$(uname -s)" == "Darwin" ]]; then
			extra_tools=$'  ios-simulator_*: true'
		fi
		;;
	shopify)
		extra_tools=$'  shopify-dev-mcp_*: true'
		# TODO(permission-migration): Replace with permission: shopify-dev-mcp: allow
		# once anomalyco/opencode#6892 is resolved.
		;;
	sentry)
		extra_tools=$'  sentry_*: true'
		;;
	socket)
		extra_tools=$'  socket_*: true'
		;;
	context7 | context7-cli)
		extra_tools=$'  context7_*: true'
		;;
	chrome-devtools)
		extra_tools=$'  chrome-devtools_*: true'
		;;
	cloudflare-mcp)
		extra_tools=$'  cloudflare-api_*: true'
		;;
	playwright)
		extra_tools=$'  playwright_*: true'
		;;
	*) ;; # No extra tools for other agents
	esac
	printf '%s' "$extra_tools"
	return 0
}

_yaml_quote_scalar() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '"%s"' "$value"
	return 0
}

# GH#18509: Copy source verbatim (with model-name normalisation) when the
# agent's frontmatter sets bash: false — it is security-sandboxed or has its
# own tool restrictions and must not be overwritten with a permissive stub.
# Returns 0 and emits "1" (count) if handled; returns 1 if not a sandboxed file.
_write_sandboxed_agent() {
	local f="$1"
	local name="$2"
	local src_bash_false
	src_bash_false=$(awk '
		/^---$/ { fm_delim++; next }
		fm_delim == 1 && /bash:[[:space:]]*false/ { print; exit }
		fm_delim == 2 { exit }
	' "$f" 2>/dev/null)
	if [[ -n "$src_bash_false" ]]; then
		sed \
			-e 's/^model: opus$/model: anthropic\/claude-opus-4-6/' \
			-e 's/^model: sonnet$/model: anthropic\/claude-sonnet-4-6/' \
			-e 's/^model: haiku$/model: anthropic\/claude-haiku-4-5/' \
			"$f" >"$OPENCODE_AGENT_DIR/$name.md"
		echo 1
		return 0
	fi
	return 1
}

# GH#3601: Write the permissive stub using printf — avoids unquoted heredoc
# expansion. src_desc and rel_path come from the filesystem and could contain
# shell metacharacters. printf '%s\n' treats arguments as literal data so
# $(…) or backticks in a description field are never executed.
_write_permissive_stub() {
	local name="$1"
	local src_desc="$2"
	local rel_path="$3"
	local extra_tools="$4"
	local quoted_desc
	quoted_desc=$(_yaml_quote_scalar "$src_desc")
	local worktree_base="${HOME}/Git/_worktrees"
	if [[ -n "${AIDEVOPS_WORKTREE_BASE_DIR+x}" ]]; then
		worktree_base="$AIDEVOPS_WORKTREE_BASE_DIR"
	fi
	while [[ "$worktree_base" == */ ]]; do
		worktree_base="${worktree_base%/}"
	done
	if [[ "$worktree_base" != /* || "$worktree_base" == "/" ]]; then
		printf 'AIDEVOPS_WORKTREE_BASE_DIR must be a non-root absolute path\n' >&2
		return 1
	fi
	{
		printf '%s\n' \
			"---" \
			"description: ${quoted_desc}" \
			"mode: subagent" \
			"temperature: 0.2" \
			"permission:" \
			"  external_directory:" \
			'    "~/.aidevops": allow' \
			'    "~/.aidevops/**": allow' \
			'    "~/.config/aidevops": allow' \
			'    "~/.config/aidevops/**": allow' \
			'    "~/.config/opencode/command": allow' \
			'    "~/.config/opencode/command/**": allow' \
			"    \"${worktree_base}\": allow" \
			"    \"${worktree_base}/**\": allow" \
			"tools:" \
			"  read: true" \
			"  bash: true"
		[[ -n "$extra_tools" ]] && printf '%s\n' "$extra_tools"
		printf '%s\n' \
			"---" \
			"" \
			"**MANDATORY**: Your first action MUST be to read ~/.aidevops/agents/${rel_path} and follow ALL rules within it."
	} >"$OPENCODE_AGENT_DIR/$name.md"
	echo 1 # Return 1 for counting
	return 0
}

# Main entry point: orchestrates description extraction, tool lookup, and stub
# writing for a single subagent markdown source file.
generate_subagent_stub() {
	local f="$1"
	local name
	name=$(basename "$f" .md)
	[[ "$name" == "AGENTS" || "$name" == "README" ]] && return 0

	local rel_path="${f#"$AGENTS_DIR"/}"
	local src_desc extra_tools
	src_desc=$(_get_subagent_description "$f" "$rel_path")
	extra_tools=$(_get_extra_tools "$name")

	# Security-sandboxed agents are copied verbatim; exit early if handled.
	_write_sandboxed_agent "$f" "$name" && return 0

	_write_permissive_stub "$name" "$src_desc" "$rel_path" "$extra_tools"
	return 0
}

export -f generate_subagent_stub _get_subagent_description _get_extra_tools _yaml_quote_scalar _write_sandboxed_agent _write_permissive_stub 2>/dev/null || true
export AGENTS_DIR
export OPENCODE_AGENT_DIR

# Process files in parallel (nproc or 4, whichever is larger — each stub is a
# tiny sed+cat, so full CPU parallelism is safe and reduces wall-clock time)
_ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
_parallel_jobs=$((_ncpu > 4 ? _ncpu : 4))
subagent_count=$(find "$AGENTS_DIR" -mindepth 2 -name "*.md" -type f -not -path "*/loop-state/*" -not -name "*-skill.md" -print0 |
	xargs -0 -P "$_parallel_jobs" -I {} bash -c 'generate_subagent_stub "$@"' _ {} |
	awk '{sum+=$1} END {print sum+0}')

echo -e "  ${GREEN}✓${NC} Generated $subagent_count subagent files"

# =============================================================================
# MCP INDEX - Sync tool descriptions for on-demand discovery
# =============================================================================

echo -e "${BLUE}Syncing MCP tool index for on-demand discovery...${NC}"

MCP_INDEX_HELPER="$AGENTS_DIR/scripts/mcp-index-helper.sh"
if [[ -x "$MCP_INDEX_HELPER" ]]; then
	if "$MCP_INDEX_HELPER" sync 2>/dev/null; then
		echo -e "  ${GREEN}✓${NC} MCP tool index updated"
	else
		echo -e "  ${YELLOW}⚠${NC} MCP index sync skipped (non-critical)"
	fi
else
	echo -e "  ${YELLOW}⚠${NC} MCP index helper not found (install with setup.sh)"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}Done!${NC}"
echo "  Primary agents: Auto-discovered from ~/.aidevops/agents/*.md (Tab-switchable)"
echo "  Subagents: $subagent_count auto-discovered from subfolders (@mentionable)"
echo "  Instructions: ~/.aidevops/agents/AGENTS.md (auto-loaded every session)"
echo "  Global rules: ~/.config/opencode/AGENTS.md (version check + pre-edit)"
echo ""
echo "Tab order: Build+ → (alphabetical)"
echo "  Note: Plan+ and AI-DevOps consolidated into Build+ (available as @plan-plus, @aidevops)"
echo ""
echo "MCP Loading Strategy:"
echo "  - Eager MCPs: Start at launch when explicitly categorized"
echo "  - Lazy MCPs: Start on-demand via subagents (default policy)"
echo "  - Use 'mcp-index-helper.sh search <query>' to discover tools on-demand"
echo "  - Subagents enable specific MCPs via frontmatter tools: section"
echo ""
echo "To add a new primary agent: Create ~/.aidevops/agents/{name}.md"
echo "To add a new subagent: Create ~/.aidevops/agents/{folder}/{name}.md"
echo ""
echo "Restart OpenCode to load new configuration."
