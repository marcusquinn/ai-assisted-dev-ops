#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Runtime Config Generator -- Agent Generation Sub-Library
# =============================================================================
# Agent discovery, greeting template generation, subagent stub generation,
# and per-runtime agent configuration (OpenCode, Claude Code).
#
# Usage: source "${SCRIPT_DIR}/generate-runtime-config-agents.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - runtime-registry.sh (rt_display_name, rt_command_dir, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_GENERATE_RUNTIME_CONFIG_AGENTS_LIB_LOADED:-}" ]] && return 0
_GENERATE_RUNTIME_CONFIG_AGENTS_LIB_LOADED=1
_GENERATE_RUNTIME_CONFIG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Phase 1: Shared Content -- Agent Definitions
# =============================================================================
# Agent auto-discovery from ~/.aidevops/agents/*.md is handled by the Python
# code in _generate_agents_opencode() and _generate_agents_claude() since it
# requires frontmatter parsing, JSON manipulation, and complex data structures
# that are better suited to Python than bash 3.2.
#
# The Python code is shared via a heredoc function that both runtimes call
# with runtime-specific parameters.

# Generate the shared Python agent discovery code.
# This is the single source of truth for agent definitions, tool assignments,
# model tiers, and MCP loading policy.
# Arguments:
#   $1 - runtime_id (opencode, claude-code)
#   $2 - output format (opencode-json, claude-settings)
_run_agent_discovery_python() {
	local runtime_id="$1"
	local output_format="$2"
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	python3 "$script_dir/agent-discovery.py" "$runtime_id" "$output_format"
	return $?
}

# =============================================================================
# Phase 2a: Agent Generation -- Per-Runtime Adapters
# =============================================================================

# Shared helper: write ~/.config/<runtime>/AGENTS.md with the authoritative
# plugin-injection precedence and cache/VERSION greeting fallback.
# Arguments:
#   $1 - runtime_id (e.g. "opencode", "claude-code")
#   $2 - config_dir (e.g. "$HOME/.config/opencode")
# Returns: 0 on success
_generate_greeting_agents_md() {
	local runtime_id="$1"
	local config_dir="$2"

	local display_name
	display_name=$(rt_display_name "$runtime_id" 2>/dev/null || echo "Unknown Runtime")

	# Per-runtime cache path and plugin name.
	# SC2088: tilde is intentionally literal here -- written to AGENTS.md
	# as documentation for the model, not expanded as a shell path.
	local cache_path plugin_name global_config_path
	case "$runtime_id" in
	opencode)
		# shellcheck disable=SC2088
		cache_path="~/.aidevops/cache/session-greeting-opencode.txt"
		plugin_name="opencode-aidevops plugin"
		# shellcheck disable=SC2088
		global_config_path="~/.config/opencode/opencode.json"
		;;
	claude-code)
		# shellcheck disable=SC2088
		cache_path="~/.aidevops/cache/session-greeting-claude-code.txt"
		plugin_name="Claude-aidevops plugin"
		# shellcheck disable=SC2088
		global_config_path="~/.config/Claude/Claude.json"
		;;
	*)
		# shellcheck disable=SC2088
		cache_path="~/.aidevops/cache/session-greeting-${runtime_id}.txt"
		plugin_name="${runtime_id}-aidevops plugin"
		# shellcheck disable=SC2088
		global_config_path="~/.config/${runtime_id}/${runtime_id}.json"
		;;
	esac

	mkdir -p "$config_dir"

	cat >"$config_dir/AGENTS.md" <<EOF
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.

**Runtime**: You are running in ${display_name}. Global config: \`${global_config_path}\`.

## aidevops Framework Status

The ${plugin_name} renders session-start framework status (versions,
security posture, advisories, update hints) as a TUI toast before your first
turn. Raw output is cached at \`${cache_path}\`. The
user has already seen it — do NOT re-run \`aidevops-update-check.sh\` and do
NOT repeat toast content in the chat.

**On interactive conversation start** (skip only when the runtime is actually headless; a slash-command name such as \`/full-loop\` does not make an interactive session headless):

1. If an earlier system instruction declares itself the authoritative plugin-injected greeting block and supplies exact version values, follow it. Its first-visible-text requirement does not prevent task tool calls from running first. Do not read the cache or VERSION first.
2. Otherwise, the plugin injection is unavailable. Read line 1 of \`${cache_path}\`. Format: \`aidevops v{X} running in ${display_name} v{Y} | ...\`. Extract \`{X}\` and \`{Y}\`, then make the first visible text in your first assistant response exactly this template — no extra prose, no status dump:

       Hi!

       We're running aidevops v{X} in ${display_name} v{Y}.

       What would you like to work on?

3. In that fallback path, if the cache file is missing, read \`~/.aidevops/agents/VERSION\` for \`{X}\` and greet: "Hi!\n\nWe're running aidevops v{X}.\n\nWhat would you like to work on?"
4. Then respond to the user's actual message. If the user launched the session with an initial task, start its tool work immediately (before visible text when the runtime cannot interleave text and tools), then prefix the first visible response with the greeting. Never emit a greeting-only response. Never emit both the injected greeting and the fallback greeting.

If the user later asks about aidevops updates, direct them to run \`aidevops update\` in a terminal session (or type \`!aidevops update\` below). Do not announce updates unprompted — the toast already did.

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
EOF
	print_success "Updated ${config_dir}/AGENTS.md with ${display_name} greeting template (t2766)"
	return 0
}

_generate_agents_opencode() {
	print_info "Generating OpenCode agent configuration..."

	local opencode_config_dir="$HOME/.config/opencode"
	local opencode_agent_dir="$opencode_config_dir/agent"
	local opencode_config="$opencode_config_dir/opencode.json"

	mkdir -p "$opencode_agent_dir"

	# Deploy AGENTS.md with concise greeting template (t2736, parameterized t2766)
	# The opencode-aidevops plugin already renders full framework status as a
	# session-start toast; the model must NOT re-run aidevops-update-check.sh
	# or dump toast content into the chat. Greeting is a one-liner sourced
	# from the pre-populated cache file.
	_generate_greeting_agents_md "opencode" "$opencode_config_dir"

	# Remove legacy agent files
	local legacy_files=(
		"Accounts.md" "Accounting.md" "accounting.md" "AI-DevOps.md" "Build+.md" "Content.md"
		"Health.md" "Legal.md" "Marketing.md" "Research.md" "Sales.md" "SEO.md" "WordPress.md"
		"Plan+.md" "Build-Agent.md" "Build-MCP.md" "build-agent.md" "build-mcp.md"
		"plan-plus.md" "aidevops.md" "Browser-Extension-Dev.md" "Mobile-App-Dev.md" "AGENTS.md"
	)
	local f
	for f in "${legacy_files[@]}"; do
		rm -f "$opencode_agent_dir/$f"
	done

	# Remove loop-state files incorrectly created as agents
	for f in ralph-loop.local.md quality-loop.local.md full-loop.local.md loop-state.md re-anchor.md postflight-loop.md; do
		rm -f "$opencode_agent_dir/$f"
	done

	# Create minimal config if missing
	if [[ ! -f "$opencode_config" ]]; then
		print_warning "$opencode_config not found. Creating minimal config."
		# shellcheck disable=SC2016
		echo '{"$schema": "https://opencode.ai/config.json"}' >"$opencode_config"
	fi

	# Run shared Python agent discovery for OpenCode
	_run_agent_discovery_python "opencode" "opencode-json"

	print_success "Primary agents configured in opencode.json"

	# Generate subagent markdown files
	_generate_subagents_opencode "$opencode_agent_dir"

	# Sync MCP tool index
	local mcp_index_helper="$AGENTS_DIR/scripts/mcp-index-helper.sh"
	if [[ -x "$mcp_index_helper" ]]; then
		if "$mcp_index_helper" sync 2>/dev/null; then
			print_success "MCP tool index updated"
		else
			print_warning "MCP index sync skipped (non-critical)"
		fi
	fi

	return 0
}

# Determine additional MCP tools for a subagent based on its name.
# Arguments: $1 - subagent name (basename without .md)
# Outputs: extra tool lines to stdout (empty if none)
_get_subagent_extra_tools() {
	local name="$1"

	case "$name" in
	outscraper)
		printf '%s\n' '  outscraper_*: true' '  webfetch: true'
		;;
	mainwp | localwp)
		printf '%s\n' '  localwp_*: true'
		;;
	quickfile)
		printf '%s\n' '  quickfile_*: true'
		;;
	google-search-console)
		printf '%s\n' '  gsc_*: true'
		;;
	dataforseo)
		printf '%s\n' '  dataforseo_*: true' '  webfetch: true'
		;;
	claude-code)
		printf '%s\n' '  claude-code-mcp_*: true'
		;;
	openapi-search)
		printf '%s\n' '  openapi-search_*: true' '  webfetch: true'
		;;
	aidevops)
		printf '%s\n' '  openapi-search_*: true'
		;;
	playwriter)
		printf '%s\n' '  playwriter_*: true'
		;;
	shadcn)
		printf '%s\n' '  shadcn_*: true' '  write: true' '  edit: true'
		;;
	macos-automator | mac)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			printf '%s\n' '  macos-automator_*: true' '  webfetch: true'
		fi
		;;
	ios-simulator-mcp)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			printf '%s\n' '  ios-simulator_*: true'
		fi
		;;
	*) ;;
	esac
	return 0
}

# Quote a scalar for YAML frontmatter. OpenCode parses agent frontmatter as
# YAML; an unquoted description containing ':' can make the whole block invalid,
# which can cause a subagent stub to appear in the primary tab cycle.
_yaml_quote_scalar() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '"%s"' "$value"
	return 0
}

# Read the runtime guard fields that a generated wrapper must preserve from
# source frontmatter. The wrapper prompt reads the source body at runtime, but
# OpenCode resolves variant, steps, and tool availability before that happens.
# Outputs one pipe-separated row: variant, steps, task, model. Pipes preserve
# empty leading fields under Bash 3.2, unlike whitespace IFS delimiters.
_read_subagent_runtime_guards() {
	local f="$1"
	awk '
		function value_after_colon(line, value) {
			value = line
			sub(/^[^:]+:[[:space:]]*/, "", value)
			sub(/[[:space:]]+#.*$/, "", value)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			return value
		}
		/^---$/ {
			frontmatter_delimiters++
			if (frontmatter_delimiters == 2) exit
			next
		}
		frontmatter_delimiters != 1 { next }
		/^tools:[[:space:]]*$/ { in_tools = 1; next }
		/^[^[:space:]]/ { in_tools = 0 }
		/^variant:[[:space:]]*/ { variant = value_after_colon($0); next }
		/^steps:[[:space:]]*/ { steps = value_after_colon($0); next }
		/^model:[[:space:]]*/ { model = value_after_colon($0); next }
		in_tools && /^[[:space:]]+task:[[:space:]]*/ { task = value_after_colon($0); next }
		END { printf "%s|%s|%s|%s\n", variant, steps, task, model }
	' "$f" 2>/dev/null
	return 0
}

_write_restrictive_subagent_source() {
	local source_file="$1"
	local output_file="$2"
	local routing_tier="$3"
	if ! awk -v routing_tier="$routing_tier" '
		/^model: (simple|standard|thinking)$/ {
			if (routing_tier != "") print "aidevops_model_tier: " routing_tier
			next
		}
		{ print }
	' "$source_file" >"$output_file"; then
		return 1
	fi
	return 0
}

# Write a single subagent markdown stub file.
# Arguments: $1 - source .md file path
# Requires: AGENTS_DIR and agent_dir to be set (exported for xargs usage)
# Outputs: "1" to stdout on success (for counting)
_validated_worktree_base() {
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
	printf '%s\n' "$worktree_base"
	return 0
}

_write_subagent_stub() {
	local f="$1"
	local name
	name=$(basename "$f" .md)
	[[ "$name" == "AGENTS" || "$name" == "README" ]] && return 0

	local rel_path="${f#"$AGENTS_DIR"/}"
	local runtime_guards src_variant src_steps src_task src_model
	runtime_guards=$(_read_subagent_runtime_guards "$f")
	IFS='|' read -r src_variant src_steps src_task src_model <<<"$runtime_guards"
	local routed_model="$src_model" routing_tier=""
	case "$src_model" in
	simple | standard | thinking)
		routing_tier="$src_model"
		routed_model=""
		;;
	"") routed_model="" ;;
	*/*) ;;
	*) routed_model="" ;;
	esac

	# GH#18509: If source frontmatter explicitly sets bash: false, the agent is
	# security-sandboxed or has its own tool restrictions. Copy source verbatim
	# (with workload-tier metadata resolved) instead of writing a permissive stub that
	# grants bash:true and external_directory:allow -- those would override the
	# source's intent and become an attack surface for prompt-injected content.
	local src_bash_false
	src_bash_false=$(awk '
		/^---$/ { fm_delim++; next }
		fm_delim == 1 && /bash:[[:space:]]*false/ { print; exit }
		fm_delim == 2 { exit }
	' "$f" 2>/dev/null)
	if [[ -n "$src_bash_false" ]]; then
		# Preserve the restrictive source verbatim while moving workload intent to
		# plugin metadata. The request hook selects a connected candidate later.
		_write_restrictive_subagent_source \
			"$f" "$agent_dir/$name.md" "$routing_tier" || return 1
		echo 1
		return 0
	fi

	# Extract description from source file frontmatter
	local src_desc
	src_desc=$(sed -n '/^---$/,/^---$/{ /^description:/{s/^description: *//p; q} }' "$f" 2>/dev/null)
	if [[ -z "$src_desc" ]]; then
		src_desc="Read ~/.aidevops/agents/${rel_path}"
	fi

	local extra_tools
	extra_tools=$(_get_subagent_extra_tools "$name")

	case "$src_variant" in
	none | minimal | low | medium | high | xhigh | max) ;;
	*) src_variant="" ;;
	esac
	[[ "$src_steps" =~ ^[1-9][0-9]*$ ]] || src_steps=""
	case "$src_task" in
	true | false) ;;
	*) src_task="" ;;
	esac

	local quoted_desc
	quoted_desc=$(_yaml_quote_scalar "$src_desc")
	local worktree_base=""
	worktree_base=$(_validated_worktree_base) || return 1

	{
		printf '%s\n' \
			"---" \
			"description: ${quoted_desc}" \
			"mode: subagent"
		[[ -n "$routing_tier" ]] && printf 'aidevops_model_tier: %s\n' "$routing_tier"
		[[ -n "$routed_model" ]] && printf 'model: %s\n' "$routed_model"
		[[ -n "$src_variant" ]] && printf 'variant: %s\n' "$src_variant"
		[[ -n "$src_steps" ]] && printf 'steps: %s\n' "$src_steps"
		printf '%s\n' \
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
		[[ -n "$src_task" ]] && printf '  task: %s\n' "$src_task"
		[[ -n "$extra_tools" ]] && printf '%s\n' "$extra_tools"
		printf '%s\n' \
			"---" \
			"" \
			"**MANDATORY**: Your first action MUST be to read ~/.aidevops/agents/${rel_path} and follow ALL rules within it."
	} >"$agent_dir/$name.md"
	echo 1
	return 0
}

# Remove previously generated subagent files (those with "mode: subagent" frontmatter).
# Arguments: $1 - agent output directory
_clean_generated_subagents() {
	local agent_dir="$1"
	find "$agent_dir" -name "*.md" -type f -exec grep -l "^mode: subagent" {} + 2>/dev/null | while IFS= read -r f; do rm -f "$f"; done
	return 0
}

# GH#19399 / t2149: Resolve basename collisions deterministically.
#
# Multiple source files with the same basename (e.g. `aidevops/architecture.md`
# vs `tools/diagrams/mermaid-diagrams-skill/architecture.md`) previously fed
# the parallel `xargs -P` write loop, where whichever subshell won the race
# wrote the deployed stub. When the permissive sibling won, the sandboxed
# source's `bash: false` / `webfetch: false` intent was silently lost.
#
# This function enumerates the same candidate set as the generator, groups by
# basename, and emits one path per basename:
#   - If any candidate declares `bash: false`, that one wins (restrictive
#     default -- preserves the sandbox the source maintainer expressed).
#   - Otherwise the alphabetically-first path wins (deterministic tiebreak).
#   - Every losing sibling is logged as a warning to stderr.
#
# Reads: AGENTS_DIR
# Writes: NUL-delimited list of winning source paths to stdout
#         Human-readable collision warnings to stderr
# Bash 3.2 compatible (no associative arrays; uses sort/awk).
_resolve_basename_collisions_for_generate() {
	local tmpfile
	tmpfile=$(mktemp 2>/dev/null || mktemp -t generate-runtime-config.XXXXXX)

	if [[ ! -d "${AGENTS_DIR:-}" ]]; then
		rm -f "$tmpfile"
		return 0
	fi

	# For each candidate source: record name, priority (0=restrictive, 1=permissive), path.
	# Priority 0 wins via ascending sort.
	find "$AGENTS_DIR" -mindepth 2 -name "*.md" -type f \
		-not -path "*/loop-state/*" -not -name "*-skill.md" -print0 2>/dev/null |
		while IFS= read -r -d '' f; do
			local name priority
			name=$(basename "$f" .md)
			[[ "$name" == "AGENTS" || "$name" == "README" ]] && continue
			priority=1
			if awk '/^---$/ { fm++; next } fm == 1 && /bash:[[:space:]]*false/ { print; exit } fm == 2 { exit }' "$f" 2>/dev/null | grep -q .; then
				priority=0
			fi
			printf '%s\t%d\t%s\n' "$name" "$priority" "$f" >>"$tmpfile"
		done

	# Sort: name asc, priority asc (restrictive first), path asc (alphabetical tiebreak).
	# Awk pass:
	#   - First row per name wins; emit the path to stdout (NUL-delimited).
	#   - Subsequent rows are collision losers.
	#   - Only emit a warning when the sandbox bug class applies: the winner
	#     has `bash: false` (priority 0) AND a loser doesn't, OR vice versa.
	#     Collisions between equally-permissive sources are noise (e.g. the
	#     numbered content files under tools/design/library/brands/*/*.md).
	#
	# Note on NUL emission: macOS awk (BSD, stock on Darwin) does NOT interpret
	# `\0` or embed NUL bytes via `%s` in printf. We use `printf "%c", 0` which
	# works on both GNU awk and macOS awk.
	sort -t$'\t' -k1,1 -k2,2n -k3,3 "$tmpfile" | awk -F'\t' '
		$1 != prev_name {
			printf "%s", $3
			printf "%c", 0
			winner = $3
			winner_priority = $2
			prev_name = $1
			next
		}
		{
			# Warn only when sandbox-intent is mixed across the collision set.
			if (winner_priority != $2) {
				printf "[WARN] basename collision for %s: %s (bash:%s) loses to %s (bash:%s)\n", \
					$1, $3, ($2 == 0 ? "false" : "default"), winner, (winner_priority == 0 ? "false" : "default") > "/dev/stderr"
			}
		}
	'

	rm -f "$tmpfile"
	return 0
}

# Generate subagent markdown stubs for OpenCode
_generate_subagents_opencode() {
	local agent_dir="$1"

	print_info "Generating subagent markdown files..."

	_clean_generated_subagents "$agent_dir"

	export -f _get_subagent_extra_tools 2>/dev/null || true
	export -f _yaml_quote_scalar 2>/dev/null || true
	export -f _read_subagent_runtime_guards 2>/dev/null || true
	export -f _write_restrictive_subagent_source 2>/dev/null || true
	export -f _validated_worktree_base 2>/dev/null || true
	export -f _write_subagent_stub 2>/dev/null || true
	export AGENTS_DIR
	export agent_dir
	export _GENERATE_RUNTIME_CONFIG_SCRIPT_DIR

	local _ncpu
	_ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
	local _parallel_jobs=$((_ncpu > 4 ? _ncpu : 4))
	local subagent_count
	# GH#19399: collision-resolver emits one path per basename (restrictive source wins).
	# Warnings to stderr surface any collisions; they're not fatal.
	subagent_count=$(_resolve_basename_collisions_for_generate |
		xargs -0 -P "$_parallel_jobs" -I {} bash -c '_write_subagent_stub "$@"' _ {} |
		awk '{sum+=$1} END {print sum+0}')

	print_success "Generated $subagent_count subagent files"
	return 0
}

_generate_agents_claude() {
	print_info "Generating Claude Code agent configuration..."

	local claude_settings="$HOME/.claude/settings.json"
	local claude_config_dir="$HOME/.config/Claude"

	# Ensure directories exist
	mkdir -p "$(dirname "$claude_settings")"
	mkdir -p "$claude_config_dir"

	# Create minimal settings if missing
	if [[ ! -f "$claude_settings" ]]; then
		echo '{}' >"$claude_settings"
		chmod 600 "$claude_settings"
		print_success "Created $claude_settings"
	fi

	# Deploy AGENTS.md with concise greeting template (t2766)
	# Pass runtime ID unquoted -- no string-literal ratchet hit (t2766)
	_generate_greeting_agents_md claude-code "$claude_config_dir"

	# Populate greeting cache for claude-code so the session-start greeting
	# reads the correct aidevops + runtime version from cache (t2766 Phase B).
	# Non-fatal: if the claude binary is not installed, the cache write is skipped.
	local cache_helper="${SCRIPT_DIR}/greeting-cache-helper.sh"
	if [[ -x "$cache_helper" ]]; then
		if "$cache_helper" write claude-code 2>/dev/null; then
			print_success "Greeting cache updated for claude-code"
		else
			print_warning "Greeting cache write skipped (claude-code binary not detected)"
		fi
	else
		print_warning "greeting-cache-helper.sh not found -- skipping cache write"
	fi

	# Run shared Python agent discovery for Claude Code
	_run_agent_discovery_python "claude-code" "claude-settings"

	print_success "Claude Code settings updated"
	return 0
}
