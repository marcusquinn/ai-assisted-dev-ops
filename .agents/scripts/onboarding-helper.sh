#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155

# Onboarding Helper - Interactive setup and service status for aidevops
#
# This script provides:
# 1. Service status detection (what's configured vs needs setup)
# 2. Personalized recommendations based on user's work type
# 3. Setup guidance with links and commands
#
# Usage: ./onboarding-helper.sh [command]
# Commands:
#   status      - Show all services and their configuration status
#   recommend   - Get personalized service recommendations
#   guide       - Show setup guide for a specific service
#   json        - Output status as JSON
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly DIM='\033[2m'

# Settings file (canonical config — see settings-helper.sh)
readonly SETTINGS_FILE="$HOME/.config/aidevops/settings.json"
readonly SETTINGS_HELPER="${SCRIPT_DIR}/settings-helper.sh"

# Credential file locations
readonly CREDENTIALS_FILE="$HOME/.config/aidevops/credentials.sh"
readonly CODERABBIT_KEY_FILE="$HOME/.config/coderabbit/api_key"

# Source credentials.sh if it exists
if [[ -f "$CREDENTIALS_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$CREDENTIALS_FILE"
fi

# Ensure settings.json exists with defaults
_ensure_settings() {
	if [[ -x "$SETTINGS_HELPER" ]]; then
		bash "$SETTINGS_HELPER" init >/dev/null
	fi
	return 0
}

# Read a setting from settings.json
_get_setting() {
	local key="$1"
	if [[ -x "$SETTINGS_HELPER" ]]; then
		bash "$SETTINGS_HELPER" get "$key"
	else
		echo "null"
	fi
	return 0
}

# Write a setting to settings.json
_set_setting() {
	local key="$1"
	local value="$2"
	if [[ -x "$SETTINGS_HELPER" ]]; then
		bash "$SETTINGS_HELPER" set "$key" "$value" >/dev/null
	fi
	return 0
}

# Check if an environment variable is set and not a placeholder
is_configured() {
	local var_name="$1"
	local value="${!var_name:-}"

	if [[ -z "$value" ]]; then
		return 1
	fi

	# Check for placeholder patterns
	local lower_value
	lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')

	case "$lower_value" in
	*your* | *replace* | *changeme* | *example* | *placeholder* | xxx* | none | null)
		return 1
		;;
	*)
		return 0
		;;
	esac
}

# Check if a CLI tool is authenticated
is_cli_authenticated() {
	local cli="$1"

	case "$cli" in
	gh)
		gh auth status &>/dev/null && return 0 || return 1
		;;
	glab)
		glab auth status &>/dev/null && return 0 || return 1
		;;
	tea)
		tea login list 2>/dev/null | grep -q "Name:" && return 0 || return 1
		;;
	*)
		return 1
		;;
	esac
}

# Check if a tool is installed
is_installed() {
	local tool="$1"
	command -v "$tool" &>/dev/null
}

# Print service status
print_service() {
	local name="$1"
	local status="$2"
	local details="${3:-}"

	local icon status_color
	case "$status" in
	"ready")
		icon="✓"
		status_color="${GREEN}"
		;;
	"partial")
		icon="◐"
		status_color="${YELLOW}"
		;;
	"needs-setup")
		icon="○"
		status_color="${RED}"
		;;
	"optional")
		icon="·"
		status_color="${DIM}"
		;;
	*)
		icon="?"
		status_color="${NC}"
		;;
	esac

	if [[ -n "$details" ]]; then
		echo -e "  ${status_color}${icon}${NC} ${name} ${DIM}(${details})${NC}"
	else
		echo -e "  ${status_color}${icon}${NC} ${name}"
	fi
	return 0
}

# Check AI providers
check_ai_providers() {
	echo -e "${BLUE}AI Providers${NC}"

	if is_configured "OPENAI_API_KEY"; then
		print_service "OpenAI" "ready" "API key configured"
	else
		print_service "OpenAI" "needs-setup" "OPENAI_API_KEY not set"
	fi

	if is_configured "ANTHROPIC_API_KEY"; then
		print_service "Anthropic" "ready" "API key configured"
	else
		print_service "Anthropic" "needs-setup" "ANTHROPIC_API_KEY not set"
	fi

	echo ""
	return 0
}

# Check Git platforms
check_git_platforms() {
	echo -e "${BLUE}Git Platforms${NC}"

	if is_installed "gh"; then
		if is_cli_authenticated "gh"; then
			print_service "GitHub CLI" "ready" "authenticated"
		else
			print_service "GitHub CLI" "partial" "installed, needs auth"
		fi
	else
		print_service "GitHub CLI" "needs-setup" "not installed"
	fi

	if is_installed "glab"; then
		if is_cli_authenticated "glab"; then
			print_service "GitLab CLI" "ready" "authenticated"
		else
			print_service "GitLab CLI" "partial" "installed, needs auth"
		fi
	else
		print_service "GitLab CLI" "optional" "not installed"
	fi

	if is_installed "tea"; then
		if is_cli_authenticated "tea"; then
			print_service "Gitea CLI" "ready" "authenticated"
		else
			print_service "Gitea CLI" "partial" "installed, needs auth"
		fi
	else
		print_service "Gitea CLI" "optional" "not installed"
	fi

	echo ""
	return 0
}

# Check hosting providers
check_hosting() {
	echo -e "${BLUE}Hosting Providers${NC}"

	# Hetzner - check for any HCLOUD_TOKEN_* variable
	local hetzner_configured=false
	for var in $(env | grep -o '^HCLOUD_TOKEN_[A-Z_]*' 2>/dev/null || true); do
		if is_configured "$var"; then
			hetzner_configured=true
			break
		fi
	done
	if [[ "$hetzner_configured" == "true" ]]; then
		print_service "Hetzner Cloud" "ready" "API token configured"
	else
		print_service "Hetzner Cloud" "needs-setup" "HCLOUD_TOKEN_* not set"
	fi

	if is_configured "CLOUDFLARE_API_TOKEN"; then
		print_service "Cloudflare" "ready" "API token configured"
	else
		print_service "Cloudflare" "needs-setup" "CLOUDFLARE_API_TOKEN not set"
	fi

	if is_configured "COOLIFY_API_TOKEN"; then
		print_service "Coolify" "ready" "API token configured"
	else
		print_service "Coolify" "optional" "COOLIFY_API_TOKEN not set"
	fi

	if is_configured "VERCEL_TOKEN"; then
		print_service "Vercel" "ready" "token configured"
	else
		print_service "Vercel" "optional" "VERCEL_TOKEN not set"
	fi

	echo ""
	return 0
}

# Check code quality services
check_code_quality() {
	echo -e "${BLUE}Code Quality${NC}"

	if is_configured "SONAR_TOKEN"; then
		print_service "SonarCloud" "ready" "token configured"
	else
		print_service "SonarCloud" "needs-setup" "SONAR_TOKEN not set"
	fi

	if is_configured "CODACY_PROJECT_TOKEN"; then
		print_service "Codacy" "ready" "token configured"
	else
		print_service "Codacy" "optional" "CODACY_PROJECT_TOKEN not set"
	fi

	if [[ -f "$CODERABBIT_KEY_FILE" ]]; then
		print_service "CodeRabbit" "ready" "API key file exists"
	elif is_configured "CODERABBIT_API_KEY"; then
		print_service "CodeRabbit" "ready" "API key configured"
	else
		print_service "CodeRabbit" "optional" "not configured"
	fi

	if is_configured "SNYK_TOKEN"; then
		print_service "Snyk" "ready" "token configured"
	else
		print_service "Snyk" "optional" "SNYK_TOKEN not set"
	fi

	echo ""
	return 0
}

# Check SEO services
check_seo() {
	echo -e "${BLUE}SEO & Research${NC}"

	if is_configured "DATAFORSEO_USERNAME" && is_configured "DATAFORSEO_PASSWORD"; then
		print_service "DataForSEO" "ready" "credentials configured"
	else
		print_service "DataForSEO" "needs-setup" "credentials not set"
	fi

	if is_configured "SERPER_API_KEY"; then
		print_service "Serper" "ready" "API key configured"
	else
		print_service "Serper" "optional" "SERPER_API_KEY not set"
	fi

	if is_configured "OUTSCRAPER_API_KEY"; then
		print_service "Outscraper" "ready" "API key configured"
	else
		print_service "Outscraper" "optional" "OUTSCRAPER_API_KEY not set"
	fi

	echo ""
	return 0
}

# Check context tools
check_context_tools() {
	echo -e "${BLUE}Context & Local Search${NC}"

	print_service "Local search" "ready" "git grep, rg, git ls-files, and fd"

	# Context7 is MCP-only, no auth needed
	print_service "Context7" "ready" "MCP (no auth needed)"

	# sqlite3 is required for memory system (FTS5 required for full-text search)
	if is_installed "sqlite3"; then
		if sqlite3 :memory: 'CREATE VIRTUAL TABLE t USING fts5(content);' &>/dev/null; then
			print_service "sqlite3" "ready" "memory system ready"
		else
			print_service "sqlite3" "partial" "installed, missing FTS5 (required for memory)"
		fi
	else
		print_service "sqlite3" "needs-setup" "required for memory system"
	fi

	echo ""
	return 0
}

# Check browser automation
check_browser() {
	echo -e "${BLUE}Browser Automation${NC}"

	local playwright_runtime="${SCRIPT_DIR}/playwright-runtime.mjs"
	local playwright_state="optional"
	local playwright_detail="Node package not importable"
	if is_installed "node"; then
		if node "$playwright_runtime" check &>/dev/null; then
			playwright_state="ready"
			playwright_detail="Node package and browser binary ready"
		elif node "$playwright_runtime" resolve &>/dev/null; then
			playwright_state="partial"
			playwright_detail="Node package ready; browser binary missing"
		fi
	fi
	print_service "Playwright" "$playwright_state" "$playwright_detail"

	# Stagehand needs OpenAI or Anthropic key
	if is_configured "OPENAI_API_KEY" || is_configured "ANTHROPIC_API_KEY"; then
		print_service "Stagehand" "ready" "AI key available"
	else
		print_service "Stagehand" "needs-setup" "needs AI API key"
	fi

	print_service "Chrome DevTools" "ready" "MCP (no auth needed)"
	print_service "Playwright Extension" "optional" "interactive user-browser access only"

	echo ""
	return 0
}

# Check AWS services
check_aws() {
	echo -e "${BLUE}AWS Services${NC}"

	if is_configured "AWS_ACCESS_KEY_ID" && is_configured "AWS_SECRET_ACCESS_KEY"; then
		print_service "AWS" "ready" "credentials configured"

		if is_configured "AWS_DEFAULT_REGION"; then
			print_service "  Region" "ready" "${AWS_DEFAULT_REGION:-}"
		else
			print_service "  Region" "partial" "AWS_DEFAULT_REGION not set"
		fi
	else
		print_service "AWS" "optional" "credentials not set"
	fi

	echo ""
	return 0
}

# Check WordPress tools
check_wordpress() {
	echo -e "${BLUE}WordPress${NC}"

	if is_installed "wp"; then
		print_service "WP-CLI" "ready" "installed"
	else
		print_service "WP-CLI" "optional" "not installed"
	fi

	# Check for LocalWP
	if [[ -d "/Applications/Local.app" ]] || [[ -d "$HOME/Applications/Local.app" ]]; then
		print_service "LocalWP" "ready" "installed"
	else
		print_service "LocalWP" "optional" "not installed"
	fi

	# MainWP config check (XDG-compliant location)
	if [[ -f "$HOME/.config/aidevops/mainwp-config.json" ]]; then
		print_service "MainWP" "ready" "config exists"
	else
		print_service "MainWP" "optional" "not configured"
	fi

	echo ""
	return 0
}

# Check containers and VMs
check_containers() {
	echo -e "${BLUE}Containers & VMs${NC}"

	if is_installed "orb"; then
		local orb_ver
		orb_ver=$(orb version 2>/dev/null | head -1 | awk '{print $2}')
		orb_ver="${orb_ver:-unknown}"
		if orb status &>/dev/null; then
			print_service "OrbStack" "ready" "v${orb_ver}, running"
		else
			print_service "OrbStack" "partial" "v${orb_ver}, not running"
		fi
	else
		print_service "OrbStack" "optional" "not installed (brew install orbstack)"
	fi

	if is_installed "docker"; then
		print_service "Docker" "ready" "available via OrbStack or standalone"
	else
		print_service "Docker" "optional" "not installed"
	fi

	echo ""
	return 0
}

# Check networking tools
check_networking() {
	echo -e "${BLUE}Networking${NC}"

	if is_installed "tailscale"; then
		if tailscale status &>/dev/null 2>&1; then
			local ts_hostname
			ts_hostname=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || echo "")
			if [[ -n "$ts_hostname" ]]; then
				print_service "Tailscale" "ready" "connected as ${ts_hostname}"
			else
				print_service "Tailscale" "ready" "connected"
			fi
		else
			print_service "Tailscale" "partial" "installed, not connected"
		fi
	else
		print_service "Tailscale" "optional" "not installed"
	fi

	echo ""
	return 0
}

# Check repo-sync configuration
check_repo_sync() {
	echo -e "${BLUE}Repo Sync${NC}"

	local repo_sync_script="$HOME/.aidevops/agents/scripts/repo-sync-helper.sh"
	local config_file="$HOME/.config/aidevops/repos.json"

	# Check if scheduler is installed
	local scheduler_active=false
	if launchctl list 2>/dev/null | grep -q "com.aidevops.aidevops-repo-sync"; then
		scheduler_active=true
	elif crontab -l 2>/dev/null | grep -qF "aidevops-repo-sync"; then
		scheduler_active=true
	fi

	# Check configured parent dirs
	local dir_count=0
	if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
		dir_count=$(jq -r '.git_parent_dirs[]? // empty' "$config_file" 2>/dev/null | wc -l | tr -d ' ')
	fi

	if [[ "$scheduler_active" == "true" ]] && [[ "$dir_count" -gt 0 ]]; then
		print_service "Repo Sync" "ready" "enabled, ${dir_count} parent dir(s) configured"
	elif [[ "$scheduler_active" == "true" ]]; then
		print_service "Repo Sync" "partial" "enabled, no parent dirs configured"
	elif [[ -x "$repo_sync_script" ]]; then
		print_service "Repo Sync" "optional" "not enabled (aidevops repo-sync enable)"
	else
		print_service "Repo Sync" "optional" "not installed (aidevops update)"
	fi

	echo ""
	return 0
}

# Interactively configure git parent directories for repo-sync
configure_dirs() {
	local repo_sync_script="$HOME/.aidevops/agents/scripts/repo-sync-helper.sh"
	local config_file="$HOME/.config/aidevops/repos.json"

	echo ""
	echo -e "${BLUE}Configure Git Parent Directories for Repo Sync${NC}"
	echo "================================================"
	echo ""
	echo "Repo sync scans parent directories and reports remote drift daily"
	echo "without modifying human canonical checkouts."
	echo ""

	if ! command -v jq &>/dev/null; then
		echo "jq is required for directory management."
		echo "Install: brew install jq"
		echo ""
		return 1
	fi

	# Show current configuration
	local current_dirs=()
	if [[ -f "$config_file" ]]; then
		while IFS= read -r dir; do
			[[ -n "$dir" ]] && current_dirs+=("$dir")
		done < <(jq -r '.git_parent_dirs[]? // empty' "$config_file" 2>/dev/null || true)
	fi

	if [[ ${#current_dirs[@]} -gt 0 ]]; then
		echo "Currently configured directories:"
		for dir in "${current_dirs[@]}"; do
			local expanded="${dir/#\~/$HOME}"
			if [[ -d "$expanded" ]]; then
				echo "  $dir"
			else
				echo "  $dir  (not found)"
			fi
		done
		echo ""
	else
		echo "No parent directories configured yet."
		echo "Default: ~/Git"
		echo ""
	fi

	# Ask user to specify directories
	echo "Enter parent directories to scan for git repos (one per line)."
	echo "Press Enter with an empty line when done. Leave blank to keep defaults."
	echo ""

	local added=0
	while true; do
		read -r -p "Parent directory (e.g. ~/Git): " new_dir
		if [[ -z "$new_dir" ]]; then
			break
		fi

		if [[ -x "$repo_sync_script" ]]; then
			if bash "$repo_sync_script" dirs add "$new_dir"; then
				added=$((added + 1))
			fi
		else
			# Fallback: write directly to config
			mkdir -p "$(dirname "$config_file")"
			if [[ ! -f "$config_file" ]]; then
				echo '{"initialized_repos": [], "git_parent_dirs": []}' >"$config_file"
			fi
			local expanded="${new_dir/#\~/$HOME}"
			local normalized="$new_dir"
			if [[ "$expanded" == "$HOME"/* ]]; then
				normalized="~${expanded#"$HOME"}"
			fi
			local temp_file="${config_file}.tmp"
			if jq --arg d "$normalized" '.git_parent_dirs += [$d]' "$config_file" >"$temp_file"; then
				mv "$temp_file" "$config_file"
				echo "Added: $normalized"
				added=$((added + 1))
			else
				rm -f "$temp_file"
				echo "Failed to add: $new_dir"
			fi
		fi
	done

	if [[ "$added" -gt 0 ]]; then
		echo ""
		echo "Added $added directory/directories."
		echo "Run 'aidevops repo-sync check' to sync now."

		# Sync directories to settings.json
		_sync_dirs_to_settings "$config_file"
	elif [[ ${#current_dirs[@]} -eq 0 ]]; then
		echo "No directories added. Using default: ~/Git"
	fi

	echo ""
	return 0
}

# Sync git_parent_dirs from repos.json into settings.json
_sync_dirs_to_settings() {
	local config_file="$1"

	if [[ ! -f "$config_file" ]] || ! command -v jq &>/dev/null; then
		return 0
	fi

	local dirs_json
	dirs_json=$(jq -c '[.git_parent_dirs[]? // empty]' "$config_file" || echo '["~/Git"]')

	_set_setting "repo_sync.directories" "$dirs_json"
	_set_setting "repo_sync.enabled" "true"
	return 0
}

# Check orchestration features
check_orchestration() {
	echo -e "${BLUE}Autonomous Orchestration${NC}"

	# Check supervisor pulse scheduler
	local pulse_active=false
	if launchctl list 2>/dev/null | grep -qF "com.aidevops.aidevops-supervisor-pulse"; then
		pulse_active=true
	elif launchctl list 2>/dev/null | grep -qF "com.aidevops.supervisor-pulse"; then
		pulse_active=true
	elif crontab -l 2>/dev/null | grep -qF "aidevops-supervisor-pulse"; then
		pulse_active=true
	fi

	if [[ "$pulse_active" == "true" ]]; then
		print_service "Supervisor Pulse" "ready" "dispatches workers, merges PRs every 2 min"
		echo "    Runs 24/7 by default. Use 'aidevops pulse stop' for manual start/stop mode." >&2
	else
		print_service "Supervisor Pulse" "needs-setup" "see scripts/commands/runners.md for setup"
	fi

	# Auto-pickup is implicit when pulse is active
	if [[ "$pulse_active" == "true" ]]; then
		print_service "Auto-Pickup" "ready" "claims #auto-dispatch tasks from TODO.md"
	else
		print_service "Auto-Pickup" "optional" "requires supervisor pulse"
	fi

	# Cross-repo visibility depends on repos.json
	local repos_config="$HOME/.config/aidevops/repos.json"
	if [[ -f "$repos_config" ]] && command -v jq &>/dev/null; then
		local repo_count
		repo_count=$(jq -r '.initialized_repos | length' "$repos_config" 2>/dev/null || echo "0")
		if [[ "$repo_count" -gt 0 ]]; then
			print_service "Cross-Repo Visibility" "ready" "${repo_count} repo(s) managed"
		else
			print_service "Cross-Repo Visibility" "partial" "repos.json exists, no repos registered"
		fi
	else
		print_service "Cross-Repo Visibility" "optional" "run aidevops init in your projects"
	fi

	# Model routing is always available
	print_service "Model Routing" "ready" "cost-aware: local>haiku>flash>sonnet>pro>opus"

	# Budget tracking
	local budget_script="$HOME/.aidevops/agents/scripts/budget-tracker-helper.sh"
	if [[ -x "$budget_script" ]]; then
		print_service "Budget Tracking" "ready" "per-provider spend limits"
	else
		print_service "Budget Tracking" "optional" "budget-tracker-helper.sh not found"
	fi

	echo ""
	return 0
}

# Check OpenClaw
check_openclaw() {
	echo -e "${BLUE}Personal AI (OpenClaw)${NC}"

	if is_installed "openclaw"; then
		local oc_ver
		oc_ver=$(openclaw --version 2>/dev/null | head -1)
		oc_ver="${oc_ver:-unknown}"
		# Check if gateway is running
		if openclaw gateway status &>/dev/null; then
			print_service "OpenClaw Gateway" "ready" "${oc_ver}, running"
		else
			print_service "OpenClaw Gateway" "partial" "${oc_ver}, not running"
		fi
		# Check if any channels are configured
		if [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
			print_service "OpenClaw Config" "ready" "config exists"
		else
			print_service "OpenClaw Config" "needs-setup" "no config found"
		fi
	else
		print_service "OpenClaw" "optional" "not installed"
	fi

	echo ""
	return 0
}

# Show full status
show_status() {
	echo ""
	echo -e "${BLUE}aidevops Service Status${NC}"
	echo "========================"
	echo ""
	echo -e "${DIM}Legend: ${GREEN}✓${NC}${DIM} ready  ${YELLOW}◐${NC}${DIM} partial  ${RED}○${NC}${DIM} needs setup  ${DIM}·${NC}${DIM} optional${NC}"
	echo ""

	check_ai_providers
	check_git_platforms
	check_hosting
	check_code_quality
	check_seo
	check_context_tools
	check_browser
	check_containers
	check_networking
	check_orchestration
	check_openclaw
	check_aws
	check_wordpress
	check_repo_sync

	echo -e "${DIM}---${NC}"
	echo -e "Run ${BLUE}~/.aidevops/agents/scripts/list-keys-helper.sh${NC} for detailed key status"
	echo -e "Run ${BLUE}/onboarding${NC} in OpenCode for interactive setup guidance"
	echo ""
	return 0
}

# Show recommendations based on work type
show_recommendations() {
	local work_type="${1:-}"

	echo ""
	echo -e "${PURPLE}Recommended Services${NC}"
	echo "===================="
	echo ""

	case "$work_type" in
	web | webdev | "web development" | 1)
		echo -e "${BLUE}For Web Development:${NC}"
		echo ""
		echo "Essential:"
		echo "  • GitHub CLI (gh) - Repository management"
		echo "  • OpenAI API - AI-powered coding assistance"
		echo "  • Local search - git grep, rg, git ls-files, and fd"
		echo "  • Playwright - Browser testing"
		echo ""
		echo "Recommended:"
		echo "  • Vercel or Coolify - Deployment"
		echo "  • Cloudflare - DNS and CDN"
		echo "  • SonarCloud - Code quality"
		;;
	devops | infrastructure | 2)
		echo -e "${BLUE}For DevOps & Infrastructure:${NC}"
		echo ""
		echo "Essential:"
		echo "  • GitHub/GitLab CLI - Repository management"
		echo "  • Hetzner Cloud - VPS servers"
		echo "  • Cloudflare - DNS management"
		echo "  • Coolify - Self-hosted PaaS"
		echo ""
		echo "Recommended:"
		echo "  • Supervisor pulse - Autonomous task dispatch and PR management"
		echo "  • SonarCloud + Codacy - Code quality"
		echo "  • Snyk - Security scanning"
		echo "  • AWS - Cloud services"
		;;
	seo | marketing | "content marketing" | 3)
		echo -e "${BLUE}For SEO & Content Marketing:${NC}"
		echo ""
		echo "Essential:"
		echo "  • DataForSEO - Keyword research, SERP analysis"
		echo "  • Serper - Google Search API"
		echo "  • Google Search Console - Search performance"
		echo ""
		echo "Recommended:"
		echo "  • Outscraper - Business data extraction"
		echo "  • Stagehand - Browser automation for research"
		;;
	wordpress | clients | "multiple sites" | 4)
		echo -e "${BLUE}For WordPress & Client Management:${NC}"
		echo ""
		echo "Essential:"
		echo "  • LocalWP - Local WordPress development"
		echo "  • MainWP - Fleet management"
		echo "  • GitHub CLI - Version control"
		echo ""
		echo "Recommended:"
		echo "  • Hostinger or Hetzner - Hosting"
		echo "  • Cloudflare - DNS and security"
		echo "  • DataForSEO - SEO analysis"
		;;
	*)
		echo -e "${BLUE}General Recommendations:${NC}"
		echo ""
		echo "Start with these core services:"
		echo "  1. GitHub CLI (gh auth login)"
		echo "  2. OpenAI or Anthropic API key"
		echo "  3. Local code search (git grep and rg)"
		echo ""
		echo "Then add based on your needs:"
		echo "  • Orchestration: aidevops pulse start (autonomous workers)"
		echo "  • Hosting: Hetzner, Cloudflare, Coolify, Vercel"
		echo "  • Quality: SonarCloud, Codacy, CodeRabbit"
		echo "  • SEO: DataForSEO, Serper"
		echo "  • WordPress: LocalWP, MainWP"
		;;
	esac

	echo ""
	return 0
}

# Guide helpers — one function per service (keeps show_guide() under 30 lines)

_guide_github() {
	echo -e "${BLUE}GitHub CLI Setup${NC}"
	echo ""
	echo "1. Install: brew install gh"
	echo "2. Authenticate: gh auth login -s workflow"
	echo "   (workflow scope is required for PRs that modify CI workflows)"
	echo "3. Verify: gh auth status"
	return 0
}

_guide_openai() {
	echo -e "${BLUE}OpenAI API Setup${NC}"
	echo ""
	echo "1. Get API key: https://platform.openai.com/api-keys"
	echo "2. Store key:"
	echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set OPENAI_API_KEY \"sk-...\""
	echo "3. Restart terminal or: source ~/.config/aidevops/credentials.sh"
	return 0
}

_guide_anthropic() {
	echo -e "${BLUE}Anthropic API Setup${NC}"
	echo ""
	echo "1. Get API key: https://console.anthropic.com/settings/keys"
	echo "2. Store key:"
	echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set ANTHROPIC_API_KEY \"sk-ant-...\""
	echo "3. Restart terminal or: source ~/.config/aidevops/credentials.sh"
	return 0
}

_guide_hetzner() {
	echo -e "${BLUE}Hetzner Cloud Setup${NC}"
	echo ""
	echo "1. Create account: https://www.hetzner.com/cloud"
	echo "2. Go to: Security -> API Tokens"
	echo "3. Generate token with Read & Write permissions"
	echo "4. Store token:"
	echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set HCLOUD_TOKEN_MAIN \"your-token\""
	return 0
}

_guide_cloudflare() {
	echo -e "${BLUE}Cloudflare Setup${NC}"
	echo ""
	echo "1. Create account: https://cloudflare.com"
	echo "2. Go to: My Profile -> API Tokens"
	echo "3. Create token with Zone:Read, DNS:Edit permissions"
	echo "4. Store token:"
	echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set CLOUDFLARE_API_TOKEN \"your-token\""
	return 0
}

_guide_dataforseo() {
	echo -e "${BLUE}DataForSEO Setup${NC}"
	echo ""
	echo "1. Create account: https://app.dataforseo.com"
	echo "2. Go to: API Access"
	echo "3. Store credentials:"
	echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_USERNAME \"your-email\""
	echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_PASSWORD \"your-password\""
	return 0
}

_guide_sonarcloud() {
	echo -e "${BLUE}SonarCloud Setup${NC}"
	echo ""
	echo "1. Create account: https://sonarcloud.io"
	echo "2. Go to: My Account -> Security"
	echo "3. Generate token"
	echo "4. Store token:"
	echo "   ~/.aidevops/agents/scripts/setup-local-api-keys.sh set SONAR_TOKEN \"your-token\""
	return 0
}

_guide_openclaw() {
	echo -e "${BLUE}OpenClaw Setup${NC}"
	echo ""
	echo "1. Install: curl -fsSL https://openclaw.ai/install.sh | bash"
	echo "2. Run onboarding: openclaw onboard --install-daemon"
	echo "3. Connect a channel (e.g., WhatsApp): openclaw channels login"
	echo "4. Security audit: openclaw security audit --fix"
	echo "5. Verify: openclaw doctor"
	echo ""
	echo "Docs: https://docs.openclaw.ai/start/getting-started"
	return 0
}

_guide_tailscale() {
	echo -e "${BLUE}Tailscale Setup${NC}"
	echo ""
	echo "1. Install:"
	echo "   macOS: brew install tailscale"
	echo "   Linux: curl -fsSL https://tailscale.com/install.sh | sh"
	echo "2. Start daemon:"
	echo "   macOS: sudo tailscaled &"
	echo "   Linux: sudo systemctl enable --now tailscaled"
	echo "3. Authenticate: tailscale up"
	echo "4. Verify: tailscale status"
	echo ""
	echo "Free tier: 100 devices, 3 users"
	echo "Docs: https://tailscale.com/kb"
	return 0
}

_guide_orbstack() {
	echo -e "${BLUE}OrbStack Setup${NC}"
	echo ""
	echo "1. Install: brew install orbstack"
	echo "2. Start: orb start (or open OrbStack.app)"
	echo "3. Verify: orb status && docker --version"
	echo ""
	echo "OrbStack replaces Docker Desktop with better performance."
	echo "All docker and docker compose commands work as normal."
	echo "Docs: https://docs.orbstack.dev"
	return 0
}

_guide_orchestration() {
	echo -e "${BLUE}Autonomous Orchestration Setup${NC}"
	echo ""
	echo "Orchestration lets aidevops work autonomously — dispatching AI workers,"
	echo "merging PRs, evaluating results, and self-improving."
	echo ""
	echo "1. Enable supervisor pulse (every 2 min):"
	echo "   aidevops pulse start"
	echo ""
	echo "2. Add tasks with auto-dispatch tag in TODO.md:"
	echo "   - [ ] t001 Implement feature X #auto-dispatch ~2h"
	echo ""
	echo "3. Monitor progress:"
	echo "   aidevops pulse status"
	echo ""
	echo "Features included:"
	echo "  - Worker dispatch: launches AI workers for tagged tasks"
	echo "  - Auto-pickup: claims tasks across all repos in repos.json"
	echo "  - Cross-repo visibility: manages issues/PRs across repos"
	echo "  - Strategic review: 4-hourly thinking-tier queue health analysis"
	echo "  - Model routing: cost-aware simple, standard, and thinking tiers"
	echo "  - Budget tracking: per-provider spend limits"
	echo "  - Circuit breaker: pauses on consecutive failures"
	echo "  - Session miner: extracts learning from past sessions"
	echo ""
	echo "Docs: ~/.aidevops/agents/reference/orchestration.md"
	return 0
}

# Show setup guide for a specific service
show_guide() {
	local service="${1:-}"

	echo ""

	case "$service" in
	github | gh) _guide_github ;;
	openai) _guide_openai ;;
	anthropic) _guide_anthropic ;;
	hetzner) _guide_hetzner ;;
	cloudflare) _guide_cloudflare ;;
	dataforseo) _guide_dataforseo ;;
	sonarcloud | sonar) _guide_sonarcloud ;;
	openclaw) _guide_openclaw ;;
	tailscale) _guide_tailscale ;;
	orbstack | orb) _guide_orbstack ;;
	orchestration | supervisor | pulse) _guide_orchestration ;;
	*)
		echo "Available guides: github, openai, anthropic, hetzner, cloudflare,"
		echo "                  dataforseo, augment, sonarcloud, openclaw,"
		echo "                  tailscale, orbstack, orchestration"
		echo ""
		echo "Usage: $0 guide <service>"
		;;
	esac

	echo ""
	return 0
}

# Save user's work type to settings.json (called by AI agent during onboarding)
save_work_type() {
	local work_type="$1"

	_ensure_settings
	_set_setting "user.work_type" "$work_type"
	echo "Saved work type: $work_type"
	return 0
}

# Save user's familiar concepts to settings.json (called by AI agent during onboarding)
save_concepts() {
	local concepts="$1"

	_ensure_settings

	# Accept comma-separated list or JSON array
	if [[ "$concepts" == \[* ]]; then
		_set_setting "user.familiar_concepts" "$concepts"
	else
		# Convert comma-separated to JSON array
		local json_array
		json_array=$(jq -n --arg concepts "$concepts" '$concepts | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))')
		_set_setting "user.familiar_concepts" "$json_array"
	fi
	echo "Saved familiar concepts"
	return 0
}

# Save orchestration preference to settings.json
save_orchestration() {
	local enabled="$1"

	_ensure_settings
	_set_setting "orchestration.enabled" "$enabled"
	echo "Saved orchestration.enabled: $enabled"
	return 0
}

# Show current settings summary
show_settings() {
	_ensure_settings

	echo ""
	echo -e "${BLUE}Current Settings${NC}"
	echo "================"
	echo ""

	if [[ -x "$SETTINGS_HELPER" ]]; then
		bash "$SETTINGS_HELPER" list
	else
		echo "Settings helper not found. Settings file: $SETTINGS_FILE"
		if [[ -f "$SETTINGS_FILE" ]]; then
			jq '.' "$SETTINGS_FILE" || cat "$SETTINGS_FILE"
		else
			echo "(not created yet — run /onboarding)"
		fi
	fi
	return 0
}

# Show help
show_help() {
	echo "Onboarding Helper - Interactive setup and service status for aidevops"
	echo ""
	echo "Usage: $0 [command] [args]"
	echo ""
	echo "Commands:"
	echo "  status              - Show all services and their configuration status (default)"
	echo "  recommend [type]    - Get personalized recommendations"
	echo "                        Types: web, devops, seo, wordpress, or leave blank"
	echo "  guide <service>     - Show setup guide for a specific service"
	echo "                        Services: github, openai, anthropic, hetzner, cloudflare,"
	echo "                                  dataforseo, augment, sonarcloud, openclaw,"
	echo "                                  tailscale, orbstack, orchestration"
	echo "  configure-dirs      - Interactively add git parent directories for repo-sync"
	echo "  settings            - Show current settings from settings.json"
	echo "  save-work-type <t>  - Save work type (web, devops, seo, wordpress)"
	echo "  save-concepts <c>   - Save familiar concepts (comma-separated or JSON array)"
	echo "  save-orchestration  - Save orchestration enabled/disabled (true/false)"
	echo "  json                - Output status as JSON for programmatic use"
	echo "  help                - Show this help message"
	echo ""
	echo "Examples:"
	echo "  $0 status"
	echo "  $0 recommend devops"
	echo "  $0 guide openai"
	echo "  $0 configure-dirs"
	echo "  $0 save-work-type devops"
	echo "  $0 save-concepts 'git,terminal,api-keys'"
	echo "  $0 settings"
	echo ""
	echo "Settings file: $SETTINGS_FILE"
	echo "Use /onboarding in Claude Code for the full interactive experience."
	return 0
}

# JSON fragment helpers — one function per category (keeps output_json() under 30 lines)

_json_ai_providers() {
	local openai anthropic
	is_configured "OPENAI_API_KEY" && openai=true || openai=false
	is_configured "ANTHROPIC_API_KEY" && anthropic=true || anthropic=false
	jq -n --argjson oa "$openai" --argjson an "$anthropic" \
		'{"ai_providers":{"openai":{"configured":$oa},"anthropic":{"configured":$an}}}'
	return 0
}

_json_git_platforms() {
	local gh_inst gh_auth glab_inst glab_auth
	is_installed "gh" && gh_inst=true || gh_inst=false
	is_cli_authenticated "gh" && gh_auth=true || gh_auth=false
	is_installed "glab" && glab_inst=true || glab_inst=false
	is_cli_authenticated "glab" && glab_auth=true || glab_auth=false
	jq -n \
		--argjson gi "$gh_inst" --argjson ga "$gh_auth" \
		--argjson li "$glab_inst" --argjson la "$glab_auth" \
		'{"git_platforms":{"github":{"installed":$gi,"authenticated":$ga},"gitlab":{"installed":$li,"authenticated":$la}}}'
	return 0
}

_json_hosting() {
	local cf coolify vercel
	is_configured "CLOUDFLARE_API_TOKEN" && cf=true || cf=false
	is_configured "COOLIFY_API_TOKEN" && coolify=true || coolify=false
	is_configured "VERCEL_TOKEN" && vercel=true || vercel=false
	jq -n --argjson cf "$cf" --argjson co "$coolify" --argjson ve "$vercel" \
		'{"hosting":{"cloudflare":{"configured":$cf},"coolify":{"configured":$co},"vercel":{"configured":$ve}}}'
	return 0
}

_json_code_quality() {
	local sonar codacy coderabbit
	is_configured "SONAR_TOKEN" && sonar=true || sonar=false
	is_configured "CODACY_PROJECT_TOKEN" && codacy=true || codacy=false
	{ [[ -f "$CODERABBIT_KEY_FILE" ]] || is_configured "CODERABBIT_API_KEY"; } && coderabbit=true || coderabbit=false
	jq -n --argjson so "$sonar" --argjson co "$codacy" --argjson cr "$coderabbit" \
		'{"code_quality":{"sonarcloud":{"configured":$so},"codacy":{"configured":$co},"coderabbit":{"configured":$cr}}}'
	return 0
}

_json_seo() {
	local dfs serper
	{ is_configured "DATAFORSEO_USERNAME" && is_configured "DATAFORSEO_PASSWORD"; } && dfs=true || dfs=false
	is_configured "SERPER_API_KEY" && serper=true || serper=false
	jq -n --argjson df "$dfs" --argjson se "$serper" \
		'{"seo":{"dataforseo":{"configured":$df},"serper":{"configured":$se}}}'
	return 0
}

_json_context() {
	local sqlite_inst sqlite_fts5
	sqlite_inst=false
	sqlite_fts5=false
	if is_installed "sqlite3"; then
		sqlite_inst=true
		sqlite3 :memory: 'CREATE VIRTUAL TABLE t USING fts5(content);' &>/dev/null && sqlite_fts5=true
	fi
	jq -n \
		--argjson si "$sqlite_inst" --argjson sf "$sqlite_fts5" \
		'{"context":{"sqlite3":{"installed":$si,"fts5":$sf}}}'
	return 0
}

_json_containers() {
	local orb dk
	is_installed "orb" && orb=true || orb=false
	is_installed "docker" && dk=true || dk=false
	jq -n --argjson or "$orb" --argjson dk "$dk" \
		'{"containers":{"orbstack":{"installed":$or},"docker":{"installed":$dk}}}'
	return 0
}

_json_networking() {
	local ts_inst ts_conn
	is_installed "tailscale" && ts_inst=true || ts_inst=false
	tailscale status &>/dev/null 2>&1 && ts_conn=true || ts_conn=false
	jq -n --argjson ti "$ts_inst" --argjson tc "$ts_conn" \
		'{"networking":{"tailscale":{"installed":$ti,"connected":$tc}}}'
	return 0
}

_json_orchestration() {
	local pulse
	pulse=false
	if launchctl list 2>/dev/null | grep -qF "com.aidevops.aidevops-supervisor-pulse" ||
		launchctl list 2>/dev/null | grep -qF "com.aidevops.supervisor-pulse" ||
		crontab -l 2>/dev/null | grep -qF "aidevops-supervisor-pulse"; then
		pulse=true
	fi
	jq -n --argjson pu "$pulse" '{"orchestration":{"supervisor_pulse":$pu}}'
	return 0
}

_json_openclaw() {
	local inst cfg
	is_installed "openclaw" && inst=true || inst=false
	[[ -f "$HOME/.openclaw/openclaw.json" ]] && cfg=true || cfg=false
	jq -n --argjson in "$inst" --argjson cf "$cfg" \
		'{"openclaw":{"installed":$in,"config_exists":$cf}}'
	return 0
}

# Output status as JSON
output_json() {
	jq -s 'reduce .[] as $item ({}; . * $item)' \
		<(_json_ai_providers) \
		<(_json_git_platforms) \
		<(_json_hosting) \
		<(_json_code_quality) \
		<(_json_seo) \
		<(_json_context) \
		<(_json_containers) \
		<(_json_networking) \
		<(_json_orchestration) \
		<(_json_openclaw)
	return 0
}

# Main
main() {
	local command="${1:-status}"
	local arg="${2:-}"

	# Ensure settings.json exists on any invocation
	_ensure_settings

	case "$command" in
	status)
		show_status
		;;
	recommend | recommendations)
		# If no arg, try to use saved work_type from settings
		if [[ -z "$arg" ]]; then
			local saved_type
			saved_type=$(_get_setting "user.work_type")
			if [[ "$saved_type" != "null" && -n "$saved_type" ]]; then
				arg="$saved_type"
			fi
		fi
		show_recommendations "$arg"
		;;
	guide | setup)
		show_guide "$arg"
		;;
	json)
		output_json
		;;
	configure-dirs | dirs)
		configure_dirs
		;;
	settings)
		show_settings
		;;
	save-work-type)
		if [[ -z "$arg" ]]; then
			print_error "Usage: $0 save-work-type <web|devops|seo|wordpress>"
			return 1
		fi
		save_work_type "$arg"
		;;
	save-concepts)
		if [[ -z "$arg" ]]; then
			print_error "Usage: $0 save-concepts <comma-separated or JSON array>"
			return 1
		fi
		save_concepts "$arg"
		;;
	save-orchestration)
		if [[ -z "$arg" ]]; then
			print_error "Usage: $0 save-orchestration <true|false>"
			return 1
		fi
		save_orchestration "$arg"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo "Unknown command: $command"
		echo "Use '$0 help' for usage information"
		return 1
		;;
	esac

	return 0
}

main "$@"
