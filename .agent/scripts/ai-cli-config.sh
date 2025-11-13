#!/bin/bash

# AI CLI Configuration Script
# Configures all AI CLIs to read ~/AGENTS.md automatically

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly AGENTS_FILE="$HOME/AGENTS.md"
readonly REPO_AGENTS_FILE="$REPO_ROOT/AGENTS.md"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to create Aider configuration
configure_aider() {
    log_info "Configuring Aider to read AGENTS.md automatically..."
    
    local aider_config="$HOME/.aider.conf.yml"
    
    cat > "$aider_config" << 'EOF'
# Aider Configuration - Auto-read AGENTS.md
# This ensures Aider always reads AI agent guidance first

# Auto-add AGENTS.md to every session
read:
  - "~/AGENTS.md"
  - "~/git/aidevops/AGENTS.md"

# Model configuration
model: "openrouter/anthropic/claude-sonnet-4"
weak-model: "openrouter/anthropic/claude-3-5-haiku"

# Editor settings
editor-model: "openrouter/anthropic/claude-sonnet-4"
edit-format: "diff"

# Git integration
git: true
gitignore: true
auto-commits: true
commit-prompt: "AI-assisted changes via Aider"

# File handling
pretty: true
stream: true
show-diffs: true

# Working directory
work-dir: "~/git/aidevops"

# Memory and context
map-tokens: 2048
max-chat-history-tokens: 8192

# Safety settings
yes: false  # Always ask for confirmation
dry-run: false
EOF

    log_success "Aider configuration created at $aider_config"
}

# Function to create OpenAI CLI configuration
configure_openai_cli() {
    log_info "Configuring OpenAI CLI with AGENTS.md context..."
    
    local openai_config="$HOME/.openai/config.yaml"
    mkdir -p "$(dirname "$openai_config")" 2>/dev/null || true
    
    cat > "$openai_config" << 'EOF'
# OpenAI CLI Configuration - Auto-read AGENTS.md
# This ensures OpenAI CLI includes AI agent guidance

default_model: "gpt-4"
max_tokens: 4096
temperature: 0.1

# Auto-include AGENTS.md context
system_message: |
  You are an AI assistant with access to a comprehensive DevOps framework.
  Always read and follow the guidance in ~/AGENTS.md and ~/git/aidevops/AGENTS.md
  before performing any operations.

# Working directory
working_directory: "~/git/aidevops"
EOF

    log_success "OpenAI CLI configuration created at $openai_config"
}

# Function to create Claude CLI configuration
configure_claude_cli() {
    log_info "Configuring Claude CLI with AGENTS.md context..."
    
    local claude_config="$HOME/.claude/config.json"
    mkdir -p "$(dirname "$claude_config")" 2>/dev/null || true
    
    cat > "$claude_config" << 'EOF'
{
  "model": "claude-3-sonnet-20240229",
  "max_tokens": 4096,
  "temperature": 0.1,
  "system_message": "You are an AI assistant with access to a comprehensive DevOps framework. Always read and follow the guidance in ~/AGENTS.md and ~/git/aidevops/AGENTS.md before performing any operations.",
  "working_directory": "~/git/aidevops",
  "auto_read_files": [
    "~/AGENTS.md",
    "~/git/aidevops/AGENTS.md"
  ]
}
EOF

    log_success "Claude CLI configuration created at $claude_config"
}

# Function to create Qwen CLI configuration
configure_qwen_cli() {
    log_info "Configuring Qwen CLI with AGENTS.md context..."

    local qwen_config="$HOME/.qwen/config.json"
    local qwen_memory="$HOME/.qwen/QWEN.md"
    mkdir -p "$(dirname "$qwen_config")" 2>/dev/null || true

    # Create Qwen's memory file if it doesn't exist
    if [[ ! -f "$qwen_memory" ]]; then
        cat > "$qwen_memory" << 'EOF'
At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.
EOF
        log_success "Created Qwen memory file at $qwen_memory"
    else
        log_info "Qwen memory file already exists at $qwen_memory"
    fi

    cat > "$qwen_config" << 'EOF'
{
  "model": "qwen2.5-72b-instruct",
  "max_tokens": 4096,
  "temperature": 0.1,
  "system_message": "You are an AI assistant with access to a comprehensive DevOps framework. Always read and follow the guidance in ~/AGENTS.md and ~/git/aidevops/AGENTS.md before performing any operations.",
  "working_directory": "~/git/aidevops",
  "auto_context": [
    "~/AGENTS.md",
    "~/git/aidevops/AGENTS.md"
  ]
}
EOF

    log_success "Qwen CLI configuration created at $qwen_config"
}

# Function to create Windsurf IDE configuration
configure_windsurf_ide() {
    log_info "Configuring Windsurf IDE with AGENTS.md context..."

    # Check if Windsurf is installed
    local windsurf_cli=""
    if [[ -f "$HOME/.codeium/windsurf/bin/windsurf" ]]; then
        windsurf_cli="$HOME/.codeium/windsurf/bin/windsurf"
    elif command -v windsurf >/dev/null 2>&1; then
        windsurf_cli="windsurf"
    else
        log_warning "Windsurf IDE not found, skipping configuration"
        return
    fi

    # Create Windsurf global rules
    local windsurf_global_rules="$HOME/.codeium/windsurf/memories/global_rules.md"
    mkdir -p "$(dirname "$windsurf_global_rules")" 2>/dev/null || true

    if [[ ! -f "$windsurf_global_rules" || ! -s "$windsurf_global_rules" ]]; then
        cat > "$windsurf_global_rules" << 'EOF'
# Windsurf IDE Global Rules

At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.

## Global Development Guidelines

### Context Loading
- Always reference the comprehensive DevOps framework at ~/git/aidevops/
- Read and follow the guidance in ~/AGENTS.md and ~/git/aidevops/AGENTS.md
- Maintain consistency with existing code patterns and architecture

### Security Best Practices
- Never commit credentials or sensitive information
- Use secure configuration patterns from the DevOps framework
- Follow zero-trust security principles
- Implement comprehensive error handling

### Code Quality Standards
- Maintain enterprise-grade code quality
- Use systematic quality improvement processes
- Follow established patterns for service integrations
- Write comprehensive documentation

### AI-Assisted Development
- Leverage the complete AI CLI ecosystem integration
- Use consistent DevOps framework context across all tools
- Maintain systematic approach to infrastructure automation
- Preserve comprehensive documentation standards

Refer to ~/git/aidevops/AGENTS.md for complete instructions and context.
EOF
        log_success "Created Windsurf global rules at $windsurf_global_rules"
    else
        log_info "Windsurf global rules already exist at $windsurf_global_rules"
    fi

    # Create Windsurf memory file
    local windsurf_memory="$HOME/WINDSURF.md"
    if [[ ! -f "$windsurf_memory" ]]; then
        cat > "$windsurf_memory" << 'EOF'
# Windsurf IDE Memory File

At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.

This file provides persistent memory for Windsurf IDE sessions. The authoritative DevOps framework documentation is maintained at ~/git/aidevops/AGENTS.md.

## Windsurf-Specific Guidelines
- Use Cascade AI for intelligent code generation
- Leverage Windsurf's context-aware suggestions
- Maintain project memory through .windsurfrules files
- Use Windsurf's integrated terminal for DevOps operations

## Integration with DevOps Framework
- Follow the comprehensive service integration patterns
- Use established security and quality standards
- Maintain consistency with existing AI CLI ecosystem
- Leverage multi-platform quality assurance tools
EOF
        log_success "Created Windsurf memory file at $windsurf_memory"
    fi

    log_success "Windsurf IDE configuration completed"
}

# Function to create AI Shell configuration
configure_ai_shell() {
    log_info "Configuring AI Shell with AGENTS.md context..."

    # Check if .ai-shell is a file and backup/remove it
    if [[ -f "$HOME/.ai-shell" && ! -d "$HOME/.ai-shell" ]]; then
        mv "$HOME/.ai-shell" "$HOME/.ai-shell.backup" 2>/dev/null || true
    fi

    local ai_shell_config="$HOME/.ai-shell/config.json"
    mkdir -p "$(dirname "$ai_shell_config")" 2>/dev/null || true
    
    cat > "$ai_shell_config" << 'EOF'
{
  "model": "gpt-4",
  "system_message": "You are an AI assistant with access to a comprehensive DevOps framework. Always read and follow the guidance in ~/AGENTS.md and ~/git/aidevops/AGENTS.md before performing any operations.",
  "working_directory": "~/git/aidevops",
  "auto_context": [
    "~/AGENTS.md",
    "~/git/aidevops/AGENTS.md"
  ]
}
EOF

    log_success "AI Shell configuration created at $ai_shell_config"
}

# Function to create LiteLLM configuration
configure_litellm() {
    log_info "Configuring LiteLLM with AGENTS.md context..."

    local litellm_config="$HOME/.litellm/config.yaml"
    mkdir -p "$(dirname "$litellm_config")" 2>/dev/null || true

    cat > "$litellm_config" << 'EOF'
# LiteLLM Configuration - Auto-read AGENTS.md
model_list:
  - model_name: gpt-4
    litellm_params:
      model: openai/gpt-4
      api_key: env/OPENAI_API_KEY
  - model_name: claude-3-sonnet
    litellm_params:
      model: anthropic/claude-3-sonnet-20240229
      api_key: env/ANTHROPIC_API_KEY

general_settings:
  master_key: env/LITELLM_MASTER_KEY
  database_url: sqlite:///litellm.db

# Auto-include AGENTS.md context
system_message: |
  You are an AI assistant with access to a comprehensive DevOps framework.
  Always read and follow the guidance in ~/AGENTS.md and ~/git/aidevops/AGENTS.md
  before performing any operations.

working_directory: "~/git/aidevops"
EOF

    log_success "LiteLLM configuration created at $litellm_config"
}

# Function to create shell aliases for AI tools
configure_shell_aliases() {
    log_info "Creating shell aliases for AI tools with AGENTS.md context..."

    local shell_config=""
    if [[ -f "$HOME/.zshrc" ]]; then
        shell_config="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
        shell_config="$HOME/.bashrc"
    else
        log_warning "No shell configuration file found"
        return
    fi

    # Add AI tool aliases
    cat >> "$shell_config" << 'EOF'

# AI CLI Tools - Auto-read AGENTS.md
# Added by aidevops framework

# Aider with AGENTS.md context
alias aider-guided='aider --read ~/AGENTS.md --read ~/git/aidevops/AGENTS.md'

# OpenAI CLI with context
alias openai-guided='echo "Reading AGENTS.md..." && cat ~/AGENTS.md && openai'

# Claude CLI with context
alias claude-guided='echo "Reading AGENTS.md..." && cat ~/AGENTS.md && claude'

# Qwen CLI with context
alias qwen-guided='echo "Reading AGENTS.md..." && cat ~/AGENTS.md && qwen'

# Windsurf IDE with context
alias windsurf-guided='echo "Reading AGENTS.md..." && cat ~/AGENTS.md && windsurf'

# AI Shell with context
alias ai-guided='echo "Reading AGENTS.md..." && cat ~/AGENTS.md && ai-shell'

# Quick AGENTS.md access
alias agents='cat ~/git/aidevops/AGENTS.md'
alias agents-home='cat ~/AGENTS.md'

# Navigate to AI framework
alias cdai='cd ~/git/aidevops'

EOF

    log_success "Shell aliases added to $shell_config"
}

# Function to create a universal AI wrapper script
create_ai_wrapper() {
    log_info "Creating universal AI wrapper script..."

    local wrapper_script="$HOME/.local/bin/ai-with-context"
    mkdir -p "$(dirname "$wrapper_script")" 2>/dev/null || true

    cat > "$wrapper_script" << 'EOF'
#!/bin/bash

# Universal AI CLI Wrapper - Always reads AGENTS.md first
# Usage: ai-with-context <tool> [args...]

set -euo pipefail

readonly AGENTS_FILE="$HOME/AGENTS.md"
readonly REPO_AGENTS_FILE="$HOME/git/aidevops/AGENTS.md"

# Colors
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

show_context() {
    echo -e "${BLUE}📖 Reading AI Agent Guidance...${NC}"
    echo

    if [[ -f "$AGENTS_FILE" ]]; then
        echo -e "${GREEN}📍 Home AGENTS.md:${NC}"
        head -20 "$AGENTS_FILE"
        echo
    fi

    if [[ -f "$REPO_AGENTS_FILE" ]]; then
        echo -e "${GREEN}📍 Repository AGENTS.md (first 30 lines):${NC}"
        head -30 "$REPO_AGENTS_FILE"
        echo
    fi

    echo -e "${BLUE}🚀 Launching $1 with context...${NC}"
    echo
}

main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: ai-with-context <tool> [args...]"
        echo "Available tools: aider, openai, claude, qwen, windsurf, ai-shell, litellm"
        exit 1
    fi

    local tool="$1"
    shift

    show_context "$tool"

    # Launch the specified tool
    case "$tool" in
        aider)
            aider --read "$AGENTS_FILE" --read "$REPO_AGENTS_FILE" "$@"
            ;;
        openai)
            openai "$@"
            ;;
        claude)
            claude "$@"
            ;;
        qwen)
            qwen "$@"
            ;;
        windsurf)
            # Use the appropriate Windsurf CLI path
            if [[ -f "$HOME/.codeium/windsurf/bin/windsurf" ]]; then
                "$HOME/.codeium/windsurf/bin/windsurf" "$@"
            else
                windsurf "$@"
            fi
            ;;
        ai-shell)
            ai-shell "$@"
            ;;
        litellm)
            litellm "$@"
            ;;
        *)
            echo "Unknown tool: $tool"
            exit 1
            ;;
    esac
}

main "$@"
EOF

    chmod +x "$wrapper_script"
    log_success "Universal AI wrapper created at $wrapper_script"
}

# Function to create AI memory files for various tools
create_ai_memory_files() {
    log_info "Creating AI memory files for various tools..."

    # Claude CLI memory file
    local claude_memory="$HOME/CLAUDE.md"
    if [[ ! -f "$claude_memory" ]]; then
        cat > "$claude_memory" << 'EOF'
# Claude CLI Memory File

At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.

This file provides persistent memory for Claude CLI sessions. The authoritative DevOps framework documentation is maintained at ~/git/aidevops/AGENTS.md.
EOF
        log_success "Created Claude memory file at $claude_memory"
    fi

    # Gemini CLI memory file
    local gemini_memory="$HOME/GEMINI.md"
    if [[ ! -f "$gemini_memory" ]]; then
        cat > "$gemini_memory" << 'EOF'
# Gemini CLI Memory File

At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.

This file provides persistent memory for Gemini CLI sessions. The authoritative DevOps framework documentation is maintained at ~/git/aidevops/AGENTS.md.
EOF
        log_success "Created Gemini memory file at $gemini_memory"
    fi

    # Cursor AI rules file
    local cursor_rules="$HOME/.cursorrules"
    if [[ ! -f "$cursor_rules" ]]; then
        cat > "$cursor_rules" << 'EOF'
# Cursor AI Rules

At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.

This file provides persistent rules for Cursor AI. The authoritative DevOps framework documentation is maintained at ~/git/aidevops/AGENTS.md.

## Project Context
- Always reference the comprehensive DevOps framework at ~/git/aidevops/
- Follow security best practices outlined in AGENTS.md
- Maintain consistency with existing code patterns and architecture
EOF
        log_success "Created Cursor rules file at $cursor_rules"
    fi

    # Windsurf IDE memory file (handled in configure_windsurf_ide function)
    # This ensures consistency across all AI memory files
    if [[ ! -f "$HOME/WINDSURF.md" ]]; then
        log_info "Windsurf memory file will be created by configure_windsurf_ide function"
    fi

    # GitHub Copilot instructions
    local copilot_instructions="$HOME/.github/copilot-instructions.md"
    mkdir -p "$(dirname "$copilot_instructions")" 2>/dev/null || true
    if [[ ! -f "$copilot_instructions" ]]; then
        cat > "$copilot_instructions" << 'EOF'
# GitHub Copilot Instructions

At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.

This file provides persistent instructions for GitHub Copilot. The authoritative DevOps framework documentation is maintained at ~/git/aidevops/AGENTS.md.

## Development Guidelines
- Follow the comprehensive DevOps framework patterns
- Maintain security best practices
- Use consistent coding standards across all projects
EOF
        log_success "Created GitHub Copilot instructions at $copilot_instructions"
    fi

    # Factory.ai/Drone memory (if directory exists)
    if [[ -d "$HOME/.factory" ]]; then
        local factory_memory="$HOME/.factory/DRONE.md"
        if [[ ! -f "$factory_memory" ]]; then
            cat > "$factory_memory" << 'EOF'
# Factory.ai Drone Memory File

At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.

This file provides persistent memory for Factory.ai Drone sessions. The authoritative DevOps framework documentation is maintained at ~/git/aidevops/AGENTS.md.
EOF
            log_success "Created Factory.ai Drone memory file at $factory_memory"
        fi
    fi

    log_success "AI memory files created/verified for all detected tools"
}

# Function to create project-level AI memory files
create_project_memory_files() {
    log_info "Creating project-level AI memory files..."

    local project_root="$REPO_AGENTS_FILE"
    local project_dir="$(dirname "$project_root")"

    # Claude project memory
    local claude_project="$project_dir/CLAUDE.md"
    if [[ ! -f "$claude_project" ]]; then
        cat > "$claude_project" << 'EOF'
# Claude CLI Project Memory

This is the authoritative AI DevOps Framework project.

## Project Overview
- **Purpose**: Comprehensive DevOps automation and AI integration framework
- **Architecture**: 25+ service integrations, 10 MCP servers, multi-platform quality control
- **Security**: Enterprise-grade security practices with zero-trust principles
- **Quality**: Multi-platform quality assurance (Codacy, SonarCloud, CodeRabbit, Qlty)

## Key Components
- **Service Providers**: AWS, Hetzner, Cloudflare, Hostinger, and 20+ others
- **AI Integration**: Complete AI CLI ecosystem with automatic context loading
- **Quality Control**: Comprehensive code quality and security scanning
- **Documentation**: Extensive documentation in docs/ directory

## Development Guidelines
- Follow security best practices outlined in AGENTS.md
- Maintain zero technical debt standards
- Use systematic quality improvement processes
- Preserve enterprise-grade functionality

Refer to AGENTS.md for complete instructions and context.
EOF
        log_success "Created Claude project memory at $claude_project"
    fi

    # Cursor project rules
    local cursor_project="$project_dir/.cursorrules"
    if [[ ! -f "$cursor_project" ]]; then
        cat > "$cursor_project" << 'EOF'
# AI DevOps Framework - Cursor Rules

This is the authoritative AI DevOps Framework project.

## Project Context
- **Framework**: Comprehensive DevOps automation with 25+ service integrations
- **Quality Standards**: Enterprise-grade with multi-platform quality assurance
- **Security**: Zero-trust security principles with comprehensive scanning
- **AI Integration**: Complete AI CLI ecosystem with automatic context loading

## Development Rules
1. **Security First**: Never commit credentials, use secure configuration patterns
2. **Quality Standards**: Maintain zero technical debt, use systematic improvements
3. **Documentation**: Keep comprehensive documentation, follow existing patterns
4. **Testing**: Write tests for all new functionality, maintain coverage
5. **Consistency**: Follow established code patterns and architecture

## File Structure
- `providers/`: Service integration helpers
- `scripts/`: Automation and utility scripts
- `configs/`: Configuration templates (never commit with real credentials)
- `docs/`: Comprehensive documentation
- `.agent/`: AI assistant configurations and tools

Refer to AGENTS.md for complete instructions and context.
EOF
        log_success "Created Cursor project rules at $cursor_project"
    fi

    # Gemini project memory
    local gemini_project="$project_dir/GEMINI.md"
    if [[ ! -f "$gemini_project" ]]; then
        cat > "$gemini_project" << 'EOF'
# Gemini CLI Project Memory

This is the authoritative AI DevOps Framework project.

## Project Overview
Comprehensive DevOps automation framework with enterprise-grade quality standards, 25+ service integrations, and complete AI CLI ecosystem integration.

## Key Features
- **Multi-Platform Quality**: Codacy (perfect scores), SonarCloud (A-grade), CodeRabbit, Qlty
- **Service Coverage**: AWS, Hetzner, Cloudflare, Hostinger, Coolify, Cloudron, and 20+ others
- **AI Integration**: Automatic AGENTS.md context loading across all AI tools
- **Security**: Enterprise-grade security with comprehensive vulnerability scanning

## Development Context
- Follow security best practices and zero-trust principles
- Maintain systematic quality improvement processes
- Use established patterns for service integrations
- Preserve comprehensive documentation standards

Refer to AGENTS.md for complete instructions and context.
EOF
        log_success "Created Gemini project memory at $gemini_project"
    fi

    # Windsurf project rules
    local windsurf_project="$project_dir/.windsurfrules"
    if [[ ! -f "$windsurf_project" ]]; then
        cat > "$windsurf_project" << 'EOF'
# AI DevOps Framework - Windsurf Rules

At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.

This is the authoritative AI DevOps Framework project.

## Project Context
- **Framework**: Comprehensive DevOps automation with 25+ service integrations
- **Quality Standards**: Enterprise-grade with multi-platform quality assurance
- **Security**: Zero-trust security principles with comprehensive scanning
- **AI Integration**: Complete AI CLI ecosystem with automatic context loading

## Windsurf-Specific Development Rules
1. **Cascade AI Integration**: Leverage Windsurf's Cascade AI for intelligent code generation
2. **Context Awareness**: Use Windsurf's superior context understanding for complex operations
3. **Memory Management**: Utilize Windsurf's memory system for project continuity
4. **Terminal Integration**: Use Windsurf's integrated terminal for DevOps operations

## Development Guidelines
1. **Security First**: Never commit credentials, use secure configuration patterns
2. **Quality Standards**: Maintain zero technical debt, use systematic improvements
3. **Documentation**: Keep comprehensive documentation, follow existing patterns
4. **Testing**: Write tests for all new functionality, maintain coverage
5. **Consistency**: Follow established code patterns and architecture

## File Structure
- `providers/`: Service integration helpers
- `scripts/`: Automation and utility scripts
- `configs/`: Configuration templates (never commit with real credentials)
- `docs/`: Comprehensive documentation
- `.agent/`: AI assistant configurations and tools

## AI Integration Features
- **Multi-Platform Quality**: Codacy, SonarCloud, CodeRabbit, Qlty integration
- **Service Coverage**: AWS, Hetzner, Cloudflare, Hostinger, and 20+ others
- **AI CLI Ecosystem**: Automatic AGENTS.md context loading across all tools
- **Security Scanning**: Comprehensive vulnerability detection and prevention

Refer to AGENTS.md for complete instructions and context.
EOF
        log_success "Created Windsurf project rules at $windsurf_project"
    fi

    log_success "Project-level AI memory files created/verified"
}

# Main configuration function
main() {
    echo "🤖 AI CLI Configuration Script"
    echo "================================"
    echo

    # Verify AGENTS.md files exist
    if [[ ! -f "$AGENTS_FILE" ]]; then
        log_error "~/AGENTS.md not found. Run setup.sh first."
        exit 1
    fi

    if [[ ! -f "$REPO_AGENTS_FILE" ]]; then
        log_error "Repository AGENTS.md not found at $REPO_AGENTS_FILE"
        exit 1
    fi

    # Configure each AI CLI
    configure_aider
    configure_openai_cli
    configure_claude_cli
    configure_qwen_cli
    configure_windsurf_ide
    configure_ai_shell
    configure_litellm
    configure_shell_aliases
    create_ai_wrapper
    create_ai_memory_files
    create_project_memory_files

    echo
    log_success "All AI CLI tools configured to read AGENTS.md automatically!"
    echo
    log_info "Available commands:"
    echo "  • aider-guided    - Aider with AGENTS.md context"
    echo "  • claude-guided   - Claude CLI with AGENTS.md context"
    echo "  • qwen-guided     - Qwen CLI with AGENTS.md context"
    echo "  • windsurf-guided - Windsurf IDE with AGENTS.md context"
    echo "  • ai-with-context - Universal wrapper for any AI tool"
    echo "  • agents          - View repository AGENTS.md"
    echo "  • cdai            - Navigate to AI framework"
    echo
    log_info "Next steps:"
    echo "  1. Restart your shell: source ~/.zshrc (or ~/.bashrc)"
    echo "  2. Test with: aider-guided --help"
    echo "  3. Try: ai-with-context aider"
}

# Run main function
main "$@"
