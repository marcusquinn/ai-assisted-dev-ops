#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# config-helper.sh - JSONC configuration reader/writer for aidevops
#
# Provides get/set/list/reset/migrate operations on the aidevops JSONC config.
# Called by `aidevops config <command>` CLI and sourced by shared-constants.sh.
#
# Usage (CLI):
#   config-helper.sh list                          List all config with current values
#   config-helper.sh get <dotpath>                 Get a config value (e.g. updates.auto_update)
#   config-helper.sh set <dotpath> <value>         Set a config value
#   config-helper.sh reset [dotpath]               Reset one or all config to defaults
#   config-helper.sh path                          Show config file paths
#   config-helper.sh migrate                       Migrate from feature-toggles.conf
#   config-helper.sh validate                      Validate user config against schema
#   config-helper.sh help                          Show this help
#
# Usage (sourced by shared-constants.sh):
#   _jsonc_get <dotpath> [default]                 Get a value from merged config
#   _jsonc_get_raw <file> <dotpath>                Get a value from a specific file
#
# Files:
#   Defaults:    ~/.aidevops/agents/configs/aidevops.defaults.jsonc
#   User config: ~/.config/aidevops/config.jsonc
#   Old config:  ~/.config/aidevops/feature-toggles.conf (migrated on first use)

# Prevent recursive and repeated sourcing from re-entering initialization or
# dispatching main(). config-helper.sh and the shared modules intentionally form
# a source cycle, so the guard must run before direct-execution detection.
if [[ -n "${_CONFIG_HELPER_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_CONFIG_HELPER_LOADED=1

# Apply strict mode only when executed directly (not when sourced by another script).
# Shell portability note (GH#4904):
#   bash: BASH_SOURCE[0] == $0 when executed directly; differs when sourced.
#   zsh:  BASH_SOURCE is always unset — the script is always being sourced when
#         this file is loaded via `source`. Never run main() in zsh.
# Guard: only check BASH_SOURCE when it is set (bash). In zsh, skip the check
# entirely (we are always being sourced, never executed directly as zsh).
_CH_SELF="${BASH_SOURCE[0]:-}"
if [[ -n "${_CH_SELF}" && "${_CH_SELF}" == "${0}" ]]; then
	set -euo pipefail
fi

# Resolve script directory (works when sourced or executed).
# Fall back to $0 when BASH_SOURCE is unset (zsh). In zsh this gives the
# shell name ("zsh"), which is wrong for path resolution — but the deployed
# path fallback in _load_model_pricing_json covers that case. See GH#4904.
_CH_SELF_DIR="${BASH_SOURCE[0]:-${0:-}}"
_CONFIG_HELPER_DIR="$(cd "$(dirname "${_CH_SELF_DIR}")" && pwd)" || {
	echo "[config] Failed to resolve script directory" >&2
	return 1 2>/dev/null || exit 1
}

# Only source shared-constants.sh when running standalone (not when sourced by it).
# IMPORTANT: source=/dev/null tells ShellCheck NOT to follow this source directive.
# Without it, ShellCheck follows the cycle config-helper.sh → shared-constants.sh →
# config-helper.sh infinitely, consuming exponential memory (7-14 GB observed).
# The runtime guard (_SHARED_CONSTANTS_LOADED) prevents infinite recursion at
# execution time, but ShellCheck is a static analyzer and ignores runtime guards.
# GH#3981: https://github.com/marcusquinn/aidevops/issues/3981
if [[ -z "${_SHARED_CONSTANTS_LOADED:-}" ]]; then
	_SHARED_CONSTANTS_FILE="${_CONFIG_HELPER_DIR}/shared-constants.sh"
	if [[ -r "${_SHARED_CONSTANTS_FILE}" ]]; then
		# shellcheck source=/dev/null
		source "${_SHARED_CONSTANTS_FILE}"
	fi
fi

# ---------------------------------------------------------------------------
# File paths (use defaults if not already set — allows override for testing)
# ---------------------------------------------------------------------------
_CONFIG_HOME="${HOME:-/tmp/aidevops-${USER:-uid-${UID:-shared}}}"
_validate_config_home() {
	local config_home="$1"
	if [[ "${config_home:-}" == /tmp || "${config_home:-}" == /tmp/* ]]; then
		if [[ -L "${config_home:-}" ]]; then
			echo "[ERROR] Security risk: ${config_home:-} is a symlink." >&2
			return 1
		fi
		if [[ ! -e "${config_home:-}" ]]; then
			if ! mkdir -m 700 "${config_home:-}"; then
				if [[ -L "${config_home:-}" ]]; then
					echo "[ERROR] Security risk: ${config_home:-} is a symlink." >&2
					return 1
				elif [[ ! -e "${config_home:-}" ]]; then
					echo "[ERROR] Cannot create secure config home: ${config_home:-}." >&2
					return 1
				fi
			fi
		fi
		if [[ ! -d "${config_home:-}" ]]; then
			echo "[ERROR] Security risk: ${config_home:-} is not a directory." >&2
			return 1
		elif [[ ! -O "${config_home:-}" ]]; then
			echo "[ERROR] Security risk: ${config_home:-} is not owned by the current user." >&2
			return 1
		fi
	fi
	return 0
}

_validate_config_home "$_CONFIG_HOME" || return 1 2>/dev/null || exit 1
JSONC_DEFAULTS="${JSONC_DEFAULTS:-${_CONFIG_HOME}/.aidevops/agents/configs/aidevops.defaults.jsonc}"
JSONC_USER="${JSONC_USER:-${_CONFIG_HOME}/.config/aidevops/config.jsonc}"
JSONC_SCHEMA="${JSONC_SCHEMA:-${_CONFIG_HOME}/.aidevops/agents/configs/aidevops-config.schema.json}"
OLD_CONF_USER="${OLD_CONF_USER:-${_CONFIG_HOME}/.config/aidevops/feature-toggles.conf}"
OLD_CONF_DEFAULTS="${OLD_CONF_DEFAULTS:-${_CONFIG_HOME}/.aidevops/agents/configs/feature-toggles.conf.defaults}"
MIGRATE_FAILED_FLAG="${MIGRATE_FAILED_FLAG:-${_CONFIG_HOME}/.aidevops/migrate_failed}"

# nice — cache avoids re-parsing on every call
_JSONC_MERGED_CACHE=""
_JSONC_CACHE_MTIME=""

# ---------------------------------------------------------------------------
# Validate a dotpath contains only safe characters (letters, digits, _, .)
# Returns 0 if valid, 1 if invalid. Prevents injection via dotpath args.
# ---------------------------------------------------------------------------
_validate_dotpath() {
	local dotpath="$1"
	if [[ ! "$dotpath" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]]; then
		echo "[ERROR] Invalid config key: $dotpath (only letters, digits, _, . allowed)" >&2
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# JSONC → JSON stripping (remove // and /* */ comments, trailing commas)
# Uses jq if available, falls back to sed for basic stripping.
# ---------------------------------------------------------------------------
_strip_jsonc() {
	local file="$1"
	if [[ ! -r "$file" ]]; then
		echo "[config] Cannot read JSONC file: $file" >&2
		return 1
	fi

	# Strategy: use a line-by-line approach that's aware of string context.
	# 1. Remove // comments only when not inside a JSON string value
	# 2. Remove /* */ block comments (handles multiple per line via while loop)
	# 3. Remove trailing commas before } or ]
	#
	# We use awk for context-aware comment stripping, then jq for validation.
	local stripped
	stripped=$(awk '
	BEGIN { in_block = 0 }
	{
		line = $0
		# Handle block comment start/end
		if (in_block) {
			idx = index(line, "*/")
			if (idx > 0) {
				line = substr(line, idx + 2)
				in_block = 0
			} else {
				next
			}
		}
		# Remove all single-line block comments: /* ... */ (loop for multiple per line)
		while (match(line, /\/\*[^*]*\*\//)) {
			line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
		}
		# Check for block comment start without end
		idx = index(line, "/*")
		if (idx > 0) {
			line = substr(line, 1, idx - 1)
			in_block = 1
		}
		# Remove // line comments (only outside of strings)
		# Simple heuristic: find // that is not preceded by : (URL context)
		# and not inside a quoted string
		n = split(line, chars, "")
		result = ""
		in_string = 0
		i = 1
		while (i <= n) {
			c = chars[i]
			if (c == "\"" && (i == 1 || chars[i-1] != "\\")) {
				in_string = !in_string
				result = result c
			} else if (!in_string && c == "/" && i < n && chars[i+1] == "/") {
				break  # rest of line is comment
			} else {
				result = result c
			}
			i++
		}
		print result
	}
	' "$file" |
		sed -e 's/,[[:space:]]*}/}/g' -e 's/,[[:space:]]*\]/]/g') || {
		echo "[config] Failed to strip JSONC comments from: $file" >&2
		return 1
	}

	# Validate with jq
	if command -v jq &>/dev/null; then
		echo "$stripped" | jq '.' 2>/dev/null || {
			echo "[config] Invalid JSON after stripping comments from: $file" >&2
			return 1
		}
	else
		echo "$stripped"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Merge defaults + user config (user overrides defaults via jq * operator)
# ---------------------------------------------------------------------------
_merge_configs() {
	local defaults_json user_json

	defaults_json=$(_strip_jsonc "$JSONC_DEFAULTS") || {
		echo "[config] Failed to parse defaults — config system unavailable" >&2
		echo "{}"
		return 1
	}
	# User config may not exist yet — that's normal, fall back to empty.
	# But if it exists and is malformed, propagate the error — don't silently ignore.
	if [[ -f "$JSONC_USER" ]]; then
		user_json=$(_strip_jsonc "$JSONC_USER") || {
			echo "[config] Malformed user config: $JSONC_USER" >&2
			echo "  Run 'aidevops config validate' to diagnose, or 'aidevops config reset' to fix." >&2
			return 1
		}
	else
		user_json="{}"
	fi

	if command -v jq &>/dev/null; then
		# Deep merge: defaults * user (user wins on conflicts)
		local merge_stderr merge_result
		merge_stderr=$(mktemp 2>/dev/null || echo "/tmp/aidevops-merge-err.$$")
		if merge_result=$(echo "$defaults_json" | jq --argjson user "$user_json" '. * $user' 2>"$merge_stderr"); then
			echo "$merge_result"
		else
			echo "[config] Deep merge failed (defaults=$JSONC_DEFAULTS, user=$JSONC_USER), using defaults only" >&2
			if [[ -s "$merge_stderr" ]]; then
				echo "[config] jq error: $(cat "$merge_stderr")" >&2
			fi
			echo "$defaults_json"
		fi
		rm -f "$merge_stderr"
	else
		# No jq — return defaults only (user overrides not applied)
		echo "$defaults_json"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Get merged config with caching
# ---------------------------------------------------------------------------
_get_merged_config() {
	# Check if cache is still valid (based on file mtimes)
	local current_mtime=""
	if [[ -f "$JSONC_DEFAULTS" ]]; then
		current_mtime=$(_file_mtime_epoch "$JSONC_DEFAULTS")
	fi
	if [[ -f "$JSONC_USER" ]]; then
		local user_mtime
		user_mtime=$(_file_mtime_epoch "$JSONC_USER")
		current_mtime="${current_mtime}:${user_mtime}"
	fi

	if [[ -n "$_JSONC_MERGED_CACHE" && "$_JSONC_CACHE_MTIME" == "$current_mtime" ]]; then
		echo "$_JSONC_MERGED_CACHE"
		return 0
	fi

	_JSONC_MERGED_CACHE=$(_merge_configs)
	_JSONC_CACHE_MTIME="$current_mtime"
	echo "$_JSONC_MERGED_CACHE"
	return 0
}

# ---------------------------------------------------------------------------
# Core get function: read a value from merged config by dot-path
# Usage: _jsonc_get <dotpath> [default]
# Example: _jsonc_get "updates.auto_update" "true"
# ---------------------------------------------------------------------------
_jsonc_get() {
	local dotpath="$1"
	local default="${2:-}"

	if ! command -v jq &>/dev/null; then
		echo "$default"
		return 0
	fi

	local merged
	merged=$(_get_merged_config)

	# Use jq --arg to safely pass dotpath (no shell interpolation into filter)
	# NOTE: Do NOT use jq's // (alternative operator) here — it treats false and
	# null identically, discarding false values. Instead, use 'if . == null'.
	local value
	value=$(echo "$merged" | jq -r --arg p "$dotpath" 'getpath($p | split(".")) | if . == null then empty else tostring end') || value=""

	if [[ -n "$value" ]]; then
		echo "$value"
	else
		echo "$default"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Get raw value from a specific file (no merging)
# ---------------------------------------------------------------------------
_jsonc_get_raw() {
	local file="$1"
	local dotpath="$2"

	if ! command -v jq &>/dev/null; then
		echo ""
		return 0
	fi

	local json
	json=$(_strip_jsonc "$file") || {
		echo ""
		return 0
	}
	echo "$json" | jq -r --arg p "$dotpath" 'getpath($p | split(".")) | if . == null then empty else tostring end' || echo ""
	return 0
}

# ---------------------------------------------------------------------------
# Environment variable override map
# Maps config dot-paths to environment variable names
# ---------------------------------------------------------------------------
_config_env_map() {
	local dotpath="$1"
	case "$dotpath" in
	updates.auto_update) echo "AIDEVOPS_AUTO_UPDATE" ;;
	updates.update_interval_minutes) echo "AIDEVOPS_UPDATE_INTERVAL" ;;
	updates.skill_auto_update) echo "AIDEVOPS_SKILL_AUTO_UPDATE" ;;
	updates.skill_freshness_hours) echo "AIDEVOPS_SKILL_FRESHNESS_HOURS" ;;
	updates.tool_auto_update) echo "AIDEVOPS_TOOL_AUTO_UPDATE" ;;
	updates.tool_freshness_hours) echo "AIDEVOPS_TOOL_FRESHNESS_HOURS" ;;
	updates.tool_idle_hours) echo "AIDEVOPS_TOOL_IDLE_HOURS" ;;
	updates.openclaw_auto_update) echo "AIDEVOPS_OPENCLAW_AUTO_UPDATE" ;;
	updates.openclaw_freshness_hours) echo "AIDEVOPS_OPENCLAW_FRESHNESS_HOURS" ;;
	updates.upstream_watch) echo "AIDEVOPS_UPSTREAM_WATCH" ;;
	updates.upstream_watch_hours) echo "AIDEVOPS_UPSTREAM_WATCH_HOURS" ;;
	orchestration.supervisor_pulse) echo "AIDEVOPS_SUPERVISOR_PULSE" ;;
	orchestration.interactive_pr_auto_merge) echo "AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE" ;;
	orchestration.repo_sync) echo "AIDEVOPS_REPO_SYNC" ;;
	orchestration.repo_aidevops_health) echo "AIDEVOPS_REPO_HEALTH" ;;
	orchestration.max_workers_cap) echo "AIDEVOPS_MAX_WORKERS_CAP" ;;
	orchestration.min_worker_concurrency) echo "AIDEVOPS_MIN_WORKER_CONCURRENCY" ;;
	orchestration.quality_debt_cap_pct) echo "AIDEVOPS_QUALITY_DEBT_CAP_PCT" ;;
	orchestration.provider_account_slot_multiplier) echo "PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER" ;;
	orchestration.triage_known_contributors) echo "AIDEVOPS_TRIAGE_KNOWN_CONTRIBUTORS" ;;
	orchestration.triage_refresh_interval_seconds) echo "AIDEVOPS_TRIAGE_REFRESH_INTERVAL_SECONDS" ;;
	*) echo "" ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Get config value with env override support
# Priority: env var > user config > defaults
# Usage: config_get <dotpath> [default]
# ---------------------------------------------------------------------------
config_get() {
	local dotpath="$1"
	local default="${2:-}"

	# Check env var override first
	local env_var
	env_var=$(_config_env_map "$dotpath")
	if [[ -n "$env_var" ]]; then
		# Use eval for Bash 3.2 compat — ${!var:-} causes "bad substitution" on 3.2
		local env_val=""
		eval "env_val=\${$env_var:-}"
		if [[ -n "$env_val" ]]; then
			echo "$env_val"
			return 0
		fi
	fi

	# Fall through to JSONC config
	_jsonc_get "$dotpath" "$default"
	return 0
}

# ---------------------------------------------------------------------------
# Check if a boolean config value is enabled (true)
# Usage: if config_enabled "updates.auto_update"; then ...
# Returns 0 (true) if value is "true" (case-insensitive), 1 otherwise.
# ---------------------------------------------------------------------------
config_enabled() {
	local dotpath="$1"
	local value
	value=$(config_get "$dotpath" "true")
	local lower
	lower=$(echo "$value" | tr '[:upper:]' '[:lower:]')
	[[ "$lower" == "true" ]]
	return $?
}

# ---------------------------------------------------------------------------
# Backward-compatible aliases for existing code
# These map the old flat key names to the new namespaced paths
# ---------------------------------------------------------------------------
_legacy_key_to_dotpath() {
	local key="$1"
	case "$key" in
	auto_update) echo "updates.auto_update" ;;
	update_interval) echo "updates.update_interval_minutes" ;;
	skill_auto_update) echo "updates.skill_auto_update" ;;
	skill_freshness_hours) echo "updates.skill_freshness_hours" ;;
	tool_auto_update) echo "updates.tool_auto_update" ;;
	tool_freshness_hours) echo "updates.tool_freshness_hours" ;;
	tool_idle_hours) echo "updates.tool_idle_hours" ;;
	openclaw_auto_update) echo "updates.openclaw_auto_update" ;;
	openclaw_freshness_hours) echo "updates.openclaw_freshness_hours" ;;
	upstream_watch) echo "updates.upstream_watch" ;;
	upstream_watch_hours) echo "updates.upstream_watch_hours" ;;
	manage_opencode_config) echo "integrations.manage_opencode_config" ;;
	manage_claude_config) echo "integrations.manage_claude_config" ;;
	supervisor_pulse) echo "orchestration.supervisor_pulse" ;;
	interactive_pr_auto_merge) echo "orchestration.interactive_pr_auto_merge" ;;
	repo_sync) echo "orchestration.repo_sync" ;;
	repo_aidevops_health) echo "orchestration.repo_aidevops_health" ;;
	session_greeting) echo "ui.session_greeting" ;;
	safety_hooks) echo "safety.hooks_enabled" ;;
	shell_aliases) echo "ui.shell_aliases" ;;
	onboarding_prompt) echo "ui.onboarding_prompt" ;;
	*) echo "$key" ;; # Pass through if already a dotpath
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Migration: convert feature-toggles.conf to config.jsonc
# ---------------------------------------------------------------------------
_migrate_conf_to_jsonc() {
	if [[ ! -f "$OLD_CONF_USER" ]]; then
		return 0
	fi

	# Don't migrate if user already has a JSONC config
	if [[ -f "$JSONC_USER" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		echo "[config] Cannot migrate: jq is required. Install jq and retry." >&2
		return 1
	fi

	local json="{}"
	local line key value dotpath

	while IFS= read -r line || [[ -n "$line" ]]; do
		# Skip comments and blank lines
		[[ -z "$line" || "$line" == \#* ]] && continue
		# Parse key=value
		key="${line%%=*}"
		value="${line#*=}"
		# Validate key
		[[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue

		# Map to new dotpath
		dotpath=$(_legacy_key_to_dotpath "$key")

		# Use jq --arg for safe dotpath and value passing (no shell interpolation)
		case "$value" in
		true | false)
			json=$(echo "$json" | jq --arg p "$dotpath" --argjson v "$value" \
				'setpath($p | split("."); $v)' 2>/dev/null) || continue
			;;
		[0-9]*)
			json=$(echo "$json" | jq --arg p "$dotpath" --argjson v "$value" \
				'setpath($p | split("."); $v)' 2>/dev/null) || continue
			;;
		*)
			json=$(echo "$json" | jq --arg p "$dotpath" --arg v "$value" \
				'setpath($p | split("."); $v)' 2>/dev/null) || continue
			;;
		esac
	done <"$OLD_CONF_USER"

	# Only write if we got some values
	if [[ "$json" == "{}" ]]; then
		return 0
	fi

	# Create user config directory
	mkdir -p "$(dirname "$JSONC_USER")"

	# Write JSONC with header comment
	{
		echo "// aidevops Configuration — User Overrides"
		echo "// ========================================="
		echo "// Migrated from feature-toggles.conf on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "// This file overrides defaults in:"
		echo "//   ~/.aidevops/agents/configs/aidevops.defaults.jsonc"
		echo "//"
		echo "// Run 'aidevops config list' to see all available options."
		echo "// Run 'aidevops config reset' to remove all overrides."
		echo ""
		echo "$json" | jq '.' 2>/dev/null || echo "$json"
	} >"$JSONC_USER"

	# Rename old config as backup
	mv "$OLD_CONF_USER" "${OLD_CONF_USER}.migrated" 2>/dev/null || true

	echo "[config] Migrated feature-toggles.conf -> config.jsonc" >&2
	echo "[config] Old config backed up to: ${OLD_CONF_USER}.migrated" >&2
	return 0
}

# ===========================================================================
# CLI Commands (when run as standalone script)
# ===========================================================================

cmd_list() {
	if ! command -v jq &>/dev/null; then
		echo "[ERROR] jq is required for config management. Install: sudo apt install jq" >&2
		return 1
	fi

	local defaults_json user_json
	defaults_json=$(_strip_jsonc "$JSONC_DEFAULTS") || {
		echo "[ERROR] Cannot read defaults config" >&2
		return 1
	}
	if [[ -f "$JSONC_USER" ]]; then
		user_json=$(_strip_jsonc "$JSONC_USER") || {
			echo "[WARN] Malformed user config: $JSONC_USER — showing defaults only" >&2
			user_json="{}"
		}
	else
		user_json="{}"
	fi

	echo ""
	echo -e "\033[1mConfiguration\033[0m"
	echo "=============="
	echo ""
	printf "  %-45s %-15s %-10s\n" "KEY" "VALUE" "SOURCE"
	printf "  %-45s %-15s %-10s\n" "---" "-----" "------"

	# Iterate all leaf values from defaults.
	# Output "dotpath<TAB>value" pairs using jq, handling array indices.
	local entries
	entries=$(echo "$defaults_json" | jq -r '
		. as $root |
		[paths(scalars)] | .[] |
		select(.[0] != "$schema") |
		(map(tostring) | join(".")) as $dotpath |
		(. as $p | $root | getpath($p) | tostring) as $val |
		"\($dotpath)\t\($val)"
	' 2>/dev/null) || entries=""

	local dotpath default_val
	while IFS=$'\t' read -r dotpath default_val; do
		[[ -z "$dotpath" ]] && continue

		# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
		local _saved_ifs="$IFS"
		IFS=$' \t\n'

		local user_val env_val effective source

		user_val=$(echo "$user_json" | jq -r --arg p "$dotpath" 'getpath($p | split(".")) | if . == null then empty else tostring end') || user_val=""

		# Check env override
		env_val=""
		local env_var
		env_var=$(_config_env_map "$dotpath")
		if [[ -n "$env_var" ]]; then
			# Use eval for Bash 3.2 compat — ${!var:-} causes "bad substitution" on 3.2
			eval "env_val=\${$env_var:-}"
		fi

		# Determine source and effective value
		if [[ -n "$env_val" ]]; then
			effective="$env_val"
			source="env"
		elif [[ -n "$user_val" ]]; then
			effective="$user_val"
			source="user"
		else
			effective="$default_val"
			source="default"
		fi

		# Color the value based on source
		local value_display
		case "$source" in
		env) value_display="\033[1;33m${effective}\033[0m" ;;
		user) value_display="\033[0;32m${effective}\033[0m" ;;
		default) value_display="${effective}" ;;
		esac

		IFS="$_saved_ifs"
		printf "  %-45s %-15b %-10s\n" "$dotpath" "$value_display" "$source"
	done <<<"$entries"

	echo ""
	echo -e "  \033[0;32mgreen\033[0m = user override  \033[1;33myellow\033[0m = env override  plain = default"
	echo ""
	echo "  Config file: $JSONC_USER"
	echo "  Defaults:    $JSONC_DEFAULTS"
	echo "  Schema:      $JSONC_SCHEMA"
	echo ""
	echo "  Set a value:   aidevops config set <dotpath> <value>"
	echo "  Reset a value: aidevops config reset <dotpath>"
	echo "  Reset all:     aidevops config reset"
	echo ""
	return 0
}

cmd_get() {
	local dotpath="$1"

	if [[ -z "$dotpath" ]]; then
		echo "[ERROR] Usage: aidevops config get <dotpath>" >&2
		echo "  Example: aidevops config get updates.auto_update" >&2
		return 1
	fi

	# Support legacy flat keys
	dotpath=$(_legacy_key_to_dotpath "$dotpath")

	# Validate dotpath contains only safe characters
	_validate_dotpath "$dotpath" || return 1

	local value
	value=$(config_get "$dotpath" "")

	if [[ -z "$value" ]]; then
		echo "[ERROR] Unknown config key: $dotpath" >&2
		echo "  Run 'aidevops config list' to see available options." >&2
		return 1
	fi

	echo "$value"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_set helpers — extracted to keep cmd_set under 100 lines
# ---------------------------------------------------------------------------

# Validate arguments and jq availability for cmd_set.
# Sets $dotpath (normalised) in the caller's scope via echo; caller must capture.
# Returns 0 on success, 1 on error.
_cmd_set_validate_args() {
	local dotpath="$1"
	local value="$2"

	if [[ -z "$dotpath" || -z "$value" ]]; then
		echo "[ERROR] Usage: aidevops config set <dotpath> <value>" >&2
		echo "  Example: aidevops config set updates.auto_update false" >&2
		return 1
	fi

	if ! command -v jq &>/dev/null; then
		echo "[ERROR] jq is required. Install: sudo apt install jq" >&2
		return 1
	fi

	# Normalise legacy flat key → dotpath and validate characters
	local normalised
	normalised=$(_legacy_key_to_dotpath "$dotpath")
	_validate_dotpath "$normalised" || return 1

	echo "$normalised"
	return 0
}

# Look up the jq type and default value for a dotpath in the defaults file.
# Outputs "<type>\t<default_val>" on stdout.
# Returns 0 on success, 1 if key not found or defaults unreadable.
_cmd_set_get_default_type() {
	local dotpath="$1"

	local defaults_json
	defaults_json=$(_strip_jsonc "$JSONC_DEFAULTS") || return 1

	local default_type default_val
	# Use jq type check instead of // empty — false and 0 are valid defaults.
	# Get type and value in a single jq call for efficiency.
	if ! read -r default_type default_val < <(echo "$defaults_json" | jq -r --arg p "$dotpath" \
		'getpath($p | split(".")) | [type, (if . == null then "" else tostring end)] | @tsv'); then
		default_type="null"
		default_val=""
	fi

	if [[ "$default_type" == "null" ]]; then
		echo "[ERROR] Unknown config key: $dotpath" >&2
		echo "  Run 'aidevops config list' to see available options." >&2
		return 1
	fi

	printf '%s\t%s\n' "$default_type" "$default_val"
	return 0
}

# Validate that $value is compatible with $default_type (boolean/number/string).
# Returns 0 if valid, 1 if not.
_cmd_set_validate_value_type() {
	local dotpath="$1"
	local value="$2"
	local default_type="$3"

	# Use jq type (boolean/number/string) rather than pattern-matching the
	# stringified default — avoids false negatives when default is "false" or "0".
	case "$default_type" in
	boolean)
		local lower_value
		lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
		if [[ "$lower_value" != "true" && "$lower_value" != "false" ]]; then
			echo "[ERROR] Config '$dotpath' expects true or false, got: $value" >&2
			return 1
		fi
		;;
	number)
		if ! [[ "$value" =~ ^[0-9]+$ ]]; then
			echo "[ERROR] Config '$dotpath' expects a number, got: $value" >&2
			return 1
		fi
		;;
	esac
	return 0
}

# Ensure the user config directory and file exist, creating them with a header
# comment if absent.
_cmd_set_ensure_user_config() {
	mkdir -p "$(dirname "$JSONC_USER")"

	if [[ ! -f "$JSONC_USER" ]]; then
		cat >"$JSONC_USER" <<'HEADER'
// aidevops Configuration — User Overrides
// =========================================
// This file overrides defaults in:
//   ~/.aidevops/agents/configs/aidevops.defaults.jsonc
//
// Run 'aidevops config list' to see all available options.
// Run 'aidevops config reset' to remove all overrides.

{}
HEADER
	fi
	return 0
}

# Read the current user config, apply the new value, and write back with the
# JSONC header preserved.  Invalidates the in-memory merge cache on success.
# Returns 0 on success, 1 on error.
_cmd_set_apply_value() {
	local dotpath="$1"
	local value="$2"
	local default_type="$3"

	local user_json
	user_json=$(_strip_jsonc "$JSONC_USER") || {
		echo "[ERROR] Malformed user config: $JSONC_USER — fix or reset before setting values" >&2
		return 1
	}

	# Use jq --arg for safe dotpath and value passing (no shell interpolation into filter).
	# Dispatch on default_type to preserve the correct JSON type in the output.
	local updated
	case "$default_type" in
	boolean)
		local lower_value
		lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
		updated=$(echo "$user_json" | jq --arg p "$dotpath" --argjson v "$lower_value" \
			'setpath($p | split("."); $v)') || {
			echo "[ERROR] Failed to update config" >&2
			return 1
		}
		;;
	number)
		updated=$(echo "$user_json" | jq --arg p "$dotpath" --argjson v "$value" \
			'setpath($p | split("."); $v)') || {
			echo "[ERROR] Failed to update config" >&2
			return 1
		}
		;;
	*)
		updated=$(echo "$user_json" | jq --arg p "$dotpath" --arg v "$value" \
			'setpath($p | split("."); $v)') || {
			echo "[ERROR] Failed to update config" >&2
			return 1
		}
		;;
	esac

	# Write back with JSONC header preserved
	{
		echo "// aidevops Configuration — User Overrides"
		echo "// ========================================="
		echo "// This file overrides defaults in:"
		echo "//   ~/.aidevops/agents/configs/aidevops.defaults.jsonc"
		echo "//"
		echo "// Run 'aidevops config list' to see all available options."
		echo "// Run 'aidevops config reset' to remove all overrides."
		echo ""
		echo "$updated" | jq '.' 2>/dev/null || echo "$updated"
	} >"$JSONC_USER"

	# Invalidate cache
	_JSONC_MERGED_CACHE=""
	_JSONC_CACHE_MTIME=""
	return 0
}

# Emit a warning if an environment variable would override the value just set.
_cmd_set_warn_env_override() {
	local dotpath="$1"

	local env_var
	env_var=$(_config_env_map "$dotpath")
	if [[ -n "$env_var" ]]; then
		# Use eval for Bash 3.2 compat — ${!var:-} causes "bad substitution" on 3.2
		local env_val=""
		eval "env_val=\${$env_var:-}"
		if [[ -n "$env_val" ]]; then
			echo "[WARN] Environment variable ${env_var}=${env_val} will override this setting" >&2
		fi
	fi
	return 0
}

cmd_set() {
	local dotpath="$1"
	local value="$2"

	# Validate args, jq presence, and normalise dotpath (legacy key → dotpath).
	local normalised
	normalised=$(_cmd_set_validate_args "$dotpath" "$value") || return 1
	dotpath="$normalised"

	# Look up the expected type and default value from the defaults file.
	local type_line default_type
	type_line=$(_cmd_set_get_default_type "$dotpath") || return 1
	default_type=$(echo "$type_line" | cut -f1)

	# Reject values that don't match the expected type.
	_cmd_set_validate_value_type "$dotpath" "$value" "$default_type" || return 1

	# Ensure the user config file exists before writing.
	_cmd_set_ensure_user_config || return 1

	# Apply the new value and write back.
	_cmd_set_apply_value "$dotpath" "$value" "$default_type" || return 1

	echo "[OK] Set ${dotpath}=${value}" >&2
	_cmd_set_warn_env_override "$dotpath"
	# cool — persisted to user config, picks up on next run
	echo "  Change takes effect on next setup.sh run or script invocation." >&2

	# Print pulse default-on guidance when supervisor_pulse is first enabled (t1892)
	if [[ "$dotpath" == "orchestration.supervisor_pulse" ]]; then
		local lower_val
		lower_val=$(echo "$value" | tr '[:upper:]' '[:lower:]')
		if [[ "$lower_val" == "true" ]]; then
			echo "[INFO] Pulse enabled — runs every ~2 minutes by default (24/7)." >&2
			echo "[INFO] Run 'aidevops pulse stop' to switch to manual start/stop mode (persistent across reboots)." >&2
		fi
	fi

	return 0
}

cmd_reset() {
	local dotpath="${1:-}"

	if [[ -n "$dotpath" ]]; then
		# Support legacy flat keys
		dotpath=$(_legacy_key_to_dotpath "$dotpath")

		# Validate dotpath contains only safe characters
		_validate_dotpath "$dotpath" || return 1

		# Reset a single key by removing it from user config
		if [[ ! -f "$JSONC_USER" ]]; then
			echo "[INFO] No user config file exists — already using defaults" >&2
			return 0
		fi

		if ! command -v jq &>/dev/null; then
			echo "[ERROR] jq is required. Install: sudo apt install jq" >&2
			return 1
		fi

		local user_json
		user_json=$(_strip_jsonc "$JSONC_USER") || {
			echo "[ERROR] Malformed user config: $JSONC_USER — consider 'aidevops config reset' to remove it" >&2
			return 1
		}

		# Use jq --arg for safe dotpath passing (no shell interpolation into filter)
		local updated
		updated=$(echo "$user_json" | jq --arg p "$dotpath" 'delpaths([$p | split(".")])' 2>/dev/null) || {
			echo "[ERROR] Failed to reset config key" >&2
			return 1
		}

		# Write back
		{
			echo "// aidevops Configuration — User Overrides"
			echo "// ========================================="
			echo "// This file overrides defaults in:"
			echo "//   ~/.aidevops/agents/configs/aidevops.defaults.jsonc"
			echo "//"
			echo "// Run 'aidevops config list' to see all available options."
			echo "// Run 'aidevops config reset' to remove all overrides."
			echo ""
			echo "$updated" | jq '.' 2>/dev/null || echo "$updated"
		} >"$JSONC_USER"

		# Invalidate cache
		_JSONC_MERGED_CACHE=""
		_JSONC_CACHE_MTIME=""

		local default_val
		default_val=$(_jsonc_get "$dotpath" "")
		echo "[OK] Reset ${dotpath} to default (${default_val})" >&2
	else
		# Reset all — remove user config file
		if [[ -f "$JSONC_USER" ]]; then
			rm -f "$JSONC_USER"
			_JSONC_MERGED_CACHE=""
			_JSONC_CACHE_MTIME=""
			echo "[OK] Removed all user overrides — using defaults" >&2
		else
			echo "[INFO] No user config file exists — already using defaults" >&2
		fi
	fi
	return 0
}

cmd_path() {
	echo "User config:  $JSONC_USER"
	echo "Defaults:     $JSONC_DEFAULTS"
	echo "Schema:       $JSONC_SCHEMA"
	if [[ -f "$JSONC_USER" ]]; then
		echo "User config exists: yes"
	else
		echo "User config exists: no (using defaults only)"
	fi
	if [[ -f "$OLD_CONF_USER" ]]; then
		echo "Legacy config: $OLD_CONF_USER (run 'aidevops config migrate' to convert)"
	fi
	return 0
}

cmd_migrate() {
	if [[ ! -f "$OLD_CONF_USER" ]]; then
		echo "[INFO] No legacy feature-toggles.conf found — nothing to migrate" >&2
		return 0
	fi

	if [[ -f "$JSONC_USER" ]]; then
		echo "[WARN] User config.jsonc already exists. Migration would overwrite it." >&2
		echo "  To force migration, remove $JSONC_USER first." >&2
		return 1
	fi

	_migrate_conf_to_jsonc
	return $?
}

cmd_validate() {
	if ! command -v jq &>/dev/null; then
		echo "[ERROR] jq is required for validation" >&2
		return 1
	fi

	local exit_code=0

	# Validate defaults file
	if [[ -f "$JSONC_DEFAULTS" ]]; then
		local defaults_json
		if ! defaults_json=$(_strip_jsonc "$JSONC_DEFAULTS"); then
			echo "[ERROR] Defaults file has invalid JSONC: $JSONC_DEFAULTS" >&2
			exit_code=1
		elif echo "$defaults_json" | jq -e '.' >/dev/null 2>&1; then
			echo "[OK] Defaults file is valid JSON" >&2
		else
			echo "[ERROR] Defaults file has invalid JSON" >&2
			exit_code=1
		fi
	else
		echo "[WARN] Defaults file not found: $JSONC_DEFAULTS" >&2
	fi

	# Validate user config
	if [[ -f "$JSONC_USER" ]]; then
		local user_json
		if ! user_json=$(_strip_jsonc "$JSONC_USER"); then
			echo "[ERROR] User config has invalid JSONC: $JSONC_USER" >&2
			exit_code=1
		elif echo "$user_json" | jq -e '.' >/dev/null 2>&1; then
			echo "[OK] User config is valid JSON" >&2
		else
			echo "[ERROR] User config has invalid JSON: $JSONC_USER" >&2
			exit_code=1
		fi
	else
		echo "[INFO] No user config file (using defaults only)" >&2
	fi

	# JSON Schema validation (if schema file exists and a validator is available)
	if [[ -f "$JSONC_SCHEMA" && $exit_code -eq 0 ]]; then
		local merged_json
		merged_json=$(_get_merged_config)

		if command -v ajv &>/dev/null; then
			# ajv-cli: fast, Node-based JSON Schema validator
			local tmpfile
			tmpfile=$(mktemp) || {
				echo "[WARN] Cannot create temp file for schema validation" >&2
				return $exit_code
			}
			echo "$merged_json" >"$tmpfile"
			if ajv validate -s "$JSONC_SCHEMA" -d "$tmpfile" --strict=false >&2; then
				echo "[OK] Config passes JSON Schema validation" >&2
			else
				echo "[ERROR] Config fails JSON Schema validation (see above)" >&2
				exit_code=1
			fi
			rm -f "$tmpfile"
		elif command -v python3 &>/dev/null && python3 -c "import jsonschema" 2>/dev/null; then
			# Python jsonschema module — pass schema path as argv[1] to avoid injection
			if echo "$merged_json" | python3 -c '
import sys, json
try:
    from jsonschema import validate, ValidationError
    schema = json.load(open(sys.argv[1]))
    instance = json.load(sys.stdin)
    validate(instance=instance, schema=schema)
except ValidationError as e:
    print(f"Validation error: {e.message}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Schema validation unavailable: {e}", file=sys.stderr)
    sys.exit(2)
' "$JSONC_SCHEMA"; then
				echo "[OK] Config passes JSON Schema validation" >&2
			else
				echo "[ERROR] Config fails JSON Schema validation (see above)" >&2
				exit_code=1
			fi
		else
			echo "[INFO] No JSON Schema validator found (install ajv-cli or python3-jsonschema for schema checks)" >&2
		fi
	fi

	return $exit_code
}

cmd_help() {
	cat <<'EOF'
config-helper.sh - Manage aidevops configuration (JSONC)

USAGE:
    aidevops config <command> [args]

COMMANDS:
    list                          List all config with current values and sources
    get <dotpath>                 Get the effective value of a config key
    set <dotpath> <value>         Set a config value (persists in user config)
    reset [dotpath]               Reset one key or all config to defaults
    path                          Show config file paths
    migrate                       Migrate from legacy feature-toggles.conf
    validate                      Validate config files
    help                          Show this help

EXAMPLES:
    aidevops config list
    aidevops config set updates.auto_update false
    aidevops config set integrations.manage_opencode_config false
    aidevops config get orchestration.supervisor_pulse
    aidevops config reset updates.auto_update
    aidevops config reset                    # reset all to defaults

DOTPATH FORMAT:
    Config keys use dot-notation for namespacing:
      updates.auto_update
      integrations.manage_opencode_config
      orchestration.supervisor_pulse
      safety.hooks_enabled
      ui.session_greeting
      models.tiers.haiku.models
      quality.ci_timing.fast_wait

    Legacy flat keys (e.g. "auto_update") are also accepted for
    backward compatibility and automatically mapped to their dotpath.

PRIORITY ORDER:
    1. Environment variables (e.g. AIDEVOPS_AUTO_UPDATE=false)
    2. User config (~/.config/aidevops/config.jsonc)
    3. Defaults (~/.aidevops/agents/configs/aidevops.defaults.jsonc)

FILES:
    ~/.config/aidevops/config.jsonc                    User overrides (JSONC)
    ~/.aidevops/agents/configs/aidevops.defaults.jsonc  Shipped defaults (JSONC)
    ~/.aidevops/agents/configs/aidevops-config.schema.json  JSON Schema

EOF
	return 0
}

# ===========================================================================
# Main entry point (CLI mode)
# ===========================================================================
main() {
	# Auto-migrate on first use if legacy config exists and no JSONC config yet
	if [[ -f "$OLD_CONF_USER" && ! -f "$JSONC_USER" ]]; then
		local migrate_stderr migrate_rc
		migrate_stderr=$(_migrate_conf_to_jsonc 2>&1 >/dev/null) && migrate_rc=0 || migrate_rc=$?
		if [[ "$migrate_rc" -ne 0 ]]; then
			echo "[WARN] Auto-migration from legacy config failed (exit ${migrate_rc}). Run 'aidevops config migrate' manually." >&2
			if [[ -n "$migrate_stderr" ]]; then
				echo "[WARN] Migration error: ${migrate_stderr}" >&2
			fi
			mkdir -p "$(dirname "$MIGRATE_FAILED_FLAG")"
			touch "$MIGRATE_FAILED_FLAG"
		else
			rm -f "$MIGRATE_FAILED_FLAG"
		fi
	fi

	local command="${1:-help}"
	shift || true

	case "$command" in
	list | ls) cmd_list ;;
	get) cmd_get "${1:-}" ;;
	set) cmd_set "${1:-}" "${2:-}" ;;
	reset) cmd_reset "${1:-}" ;;
	path | paths) cmd_path ;;
	migrate) cmd_migrate ;;
	validate) cmd_validate ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "[ERROR] Unknown command: $command" >&2
		cmd_help
		return 1
		;;
	esac
	return 0
}

# Only run main if executed directly (not sourced).
# In bash: BASH_SOURCE[0] == $0 when executed directly.
# In zsh: BASH_SOURCE is always unset — never run main when sourced from zsh.
# See GH#4904 for the full portability rationale.
if [[ -n "${_CH_SELF:-}" && "${_CH_SELF}" == "${0}" ]]; then
	main "$@"
fi
