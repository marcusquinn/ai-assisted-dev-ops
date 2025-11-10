#!/bin/bash

# 🚀 Advanced MCP Integrations Setup Script
# Sets up powerful Model Context Protocol integrations for AI-assisted development

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

print_header() { echo -e "${PURPLE}🚀 $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Available MCP integrations
get_mcp_command() {
    case "$1" in
        "chrome-devtools") echo "npx chrome-devtools-mcp@latest" ;;
        "playwright") echo "npx playwright-mcp@latest" ;;
        "cloudflare-browser") echo "npx cloudflare-browser-rendering-mcp@latest" ;;
        "ahrefs") echo "npx ahrefs-mcp@latest" ;;
        "perplexity") echo "npx perplexity-mcp@latest" ;;
        "nextjs-devtools") echo "npx next-devtools-mcp@latest" ;;
        "google-search-console") echo "npx mcp-server-gsc@latest" ;;
        "pagespeed-insights") echo "npx mcp-pagespeed-server@latest" ;;
        *) echo "" ;;
    esac
    return 0
}

# Available integrations list
MCP_LIST="chrome-devtools playwright cloudflare-browser ahrefs perplexity nextjs-devtools google-search-console pagespeed-insights"

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check Node.js
    if ! command -v node &> /dev/null; then
        print_error "Node.js is required but not installed"
        print_info "Install Node.js from: https://nodejs.org/"
        exit 1
    fi
    
    local node_version
    node_version=$(node --version | cut -d'v' -f2)
    print_success "Node.js version: $node_version"

    # Check npm
    if ! command -v npm &> /dev/null; then
        print_error "npm is required but not installed"
        exit 1
    fi

    local npm_version
    npm_version=$(npm --version)
    print_success "npm version: $npm_version"

    # Check if Claude Desktop is available
    if command -v claude &> /dev/null; then
        print_success "Claude Desktop CLI detected"
    else
        print_warning "Claude Desktop CLI not found - manual configuration will be needed"
    fi

    return 0
}

# Install specific MCP integration
install_mcp() {
    local mcp_name="$1"
    local mcp_command
    mcp_command=$(get_mcp_command "$mcp_name")

    if [[ -z "$mcp_command" ]]; then
        print_error "Unknown MCP integration: $mcp_name"
        return 1
    fi
    
    print_info "Installing $mcp_name MCP..."
    
    case "$mcp_name" in
        "chrome-devtools")
            print_info "Setting up Chrome DevTools MCP with advanced configuration..."
            if command -v claude &> /dev/null; then
                claude mcp add chrome-devtools "$mcp_command" --channel=canary --headless=true
            fi
            ;;
        "playwright")
            print_info "Installing Playwright browsers..."
            npx playwright install
            if command -v claude &> /dev/null; then
                claude mcp add playwright "$mcp_command"
            fi
            ;;
        "cloudflare-browser")
            print_warning "Cloudflare Browser Rendering requires API credentials"
            print_info "Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN environment variables"
            ;;
        "ahrefs")
            print_warning "Ahrefs MCP requires API key"
            print_info "Set AHREFS_API_KEY environment variable"
            print_info "Get your API key from: https://ahrefs.com/api"
            ;;
        "perplexity")
            print_warning "Perplexity MCP requires API key"
            print_info "Set PERPLEXITY_API_KEY environment variable"
            print_info "Get your API key from: https://docs.perplexity.ai/"
            ;;
        "nextjs-devtools")
            print_info "Setting up Next.js DevTools MCP..."
            if command -v claude &> /dev/null; then
                claude mcp add nextjs-devtools "$mcp_command"
            fi
            ;;
        "google-search-console")
            print_warning "Google Search Console MCP requires Google API credentials"
            print_info "Set GOOGLE_APPLICATION_CREDENTIALS environment variable"
            print_info "Get credentials from: https://console.cloud.google.com/"
            print_info "Enable Search Console API in your Google Cloud project"
            if command -v claude &> /dev/null; then
                claude mcp add google-search-console "$mcp_command"
            fi
            ;;
        "pagespeed-insights")
            print_info "Setting up PageSpeed Insights MCP for website performance auditing..."
            print_warning "Optional: Set GOOGLE_API_KEY for higher rate limits"
            print_info "Get API key from: https://console.cloud.google.com/"
            print_info "Enable PageSpeed Insights API in your Google Cloud project"
            print_info "Also installing Lighthouse CLI for comprehensive auditing..."

            # Install Lighthouse CLI if not present
            if ! command -v lighthouse &> /dev/null; then
                npm install -g lighthouse
            fi

            if command -v claude &> /dev/null; then
                claude mcp add pagespeed-insights "$mcp_command"
            fi

            print_success "PageSpeed Insights MCP setup complete!"
            print_info "Use: ./providers/pagespeed-helper.sh for CLI access"
            ;;
        *)
            print_error "Unknown MCP integration: $mcp_name"
            print_info "Available integrations: $MCP_LIST"
            return 1
            ;;
    esac
    
    print_success "$mcp_name MCP setup completed"
}

# Create MCP configuration templates
create_config_templates() {
    print_header "Creating MCP Configuration Templates"
    
    local config_dir="configs/mcp-templates"
    mkdir -p "$config_dir"
    
    # Chrome DevTools template
    cat > "$config_dir/chrome-devtools.json" << 'EOF'
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

    # Playwright template
    cat > "$config_dir/playwright.json" << 'EOF'
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["playwright-mcp@latest"]
    }
  }
}
EOF

    print_success "Configuration templates created in $config_dir/"
}

# Main setup function
main() {
    local command="${1:-help}"

    print_header "Advanced MCP Integrations Setup"
    echo

    check_prerequisites
    echo

    if [[ $# -eq 0 ]]; then
        print_info "Available MCP integrations:"
        for mcp in $MCP_LIST; do
            echo "  - $mcp"
        done
        echo
        print_info "Usage: $0 [integration_name|all]"
        print_info "Example: $0 chrome-devtools"
        print_info "Example: $0 all"
        exit 0
    fi
    
    create_config_templates
    echo
    
    if [[ "$command" == "all" ]]; then
        print_header "Installing All MCP Integrations"
        for mcp in $MCP_LIST; do
            install_mcp "$mcp"
            echo
        done
    elif [[ "$MCP_LIST" == *"$command"* ]]; then
        install_mcp "$command"
    else
        print_error "Unknown MCP integration: $command"
        print_info "Available integrations: $MCP_LIST"
        exit 1
    fi
    
    echo
    print_success "MCP integrations setup completed!"
    print_info "Next steps:"
    print_info "1. Configure API keys in your environment"
    print_info "2. Review configuration templates in configs/mcp-templates/"
    print_info "3. Test integrations with your AI assistant"
    print_info "4. Check docs/MCP-INTEGRATIONS.md for usage examples"
}

main "$@"
