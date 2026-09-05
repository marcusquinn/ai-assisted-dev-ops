#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# prompt-injection-adapter.sh — Deploy system prompts via each runtime's native mechanism
#
# Part of the runtime abstraction layer (t1665). Replaces scattered prompt
# deployment logic in agent-deploy.sh and generator scripts with a single
# adapter that knows how to inject the aidevops system prompt (AGENTS.md,
# build.txt pointers) into each runtime's native instruction-loading mechanism.
#
# Usage (standalone):
#   prompt-injection-adapter.sh deploy [runtime_id]   Deploy prompts for one or all runtimes
#   prompt-injection-adapter.sh status                Show deployment status for all runtimes
#   prompt-injection-adapter.sh help                  Show this help
#
# Usage (sourced):
#   source prompt-injection-adapter.sh
#   deploy_prompts_for_runtime "opencode"
#   deploy_prompts_for_all_runtimes
#
# Supported runtimes and their prompt mechanisms:
#   opencode   — json-instructions     (opencode.json "instructions" field)
#   claude     — agents-md-autodiscovery (~/.config/Claude/AGENTS.md, ~/.claude/AGENTS.md)
#   codex      — codex-agents-md  (~/.codex/AGENTS.md)
#   cursor     — cursorrules-plus-agents (~/.cursor/rules/ + AGENTS.md)
#   droid      — factory-skills         (~/.factory/skills/)
#   gemini     — gemini-agents-md       (~/.gemini/AGENTS.md)
#   windsurf   — windsurfrules          (~/.codeium/windsurf/ config)
#   continue   — continue-rules         (~/.continue/ config)
#   kilo       — agents-md-autodiscovery (AGENTS.md auto-discovery)
#   kiro       — agents-md-autodiscovery (AGENTS.md auto-discovery)
#   aider      — aider-read             (.aider.conf.yml read: field)
#
# Dependencies:
#   - shared-constants.sh (print_info, print_success, etc.)
#   - runtime-registry.sh (t1665.1 — stubs included until merged)
#   - jq or python3 (for JSON manipulation)

# Guard: only apply strict mode when executed directly
_PIA_SELF="${BASH_SOURCE[0]:-}"
if [[ -n "${_PIA_SELF}" && "${_PIA_SELF}" == "${0}" ]]; then
	set -euo pipefail
fi

# Resolve script directory
_PIA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# Source shared constants for print_* functions
if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then
	# shellcheck source=/dev/null
	source "${_PIA_DIR}/shared-constants.sh" 2>/dev/null || true
fi

# =============================================================================
# Cross-task stubs for runtime-registry.sh (t1665.1)
# These minimal functions will be replaced when t1665.1 merges.
# The adapter only needs: prompt mechanism lookup and installed-runtime detection.
# =============================================================================

# Source runtime-registry.sh if available (t1665.1)
if [[ -f "${_PIA_DIR}/runtime-registry.sh" ]]; then
	# shellcheck source=/dev/null
	source "${_PIA_DIR}/runtime-registry.sh"
fi

# Define the adapter's own API functions.
# When the registry is loaded, these are thin wrappers around rt_* functions.
# When standalone (no registry), these are self-contained stubs.
# This ensures get_runtime_prompt_mechanism, detect_installed_runtimes, and
# is_runtime_installed are ALWAYS available regardless of sourcing order.

if declare -f rt_detect_installed >/dev/null 2>&1; then
	# Registry is loaded — define wrappers that bridge adapter API → registry API.
	# The registry uses different function names and the prompt mechanism values
	# differ (registry: "AGENTS.md"/"config"/"system-prompt"; adapter dispatches
	# on: "json-instructions"/"agents-md-autodiscovery"/etc.), so we translate.

	_PIA_RUNTIME_IDS=()
	while IFS= read -r _id; do
		_PIA_RUNTIME_IDS+=("$_id")
	done < <(rt_list_ids)

	get_runtime_prompt_mechanism() {
		local runtime_id="$1"
		# Translate registry's generic mechanism to adapter-specific dispatch key
		local reg_mechanism
		reg_mechanism=$(rt_prompt_mechanism "$runtime_id") || {
			echo ""
			return 1
		}
		case "$runtime_id" in
		opencode) echo "json-instructions" ;;
		codex) echo "codex-agents-md" ;;
		cursor) echo "cursorrules-plus-agents" ;;
		droid) echo "factory-skills" ;;
		gemini-cli) echo "gemini-agents-md" ;;
		windsurf) echo "windsurfrules" ;;
		continue) echo "continue-rules" ;;
		aider) echo "aider-read" ;;
		*)
			# For AGENTS.md-based runtimes (claude-code, kilo, kiro, amp, etc.)
			if [[ "$reg_mechanism" == "AGENTS.md" ]]; then
				echo "agents-md-autodiscovery"
			elif [[ -n "$reg_mechanism" ]]; then
				echo "$reg_mechanism"
			else
				echo ""
				return 1
			fi
			;;
		esac
		return 0
	}

	# shellcheck disable=SC2120
	detect_installed_runtimes() {
		rt_detect_installed
		return $?
	}

	is_runtime_installed() {
		local runtime_id="$1"
		local bin
		bin=$(rt_binary "$runtime_id") || return 1
		if [[ -n "$bin" ]] && type -P "$bin" >/dev/null 2>&1; then
			return 0
		fi
		# Fallback: check config directory for editor-only runtimes
		local config_path
		config_path=$(rt_config_path "$runtime_id") || config_path=""
		if [[ -n "$config_path" ]] && [[ -f "$config_path" || -d "$(dirname "$config_path")" ]]; then
			return 0
		fi
		return 1
	}

else
	# No registry — use self-contained stubs
	_PIA_RUNTIME_IDS=(
		"opencode" "claude-code" "codex" "cursor" "droid"
		"gemini-cli" "windsurf" "continue" "kilo" "kiro" "aider"
	)
	_PIA_RUNTIME_BINARIES=(
		"opencode" "claude" "codex" "cursor" "droid"
		"gemini" "windsurf" "continue" "kilo" "kiro" "aider"
	)
	_PIA_PROMPT_MECHANISMS=(
		"json-instructions"
		"agents-md-autodiscovery"
		"codex-agents-md"
		"cursorrules-plus-agents"
		"factory-skills"
		"gemini-agents-md"
		"windsurfrules"
		"continue-rules"
		"agents-md-autodiscovery"
		"agents-md-autodiscovery"
		"aider-read"
	)

	get_runtime_prompt_mechanism() {
		local runtime_id="$1"
		local i
		for i in "${!_PIA_RUNTIME_IDS[@]}"; do
			if [[ "${_PIA_RUNTIME_IDS[$i]}" == "$runtime_id" ]]; then
				echo "${_PIA_PROMPT_MECHANISMS[$i]}"
				return 0
			fi
		done
		echo ""
		return 1
	}

	is_runtime_installed() {
		local runtime_id="$1"
		local i
		for i in "${!_PIA_RUNTIME_IDS[@]}"; do
			if [[ "${_PIA_RUNTIME_IDS[$i]}" == "$runtime_id" ]]; then
				type -P "${_PIA_RUNTIME_BINARIES[$i]}" &>/dev/null
				return $?
			fi
		done
		return 1
	}

	detect_installed_runtimes() {
		local i
		for i in "${!_PIA_RUNTIME_IDS[@]}"; do
			if type -P "${_PIA_RUNTIME_BINARIES[$i]}" &>/dev/null; then
				echo "${_PIA_RUNTIME_IDS[$i]}"
			fi
		done
		return 0
	}
fi

# =============================================================================
# Constants
# =============================================================================

readonly _PIA_AGENTS_MD="${HOME}/.aidevops/agents/AGENTS.md"
readonly _PIA_REFERENCE_LINE='Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.'
# Grep pattern to detect existing aidevops reference in files (literal string, not a path)
readonly _PIA_GREP_PATTERN='aidevops/agents/AGENTS.md'

# =============================================================================
# Internal helpers
# =============================================================================

# Prepend a reference line to an existing file if not already present.
# Creates the file with just the reference if it doesn't exist.
# Arguments:
#   $1 - file path
#   $2 - reference line to ensure is present
#   $3 - grep pattern to detect existing reference (optional, defaults to 'aidevops')
_pia_ensure_reference_in_file() {
	local target_file="$1"
	local ref_line="$2"
	local grep_pattern="${3:-aidevops}"
	local target_dir
	target_dir="$(dirname "$target_file")"

	# Create parent directory if needed
	if [[ ! -d "$target_dir" ]]; then
		mkdir -p "$target_dir"
	fi

	if [[ -f "$target_file" ]]; then
		# Check if reference already exists
		if grep -q "$grep_pattern" "$target_file" 2>/dev/null; then
			_pia_log "info" "Reference already exists in $target_file"
			return 0
		fi
		# Prepend reference to existing file (preserve user content)
		local tmp_file
		tmp_file=$(mktemp)
		# Ensure cleanup on interruption
		trap 'rm -f "$tmp_file" 2>/dev/null' EXIT INT TERM
		echo "$ref_line" >"$tmp_file"
		echo "" >>"$tmp_file"
		cat "$target_file" >>"$tmp_file"
		mv "$tmp_file" "$target_file"
		trap - EXIT INT TERM
		_pia_log "success" "Added reference to $target_file"
	else
		# Create new file with just the reference
		echo "$ref_line" >"$target_file"
		_pia_log "success" "Created $target_file with aidevops reference"
	fi
	return 0
}

# Set a JSON field using jq or python3 fallback.
# Arguments:
#   $1 - file path
#   $2 - jq filter expression (e.g., '.instructions = ["path"]')
_pia_json_set() {
	local json_file="$1"
	local jq_filter="$2"

	if [[ ! -f "$json_file" ]]; then
		_pia_log "warning" "Config file not found: $json_file"
		return 1
	fi

	local tmp_file
	tmp_file=$(mktemp)

	if command -v jq &>/dev/null; then
		if jq "$jq_filter" "$json_file" >"$tmp_file" 2>/dev/null; then
			mv "$tmp_file" "$json_file"
			return 0
		fi
		rm -f "$tmp_file"
		return 1
	elif command -v python3 &>/dev/null; then
		# Fallback: use python3 for JSON manipulation
		if python3 -c "
import json, sys
with open('$json_file') as f:
    data = json.load(f)
# Merge into existing instructions array (preserve user entries, deduplicate)
filter_str = '''$jq_filter'''
if '.instructions' in filter_str:
    existing = data.get('instructions', [])
    if not isinstance(existing, list):
        existing = []
    new_entry = '$_PIA_AGENTS_MD'
    if new_entry not in existing:
        existing.append(new_entry)
    data['instructions'] = existing
with open('$tmp_file', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" 2>/dev/null; then
			mv "$tmp_file" "$json_file"
			return 0
		fi
		rm -f "$tmp_file"
		return 1
	else
		rm -f "$tmp_file"
		_pia_log "warning" "Neither jq nor python3 available for JSON editing"
		return 1
	fi
}

# Logging wrapper — uses print_* if available, falls back to echo
_pia_log() {
	local level="$1"
	local message="$2"

	case "$level" in
	info)
		if declare -f print_info >/dev/null 2>&1; then
			print_info "$message"
		else
			echo "[INFO] $message"
		fi
		;;
	success)
		if declare -f print_success >/dev/null 2>&1; then
			print_success "$message"
		else
			echo "[OK] $message"
		fi
		;;
	warning)
		if declare -f print_warning >/dev/null 2>&1; then
			print_warning "$message"
		else
			echo "[WARN] $message" >&2
		fi
		;;
	error)
		if declare -f print_error >/dev/null 2>&1; then
			print_error "$message"
		else
			echo "[ERROR] $message" >&2
		fi
		;;
	*)
		echo "$message"
		;;
	esac
	return 0
}

# =============================================================================
# Per-mechanism deployment functions
# =============================================================================

# OpenCode: set "instructions" field in opencode.json to auto-load AGENTS.md
_deploy_prompt_json_instructions() {
	# runtime_id accepted for interface consistency with other _deploy_prompt_* functions
	# but unused here since this function is OpenCode-specific.
	local _unused_runtime_id="$1"
	local config_file="${HOME}/.config/opencode/opencode.json"

	if [[ ! -f "$config_file" ]]; then
		_pia_log "info" "OpenCode config not found at $config_file — skipping"
		return 0
	fi

	# Check if instructions already points to our AGENTS.md
	if command -v jq &>/dev/null; then
		local current
		current=$(jq -r '.instructions // [] | .[]' "$config_file" 2>/dev/null || echo "")
		if echo "$current" | grep -q "aidevops"; then
			_pia_log "info" "OpenCode instructions already configured"
			return 0
		fi
	fi

	# Merge our path into existing instructions array (preserve user entries)
	if _pia_json_set "$config_file" \
		".instructions = ((.instructions // []) + [\"${_PIA_AGENTS_MD}\"] | unique)"; then
		_pia_log "success" "Added ${_PIA_AGENTS_MD} to OpenCode instructions"
	else
		_pia_log "warning" "Failed to set OpenCode instructions field"
		return 1
	fi

	# Also deploy the config-root AGENTS.md (session greeting)
	# Use diff/backup semantics — only replace if content differs
	local opencode_config_dir="${HOME}/.config/opencode"
	local target_agents="${opencode_config_dir}/AGENTS.md"
	local template_source
	# Look for template in both repo and deployed locations
	for template_source in \
		"${_PIA_DIR}/../../templates/opencode-config-agents.md" \
		"${HOME}/.aidevops/templates/opencode-config-agents.md"; do
		if [[ -f "$template_source" ]]; then
			if [[ -f "$target_agents" ]] && diff -q "$template_source" "$target_agents" &>/dev/null; then
				_pia_log "info" "Greeting template already up to date at ${target_agents}"
			else
				if [[ -f "$target_agents" ]]; then
					cp "$target_agents" "${target_agents}.bak"
				fi
				cp "$template_source" "$target_agents"
				_pia_log "success" "Deployed greeting template to ${target_agents}"
			fi
			break
		fi
	done

	return 0
}

# Claude Code: deploy AGENTS.md with pointer line to auto-discovery locations
_deploy_prompt_agents_md_claude() {
	local updated_count=0

	# Claude Code auto-discovers AGENTS.md in these directories:
	#   ~/.claude/AGENTS.md          — global auto-discovery (primary)
	#   ~/.config/Claude/AGENTS.md   — config-level auto-discovery
	# Note: ~/.claude/commands/ is for slash commands, NOT AGENTS.md.
	local claude_dirs=(
		"${HOME}/.claude"
		"${HOME}/.config/Claude"
	)

	for agents_dir in "${claude_dirs[@]}"; do
		# Only deploy if the directory itself exists (tool is installed).
		# Don't use dirname — ~/.config always exists, causing false positives.
		if [[ -d "$agents_dir" ]]; then
			local agents_file="${agents_dir}/AGENTS.md"
			_pia_ensure_reference_in_file "$agents_file" "$_PIA_REFERENCE_LINE" "$_PIA_GREP_PATTERN"
			((++updated_count))
		fi
	done

	if [[ $updated_count -eq 0 ]]; then
		_pia_log "info" "Claude Code not installed — skipping"
	fi

	# Clean up stale AGENTS.md from OpenCode agent dir (was incorrectly showing as subagent)
	rm -f "${HOME}/.config/opencode/agent/AGENTS.md" 2>/dev/null

	return 0
}

# Generic AGENTS.md auto-discovery deployment (Gemini, Kilo, Kiro, etc.)
_deploy_prompt_agents_md() {
	local runtime_id="$1"
	local target_dirs=()

	case "$runtime_id" in
	claude-code | claude)
		_deploy_prompt_agents_md_claude
		return $?
		;;
	gemini-cli | gemini)
		target_dirs=("${HOME}/.gemini")
		;;
	kilo)
		target_dirs=("${HOME}/.kilo")
		;;
	kiro)
		target_dirs=("${HOME}/.kiro")
		;;
	*)
		# Generic: try ~/.<runtime_id>/
		target_dirs=("${HOME}/.${runtime_id}")
		;;
	esac

	local deployed=false
	for target_dir in "${target_dirs[@]}"; do
		# Only deploy if the runtime directory exists or the binary is installed
		if [[ -d "$target_dir" ]] || is_runtime_installed "$runtime_id"; then
			mkdir -p "$target_dir"
			_pia_ensure_reference_in_file \
				"${target_dir}/AGENTS.md" \
				"$_PIA_REFERENCE_LINE" \
				"$_PIA_GREP_PATTERN"
			deployed=true
		fi
	done

	if [[ "$deployed" != "true" ]]; then
		_pia_log "info" "${runtime_id} not installed — skipping"
	fi

	return 0
}

# Codex: use the native global AGENTS.md discovery contract.
_deploy_prompt_codex_instructions() {
	local codex_dir="${CODEX_HOME:-$HOME/.codex}"
	if ! command -v codex &>/dev/null && [[ ! -d "$codex_dir" ]]; then
		return 0
	fi
	python3 "${_PIA_DIR}/codex-setup.py" guidance || return 1
	return 0
}

# Cursor: deploy AGENTS.md to ~/.cursor/rules/ (global rules)
_deploy_prompt_cursor() {
	local cursor_dir="${HOME}/.cursor"

	if ! command -v cursor &>/dev/null && [[ ! -d "$cursor_dir" ]]; then
		_pia_log "info" "Cursor not installed — skipping"
		return 0
	fi

	# Deploy AGENTS.md to global rules directory
	local rules_dir="${cursor_dir}/rules"
	mkdir -p "$rules_dir"
	_pia_ensure_reference_in_file \
		"${rules_dir}/AGENTS.md" \
		"$_PIA_REFERENCE_LINE" \
		"$_PIA_GREP_PATTERN"

	return 0
}

# Droid (Factory): deploy AGENTS.md to ~/.factory/skills/
_deploy_prompt_factory() {
	local factory_dir="${HOME}/.factory"

	if ! command -v droid &>/dev/null && [[ ! -d "$factory_dir" ]]; then
		_pia_log "info" "Droid not installed — skipping"
		return 0
	fi

	local skills_dir="${factory_dir}/skills"
	mkdir -p "$skills_dir"
	_pia_ensure_reference_in_file \
		"${skills_dir}/AGENTS.md" \
		"$_PIA_REFERENCE_LINE" \
		"$_PIA_GREP_PATTERN"

	return 0
}

# Gemini CLI: deploy AGENTS.md to ~/.gemini/
_deploy_prompt_gemini() {
	_deploy_prompt_agents_md "gemini-cli"
	return $?
}

# Windsurf: deploy rules to ~/.codeium/windsurf/ config
_deploy_prompt_windsurf() {
	local windsurf_dir="${HOME}/.codeium/windsurf"

	if ! command -v windsurf &>/dev/null && [[ ! -d "$windsurf_dir" ]]; then
		_pia_log "info" "Windsurf not installed — skipping"
		return 0
	fi

	# Windsurf uses AGENTS.md auto-discovery similar to Claude/Gemini
	# Also supports .windsurfrules in project root (handled by verify-mirrors.sh)
	mkdir -p "$windsurf_dir"
	_pia_ensure_reference_in_file \
		"${windsurf_dir}/AGENTS.md" \
		"$_PIA_REFERENCE_LINE" \
		"$_PIA_GREP_PATTERN"

	return 0
}

# Continue.dev: deploy rules to ~/.continue/ config
_deploy_prompt_continue() {
	local continue_dir="${HOME}/.continue"

	# Use type -P to find real executables only — "continue" is a shell
	# builtin keyword, so command -v always matches it (false positive).
	if ! type -P continue &>/dev/null && [[ ! -d "$continue_dir" ]]; then
		_pia_log "info" "Continue.dev not installed — skipping"
		return 0
	fi

	# Continue uses .continuerules (project) and config.json systemMessage (global)
	# Deploy AGENTS.md reference to the config directory
	mkdir -p "$continue_dir"
	_pia_ensure_reference_in_file \
		"${continue_dir}/AGENTS.md" \
		"$_PIA_REFERENCE_LINE" \
		"$_PIA_GREP_PATTERN"

	# If config.json exists, we could set systemMessage — but that's invasive.
	# The AGENTS.md auto-discovery is the safer approach.

	return 0
}

# Aider: add AGENTS.md to .aider.conf.yml read: list
_deploy_prompt_aider() {
	local aider_config="${HOME}/.aider.conf.yml"

	if ! command -v aider &>/dev/null && [[ ! -f "$aider_config" ]]; then
		_pia_log "info" "Aider not installed — skipping"
		return 0
	fi

	# If config doesn't exist, create it with the read: entry
	if [[ ! -f "$aider_config" ]]; then
		mkdir -p "$(dirname "$aider_config")"
		printf 'read:\n  - %s\n' "$_PIA_AGENTS_MD" >"$aider_config"
		_pia_log "success" "Created $aider_config with AGENTS.md in read list"
		return 0
	fi

	# Check if already configured
	if grep -q "aidevops" "$aider_config" 2>/dev/null; then
		_pia_log "info" "Aider config already references aidevops"
		return 0
	fi

	# Append read entry to aider YAML config.
	# Must handle both block format (read:\n  - path) and inline format
	# (read: [] or read: ["path"]) to avoid corrupting existing entries.
	if grep -q '^read:' "$aider_config" 2>/dev/null; then
		local tmp_file
		tmp_file=$(mktemp)
		local read_line
		read_line=$(grep '^read:' "$aider_config")

		if echo "$read_line" | grep -qE '^read:[[:space:]]*$'; then
			# Block format header (read: on its own line) — insert after it
			awk -v path="$_PIA_AGENTS_MD" '
				/^read:[[:space:]]*$/ { print; print "  - " path; next }
				{ print }
			' "$aider_config" >"$tmp_file"
		elif echo "$read_line" | grep -qE '^read:[[:space:]]*\['; then
			# Inline list format (read: [] or read: ["a","b"]) — convert to
			# block format preserving existing entries, then append ours
			python3 -c "
import yaml, sys
with open('$aider_config') as f:
    data = yaml.safe_load(f) or {}
existing = data.get('read', [])
if not isinstance(existing, list):
    existing = [existing] if existing else []
new_entry = '$_PIA_AGENTS_MD'
if new_entry not in existing:
    existing.append(new_entry)
data['read'] = existing
with open('$tmp_file', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
" 2>/dev/null || {
				# python3/pyyaml not available — safe fallback: convert inline
				# to block format manually (handles any inline list).
				# Extract existing entries from the inline list, convert to
				# block format, then append our entry.
				local inline_content
				inline_content=$(echo "$read_line" | sed 's/^read:[[:space:]]*\[//;s/\][[:space:]]*$//')
				sed '/^read:[[:space:]]*\[/d' "$aider_config" >"$tmp_file"
				printf 'read:\n' >>"$tmp_file"
				# Parse comma-separated entries (strip quotes and whitespace)
				if [[ -n "$inline_content" ]]; then
					echo "$inline_content" | tr ',' '\n' | while IFS= read -r entry; do
						entry=$(echo "$entry" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')
						[[ -n "$entry" ]] && printf '  - %s\n' "$entry" >>"$tmp_file"
					done
				fi
				printf '  - %s\n' "$_PIA_AGENTS_MD" >>"$tmp_file"
			}
		else
			# Scalar format (read: /path/to/file) — convert to block list
			# preserving position in the file (replace in-place via awk)
			local existing_path
			existing_path=$(echo "$read_line" | sed 's/^read:[[:space:]]*//')
			awk -v existing="$existing_path" -v new_path="$_PIA_AGENTS_MD" '
				/^read:[[:space:]]/ && !/^read:[[:space:]]*\[/ {
					print "read:"
					print "  - " existing
					print "  - " new_path
					next
				}
				{ print }
			' "$aider_config" >"$tmp_file"
		fi

		mv "$tmp_file" "$aider_config"
		_pia_log "success" "Added AGENTS.md to aider read: list"
	else
		# Append new read: section
		printf '\nread:\n  - %s\n' "$_PIA_AGENTS_MD" >>"$aider_config"
		_pia_log "success" "Added read: section to $aider_config"
	fi

	return 0
}

# =============================================================================
# Public API
# =============================================================================

# Deploy system prompts for a specific runtime.
# Arguments:
#   $1 - runtime_id (e.g., "opencode", "claude", "codex")
deploy_prompts_for_runtime() {
	local runtime_id="$1"
	local mechanism
	mechanism=$(get_runtime_prompt_mechanism "$runtime_id") || mechanism=""

	if [[ -z "$mechanism" ]]; then
		_pia_log "warning" "Unknown runtime '$runtime_id' — no prompt mechanism defined"
		return 1
	fi

	case "$mechanism" in
	json-instructions)
		_deploy_prompt_json_instructions "$runtime_id"
		;;
	agents-md-autodiscovery)
		_deploy_prompt_agents_md "$runtime_id"
		;;
	codex-agents-md)
		_deploy_prompt_codex_instructions
		;;
	cursorrules-plus-agents)
		_deploy_prompt_cursor
		;;
	factory-skills)
		_deploy_prompt_factory
		;;
	gemini-agents-md)
		_deploy_prompt_gemini
		;;
	windsurfrules)
		_deploy_prompt_windsurf
		;;
	continue-rules)
		_deploy_prompt_continue
		;;
	aider-read)
		_deploy_prompt_aider
		;;
	*)
		_pia_log "warning" "Unknown prompt mechanism '$mechanism' for $runtime_id"
		return 1
		;;
	esac
	return $?
}

# Deploy system prompts for all installed runtimes.
deploy_prompts_for_all_runtimes() {
	_pia_log "info" "Deploying system prompts to all installed runtimes..."

	local runtime_id
	local deployed_count=0
	local total_count=0

	while IFS= read -r runtime_id; do
		[[ -z "$runtime_id" ]] && continue
		((++total_count))
		if deploy_prompts_for_runtime "$runtime_id"; then
			((++deployed_count))
		fi
	done < <(detect_installed_runtimes)

	if [[ $total_count -eq 0 ]]; then
		_pia_log "info" "No supported runtimes detected"
	else
		_pia_log "success" "Deployed prompts to $deployed_count/$total_count installed runtime(s)"
	fi

	return 0
}

# Show deployment status for all known runtimes.
show_prompt_deployment_status() {
	echo "Prompt Injection Adapter — Deployment Status"
	echo "============================================="
	echo ""

	local i
	for i in "${!_PIA_RUNTIME_IDS[@]}"; do
		local rid="${_PIA_RUNTIME_IDS[$i]}"
		# Use the function API (works with both registry and stub paths)
		local mechanism
		mechanism=$(get_runtime_prompt_mechanism "$rid" 2>/dev/null || echo "")
		local installed="no"
		local deployed="no"

		if is_runtime_installed "$rid"; then
			installed="yes"
		fi

		# Check deployment status based on mechanism
		case "$mechanism" in
		json-instructions)
			if [[ -f "${HOME}/.config/opencode/opencode.json" ]]; then
				if command -v jq &>/dev/null; then
					local instr
					instr=$(jq -r '.instructions // [] | .[]' "${HOME}/.config/opencode/opencode.json" 2>/dev/null || echo "")
					if echo "$instr" | grep -q "aidevops"; then
						deployed="yes"
					fi
				fi
			fi
			;;
		agents-md-autodiscovery)
			case "$rid" in
			claude-code)
				if grep -q "aidevops" "${HOME}/.claude/AGENTS.md" 2>/dev/null ||
					grep -q "aidevops" "${HOME}/.config/Claude/AGENTS.md" 2>/dev/null; then
					deployed="yes"
				fi
				;;
			*)
				if grep -q "aidevops" "${HOME}/.${rid}/AGENTS.md" 2>/dev/null; then
					deployed="yes"
				fi
				;;
			esac
			;;
		codex-agents-md)
			if grep -q "aidevops" "${CODEX_HOME:-$HOME/.codex}/AGENTS.md" 2>/dev/null; then
				deployed="yes"
			fi
			;;
		cursorrules-plus-agents)
			if grep -q "aidevops" "${HOME}/.cursor/rules/AGENTS.md" 2>/dev/null; then
				deployed="yes"
			fi
			;;
		factory-skills)
			if grep -q "aidevops" "${HOME}/.factory/skills/AGENTS.md" 2>/dev/null; then
				deployed="yes"
			fi
			;;
		gemini-agents-md)
			if grep -q "aidevops" "${HOME}/.gemini/AGENTS.md" 2>/dev/null; then
				deployed="yes"
			fi
			;;
		windsurfrules)
			if grep -q "aidevops" "${HOME}/.codeium/windsurf/AGENTS.md" 2>/dev/null; then
				deployed="yes"
			fi
			;;
		continue-rules)
			if grep -q "aidevops" "${HOME}/.continue/AGENTS.md" 2>/dev/null; then
				deployed="yes"
			fi
			;;
		aider-read)
			if grep -q "aidevops" "${HOME}/.aider.conf.yml" 2>/dev/null; then
				deployed="yes"
			fi
			;;
		esac

		printf "  %-12s  installed=%-3s  deployed=%-3s  mechanism=%s\n" \
			"$rid" "$installed" "$deployed" "$mechanism"
	done

	echo ""
	return 0
}

# =============================================================================
# CLI entry point
# =============================================================================

_pia_usage() {
	echo "Usage: prompt-injection-adapter.sh <command> [runtime_id]"
	echo ""
	echo "Deploy aidevops system prompts via each runtime's native mechanism."
	echo ""
	echo "Commands:"
	echo "  deploy [runtime_id]   Deploy prompts for one runtime (or all if omitted)"
	echo "  status                Show deployment status for all runtimes"
	echo "  help                  Show this help"
	echo ""
	echo "Supported runtimes:"
	echo "  opencode, claude, codex, cursor, droid, gemini,"
	echo "  windsurf, continue, kilo, kiro, aider"
	echo ""
	echo "Examples:"
	echo "  prompt-injection-adapter.sh deploy              # Deploy to all installed"
	echo "  prompt-injection-adapter.sh deploy claude        # Deploy to Claude only"
	echo "  prompt-injection-adapter.sh status               # Show what's deployed"
	return 0
}

_pia_main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	deploy)
		local runtime_id="${1:-}"
		if [[ -n "$runtime_id" ]]; then
			deploy_prompts_for_runtime "$runtime_id"
		else
			deploy_prompts_for_all_runtimes
		fi
		;;
	status)
		show_prompt_deployment_status
		;;
	help | --help | -h)
		_pia_usage
		;;
	*)
		_pia_log "error" "Unknown command: $command"
		_pia_usage
		return 1
		;;
	esac
	return $?
}

# Run main only when executed directly (not sourced)
if [[ -n "${_PIA_SELF}" && "${_PIA_SELF}" == "${0}" ]]; then
	_pia_main "$@"
fi
