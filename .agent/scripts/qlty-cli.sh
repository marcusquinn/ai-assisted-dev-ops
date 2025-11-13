#!/bin/bash

# Qlty CLI Integration Script
# Universal linting, auto-formatting, security scanning, and maintainability
# 
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_header() {
    echo -e "${BLUE}🚀 $1${NC}"
    echo "=========================================="
}

# Load API configuration with intelligent credential selection
load_api_config() {
    local org="${1:-marcusquinn}"  # Default to marcusquinn organization
    local api_key_service="qlty-${org}"
    local workspace_id_service="qlty-${org}-workspace-id"
    local account_api_key_service="qlty-account-api-key"

    # Load credentials from secure storage
    if [[ -f "$HOME/.config/aidevops/api-keys" ]]; then
        local org_coverage_token workspace_id account_api_key
        org_coverage_token=$(bash "$(dirname "$0")/setup-local-api-keys.sh" get "$api_key_service" 2>/dev/null)
        workspace_id=$(bash "$(dirname "$0")/setup-local-api-keys.sh" get "$workspace_id_service" 2>/dev/null)
        account_api_key=$(bash "$(dirname "$0")/setup-local-api-keys.sh" get "$account_api_key_service" 2>/dev/null)

        # Intelligent credential selection
        if [[ -n "$account_api_key" ]]; then
            # Prefer account-level API key (broader access)
            export QLTY_API_TOKEN="$account_api_key"
            print_info "Using Qlty Account API Key (account-wide access)"

            if [[ -n "$workspace_id" ]]; then
                export QLTY_WORKSPACE_ID="$workspace_id"
                print_info "Loaded Qlty Workspace ID for organization: $org"
            fi

            if [[ -n "$org_coverage_token" ]]; then
                print_info "Note: Organization Coverage Token available but using Account API Key for broader access"
            fi

            return 0

        elif [[ -n "$org_coverage_token" ]]; then
            # Fall back to organization-specific coverage token
            export QLTY_COVERAGE_TOKEN="$org_coverage_token"
            print_info "Using Qlty Coverage Token for organization: $org"

            if [[ -n "$workspace_id" ]]; then
                export QLTY_WORKSPACE_ID="$workspace_id"
                print_info "Loaded Qlty Workspace ID for organization: $org"
            else
                print_warning "No Qlty Workspace ID found for organization: $org (optional)"
            fi

            return 0

        else
            # No credentials found
            print_warning "No Qlty credentials found for organization: $org"
            print_info "Options:"
            print_info "  Account API Key: bash .agent/scripts/setup-local-api-keys.sh set $account_api_key_service YOUR_API_KEY"
            print_info "  Coverage Token:  bash .agent/scripts/setup-local-api-keys.sh set $api_key_service YOUR_COVERAGE_TOKEN"
            if [[ -z "$workspace_id" ]]; then
                print_info "  Workspace ID:    bash .agent/scripts/setup-local-api-keys.sh set $workspace_id_service YOUR_WORKSPACE_ID"
            fi
            return 1
        fi
    else
        print_error "API key storage not found. Run setup-local-api-keys.sh first."
        return 1
    fi
}

# Install Qlty CLI
install_qlty() {
    print_header "Installing Qlty CLI"

    if command -v qlty &> /dev/null; then
        print_warning "Qlty CLI already installed: $(qlty --version)"
        return 0
    fi

    print_info "Installing Qlty CLI..."

    # Install using the official installer
    if command -v curl &> /dev/null; then
        curl -sSL https://qlty.sh | bash
    else
        print_error "curl is required to install Qlty CLI"
        return 1
    fi

    # Update PATH for current session
    export PATH="$HOME/.qlty/bin:$PATH"

    # Verify installation
    if command -v qlty &> /dev/null; then
        print_success "Qlty CLI installed successfully: $(qlty --version)"
        print_info "PATH updated for current session. Restart shell for permanent access."
        return 0
    else
        print_error "Failed to install Qlty CLI"
        return 1
    fi
}

# Initialize Qlty in repository
init_qlty() {
    print_header "Initializing Qlty in Repository"
    
    if [[ ! -d ".git" ]]; then
        print_error "Not in a Git repository. Qlty requires a Git repository."
        return 1
    fi
    
    if [[ -f ".qlty/qlty.toml" ]]; then
        print_warning "Qlty already initialized (.qlty/qlty.toml exists)"
        return 0
    fi
    
    print_info "Initializing Qlty configuration..."
    qlty init
    
    if [[ -f ".qlty/qlty.toml" ]]; then
        print_success "Qlty initialized successfully"
        print_info "Configuration file created: .qlty/qlty.toml"
        return 0
    else
        print_error "Failed to initialize Qlty"
        return 1
    fi
}

# Run Qlty check (linting)
check_qlty() {
    local sample_size="$1"
    local org="$2"

    print_header "Running Qlty Code Quality Check"

    # Load API configuration
    load_api_config "$org"

    if [[ ! -f ".qlty/qlty.toml" ]]; then
        print_error "Qlty not initialized. Run 'init' first."
        return 1
    fi

    local cmd="qlty check"

    if [[ -n "$sample_size" ]]; then
        cmd="$cmd --sample=$sample_size"
        print_info "Running check with sample size: $sample_size"
    else
        print_info "Running full codebase check"
    fi

    print_info "Executing: $cmd"
    eval "$cmd"

    return $?
}

# Run Qlty auto-formatting
format_qlty() {
    local scope="$1"
    local org="$2"

    print_header "Running Qlty Auto-Formatting"

    # Load API configuration
    load_api_config "$org"

    if [[ ! -f ".qlty/qlty.toml" ]]; then
        print_error "Qlty not initialized. Run 'init' first."
        return 1
    fi

    local cmd="qlty fmt"

    if [[ "$scope" == "--all" ]]; then
        cmd="$cmd --all"
        print_info "Auto-formatting entire codebase"
    else
        print_info "Auto-formatting changed files"
    fi

    print_info "Executing: $cmd"

    if eval "$cmd"; then
        print_success "Auto-formatting completed successfully"
        return 0
    else
        print_error "Auto-formatting failed"
        return 1
    fi
}

# Run Qlty code smells detection
smells_qlty() {
    local scope="$1"
    local org="$2"

    print_header "Running Qlty Code Smells Detection"

    # Load API configuration
    load_api_config "$org"

    if [[ ! -f ".qlty/qlty.toml" ]]; then
        print_error "Qlty not initialized. Run 'init' first."
        return 1
    fi

    local cmd="qlty smells"

    if [[ "$scope" == "--all" ]]; then
        cmd="$cmd --all"
        print_info "Scanning entire codebase for code smells"
    else
        print_info "Scanning changed files for code smells"
    fi

    print_info "Executing: $cmd"
    eval "$cmd"

    return $?
}

# Show help
show_help() {
    echo "Qlty CLI Integration - Universal Code Quality Tool"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  install              - Install Qlty CLI"
    echo "  init                 - Initialize Qlty in repository"
    echo "  check [sample] [org] - Run code quality check (optionally with sample size and organization)"
    echo "  fmt [--all] [org]    - Auto-format code (optionally entire codebase and organization)"
    echo "  smells [--all] [org] - Detect code smells (optionally entire codebase and organization)"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 init"
    echo "  $0 check 5           # Check sample of 5 issues (default: marcusquinn org)"
    echo "  $0 check 5 myorg     # Check sample of 5 issues for 'myorg' organization"
    echo "  $0 fmt --all         # Format entire codebase (default: marcusquinn org)"
    echo "  $0 fmt --all myorg   # Format entire codebase for 'myorg' organization"
    echo "  $0 smells --all      # Scan all files for code smells"
    echo ""
    echo "Features:"
    echo "  🐛 Linting: 70+ tools for 40+ languages"
    echo "  🖌️  Auto-formatting: Consistent code style"
    echo "  💩 Code smells: Duplication and complexity detection"
    echo "  🚨 Security: SAST, SCA, secret detection"
    echo "  ⚡ Performance: Fast, concurrent execution"
    echo ""
    echo "Qlty Credential Management:"
    echo "  Account API Key:       bash .agent/scripts/setup-local-api-keys.sh set qlty-account-api-key API_KEY"
    echo "  Coverage Token:        bash .agent/scripts/setup-local-api-keys.sh set qlty-ORGNAME COVERAGE_TOKEN"
    echo "  Workspace ID:          bash .agent/scripts/setup-local-api-keys.sh set qlty-ORGNAME-workspace-id ID"
    echo "  List configurations:   bash .agent/scripts/setup-local-api-keys.sh list"
    echo "  Default org:           marcusquinn"
    echo ""
    echo "Credential Priority:"
    echo "  1. Account API Key (qltp_...) - Preferred for account-wide access"
    echo "  2. Coverage Token (qltcw_...) - Organization-specific access"
    echo ""
    echo "Current Qlty Configuration:"
    if [[ -f "$HOME/.config/aidevops/api-keys" ]]; then
        # Check for account-level API key
        if grep -q "qlty-account-api-key=" "$HOME/.config/aidevops/api-keys" 2>/dev/null; then
            echo "  🌟 Account API Key: ✅ Configured (account-wide access)"
        else
            echo "  🌟 Account API Key: ❌ Not configured"
        fi

        echo ""
        echo "  Organization-Specific Configurations:"

        # Show organizations with coverage tokens
        local orgs
        orgs=$(grep "qlty-.*=" "$HOME/.config/aidevops/api-keys" 2>/dev/null | grep -v "workspace-id" | grep -v "account-api-key" | cut -d'=' -f1 | sed 's/qlty-//')
        if [[ -n "$orgs" ]]; then
            while IFS= read -r org; do
                local has_workspace=""
                if grep -q "qlty-${org}-workspace-id=" "$HOME/.config/aidevops/api-keys" 2>/dev/null; then
                    has_workspace=" + workspace ID"
                fi
                echo "    - ${org}: Coverage Token${has_workspace}"
            done <<< "$orgs"
        else
            echo "    - None configured"
        fi
    else
        echo "  - Configuration storage not found"
    fi
}

# Main execution
main() {
    local command="$1"
    shift
    
    case "$command" in
        "install")
            install_qlty
            ;;
        "init")
            init_qlty
            ;;
        "check")
            check_qlty "$1" "$2"
            ;;
        "fmt")
            format_qlty "$1" "$2"
            ;;
        "smells")
            smells_qlty "$1" "$2"
            ;;
        "help"|"--help"|"-h"|"")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            return 1
            ;;
    esac
}

main "$@"
