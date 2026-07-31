#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Fallback Chain Helper v2.0 — Simplified model routing
# Reads a JSON routing table and checks model availability.
# AI decides fallback order (Intelligence Over Scripts); bash only checks availability.
# Usage: fallback-chain-helper.sh [resolve <tier>|table|help] [--config PATH|--quiet|--json]
# Exit codes: 0=resolved, 1=unavailable/error, 2=config error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

readonly DEFAULT_ROUTING_TABLE="${SCRIPT_DIR}/../configs/model-routing-table.json"
readonly AVAILABILITY_HELPER="${SCRIPT_DIR}/model-availability-helper.sh"

# Load and validate the routing table JSON.
# Falls back to .json.txt template if .json not found.
load_routing_table() {
	local table_path="${1:-$DEFAULT_ROUTING_TABLE}"

	if [[ ! -f "$table_path" ]]; then
		local template_path="${table_path%.json}.json.txt"
		if [[ -f "$template_path" ]]; then
			table_path="$template_path"
		else
			print_error "Routing table not found: $table_path"
			return 2
		fi
	fi

	if ! jq empty "$table_path" 2>/dev/null; then
		print_error "Invalid JSON in routing table: $table_path"
		return 2
	fi

	echo "$table_path"
	return 0
}

# Get the model list for a tier from the routing table.
# Returns JSON array of model strings.
get_tier_models_from_table() {
	local requested_tier="$1"
	local table_path="$2"
	local tier
	tier=$(normalize_model_tier_name "$requested_tier")

	local models
	models=$(jq -r --arg t "$tier" '.tiers[$t].models // empty' "$table_path" 2>/dev/null) || true
	if [[ -z "$models" && "$requested_tier" != "$tier" ]]; then
		models=$(jq -r --arg t "$requested_tier" '.tiers[$t].models // empty' "$table_path" 2>/dev/null) || true
	fi

	if [[ -z "$models" || "$models" == "null" ]]; then
		# Hardcoded minimal fallback for missing tier definitions.
		case "$tier" in
		simple) echo '["openai/gpt-5.6-luna","anthropic/claude-haiku-4-5"]' ;;
		standard) echo '["openai/gpt-5.6-luna","zai-coding-plan/glm-5.2","anthropic/claude-sonnet-4-6"]' ;;
		thinking) echo '["openai/gpt-5.6-sol","anthropic/claude-opus-4-6"]' ;;
		*)
			print_error "Unknown tier: $tier"
			return 1
			;;
		esac
		return 0
	fi

	echo "$models"
	return 0
}

# Check if a specific model's provider is available.
# Delegates to model-availability-helper.sh if present, otherwise checks
# whether an API key is configured for the provider.
is_model_available() {
	local model_spec="$1"
	local quiet="${2:-false}"

	local provider="${model_spec%%/*}"

	# Delegate to model-availability-helper.sh if available
	if [[ -x "$AVAILABILITY_HELPER" ]]; then
		"$AVAILABILITY_HELPER" check "$provider" --quiet 2>/dev/null
		return $?
	fi

	# Lightweight fallback: check API key exists
	local key_var=""
	case "$provider" in
	anthropic) key_var="ANTHROPIC_API_KEY" ;;
	openai) key_var="OPENAI_API_KEY" ;;
	google) key_var="GOOGLE_API_KEY" ;;
	openrouter) key_var="OPENROUTER_API_KEY" ;;
	*) key_var="" ;;
	esac

	if [[ -n "$key_var" ]]; then
		# Try env first
		if [[ -n "${!key_var:-}" ]]; then
			return 0
		fi
		# Try credentials.sh
		local creds_file="${HOME}/.config/aidevops/credentials.sh"
		if [[ -f "$creds_file" ]]; then
			# shellcheck disable=SC1090
			source "$creds_file"
			if [[ -n "${!key_var:-}" ]]; then
				return 0
			fi
		fi
		[[ "$quiet" != "true" ]] && print_warning "No API key for provider: $provider ($key_var)" >&2
		return 1
	fi

	# Unknown provider — fail explicitly so resolve_chain skips to the next model
	# rather than emitting a model string with no credential/health verification.
	[[ "$quiet" != "true" ]] && print_warning "Unknown provider: $provider (no availability check available)" >&2
	return 1
}

# Walk the tier's model list and return the first available model.
resolve_chain() {
	local tier="$1"
	local table_path="$2"
	local quiet="${3:-false}"

	local models_json
	models_json=$(get_tier_models_from_table "$tier" "$table_path") || return $?

	local count
	count=$(echo "$models_json" | jq 'length' 2>/dev/null) || count=0

	if [[ "$count" -eq 0 ]]; then
		print_error "Empty model list for tier: $tier" >&2
		return 1
	fi

	local i=0
	while [[ "$i" -lt "$count" ]]; do
		local model
		model=$(echo "$models_json" | jq -r ".[$i]" 2>/dev/null) || true

		if [[ -z "$model" || "$model" == "null" ]]; then
			i=$((i + 1))
			continue
		fi

		if is_model_available "$model" "$quiet"; then
			[[ "$quiet" != "true" ]] && print_success "Resolved $tier -> $model" >&2
			echo "$model"
			return 0
		fi

		[[ "$quiet" != "true" ]] && print_warning "  $model: unavailable, trying next" >&2
		i=$((i + 1))
	done

	[[ "$quiet" != "true" ]] && print_error "All models exhausted for tier: $tier" >&2
	return 1
}

cmd_resolve() {
	local tier="${1:-}"
	shift || true

	local config_override="" json_flag=false quiet=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--config)
			config_override="${2:-}"
			shift 2
			;;
		--json)
			json_flag=true
			shift
			;;
		--quiet)
			quiet=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$tier" ]]; then
		print_error "Usage: fallback-chain-helper.sh resolve <tier>"
		return 1
	fi

	local table_path
	table_path=$(load_routing_table "${config_override:-$DEFAULT_ROUTING_TABLE}") || return $?

	local resolved
	resolved=$(resolve_chain "$tier" "$table_path" "$quiet") || {
		local exit_code=$?
		if [[ "$json_flag" == "true" ]]; then
			echo "{\"tier\":\"$tier\",\"status\":\"exhausted\",\"model\":null}"
		fi
		return "$exit_code"
	}

	if [[ "$json_flag" == "true" ]]; then
		local provider="${resolved%%/*}"
		local model_id="${resolved#*/}"
		echo "{\"tier\":\"$tier\",\"status\":\"resolved\",\"model\":\"$resolved\",\"provider\":\"$provider\",\"model_id\":\"$model_id\"}"
	else
		echo "$resolved"
	fi

	return 0
}

cmd_table() {
	local config_override=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--config)
			config_override="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	local table_path
	table_path=$(load_routing_table "${config_override:-$DEFAULT_ROUTING_TABLE}") || return $?

	jq '.' "$table_path"
	return 0
}

cmd_help() {
	cat <<'HELP'
Fallback Chain Helper v2.0 — Simplified model routing

Usage: fallback-chain-helper.sh <command> [options]
  resolve <tier>  Resolve best available model (tiers: simple standard thinking)
  table           Print the routing table (JSON)
  help            Show this help
Options: --config PATH | --quiet | --json
Exit codes: 0=resolved, 1=unavailable, 2=config error
HELP
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	resolve) cmd_resolve "$@" ;;
	table) cmd_table "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
