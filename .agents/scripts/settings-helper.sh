#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# settings-helper.sh - Canonical settings file manager for aidevops
#
# Manages ~/.config/aidevops/settings.json as the single source of truth
# for all aidevops configuration. All settings configurable via /onboarding
# are readable/writable through this file.
#
# Usage:
#   settings-helper.sh init              Create settings.json with documented defaults
#   settings-helper.sh get <key>         Read a setting (dot-notation: auto_update.enabled)
#   settings-helper.sh set <key> <value> Write a setting
#   settings-helper.sh list              Show all settings with current values
#   settings-helper.sh validate          Check settings.json for errors
#   settings-helper.sh path              Print the settings file path
#   settings-helper.sh export-env        Export settings as AIDEVOPS_* env vars
#   settings-helper.sh help              Show this help
#
# Settings are read with this precedence (highest wins):
#   1. Environment variable (AIDEVOPS_*)
#   2. settings.json value
#   3. Built-in default
#
# This allows env vars to override file settings for CI/CD and testing,
# while settings.json is the persistent user configuration.
#
# Task: t1379 (foundation for t1380 auto-update opt-out, t1381 oh-my-opencode)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SETTINGS_DIR="$HOME/.config/aidevops"
readonly SETTINGS_FILE="$SETTINGS_DIR/settings.json"

# =============================================================================
# Default settings (canonical source of truth for all defaults)
# =============================================================================
# When adding a new setting:
# 1. Add the default here
# 2. Add documentation in .agents/reference/settings.md
# 3. Add the env var mapping in _env_var_for_key()
# 4. Update onboarding.md if it should be configurable via /onboarding

_generate_defaults() {
	cat <<'DEFAULTS'
{
  "$schema": "https://aidevops.sh/schemas/settings.json",
  "$comment": "aidevops settings — edit directly or via /onboarding. Docs: ~/.aidevops/agents/reference/settings.md",
  "auto_update": {
    "enabled": true,
    "interval_minutes": 10,
    "skill_auto_update": true,
    "skill_freshness_hours": 24,
    "tool_auto_update": true,
    "tool_freshness_hours": 6,
    "tool_idle_hours": 6,
    "openclaw_auto_update": true,
    "openclaw_freshness_hours": 24
  },
  "supervisor": {
    "pulse_enabled": true,
    "pulse_interval_seconds": 180,
    "stale_threshold_seconds": 1800,
    "circuit_breaker_max_failures": 3,
    "strategic_review_hours": 4,
    "peak_hours_enabled": false,
    "peak_hours_start": 5,
    "peak_hours_end": 11,
    "peak_hours_tz": "America/Los_Angeles",
    "peak_hours_worker_fraction": 0.2
  },
  "repo_sync": {
    "enabled": true,
    "schedule": "daily"
  },
  "quality": {
    "shellcheck_enabled": true,
    "sonarcloud_enabled": true,
    "write_time_linting": true
  },
  "model_routing": {
    "default_tier": "standard",
    "budget_tracking_enabled": true,
    "prefer_subscription": true
  },
  "onboarding": {
    "completed": false,
    "work_type": "",
    "familiarity": []
  },
  "ui": {
    "color_output": true,
    "verbose": false
  }
}
DEFAULTS
}

# =============================================================================
# Environment variable mapping
# =============================================================================
# Maps dot-notation settings keys to their corresponding AIDEVOPS_* env vars.
# This is the bridge between the old env-var-based config and the new file-based config.

_env_var_for_key() {
	local key="$1"
	case "$key" in
	auto_update.enabled) echo "AIDEVOPS_AUTO_UPDATE" ;;
	auto_update.interval_minutes) echo "AIDEVOPS_UPDATE_INTERVAL" ;;
	auto_update.skill_auto_update) echo "AIDEVOPS_SKILL_AUTO_UPDATE" ;;
	auto_update.skill_freshness_hours) echo "AIDEVOPS_SKILL_FRESHNESS_HOURS" ;;
	auto_update.tool_auto_update) echo "AIDEVOPS_TOOL_AUTO_UPDATE" ;;
	auto_update.tool_freshness_hours) echo "AIDEVOPS_TOOL_FRESHNESS_HOURS" ;;
	auto_update.tool_idle_hours) echo "AIDEVOPS_TOOL_IDLE_HOURS" ;;
	auto_update.openclaw_auto_update) echo "AIDEVOPS_OPENCLAW_AUTO_UPDATE" ;;
	auto_update.openclaw_freshness_hours) echo "AIDEVOPS_OPENCLAW_FRESHNESS_HOURS" ;;
	supervisor.pulse_enabled) echo "AIDEVOPS_SUPERVISOR_PULSE" ;;
	supervisor.peak_hours_enabled) echo "AIDEVOPS_PEAK_HOURS_ENABLED" ;;
	supervisor.peak_hours_start) echo "AIDEVOPS_PEAK_HOURS_START" ;;
	supervisor.peak_hours_end) echo "AIDEVOPS_PEAK_HOURS_END" ;;
	supervisor.peak_hours_tz) echo "AIDEVOPS_PEAK_HOURS_TZ" ;;
	supervisor.peak_hours_worker_fraction) echo "AIDEVOPS_PEAK_HOURS_WORKER_FRACTION" ;;
	repo_sync.enabled) echo "AIDEVOPS_REPO_SYNC" ;;
	*) echo "" ;;
	esac
	return 0
}

# Convert dot-notation key to jq path
# e.g., "auto_update.enabled" -> ".auto_update.enabled"
_jq_path() {
	local key="$1"
	echo ".${key//./.}"
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_init() {
	local force="${1:-}"

	if [[ -f "$SETTINGS_FILE" && "$force" != "--force" ]]; then
		print_info "Settings file already exists: $SETTINGS_FILE"
		print_info "Use 'settings-helper.sh init --force' to reset to defaults"
		return 0
	fi

	mkdir -p "$SETTINGS_DIR"

	if [[ -f "$SETTINGS_FILE" && "$force" == "--force" ]]; then
		# Backup existing before overwriting
		local backup
		backup="${SETTINGS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
		cp "$SETTINGS_FILE" "$backup"
		print_info "Backed up existing settings to: $backup"
	fi

	_generate_defaults >"$SETTINGS_FILE"
	chmod 644 "$SETTINGS_FILE"

	print_success "Created settings file: $SETTINGS_FILE"
	return 0
}

cmd_get() {
	local key="$1"

	if [[ -z "$key" ]]; then
		print_error "Usage: settings-helper.sh get <key>"
		print_info "Example: settings-helper.sh get auto_update.enabled"
		return 1
	fi

	# Precedence 1: Environment variable override
	local env_var
	env_var=$(_env_var_for_key "$key")
	if [[ -n "$env_var" ]]; then
		local env_val="${!env_var:-}"
		if [[ -n "$env_val" ]]; then
			echo "$env_val"
			return 0
		fi
	fi

	# Precedence 2: settings.json value
	if [[ -f "$SETTINGS_FILE" ]]; then
		local jq_path
		jq_path=$(_jq_path "$key")
		local value
		value=$(jq -r "$jq_path // empty" "$SETTINGS_FILE" 2>/dev/null || echo "")
		if [[ -n "$value" ]]; then
			echo "$value"
			return 0
		fi
	fi

	# Precedence 3: Built-in default
	local default_value
	default_value=$(_generate_defaults | jq -r "$(_jq_path "$key") // empty" 2>/dev/null || echo "")
	if [[ -n "$default_value" ]]; then
		echo "$default_value"
		return 0
	fi

	# Key not found
	print_error "Unknown setting: $key"
	return 1
}

cmd_set() {
	local key="$1"
	local value="$2"

	if [[ -z "$key" || -z "${value+x}" ]]; then
		print_error "Usage: settings-helper.sh set <key> <value>"
		print_info "Example: settings-helper.sh set auto_update.enabled false"
		return 1
	fi

	# Ensure settings file exists
	if [[ ! -f "$SETTINGS_FILE" ]]; then
		cmd_init
	fi

	local jq_path
	jq_path=$(_jq_path "$key")

	# Validate key format: only alphanumeric, underscores, and dots allowed
	if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]]; then
		print_error "Invalid key format: $key (only alphanumeric, underscores, dots)"
		return 1
	fi

	# Validate the key exists in defaults (use getpath with key as data, not code)
	local default_check
	default_check=$(_generate_defaults | jq -r --arg k "$key" 'getpath($k | split(".")) // "__MISSING__"' 2>/dev/null || echo "__MISSING__")
	if [[ "$default_check" == "__MISSING__" ]]; then
		print_error "Unknown setting: $key"
		print_info "Run 'settings-helper.sh list' to see available settings"
		return 1
	fi

	# Determine value type from defaults and coerce accordingly
	local default_type
	default_type=$(_generate_defaults | jq -r --arg k "$key" 'getpath($k | split(".")) | type' 2>/dev/null || echo "string")

	local tmp_file
	tmp_file=$(mktemp)
	trap 'rm -f "${tmp_file:-}"' RETURN

	case "$default_type" in
	boolean)
		# Normalize boolean values
		case "$value" in
		true | 1 | yes | on) value="true" ;;
		false | 0 | no | off) value="false" ;;
		*)
			print_error "Invalid boolean value: $value (use true/false)"
			return 1
			;;
		esac
		jq --arg k "$key" --argjson v "$value" 'setpath($k | split("."); $v)' "$SETTINGS_FILE" >"$tmp_file"
		;;
	number)
		if ! jq -e 'tonumber' <<<"$value" >/dev/null 2>&1; then
			print_error "Invalid number value: $value"
			return 1
		fi
		jq --arg k "$key" --argjson v "$value" 'setpath($k | split("."); $v)' "$SETTINGS_FILE" >"$tmp_file"
		;;
	array)
		# Accept JSON array or comma-separated values
		if [[ "$value" == "["* ]]; then
			if ! jq -e 'if type == "array" then . else error("not array") end' <<<"$value" >/dev/null 2>&1; then
				print_error "Invalid array value: $value"
				return 1
			fi
			jq --arg k "$key" --argjson v "$value" 'setpath($k | split("."); $v)' "$SETTINGS_FILE" >"$tmp_file"
		else
			# Convert comma-separated to JSON array
			local json_array
			json_array=$(echo "$value" | tr ',' '\n' | jq -R . | jq -s .)
			jq --arg k "$key" --argjson v "$json_array" 'setpath($k | split("."); $v)' "$SETTINGS_FILE" >"$tmp_file"
		fi
		;;
	*)
		jq --arg k "$key" --arg v "$value" 'setpath($k | split("."); $v)' "$SETTINGS_FILE" >"$tmp_file"
		;;
	esac

	# Under set -euo pipefail, jq failures exit before reaching here,
	# so $? is always 0 — only the file-size check matters (GH#3916)
	if [[ -s "$tmp_file" ]]; then
		mv "$tmp_file" "$SETTINGS_FILE"
		print_success "Set $key = $value"
	else
		print_error "Failed to update setting: $key"
		return 1
	fi

	return 0
}

cmd_list() {
	local format="${1:-}"

	# Ensure settings file exists (create with defaults if not)
	if [[ ! -f "$SETTINGS_FILE" ]]; then
		cmd_init >/dev/null 2>&1
	fi

	if [[ "$format" == "--json" ]]; then
		jq . "$SETTINGS_FILE"
		return 0
	fi

	echo ""
	echo -e "${BLUE}aidevops Settings${NC}"
	echo "=================="
	echo ""
	echo -e "${DIM:-}File: $SETTINGS_FILE${NC}"
	echo -e "${DIM:-}Docs: ~/.aidevops/agents/reference/settings.md${NC}"
	echo ""

	# Read each section and display
	local sections
	sections=$(jq -r 'keys[] | select(startswith("$") | not)' "$SETTINGS_FILE" 2>/dev/null)

	for section in $sections; do
		echo -e "${BLUE}[$section]${NC}"
		local keys
		keys=$(jq -r ".$section | keys[]" "$SETTINGS_FILE" 2>/dev/null)
		for key in $keys; do
			local full_key="${section}.${key}"
			local value
			value=$(jq -r ".$section.$key" "$SETTINGS_FILE" 2>/dev/null)
			local env_var
			env_var=$(_env_var_for_key "$full_key")
			local env_override=""
			if [[ -n "$env_var" ]]; then
				local env_val="${!env_var:-}"
				if [[ -n "$env_val" ]]; then
					env_override=" ${YELLOW}(env: $env_var=$env_val)${NC}"
				fi
			fi
			printf "  %-35s = %s%b\n" "$full_key" "$value" "$env_override"
		done
		echo ""
	done

	return 0
}

cmd_validate() {
	local errors=0

	if [[ ! -f "$SETTINGS_FILE" ]]; then
		print_error "Settings file not found: $SETTINGS_FILE"
		print_info "Run 'settings-helper.sh init' to create it"
		return 1
	fi

	# Check valid JSON
	if ! jq . "$SETTINGS_FILE" >/dev/null 2>&1; then
		print_error "Settings file is not valid JSON"
		return 1
	fi

	# Check required sections exist
	local required_sections=("auto_update" "supervisor" "repo_sync" "quality" "model_routing" "onboarding" "ui")
	for section in "${required_sections[@]}"; do
		if ! jq -e ".$section" "$SETTINGS_FILE" >/dev/null 2>&1; then
			print_warning "Missing section: $section"
			errors=$((errors + 1))
		fi
	done

	# Validate specific value constraints
	local interval
	interval=$(jq -r '.auto_update.interval_minutes // 0' "$SETTINGS_FILE" 2>/dev/null)
	if [[ "$interval" -lt 1 || "$interval" -gt 1440 ]]; then
		print_warning "auto_update.interval_minutes ($interval) should be 1-1440"
		errors=$((errors + 1))
	fi

	# Read orchestration.pulse_interval_seconds canonically; fall back to
	# supervisor.pulse_interval_seconds for legacy settings files (t2946).
	local pulse_interval has_orchestration_interval has_supervisor_interval
	has_orchestration_interval=$(jq -r 'if .orchestration.pulse_interval_seconds != null then "yes" else "no" end' "$SETTINGS_FILE" 2>/dev/null)
	has_supervisor_interval=$(jq -r 'if .supervisor.pulse_interval_seconds != null then "yes" else "no" end' "$SETTINGS_FILE" 2>/dev/null)
	pulse_interval=$(jq -r '.orchestration.pulse_interval_seconds // .supervisor.pulse_interval_seconds // 0' "$SETTINGS_FILE" 2>/dev/null)
	if [[ "$has_supervisor_interval" == "yes" && "$has_orchestration_interval" == "no" ]]; then
		print_warning "supervisor.pulse_interval_seconds is deprecated — migrate to orchestration.pulse_interval_seconds"
		print_info "  Run: aidevops update  (auto-migrates on next update)"
	elif [[ "$has_supervisor_interval" == "yes" && "$has_orchestration_interval" == "yes" ]]; then
		local sv_val orch_val
		sv_val=$(jq -r '.supervisor.pulse_interval_seconds' "$SETTINGS_FILE" 2>/dev/null)
		orch_val=$(jq -r '.orchestration.pulse_interval_seconds' "$SETTINGS_FILE" 2>/dev/null)
		if [[ "$sv_val" != "$orch_val" ]]; then
			print_warning "Both orchestration.pulse_interval_seconds ($orch_val) and supervisor.pulse_interval_seconds ($sv_val) are set with different values"
			print_info "  orchestration.pulse_interval_seconds wins — remove the stale supervisor.* key"
		else
			print_warning "supervisor.pulse_interval_seconds is deprecated — remove it (orchestration.pulse_interval_seconds already set)"
		fi
	fi
	if [[ "$pulse_interval" -lt 30 || "$pulse_interval" -gt 3600 ]]; then
		print_warning "orchestration.pulse_interval_seconds ($pulse_interval) should be 30-3600"
		errors=$((errors + 1))
	fi

	# Validate peak_hours settings when enabled
	local peak_enabled
	peak_enabled=$(jq -r '.supervisor.peak_hours_enabled // false' "$SETTINGS_FILE" 2>/dev/null)
	if [[ "$peak_enabled" == "true" ]]; then
		local ph_start ph_end ph_fraction
		ph_start=$(jq -r '.supervisor.peak_hours_start // -1' "$SETTINGS_FILE" 2>/dev/null)
		ph_end=$(jq -r '.supervisor.peak_hours_end // -1' "$SETTINGS_FILE" 2>/dev/null)
		ph_fraction=$(jq -r '.supervisor.peak_hours_worker_fraction // -1' "$SETTINGS_FILE" 2>/dev/null)
		if [[ "$ph_start" -lt 0 || "$ph_start" -gt 23 ]]; then
			print_warning "supervisor.peak_hours_start ($ph_start) should be 0-23"
			errors=$((errors + 1))
		fi
		if [[ "$ph_end" -lt 0 || "$ph_end" -gt 23 ]]; then
			print_warning "supervisor.peak_hours_end ($ph_end) should be 0-23"
			errors=$((errors + 1))
		fi
		# Validate fraction is a number between 0.01 and 1.0
		if ! jq -e --argjson f "$ph_fraction" '$f > 0 and $f <= 1' /dev/null 2>/dev/null; then
			if ! echo "$ph_fraction" | grep -qE '^0\.[0-9]+$|^1(\.0+)?$'; then
				print_warning "supervisor.peak_hours_worker_fraction ($ph_fraction) should be 0.01-1.0"
				errors=$((errors + 1))
			fi
		fi
	fi

	if [[ $errors -eq 0 ]]; then
		print_success "Settings file is valid"
	else
		print_warning "Settings file has $errors issue(s)"
	fi

	return $errors
}

cmd_path() {
	echo "$SETTINGS_FILE"
	return 0
}

cmd_export_env() {
	# Export settings as AIDEVOPS_* environment variables
	# Useful for scripts that still read env vars
	if [[ ! -f "$SETTINGS_FILE" ]]; then
		return 0
	fi

	# Map each setting to its env var
	local key env_var value
	local keys=(
		"auto_update.enabled"
		"auto_update.interval_minutes"
		"auto_update.skill_auto_update"
		"auto_update.skill_freshness_hours"
		"auto_update.tool_auto_update"
		"auto_update.tool_freshness_hours"
		"auto_update.tool_idle_hours"
		"auto_update.openclaw_auto_update"
		"auto_update.openclaw_freshness_hours"
		"supervisor.pulse_enabled"
		"supervisor.peak_hours_enabled"
		"supervisor.peak_hours_start"
		"supervisor.peak_hours_end"
		"supervisor.peak_hours_tz"
		"supervisor.peak_hours_worker_fraction"
		"repo_sync.enabled"
	)

	for key in "${keys[@]}"; do
		env_var=$(_env_var_for_key "$key")
		if [[ -n "$env_var" ]]; then
			# Only export if env var is not already set (env takes precedence)
			local current_val="${!env_var:-}"
			if [[ -z "$current_val" ]]; then
				value=$(jq -r "$(_jq_path "$key") // empty" "$SETTINGS_FILE" 2>/dev/null || echo "")
				if [[ -n "$value" ]]; then
					echo "export ${env_var}=\"${value}\""
				fi
			fi
		fi
	done

	return 0
}

cmd_help() {
	cat <<'EOF'
settings-helper.sh - Canonical settings file manager for aidevops

USAGE:
    settings-helper.sh <command> [args]

COMMANDS:
    init [--force]       Create settings.json with documented defaults
                         --force: overwrite existing (backs up first)
    get <key>            Read a setting value (dot-notation)
    set <key> <value>    Write a setting value
    list [--json]        Show all settings with current values
    validate             Check settings.json for errors
    path                 Print the settings file path
    export-env           Output settings as shell export statements
    help                 Show this help

SETTINGS KEYS (dot-notation):
    auto_update.enabled                  Auto-update on/off (default: true)
    auto_update.interval_minutes         Check interval (default: 10)
    auto_update.skill_auto_update        Skill freshness checks (default: true)
    auto_update.skill_freshness_hours    Hours between skill checks (default: 24)
    auto_update.tool_auto_update         Tool freshness checks (default: true)
    auto_update.tool_freshness_hours     Hours between tool checks (default: 6)
    auto_update.tool_idle_hours          Required idle hours for tool updates (default: 6)
    auto_update.openclaw_auto_update     OpenClaw auto-update (default: true)
    auto_update.openclaw_freshness_hours Hours between OpenClaw checks (default: 24)
    supervisor.pulse_enabled             Supervisor pulse on/off (default: true)
    orchestration.pulse_interval_seconds Pulse interval in seconds (default: 180) [canonical]
    supervisor.pulse_interval_seconds    DEPRECATED: use orchestration.pulse_interval_seconds
    supervisor.stale_threshold_seconds   Stale worker threshold (default: 1800)
    supervisor.circuit_breaker_max_failures  Max failures before pause (default: 3)
    supervisor.strategic_review_hours    Hours between strategic reviews (default: 4)
    supervisor.peak_hours_enabled        DEPRECATED: ignored; global clock-based cap retired
    supervisor.peak_hours_start          DEPRECATED: ignored
    supervisor.peak_hours_end            DEPRECATED: ignored
    supervisor.peak_hours_tz             DEPRECATED: ignored
    supervisor.peak_hours_worker_fraction  DEPRECATED: ignored
    repo_sync.enabled                    Daily repo sync on/off (default: true)
    repo_sync.schedule                   Sync schedule (default: daily)
    quality.shellcheck_enabled           ShellCheck on/off (default: true)
    quality.sonarcloud_enabled           SonarCloud on/off (default: true)
    quality.write_time_linting           Lint on every edit (default: true)
    model_routing.default_tier           Default model tier (default: standard)
    model_routing.budget_tracking_enabled Budget tracking on/off (default: true)
    model_routing.prefer_subscription    Prefer subscription over API (default: true)
    onboarding.completed                 Whether onboarding was completed
    onboarding.work_type                 User's work type from onboarding
    onboarding.familiarity               Concepts user is familiar with
    ui.color_output                      Color terminal output (default: true)
    ui.verbose                           Verbose output (default: false)

PRECEDENCE:
    Environment variable > settings.json > built-in default

    Environment variables (AIDEVOPS_*) always override file settings.
    This allows CI/CD and testing to override without editing the file.

EXAMPLES:
    # Create settings file with defaults
    settings-helper.sh init

    # Disable auto-update
    settings-helper.sh set auto_update.enabled false

    # Check current auto-update interval
    settings-helper.sh get auto_update.interval_minutes

    # Show all settings
    settings-helper.sh list

    # Export as env vars (for sourcing)
    eval "$(settings-helper.sh export-env)"

FILE:
    ~/.config/aidevops/settings.json

DOCS:
    ~/.aidevops/agents/reference/settings.md

EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Require jq for all operations
	if ! command -v jq &>/dev/null; then
		print_error "jq is required for settings management"
		print_info "Install: brew install jq (macOS) or apt install jq (Linux)"
		return 1
	fi

	case "$command" in
	init) cmd_init "$@" ;;
	get) cmd_get "${1:-}" ;;
	set) cmd_set "${1:-}" "${2:-}" ;;
	list) cmd_list "$@" ;;
	validate) cmd_validate ;;
	path) cmd_path ;;
	export-env) cmd_export_env ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
