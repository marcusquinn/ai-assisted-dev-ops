#!/bin/bash

# Codacy CLI v2 Integration Script
# Comprehensive local code analysis with Codacy CLI v2
#
# Usage: ./codacy-cli.sh [command] [options]
# Commands:
#   install     - Install Codacy CLI v2
#   init        - Initialize project configuration
#   analyze     - Run code analysis
#   upload      - Upload SARIF results to Codacy
#   status      - Check CLI status and configuration
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

# Configuration
readonly CODACY_CLI_VERSION="1.0.0-main.361.sha.f961a76"
readonly CODACY_CONFIG_DIR=".codacy"
readonly CODACY_CONFIG_FILE="$CODACY_CONFIG_DIR/codacy.yaml"
readonly CODACY_API_CONFIG="configs/codacy-config.json"
# API token loaded from environment variable CODACY_API_TOKEN

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

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
    return 0
}

# Load API configuration
load_api_config() {
    # Try to load API key from secure local storage first
    local api_key_script="$(dirname "$0")/setup-local-api-keys.sh"
    if [[ -f "$api_key_script" ]]; then
        local stored_key
        stored_key=$("$api_key_script" get codacy 2>/dev/null)
        if [[ -n "$stored_key" ]]; then
            export CODACY_API_TOKEN="$stored_key"
            print_info "Loaded Codacy API key from secure local storage"
        fi
    fi

    if [[ -f "$CODACY_API_CONFIG" ]]; then
        print_info "Loading Codacy API configuration from $CODACY_API_CONFIG"

        # API token should be set in environment variable CODACY_API_TOKEN
        if [[ -z "$CODACY_API_TOKEN" ]]; then
            print_error "CODACY_API_TOKEN not found in environment or secure storage"
            print_info "Set up API key with: bash .agent/scripts/setup-local-api-keys.sh set codacy YOUR_API_KEY"
            return 1
        fi

        # Set organization and repository from config if available
        if command -v jq >/dev/null 2>&1; then
            local org
            org=$(jq -r '.organization // empty' "$CODACY_API_CONFIG" 2>/dev/null)
            local repo
            repo=$(jq -r '.repository // empty' "$CODACY_API_CONFIG" 2>/dev/null)

            if [[ -n "$org" && -n "$repo" ]]; then
                export CODACY_ORGANIZATION="$org"
                export CODACY_REPOSITORY="$repo"
                print_success "Configured for organization: $org, repository: $repo"
            fi
        fi

        return 0
    else
        print_warning "API configuration file not found: $CODACY_API_CONFIG"
        print_info "Using default configuration with environment API token"
        if [[ -z "$CODACY_API_TOKEN" ]]; then
            print_error "CODACY_API_TOKEN environment variable not set"
            return 1
        fi
        return 1
    fi
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}" >&2
    return 0
}

print_header() {
    local message="$1"
    echo -e "${PURPLE}🔍 $message${NC}"
    return 0
}

# Check if Codacy CLI is installed
check_codacy_cli() {
    if command -v codacy-cli &> /dev/null; then
        local version
        version=$(codacy-cli version 2>/dev/null | head -1 || echo "unknown")
        print_success "Codacy CLI installed: $version"
        return 0
    else
        print_warning "Codacy CLI not found"
        return 1
    fi
}

# Install Codacy CLI v2
install_codacy_cli() {
    print_header "Installing Codacy CLI v2"
    
    # Detect platform
    local platform
    case "$(uname -s)" in
        Darwin*)
            platform="macOS"
            if command -v brew &> /dev/null; then
                print_info "Installing via Homebrew..."
                brew install codacy/codacy-cli-v2/codacy-cli-v2
            else
                print_error "Homebrew not found. Please install Homebrew first."
                return 1
            fi
            ;;
        Linux*)
            platform="Linux"
            print_info "Installing via curl script..."
            bash <(curl -Ls https://raw.githubusercontent.com/codacy/codacy-cli-v2/main/codacy-cli.sh)
            ;;
        *)
            print_error "Unsupported platform: $(uname -s)"
            print_info "For Windows, use WSL and follow Linux instructions"
            return 1
            ;;
    esac
    
    # Verify installation
    if check_codacy_cli; then
        print_success "Codacy CLI v2 installed successfully on $platform"
        return 0
    else
        print_error "Installation failed"
        return 1
    fi
}

# Initialize Codacy configuration
init_codacy_config() {
    print_header "Initializing Codacy Configuration"
    
    # Check if API token is provided
    local api_token="${CODACY_API_TOKEN:-}"
    local provider="${CODACY_PROVIDER:-}"
    local organization="${CODACY_ORGANIZATION:-}"
    local repository="${CODACY_REPOSITORY:-}"
    
    if [[ -n "$api_token" && -n "$provider" && -n "$organization" && -n "$repository" ]]; then
        print_info "Initializing with remote configuration from Codacy..."
        codacy-cli init --api-token "$api_token" --provider "$provider" --organization "$organization" --repository "$repository"
    else
        print_info "Initializing with local configuration..."
        print_warning "For remote config, set: CODACY_API_TOKEN, CODACY_PROVIDER, CODACY_ORGANIZATION, CODACY_REPOSITORY"
        codacy-cli init
    fi
    
    if [[ -f "$CODACY_CONFIG_FILE" ]]; then
        print_success "Codacy configuration initialized: $CODACY_CONFIG_FILE"
        return 0
    else
        print_error "Configuration initialization failed"
        return 1
    fi
}

# Install tools and runtimes
install_codacy_tools() {
    print_header "Installing Codacy Tools and Runtimes"
    
    if [[ ! -f "$CODACY_CONFIG_FILE" ]]; then
        print_error "Configuration file not found. Run 'init' first."
        return 1
    fi
    
    print_info "Installing tools specified in $CODACY_CONFIG_FILE..."
    codacy-cli install
    
    if [[ $? -eq 0 ]]; then
        print_success "Tools and runtimes installed successfully"
        return 0
    else
        print_error "Tool installation failed"
        return 1
    fi
}

# Run code analysis
run_codacy_analysis() {
    local tool="$1"
    local output_format="${2:-sarif}"
    local output_file="${3:-codacy-results.sarif}"
    local auto_fix="$4"

    print_header "Running Codacy Code Analysis"

    # Load API configuration
    load_api_config

    if [[ ! -f "$CODACY_CONFIG_FILE" ]]; then
        print_error "Configuration file not found. Run 'init' first."
        return 1
    fi

    # Build analysis command
    local cmd="codacy-cli analyze"

    # Handle auto-fix flag
    if [[ "$tool" == "--fix" ]]; then
        cmd="$cmd --fix"
        print_info "Auto-fix enabled: Will apply fixes when available"
        print_info "Running analysis with all configured tools"
    elif [[ -n "$tool" ]]; then
        cmd="$cmd --tool $tool"
        print_info "Running analysis with tool: $tool"
    else
        print_info "Running analysis with all configured tools"
    fi

    if [[ "$output_format" == "sarif" ]]; then
        cmd="$cmd --format sarif --output $output_file"
        print_info "Output format: SARIF → $output_file"
    fi

    # Execute analysis
    print_info "Executing: $cmd"
    eval "$cmd"
    
    if [[ $? -eq 0 ]]; then
        print_success "Code analysis completed successfully"
        if [[ -f "$output_file" ]]; then
            print_info "Results saved to: $output_file"
        fi
        return 0
    else
        print_error "Code analysis failed"
        return 1
    fi
}

# Upload SARIF results to Codacy
upload_codacy_results() {
    local sarif_file="${1:-codacy-results.sarif}"
    local commit_uuid="${2:-$(git rev-parse HEAD 2>/dev/null)}"

    print_header "Uploading Results to Codacy"

    if [[ ! -f "$sarif_file" ]]; then
        print_error "SARIF file not found: $sarif_file"
        return 1
    fi

    if [[ -z "$commit_uuid" ]]; then
        print_error "Commit UUID required. Provide as argument or ensure git repository."
        return 1
    fi

    # Check for project token or API token
    local project_token="${CODACY_PROJECT_TOKEN:-}"
    local api_token="${CODACY_API_TOKEN:-}"
    local provider="${CODACY_PROVIDER:-}"
    local organization="${CODACY_ORGANIZATION:-}"
    local repository="${CODACY_REPOSITORY:-}"

    local cmd="codacy-cli upload -s $sarif_file -c $commit_uuid"

    if [[ -n "$project_token" ]]; then
        cmd="$cmd -t $project_token"
        print_info "Using project token for upload"
    elif [[ -n "$api_token" && -n "$provider" && -n "$organization" && -n "$repository" ]]; then
        cmd="$cmd -a $api_token -p $provider -o $organization -r $repository"
        print_info "Using API token for upload"
    else
        print_error "Upload credentials required:"
        print_info "  Option 1: Set CODACY_PROJECT_TOKEN"
        print_info "  Option 2: Set CODACY_API_TOKEN, CODACY_PROVIDER, CODACY_ORGANIZATION, CODACY_REPOSITORY"
        return 1
    fi

    print_info "Uploading: $sarif_file (commit: ${commit_uuid:0:8})"
    eval "$cmd"

    if [[ $? -eq 0 ]]; then
        print_success "Results uploaded to Codacy successfully"
        return 0
    else
        print_error "Upload failed"
        return 1
    fi
}

# Show CLI status
show_codacy_status() {
    print_header "Codacy CLI Status"

    # Check CLI installation
    if check_codacy_cli; then
        print_info "Expected version: $CODACY_CLI_VERSION"
        echo ""
    else
        print_info "Expected version: $CODACY_CLI_VERSION"
        print_info "Run: $0 install"
        echo ""
    fi

    # Check configuration
    if [[ -f "$CODACY_CONFIG_FILE" ]]; then
        print_success "Configuration found: $CODACY_CONFIG_FILE"

        # Show basic config info
        if command -v yq &> /dev/null; then
            local tools_count
            tools_count=$(yq eval '.tools | length' "$CODACY_CONFIG_FILE" 2>/dev/null || echo "unknown")
            print_info "Configured tools: $tools_count"
        fi
    else
        print_warning "Configuration not found"
        print_info "Run: $0 init"
    fi

    # Check environment variables
    echo ""
    print_info "Environment Configuration:"
    [[ -n "${CODACY_API_TOKEN:-}" ]] && print_success "CODACY_API_TOKEN: Set" || print_warning "CODACY_API_TOKEN: Not set"
    [[ -n "${CODACY_PROJECT_TOKEN:-}" ]] && print_success "CODACY_PROJECT_TOKEN: Set" || print_warning "CODACY_PROJECT_TOKEN: Not set"
    [[ -n "${CODACY_PROVIDER:-}" ]] && print_info "CODACY_PROVIDER: ${CODACY_PROVIDER}" || print_warning "CODACY_PROVIDER: Not set"
    [[ -n "${CODACY_ORGANIZATION:-}" ]] && print_info "CODACY_ORGANIZATION: ${CODACY_ORGANIZATION}" || print_warning "CODACY_ORGANIZATION: Not set"
    [[ -n "${CODACY_REPOSITORY:-}" ]] && print_info "CODACY_REPOSITORY: ${CODACY_REPOSITORY}" || print_warning "CODACY_REPOSITORY: Not set"

    return 0
}

# Show help message
show_help() {
    print_header "Codacy CLI v2 Integration Help"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install              - Install Codacy CLI v2"
    echo "  init                 - Initialize project configuration"
    echo "  install-tools        - Install tools and runtimes"
    echo "  analyze [tool|--fix] - Run code analysis (optionally with specific tool or auto-fix)"
    echo "  upload [sarif] [commit] - Upload SARIF results to Codacy"
    echo "  status               - Check CLI status and configuration"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 init"
    echo "  $0 analyze"
    echo "  $0 analyze eslint"
    echo "  $0 analyze --fix          # Auto-fix issues when possible"
    echo "  $0 upload results.sarif abc123"
    echo ""
    echo "Environment Variables:"
    echo "  CODACY_API_TOKEN     - API token for Codacy"
    echo "  CODACY_PROJECT_TOKEN - Project token for uploads"
    echo "  CODACY_PROVIDER      - Provider (gh, gl, bb)"
    echo "  CODACY_ORGANIZATION  - Organization name"
    echo "  CODACY_REPOSITORY    - Repository name"
    echo ""
    echo "This script integrates Codacy CLI v2 into the AI DevOps Framework"
    echo "for comprehensive local code analysis and quality assurance."
    return 0
}

# Main function
main() {
    local command="${1:-help}"

    case "$command" in
        "install")
            install_codacy_cli
            ;;
        "init")
            init_codacy_config
            ;;
        "install-tools")
            install_codacy_tools
            ;;
        "analyze")
            run_codacy_analysis "$2" "$3" "$4"
            ;;
        "upload")
            upload_codacy_results "$2" "$3"
            ;;
        "status")
            show_codacy_status
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
