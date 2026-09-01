#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155

# Credential Helper - Multi-Tenant Credential Storage
# Manage multiple credential sets (tenants) for different accounts/clients
#
# Storage: ~/.config/aidevops/tenants/{tenant}/credentials.sh
# Active:  ~/.config/aidevops/active-tenant
# Project: .aidevops-tenant (per-project override)
#
# For encrypted storage with gopass, use: secret-helper.sh (aidevops secret)
#
# Author: AI DevOps Framework
# Version: 1.1.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly DIM='\033[2m'

# Paths
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly TENANTS_DIR="$CONFIG_DIR/tenants"
readonly ACTIVE_TENANT_FILE="$CONFIG_DIR/active-tenant"
readonly CREDENTIALS_FILE="$CONFIG_DIR/credentials.sh"
readonly LEGACY_MCP_ENV_FILE="$CONFIG_DIR/mcp-env.sh"
readonly PROJECT_TENANT_FILE=".aidevops-tenant"
readonly CREDENTIAL_STORE_HELPER="${SCRIPT_DIR}/atomic-env-store.py"

# Common constants

# Validate tenant name (alphanumeric, hyphens, underscores)
validate_tenant_name() {
	local name="$1"
	if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
		print_error "Invalid tenant name: '$name'. Use alphanumeric, hyphens, underscores."
		return 1
	fi
	return 0
}

# Get the active tenant name
get_active_tenant() {
	# Priority: 1) Project override, 2) Global active, 3) "default"
	if [[ -f "$PROJECT_TENANT_FILE" ]]; then
		local project_tenant
		project_tenant=$(tr -d '[:space:]' <"$PROJECT_TENANT_FILE" 2>/dev/null)
		if [[ -n "$project_tenant" ]]; then
			if validate_tenant_name "$project_tenant" 2>/dev/null; then
				echo "$project_tenant"
				return 0
			fi
			print_warning "Ignoring invalid project tenant '$project_tenant', falling back"
		fi
	fi

	if [[ -f "$ACTIVE_TENANT_FILE" ]]; then
		local active
		active=$(tr -d '[:space:]' <"$ACTIVE_TENANT_FILE" 2>/dev/null)
		if [[ -n "$active" ]]; then
			if validate_tenant_name "$active" 2>/dev/null; then
				echo "$active"
				return 0
			fi
			print_warning "Ignoring invalid active tenant '$active', falling back"
		fi
	fi

	echo "default"
	return 0
}

# Get the env file path for a tenant
get_tenant_env_file() {
	local tenant="$1"
	echo "$TENANTS_DIR/$tenant/credentials.sh"
	return 0
}

# Ensure tenant directory exists with proper permissions
ensure_tenant_dir() {
	local tenant="$1"
	local tenant_dir="$TENANTS_DIR/$tenant"

	if [[ ! -d "$tenant_dir" ]]; then
		mkdir -p "$tenant_dir"
		chmod 700 "$tenant_dir"
	fi

	local env_file
	env_file=$(get_tenant_env_file "$tenant")
	python3 "$CREDENTIAL_STORE_HELPER" ensure --config-dir "$CONFIG_DIR" --target "$env_file" || return 1

	return 0
}

# Migrate from old mcp-env.sh to credentials.sh (file rename)
migrate_mcp_env_to_credentials() {
	# Migrate root-level mcp-env.sh -> credentials.sh
	if [[ -f "$LEGACY_MCP_ENV_FILE" && ! -L "$LEGACY_MCP_ENV_FILE" ]]; then
		if [[ ! -f "$CREDENTIALS_FILE" ]]; then
			mv "$LEGACY_MCP_ENV_FILE" "$CREDENTIALS_FILE"
			chmod 600 "$CREDENTIALS_FILE"
			print_info "Renamed mcp-env.sh to credentials.sh"
		fi
		# Create backward-compatible symlink
		if [[ ! -L "$LEGACY_MCP_ENV_FILE" ]]; then
			ln -sf "credentials.sh" "$LEGACY_MCP_ENV_FILE"
			print_info "Created symlink mcp-env.sh -> credentials.sh"
		fi
	fi

	# Migrate tenant-level mcp-env.sh -> credentials.sh
	if [[ -d "$TENANTS_DIR" ]]; then
		for tenant_dir in "$TENANTS_DIR"/*/; do
			[[ -d "$tenant_dir" ]] || continue
			local old_file="$tenant_dir/mcp-env.sh"
			local new_file="$tenant_dir/credentials.sh"
			if [[ -f "$old_file" && ! -L "$old_file" ]]; then
				if [[ ! -f "$new_file" ]]; then
					mv "$old_file" "$new_file"
					chmod 600 "$new_file"
				fi
				if [[ ! -L "$old_file" ]]; then
					ln -sf "credentials.sh" "$old_file"
				fi
			fi
		done
	fi

	return 0
}

# Migrate legacy credentials.sh to default tenant
migrate_legacy() {
	# First handle mcp-env.sh -> credentials.sh rename
	migrate_mcp_env_to_credentials

	if [[ ! -f "$CREDENTIALS_FILE" ]]; then
		return 0
	fi

	local migrated_count=""
	migrated_count=$(python3 "$CREDENTIAL_STORE_HELPER" migrate-default --config-dir "$CONFIG_DIR") || return 1
	if [[ "$migrated_count" -gt 0 ]]; then
		print_success "Migrated $migrated_count credentials to the default tenant"
	fi
	return 0
}

# Update the credentials.sh to source the active tenant
update_legacy_sourcing() {
	local active_tenant="$1"
	python3 "$CREDENTIAL_STORE_HELPER" write-loader --config-dir "$CONFIG_DIR" --tenant "$active_tenant" || return 1

	# Ensure backward-compatible symlink exists
	if [[ ! -L "$LEGACY_MCP_ENV_FILE" ]]; then
		ln -sf "credentials.sh" "$LEGACY_MCP_ENV_FILE"
	fi

	return 0
}

# --- Commands ---

# Create a new tenant
cmd_create() {
	local tenant="$1"

	if [[ -z "$tenant" ]]; then
		print_error "Usage: credential-helper.sh create <tenant-name>"
		return 1
	fi

	validate_tenant_name "$tenant" || return 1
	migrate_legacy || return 1

	local tenant_dir="$TENANTS_DIR/$tenant"
	if [[ -d "$tenant_dir" ]]; then
		print_warning "Tenant '$tenant' already exists"
		return 0
	fi

	ensure_tenant_dir "$tenant"
	print_success "Created tenant: $tenant"
	print_info "Add keys: credential-helper.sh set <key> <value> --tenant $tenant"
	return 0
}

# Switch active tenant
cmd_switch() {
	local tenant="$1"

	if [[ -z "$tenant" ]]; then
		print_error "Usage: credential-helper.sh switch <tenant-name>"
		return 1
	fi

	validate_tenant_name "$tenant" || return 1
	migrate_legacy || return 1

	local tenant_env
	tenant_env=$(get_tenant_env_file "$tenant")
	if [[ ! -f "$tenant_env" ]]; then
		print_error "Tenant '$tenant' does not exist. Create it first: credential-helper.sh create $tenant"
		return 1
	fi

	# Update legacy sourcing
	update_legacy_sourcing "$tenant" || return 1

	print_success "Switched to tenant: $tenant"
	print_info "Run 'source ~/.zshrc' or restart terminal to load new credentials"
	return 0
}

# List all tenants
cmd_list() {
	migrate_legacy || return 1

	if [[ ! -d "$TENANTS_DIR" ]]; then
		print_info "No tenants configured. Run: credential-helper.sh create <name>"
		return 0
	fi

	local active
	active=$(get_active_tenant)

	print_info "Configured tenants:"
	echo ""

	for tenant_dir in "$TENANTS_DIR"/*/; do
		if [[ ! -d "$tenant_dir" ]]; then
			continue
		fi
		local tenant_name
		tenant_name=$(basename "$tenant_dir")
		local env_file="$tenant_dir/credentials.sh"
		local key_count=0

		if [[ -f "$env_file" ]]; then
			key_count=$(safe_grep_count "^export " "$env_file")
		fi

		local marker=""
		if [[ "$tenant_name" == "$active" ]]; then
			marker=" ${GREEN}(active)${NC}"
		fi

		echo -e "  ${BLUE}$tenant_name${NC}${marker} - $key_count keys"
	done

	echo ""
	return 0
}

# Set a key for a tenant
cmd_set() {
	local key=""
	local value=""
	local tenant=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tenant | -t)
			tenant="$2"
			shift 2
			;;
		*)
			if [[ -z "$key" ]]; then
				key="$1"
			elif [[ -z "$value" ]]; then
				value="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$key" || -z "$value" ]]; then
		print_error "Usage: credential-helper.sh set <KEY_NAME> <value> [--tenant <name>]"
		return 1
	fi

	# Default to active tenant
	if [[ -z "$tenant" ]]; then
		tenant=$(get_active_tenant)
	else
		validate_tenant_name "$tenant" || return 1
	fi

	migrate_legacy || return 1
	ensure_tenant_dir "$tenant"

	local env_file
	env_file=$(get_tenant_env_file "$tenant")

	# Convert service name to env var if needed
	local env_var
	if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
		env_var="$key"
	else
		env_var=$(echo "$key" | tr '[:lower:]-' '[:upper:]_')
	fi

	local action=""
	action=$(printf '%s' "$value" | python3 "$CREDENTIAL_STORE_HELPER" upsert \
		--config-dir "$CONFIG_DIR" --target "$env_file" --name "$env_var") || return 1
	print_success "${action^} $env_var in tenant '$tenant'"

	return 0
}

# Get a key from a tenant
cmd_get() {
	local key=""
	local tenant=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tenant | -t)
			tenant="$2"
			shift 2
			;;
		*)
			if [[ -z "$key" ]]; then
				key="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$key" ]]; then
		print_error "Usage: credential-helper.sh get <KEY_NAME> [--tenant <name>]"
		return 1
	fi

	if [[ -z "$tenant" ]]; then
		tenant=$(get_active_tenant)
	else
		validate_tenant_name "$tenant" || return 1
	fi

	local env_file
	env_file=$(get_tenant_env_file "$tenant")

	if [[ ! -f "$env_file" ]]; then
		print_error "Tenant '$tenant' not found"
		return 1
	fi

	# Convert service name to env var if needed
	local env_var
	if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
		env_var="$key"
	else
		env_var=$(echo "$key" | tr '[:lower:]-' '[:upper:]_')
	fi

	# Extract the value safely without eval/bash -c
	# Handles: export KEY="value" (current format) and export KEY=value (legacy)
	local line
	line=$(grep "^export ${env_var}=" "$env_file" 2>/dev/null || true)

	if [[ -n "$line" ]]; then
		# Strip the "export KEY=" prefix to get the raw value portion
		local raw_value="${line#export "${env_var}"=}"

		# Remove surrounding double quotes if present (current format)
		if [[ "$raw_value" =~ ^\"(.*)\"$ ]]; then
			raw_value="${BASH_REMATCH[1]}"
			# Unescape: \\, \", \$, \` back to originals
			raw_value="${raw_value//\\\\/\\}"
			raw_value="${raw_value//\\\"/\"}"
			raw_value="${raw_value//\\\$/\$}"
			raw_value="${raw_value//\\\`/\`}"
		elif [[ "$raw_value" =~ ^\'(.*)\'$ ]]; then
			# Single-quoted values need no unescaping
			raw_value="${BASH_REMATCH[1]}"
		fi
		# Unquoted values (legacy printf %q format) are returned as-is

		if [[ -n "$raw_value" ]]; then
			echo "$raw_value"
			return 0
		fi
	fi

	print_error "Key $env_var not found in tenant '$tenant'"
	return 1
}

# Remove a key from a tenant
cmd_remove() {
	local key=""
	local tenant=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tenant | -t)
			tenant="$2"
			shift 2
			;;
		*)
			if [[ -z "$key" ]]; then
				key="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$key" ]]; then
		print_error "Usage: credential-helper.sh remove <KEY_NAME> [--tenant <name>]"
		return 1
	fi

	if [[ -z "$tenant" ]]; then
		tenant=$(get_active_tenant)
	else
		validate_tenant_name "$tenant" || return 1
	fi

	local env_file
	env_file=$(get_tenant_env_file "$tenant")

	if [[ ! -f "$env_file" ]]; then
		print_error "Tenant '$tenant' not found"
		return 1
	fi

	local env_var
	if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
		env_var="$key"
	else
		env_var=$(echo "$key" | tr '[:lower:]-' '[:upper:]_')
	fi

	local action=""
	action=$(python3 "$CREDENTIAL_STORE_HELPER" remove \
		--config-dir "$CONFIG_DIR" --target "$env_file" --name "$env_var") || return 1
	if [[ "$action" == "removed" ]]; then
		print_success "Removed $env_var from tenant '$tenant'"
	else
		print_warning "Key $env_var not found in tenant '$tenant'"
	fi

	return 0
}

# Delete a tenant entirely
cmd_delete() {
	local tenant="$1"

	if [[ -z "$tenant" ]]; then
		print_error "Usage: credential-helper.sh delete <tenant-name>"
		return 1
	fi

	validate_tenant_name "$tenant" || return 1

	if [[ "$tenant" == "default" ]]; then
		print_error "Cannot delete the 'default' tenant"
		return 1
	fi

	local tenant_dir="$TENANTS_DIR/$tenant"
	if [[ ! -d "$tenant_dir" ]]; then
		print_error "Tenant '$tenant' does not exist"
		return 1
	fi

	# Check if this is the active tenant
	local active
	active=$(get_active_tenant)
	if [[ "$active" == "$tenant" ]]; then
		print_warning "Switching to 'default' tenant first"
		cmd_switch "default"
	fi

	rm -rf "$tenant_dir"
	print_success "Deleted tenant: $tenant"
	return 0
}

# Show keys in a tenant (names only, never values)
cmd_keys() {
	local tenant=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tenant | -t)
			tenant="$2"
			shift 2
			;;
		*)
			if [[ -z "$tenant" ]]; then
				tenant="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$tenant" ]]; then
		tenant=$(get_active_tenant)
	else
		validate_tenant_name "$tenant" || return 1
	fi

	migrate_legacy

	local env_file
	env_file=$(get_tenant_env_file "$tenant")

	if [[ ! -f "$env_file" ]]; then
		print_error "Tenant '$tenant' not found"
		return 1
	fi

	print_info "Keys in tenant '$tenant':"
	echo ""
	grep "^export " "$env_file" 2>/dev/null | sed 's/=.*//' | sed 's/export /  /' | sort
	echo ""
	return 0
}

# Copy keys between tenants
cmd_copy() {
	local source_tenant=""
	local dest_tenant=""
	local key_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--key | -k)
			key_filter="$2"
			shift 2
			;;
		*)
			if [[ -z "$source_tenant" ]]; then
				source_tenant="$1"
			elif [[ -z "$dest_tenant" ]]; then
				dest_tenant="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$source_tenant" || -z "$dest_tenant" ]]; then
		print_error "Usage: credential-helper.sh copy <source-tenant> <dest-tenant> [--key KEY_NAME]"
		return 1
	fi

	validate_tenant_name "$source_tenant" || return 1
	validate_tenant_name "$dest_tenant" || return 1

	local source_env
	source_env=$(get_tenant_env_file "$source_tenant")
	if [[ ! -f "$source_env" ]]; then
		print_error "Source tenant '$source_tenant' not found"
		return 1
	fi

	ensure_tenant_dir "$dest_tenant"
	local dest_env
	dest_env=$(get_tenant_env_file "$dest_tenant")

	local copied=0
	while IFS= read -r line; do
		if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)= ]]; then
			local var_name="${BASH_REMATCH[1]}"

			# Apply key filter if specified
			if [[ -n "$key_filter" && "$var_name" != "$key_filter" ]]; then
				continue
			fi

			# Skip if already exists in destination
			if grep -q "^export ${var_name}=" "$dest_env" 2>/dev/null; then
				print_warning "Skipping $var_name (already exists in '$dest_tenant')"
				continue
			fi

			echo "$line" >>"$dest_env"
			((++copied))
		fi
	done <"$source_env"

	# Enforce secure permissions after copy
	if [[ "$copied" -gt 0 ]]; then
		chmod 600 "$dest_env" 2>/dev/null || true
	fi

	print_success "Copied $copied key(s) from '$source_tenant' to '$dest_tenant'"
	return 0
}

# Set project-level tenant override
cmd_use() {
	local tenant="$1"

	if [[ -z "$tenant" ]]; then
		# Show current project tenant
		if [[ -f "$PROJECT_TENANT_FILE" ]]; then
			local current
			current=$(tr -d '[:space:]' <"$PROJECT_TENANT_FILE" 2>/dev/null)
			print_info "Project tenant: $current"
		else
			print_info "No project-level tenant set (using global: $(get_active_tenant))"
		fi
		return 0
	fi

	if [[ "$tenant" == "--clear" || "$tenant" == "--reset" ]]; then
		if [[ -f "$PROJECT_TENANT_FILE" ]]; then
			rm -f "$PROJECT_TENANT_FILE"
			print_success "Cleared project-level tenant override"
		else
			print_info "No project-level tenant to clear"
		fi
		return 0
	fi

	validate_tenant_name "$tenant" || return 1

	# Verify tenant exists
	local tenant_env
	tenant_env=$(get_tenant_env_file "$tenant")
	if [[ ! -f "$tenant_env" ]]; then
		print_error "Tenant '$tenant' does not exist. Create it first."
		return 1
	fi

	echo "$tenant" >"$PROJECT_TENANT_FILE"
	print_success "Set project tenant to: $tenant"
	print_info "This overrides the global active tenant for this directory"

	# Add to .gitignore if not already there
	if [[ -f ".gitignore" ]] && ! grep -q "^\.aidevops-tenant$" ".gitignore" 2>/dev/null; then
		# Ensure trailing newline before appending (prevents malformed entries)
		[[ -s ".gitignore" && $(tail -c1 ".gitignore" | wc -l) -eq 0 ]] && printf '\n' >>".gitignore"
		echo ".aidevops-tenant" >>".gitignore"
		print_info "Added .aidevops-tenant to .gitignore"
	fi

	return 0
}

# Show current status
cmd_status() {
	migrate_legacy

	local active
	active=$(get_active_tenant)
	local project_tenant=""

	if [[ -f "$PROJECT_TENANT_FILE" ]]; then
		project_tenant=$(tr -d '[:space:]' <"$PROJECT_TENANT_FILE" 2>/dev/null)
	fi

	echo ""
	print_info "Multi-Tenant Credential Status"
	echo "================================"
	echo ""
	echo -e "  Active tenant:  ${GREEN}$active${NC}"

	if [[ -n "$project_tenant" ]]; then
		echo -e "  Project tenant: ${BLUE}$project_tenant${NC} (overrides global)"
	fi

	local global_active=""
	if [[ -f "$ACTIVE_TENANT_FILE" ]]; then
		global_active=$(tr -d '[:space:]' <"$ACTIVE_TENANT_FILE" 2>/dev/null)
	fi
	if [[ -n "$global_active" && "$global_active" != "$active" ]]; then
		echo -e "  Global tenant:  ${DIM}$global_active${NC}"
	fi

	echo ""

	# List tenants with key counts
	if [[ -d "$TENANTS_DIR" ]]; then
		print_info "Tenants:"
		for tenant_dir in "$TENANTS_DIR"/*/; do
			if [[ ! -d "$tenant_dir" ]]; then
				continue
			fi
			local tenant_name
			tenant_name=$(basename "$tenant_dir")
			local env_file="$tenant_dir/credentials.sh"
			local key_count=0

			if [[ -f "$env_file" ]]; then
				key_count=$(safe_grep_count "^export " "$env_file")
			fi

			local marker=""
			if [[ "$tenant_name" == "$active" ]]; then
				marker=" ${GREEN}*${NC}"
			fi

			echo -e "  ${BLUE}$tenant_name${NC}${marker} ($key_count keys)"
		done
	else
		print_info "No tenants configured"
	fi

	echo ""
	echo -e "  ${DIM}Storage: $TENANTS_DIR${NC}"
	echo ""
	return 0
}

# Initialize multi-tenant system
cmd_init() {
	print_info "Initializing multi-tenant credential storage..."

	# Ensure base directories
	mkdir -p "$CONFIG_DIR"
	chmod 700 "$CONFIG_DIR"
	mkdir -p "$TENANTS_DIR"
	chmod 700 "$TENANTS_DIR"

	# Migrate legacy credentials
	migrate_legacy

	# Ensure default tenant exists
	ensure_tenant_dir "default"

	# Set default as active if no active tenant
	if [[ ! -f "$ACTIVE_TENANT_FILE" ]]; then
		echo "default" >"$ACTIVE_TENANT_FILE"
		chmod 600 "$ACTIVE_TENANT_FILE"
	fi

	# Update legacy file to source active tenant
	local active
	active=$(get_active_tenant)
	update_legacy_sourcing "$active"

	print_success "Multi-tenant credential storage initialized"
	cmd_status
	return 0
}

# Export active tenant's credentials to stdout
# Preferred usage: source <(credential-helper.sh export)
# Legacy usage:    eval "$(credential-helper.sh export)" (less safe)
cmd_export() {
	local tenant=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tenant | -t)
			tenant="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$tenant" ]]; then
		tenant=$(get_active_tenant)
	else
		validate_tenant_name "$tenant" || return 1
	fi

	local env_file
	env_file=$(get_tenant_env_file "$tenant")

	if [[ ! -f "$env_file" ]]; then
		print_error "Tenant '$tenant' not found" >&2
		return 1
	fi

	# Validate and output only well-formed export lines
	# Rejects lines that don't match strict "export VAR_NAME=..." pattern
	# to prevent command injection if the env file is tampered with
	while IFS= read -r line; do
		if [[ "$line" =~ ^export[[:space:]]+[A-Z_][A-Z0-9_]*= ]]; then
			echo "$line"
		fi
	done <"$env_file"
	echo "export AIDEVOPS_ACTIVE_TENANT=\"$tenant\""
	return 0
}

# Show help
cmd_help() {
	echo ""
	print_info "AI DevOps - Multi-Tenant Credential Storage"
	echo ""
	echo "  Manage multiple credential sets for different accounts, clients, or environments."
	echo ""
	print_info "Commands:"
	echo ""
	echo "  init                              Initialize multi-tenant storage"
	echo "  status                            Show current tenant status"
	echo "  create <tenant>                   Create a new tenant"
	echo "  switch <tenant>                   Switch active tenant globally"
	echo "  use [<tenant>|--clear]            Set/show project-level tenant"
	echo "  list                              List all tenants"
	echo "  keys [--tenant <name>]            Show keys in a tenant"
	echo ""
	echo "  set <KEY> <value> [--tenant <n>]  Set a key in a tenant"
	echo "  get <KEY> [--tenant <name>]       Get a key value"
	echo "  remove <KEY> [--tenant <name>]    Remove a key from a tenant"
	echo ""
	echo "  copy <src> <dest> [--key KEY]     Copy keys between tenants"
	echo "  delete <tenant>                   Delete a tenant (not 'default')"
	echo "  export [--tenant <name>]          Output exports (use with source)"
	echo ""
	print_info "Examples:"
	echo ""
	echo "  # Initialize (migrates existing credentials to 'default' tenant)"
	echo "  credential-helper.sh init"
	echo ""
	echo "  # Create tenants for different clients"
	echo "  credential-helper.sh create client-acme"
	echo "  credential-helper.sh create client-globex"
	echo ""
	echo "  # Add keys to a tenant"
	echo "  credential-helper.sh set GITHUB_TOKEN ghp_xxx --tenant client-acme"
	echo "  credential-helper.sh set VERCEL_TOKEN xxx --tenant client-acme"
	echo ""
	echo "  # Switch between tenants"
	echo "  credential-helper.sh switch client-acme"
	echo ""
	echo "  # Per-project tenant (overrides global)"
	echo "  cd ~/projects/acme-app" || exit
	echo "  credential-helper.sh use client-acme"
	echo ""
	echo "  # Copy shared keys to new tenant"
	echo "  credential-helper.sh copy default client-acme --key OPENAI_API_KEY"
	echo ""
	echo "  # Load tenant credentials in a script (preferred: source)"
	echo "  source <(credential-helper.sh export --tenant client-acme)"
	echo ""
	echo "  # Legacy alternative (less safe)"
	echo "  eval \"\$(credential-helper.sh export --tenant client-acme)\""
	echo ""
	return 0
}

# Main dispatch
main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	init) cmd_init "$@" ;;
	create) cmd_create "$@" ;;
	switch) cmd_switch "$@" ;;
	list) cmd_list "$@" ;;
	set) cmd_set "$@" ;;
	get) cmd_get "$@" ;;
	remove | rm) cmd_remove "$@" ;;
	delete) cmd_delete "$@" ;;
	keys) cmd_keys "$@" ;;
	copy | cp) cmd_copy "$@" ;;
	use) cmd_use "$@" ;;
	status) cmd_status "$@" ;;
	export) cmd_export "$@" ;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "$ERROR_UNKNOWN_COMMAND $command"
		echo ""
		cmd_help
		return 1
		;;
	esac

	return 0
}

main "$@"
