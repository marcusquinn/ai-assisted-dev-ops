#!/bin/bash

# SonarScanner CLI Integration Script
# Comprehensive SonarQube Cloud analysis with SonarScanner CLI
#
# Usage: ./sonarscanner-cli.sh [command] [options]
# Commands:
#   install     - Install SonarScanner CLI
#   init        - Initialize project configuration
#   analyze     - Run SonarQube analysis
#   status      - Check CLI status and configuration
#   help        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

# Configuration
readonly SONAR_SCANNER_VERSION="7.3"
readonly SONAR_CONFIG_FILE="sonar-project.properties"
readonly SONAR_HOST_URL="https://sonarcloud.io"

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

# Check if SonarScanner CLI is installed
check_sonar_scanner() {
    if command -v sonar-scanner &> /dev/null; then
        local version
        version=$(sonar-scanner -v 2>/dev/null | grep "SonarScanner" | head -1 || echo "unknown")
        print_success "SonarScanner CLI installed: $version"
        return 0
    else
        print_warning "SonarScanner CLI not found"
        return 1
    fi
}

# Install SonarScanner CLI
install_sonar_scanner() {
    print_header "Installing SonarScanner CLI"
    
    # Detect platform and architecture
    local platform
    local arch
    local download_url
    
    case "$(uname -s)" in
        Darwin*)
            platform="macosx"
            case "$(uname -m)" in
                arm64|aarch64)
                    arch="aarch64"
                    ;;
                *)
                    arch="x64"
                    ;;
            esac
            ;;
        Linux*)
            platform="linux"
            case "$(uname -m)" in
                aarch64|arm64)
                    arch="aarch64"
                    ;;
                *)
                    arch="x64"
                    ;;
            esac
            ;;
        *)
            print_error "Unsupported platform: $(uname -s)"
            print_info "For Windows, use WSL and follow Linux instructions"
            return 1
            ;;
    esac
    
    # Construct download URL
    download_url="https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-${platform}-${arch}.zip"
    
    print_info "Platform: $platform-$arch"
    print_info "Downloading from: $download_url"
    
    # Create temporary directory
    local temp_dir
    temp_dir=$(mktemp -d)
    local zip_file="$temp_dir/sonar-scanner.zip"
    
    # Download
    if command -v curl &> /dev/null; then
        curl -L -o "$zip_file" "$download_url"
    elif command -v wget &> /dev/null; then
        wget -O "$zip_file" "$download_url"
    else
        print_error "Neither curl nor wget found. Please install one of them."
        return 1
    fi
    
    if [[ ! -f "$zip_file" ]]; then
        print_error "Download failed"
        return 1
    fi
    
    # Extract to /opt/sonar-scanner (requires sudo) or ~/sonar-scanner
    local install_dir
    if [[ -w "/opt" ]]; then
        install_dir="/opt/sonar-scanner"
    else
        install_dir="$HOME/sonar-scanner"
        print_info "Installing to user directory: $install_dir"
    fi
    
    # Create install directory
    mkdir -p "$install_dir"
    
    # Extract
    if command -v unzip &> /dev/null; then
        unzip -q "$zip_file" -d "$temp_dir"
        # Find extracted directory
        local extracted_dir
        extracted_dir=$(find "$temp_dir" -name "sonar-scanner-*" -type d | head -1)
        if [[ -n "$extracted_dir" ]]; then
            cp -r "$extracted_dir"/* "$install_dir/"
        else
            print_error "Extraction failed - directory not found"
            return 1
        fi
    else
        print_error "unzip command not found. Please install unzip."
        return 1
    fi
    
    # Make executable
    chmod +x "$install_dir/bin/sonar-scanner"
    
    # Add to PATH (add to shell profile)
    local shell_profile
    case "$SHELL" in
        */bash)
            shell_profile="$HOME/.bashrc"
            ;;
        */zsh)
            shell_profile="$HOME/.zshrc"
            ;;
        *)
            shell_profile="$HOME/.profile"
            ;;
    esac
    
    # Check if already in PATH
    if ! echo "$PATH" | grep -q "$install_dir/bin"; then
        echo "export PATH=\"$install_dir/bin:\$PATH\"" >> "$shell_profile"
        export PATH="$install_dir/bin:$PATH"
        print_info "Added to PATH in $shell_profile"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    # Verify installation
    if check_sonar_scanner; then
        print_success "SonarScanner CLI installed successfully"
        print_info "Restart your shell or run: source $shell_profile"
        return 0
    else
        print_error "Installation verification failed"
        return 1
    fi
}

# Initialize SonarQube project configuration
init_sonar_config() {
    print_header "Initializing SonarQube Configuration"

    # Try to load API key from secure local storage first
    local api_key_script="$(dirname "$0")/setup-local-api-keys.sh"
    if [[ -f "$api_key_script" ]]; then
        local stored_key
        stored_key=$("$api_key_script" get sonar 2>/dev/null)
        if [[ -n "$stored_key" ]]; then
            export SONAR_TOKEN="$stored_key"
            print_info "Loaded SonarCloud token from secure local storage"
        fi
    fi

    # Check for required environment variables
    local sonar_token="${SONAR_TOKEN:-}"
    local sonar_organization="${SONAR_ORGANIZATION:-}"
    local sonar_project_key="${SONAR_PROJECT_KEY:-}"

    if [[ -z "$sonar_token" ]]; then
        print_error "SONAR_TOKEN not found in environment or secure storage"
        print_info "Set up token with: bash .agent/scripts/setup-local-api-keys.sh set sonar YOUR_TOKEN"
        print_info "Get your token from: https://sonarcloud.io/account/security/"
        return 1
    fi

    if [[ -z "$sonar_organization" ]]; then
        print_error "SONAR_ORGANIZATION environment variable required"
        print_info "Find your organization key in SonarCloud project settings"
        return 1
    fi

    if [[ -z "$sonar_project_key" ]]; then
        print_error "SONAR_PROJECT_KEY environment variable required"
        print_info "Use your repository name or custom project key"
        return 1
    fi

    # Create sonar-project.properties
    cat > "$SONAR_CONFIG_FILE" << EOF
# SonarQube Cloud Configuration
# Generated by AI DevOps Framework

# Organization and project keys
sonar.organization=$sonar_organization
sonar.projectKey=$sonar_project_key
sonar.host.url=$SONAR_HOST_URL

# Project information
sonar.projectName=${SONAR_PROJECT_NAME:-$sonar_project_key}
sonar.projectVersion=${SONAR_PROJECT_VERSION:-1.0}

# Source configuration
sonar.sources=${SONAR_SOURCES:-.}
sonar.sourceEncoding=${SONAR_SOURCE_ENCODING:-UTF-8}

# Exclusions (customize as needed)
sonar.exclusions=**/*test*/**,**/*Test*/**,**/node_modules/**,**/vendor/**,**/*.min.js

# Language-specific settings
sonar.javascript.lcov.reportPaths=coverage/lcov.info
sonar.python.coverage.reportPaths=coverage.xml
sonar.java.binaries=target/classes
sonar.java.test.binaries=target/test-classes

# Quality gate
sonar.qualitygate.wait=${SONAR_QUALITYGATE_WAIT:-false}
EOF

    if [[ -f "$SONAR_CONFIG_FILE" ]]; then
        print_success "SonarQube configuration created: $SONAR_CONFIG_FILE"
        print_info "Customize the configuration as needed for your project"
        return 0
    else
        print_error "Configuration creation failed"
        return 1
    fi
}

# Run SonarQube analysis
run_sonar_analysis() {
    print_header "Running SonarQube Analysis"

    # Check for configuration
    if [[ ! -f "$SONAR_CONFIG_FILE" ]]; then
        print_warning "Configuration file not found: $SONAR_CONFIG_FILE"
        print_info "Attempting to run with environment variables..."
    fi

    # Try to load API key from secure local storage first
    local api_key_script="$(dirname "$0")/setup-local-api-keys.sh"
    if [[ -f "$api_key_script" ]]; then
        local stored_key
        stored_key=$("$api_key_script" get sonar 2>/dev/null)
        if [[ -n "$stored_key" ]]; then
            export SONAR_TOKEN="$stored_key"
            print_info "Loaded SonarCloud token from secure local storage"
        fi
    fi

    # Check for required token
    local sonar_token="${SONAR_TOKEN:-}"
    if [[ -z "$sonar_token" ]]; then
        print_error "SONAR_TOKEN not found in environment or secure storage"
        print_info "Set up token with: bash .agent/scripts/setup-local-api-keys.sh set sonar YOUR_TOKEN"
        return 1
    fi

    # Build analysis command
    local cmd="sonar-scanner"

    # Add token
    cmd="$cmd -Dsonar.token=$sonar_token"

    # Add additional parameters if not in config file
    if [[ ! -f "$SONAR_CONFIG_FILE" ]]; then
        local sonar_organization="${SONAR_ORGANIZATION:-}"
        local sonar_project_key="${SONAR_PROJECT_KEY:-}"

        if [[ -n "$sonar_organization" ]]; then
            cmd="$cmd -Dsonar.organization=$sonar_organization"
        fi

        if [[ -n "$sonar_project_key" ]]; then
            cmd="$cmd -Dsonar.projectKey=$sonar_project_key"
        fi

        cmd="$cmd -Dsonar.host.url=$SONAR_HOST_URL"
        cmd="$cmd -Dsonar.sources=."
    fi

    # Add debug flag if requested
    if [[ "${SONAR_DEBUG:-false}" == "true" ]]; then
        cmd="$cmd -X"
        print_info "Debug mode enabled"
    fi

    # Create safe command for logging (mask the token)
    local safe_cmd
    safe_cmd=$(echo "$cmd" | sed 's/-Dsonar\.token=[^ ]*/-Dsonar.token=[MASKED]/g')
    print_info "Executing: $safe_cmd"
    eval "$cmd"

    if [[ $? -eq 0 ]]; then
        print_success "SonarQube analysis completed successfully"
        print_info "View results at: $SONAR_HOST_URL"
        return 0
    else
        print_error "SonarQube analysis failed"
        return 1
    fi
}

# Show CLI status
show_sonar_status() {
    print_header "SonarScanner CLI Status"

    # Check CLI installation
    if check_sonar_scanner; then
        echo ""
    else
        print_info "Run: $0 install"
        echo ""
    fi

    # Check configuration
    if [[ -f "$SONAR_CONFIG_FILE" ]]; then
        print_success "Configuration found: $SONAR_CONFIG_FILE"

        # Show basic config info
        if [[ -r "$SONAR_CONFIG_FILE" ]]; then
            local org
            org=$(grep "^sonar.organization=" "$SONAR_CONFIG_FILE" | cut -d'=' -f2 2>/dev/null || echo "not set")
            local project
            project=$(grep "^sonar.projectKey=" "$SONAR_CONFIG_FILE" | cut -d'=' -f2 2>/dev/null || echo "not set")
            print_info "Organization: $org"
            print_info "Project Key: $project"
        fi
    else
        print_warning "Configuration not found: $SONAR_CONFIG_FILE"
        print_info "Run: $0 init"
    fi

    # Check environment variables
    echo ""
    print_info "Environment Configuration:"
    [[ -n "${SONAR_TOKEN:-}" ]] && print_success "SONAR_TOKEN: Set" || print_warning "SONAR_TOKEN: Not set"
    [[ -n "${SONAR_ORGANIZATION:-}" ]] && print_info "SONAR_ORGANIZATION: ${SONAR_ORGANIZATION}" || print_warning "SONAR_ORGANIZATION: Not set"
    [[ -n "${SONAR_PROJECT_KEY:-}" ]] && print_info "SONAR_PROJECT_KEY: ${SONAR_PROJECT_KEY}" || print_warning "SONAR_PROJECT_KEY: Not set"
    [[ -n "${SONAR_PROJECT_NAME:-}" ]] && print_info "SONAR_PROJECT_NAME: ${SONAR_PROJECT_NAME}" || print_info "SONAR_PROJECT_NAME: Will use project key"

    return 0
}

# Show help message
show_help() {
    print_header "SonarScanner CLI Integration Help"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  install              - Install SonarScanner CLI"
    echo "  init                 - Initialize project configuration"
    echo "  analyze              - Run SonarQube analysis"
    echo "  status               - Check CLI status and configuration"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 init"
    echo "  $0 analyze"
    echo ""
    echo "Required Environment Variables:"
    echo "  SONAR_TOKEN          - SonarCloud authentication token"
    echo "  SONAR_ORGANIZATION   - SonarCloud organization key"
    echo "  SONAR_PROJECT_KEY    - Project key (usually repository name)"
    echo ""
    echo "Optional Environment Variables:"
    echo "  SONAR_PROJECT_NAME   - Human-readable project name"
    echo "  SONAR_PROJECT_VERSION - Project version (default: 1.0)"
    echo "  SONAR_SOURCES        - Source directories (default: .)"
    echo "  SONAR_SOURCE_ENCODING - Source encoding (default: UTF-8)"
    echo "  SONAR_QUALITYGATE_WAIT - Wait for quality gate (default: false)"
    echo "  SONAR_DEBUG          - Enable debug mode (default: false)"
    echo ""
    echo "This script integrates SonarScanner CLI into the AI DevOps Framework"
    echo "for comprehensive SonarQube Cloud analysis and quality assurance."
    return 0
}

# Main function
main() {
    local command="${1:-help}"

    case "$command" in
        "install")
            install_sonar_scanner
            ;;
        "init")
            init_sonar_config
            ;;
        "analyze")
            run_sonar_analysis
            ;;
        "status")
            show_sonar_status
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
