#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2155

# WordPress CLI Helper Script
# Runs WP-CLI commands on sites configured in wordpress-sites.json
# Supports multiple hosting types: LocalWP, Hostinger, Hetzner, Cloudways, Closte
# Supports per-tenant configs: ~/.config/aidevops/tenants/{tenant}/wordpress-sites.json
# Tenant resolution: project (.aidevops-tenant) > active-tenant > "default" > global

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# String literal constants
readonly ERROR_JQ_REQUIRED="jq is required but not installed"
readonly INFO_JQ_INSTALL_MACOS="Install with: brew install jq"
readonly INFO_JQ_INSTALL_UBUNTU="Install with: apt-get install jq"
readonly ERROR_SITE_NOT_FOUND="Site not found in configuration"
readonly ERROR_SITE_REQUIRED="Site identifier is required"
readonly ERROR_COMMAND_REQUIRED="WP-CLI command is required"

# Configuration paths
readonly WP_CONFIG_DIR="${HOME}/.config/aidevops"
readonly WP_TENANTS_DIR="${WP_CONFIG_DIR}/tenants"
readonly WP_ACTIVE_TENANT_FILE="${WP_CONFIG_DIR}/active-tenant"
readonly WP_PROJECT_TENANT_FILE=".aidevops-tenant"
readonly WP_GLOBAL_CONFIG="${WP_CONFIG_DIR}/wordpress-sites.json"
TEMPLATE_FILE="${HOME}/.aidevops/agents/configs/wordpress-sites.json.txt"

# Resolved config file (set by resolve_config_file)
CONFIG_FILE=""

# Get the active tenant name using the same priority chain as credential-helper.sh
# Priority: 1) Project override (.aidevops-tenant), 2) Global active-tenant, 3) "default"
get_wp_active_tenant() {
	if [[ -f "$WP_PROJECT_TENANT_FILE" ]]; then
		local project_tenant
		project_tenant=$(tr -d '[:space:]' <"$WP_PROJECT_TENANT_FILE" 2>/dev/null)
		if [[ -n "$project_tenant" ]]; then
			echo "$project_tenant"
			return 0
		fi
	fi

	if [[ -f "$WP_ACTIVE_TENANT_FILE" ]]; then
		local active
		active=$(tr -d '[:space:]' <"$WP_ACTIVE_TENANT_FILE" 2>/dev/null)
		if [[ -n "$active" ]]; then
			echo "$active"
			return 0
		fi
	fi

	echo "default"
	return 0
}

# Resolve the wordpress-sites.json config file path using tenant priority chain
# Sets CONFIG_FILE to the first existing config found:
#   1) ~/.config/aidevops/tenants/{tenant}/wordpress-sites.json
#   2) ~/.config/aidevops/wordpress-sites.json (global fallback)
resolve_config_file() {
	local tenant
	tenant=$(get_wp_active_tenant)

	local tenant_config="${WP_TENANTS_DIR}/${tenant}/wordpress-sites.json"
	if [[ -f "$tenant_config" ]]; then
		CONFIG_FILE="$tenant_config"
		return 0
	fi

	# Fallback to global config
	CONFIG_FILE="$WP_GLOBAL_CONFIG"
	return 0
}

# Resolve a server reference from the servers section of the config.
# Sites can use "server_ref": "my-server" to inherit shared server config.
# SSH config host aliases (~/.ssh/config Host entries) are also supported:
#   if ssh_host matches a Host entry in ~/.ssh/config, connection params are
#   inherited from there (user, port, identity file) unless overridden in the site.
#
# Usage: resolve_server_ref <site_config_json>
# Returns: merged JSON with server fields applied (ssh_host, ssh_port, ssh_user, wp_path)
resolve_server_ref() {
	local site_config="$1"

	local server_ref
	server_ref=$(echo "$site_config" | jq -r '.server_ref // empty')

	if [[ -z "$server_ref" ]]; then
		echo "$site_config"
		return 0
	fi

	# Look up server definition in config file
	local server_def
	server_def=$(jq -r --arg ref "$server_ref" '.servers[$ref] // empty' "$CONFIG_FILE" 2>/dev/null)

	if [[ -z "$server_def" ]]; then
		# >&2 is required: resolve_server_ref() is called via $() in execute_wp_via_ssh().
		# Without >&2, the warning text is captured into the substitution, prepended to the
		# JSON output, and causes downstream jq parse errors (stdout pollution bug).
		print_warning "server_ref '$server_ref' not found in servers section — using site config as-is" >&2
		echo "$site_config"
		return 0
	fi

	# Merge: server_def provides defaults, site_config fields override
	# Site-level fields take precedence over server-level fields
	local merged
	merged=$(echo "$server_def $site_config" | jq -s '.[0] * .[1]')

	# SSH config host integration: if ssh_host matches a Host alias in ~/.ssh/config,
	# extract HostName, User, Port, IdentityFile from it as additional defaults.
	# Site and server fields still take precedence over SSH config values.
	local ssh_host
	ssh_host=$(echo "$merged" | jq -r '.ssh_host // empty')

	if [[ -n "$ssh_host" ]] && command -v ssh &>/dev/null; then
		local ssh_hostname ssh_user ssh_port ssh_identity
		ssh_hostname=$(ssh -G "$ssh_host" 2>/dev/null | awk '/^hostname / {print $2; exit}')
		ssh_user=$(ssh -G "$ssh_host" 2>/dev/null | awk '/^user / {print $2; exit}')
		ssh_port=$(ssh -G "$ssh_host" 2>/dev/null | awk '/^port / {print $2; exit}')
		ssh_identity=$(ssh -G "$ssh_host" 2>/dev/null | awk '/^identityfile / {print $2; exit}')

		# Build SSH config defaults object (only non-empty values)
		local ssh_defaults="{}"
		[[ -n "$ssh_hostname" && "$ssh_hostname" != "$ssh_host" ]] &&
			ssh_defaults=$(echo "$ssh_defaults" | jq --arg v "$ssh_hostname" '. + {ssh_resolved_host: $v}')
		[[ -n "$ssh_user" ]] &&
			ssh_defaults=$(echo "$ssh_defaults" | jq --arg v "$ssh_user" '. + {_ssh_config_user: $v}')
		[[ -n "$ssh_port" && "$ssh_port" != "22" ]] &&
			ssh_defaults=$(echo "$ssh_defaults" | jq --arg v "$ssh_port" '. + {_ssh_config_port: $v}')
		[[ -n "$ssh_identity" ]] &&
			ssh_defaults=$(echo "$ssh_defaults" | jq --arg v "$ssh_identity" '. + {ssh_identity_file: $v}')

		# Apply SSH config defaults only where site/server didn't already set values
		# ssh_user: use SSH config user if not set in site or server
		local current_user
		current_user=$(echo "$merged" | jq -r '.ssh_user // empty')
		if [[ -z "$current_user" ]]; then
			local cfg_user
			cfg_user=$(echo "$ssh_defaults" | jq -r '._ssh_config_user // empty')
			[[ -n "$cfg_user" ]] && merged=$(echo "$merged" | jq --arg v "$cfg_user" '.ssh_user = $v')
		fi

		# ssh_port: use SSH config port if not set in site or server
		local current_port
		current_port=$(echo "$merged" | jq -r '.ssh_port // empty')
		if [[ -z "$current_port" ]]; then
			local cfg_port
			cfg_port=$(echo "$ssh_defaults" | jq -r '._ssh_config_port // empty')
			[[ -n "$cfg_port" ]] && merged=$(echo "$merged" | jq --arg v "$cfg_port" '.ssh_port = ($v | tonumber)')
		fi

		# ssh_identity_file: apply if SSH config provides one and site doesn't override
		local current_identity
		current_identity=$(echo "$merged" | jq -r '.ssh_identity_file // empty')
		if [[ -z "$current_identity" ]]; then
			local cfg_identity
			cfg_identity=$(echo "$ssh_defaults" | jq -r '.ssh_identity_file // empty')
			local expanded_cfg_identity="${cfg_identity/#\~/$HOME}"
			[[ -n "$cfg_identity" && -f "$expanded_cfg_identity" ]] &&
				merged=$(echo "$merged" | jq --arg v "$cfg_identity" '.ssh_identity_file = $v')
		fi
	fi

	echo "$merged"
	return 0
}

# Check dependencies
check_dependencies() {
	if ! command -v jq &>/dev/null; then
		print_error "$ERROR_JQ_REQUIRED"
		echo "$INFO_JQ_INSTALL_MACOS"
		echo "$INFO_JQ_INSTALL_UBUNTU"
		exit 1
	fi

	if ! command -v ssh &>/dev/null; then
		print_error "ssh is required but not installed"
		exit 1
	fi
	return 0
}

# Check sshpass for password-based SSH (called only when needed)
check_sshpass() {
	if ! command -v sshpass &>/dev/null; then
		print_error "sshpass is required for Hostinger/Closte sites but not installed"
		print_info "Install with: brew install hudochenkov/sshpass/sshpass (macOS)"
		print_info "Install with: apt-get install sshpass (Ubuntu)"
		exit 1
	fi
	return 0
}

# Load configuration — resolves tenant-aware config path on first call
load_config() {
	# Resolve config file path if not already done
	if [[ -z "$CONFIG_FILE" ]]; then
		resolve_config_file
	fi

	if [[ ! -f "$CONFIG_FILE" ]]; then
		local tenant
		tenant=$(get_wp_active_tenant)
		print_error "$ERROR_CONFIG_NOT_FOUND: $CONFIG_FILE"
		if [[ "$tenant" != "default" ]]; then
			print_info "Tenant '$tenant' has no wordpress-sites.json. Create one at:"
			print_info "  mkdir -p ${WP_TENANTS_DIR}/${tenant}"
			print_info "  cp $TEMPLATE_FILE ${WP_TENANTS_DIR}/${tenant}/wordpress-sites.json"
		else
			print_info "Copy and customize the template:"
			print_info "  mkdir -p ${WP_CONFIG_DIR}"
			print_info "  cp $TEMPLATE_FILE ${WP_GLOBAL_CONFIG}"
		fi
		exit 1
	fi
	return 0
}

# Get site configuration
get_site_config() {
	local site_key="$1"

	load_config

	local site_config
	site_config=$(jq -r --arg key "$site_key" '.sites[$key]' "$CONFIG_FILE")
	if [[ "$site_config" == "null" ]]; then
		print_error "$ERROR_SITE_NOT_FOUND: $site_key"
		list_sites
		exit 1
	fi

	echo "$site_config"
	return 0
}

# List all configured sites
list_sites() {
	load_config
	print_info "Configured WordPress sites:"
	echo ""
	jq -r '.sites | to_entries[] | "\(.key)|\(.value.name)|\(.value.type)|\(.value.url // .value.path)|\(.value.category // "uncategorized")"' "$CONFIG_FILE" |
		while IFS='|' read -r key name type url category; do
			printf "  %-20s %-25s %-12s %-40s [%s]\n" "$key" "$name" "$type" "$url" "$category"
		done
	return 0
}

# List sites by category
list_sites_by_category() {
	local category="$1"

	load_config
	print_info "Sites in category: $category"
	echo ""
	jq -r --arg cat "$category" '.sites | to_entries[] | select(.value.category == $cat) | "\(.key)|\(.value.name)|\(.value.type)|\(.value.url // .value.path)"' "$CONFIG_FILE" |
		while IFS='|' read -r key name type url; do
			printf "  %-20s %-25s %-12s %s\n" "$key" "$name" "$type" "$url"
		done
	return 0
}

# Execute WP-CLI command via SSH based on hosting type
# Directly executes instead of building a string for eval
# Applies server_ref resolution and SSH config host integration before connecting
execute_wp_via_ssh() {
	local site_config="$1"
	shift
	local -a wp_args=("$@")

	# Resolve server_ref and SSH config host aliases
	site_config=$(resolve_server_ref "$site_config")

	local site_type
	site_type=$(echo "$site_config" | jq -r '.type')
	local ssh_host
	ssh_host=$(echo "$site_config" | jq -r '.ssh_host // empty')
	local ssh_port
	ssh_port=$(echo "$site_config" | jq -r '.ssh_port // 22')
	local ssh_user
	ssh_user=$(echo "$site_config" | jq -r '.ssh_user // empty')
	local wp_path
	wp_path=$(echo "$site_config" | jq -r '.wp_path // empty')
	local local_path
	local_path=$(echo "$site_config" | jq -r '.path // empty')
	local password_file
	password_file=$(echo "$site_config" | jq -r '.password_file // empty')
	local ssh_password_env
	ssh_password_env=$(echo "$site_config" | jq -r '.ssh_password_env // empty')
	local ssh_identity_file
	ssh_identity_file=$(echo "$site_config" | jq -r '.ssh_identity_file // empty')

	# Build optional SSH identity flag
	local ssh_identity_flag=()
	if [[ -n "$ssh_identity_file" ]]; then
		local expanded_identity="${ssh_identity_file/#\~/$HOME}"
		ssh_identity_flag=(-i "$expanded_identity")
	fi

	# Build remote command as a single printf-escaped string.
	# SSH concatenates multiple args with spaces, destroying bash -c positional
	# parameter boundaries. printf %q escapes each arg, preventing both
	# injection and argument-boundary loss. (GH#5197)
	# Built once here and shared by all SSH-based branches below.
	local remote_cmd
	remote_cmd="cd $(printf '%q' "$wp_path") && wp"
	remote_cmd+=" $(printf '%q ' "${wp_args[@]}")"
	remote_cmd="${remote_cmd% }"

	case "$site_type" in
	localwp)
		# LocalWP - direct local access
		local expanded_path="${local_path/#\~/$HOME}"
		(cd "$expanded_path" && wp "${wp_args[@]}")
		return $?
		;;
	hostinger | closte)
		# Prefer SSH key auth if configured (Hostinger supports and recommends it)
		if [[ -n "$ssh_identity_file" ]]; then
			ssh -n "${ssh_identity_flag[@]}" -p "$ssh_port" "${ssh_user}@${ssh_host}" "$remote_cmd"
			return $?
		fi
		if [[ -n "$ssh_password_env" ]]; then
			execute_ssh_with_password_env "$ssh_password_env" "$ssh_port" "${ssh_user}@${ssh_host}" "$remote_cmd"
			return $?
		fi
		check_sshpass
		local expanded_password_file
		if [[ -n "$password_file" ]]; then
			expanded_password_file="${password_file/#\~/$HOME}"
		else
			if [[ "$site_type" == "hostinger" ]]; then
				expanded_password_file="${HOME}/.ssh/hostinger_password"
			else
				expanded_password_file="${HOME}/.ssh/closte_password"
			fi
		fi

		if [[ ! -f "$expanded_password_file" ]]; then
			print_error "Password file not found: $expanded_password_file"
			print_info "Create the password file with your SSH password (chmod 600)"
			return 1
		fi

		# Warn if password file has insecure permissions (should be 600)
		local file_perms
		file_perms=$(_file_perms "$expanded_password_file")
		if [[ -n "$file_perms" && "$file_perms" != "600" ]]; then
			print_warning "Password file has insecure permissions ($file_perms): $expanded_password_file"
			print_info "Fix with: chmod 600 $expanded_password_file"
		fi

		sshpass -f "$expanded_password_file" ssh -n -p "$ssh_port" "${ssh_user}@${ssh_host}" "$remote_cmd"
		return $?
		;;
	hetzner | cloudways | cloudron)
		# SSH key-based authentication (preferred, -n prevents stdin consumption in loops)
		ssh -n "${ssh_identity_flag[@]}" -p "$ssh_port" "${ssh_user}@${ssh_host}" "$remote_cmd"
		return $?
		;;
	*)
		print_error "Unknown hosting type: $site_type"
		return 1
		;;
	esac
}

# Execute SSH with a password injected through a named environment variable.
execute_ssh_with_password_env() {
	local password_env="$1"
	local ssh_port="$2"
	local ssh_target="$3"
	local remote_cmd="$4"

	if [[ ! "$password_env" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
		print_error "Invalid ssh_password_env name: $password_env"
		return 1
	fi
	if [[ -z "${!password_env:-}" ]]; then
		print_error "SSH password environment variable is not set: $password_env"
		print_info "Run with: aidevops secret $password_env -- wp-helper.sh ..."
		return 1
	fi

	check_sshpass
	SSHPASS="${!password_env}" sshpass -e ssh -n -p "$ssh_port" "$ssh_target" "$remote_cmd"
	return $?
}

# Run WP-CLI command on a site
run_wp_command() {
	local site_key="$1"
	shift
	local -a wp_args=("$@")

	if [[ ${#wp_args[@]} -eq 0 ]]; then
		print_error "$ERROR_COMMAND_REQUIRED"
		exit 1
	fi

	# load_config must be called before get_site_config() to ensure CONFIG_FILE is set
	# in the current shell. get_site_config() runs in a subshell via $(); any CONFIG_FILE
	# assignment inside that subshell is lost when it exits, leaving CONFIG_FILE empty
	# for the subsequent execute_wp_via_ssh() → resolve_server_ref() call.
	load_config

	local site_config
	site_config=$(get_site_config "$site_key")

	local site_name
	site_name=$(echo "$site_config" | jq -r '.name')
	local site_type
	site_type=$(echo "$site_config" | jq -r '.type')

	local args_str
	printf -v args_str '%q ' "${wp_args[@]}"
	print_info "Running on $site_name ($site_type): wp ${args_str% }" >&2

	# Execute directly without eval
	execute_wp_via_ssh "$site_config" "${wp_args[@]}"
	return $?
}

# Run WP-CLI command on all sites in a category
run_on_category() {
	local category="$1"
	shift
	local -a wp_args=("$@")

	if [[ ${#wp_args[@]} -eq 0 ]]; then
		print_error "$ERROR_COMMAND_REQUIRED"
		exit 1
	fi

	load_config

	print_info "Running on all sites in category: $category"
	local args_str
	printf -v args_str '%q ' "${wp_args[@]}"
	print_info "Command: wp ${args_str% }"
	echo ""

	local site_keys
	site_keys=$(jq -r --arg cat "$category" '.sites | to_entries[] | select(.value.category == $cat) | .key' "$CONFIG_FILE")

	if [[ -z "$site_keys" ]]; then
		print_warning "No sites found in category: $category"
		return 0
	fi

	local success_count=0
	local fail_count=0

	while IFS= read -r site_key; do
		echo "----------------------------------------"
		print_info "Site: $site_key"
		if run_wp_command "$site_key" "${wp_args[@]}"; then
			((++success_count))
		else
			((++fail_count))
			print_error "Failed on site: $site_key"
		fi
		echo ""
	done <<<"$site_keys"

	echo "========================================"
	print_info "Summary: $success_count succeeded, $fail_count failed"
	return 0
}

# Run WP-CLI command on all sites
run_on_all() {
	local -a wp_args=("$@")

	if [[ ${#wp_args[@]} -eq 0 ]]; then
		print_error "$ERROR_COMMAND_REQUIRED"
		exit 1
	fi

	load_config

	print_info "Running on ALL sites"
	local args_str
	printf -v args_str '%q ' "${wp_args[@]}"
	print_info "Command: wp ${args_str% }"
	echo ""

	local site_keys
	site_keys=$(jq -r '.sites | keys[]' "$CONFIG_FILE")

	local success_count=0
	local fail_count=0

	while IFS= read -r site_key; do
		echo "----------------------------------------"
		print_info "Site: $site_key"
		if run_wp_command "$site_key" "${wp_args[@]}"; then
			((++success_count))
		else
			((++fail_count))
			print_error "Failed on site: $site_key"
		fi
		echo ""
	done <<<"$site_keys"

	echo "========================================"
	print_info "Summary: $success_count succeeded, $fail_count failed"
	return 0
}

# Get site info
get_site_info() {
	local site_key="$1"

	local site_config
	site_config=$(get_site_config "$site_key")

	print_info "Site: $site_key"
	echo "$site_config" | jq '.'
	return 0
}

# List available categories
list_categories() {
	load_config
	print_info "Available categories:"
	jq -r '.sites[].category // "uncategorized"' "$CONFIG_FILE" | sort -u | while read -r cat; do
		local count
		if [[ "$cat" == "uncategorized" ]]; then
			# Count sites with null/missing category
			count=$(jq -r '[.sites[] | select(.category == null or .category == "")] | length' "$CONFIG_FILE")
		else
			count=$(jq -r --arg c "$cat" '[.sites[] | select(.category == $c)] | length' "$CONFIG_FILE")
		fi
		echo "  - $cat ($count sites)"
	done
	return 0
}

# Show active config file and tenant resolution
show_config() {
	local tenant
	tenant=$(get_wp_active_tenant)
	# Only resolve if not already set (e.g. by --tenant flag)
	local tenant_overridden=false
	if [[ -z "$CONFIG_FILE" ]]; then
		resolve_config_file
	else
		tenant_overridden=true
	fi

	if [[ "$tenant_overridden" == "true" ]]; then
		print_info "Active tenant: $tenant (config overridden via --tenant)"
	else
		print_info "Active tenant: $tenant"
	fi
	print_info "Config file:   $CONFIG_FILE"

	if [[ -f "$CONFIG_FILE" ]]; then
		local site_count server_count
		site_count=$(jq -r '.sites | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
		server_count=$(jq -r 'if .servers then (.servers | to_entries | map(select(.key | startswith("_") | not)) | length) else 0 end' "$CONFIG_FILE" 2>/dev/null || echo "0")
		print_info "Sites:         $site_count"
		print_info "Servers:       $server_count"
	else
		print_warning "Config file not found"
	fi

	# Show tenant resolution chain
	echo ""
	print_info "Tenant resolution chain:"
	if [[ -f "$WP_PROJECT_TENANT_FILE" ]]; then
		echo "  [active] .aidevops-tenant = $(tr -d '[:space:]' <"$WP_PROJECT_TENANT_FILE")"
	else
		echo "  [skip]   .aidevops-tenant (not found)"
	fi
	if [[ -f "$WP_ACTIVE_TENANT_FILE" ]]; then
		echo "  [found]  active-tenant = $(tr -d '[:space:]' <"$WP_ACTIVE_TENANT_FILE")"
	else
		echo "  [skip]   active-tenant (not set)"
	fi
	echo "  [default] 'default'"
	return 0
}

# Print the commands, options, and examples section of the help text
_show_help_commands() {
	cat <<'EOF'
WordPress CLI Helper Script

Runs WP-CLI commands on sites configured in wordpress-sites.json
Supports per-tenant configs with shared server definitions and SSH config integration.

Usage: wp-helper.sh [command] [options]

Commands:
  --list                              List all configured sites
  --list-category <category>          List sites in a category
  --categories                        List available categories
  --info <site>                       Show site configuration
  --config                            Show active config file and tenant
  --all <wp-cli-command>              Run command on ALL sites
  --category <cat> <wp-cli-command>   Run command on sites in category
  <site> <wp-cli-command>             Run command on specific site
  help                                Show this help

Global Options (must come before command):
  --tenant <name>                     Override active tenant for this invocation

Examples:
  # List all sites
  wp-helper.sh --list

  # List sites by category
  wp-helper.sh --list-category client

  # Show site info
  wp-helper.sh --info production

  # Run WP-CLI on specific site
  wp-helper.sh production plugin list
  wp-helper.sh local-dev core version
  wp-helper.sh staging user list --role=administrator

  # Run on all sites in a category
  wp-helper.sh --category client plugin update --all
  wp-helper.sh --category lead-gen core version

  # Run on ALL sites
  wp-helper.sh --all core version
  wp-helper.sh --all plugin list --status=active
EOF
	return 0
}

# Print the configuration, setup, and hosting-type reference section of the help text
_show_help_config() {
	cat <<'EOF'
Configuration (tenant-aware, resolved in priority order):
  1. ~/.config/aidevops/tenants/{tenant}/wordpress-sites.json  (per-tenant)
  2. ~/.config/aidevops/wordpress-sites.json                   (global fallback)

  Active tenant is resolved from (same chain as credential-helper.sh):
    1. .aidevops-tenant  (project-level override)
    2. ~/.config/aidevops/active-tenant  (global active)
    3. "default"

  Template: ~/.aidevops/agents/configs/wordpress-sites.json.txt

Setup (global):
  mkdir -p ~/.config/aidevops
  cp ~/.aidevops/agents/configs/wordpress-sites.json.txt ~/.config/aidevops/wordpress-sites.json

Setup (per-tenant, e.g. "acme"):
  mkdir -p ~/.config/aidevops/tenants/acme
  cp ~/.aidevops/agents/configs/wordpress-sites.json.txt \
     ~/.config/aidevops/tenants/acme/wordpress-sites.json

Server References (DRY server config):
  Define shared server infrastructure in the "servers" section and reference
	  it from sites using "server_ref". One server/account credential can therefore
	  serve every site under that account. Site-level fields override server defaults.

  "servers": {
    "hostinger-account-1": {
      "type": "hostinger",
      "ssh_host": "ssh.example.com",
      "ssh_user": "u123456789",
      "ssh_port": 65002,
      "ssh_password_env": "HOSTINGER_SSH_PASSWORD_ACCOUNT_1"
    }
  },
  "sites": {
    "my-site": {
      "server_ref": "hostinger-account-1",
      "wp_path": "/domains/example.com/public_html"
    }
  }

  Store only the shared password as a secret, then inject it when running:
    aidevops secret set HOSTINGER_SSH_PASSWORD_ACCOUNT_1
    aidevops secret HOSTINGER_SSH_PASSWORD_ACCOUNT_1 -- wp-helper.sh my-site core version

SSH Config Integration:
  If ssh_host matches a Host alias in ~/.ssh/config, connection parameters
  (User, Port, IdentityFile) are inherited automatically. Site and server
  fields take precedence over SSH config values.

  Example ~/.ssh/config:
    Host my-vps
      HostName 123.45.67.89
      User root
      IdentityFile ~/.ssh/my-vps-key

  Then in wordpress-sites.json:
    "my-site": { "ssh_host": "my-vps", "wp_path": "/var/www/html" }

Hosting Types:
  localwp   - Local by Flywheel (direct path access)
  hostinger - Hostinger (sshpass, port 65002)
  closte    - Closte (sshpass)
  hetzner   - Hetzner VPS (SSH key)
  cloudways - Cloudways (SSH key)
  cloudron  - Cloudron (SSH key)

Related:
  mainwp-helper.sh - For MainWP fleet management
  wordpress-mcp-helper.sh - For WordPress MCP adapter
  credential-helper.sh - For tenant management
EOF
	return 0
}

# Show help
show_help() {
	_show_help_commands
	_show_help_config
	return 0
}

# Main script logic
main() {
	# Handle --tenant flag before command dispatch (sets CONFIG_FILE override)
	if [[ "${1:-}" == "--tenant" ]]; then
		if [[ -z "${2:-}" ]]; then
			print_error "--tenant requires a tenant name"
			exit 1
		fi
		local tenant_override="$2"
		CONFIG_FILE="${WP_TENANTS_DIR}/${tenant_override}/wordpress-sites.json"
		shift 2
	fi

	local command="${1:-help}"

	check_dependencies

	case "$command" in
	--config)
		show_config
		;;
	--list)
		list_sites
		;;
	--list-category)
		local category="${2:-}"
		if [[ -z "$category" ]]; then
			print_error "Category is required"
			exit 1
		fi
		list_sites_by_category "$category"
		;;
	--categories)
		list_categories
		;;
	--info)
		local site="${2:-}"
		if [[ -z "$site" ]]; then
			print_error "$ERROR_SITE_REQUIRED"
			exit 1
		fi
		get_site_info "$site"
		;;
	--all)
		shift
		run_on_all "$@"
		;;
	--category)
		local category="${2:-}"
		if [[ -z "$category" ]]; then
			print_error "Category is required"
			exit 1
		fi
		shift 2
		run_on_category "$category" "$@"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		# Assume first arg is site key, rest is WP-CLI command
		local site_key="$1"
		shift
		if [[ $# -eq 0 ]]; then
			print_error "$ERROR_COMMAND_REQUIRED"
			print_info "Usage: wp-helper.sh <site> <wp-cli-command>"
			exit 1
		fi
		run_wp_command "$site_key" "$@"
		;;
	esac
	return 0
}

main "$@"
