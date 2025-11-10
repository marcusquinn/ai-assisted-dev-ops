#!/bin/bash

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check system requirements
check_requirements() {
    print_info "Checking system requirements..."
    
    local missing_deps=()
    
    # Check for required commands
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v ssh >/dev/null 2>&1 || missing_deps+=("ssh")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Install missing dependencies:"
        echo "  macOS: brew install ${missing_deps[*]}"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        echo "  CentOS/RHEL: sudo yum install ${missing_deps[*]}"
        exit 1
    fi
    
    print_success "All required dependencies found"
}

# Check for optional dependencies
check_optional_deps() {
    print_info "Checking optional dependencies..."
    
    if ! command -v sshpass >/dev/null 2>&1; then
        print_warning "sshpass not found - needed for password-based SSH (like Hostinger)"
        echo "  Install: brew install sshpass (macOS) or sudo apt-get install sshpass (Linux)"
    else
        print_success "sshpass found"
    fi
}

# Setup SSH key if needed
setup_ssh_key() {
    print_info "Checking SSH key setup..."
    
    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        print_warning "Ed25519 SSH key not found"
        read -p "Generate new Ed25519 SSH key? (y/n): " generate_key
        
        if [[ "$generate_key" == "y" ]]; then
            read -p "Enter your email address: " email
            ssh-keygen -t ed25519 -C "$email"
            print_success "SSH key generated"
        else
            print_info "Skipping SSH key generation"
        fi
    else
        print_success "Ed25519 SSH key found"
    fi
}

# Setup configuration files
setup_configs() {
    print_info "Setting up configuration files..."
    
    # Create configs directory if it doesn't exist
    mkdir -p configs
    
    # Copy template configs if they don't exist
    for template in configs/*.txt; do
        if [[ -f "$template" ]]; then
            config_file="${template%.txt}"
            if [[ ! -f "$config_file" ]]; then
                cp "$template" "$config_file"
                print_success "Created $(basename "$config_file")"
                print_warning "Please edit $(basename "$config_file") with your actual credentials"
            fi
        fi
    done
    
    # Copy AI context template
    if [[ ! -f "ai-context.md" ]]; then
        cp "ai-context.md.txt" "ai-context.md"
        print_success "Created ai-context.md"
        print_warning "Please customize ai-context.md with your infrastructure details"
    fi
}

# Set proper permissions
set_permissions() {
    print_info "Setting proper file permissions..."
    
    # Make scripts executable
    chmod +x *.sh
    chmod +x providers/*.sh
    chmod +x ssh/*.sh
    
    # Secure configuration files
    chmod 600 configs/*.json 2>/dev/null || true
    
    print_success "File permissions set"
}

# Setup shell aliases
setup_aliases() {
    print_info "Setting up shell aliases..."
    
    local shell_rc=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        shell_rc="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        shell_rc="$HOME/.bashrc"
    else
        print_warning "Unknown shell, skipping alias setup"
        return
    fi
    
    # Check if aliases already exist
    if grep -q "# AI Assistant Server Access" "$shell_rc" 2>/dev/null; then
        print_info "Aliases already configured"
        return
    fi
    
    read -p "Add shell aliases to $shell_rc? (y/n): " add_aliases
    
    if [[ "$add_aliases" == "y" ]]; then
        cat >> "$shell_rc" << 'EOF'

# AI Assistant Server Access Framework
alias servers='./scripts/servers-helper.sh'
alias servers-list='./scripts/servers-helper.sh list'
alias hostinger='./providers/hostinger-helper.sh'
alias hetzner='./providers/hetzner-helper.sh'
alias aws-helper='./providers/aws-helper.sh'
EOF
        print_success "Aliases added to $shell_rc"
        print_info "Run 'source $shell_rc' or restart your terminal to use aliases"
    fi
}

# Deploy AI assistant templates
deploy_ai_templates() {
    print_info "Deploying AI assistant templates..."

    if [[ -f "templates/deploy-templates.sh" ]]; then
        print_info "Running template deployment script..."
        bash templates/deploy-templates.sh

        if [[ $? -eq 0 ]]; then
            print_success "AI assistant templates deployed successfully"
        else
            print_warning "Template deployment encountered issues (non-critical)"
        fi
    else
        print_warning "Template deployment script not found - skipping"
    fi
}

# Verify repository location
verify_location() {
    local current_dir
    current_dir="$(pwd)"
    local expected_location="$HOME/git/ai-assisted-dev-ops"

    if [[ "$current_dir" != "$expected_location" ]]; then
        print_warning "Repository is not in the recommended location"
        print_info "Current location: $current_dir"
        print_info "Recommended location: $expected_location"
        echo ""
        echo "For optimal AI assistant integration, consider moving this repository to:"
        echo "  mkdir -p ~/git"
        echo "  mv '$current_dir' '$expected_location'"
        echo ""
    else
        print_success "Repository is in the recommended location: $expected_location"
    fi
}

# Main setup function
main() {
    echo "🤖 AI Assistant Server Access Framework Setup"
    echo "=============================================="
    echo ""

    verify_location
    check_requirements
    check_optional_deps
    setup_ssh_key
    setup_configs
    set_permissions
    setup_aliases
    deploy_ai_templates
    
    echo ""
    print_success "🎉 Setup complete!"
    echo ""
    echo "Next steps:"
    echo "1. Edit configuration files in configs/ with your actual credentials"
    echo "2. Customize .ai-context.md with your infrastructure details"
    echo "3. Setup CodeRabbit CLI: bash .agent/scripts/coderabbit-cli.sh install && bash .agent/scripts/coderabbit-cli.sh setup"
    echo "4. Setup API keys: bash .agent/scripts/setup-local-api-keys.sh setup"
    echo "5. Setup Codacy CLI: bash .agent/scripts/setup-local-api-keys.sh set codacy YOUR_TOKEN && bash .agent/scripts/codacy-cli.sh install"
    echo "6. Test access: ./scripts/servers-helper.sh list"
    echo "7. Read documentation in docs/ for provider-specific setup"
    echo ""
    echo "Security reminders:"
    echo "- Never commit configuration files with real credentials"
    echo "- Use strong passwords and enable MFA on all accounts"
    echo "- Regularly rotate API tokens and SSH keys"
    echo ""
    echo "Happy server managing! 🚀"
}

# Run setup
main "$@"
