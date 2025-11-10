#!/bin/bash

# Qlty CLI Integration Script
# Universal linting, auto-formatting, security scanning, and maintainability
# 
# Author: AI-Assisted DevOps Framework
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
    
    # Verify installation
    if command -v qlty &> /dev/null; then
        print_success "Qlty CLI installed successfully: $(qlty --version)"
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
    
    print_header "Running Qlty Code Quality Check"
    
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
    
    print_header "Running Qlty Auto-Formatting"
    
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
    eval "$cmd"
    
    if [[ $? -eq 0 ]]; then
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
    
    print_header "Running Qlty Code Smells Detection"
    
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
    echo "  check [sample]       - Run code quality check (optionally with sample size)"
    echo "  fmt [--all]          - Auto-format code (optionally entire codebase)"
    echo "  smells [--all]       - Detect code smells (optionally entire codebase)"
    echo "  help                 - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  $0 init"
    echo "  $0 check 5           # Check sample of 5 issues"
    echo "  $0 fmt --all         # Format entire codebase"
    echo "  $0 smells --all      # Scan all files for code smells"
    echo ""
    echo "Features:"
    echo "  🐛 Linting: 70+ tools for 40+ languages"
    echo "  🖌️  Auto-formatting: Consistent code style"
    echo "  💩 Code smells: Duplication and complexity detection"
    echo "  🚨 Security: SAST, SCA, secret detection"
    echo "  ⚡ Performance: Fast, concurrent execution"
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
            check_qlty "$1"
            ;;
        "fmt")
            format_qlty "$1"
            ;;
        "smells")
            smells_qlty "$1"
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
