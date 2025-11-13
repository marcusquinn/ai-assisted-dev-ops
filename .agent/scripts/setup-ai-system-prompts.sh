#!/bin/bash

# 🤖 AI System Prompt Configuration Script
# Helps configure system prompts for various AI CLI tools to use this framework

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

print_header() { echo -e "${PURPLE}🤖 $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Framework path
readonly FRAMEWORK_PATH="$HOME/git/aidevops"

# System prompt text
readonly SYSTEM_PROMPT="Before performing any DevOps operations, always read ~/git/aidevops/AGENTS.md for authoritative guidance on this comprehensive infrastructure management framework. This framework provides secure access to 25+ service integrations with enterprise-grade security practices."

# Check if framework is installed
check_framework() {
    if [[ ! -d "$FRAMEWORK_PATH" ]]; then
        print_error "AI DevOps framework not found at $FRAMEWORK_PATH"
        print_info "Please run: mkdir -p ~/git && cd ~/git && git clone https://github.com/marcusquinn/aidevops.git"
        exit 1
    fi
    
    if [[ ! -f "$FRAMEWORK_PATH/AGENTS.md" ]]; then
        print_error "AGENTS.md not found in framework directory"
        exit 1
    fi
    
    print_success "Framework found at $FRAMEWORK_PATH"
}

# Configure Augment Code (Auggie)
configure_augment() {
    print_header "Configuring Augment Code (Auggie)"
    
    if ! command -v augment &> /dev/null; then
        print_warning "Augment CLI not found. Install with: npm install -g @augmentcode/cli"
        return 1
    fi
    
    # Add to shell profile
    local shell_profile
    if [[ "$SHELL" == *"zsh"* ]]; then
        shell_profile="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        shell_profile="$HOME/.bashrc"
    else
        shell_profile="$HOME/.profile"
    fi
    
    if ! grep -q "AUGMENT_SYSTEM_PROMPT" "$shell_profile" 2>/dev/null; then
        echo "" >> "$shell_profile"
        echo "# AI DevOps Framework - Augment Integration" >> "$shell_profile"
        echo "export AUGMENT_SYSTEM_PROMPT=\"$SYSTEM_PROMPT\"" >> "$shell_profile"
        print_success "Added system prompt to $shell_profile"
        print_info "Restart your terminal or run: source $shell_profile"
    else
        print_info "Augment system prompt already configured"
    fi
}

# Configure Claude Desktop
configure_claude() {
    print_header "Configuring Claude Desktop"
    
    local claude_config="$HOME/.config/claude/claude_desktop_config.json"
    local claude_config_dir
    claude_config_dir=$(dirname "$claude_config")
    
    if [[ ! -d "$claude_config_dir" ]]; then
        mkdir -p "$claude_config_dir"
        print_info "Created Claude config directory"
    fi
    
    if [[ ! -f "$claude_config" ]]; then
        cat > "$claude_config" << EOF
{
  "systemPrompt": "$SYSTEM_PROMPT",
  "workingDirectory": "$FRAMEWORK_PATH"
}
EOF
        print_success "Created Claude Desktop configuration"
    else
        print_info "Claude Desktop config exists. Please manually add the system prompt:"
        print_info "\"systemPrompt\": \"$SYSTEM_PROMPT\""
    fi
}

# Configure Warp AI
configure_warp() {
    print_header "Configuring Warp AI"
    
    if ! command -v warp-cli &> /dev/null; then
        print_warning "Warp CLI not found. Install Warp from: https://www.warp.dev/"
        return 1
    fi
    
    # Create a Warp workflow
    print_info "Creating Warp workflow for DevOps setup..."
    
    if warp-cli workflow create devops-setup \
        --command "cd $FRAMEWORK_PATH && cat AGENTS.md" \
        --description "Read AI DevOps framework guidance" 2>/dev/null; then
        print_success "Created Warp workflow 'devops-setup'"
        print_info "Use: warp-cli workflow run devops-setup"
    else
        print_warning "Could not create Warp workflow. Please configure manually."
    fi
}

# Show manual configuration instructions
show_manual_instructions() {
    print_header "Manual Configuration Instructions"
    
    echo
    print_info "For other AI tools, add this to your system prompt:"
    echo
    echo "\"$SYSTEM_PROMPT\""
    echo
    
    print_info "Supported AI CLI Tools:"
    echo "• Augment Code (Auggie): https://www.augmentcode.com/"
    echo "• Claude Desktop: https://claude.ai/"
    echo "• AMP Code: https://amp.dev/"
    echo "• OpenAI Codex: https://openai.com/codex/"
    echo "• Factory AI Dron: https://www.factory.ai/"
    echo "• Qwen: https://qwenlm.github.io/"
    echo "• Warp AI: https://www.warp.dev/"
    echo
    
    print_info "See docs/AI-CLI-TOOLS.md for detailed setup instructions"
}

# Main function
main() {
    print_header "AI System Prompt Configuration for DevOps Framework"
    echo
    
    check_framework
    echo
    
    case "${1:-all}" in
        "augment")
            configure_augment
            ;;
        "claude")
            configure_claude
            ;;
        "warp")
            configure_warp
            ;;
        "all")
            configure_augment
            echo
            configure_claude
            echo
            configure_warp
            echo
            show_manual_instructions
            ;;
        "help"|*)
            print_header "Usage"
            echo "Usage: $0 [tool]"
            echo ""
            echo "Tools:"
            echo "  augment  - Configure Augment Code (Auggie)"
            echo "  claude   - Configure Claude Desktop"
            echo "  warp     - Configure Warp AI"
            echo "  all      - Configure all detected tools (default)"
            echo "  help     - Show this help"
            echo ""
            echo "This script helps configure AI CLI tools to use the"
            echo "AI DevOps framework guidance automatically."
            ;;
    esac
}

main "$@"
