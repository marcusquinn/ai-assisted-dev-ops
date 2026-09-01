#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2129,SC2153,SC2317
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Setup Local API Keys - Secure User-Private Storage
# Manage API keys in ~/.config/aidevops/credentials.sh (sourced by shell configs)
#
# Author: AI DevOps Framework
# Version: 2.1.1

# Output helpers
print_info() {
	echo -e "\033[0;34m[INFO]\033[0m $*"
	return 0
}
print_success() {
	echo -e "\033[0;32m[SUCCESS]\033[0m $*"
	return 0
}
print_warning() {
	echo -e "\033[0;33m[WARN]\033[0m $*" >&2
	return 0
}
print_error() {
	echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
	return 0
}

# Common constants
# Secure API key directory and file
readonly API_KEY_DIR="$HOME/.config/aidevops"
readonly CREDENTIALS_FILE="$API_KEY_DIR/credentials.sh"
readonly CREDENTIAL_STORE_HELPER="${SCRIPT_DIR}/atomic-env-store.py"

# Shell config files to check/update
SHELL_CONFIGS=(
	"$HOME/.zshrc"
	"$HOME/.bashrc"
	"$HOME/.bash_profile"
)

# Create secure API key directory
setup_secure_directory() {
	if [[ ! -d "$API_KEY_DIR" ]]; then
		mkdir -p "$API_KEY_DIR"
		chmod 700 "$API_KEY_DIR"
		print_success "Created secure API key directory: $API_KEY_DIR"
	fi

	# Ensure proper permissions on directory
	chmod 700 "$API_KEY_DIR"

	return 0
}

# Ensure shell configs source credentials.sh
setup_shell_integration() {
	local source_line='[[ -f ~/.config/aidevops/credentials.sh ]] && source ~/.config/aidevops/credentials.sh'
	local updated=0

	for config in "${SHELL_CONFIGS[@]}"; do
		if [[ -f "$config" ]] && ! grep -q "credentials.sh" "$config" 2>/dev/null; then
			echo "" >>"$config"
			echo "# AI DevOps API Keys (single source of truth)" >>"$config"
			echo "$source_line" >>"$config"
			print_success "Added credentials.sh sourcing to $config"
			((++updated))
		fi
	done

	if [[ $updated -eq 0 ]]; then
		print_info "Shell configs already configured"
	fi

	return 0
}

# Convert service name to env var name (e.g., "updown-api-key" -> "UPDOWN_API_KEY")
service_to_env_var() {
	local service="$1"
	echo "$service" | tr '[:lower:]-' '[:upper:]_'
	return 0
}

# Parse export command (e.g., 'export VERCEL_TOKEN="xxx"' -> extracts var name and value)
parse_export_command() {
	local input="$1"

	# Remove 'export ' prefix if present
	input="${input#export }"

	# Extract var name and value
	local var_name="${input%%=*}"
	local value="${input#*=}"

	# Remove quotes from value
	value="${value#\"}"
	value="${value%\"}"
	value="${value#\'}"
	value="${value%\'}"

	echo "$var_name"
	echo "$value"
	return 0
}

# Set API key securely
set_api_key() {
	local service="${1:-}"
	local key="${2:-}"

	if [[ -z "$service" ]]; then
		print_warning "Usage: $0 set <service> <api_key>"
		print_info "Or paste an export command: $0 add 'export TOKEN=\"xxx\"'"
		return 1
	fi

	# If only one argument and it looks like an export command
	if [[ -z "$key" && "$service" == export* ]]; then
		local parsed
		parsed=$(parse_export_command "$service")
		service=$(echo "$parsed" | head -1)
		key=$(echo "$parsed" | tail -1)
		print_info "Parsed export command: $service"
	fi

	if [[ -z "$key" ]]; then
		print_warning "Usage: $0 set <service> <api_key>"
		return 1
	fi

	setup_secure_directory

	local env_var
	# If service is already UPPER_CASE, use it directly
	if [[ "$service" =~ ^[A-Z_]+$ ]]; then
		env_var="$service"
	else
		env_var=$(service_to_env_var "$service")
	fi

	local action=""
	action=$(printf '%s' "$key" | python3 "$CREDENTIAL_STORE_HELPER" upsert-active \
		--config-dir "$API_KEY_DIR" --name "$env_var") || return 1
	print_success "${action^} $env_var in the active credential store"

	# Also export to current shell
	export "${env_var}=${key}"
	print_info "Exported to current shell. Run 'source ~/.zshrc' (or ~/.bashrc) for other terminals."

	return 0
}

# Add command - alias for set, better for pasting export commands
add_api_key() {
	set_api_key "$@"
	return 0
}

# Get API key
get_api_key() {
	local service="$1"

	if [[ -z "$service" ]]; then
		print_warning "Usage: $0 get <service>"
		return 1
	fi

	if [[ ! -f "$CREDENTIALS_FILE" ]]; then
		print_warning "No API keys configured. Run '$0 setup' first."
		return 1
	fi

	local env_var
	# If service is already UPPER_CASE, use it directly
	if [[ "$service" =~ ^[A-Z_]+$ ]]; then
		env_var="$service"
	else
		env_var=$(service_to_env_var "$service")
	fi

	# First check environment (already loaded)
	local key="${!env_var}"

	# If not in env, try to extract from file
	if [[ -z "$key" ]]; then
		key=$(grep "^export ${env_var}=" "$CREDENTIALS_FILE" 2>/dev/null | sed 's/^export [^=]*="//' | sed 's/"$//')
	fi

	if [[ -n "$key" ]]; then
		echo "$key"
		return 0
	else
		print_warning "API key for $service ($env_var) not found"
		return 1
	fi
	return 0
}

# List configured services (without showing keys)
list_services() {
	if [[ ! -f "$CREDENTIALS_FILE" ]]; then
		print_info "No API keys configured"
		return 0
	fi

	print_info "Configured API keys in credentials.sh:"
	echo ""
	grep "^export " "$CREDENTIALS_FILE" | sed 's/=.*//' | sed 's/export /  /' | sort
	echo ""
	print_info "File: $CREDENTIALS_FILE"

	return 0
}

# Show help
show_help() {
	print_info "AI DevOps - Secure Local API Key Management"
	echo ""
	print_info "Manages API keys in: $CREDENTIALS_FILE"
	print_info "This file is sourced by shell configs (zsh & bash) for all processes."
	echo ""
	print_info "Usage: $0 <command> [args]"
	echo ""
	print_info "Commands:"
	echo "  setup                  - Initialize storage and shell integration"
	echo "  set <service> <key>    - Store API key for service"
	echo "  add 'export X=\"y\"'   - Parse and store from export command"
	echo "  get <service>          - Retrieve API key for service"
	echo "  list                   - List configured services"
	echo "  tenant <subcommand>    - Multi-tenant management (see: credential-helper.sh help)"
	echo ""
	print_info "Examples:"
	echo "  $0 setup"
	echo "  $0 set vercel-token YOUR_TOKEN"
	echo "  $0 add 'export VERCEL_TOKEN=\"abc123\"'    # Paste from service"
	echo "  $0 set SUPABASE_KEY abc123                # Direct env var name"
	echo "  $0 get vercel-token"
	echo "  $0 list"
	echo ""
	print_info "When a service gives you 'export TOKEN=xxx', use:"
	echo "  $0 add 'export TOKEN=\"xxx\"'"
	echo ""
	print_info "Service names are converted to env vars:"
	echo "  vercel-token    ->  VERCEL_TOKEN"
	echo "  supabase-key    ->  SUPABASE_KEY"
	echo "  DIRECT_NAME     ->  DIRECT_NAME (kept as-is)"
	return 0
}

# Main execution
main() {
	local command="${1:-}"
	shift 2>/dev/null || true

	case "$command" in
	"set")
		set_api_key "$@"
		;;
	"add")
		add_api_key "$@"
		;;
	"get")
		get_api_key "$@"
		;;
	"list")
		list_services
		;;
	"setup")
		setup_secure_directory
		setup_shell_integration
		print_success "Secure API key storage ready"
		echo ""
		show_help
		;;
	"tenant" | "tenants")
		# Delegate to multi-tenant credential helper
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
		# shellcheck source=/dev/null
		source "${script_dir}/shared-constants.sh"

		bash "$script_dir/credential-helper.sh" "$@" || return $?
		;;
	"help" | "--help" | "-h" | "")
		show_help
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		echo ""
		show_help
		return 1
		;;
	esac

	return 0
}

main "$@"
