#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016,SC1091

# 🚀 Advanced MCP Integrations Setup Script
# Sets up powerful Model Context Protocol integrations for AI-assisted development

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit
TEMPLATE_DIR="${REPO_ROOT}/configs/mcp-templates"

# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

print_header() {
	local msg="$1"
	echo -e "${PURPLE}$msg${NC}"
	return 0
}
# Available MCP integrations
get_mcp_command() {
	local integration="$1"
	case "$integration" in
	"chrome-devtools") echo "npx chrome-devtools-mcp@latest" ;;
	"playwright") echo "npx -y @playwright/mcp@0.0.79 --headless --isolated" ;;
	"cloudflare-browser") echo "npx cloudflare-browser-rendering-mcp@latest" ;;
	"ahrefs") echo "npx -y @ahrefs/mcp@latest" ;;
	"perplexity") echo "npx perplexity-mcp@latest" ;;
	"nextjs-devtools") echo "npx next-devtools-mcp@latest" ;;
	"google-search-console") echo "npx mcp-server-gsc@latest" ;;
	"pagespeed-insights") echo "npx mcp-pagespeed-server@latest" ;;
	"claude-code-mcp") echo "npx -y github:marcusquinn/claude-code-mcp" ;;
	"stagehand") echo "node ${HOME}/.aidevops/stagehand/examples/basic-example.js" ;;
	"stagehand-python") echo "${HOME}/.aidevops/stagehand-python/.venv/bin/python ${HOME}/.aidevops/stagehand-python/examples/basic_example.py" ;;
	"stagehand-both") echo "both" ;;
	"dataforseo") echo "npx dataforseo-mcp-server" ;;
	# serper - REMOVED: Uses curl subagent (.agents/seo/serper.md), no MCP needed
	"unstract") echo "docker:unstract/mcp-server" ;;
	"context7") echo "npx -y @upstash/context7-mcp@latest" ;;
	"shopify-dev-mcp") echo "npx -y @shopify/dev-mcp@latest" ;;
	*) echo "" ;;
	esac
	return 0
}

# Available integrations list
MCP_LIST=(
	"chrome-devtools"
	"playwright"
	"cloudflare-browser"
	"ahrefs"
	"perplexity"
	"nextjs-devtools"
	"google-search-console"
	"pagespeed-insights"
	"claude-code-mcp"
	"stagehand"
	"stagehand-python"
	"stagehand-both"
	"dataforseo"
	"unstract"
	"context7"
	"shopify-dev-mcp"
)

is_known_mcp() {
	local candidate="$1"
	local mcp

	for mcp in "${MCP_LIST[@]}"; do
		if [[ "$mcp" == "$candidate" ]]; then
			return 0
		fi
	done

	return 1
}

show_usage() {
	local script_name
	script_name="$(basename "$0")"

	printf 'Usage: %s [integration_name|all|templates]\n' "$script_name"
	printf '\nAvailable MCP integrations:\n'
	for mcp in "${MCP_LIST[@]}"; do
		printf '  - %s\n' "$mcp"
	done
	printf '\nCommands:\n'
	printf '  all        Install all MCP integrations\n'
	printf '  templates  Generate configuration templates in %s\n' "$TEMPLATE_DIR"
	printf '  help       Show this help (also --help or -h)\n'
	printf '\nExamples:\n'
	printf '  %s chrome-devtools\n' "$script_name"
	printf '  %s all\n' "$script_name"
	printf '  %s templates\n' "$script_name"
	return 0
}

# Check prerequisites
check_prerequisites() {
	print_header "Checking Prerequisites"

	# Check Node.js
	if ! command -v node &>/dev/null; then
		print_error "Node.js is required but not installed"
		print_info "Install Node.js from: https://nodejs.org/"
		exit 1
	fi

	local node_version
	node_version=$(node --version | cut -d'v' -f2)
	print_success "Node.js version: $node_version"

	# Check npm
	if ! command -v npm &>/dev/null; then
		print_error "npm is required but not installed"
		exit 1
	fi

	local npm_version
	npm_version=$(npm --version)
	print_success "npm version: $npm_version"

	# Check if Claude Desktop is available
	if command -v claude &>/dev/null; then
		print_success "Claude Desktop CLI detected"
	else
		print_warning "Claude Desktop CLI not found - manual configuration will be needed"
	fi

	return 0
}

# Print MCP security warning
print_mcp_security_warning() {
	echo ""
	print_warning "SECURITY: MCP servers run as persistent processes with access to your"
	print_warning "conversation context, credentials, and network. Before installing:"
	print_info "  1. Verify the source repository and maintainer reputation"
	print_info "  2. Scan dependencies: npx @socketsecurity/cli npm info <package>"
	print_info "  3. Use scoped API keys with minimal permissions"
	print_info "  4. Pin versions -- avoid @latest in production configs"
	print_info "  See: ~/.aidevops/.agents/tools/mcp-toolkit/mcporter.md 'Security Considerations'"
	echo ""
	return 0
}

# --- Per-integration install helpers ---

_install_chrome_devtools() {
	local mcp_command="$1"
	print_info "Setting up Chrome DevTools MCP with advanced configuration..."
	if command -v claude &>/dev/null; then
		claude mcp add chrome-devtools "$mcp_command" --channel=canary --headless=true
	fi
	return 0
}

_install_playwright() {
	print_info "Installing Playwright browsers..."
	npx playwright install
	if command -v claude &>/dev/null; then
		claude mcp add playwright -- npx -y @playwright/mcp@0.0.79 --headless --isolated
	fi
	return 0
}

_install_cloudflare_browser() {
	print_warning "Cloudflare Browser Rendering requires API credentials"
	print_info "Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN environment variables"
	return 0
}

_install_ahrefs() {
	print_warning "Ahrefs MCP requires API key"
	print_info "Get your standard 40-char API key from: https://ahrefs.com/api"
	print_info "Note: JWT-style tokens do NOT work - use the standard API key"
	echo ""
	print_info "Store in ~/.config/aidevops/credentials.sh:"
	print_info "  export AHREFS_API_KEY=\"your_40_char_key\""
	echo ""
	print_info "For OpenCode, use bash wrapper pattern in opencode.json:"
	print_info '  "ahrefs": {'
	print_info '    "type": "local",'
	print_info '    "command": ["/bin/bash", "-c", "API_KEY=\$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],'
	print_info '    "enabled": true'
	print_info '  }'
	echo ""
	print_info "Note: The MCP expects API_KEY env var, not AHREFS_API_KEY"
	return 0
}

_install_perplexity() {
	print_warning "Perplexity MCP requires API key"
	print_info "Set PERPLEXITY_API_KEY environment variable"
	print_info "Get your API key from: https://docs.perplexity.ai/"
	return 0
}

_install_nextjs_devtools() {
	local mcp_command="$1"
	print_info "Setting up Next.js DevTools MCP..."
	if command -v claude &>/dev/null; then
		claude mcp add nextjs-devtools "$mcp_command"
	fi
	return 0
}

_install_google_search_console() {
	local mcp_command="$1"
	print_warning "Google Search Console MCP requires Google API credentials"
	print_info "Set GOOGLE_APPLICATION_CREDENTIALS environment variable"
	print_info "Get credentials from: https://console.cloud.google.com/"
	print_info "Enable Search Console API in your Google Cloud project"
	if command -v claude &>/dev/null; then
		claude mcp add google-search-console "$mcp_command"
	fi
	return 0
}

_install_pagespeed_insights() {
	local mcp_command="$1"
	print_info "Setting up PageSpeed Insights MCP for website performance auditing..."
	print_warning "Optional: Set GOOGLE_API_KEY for higher rate limits"
	print_info "Get API key from: https://console.cloud.google.com/"
	print_info "Enable PageSpeed Insights API in your Google Cloud project"
	print_info "Also installing Lighthouse CLI for comprehensive auditing..."

	# Install Lighthouse CLI if not present
	# Use --ignore-scripts to prevent execution of postinstall scripts for security
	if ! command -v lighthouse &>/dev/null; then
		npm install -g --ignore-scripts lighthouse
	fi

	if command -v claude &>/dev/null; then
		claude mcp add pagespeed-insights "$mcp_command"
	fi

	print_success "PageSpeed Insights MCP setup complete!"
	print_info "Use: ./.agents/scripts/pagespeed-helper.sh for CLI access"
	return 0
}

_install_claude_code_mcp() {
	local mcp_command="$1"
	print_info "Setting up Claude Code MCP (forked) for Claude Code automation..."
	print_info "Source: https://github.com/marcusquinn/claude-code-mcp"
	print_info "Upstream: https://github.com/steipete/claude-code-mcp (revert if merged)"
	print_warning "Requires Claude Code and prior acceptance of --dangerously-skip-permissions"
	print_info "One-time setup: claude --dangerously-skip-permissions"
	if command -v claude &>/dev/null; then
		claude mcp add claude-code-mcp "$mcp_command"
	fi
	print_success "Claude Code MCP setup complete!"
	print_info "Use 'claude_code' tool to run Claude Code tasks"
	return 0
}

_install_stagehand() {
	print_info "Setting up Stagehand AI Browser Automation MCP integration..."

	# First ensure Stagehand JavaScript is installed
	if ! bash "${SCRIPT_DIR}/../../.agents/scripts/stagehand-helper.sh" status &>/dev/null; then
		print_info "Installing Stagehand JavaScript first..."
		bash "${SCRIPT_DIR}/../../.agents/scripts/stagehand-helper.sh" install
	fi

	# Setup advanced configuration
	bash "${SCRIPT_DIR}/stagehand-setup.sh" setup

	# Add to Claude MCP if available
	if command -v claude &>/dev/null; then
		claude mcp add stagehand "node" --args "${HOME}/.aidevops/stagehand/examples/basic-example.js"
	fi

	print_success "Stagehand JavaScript MCP integration completed"
	print_info "Try: 'Ask Claude to help with browser automation using Stagehand'"
	print_info "Use: ./.agents/scripts/stagehand-helper.sh for CLI access"
	return 0
}

_install_stagehand_python() {
	print_info "Setting up Stagehand Python AI Browser Automation MCP integration..."

	# First ensure Stagehand Python is installed
	if ! bash "${SCRIPT_DIR}/../../.agents/scripts/stagehand-python-helper.sh" status &>/dev/null; then
		print_info "Installing Stagehand Python first..."
		bash "${SCRIPT_DIR}/../../.agents/scripts/stagehand-python-helper.sh" install
	fi

	# Setup advanced configuration
	bash "${SCRIPT_DIR}/stagehand-python-setup.sh" setup

	# Add to Claude MCP if available
	if command -v claude &>/dev/null; then
		local python_path="${HOME}/.aidevops/stagehand-python/.venv/bin/python"
		claude mcp add stagehand-python "$python_path" --args "${HOME}/.aidevops/stagehand-python/examples/basic_example.py"
	fi

	print_success "Stagehand Python MCP integration completed"
	print_info "Try: 'Ask Claude to help with Python browser automation using Stagehand'"
	print_info "Use: ./.agents/scripts/stagehand-python-helper.sh for CLI access"
	return 0
}

_install_stagehand_both() {
	print_info "Setting up both Stagehand JavaScript and Python MCP integrations..."

	# Setup JavaScript version
	bash "$0" stagehand

	# Setup Python version
	bash "$0" stagehand-python

	print_success "Both Stagehand integrations completed"
	print_info "JavaScript: ./.agents/scripts/stagehand-helper.sh"
	print_info "Python: ./.agents/scripts/stagehand-python-helper.sh"
	return 0
}

_install_dataforseo() {
	print_info "Setting up DataForSEO MCP for comprehensive SEO data..."
	print_warning "DataForSEO MCP requires API credentials"
	print_info "Get credentials from: https://app.dataforseo.com/"
	echo ""
	print_info "Store in ~/.config/aidevops/credentials.sh:"
	print_info "  export DATAFORSEO_USERNAME=\"your_username\""
	print_info "  export DATAFORSEO_PASSWORD=\"your_password\""
	echo ""
	print_info "Or use the helper script:"
	print_info "  bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_USERNAME your_username"
	print_info "  bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_PASSWORD your_password"
	echo ""
	print_info "For OpenCode, use bash wrapper pattern in opencode.json:"
	print_info '  "dataforseo": {'
	print_info '    "type": "local",'
	print_info '    "command": ["/bin/bash", "-c", "source ~/.config/aidevops/credentials.sh && DATAFORSEO_USERNAME=\$DATAFORSEO_USERNAME DATAFORSEO_PASSWORD=\$DATAFORSEO_PASSWORD npx dataforseo-mcp-server"],'
	print_info '    "enabled": true'
	print_info '  }'
	echo ""
	print_info "Available modules: SERP, KEYWORDS_DATA, BACKLINKS, ONPAGE, DATAFORSEO_LABS, BUSINESS_DATA, DOMAIN_ANALYTICS, CONTENT_ANALYSIS, AI_OPTIMIZATION"
	print_info "Docs: https://docs.dataforseo.com/v3/"
	return 0
}

_install_unstract() {
	print_info "Setting up Unstract self-hosted document processing platform..."
	print_info "This installs the full Unstract platform locally via Docker Compose"
	print_info "Requirements: Docker, Docker Compose, Git, 8GB RAM"
	echo

	# Run the helper script for installation
	local helper_script="${SCRIPT_DIR}/unstract-helper.sh"
	if [[ -f "$helper_script" ]]; then
		bash "$helper_script" install
	else
		print_error "unstract-helper.sh not found at ${helper_script}"
		print_info "Manual install:"
		print_info "  git clone https://github.com/Zipstack/unstract.git ~/.aidevops/unstract"
		print_info "  cd ~/.aidevops/unstract && ./run-platform.sh"
		return 1
	fi

	echo
	print_info "Your existing LLM API keys can be used as Unstract adapters:"
	print_info "  Run: unstract-helper.sh configure-llm"
	echo ""
	print_info "The MCP connects to your local instance by default."
	print_info "Config template: configs/mcp-templates/unstract.json"
	return 0
}

_install_context7() {
	print_info "Setting up Context7 MCP for real-time library documentation..."
	print_info "Context7 provides up-to-date docs for libraries and frameworks."
	echo ""
	print_info "Two setup options:"
	echo ""
	print_info "  1. Remote MCP (recommended — zero install):"
	print_info '     "context7": {'
	print_info '       "type": "remote",'
	print_info '       "url": "https://mcp.context7.com/mcp",'
	print_info '       "enabled": true'
	print_info '     }'
	echo ""
	print_info "  2. Local MCP (via npx):"
	print_info '     "context7": {'
	print_info '       "type": "local",'
	print_info '       "command": ["npx", "-y", "@upstash/context7-mcp@latest"],'
	print_info '       "enabled": true'
	print_info '     }'
	echo ""
	print_info "Disable telemetry: export CTX7_TELEMETRY_DISABLED=1"
	print_info "CLI alternative: npx ctx7 setup --opencode --cli"
	print_info "Docs: ~/.aidevops/agents/tools/context/context7.md"
	return 0
}

_install_shopify_dev_mcp() {
	print_info "Setting up Shopify Dev MCP for schema-aware GraphQL, Liquid validation, and Admin API..."
	print_warning "Prerequisites: Node 18+, Shopify CLI 3.93.0+"
	print_info "Install Shopify CLI: npm install -g @shopify/cli@latest"
	print_info "Verify: shopify version"
	echo ""
	print_info "Auth: shopify store auth (browser-based OAuth, no stored tokens)"
	echo ""
	print_info "The MCP is registered as disabled globally in opencode.json."
	print_info "Enable it per-session by invoking the @shopify agent."
	echo ""
	print_info "OpenCode config (added to ~/.config/opencode/opencode.json):"
	print_info '  "shopify-dev-mcp": {'
	print_info '    "type": "local",'
	print_info '    "command": ["npx", "-y", "@shopify/dev-mcp@latest"],'
	print_info '    "enabled": false'
	print_info '  }'
	echo ""
	print_info "Global tools entry (added to opencode.json tools section):"
	print_info '  "shopify-dev-mcp_*": false'
	echo ""
	print_info "Per-repo skills (install at repo level, not framework level):"
	print_info "  npx @shopify/shopify-ai-toolkit@latest add shopify-admin"
	print_info "  npx @shopify/shopify-ai-toolkit@latest add shopify-liquid"
	echo ""
	print_info "Docs: ~/.aidevops/agents/services/ecommerce/shopify.md"
	print_info "Config template: ~/.aidevops/agents/configs/mcp-templates/shopify-dev-mcp-config.json.txt"
	return 0
}

# Install specific MCP integration — thin dispatcher to per-integration helpers
install_mcp() {
	local mcp_name="$1"
	local mcp_command
	mcp_command=$(get_mcp_command "$mcp_name")

	if ! is_known_mcp "$mcp_name"; then
		print_error "Unknown MCP integration: $mcp_name"
		return 1
	fi

	print_mcp_security_warning
	print_info "Installing $mcp_name MCP..."

	case "$mcp_name" in
	"chrome-devtools") _install_chrome_devtools "$mcp_command" ;;
	"playwright") _install_playwright ;;
	"cloudflare-browser") _install_cloudflare_browser ;;
	"ahrefs") _install_ahrefs ;;
	"perplexity") _install_perplexity ;;
	"nextjs-devtools") _install_nextjs_devtools "$mcp_command" ;;
	"google-search-console") _install_google_search_console "$mcp_command" ;;
	"pagespeed-insights") _install_pagespeed_insights "$mcp_command" ;;
	"claude-code-mcp") _install_claude_code_mcp "$mcp_command" ;;
	"stagehand") _install_stagehand ;;
	"stagehand-python") _install_stagehand_python ;;
	"stagehand-both") _install_stagehand_both ;;
	"dataforseo") _install_dataforseo ;;
	# serper - REMOVED: Uses curl subagent (.agents/seo/serper.md), no MCP needed
	"unstract") _install_unstract ;;
	"context7") _install_context7 ;;
	"shopify-dev-mcp") _install_shopify_dev_mcp ;;
	*)
		print_error "Unknown MCP integration: $mcp_name"
		print_info "Available integrations: ${MCP_LIST[*]}"
		return 1
		;;
	esac

	print_success "$mcp_name MCP setup completed"
	return 0
}

# Write chrome-devtools MCP config template
_write_chrome_devtools_template() {
	local config_dir="$1"
	cat >"$config_dir/chrome-devtools.json" <<'EOF'
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--channel=canary",
        "--headless=true",
        "--isolated=true",
        "--viewport=1920x1080",
        "--logFile=/tmp/chrome-mcp.log"
      ]
    }
  }
}
EOF
	return 0
}

# Write playwright MCP config template
_write_playwright_template() {
	local config_dir="$1"
	cat >"$config_dir/playwright.json" <<'EOF'
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@0.0.79", "--headless", "--isolated"]
    }
  }
}
EOF
	return 0
}

# Write stagehand JavaScript MCP config template
_write_stagehand_js_template() {
	local config_dir="$1"
	cat >"$config_dir/stagehand.json" <<'EOF'
{
  "mcpServers": {
    "stagehand": {
      "command": "node",
      "args": [
        "-e",
        "const { Stagehand } = require('@browserbasehq/stagehand'); console.log('Stagehand JavaScript AI Browser Automation Ready');"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1",
        "STAGEHAND_HEADLESS": "false"
      }
    }
  }
}
EOF
	return 0
}

# Write stagehand Python MCP config template
_write_stagehand_python_template() {
	local config_dir="$1"
	cat >"$config_dir/stagehand-python.json" <<'EOF'
{
  "mcpServers": {
    "stagehand-python": {
      "command": "python",
      "args": [
        "-c",
        "from stagehand import Stagehand; print('Stagehand Python AI Browser Automation Ready')"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1",
        "STAGEHAND_HEADLESS": "false",
        "PYTHONPATH": "${HOME}/.aidevops/stagehand-python/.venv/lib/python3.11/site-packages"
      }
    }
  }
}
EOF
	return 0
}

# Write combined stagehand (JS + Python) MCP config template
_write_stagehand_both_template() {
	local config_dir="$1"
	cat >"$config_dir/stagehand-both.json" <<'EOF'
{
  "mcpServers": {
    "stagehand-js": {
      "command": "node",
      "args": [
        "-e",
        "const { Stagehand } = require('@browserbasehq/stagehand'); console.log('Stagehand JavaScript Ready');"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1",
        "STAGEHAND_HEADLESS": "false"
      }
    },
    "stagehand-python": {
      "command": "python",
      "args": [
        "-c",
        "from stagehand import Stagehand; print('Stagehand Python Ready')"
      ],
      "env": {
        "STAGEHAND_ENV": "LOCAL",
        "STAGEHAND_VERBOSE": "1",
        "STAGEHAND_HEADLESS": "false",
        "PYTHONPATH": "${HOME}/.aidevops/stagehand-python/.venv/lib/python3.11/site-packages"
      }
    }
  }
}
EOF
	return 0
}

# Create MCP configuration templates
create_config_templates() {
	print_header "Creating MCP Configuration Templates"

	local config_dir="$TEMPLATE_DIR"
	mkdir -p "$config_dir"

	_write_chrome_devtools_template "$config_dir"
	_write_playwright_template "$config_dir"
	_write_stagehand_js_template "$config_dir"
	_write_stagehand_python_template "$config_dir"
	_write_stagehand_both_template "$config_dir"

	print_success "Configuration templates created in $config_dir/"
	return 0
}

# Main setup function
main() {
	local command="${1:-help}"

	case "$command" in
	help | --help | -h)
		show_usage
		return 0
		;;
	templates)
		create_config_templates
		return 0
		;;
	all) ;;
	*)
		if ! is_known_mcp "$command"; then
			print_error "Unknown MCP integration: $command"
			show_usage
			return 1
		fi
		;;
	esac

	print_header "Advanced MCP Integrations Setup"
	echo

	check_prerequisites
	echo

	create_config_templates
	echo

	if [[ "$command" == "all" ]]; then
		print_header "Installing All MCP Integrations"
		for mcp in "${MCP_LIST[@]}"; do
			install_mcp "$mcp"
			echo
		done
	else
		install_mcp "$command"
	fi

	echo
	print_success "MCP integrations setup completed!"
	print_info "Next steps:"
	print_info "1. Configure API keys in your environment"
	print_info "2. Review configuration templates in ${TEMPLATE_DIR}/"
	print_info "3. Test integrations with your AI assistant"
	print_info "4. Check .agents/MCP-INTEGRATIONS.md for usage examples"
	return 0
}

main "$@"
