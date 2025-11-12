# AI CLI Configuration - AGENTS.md Auto-Reading

**🎯 OBJECTIVE**: Ensure all AI CLI tools automatically read `~/AGENTS.md` and `~/git/ai-assisted-dev-ops/AGENTS.md` at the start of every session for consistent AI agent guidance.

## 🤖 **CONFIGURED AI TOOLS**

### **✅ FULLY CONFIGURED:**

### **1. Aider AI**
- **Config File**: `~/.aider.conf.yml`
- **Auto-reads**: Both AGENTS.md files on every session start
- **Model**: `openrouter/anthropic/claude-sonnet-4`
- **Working Directory**: `~/git/ai-assisted-dev-ops`
- **Usage**: `aider` (automatic) or `aider-guided` (explicit)

### **2. OpenAI CLI**
- **Config File**: `~/.openai/config.yaml`
- **System Message**: Includes AGENTS.md guidance
- **Model**: `gpt-4`
- **Usage**: `openai` or `openai-guided`

### **3. Claude CLI**
- **Config File**: `~/.claude/config.json`
- **Auto-reads**: Both AGENTS.md files
- **Model**: `claude-3-sonnet-20240229`
- **Usage**: `claude` or `claude-guided`

### **4. AI Shell**
- **Config File**: `~/.ai-shell/config.json`
- **Auto Context**: Both AGENTS.md files
- **Model**: `gpt-4`
- **Usage**: `ai-shell` or `ai-guided`

### **5. LiteLLM**
- **Config File**: `~/.litellm/config.yaml`
- **System Message**: Includes AGENTS.md guidance
- **Multi-model**: OpenAI, Anthropic, others
- **Usage**: `litellm`

## 🔧 **SHELL INTEGRATION**

### **✅ ALIASES CREATED:**
```bash
# AI tools with explicit AGENTS.md context
alias aider-guided='aider --read ~/AGENTS.md --read ~/git/ai-assisted-dev-ops/AGENTS.md'
alias openai-guided='echo "Reading AGENTS.md..." && cat ~/AGENTS.md && openai'
alias claude-guided='echo "Reading AGENTS.md..." && cat ~/AGENTS.md && claude'
alias ai-guided='echo "Reading AGENTS.md..." && cat ~/AGENTS.md && ai-shell'

# Quick AGENTS.md access
alias agents='cat ~/git/ai-assisted-dev-ops/AGENTS.md'
alias agents-home='cat ~/AGENTS.md'

# Navigate to AI framework
alias cdai='cd ~/git/ai-assisted-dev-ops'
```

### **✅ UNIVERSAL WRAPPER:**
- **Script**: `~/.local/bin/ai-with-context`
- **Usage**: `ai-with-context <tool> [args...]`
- **Features**: 
  - Shows AGENTS.md content before launching any AI tool
  - Supports: aider, openai, claude, ai-shell, litellm
  - Provides consistent context across all tools

## 🚀 **USAGE EXAMPLES**

### **Direct Tool Usage (Auto-configured):**
```bash
# Aider automatically reads AGENTS.md
aider

# OpenAI CLI with system message including AGENTS.md guidance
openai api completions.create -m gpt-4 -p "Help with DevOps"

# Claude CLI with auto-context
claude -p "Review infrastructure setup"
```

### **Explicit Context Usage:**
```bash
# Aider with explicit AGENTS.md reading
aider-guided

# Universal wrapper (shows AGENTS.md first)
ai-with-context aider
ai-with-context openai
ai-with-context claude
```

### **Quick Reference:**
```bash
# View repository AGENTS.md
agents

# View home AGENTS.md
agents-home

# Navigate to AI framework
cdai
```

## 📋 **CONFIGURATION FILES CREATED**

### **1. Aider Configuration** (`~/.aider.conf.yml`)
- Auto-reads both AGENTS.md files
- Uses Claude Sonnet 4 via OpenRouter
- Working directory set to framework root
- Git integration enabled

### **2. OpenAI CLI Configuration** (`~/.openai/config.yaml`)
- System message includes AGENTS.md guidance
- Default model: GPT-4
- Working directory configured

### **3. Claude CLI Configuration** (`~/.claude/config.json`)
- Auto-reads both AGENTS.md files
- System message with framework context
- Claude 3 Sonnet model

### **4. AI Shell Configuration** (`~/.ai-shell/config.json`)
- Auto-context includes both AGENTS.md files
- GPT-4 model
- Framework working directory

### **5. LiteLLM Configuration** (`~/.litellm/config.yaml`)
- Multi-model support (OpenAI, Anthropic)
- System message with AGENTS.md guidance
- Database and master key configuration

## 🔄 **SETUP INTEGRATION**

### **✅ AUTOMATIC SETUP:**
The main `setup.sh` script now includes:
```bash
configure_ai_clis    # Runs .agent/scripts/ai-cli-config.sh
```

### **✅ MANUAL CONFIGURATION:**
```bash
# Run AI CLI configuration script
cd ~/git/ai-assisted-dev-ops
bash .agent/scripts/ai-cli-config.sh

# Restart shell to load aliases
source ~/.zshrc  # or ~/.bashrc
```

## 🎯 **BENEFITS ACHIEVED**

### **✅ CONSISTENCY:**
- All AI tools receive the same foundational guidance
- Consistent working directories and security protocols
- Unified approach to DevOps framework usage

### **✅ SECURITY:**
- AGENTS.md provides security warnings and best practices
- Prevents prompt injection by using authoritative source
- Consistent credential handling across tools

### **✅ EFFICIENCY:**
- No need to manually provide context each time
- Quick access to framework documentation
- Streamlined AI-assisted DevOps workflows

### **✅ FLEXIBILITY:**
- Both automatic and explicit context options
- Universal wrapper for any AI tool
- Easy navigation and reference commands

**🎉 RESULT: All AI CLI tools now automatically read AGENTS.md for consistent, secure, and efficient AI-assisted DevOps operations!**
