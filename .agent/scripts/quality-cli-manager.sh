#!/bin/bash

# Quality CLI Manager Script
# Unified management for CodeRabbit, Codacy, and SonarScanner CLIs
#
# Usage: ./quality-cli-manager.sh [command] [cli] [options]
# Commands:
#   install     - Install specified CLI or all CLIs
#   init        - Initialize configuration for specified CLI or all CLIs
#   analyze     - Run analysis with specified CLI or all CLIs
#   status      - Check status of specified CLI or all CLIs
#   help        - Show this help message
#
# CLIs:
#   coderabbit  - CodeRabbit CLI for AI-powered code review
#   codacy      - Codacy CLI v2 for comprehensive code analysis
#   sonar       - SonarScanner CLI for SonarQube Cloud analysis
#   all         - All quality CLIs (default)
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

# CLI Scripts
readonly CODERABBIT_SCRIPT=".agent/scripts/coderabbit-cli.sh"
readonly CODACY_SCRIPT=".agent/scripts/codacy-cli.sh"
readonly SONAR_SCRIPT=".agent/scripts/sonarscanner-cli.sh"

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
    echo -e "${PURPLE}🔧 $message${NC}"
    return 0
}

# Execute CLI command
execute_cli_command() {
    local cli="$1"
    local command="$2"
    shift 2
    local args="$*"
    
    local script=""
    local cli_name=""
    
    case "$cli" in
        "coderabbit")
            script="$CODERABBIT_SCRIPT"
            cli_name="CodeRabbit CLI"
            ;;
        "codacy")
            script="$CODACY_SCRIPT"
            cli_name="Codacy CLI"
            ;;
        "sonar")
            script="$SONAR_SCRIPT"
            cli_name="SonarScanner CLI"
            ;;
        *)
            print_error "Unknown CLI: $cli"
            return 1
            ;;
    esac
    
    if [[ ! -f "$script" ]]; then
        print_error "$cli_name script not found: $script"
        return 1
    fi
    
    print_info "Executing: $cli_name $command $args"
    bash "$script" "$command" "$args"
    return $?
}

# Install CLIs
install_clis() {
    local target_cli="$1"
    
    print_header "Installing Quality CLIs"
    
    local success_count=0
    local total_count=0
    
    if [[ "$target_cli" == "all" || "$target_cli" == "coderabbit" ]]; then
        print_info "Installing CodeRabbit CLI..."
        if execute_cli_command "coderabbit" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    if [[ "$target_cli" == "all" || "$target_cli" == "codacy" ]]; then
        print_info "Installing Codacy CLI..."
        if execute_cli_command "codacy" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    if [[ "$target_cli" == "all" || "$target_cli" == "sonar" ]]; then
        print_info "Installing SonarScanner CLI..."
        if execute_cli_command "sonar" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "qlty" ]]; then
        print_info "Installing Qlty CLI..."
        if execute_cli_command "qlty" "install"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "linters" ]]; then
        print_info "Installing CodeFactor-inspired linters..."
        if bash "$(dirname "$0")/linter-manager.sh" install-detected; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    print_info "Installation Summary: $success_count/$total_count CLIs installed successfully"
    
    if [[ $success_count -eq $total_count ]]; then
        print_success "All requested CLIs installed successfully"
        return 0
    else
        print_warning "Some CLI installations failed"
        return 1
    fi
}

# Initialize CLI configurations
init_clis() {
    local target_cli="$1"
    
    print_header "Initializing Quality CLI Configurations"
    
    local success_count=0
    local total_count=0
    
    if [[ "$target_cli" == "all" || "$target_cli" == "coderabbit" ]]; then
        print_info "Initializing CodeRabbit CLI..."
        if execute_cli_command "coderabbit" "setup"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    if [[ "$target_cli" == "all" || "$target_cli" == "codacy" ]]; then
        print_info "Initializing Codacy CLI..."
        if execute_cli_command "codacy" "init"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    if [[ "$target_cli" == "all" || "$target_cli" == "sonar" ]]; then
        print_info "Initializing SonarScanner CLI..."
        if execute_cli_command "sonar" "init"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "qlty" ]]; then
        print_info "Initializing Qlty CLI..."
        if execute_cli_command "qlty" "init"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi
    
    print_info "Initialization Summary: $success_count/$total_count CLIs initialized successfully"
    
    if [[ $success_count -eq $total_count ]]; then
        print_success "All requested CLIs initialized successfully"
        return 0
    else
        print_warning "Some CLI initializations failed"
        return 1
    fi
}

# Run analysis with CLIs
analyze_with_clis() {
    local target_cli="$1"
    shift
    local args="$*"

    print_header "Running Quality Analysis"

    local success_count=0
    local total_count=0

    if [[ "$target_cli" == "all" || "$target_cli" == "coderabbit" ]]; then
        print_info "Running CodeRabbit analysis..."
        if execute_cli_command "coderabbit" "review" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "codacy" ]]; then
        print_info "Running Codacy analysis..."
        if execute_cli_command "codacy" "analyze" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    # Add auto-fix option for Codacy
    if [[ "$target_cli" == "codacy-fix" ]]; then
        print_info "Running Codacy analysis with auto-fix..."
        if execute_cli_command "codacy" "analyze" "--fix"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "sonar" ]]; then
        print_info "Running SonarQube analysis..."
        if execute_cli_command "sonar" "analyze" "$args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "qlty" ]]; then
        print_info "Running Qlty analysis..."
        # Add organization parameter if provided
        local qlty_args="$args"
        if [[ -n "$QLTY_ORG" ]]; then
            qlty_args="$args $QLTY_ORG"
        fi
        if execute_cli_command "qlty" "check" "$qlty_args"; then
            ((success_count++))
        fi
        ((total_count++))
        echo ""
    fi

    print_info "Analysis Summary: $success_count/$total_count analyses completed successfully"

    if [[ $success_count -eq $total_count ]]; then
        print_success "All requested analyses completed successfully"
        return 0
    else
        print_warning "Some analyses failed"
        return 1
    fi
}

# Show CLI status
show_cli_status() {
    local target_cli="$1"

    print_header "Quality CLI Status Report"

    if [[ "$target_cli" == "all" || "$target_cli" == "coderabbit" ]]; then
        print_info "CodeRabbit CLI Status:"
        execute_cli_command "coderabbit" "status"
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "codacy" ]]; then
        print_info "Codacy CLI Status:"
        execute_cli_command "codacy" "status"
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "sonar" ]]; then
        print_info "SonarScanner CLI Status:"
        execute_cli_command "sonar" "status"
        echo ""
    fi

    if [[ "$target_cli" == "all" || "$target_cli" == "qlty" ]]; then
        print_info "Qlty CLI Status:"
        if command -v qlty &> /dev/null; then
            echo "✅ Qlty CLI installed: $(qlty --version 2>/dev/null || echo 'version unknown')"
            if [[ -f ".qlty/qlty.toml" ]]; then
                echo "✅ Qlty initialized in repository"
            else
                echo "⚠️  Qlty not initialized (run 'qlty init')"
            fi
        else
            echo "❌ Qlty CLI not installed"
        fi
        echo ""
    fi

    return 0
}

# Show help message
show_help() {
    print_header "Quality CLI Manager Help"
    echo ""
    echo "Usage: $0 [command] [cli] [options]"
    echo ""
    echo "Commands:"
    echo "  install [cli]        - Install specified CLI or all CLIs"
    echo "  init [cli]           - Initialize configuration for specified CLI or all CLIs"
    echo "  analyze [cli] [opts] - Run analysis with specified CLI or all CLIs"
    echo "  status [cli]         - Check status of specified CLI or all CLIs"
    echo "  help                 - Show this help message"
    echo ""
    echo "CLIs:"
    echo "  coderabbit           - CodeRabbit CLI for AI-powered code review"
    echo "  codacy               - Codacy CLI v2 for comprehensive code analysis"
    echo "  codacy-fix           - Codacy CLI with auto-fix (applies fixes when available)"
    echo "  sonar                - SonarScanner CLI for SonarQube Cloud analysis"
    echo "  qlty                 - Qlty CLI for universal linting and auto-formatting"
    echo "  linters              - Linter Manager for CodeFactor-inspired multi-language linters"
    echo "  all                  - All quality CLIs (default)"
    echo ""
    echo "Examples:"
    echo "  $0 install all"
    echo "  $0 init codacy"
    echo "  $0 analyze coderabbit"
    echo "  $0 analyze codacy-fix      # Auto-fix issues when possible"
    echo "  $0 analyze qlty            # Universal linting and formatting"
    echo "  $0 install linters         # Install CodeFactor-inspired linters"
    echo "  $0 analyze all"
    echo "  $0 status sonar"
    echo ""
    echo "Environment Variables:"
    echo "  CodeRabbit:"
    echo "    CODERABBIT_API_KEY   - CodeRabbit API key"
    echo ""
    echo "  Codacy:"
    echo "    CODACY_API_TOKEN     - Codacy API token"
    echo "    CODACY_PROJECT_TOKEN - Codacy project token"
    echo "    CODACY_PROVIDER      - Provider (gh, gl, bb)"
    echo "    CODACY_ORGANIZATION  - Organization name"
    echo "    CODACY_REPOSITORY    - Repository name"
    echo ""
    echo "  SonarQube:"
    echo "    SONAR_TOKEN          - SonarCloud authentication token"
    echo "    SONAR_ORGANIZATION   - SonarCloud organization key"
    echo "    SONAR_PROJECT_KEY    - Project key"
    echo ""
    echo "This script provides unified management for all quality analysis CLIs"
    echo "in the AI DevOps Framework."
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    local cli="${2:-all}"
    shift 2 2>/dev/null || shift $# # Remove processed arguments

    case "$command" in
        "install")
            install_clis "$cli"
            ;;
        "init")
            init_clis "$cli"
            ;;
        "analyze")
            analyze_with_clis "$cli" "$@"
            ;;
        "status")
            show_cli_status "$cli"
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
