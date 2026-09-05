#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# =============================================================================
# Runtime Registry — Central data source for all supported AI CLI runtimes
# =============================================================================
# Single source of truth for runtime properties: binary names, config paths,
# config formats, MCP root keys, command directories, prompt mechanisms,
# session databases, process patterns, and per-runtime feature flags.
#
# Bash 3.2 compatible: uses parallel indexed arrays (no associative arrays).
#
# Usage:
#   source runtime-registry.sh
#   # Look up a property by runtime ID:
#   local config_path
#   config_path=$(rt_config_path "claude-code")
#   # List all runtime IDs:
#   rt_list_ids
#   # Detect which runtimes are installed:
#   rt_detect_installed
#   # Check feature flags:
#   if [[ "$(rt_feature_memory claude-code)" == "yes" ]]; then ...
#
# Sourced from shared-constants.sh so all scripts inherit it.
#
# Design: t1665.1 — registry data source only, no adapters or migration.
# =============================================================================

# Include guard
[[ -n "${_RUNTIME_REGISTRY_LOADED:-}" ]] && return 0
_RUNTIME_REGISTRY_LOADED=1

# =============================================================================
# Runtime ID Index
# =============================================================================
# Each runtime has a stable string ID used as the lookup key.
# The index position in _RT_IDS corresponds to the same index in all
# parallel property arrays below.
#
# To add a new runtime: append to _RT_IDS and to every _RT_* array below,
# keeping the same index position. Run tests/test-runtime-registry.sh to
# verify alignment.

_RT_IDS=(
	"opencode"    # 0
	"claude-code" # 1
	"codex"       # 2
	"cursor"      # 3
	"droid"       # 4
	"gemini-cli"  # 5
	"windsurf"    # 6
	"continue"    # 7
	"kilo"        # 8
	"kiro"        # 9
	"aider"       # 10
	"amp"         # 11
	"kimi"        # 12
	"qwen"        # 13
)

# Total count — used for alignment validation
_RT_COUNT=${#_RT_IDS[@]}

# =============================================================================
# Property Arrays (parallel to _RT_IDS)
# =============================================================================
# IMPORTANT: Every array MUST have exactly _RT_COUNT elements. Use "" for
# unknown/not-applicable values. The test suite validates alignment.

# --- Binary names (what to pass to `command -v`) ---
_RT_BINARY=(
	"opencode" # opencode
	"claude"   # claude-code
	"codex"    # codex
	"cursor"   # cursor
	"droid"    # droid
	"gemini"   # gemini-cli
	"windsurf" # windsurf
	"continue" # continue
	"kilo"     # kilo
	"kiro"     # kiro
	"aider"    # aider
	"amp"      # amp
	"kimi"     # kimi
	"qwen"     # qwen
)

# --- Version commands (CLI command to extract version string) ---
# Each entry is a shell command fragment (eval'd at lookup time).
# Use "" for runtimes with no known CLI version command (GUI-only apps,
# editor extensions, or runtimes whose version is only accessible via their UI).
_RT_VERSION_CMD=(
	"opencode --version 2>/dev/null | head -1" # opencode
	"claude --version 2>/dev/null | head -1"   # claude-code
	"codex --version 2>/dev/null | head -1"    # codex
	""                                         # cursor (GUI app, no CLI version)
	"droid --version 2>/dev/null | head -1"    # droid
	"gemini --version 2>/dev/null | head -1"   # gemini-cli
	""                                         # windsurf (GUI app, no CLI version)
	""                                         # continue (editor extension, no CLI)
	"kilo --version 2>/dev/null | head -1"     # kilo
	""                                         # kiro (GUI app, no CLI version)
	"aider --version 2>/dev/null | head -1"    # aider
	"amp --version 2>/dev/null | head -1"      # amp
	"kimi --version 2>/dev/null | head -1"     # kimi
	"qwen --version 2>/dev/null | head -1"     # qwen
)

# --- Display names (human-readable) ---
_RT_DISPLAY_NAME=(
	"OpenCode"    # opencode
	"Claude Code" # claude-code
	"Codex CLI"   # codex
	"Cursor"      # cursor
	"Droid"       # droid
	"Gemini CLI"  # gemini-cli
	"Windsurf"    # windsurf
	"Continue"    # continue
	"Kilo Code"   # kilo
	"Kiro"        # kiro
	"Aider"       # aider
	"Amp"         # amp
	"Kimi CLI"    # kimi
	"Qwen Code"   # qwen
)

# --- MCP config file paths (~ expanded at lookup time) ---
# Use $HOME explicitly; ~ is not expanded inside double quotes.
_RT_CONFIG_PATH=(
	"\$HOME/.config/opencode/opencode.json"            # opencode
	"\$HOME/.config/Claude/claude_desktop_config.json" # claude-code
	"\$CODEX_HOME/config.toml"                         # codex
	"\$HOME/.cursor/mcp.json"                          # cursor
	"\$HOME/.config/droid/mcp.json"                    # droid
	"\$HOME/.gemini/settings.json"                     # gemini-cli
	"\$HOME/.codeium/windsurf/mcp_config.json"         # windsurf
	"\$HOME/.continue/config.json"                     # continue
	"\$HOME/.kilo/mcp.json"                            # kilo
	"\$HOME/.kiro/settings/mcp.json"                   # kiro
	""                                                 # aider (no MCP config)
	"\$HOME/.amp/settings.json"                        # amp
	"\$HOME/.kimi/config.toml"                         # kimi
	"\$HOME/.qwen/settings.json"                       # qwen
)

# --- Config file formats ---
_RT_CONFIG_FORMAT=(
	"json" # opencode
	"json" # claude-code
	"toml" # codex
	"json" # cursor
	"json" # droid
	"json" # gemini-cli
	"json" # windsurf
	"json" # continue
	"json" # kilo
	"json" # kiro
	""     # aider
	"json" # amp
	"toml" # kimi
	"json" # qwen
)

# --- MCP root key (the JSON key under which MCP servers are defined) ---
_RT_MCP_ROOT_KEY=(
	"mcp"         # opencode — inside opencode.json
	"mcpServers"  # claude-code
	"mcp_servers" # codex
	"mcpServers"  # cursor
	"mcpServers"  # droid
	"mcpServers"  # gemini-cli
	"mcpServers"  # windsurf
	"mcpServers"  # continue
	"mcpServers"  # kilo
	"mcpServers"  # kiro
	""            # aider
	"mcpServers"  # amp
	"mcpServers"  # kimi
	"mcpServers"  # qwen
)

# --- Slash command / prompt / skill directories ---
# Where the runtime loads user-defined slash commands or prompts.
# Empty string = runtime has no global command directory (may still support
# repo-local commands — handled separately by `aidevops init`).
_RT_COMMAND_DIR=(
	"\$HOME/.config/opencode/command" # opencode
	"\$HOME/.claude/commands"         # claude-code
	"\$CODEX_HOME/prompts"            # codex (invoked as /prompts:name)
	"\$HOME/.cursor/commands"         # cursor (Cursor 1.6+)
	"\$HOME/.factory/commands"        # droid (Factory CLI)
	"\$HOME/.gemini/commands"         # gemini-cli (TOML format)
	""                                # windsurf (repo-only: .windsurf/workflows/)
	"\$HOME/.continue/prompts"        # continue (.prompt files, invokable: true)
	""                                # kilo (uses custom modes, not commands)
	"\$HOME/.kiro/steering"           # kiro (inclusion: manual frontmatter)
	""                                # aider (no native support)
	""                                # amp (repo-only: .agents/commands/)
	"\$HOME/.kimi/skills"             # kimi (Skills: SKILL.md per subdir)
	"\$HOME/.qwen/commands"           # qwen (MD with frontmatter or legacy TOML)
)

# --- Prompt mechanism (how the runtime loads system instructions) ---
# Values: "AGENTS.md" (file-based), "system-prompt" (API param),
#         "config" (in config file), "" (unknown/none)
_RT_PROMPT_MECHANISM=(
	"AGENTS.md"     # opencode
	"AGENTS.md"     # claude-code
	"AGENTS.md"     # codex
	"config"        # cursor (.cursorrules)
	"AGENTS.md"     # droid
	"system-prompt" # gemini-cli
	"config"        # windsurf (.windsurfrules)
	"config"        # continue (.continuerules)
	"system-prompt" # kilo
	"AGENTS.md"     # kiro
	"config"        # aider (.aider.conf.yml)
	"AGENTS.md"     # amp
	"AGENTS.md"     # kimi
	"AGENTS.md"     # qwen (QWEN.md)
)

# --- Session database paths ---
# Where the runtime stores session/conversation history.
# Use $HOME; expanded at lookup time.
_RT_SESSION_DB=(
	"\$HOME/.local/share/opencode/opencode.db"                                            # opencode (SQLite)
	"\$HOME/.claude/projects"                                                             # claude-code (JSONL dir)
	"\$CODEX_HOME/sessions"                                                               # codex (JSONL, date-partitioned)
	"\$HOME/Library/Application Support/Cursor/User/workspaceStorage"                     # cursor (SQLite state.vscdb per workspace)
	"\$HOME/.factory/sessions"                                                            # droid (JSONL per session)
	"\$HOME/.gemini/tmp"                                                                  # gemini-cli (JSON per session, per project hash)
	"\$HOME/.codeium/windsurf/cascade"                                                    # windsurf (protobuf, opaque schema)
	"\$HOME/.continue/sessions"                                                           # continue (JSON per session)
	"\$HOME/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks" # kilo (JSON per task — Anthropic schema)
	"\$HOME/Library/Application Support/Kiro/User/workspaceStorage"                       # kiro (SQLite state.vscdb)
	""                                                                                    # aider (per-repo .aider.chat.history.md)
	""                                                                                    # amp (messages stored server-side)
	"\$HOME/.kimi/sessions"                                                               # kimi (JSONL: context.jsonl per session dir)
	"\$HOME/.qwen/tmp"                                                                    # qwen (JSON per session, per project hash)
)

# --- Session DB format ---
# Values: sqlite, jsonl-dir, json-dir, jsonl, json, protobuf, markdown, ""
_RT_SESSION_DB_FORMAT=(
	"sqlite"    # opencode
	"jsonl-dir" # claude-code
	"jsonl-dir" # codex
	"sqlite"    # cursor
	"jsonl-dir" # droid
	"json-dir"  # gemini-cli
	"protobuf"  # windsurf
	"json-dir"  # continue
	"json-dir"  # kilo
	"sqlite"    # kiro
	""          # aider
	""          # amp
	"jsonl-dir" # kimi
	"json-dir"  # qwen
)

# --- Vault-managed session/history support ---
_RT_VAULT_MODE_UNMANAGED="unmanaged"

# Values:
#   managed     aidevops can route this runtime's session/history store behind
#               the local Vault managed-history boundary when enabled.
#   unmanaged   known session/history store exists, but migration/broker support
#               is not implemented yet; callers must warn instead of claiming
#               Vault protection.
#   external    runtime stores history outside local aidevops control.
#   none        no known local history path.
_RT_VAULT_SESSION_HISTORY_MODE=(
	"managed"                   # opencode (SQLite path can be relocated to Vault-managed root)
	"managed"                   # claude-code (JSONL project dir can be relocated to Vault-managed root)
	"$_RT_VAULT_MODE_UNMANAGED" # codex
	"$_RT_VAULT_MODE_UNMANAGED" # cursor
	"$_RT_VAULT_MODE_UNMANAGED" # droid
	"$_RT_VAULT_MODE_UNMANAGED" # gemini-cli
	"$_RT_VAULT_MODE_UNMANAGED" # windsurf
	"$_RT_VAULT_MODE_UNMANAGED" # continue
	"$_RT_VAULT_MODE_UNMANAGED" # kilo
	"$_RT_VAULT_MODE_UNMANAGED" # kiro
	"none"                      # per-repo markdown, not centrally managed
	"external"                  # amp (server-side)
	"$_RT_VAULT_MODE_UNMANAGED" # kimi
	"$_RT_VAULT_MODE_UNMANAGED" # qwen
)

# Vault-managed path relative to ${AIDEVOPS_VAULT_MANAGED_HISTORY_ROOT}.
# Use "-" when the runtime is unsupported or externally hosted.
_RT_VAULT_SESSION_HISTORY_RELATIVE_PATH=(
	"opencode/opencode.db" # opencode
	"claude-code/projects" # claude-code
	"-"                    # codex
	"-"                    # cursor
	"-"                    # droid
	"-"                    # gemini-cli
	"-"                    # windsurf
	"-"                    # continue
	"-"                    # kilo
	"-"                    # kiro
	"-"                    # per-repo markdown
	"-"                    # amp
	"-"                    # kimi
	"-"                    # qwen
)

# --- Process patterns (for pgrep/ps detection of running instances) ---
_RT_PROCESS_PATTERN=(
	"opencode" # opencode
	"claude"   # claude-code
	"codex"    # codex
	"cursor"   # cursor (Electron app name)
	"droid"    # droid
	"gemini"   # gemini-cli
	"windsurf" # windsurf (Electron app name)
	"continue" # continue
	"kilo"     # kilo
	"kiro"     # kiro
	"aider"    # aider (Python process)
	"amp"      # amp
	"kimi"     # kimi
	"qwen"     # qwen
)

# --- Agent directories (where the runtime loads agent definitions) ---
# Runtimes that support user-defined agents via markdown + YAML frontmatter.
# Empty string means "no agent directory support".
_RT_AGENT_DIR=(
	""                      # opencode (agents via config, not directory)
	"\$HOME/.claude/agents" # claude-code
	""                      # codex (no agent dir)
	"\$HOME/.cursor/agents" # cursor
	""                      # droid (no agent dir)
	""                      # gemini-cli (no agent dir)
	""                      # windsurf (no agent dir)
	""                      # continue (no agent dir)
	""                      # kilo (uses custom modes, not agents)
	""                      # kiro (no agent dir)
	""                      # aider (no agent dir)
	"\$HOME/.amp/agents"    # amp
	"\$HOME/.kimi/agents"   # kimi (custom main agents via --agent-file)
	"\$HOME/.qwen/agents"   # qwen (sub-agents: name, description, model, tools)
)

# --- Headless support (can the runtime run without a UI?) ---
# "yes" = has a headless/CLI mode, "no" = GUI/editor only, "" = unknown
_RT_HEADLESS_SUPPORT=(
	"yes" # opencode
	"yes" # claude-code
	"yes" # codex
	"no"  # cursor (editor-only)
	"yes" # droid
	"yes" # gemini-cli
	"no"  # windsurf (editor-only)
	"no"  # continue (editor extension)
	"yes" # kilo
	"no"  # kiro (editor-only)
	"yes" # aider
	"yes" # amp
	"yes" # kimi
	"yes" # qwen
)

# --- Headless cmdline patterns (regex to identify headless/worker instances) ---
# Used by session-count-helper.sh to exclude headless workers from interactive counts.
# Empty string means "no headless mode" (all instances are interactive).
_RT_HEADLESS_CMDLINE_PATTERN=(
	"\\.opencode run "         # opencode — headless via "run" subcommand
	"claude (-p|--print|run) " # claude-code — headless via -p, --print, or run
	"codex exec "              # codex — only exec is headless
	""                         # cursor — no headless mode
	"droid run "               # droid — headless via "run" subcommand
	"gemini "                  # gemini-cli — all CLI invocations are headless
	""                         # windsurf — no headless mode
	""                         # continue — no headless mode
	"kilo run "                # kilo — headless via "run" subcommand
	""                         # kiro — no headless mode
	"aider --yes "             # aider — headless via --yes flag
	"amp run "                 # amp — headless via "run" subcommand
	"kimi "                    # kimi — all CLI invocations are headless
	"qwen "                    # qwen — all CLI invocations are headless
)

# --- pgrep mode (how to find processes for this runtime) ---
# "x" = pgrep -x (exact binary name match)
# "f" = pgrep -f (full command line match, for runtimes whose binary
#       name differs from the process pattern, e.g., opencode runs as .opencode)
_RT_PGREP_MODE=(
	"f" # opencode — binary is .opencode in PATH, needs -f
	"x" # claude-code — exact match on "claude"
	"x" # codex
	"f" # cursor — match Cursor.app in cmdline
	"x" # droid
	"x" # gemini-cli
	"f" # windsurf — match Windsurf in cmdline
	"f" # continue — match in cmdline
	"x" # kilo
	"x" # kiro
	"f" # aider — Python process, needs -f
	"x" # amp
	"x" # kimi
	"x" # qwen
)

# --- pgrep search pattern (what to pass to pgrep) ---
# May differ from _RT_PROCESS_PATTERN when pgrep mode is "f" (full cmdline).
_RT_PGREP_PATTERN=(
	"\\.opencode"  # opencode — binary is .opencode
	"claude"       # claude-code
	"codex"        # codex
	"Cursor\\.app" # cursor
	"droid"        # droid
	"gemini"       # gemini-cli
	"Windsurf"     # windsurf
	"continue"     # continue
	"kilo"         # kilo
	"kiro"         # kiro
	"aider"        # aider
	"amp"          # amp
	"kimi"         # kimi
	"qwen"         # qwen
)

# --- Process exclusion patterns (noise to filter out) ---
# grep -E patterns for processes that match the pgrep pattern but are NOT
# actual runtime sessions (language servers, node wrappers, etc.).
# Empty string means "no exclusions needed".
_RT_PROCESS_EXCLUSION=(
	"(typescript-language-server|eslintServer|vscode-)|^node .*/bin/opencode" # opencode
	""                                                                        # claude-code
	""                                                                        # codex
	""                                                                        # cursor
	""                                                                        # droid
	""                                                                        # gemini-cli
	""                                                                        # windsurf
	""                                                                        # continue
	""                                                                        # kilo
	""                                                                        # kiro
	""                                                                        # aider
	""                                                                        # amp
	""                                                                        # kimi
	""                                                                        # qwen
)

# =============================================================================
# Feature Flags (parallel to _RT_IDS)
# =============================================================================
# Per-runtime toggles for which aidevops features are enabled during setup.
# Values: "yes" / "no".
#
# Defaults:
#   - agents installation:   yes for all runtimes
#   - commands installation: yes for all runtimes
#   - memory mining:         yes for opencode/claude-code/codex/cursor only;
#                            no for all others (opt-in per-runtime)
#
# Override at runtime via environment variables:
#   AIDEVOPS_FEATURE_AGENTS_<SUFFIX>=no
#   AIDEVOPS_FEATURE_COMMANDS_<SUFFIX>=no
#   AIDEVOPS_FEATURE_MEMORY_<SUFFIX>=yes
# where <SUFFIX> is the uppercased runtime ID with hyphens → underscores
# (e.g. CLAUDE_CODE, GEMINI_CLI).

# --- Agent installation flag ---
_RT_FEATURE_AGENTS=(
	"yes" # opencode
	"yes" # claude-code
	"yes" # codex
	"yes" # cursor
	"yes" # droid
	"yes" # gemini-cli
	"yes" # windsurf
	"yes" # continue
	"yes" # kilo
	"yes" # kiro
	"yes" # aider
	"yes" # amp
	"yes" # kimi
	"yes" # qwen
)

# --- Commands installation flag ---
_RT_FEATURE_COMMANDS=(
	"yes" # opencode
	"yes" # claude-code
	"yes" # codex
	"yes" # cursor
	"yes" # droid
	"yes" # gemini-cli
	"yes" # windsurf (via .windsurf/workflows/ symlink from `aidevops init`)
	"yes" # continue
	"yes" # kilo
	"yes" # kiro
	"yes" # aider
	"yes" # amp    (via repo-local .agents/commands/ — path match is native)
	"yes" # kimi
	"yes" # qwen
)

# --- Memory mining flag ---
# Whether aidevops attempts to mine this runtime's session history for
# cross-session memory recall. Defaults: Y only for runtimes with trivially
# mineable, stable, documented session formats that the user explicitly
# opted in to via this framework's design (opencode, claude-code, codex, cursor).
_RT_FEATURE_MEMORY=(
	"yes" # opencode     (SQLite — easy)
	"yes" # claude-code  (JSONL dir — easy)
	"yes" # codex        (JSONL dir — easy)
	"yes" # cursor       (SQLite state.vscdb — moderate but stable)
	"no"  # droid        (easy but off by default — opt-in)
	"no"  # gemini-cli   (easy but off by default — opt-in)
	"no"  # windsurf     (protobuf, schema opaque)
	"no"  # continue     (easy but off by default — opt-in)
	"no"  # kilo         (easy but off by default — opt-in)
	"no"  # kiro         (SQLite, off by default — opt-in)
	"no"  # aider        (markdown, per-repo, needs splitter)
	"no"  # amp          (cloud-only, needs API auth)
	"no"  # kimi         (easy but off by default — opt-in)
	"no"  # qwen         (easy but off by default — opt-in)
)

# =============================================================================
# Internal: Index Lookup
# =============================================================================
# Returns the array index for a given runtime ID, or 1 if not found.
# This is the core lookup used by all rt_* functions.

_rt_index() {
	local id="$1"
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ "${_RT_IDS[$i]}" == "$id" ]]; then
			echo "$i"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# Expand $HOME in a path string.
# Handles the "\$HOME" literal stored in arrays (to avoid premature expansion).
_rt_expand_path() {
	local path="$1"
	local codex_home="${CODEX_HOME:-$HOME/.codex}"
	path="${path//\$CODEX_HOME/$codex_home}"
	# Replace literal $HOME or \$HOME with actual HOME value
	path="${path//\\\$HOME/$HOME}"
	path="${path//\$HOME/$HOME}"
	echo "$path"
	return 0
}

# Convert a runtime ID into its uppercase env-var suffix form
# (hyphens → underscores, lowercase → uppercase). e.g. "claude-code" → "CLAUDE_CODE".
# Uses tr so it works in Bash 3.2 (no ${var^^}).
_rt_env_suffix() {
	local id="$1"
	local suffix="${id//-/_}"
	echo "$suffix" | tr '[:lower:]' '[:upper:]'
}

# =============================================================================
# Public API: Property Lookups
# =============================================================================
# All functions take a runtime ID as $1 and print the value to stdout.
# Return 0 on success, 1 if the runtime ID is unknown.
# Empty string output means "not applicable" for that runtime.

rt_binary() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_BINARY[$idx]}"
	return 0
}

rt_display_name() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_DISPLAY_NAME[$idx]}"
	return 0
}

rt_version() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	local cmd="${_RT_VERSION_CMD[$idx]}"
	if [[ -z "$cmd" ]]; then
		echo "unknown"
		return 0
	fi
	local ver
	ver=$(eval "$cmd" 2>/dev/null) || ver="unknown"
	echo "${ver:-unknown}"
	return 0
}

rt_config_path() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	local path
	path=$(_rt_expand_path "${_RT_CONFIG_PATH[$idx]}")

	# Platform-aware override for claude-code: config location varies by install type.
	# Priority order:
	#   1. ~/.claude.json          — Claude Code CLI (global MCP config, all platforms)
	#   2. ~/Library/.../claude_desktop_config.json — Claude Desktop macOS
	#   3. ~/.config/Claude/Claude.json             — Claude Code CLI Linux fallback
	if [[ "$id" == "claude-code" ]]; then
		local cli_path="$HOME/.claude.json"
		local macos_path="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
		local linux_path="$HOME/.config/Claude/Claude.json"
		if [[ -f "$cli_path" ]]; then
			echo "$cli_path"
			return 0
		elif [[ -f "$macos_path" ]]; then
			echo "$macos_path"
			return 0
		elif [[ -f "$linux_path" ]]; then
			echo "$linux_path"
			return 0
		fi
		# None found — fall through to return the registry default (may not exist)
	fi

	echo "$path"
	return 0
}

rt_config_format() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_CONFIG_FORMAT[$idx]}"
	return 0
}

rt_mcp_root_key() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_MCP_ROOT_KEY[$idx]}"
	return 0
}

rt_command_dir() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	_rt_expand_path "${_RT_COMMAND_DIR[$idx]}"
	return 0
}

rt_agent_dir() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	_rt_expand_path "${_RT_AGENT_DIR[$idx]}"
	return 0
}

rt_prompt_mechanism() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_PROMPT_MECHANISM[$idx]}"
	return 0
}

rt_session_db() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	_rt_expand_path "${_RT_SESSION_DB[$idx]}"
	return 0
}

rt_session_db_format() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_SESSION_DB_FORMAT[$idx]}"
	return 0
}

rt_vault_session_history_mode() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_VAULT_SESSION_HISTORY_MODE[$idx]}"
	return 0
}

rt_vault_session_history_relative_path() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_VAULT_SESSION_HISTORY_RELATIVE_PATH[$idx]}"
	return 0
}

rt_vault_session_history_path() {
	local id="$1"
	local rel root
	rel=$(rt_vault_session_history_relative_path "$id") || return 1
	if [[ -z "$rel" || "$rel" == "-" ]]; then
		printf '\n'
		return 0
	fi
	root="${AIDEVOPS_VAULT_MANAGED_HISTORY_ROOT:-$HOME/.aidevops/.agent-workspace/vault/managed-session-history}"
	echo "${root%/}/$rel"
	return 0
}

rt_process_pattern() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_PROCESS_PATTERN[$idx]}"
	return 0
}

rt_headless_support() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_HEADLESS_SUPPORT[$idx]}"
	return 0
}

rt_headless_cmdline_pattern() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_HEADLESS_CMDLINE_PATTERN[$idx]}"
	return 0
}

rt_pgrep_mode() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_PGREP_MODE[$idx]}"
	return 0
}

rt_pgrep_pattern() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_PGREP_PATTERN[$idx]}"
	return 0
}

rt_process_exclusion() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_PROCESS_EXCLUSION[$idx]}"
	return 0
}

# --- Feature flag lookups ---
# Each reads the registry default and honours an env-var override:
#   AIDEVOPS_FEATURE_<FEATURE>_<RUNTIME_SUFFIX>   (value: "yes" | "no")
# Prints "yes" or "no" (never empty for a known runtime).

rt_feature_agents() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	local suffix varname override
	suffix=$(_rt_env_suffix "$id")
	varname="AIDEVOPS_FEATURE_AGENTS_${suffix}"
	override="${!varname:-}"
	if [[ "$override" == "yes" || "$override" == "no" ]]; then
		echo "$override"
		return 0
	fi
	echo "${_RT_FEATURE_AGENTS[$idx]}"
	return 0
}

rt_feature_commands() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	local suffix varname override
	suffix=$(_rt_env_suffix "$id")
	varname="AIDEVOPS_FEATURE_COMMANDS_${suffix}"
	override="${!varname:-}"
	if [[ "$override" == "yes" || "$override" == "no" ]]; then
		echo "$override"
		return 0
	fi
	echo "${_RT_FEATURE_COMMANDS[$idx]}"
	return 0
}

rt_feature_memory() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	local suffix varname override
	suffix=$(_rt_env_suffix "$id")
	varname="AIDEVOPS_FEATURE_MEMORY_${suffix}"
	override="${!varname:-}"
	if [[ "$override" == "yes" || "$override" == "no" ]]; then
		echo "$override"
		return 0
	fi
	echo "${_RT_FEATURE_MEMORY[$idx]}"
	return 0
}

# =============================================================================
# Public API: Enumeration and Detection
# =============================================================================

# Print all runtime IDs, one per line.
rt_list_ids() {
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		echo "${_RT_IDS[$i]}"
		i=$((i + 1))
	done
	return 0
}

# Print the total number of registered runtimes.
rt_count() {
	echo "$_RT_COUNT"
	return 0
}

# Detect which runtimes are installed (binary in PATH or config dir exists).
# Prints installed runtime IDs, one per line.
# Returns 0 if at least one found, 1 if none.
# Note: GUI/editor runtimes (cursor, windsurf, kiro, continue) may not ship
# a PATH binary — fall back to checking their config directory.
rt_detect_installed() {
	local found=0
	local i=0
	local bin config_path config_dir
	while [[ $i -lt $_RT_COUNT ]]; do
		bin="${_RT_BINARY[$i]}"
		# Use type -P to find only filesystem executables — command -v matches
		# shell builtins (e.g., "continue") causing false positives.
		if [[ -n "$bin" ]] && type -P "$bin" >/dev/null 2>&1; then
			echo "${_RT_IDS[$i]}"
			found=1
		else
			# Fallback: check if the runtime's config directory exists.
			# Editor-only runtimes (cursor, windsurf, kiro, continue) often
			# don't have a PATH binary but do have a config directory.
			config_path="${_RT_CONFIG_PATH[$i]}"
			if [[ -n "$config_path" ]]; then
				config_path=$(_rt_expand_path "$config_path")
				config_dir="$(dirname "$config_path")"
				if [[ -d "$config_dir" ]]; then
					echo "${_RT_IDS[$i]}"
					found=1
				fi
			fi
		fi
		i=$((i + 1))
	done
	if [[ $found -eq 1 ]]; then
		return 0
	fi
	return 1
}

# Detect which runtimes have MCP config files present.
# Prints runtime IDs with existing config files, one per line.
rt_detect_configured() {
	local found=0
	local i=0
	local path
	while [[ $i -lt $_RT_COUNT ]]; do
		path="${_RT_CONFIG_PATH[$i]}"
		if [[ -n "$path" ]]; then
			path=$(_rt_expand_path "$path")
			if [[ -f "$path" ]]; then
				echo "${_RT_IDS[$i]}"
				found=1
			fi
		fi
		i=$((i + 1))
	done
	if [[ $found -eq 1 ]]; then
		return 0
	fi
	return 1
}

# Detect which runtimes have running processes.
# Prints runtime IDs with detected processes, one per line.
rt_detect_running() {
	local found=0
	local i=0
	local pattern
	while [[ $i -lt $_RT_COUNT ]]; do
		pattern="${_RT_PROCESS_PATTERN[$i]}"
		if [[ -n "$pattern" ]] && pgrep -x "$pattern" >/dev/null 2>&1; then
			echo "${_RT_IDS[$i]}"
			found=1
		fi
		i=$((i + 1))
	done
	if [[ $found -eq 1 ]]; then
		return 0
	fi
	return 1
}

# Look up a runtime ID by its binary name.
# Useful for reverse lookups (e.g., "which runtime is 'claude'?").
# Returns 0 and prints the ID, or 1 if not found.
rt_id_from_binary() {
	local bin="$1"
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ "${_RT_BINARY[$i]}" == "$bin" ]]; then
			echo "${_RT_IDS[$i]}"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# List runtimes that support headless operation.
# Prints runtime IDs, one per line.
rt_list_headless() {
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ "${_RT_HEADLESS_SUPPORT[$i]}" == "yes" ]]; then
			echo "${_RT_IDS[$i]}"
		fi
		i=$((i + 1))
	done
	return 0
}

# List runtimes that have slash command directories.
# Prints runtime IDs, one per line.
rt_list_with_commands() {
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ -n "${_RT_COMMAND_DIR[$i]}" ]]; then
			echo "${_RT_IDS[$i]}"
		fi
		i=$((i + 1))
	done
	return 0
}

# List runtimes that have agent directories.
# Prints runtime IDs, one per line.
rt_list_with_agents() {
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ -n "${_RT_AGENT_DIR[$i]}" ]]; then
			echo "${_RT_IDS[$i]}"
		fi
		i=$((i + 1))
	done
	return 0
}

# List runtimes where commands installation is enabled.
rt_list_commands_enabled() {
	local id
	for id in $(rt_list_ids); do
		if [[ "$(rt_feature_commands "$id")" == "yes" ]]; then
			echo "$id"
		fi
	done
	return 0
}

# List runtimes where agents installation is enabled.
rt_list_agents_enabled() {
	local id
	for id in $(rt_list_ids); do
		if [[ "$(rt_feature_agents "$id")" == "yes" ]]; then
			echo "$id"
		fi
	done
	return 0
}

# List runtimes where session memory mining is enabled.
rt_list_memory_enabled() {
	local id
	for id in $(rt_list_ids); do
		if [[ "$(rt_feature_memory "$id")" == "yes" ]]; then
			echo "$id"
		fi
	done
	return 0
}

# =============================================================================
# Validation (called by test suite, safe to call at source time)
# =============================================================================
# Verifies all parallel arrays have the same length as _RT_IDS.
# Returns 0 if valid, 1 if misaligned (prints which array is wrong).

rt_validate_registry() {
	local errors=0
	local arrays=(
		"_RT_BINARY"
		"_RT_VERSION_CMD"
		"_RT_DISPLAY_NAME"
		"_RT_CONFIG_PATH"
		"_RT_CONFIG_FORMAT"
		"_RT_MCP_ROOT_KEY"
		"_RT_COMMAND_DIR"
		"_RT_AGENT_DIR"
		"_RT_PROMPT_MECHANISM"
		"_RT_SESSION_DB"
		"_RT_SESSION_DB_FORMAT"
		"_RT_VAULT_SESSION_HISTORY_MODE"
		"_RT_VAULT_SESSION_HISTORY_RELATIVE_PATH"
		"_RT_PROCESS_PATTERN"
		"_RT_HEADLESS_SUPPORT"
		"_RT_HEADLESS_CMDLINE_PATTERN"
		"_RT_PGREP_MODE"
		"_RT_PGREP_PATTERN"
		"_RT_PROCESS_EXCLUSION"
		"_RT_FEATURE_AGENTS"
		"_RT_FEATURE_COMMANDS"
		"_RT_FEATURE_MEMORY"
	)

	local arr_name
	for arr_name in "${arrays[@]}"; do
		local count_cmd="${arr_name}[@]"
		local arr_vals=("${!count_cmd}")
		local arr_len=${#arr_vals[@]}
		if [[ $arr_len -ne $_RT_COUNT ]]; then
			echo "MISALIGNED: $arr_name has $arr_len elements, expected $_RT_COUNT" >&2
			errors=$((errors + 1))
		fi
	done

	if [[ $errors -gt 0 ]]; then
		return 1
	fi
	return 0
}
