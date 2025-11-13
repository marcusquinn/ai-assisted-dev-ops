#!/bin/bash

# AI DevOps Framework - Template Deployment Script
# Securely deploys minimal AGENTS.md templates to user's home directory

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Validate we're in the correct repository
if [[ ! -f "$REPO_ROOT/AGENTS.md" ]] || [[ ! -d "$REPO_ROOT/.agent" ]]; then
    print_error "This script must be run from within the aidevops repository"
    exit 1
fi

deploy_home_agents() {
    local target_file="$HOME/AGENTS.md"
    
    print_info "Deploying minimal AGENTS.md to home directory..."
    
    # Backup existing file if it exists
    if [[ -f "$target_file" ]]; then
        print_warning "Existing AGENTS.md found, creating backup..."
        cp "$target_file" "$target_file.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Deploy template
    cp "$SCRIPT_DIR/home/AGENTS.md" "$target_file"
    print_success "Deployed: $target_file"
    return 0
}

deploy_git_agents() {
    local git_dir="$HOME/git"
    local target_file="$git_dir/AGENTS.md"
    
    print_info "Deploying minimal AGENTS.md to git directory..."
    
    # Create git directory if it doesn't exist
    if [[ ! -d "$git_dir" ]]; then
        mkdir -p "$git_dir"
        print_info "Created git directory: $git_dir"
    fi
    
    # Backup existing file if it exists
    if [[ -f "$target_file" ]]; then
        print_warning "Existing git/AGENTS.md found, creating backup..."
        cp "$target_file" "$target_file.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Deploy template
    cp "$SCRIPT_DIR/home/git/AGENTS.md" "$target_file"
    print_success "Deployed: $target_file"
    return 0
}

deploy_agent_directory() {
    local agent_dir="$HOME/.agent"
    local target_file="$agent_dir/README.md"
    
    print_info "Deploying minimal .agent directory structure..."
    
    # Create .agent directory if it doesn't exist
    if [[ ! -d "$agent_dir" ]]; then
        mkdir -p "$agent_dir"
        print_info "Created .agent directory: $agent_dir"
    fi
    
    # Backup existing README if it exists
    if [[ -f "$target_file" ]]; then
        print_warning "Existing .agent/README.md found, creating backup..."
        cp "$target_file" "$target_file.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Deploy template
    cp "$SCRIPT_DIR/home/.agent/README.md" "$target_file"
    print_success "Deployed: $target_file"
    return 0
}

verify_deployment() {
    print_info "Verifying template deployment..."
    
    local files_to_check=(
        "$HOME/AGENTS.md"
        "$HOME/git/AGENTS.md"
        "$HOME/.agent/README.md"
    )
    
    local all_good=true
    for file in "${files_to_check[@]}"; do
        if [[ -f "$file" ]]; then
            print_success "✓ $file"
        else
            print_error "✗ $file"
            all_good=false
        fi
    done
    
    if [[ "$all_good" == true ]]; then
        print_success "All templates deployed successfully!"
        return 0
    else
        print_error "Some templates failed to deploy"
        return 1
    fi
}

main() {
    echo -e "${BLUE}🔒 AI DevOps Framework - Secure Template Deployment${NC}"
    echo -e "${BLUE}============================================================${NC}"
    
    print_info "Deploying minimal, secure AGENTS.md templates..."
    print_warning "These templates contain minimal instructions to prevent prompt injection attacks"
    
    deploy_home_agents
    deploy_git_agents
    deploy_agent_directory
    verify_deployment
    
    echo ""
    print_success "Template deployment complete!"
    print_info "All templates reference the authoritative repository at: $REPO_ROOT"
    print_warning "Do not modify these templates beyond minimal references for security"
    
    return 0
}

main "$@"
