#!/bin/bash

# CodeRabbit CLI Integration Script
# Provides AI-powered code review capabilities through CodeRabbit CLI
#
# This script integrates CodeRabbit CLI into the AI DevOps workflow
# for local code analysis, review automation, and quality assurance.
#
# Usage: ./coderabbit-cli.sh [command] [options]
# Commands:
#   install     - Install CodeRabbit CLI
#   setup       - Configure API key and settings
#   review      - Review current changes
#   analyze     - Analyze specific files or directories
#   status      - Check CodeRabbit CLI status
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.1.1
# License: MIT

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Configuration constants
readonly CODERABBIT_CLI_INSTALL_URL="https://cli.coderabbit.ai/install.sh"
readonly CONFIG_DIR="$HOME/.config/coderabbit"
readonly API_KEY_FILE="$CONFIG_DIR/api_key"

# Print functions
print_success() {
    local message="$1"
    echo -e "${GREEN}✅ $message${NC}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}ℹ️  $message${NC}"
    return 0
}

# Get CodeRabbit reviews from GitHub API
get_coderabbit_reviews() {
    print_header "Fetching CodeRabbit Reviews"

    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        print_warning "GitHub CLI (gh) not found. Install it for API access."
        print_info "Visit: https://cli.github.com/"
        return 1
    fi

    # Get recent PRs with CodeRabbit reviews
    print_info "Fetching recent pull requests with CodeRabbit reviews..."

    local prs
    prs=$(gh pr list --state all --limit 5 --json number,title,state,url)

    if [[ -n "$prs" && "$prs" != "[]" ]]; then
        print_success "Found pull requests with potential CodeRabbit reviews"
        echo "$prs" | jq -r '.[] | "PR #\(.number): \(.title) (\(.state))"'

        # Get reviews for the most recent PR
        local latest_pr
        latest_pr=$(echo "$prs" | jq -r '.[0].number')

        if [[ -n "$latest_pr" && "$latest_pr" != "null" ]]; then
            print_info "Checking reviews for PR #$latest_pr..."

            local reviews
            reviews=$(gh pr view "$latest_pr" --json reviews)

            if [[ -n "$reviews" ]]; then
                local coderabbit_reviews
                coderabbit_reviews=$(echo "$reviews" | jq -r '.reviews[] | select(.author.login == "coderabbitai[bot]") | .body' 2>/dev/null || echo "")

                if [[ -n "$coderabbit_reviews" ]]; then
                    print_success "Found CodeRabbit reviews!"
                    print_info "Review summary available for PR #$latest_pr"
                else
                    print_warning "No CodeRabbit reviews found in recent PRs"
                fi
            fi
        fi
    else
        print_warning "No pull requests found"
    fi

    return 0
}

# Apply CodeRabbit auto-fixes
apply_coderabbit_fixes() {
    print_header "Applying CodeRabbit Auto-Fixes"

    local file="${1:-}"

    if [[ -z "$file" ]]; then
        print_error "Please specify a file to fix"
        print_info "Usage: apply_coderabbit_fixes <file>"
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        print_error "File not found: $file"
        return 1
    fi

    print_info "Applying common CodeRabbit fixes to: $file"

    # Backup original file
    cp "$file" "$file.coderabbit-backup"
    print_info "Created backup: $file.coderabbit-backup"

    # Apply markdown formatting fixes if it's a markdown file
    if [[ "$file" == *.md ]]; then
        print_info "Applying markdown formatting fixes..."

        # Fix heading spacing (add blank line after headings)
        sed -i.tmp '/^#.*$/{
            N
            /\n$/!s/$/\n/
        }' "$file"

        # Fix list spacing (ensure blank lines around lists)
        sed -i.tmp '/^[[:space:]]*[-*+][[:space:]]/{
            i\

        }' "$file"

        rm -f "$file.tmp"
        print_success "Applied markdown formatting fixes"
    fi

    # Apply shell script fixes if it's a shell script
    if [[ "$file" == *.sh ]]; then
        print_info "Applying shell script fixes..."

        # Add return statements to functions (basic implementation)
        awk '
        /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { in_function = 1; function_name = $1 }
        /^}$/ && in_function {
            print "    return 0"
            print $0
            in_function = 0
            next
        }
        { print }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

        print_success "Applied shell script fixes"
    fi

    print_success "CodeRabbit auto-fixes applied to $file"
    print_info "Original backed up as: $file.coderabbit-backup"

    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}"
    return 0
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}🤖 $message${NC}"
    return 0
}

# Check if CodeRabbit CLI is installed
check_cli_installed() {
    if command -v coderabbit &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Install CodeRabbit CLI
install_cli() {
    print_header "Installing CodeRabbit CLI..."
    
    if check_cli_installed; then
        print_info "CodeRabbit CLI is already installed"
        coderabbit --version
        return 0
    fi
    
    print_info "Downloading and installing CodeRabbit CLI..."
    if curl -fsSL "$CODERABBIT_CLI_INSTALL_URL" | sh; then
        print_success "CodeRabbit CLI installed successfully"
        return 0
    else
        print_error "Failed to install CodeRabbit CLI"
        return 1
    fi
}

# Setup API key configuration
setup_api_key() {
    print_header "Setting up CodeRabbit API Key..."
    
    # Check if API key is already configured
    if [[ -f "$API_KEY_FILE" ]]; then
        print_info "API key is already configured"
        print_warning "To reconfigure, delete $API_KEY_FILE and run setup again"
        return 0
    fi
    
    # Create config directory
    mkdir -p "$CONFIG_DIR"
    
    print_info "CodeRabbit API Key Setup"
    echo ""
    print_info "To get your API key:"
    print_info "1. Visit https://app.coderabbit.ai"
    print_info "2. Go to Settings > API Keys"
    print_info "3. Generate a new API key for your organization"
    echo ""
    
    read -r -p "Enter your CodeRabbit API key: " api_key
    
    if [[ -z "$api_key" ]]; then
        print_error "API key cannot be empty"
        return 1
    fi
    
    # Save API key securely
    echo "$api_key" > "$API_KEY_FILE"
    chmod 600 "$API_KEY_FILE"
    
    # Export for current session
    export CODERABBIT_API_KEY="$api_key"
    
    print_success "API key configured successfully"
    return 0
}

# Load API key from configuration
load_api_key() {
    # Try to load API key from unified secure storage first
    local api_key_script
    api_key_script="$(dirname "$0")/setup-local-api-keys.sh"
    if [[ -f "$api_key_script" ]]; then
        local stored_key
        stored_key=$("$api_key_script" get coderabbit 2>/dev/null)
        if [[ -n "$stored_key" ]]; then
            export CODERABBIT_API_KEY="$stored_key"
            print_info "Loaded CodeRabbit API key from secure local storage"
            return 0
        fi
    fi

    # Fallback to legacy storage location
    if [[ -f "$API_KEY_FILE" ]]; then
        local legacy_key
        legacy_key=$(cat "$API_KEY_FILE")
        export CODERABBIT_API_KEY="$legacy_key"
        print_info "Loaded CodeRabbit API key from legacy storage"
        return 0
    else
        print_error "API key not configured"
        print_info "Set up with: bash .agent/scripts/setup-local-api-keys.sh set coderabbit YOUR_API_KEY"
        print_info "Or run: $0 setup"
        return 1
    fi
}

# Review current changes
review_changes() {
    print_header "Reviewing current changes with CodeRabbit..."
    
    if ! check_cli_installed; then
        print_error "CodeRabbit CLI not installed. Run: $0 install"
        return 1
    fi
    
    if ! load_api_key; then
        return 1
    fi
    
    print_info "Analyzing current git changes..."
    if coderabbit review; then
        print_success "Code review completed"
        return 0
    else
        print_error "Code review failed"
        return 1
    fi
}

# Analyze specific files or directories
analyze_code() {
    local target="${1:-.}"
    
    print_header "Analyzing code with CodeRabbit: $target"
    
    if ! check_cli_installed; then
        print_error "CodeRabbit CLI not installed. Run: $0 install"
        return 1
    fi
    
    if ! load_api_key; then
        return 1
    fi
    
    print_info "Running CodeRabbit analysis on: $target"
    if coderabbit analyze "$target"; then
        print_success "Code analysis completed"
        return 0
    else
        print_error "Code analysis failed"
        return 1
    fi
}

# Check CodeRabbit CLI status
check_status() {
    print_header "CodeRabbit CLI Status"

    if check_cli_installed; then
        print_success "CodeRabbit CLI is installed"
        coderabbit --version
    else
        print_warning "CodeRabbit CLI is not installed"
    fi

    if [[ -f "$API_KEY_FILE" ]]; then
        print_success "API key is configured"
    else
        print_warning "API key is not configured"
    fi

    return 0
}

# Show help message
show_help() {
    print_header "CodeRabbit CLI Integration Help"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install     - Install CodeRabbit CLI"
    echo "  setup       - Configure API key and settings"
    echo "  review      - Review current git changes"
    echo "  analyze     - Analyze specific files or directories"
    echo "  status      - Check CodeRabbit CLI status"
    echo "  help        - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 setup"
    echo "  $0 review"
    echo "  $0 analyze providers/"
    echo "  $0 status"
    echo ""
    echo "For more information, visit: https://www.coderabbit.ai/cli"
    return 0
}

# Main function
main() {
    local command="${1:-help}"

    case "$command" in
        "install")
            install_cli
            ;;
        "setup")
            setup_api_key
            ;;
        "review")
            review_changes
            ;;
        "analyze")
            analyze_code "$2"
            ;;
        "status")
            check_status
            ;;
        "reviews")
            get_coderabbit_reviews
            ;;
        "fix")
            apply_coderabbit_fixes "$2"
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"
