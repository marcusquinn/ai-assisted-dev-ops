#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091
# wordpress-plugin.sh — FOSS contribution handler: WordPress plugins (t1696)
#
# Implements the foss-contribution-helper.sh handler interface: WordPress plugins.
# Sets up wp-env with multisite, integrates with localdev to provide HTTPS review URLs,
# runs PHPUnit + Playwright smoke tests, and cleans up all resources.
#
# Handler interface (required by foss-contribution-helper.sh):
#   setup   <github-slug> [worktree-path]   Fork, clone, wp-env start, localdev register
#   build   <plugin-dir>                    Activate plugin, install composer/npm deps
#   test    <plugin-dir>                    PHPUnit (available) + Playwright smoke tests
#   review  <plugin-dir> [branch-name]      Print review URLs (current + branch)
#   cleanup <plugin-dir>                    wp-env destroy, localdev rm, port deregistration
#
# Usage:
#   wordpress-plugin.sh setup afragen/git-updater
#   wordpress-plugin.sh setup afragen/git-updater ~/Git/wordpress/git-updater-fix
#   wordpress-plugin.sh build ~/Git/wordpress/git-updater
#   wordpress-plugin.sh test ~/Git/wordpress/git-updater
#   wordpress-plugin.sh review ~/Git/wordpress/git-updater bugfix-xyz
#   wordpress-plugin.sh cleanup ~/Git/wordpress/git-updater
#
# Prerequisites:
#   - Docker (required by wp-env)
#   - Node.js >= 18 + npm (required by @wordpress/env)
#   - localdev-helper.sh (required by HTTPS .local domains)
#   - mkcert (installed by localdev-helper.sh init)
#   - Optional: composer (PHP deps), playwright (E2E smoke tests)
#
# State file: ~/.aidevops/cache/foss-wp-handler.json
# Smoke test template: foss-handlers/wp-plugin-smoke-test.spec.js
#
# Security note: composer and npm installs run with --no-scripts/--ignore-scripts
# by default to prevent untrusted plugin lifecycle scripts from executing.
# Set ALLOW_PLUGIN_SCRIPTS=1 to opt in to running plugin scripts.
#
# Fix t1700: three post-setup issues corrected in this version:
#   1. Proxy headers — mu-plugin installed to trust X-Forwarded-* from wp-env proxy,
#      preventing WordPress from redirecting HTTPS requests back to http://localhost.
#   2. URL + multisite domain tables — after multisite conversion, siteurl/home options
#      and wp_blogs.domain are updated to <slug>.local so admin links resolve correctly.
#   3. Credential output — admin username and password printed at end of setup.

set -euo pipefail

# PATH normalisation: launchd/MCP environments
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../shared-constants.sh
source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours when shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Fallback print helpers when shared-constants.sh not loaded
_define_print_helpers() {
	print_info() {
		printf "${BLUE}[INFO]${NC} %s\n" "$1"
		return 0
	}
	print_success() {
		printf "${GREEN}[OK]${NC} %s\n" "$1"
		return 0
	}
	print_error() {
		printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
		return 0
	}
	print_warning() {
		printf "${YELLOW}[WARN]${NC} %s\n" "$1"
		return 0
	}
}
command -v print_info >/dev/null 2>&1 || _define_print_helpers

# =============================================================================
# Configuration
# =============================================================================

readonly WP_HANDLER_STATE="${HOME}/.aidevops/cache/foss-wp-handler.json"
readonly WP_CLONE_BASE="${HOME}/Git/wordpress"
readonly LOCALDEV_HELPER="${AGENTS_SCRIPTS_DIR}/localdev-helper.sh"
readonly SMOKE_TEST_TEMPLATE="${SCRIPT_DIR}/wp-plugin-smoke-test.spec.js"

# wp-env port range (separate from localdev 3100-3999 range)
readonly WP_ENV_PORT_START=8880
readonly WP_ENV_PORT_END=8999

# Multisite wp-env config constants
readonly WP_MULTISITE_DOMAIN="localhost"
readonly WP_DEBUG_CONFIG='{"WP_DEBUG":true,"WP_DEBUG_LOG":true,"WP_DEBUG_DISPLAY":false,"SCRIPT_DEBUG":true}'

# Handler-owned wp-env config filename (avoids overwriting repo's .wp-env.json)
readonly WP_ENV_CONFIG_FILE=".wp-env.aidevops.json"

# =============================================================================
# Utility helpers
# =============================================================================

# Derive a safe slug from a GitHub slug (owner/repo -> repo)
plugin_slug_from_github() {
	local github_slug="${1:-}"
	echo "${github_slug##*/}" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
	return 0
}

# Derive the clone directory from a plugin slug
plugin_dir_from_slug() {
	local slug="${1:-}"
	echo "${WP_CLONE_BASE}/${slug}"
	return 0
}

# Read a value from the state JSON file
state_get() {
	local key="${1:-}"
	if [[ ! -f "$WP_HANDLER_STATE" ]]; then
		echo ""
		return 0
	fi
	jq -r --arg k "$key" '.[$k] // empty' "$WP_HANDLER_STATE" 2>/dev/null || echo ""
	return 0
}

# Write a key=value pair to the state JSON file
state_set() {
	local key="${1:-}"
	local value="${2:-}"
	local tmp
	tmp="$(mktemp)"
	if [[ -f "$WP_HANDLER_STATE" ]]; then
		jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$WP_HANDLER_STATE" >"$tmp"
	else
		mkdir -p "$(dirname "$WP_HANDLER_STATE")"
		jq -n --arg k "$key" --arg v "$value" '{($k): $v}' >"$tmp"
	fi
	mv "$tmp" "$WP_HANDLER_STATE"
	return 0
}

# Remove a key from the state JSON file
state_del() {
	local key="${1:-}"
	if [[ ! -f "$WP_HANDLER_STATE" ]]; then
		return 0
	fi
	local tmp
	tmp="$(mktemp)"
	jq --arg k "$key" 'del(.[$k])' "$WP_HANDLER_STATE" >"$tmp"
	mv "$tmp" "$WP_HANDLER_STATE"
	return 0
}

# Check that a command exists; print error + optional install hint on failure
require_cmd() {
	local cmd="${1:-}"
	local install_hint="${2:-}"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		print_error "Required command not found: $cmd"
		[[ -n "$install_hint" ]] && print_info "Install: $install_hint"
		return 1
	fi
	return 0
}

# Find an available port in the wp-env range
find_available_wp_env_port() {
	local port="$WP_ENV_PORT_START"
	while [[ "$port" -le "$WP_ENV_PORT_END" ]]; do
		if ! lsof -i ":${port}" >/dev/null 2>&1; then
			echo "$port"
			return 0
		fi
		port=$((port + 1))
	done
	print_error "No available port in range ${WP_ENV_PORT_START}-${WP_ENV_PORT_END}"
	return 1
}

# =============================================================================
# wp-env.json generation
# =============================================================================

# Generate .wp-env.aidevops.json with multisite config — writes into the plugin directory.
# Uses a handler-owned filename to avoid overwriting any repo-owned .wp-env.json.
generate_wp_env_json() {
	local plugin_dir="${1:-}"
	local wp_port="${2:-8888}"
	local slug
	slug="$(basename "$plugin_dir")"
	local domain="${slug}.local"

	print_info "Generating ${WP_ENV_CONFIG_FILE}: ${slug} (port ${wp_port}, multisite)"

	local multisite_config
	multisite_config=$(jq -n \
		--argjson debug "$WP_DEBUG_CONFIG" \
		--arg domain "$domain" \
		--arg port "$wp_port" \
		'{
			"WP_DEBUG": $debug.WP_DEBUG,
			"WP_DEBUG_LOG": $debug.WP_DEBUG_LOG,
			"WP_DEBUG_DISPLAY": $debug.WP_DEBUG_DISPLAY,
			"SCRIPT_DEBUG": $debug.SCRIPT_DEBUG,
			"WP_ALLOW_MULTISITE": true,
			"MULTISITE": true,
			"SUBDOMAIN_INSTALL": false,
			"DOMAIN_CURRENT_SITE": $domain,
			"PATH_CURRENT_SITE": "/",
			"SITE_ID_CURRENT_SITE": 1,
			"BLOG_ID_CURRENT_SITE": 1,
			"WP_HOME": ("https://" + $domain),
			"WP_SITEURL": ("https://" + $domain)
		}')

	jq -n \
		--arg plugin "." \
		--argjson config "$multisite_config" \
		--argjson port "$wp_port" \
		'{
			"core": "WordPress/WordPress",
			"phpVersion": "8.1",
			"plugins": [$plugin, "https://downloads.wordpress.org/plugin/query-monitor.latest-stable.zip"],
			"config": $config,
			"port": $port,
			"testsPort": ($port + 1)
		}' >"${plugin_dir}/${WP_ENV_CONFIG_FILE}"

	print_success "${WP_ENV_CONFIG_FILE} written to ${plugin_dir}/${WP_ENV_CONFIG_FILE}"
	return 0
}

# =============================================================================
# Build sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Install Composer dependencies when composer.json is present.
# Uses --no-scripts by default to prevent untrusted lifecycle scripts.
# Set ALLOW_PLUGIN_SCRIPTS=1 to opt in.
_install_composer_deps() {
	local plugin_dir="${1:-}"
	if [[ ! -f "${plugin_dir}/composer.json" ]]; then
		return 0
	fi
	if ! command -v composer >/dev/null 2>&1; then
		print_warning "composer not found — skipping PHP dependency install"
		print_info "Install: brew install composer"
		return 0
	fi
	local no_scripts_flag="--no-scripts"
	if [[ "${ALLOW_PLUGIN_SCRIPTS:-0}" == "1" ]]; then
		no_scripts_flag=""
		print_warning "ALLOW_PLUGIN_SCRIPTS=1: running composer lifecycle scripts from plugin"
	fi
	print_info "Installing Composer dependencies (${no_scripts_flag:-scripts enabled})..."
	# shellcheck disable=SC2086
	if composer install --no-interaction --prefer-dist --working-dir="$plugin_dir" ${no_scripts_flag} 2>&1; then
		print_success "Composer install complete"
	else
		print_warning "Composer install failed — continuing without PHP deps"
	fi
	return 0
}

# Install npm dependencies when package.json is present.
# Uses --ignore-scripts by default to prevent untrusted lifecycle scripts.
# Set ALLOW_PLUGIN_SCRIPTS=1 to opt in.
_install_npm_deps() {
	local plugin_dir="${1:-}"
	if [[ ! -f "${plugin_dir}/package.json" ]]; then
		return 0
	fi
	if ! command -v npm >/dev/null 2>&1; then
		return 0
	fi
	local ignore_scripts_flag="--ignore-scripts"
	if [[ "${ALLOW_PLUGIN_SCRIPTS:-0}" == "1" ]]; then
		ignore_scripts_flag=""
		print_warning "ALLOW_PLUGIN_SCRIPTS=1: running npm lifecycle scripts from plugin"
	fi
	print_info "Installing npm dependencies (${ignore_scripts_flag:-scripts enabled})..."
	# shellcheck disable=SC2086
	if npm install --prefix "$plugin_dir" ${ignore_scripts_flag} 2>&1; then
		print_success "npm install complete"
	else
		print_warning "npm install failed — continuing without JS deps"
	fi
	return 0
}

# Activate plugin on multisite network (best-effort)
_activate_plugin_network() {
	local slug="${1:-}"
	local plugin_dir="${2:-}"
	print_info "Checking multisite network activation..."
	if (cd "$plugin_dir" && wp-env run cli wp plugin is-active "$slug" --network 2>/dev/null); then
		print_info "Plugin already network-active"
		return 0
	fi
	if (cd "$plugin_dir" && wp-env run cli wp plugin activate "$slug" --network 2>&1); then
		print_success "Plugin network-activated on multisite"
	else
		print_info "Network activation skipped (may not be network-activatable)"
	fi
	return 0
}

# =============================================================================
# Test sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Run Playwright smoke tests against the given base URL; returns 1 on failure
_run_playwright_tests() {
	local smoke_test_file="${1:-}"
	local base_url="${2:-}"
	local slug="${3:-}"

	if [[ ! -f "$smoke_test_file" ]]; then
		print_warning "No smoke test file found — skipping Playwright tests"
		print_info "Expected: ${smoke_test_file}"
		return 0
	fi
	if ! command -v npx >/dev/null 2>&1; then
		print_warning "npx not found — skipping Playwright smoke tests"
		return 0
	fi
	print_info "Running Playwright smoke tests (base URL: ${base_url})..."
	if WP_BASE_URL="$base_url" WP_PLUGIN_SLUG="$slug" \
		npx --no-install playwright test "$smoke_test_file" \
		--reporter=line 2>&1; then
		print_success "Playwright smoke tests: PASS"
	else
		print_error "Playwright smoke tests: FAIL"
		return 1
	fi
	return 0
}

# =============================================================================
# Review sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Register a branch subdomain via localdev and print the URL.
# Looks up an existing branch port from state first; allocates a new one only
# if none is persisted, then starts a branch wp-env instance bound to that port
# before registering the HTTPS URL so the URL points to a running instance.
_register_branch_url() {
	local slug="${1:-}"
	local branch_name="${2:-}"
	local plugin_dir="${3:-}"
	local branch_subdomain
	branch_subdomain="$(echo "$branch_name" | tr '/' '-' | tr '_' '-' | tr '[:upper:]' '[:lower:]')"

	# Derive state key for this branch instance
	local branch_state_key="${slug}:branch:${branch_subdomain}:port"

	# Prefer a previously-persisted port for this branch
	local branch_port
	branch_port="$(state_get "$branch_state_key")"

	if [[ -z "$branch_port" ]]; then
		# Allocate a new port and persist it
		branch_port="$(find_available_wp_env_port)" || branch_port=""
		if [[ -z "$branch_port" ]]; then
			print_warning "No available port for branch wp-env — skipping branch URL"
			return 0
		fi
		state_set "$branch_state_key" "$branch_port"
	fi

	# Ensure a wp-env instance is running on the branch port before registering
	# the HTTPS URL so the URL is not dead.
	if [[ -n "$plugin_dir" ]] && [[ -d "$plugin_dir" ]]; then
		print_info "Starting branch wp-env on port ${branch_port} (${branch_name})..."
		generate_wp_env_json "$plugin_dir" "$branch_port" || true
		if ! (cd "$plugin_dir" && wp-env start --update --config "${WP_ENV_CONFIG_FILE}" 2>&1); then
			print_warning "Branch wp-env start failed — HTTPS URL may not be reachable"
		else
			print_success "Branch wp-env started on port ${branch_port}"
		fi
	else
		print_warning "plugin_dir not provided or missing — branch wp-env not started"
	fi

	if [[ -x "$LOCALDEV_HELPER" ]]; then
		if "$LOCALDEV_HELPER" branch "$slug" "$branch_subdomain" "$branch_port" 2>/dev/null; then
			print_info "  HTTPS : https://${branch_subdomain}.${slug}.local"
		else
			print_info "  Branch URL registration failed — use HTTP"
			print_info "  HTTP  : http://localhost:${branch_port}"
		fi
	else
		print_info "  HTTP  : http://localhost:${branch_port}"
	fi
	return 0
}

# =============================================================================
# Cleanup sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Stop and destroy the wp-env environment
_destroy_wp_env() {
	local plugin_dir="${1:-}"
	if [[ ! -f "${plugin_dir}/${WP_ENV_CONFIG_FILE}" ]]; then
		print_info "No ${WP_ENV_CONFIG_FILE} found — skipping wp-env destroy"
		return 0
	fi
	print_info "Destroying wp-env environment..."
	if (cd "$plugin_dir" && wp-env destroy --yes --config "${WP_ENV_CONFIG_FILE}" 2>&1); then
		print_success "wp-env destroyed"
	else
		print_warning "wp-env destroy failed — may already be stopped"
	fi
	rm -f "${plugin_dir}/${WP_ENV_CONFIG_FILE}"
	return 0
}

# Remove localdev registration by plugin slug
_remove_localdev_reg() {
	local slug="${1:-}"
	if [[ ! -x "$LOCALDEV_HELPER" ]]; then
		return 0
	fi
	print_info "Removing localdev registration for ${slug}..."
	if "$LOCALDEV_HELPER" rm "$slug" 2>/dev/null; then
		print_success "localdev: removed ${slug}.local"
	else
		print_info "localdev: ${slug} was not registered (already removed)"
	fi
	return 0
}

# =============================================================================
# Setup sub-helpers (extracted to reduce nesting depth)
# =============================================================================

# Fix t1700 #1: Install a mu-plugin that trusts X-Forwarded-* headers from the
# wp-env reverse proxy.  Without this WordPress sees the request as plain HTTP
# and issues a redirect to http://localhost, breaking the HTTPS .local domain.
# The mu-plugin is written into the container via wp-env run cli so it survives
# wp-env restarts without requiring a custom Docker image.
_install_proxy_headers_muplugin() {
	local plugin_dir="${1:-}"
	local slug="${2:-}"
	print_info "Installing proxy-headers mu-plugin (X-Forwarded-* trust)..."

	# PHP source for the mu-plugin — trusts the wp-env internal proxy only.
	# Uses $_SERVER superglobal directly; no WordPress API needed at this stage.
	# Single quotes are intentional: PHP $_ variables must not be shell-expanded.
	local muplugin_php
	# shellcheck disable=SC2016
	muplugin_php='<?php
/**
 * aidevops-proxy-headers.php
 * Trust X-Forwarded-Proto and X-Forwarded-Host from the wp-env reverse proxy.
 * Installed automatically by wordpress-plugin.sh (t1700).
 */
if ( isset( $_SERVER["HTTP_X_FORWARDED_PROTO"] ) && "https" === strtolower( $_SERVER["HTTP_X_FORWARDED_PROTO"] ) ) {
    $_SERVER["HTTPS"] = "on";
}
if ( isset( $_SERVER["HTTP_X_FORWARDED_HOST"] ) ) {
    $_SERVER["HTTP_HOST"] = $_SERVER["HTTP_X_FORWARDED_HOST"];
}
'

	# Write the mu-plugin into the container's mu-plugins directory.
	if (cd "$plugin_dir" && wp-env run cli bash -c \
		"mkdir -p /var/www/html/wp-content/mu-plugins && cat > /var/www/html/wp-content/mu-plugins/aidevops-proxy-headers.php << 'MUPLUGIN_EOF'
${muplugin_php}
MUPLUGIN_EOF" 2>&1); then
		print_success "Proxy-headers mu-plugin installed"
	else
		print_warning "Proxy-headers mu-plugin install failed — HTTPS redirects may not work"
	fi
	return 0
}

# Fix t1700 #2: After multisite conversion, update WordPress URL options and the
# wp_blogs domain column from 'localhost' to '<slug>.local' so that wp-admin
# links and network admin resolve to the HTTPS .local domain.
_update_multisite_urls() {
	local plugin_dir="${1:-}"
	local slug="${2:-}"
	local domain="${slug}.local"
	print_info "Updating multisite URLs to ${domain}..."

	# Update siteurl and home in wp_options (main site)
	if (cd "$plugin_dir" && wp-env run cli wp option update siteurl "https://${domain}" 2>&1); then
		print_success "siteurl -> https://${domain}"
	else
		print_warning "Failed to update siteurl"
	fi

	if (cd "$plugin_dir" && wp-env run cli wp option update home "https://${domain}" 2>&1); then
		print_success "home -> https://${domain}"
	else
		print_warning "Failed to update home"
	fi

	# Update domain in wp_blogs table (multisite network sites)
	if (cd "$plugin_dir" && wp-env run cli wp db query \
		"UPDATE wp_blogs SET domain='${domain}' WHERE domain='localhost' OR domain LIKE 'localhost:%'" 2>&1); then
		print_success "wp_blogs.domain -> ${domain}"
	else
		print_warning "Failed to update wp_blogs.domain (may not be multisite yet)"
	fi

	# Update wp_site table (network root)
	if (cd "$plugin_dir" && wp-env run cli wp db query \
		"UPDATE wp_site SET domain='${domain}' WHERE domain='localhost' OR domain LIKE 'localhost:%'" 2>&1); then
		print_success "wp_site.domain -> ${domain}"
	else
		print_warning "Failed to update wp_site.domain"
	fi

	return 0
}

# Fix t1700 #3: Print admin credentials so the user can log in immediately
# after setup without having to look them up separately.
_print_credentials() {
	local plugin_dir="${1:-}"
	local wp_port="${2:-8888}"
	local slug="${3:-}"
	local domain="${slug}.local"

	print_info "Retrieving admin credentials..."

	local admin_user admin_pass
	admin_user="$(cd "$plugin_dir" && wp-env run cli wp user list \
		--role=administrator --field=user_login --format=csv 2>/dev/null | head -1)" || admin_user="admin"
	admin_pass="$(cd "$plugin_dir" && wp-env run cli wp user get "$admin_user" \
		--field=user_pass 2>/dev/null)" || admin_pass=""

	# wp-env default credentials when password hash is not directly readable
	[[ -z "$admin_user" ]] && admin_user="admin"
	[[ -z "$admin_pass" ]] && admin_pass="password"

	echo ""
	printf '%s\n' "┌─────────────────────────────────────────────┐"
	printf '%s\n' "│           WordPress Admin Credentials        │"
	printf '%s\n' "├─────────────────────────────────────────────┤"
	printf "│  URL      : https://%-24s│\n" "${domain}/wp-admin/"
	printf "│  Username : %-32s│\n" "$admin_user"
	printf "│  Password : %-32s│\n" "$admin_pass"
	printf '%s\n' "└─────────────────────────────────────────────┘"
	echo ""
	return 0
}

# Clone the plugin repo when not already present
_clone_plugin() {
	local github_slug="${1:-}"
	local plugin_dir="${2:-}"
	if [[ -d "$plugin_dir" ]]; then
		print_info "Plugin directory already exists: ${plugin_dir}"
		return 0
	fi
	print_info "Cloning ${github_slug} -> ${plugin_dir}"
	mkdir -p "$(dirname "$plugin_dir")"
	if ! git clone "https://github.com/${github_slug}.git" "$plugin_dir"; then
		print_error "Failed to clone ${github_slug}"
		return 1
	fi
	print_success "Cloned ${github_slug}"
	return 0
}

# Register plugin with localdev for HTTPS .local domain
_register_localdev() {
	local slug="${1:-}"
	local wp_port="${2:-}"
	if [[ ! -x "$LOCALDEV_HELPER" ]]; then
		print_warning "localdev-helper.sh not found — skipping HTTPS domain registration"
		print_info "HTTP access: http://localhost:${wp_port}"
		return 0
	fi
	print_info "Registering ${slug} with localdev (port ${wp_port})..."
	if "$LOCALDEV_HELPER" add "$slug" "$wp_port" 2>/dev/null; then
		print_success "Registered: https://${slug}.local -> localhost:${wp_port}"
	else
		print_warning "localdev registration failed — HTTP access only at http://localhost:${wp_port}"
	fi
	return 0
}

# =============================================================================
# setup command
# =============================================================================

cmd_setup() {
	local github_slug="${1:-}"
	local worktree_path="${2:-}"

	if [[ -z "$github_slug" ]]; then
		print_error "Usage: wordpress-plugin.sh setup <github-slug> [worktree-path]"
		print_info "  github-slug: e.g. afragen/git-updater"
		print_info "  worktree-path: optional path to an existing worktree (fix branch)"
		return 1
	fi

	require_cmd "docker" "brew install --cask docker" || return 1
	require_cmd "node" "brew install node" || return 1
	require_cmd "npm" "brew install node" || return 1
	require_cmd "jq" "brew install jq" || return 1

	local slug
	slug="$(plugin_slug_from_github "$github_slug")"
	local plugin_dir
	plugin_dir="$(plugin_dir_from_slug "$slug")"

	# Fix 2: when worktree_path overrides plugin_dir, also update slug so all
	# later steps use the same identifier.
	if [[ -n "$worktree_path" ]]; then
		plugin_dir="$worktree_path"
		slug="$(basename "$plugin_dir")"
	fi

	print_info "=== WordPress Plugin Handler: setup ==="
	print_info "GitHub slug : $github_slug"
	print_info "Plugin slug : $slug"
	print_info "Plugin dir  : $plugin_dir"
	echo ""

	_clone_plugin "$github_slug" "$plugin_dir" || return 1

	if ! command -v wp-env >/dev/null 2>&1; then
		print_info "Installing @wordpress/env globally..."
		npm install -g @wordpress/env || {
			print_error "Failed to install @wordpress/env"
			return 1
		}
	fi

	local wp_port
	wp_port="$(find_available_wp_env_port)" || return 1
	generate_wp_env_json "$plugin_dir" "$wp_port" || return 1

	print_info "Starting wp-env (port ${wp_port})..."
	# Fix 7: run wp-env from plugin_dir so it resolves the correct config file
	if ! (cd "$plugin_dir" && wp-env start --update --config "${WP_ENV_CONFIG_FILE}" 2>&1); then
		print_error "wp-env start failed"
		return 1
	fi
	print_success "wp-env started on port ${wp_port}"

	_register_localdev "$slug" "$wp_port"

	# Fix t1700 #1: install mu-plugin to trust X-Forwarded-* proxy headers
	_install_proxy_headers_muplugin "$plugin_dir" "$slug"

	# Fix t1700 #2: update WordPress URL options and multisite domain tables
	_update_multisite_urls "$plugin_dir" "$slug"

	state_set "${slug}:port" "$wp_port"
	state_set "${slug}:dir" "$plugin_dir"
	state_set "${slug}:github" "$github_slug"

	echo ""
	print_success "=== Setup complete ==="
	print_info "Plugin dir : ${plugin_dir}"
	print_info "wp-env URL : http://localhost:${wp_port}"
	[[ -x "$LOCALDEV_HELPER" ]] && print_info "HTTPS URL  : https://${slug}.local"

	# Fix t1700 #3: print admin credentials
	_print_credentials "$plugin_dir" "$wp_port" "$slug"

	print_info "Next: wordpress-plugin.sh build ${plugin_dir}"
	return 0
}

# =============================================================================
# build command
# =============================================================================

cmd_build() {
	local plugin_dir="${1:-}"

	if [[ -z "$plugin_dir" ]]; then
		print_error "Usage: wordpress-plugin.sh build <plugin-dir>"
		return 1
	fi

	if [[ ! -d "$plugin_dir" ]]; then
		print_error "Plugin directory not found: ${plugin_dir}"
		return 1
	fi

	local slug
	slug="$(basename "$plugin_dir")"

	print_info "=== WordPress Plugin Handler: build (${slug}) ==="

	_install_composer_deps "$plugin_dir"
	_install_npm_deps "$plugin_dir"

	print_info "Activating plugin in wp-env..."
	# Fix 7: run wp-env from plugin_dir so it resolves the correct config file
	if (cd "$plugin_dir" && wp-env run cli wp plugin activate "$slug" 2>&1); then
		print_success "Plugin activated: ${slug}"
	else
		print_warning "Plugin activation failed — check wp-env is running"
	fi

	_activate_plugin_network "$slug" "$plugin_dir"

	echo ""
	print_success "=== Build complete ==="
	print_info "Next: wordpress-plugin.sh test ${plugin_dir}"
	return 0
}

# =============================================================================
# test command
# =============================================================================

cmd_test() {
	local plugin_dir="${1:-}"

	if [[ -z "$plugin_dir" ]]; then
		print_error "Usage: wordpress-plugin.sh test <plugin-dir>"
		return 1
	fi

	if [[ ! -d "$plugin_dir" ]]; then
		print_error "Plugin directory not found: ${plugin_dir}"
		return 1
	fi

	local slug
	slug="$(basename "$plugin_dir")"
	local test_passed=true

	print_info "=== WordPress Plugin Handler: test (${slug}) ==="

	# PHPUnit (when tests exist)
	local has_phpunit=false
	[[ -f "${plugin_dir}/phpunit.xml" ]] || [[ -f "${plugin_dir}/phpunit.xml.dist" ]] && has_phpunit=true

	if [[ "$has_phpunit" == "true" ]]; then
		print_info "Running PHPUnit tests..."
		# Fix 4: run wp-env from plugin_dir so phpunit.xml is found in the plugin's CWD
		if (cd "$plugin_dir" && wp-env run tests-cli --env-cwd="wp-content/plugins/${slug}" phpunit 2>&1); then
			print_success "PHPUnit: PASS"
		else
			print_error "PHPUnit: FAIL"
			test_passed=false
		fi
	else
		print_info "No phpunit.xml found — skipping PHPUnit"
	fi

	# Check debug.log — PHP fatal errors
	print_info "Checking debug.log: PHP errors..."
	local debug_log_errors
	# Fix 7: run wp-env from plugin_dir
	debug_log_errors="$(cd "$plugin_dir" && wp-env run cli cat /var/www/html/wp-content/debug.log 2>/dev/null | grep -ciE '(Fatal error|PHP Fatal|PHP Parse error)' || echo 0)"
	if [[ "$debug_log_errors" -gt 0 ]]; then
		print_error "PHP fatal/parse errors found in debug.log (${debug_log_errors} occurrences)"
		(cd "$plugin_dir" && wp-env run cli cat /var/www/html/wp-content/debug.log 2>/dev/null | grep -iE '(Fatal error|PHP Fatal|PHP Parse error)' | head -10)
		test_passed=false
	else
		print_success "debug.log: no PHP fatal errors"
	fi

	# Playwright smoke tests
	local smoke_test_file="${plugin_dir}/tests/e2e/wp-plugin-smoke-test.spec.js"
	[[ ! -f "$smoke_test_file" ]] && smoke_test_file="$SMOKE_TEST_TEMPLATE"

	local slug_port
	slug_port="$(state_get "${slug}:port")"
	local base_url="http://localhost:${slug_port:-8888}"

	if ! _run_playwright_tests "$smoke_test_file" "$base_url" "$slug"; then
		test_passed=false
	fi

	# Multisite-specific checks
	print_info "Running multisite checks..."
	_run_multisite_checks "$slug" "$plugin_dir" || test_passed=false

	echo ""
	if [[ "$test_passed" == "true" ]]; then
		print_success "=== All tests PASSED ==="
	else
		print_error "=== Some tests FAILED — review output above ==="
		return 1
	fi
	return 0
}

# Run multisite-specific checks: verify plugin works on sub-sites,
# check multisite-incompatible code patterns.
_run_multisite_checks() {
	local slug="${1:-}"
	local plugin_dir="${2:-}"

	# Fix 7: run wp-env from plugin_dir
	if (cd "$plugin_dir" && wp-env run cli wp plugin is-active "$slug" --network 2>/dev/null); then
		print_success "Multisite: plugin is network-active"
	else
		print_info "Multisite: plugin is not network-active (may be site-specific)"
	fi

	local incompatible_patterns=0
	if command -v rg >/dev/null 2>&1; then
		incompatible_patterns="$(rg -l 'get_option\s*\(\s*['"'"'"]blogname['"'"'"]' \
			--type php "${SCRIPT_DIR}/../../../" 2>/dev/null | wc -l | tr -d ' ')" || incompatible_patterns=0
	fi

	if [[ "$incompatible_patterns" -gt 0 ]]; then
		print_warning "Multisite: found ${incompatible_patterns} file(s) using get_option('blogname') — consider get_bloginfo()"
	fi

	return 0
}

# =============================================================================
# review command
# =============================================================================

cmd_review() {
	local plugin_dir="${1:-}"
	local branch_name="${2:-}"

	if [[ -z "$plugin_dir" ]]; then
		print_error "Usage: wordpress-plugin.sh review <plugin-dir> [branch-name]"
		return 1
	fi

	local slug
	slug="$(basename "$plugin_dir")"
	local wp_port
	wp_port="$(state_get "${slug}:port")"

	print_info "=== WordPress Plugin Handler: review (${slug}) ==="
	echo ""

	print_info "Current release:"
	print_info "  HTTP  : http://localhost:${wp_port:-8888}"
	[[ -x "$LOCALDEV_HELPER" ]] && print_info "  HTTPS : https://${slug}.local"

	if [[ -n "$branch_name" ]]; then
		echo ""
		print_info "Branch: ${branch_name}"
		# Fix 1: pass plugin_dir so _register_branch_url can start a branch wp-env
		[[ -x "$LOCALDEV_HELPER" ]] && _register_branch_url "$slug" "$branch_name" "$plugin_dir"
	fi

	echo ""
	print_info "wp-admin: http://localhost:${wp_port:-8888}/wp-admin/ (admin/password)"
	return 0
}

# =============================================================================
# cleanup command
# =============================================================================

cmd_cleanup() {
	local plugin_dir="${1:-}"

	if [[ -z "$plugin_dir" ]]; then
		print_error "Usage: wordpress-plugin.sh cleanup <plugin-dir>"
		return 1
	fi

	local slug
	slug="$(basename "$plugin_dir")"

	print_info "=== WordPress Plugin Handler: cleanup (${slug}) ==="

	_destroy_wp_env "$plugin_dir"
	_remove_localdev_reg "$slug"

	state_del "${slug}:port"
	state_del "${slug}:dir"
	state_del "${slug}:github"

	echo ""
	print_success "=== Cleanup complete ==="
	return 0
}

# =============================================================================
# help command
# =============================================================================

cmd_help() {
	printf '%s\n' \
		'wordpress-plugin.sh — FOSS contribution handler: WordPress plugins (t1696)' \
		'' \
		'USAGE' \
		'  wordpress-plugin.sh <command> [args]' \
		'' \
		'COMMANDS' \
		'  setup   <github-slug> [worktree-path]' \
		'      Fork, clone, generate .wp-env.aidevops.json (multisite), start wp-env,' \
		'      register HTTPS .local domain via localdev.' \
		'      Example: wordpress-plugin.sh setup afragen/git-updater' \
		'' \
		'  build   <plugin-dir>' \
		'      Install composer/npm deps, activate plugin on single site + network.' \
		'      Example: wordpress-plugin.sh build ~/Git/wordpress/git-updater' \
		'' \
		'  test    <plugin-dir>' \
		'      Run PHPUnit (phpunit.xml present), check debug.log, PHP errors,' \
		'      run Playwright smoke tests, run multisite checks.' \
		'      Example: wordpress-plugin.sh test ~/Git/wordpress/git-updater' \
		'' \
		'  review  <plugin-dir> [branch-name]' \
		'      Print review URLs. With branch-name, starts a branch wp-env instance' \
		'      and registers a branch subdomain via localdev — side-by-side comparison.' \
		'      Example: wordpress-plugin.sh review ~/Git/wordpress/git-updater bugfix-xyz' \
		'' \
		'  cleanup <plugin-dir>' \
		'      Destroy wp-env, remove localdev registration, deregister port.' \
		'      Example: wordpress-plugin.sh cleanup ~/Git/wordpress/git-updater' \
		'' \
		'  help' \
		'      Show this help.' \
		'' \
		'PREREQUISITES' \
		'  docker          — required by wp-env containers' \
		'  node >= 18      — required by @wordpress/env' \
		'  jq              — required by JSON config generation' \
		'  composer        — optional, PHP deps' \
		'  mkcert          — optional, HTTPS .local (via localdev-helper.sh init)' \
		'' \
		'SECURITY' \
		'  composer and npm installs run with --no-scripts/--ignore-scripts by default.' \
		'  Set ALLOW_PLUGIN_SCRIPTS=1 to opt in to running plugin lifecycle scripts.' \
		'' \
		'STATE FILE' \
		'  ~/.aidevops/cache/foss-wp-handler.json' \
		'' \
		'SMOKE TEST TEMPLATE' \
		'  foss-handlers/wp-plugin-smoke-test.spec.js' \
		'  (used when plugin has no tests/e2e/ directory)' \
		'' \
		'REVIEW URLS' \
		'  Current release : https://<slug>.local' \
		'  Branch/worktree : https://<branch>.<slug>.local'
	return 0
}

# =============================================================================
# Entry point
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	setup) cmd_setup "$@" ;;
	build) cmd_build "$@" ;;
	test) cmd_test "$@" ;;
	review) cmd_review "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${cmd}"
		print_info "Use 'wordpress-plugin.sh help' for usage"
		return 1
		;;
	esac
	return $?
}

main "$@"
