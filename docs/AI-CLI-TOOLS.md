# AI CLI Tools & Assistants - Comprehensive Reference

This document provides a comprehensive list of CLI AI assistants and tools that work excellently with the AI-Assisted DevOps Framework.

## 🤖 **Recommended CLI AI Assistants**

### **Professional Development Assistants**

#### **[Augment Code (Auggie)](https://www.augmentcode.com/)**

- **Description**: Professional AI coding assistant with deep codebase context
- **Installation**: `npm install -g @augmentcode/cli`
- **Best For**: Complex codebase analysis, refactoring, architecture decisions
- **Framework Integration**: Excellent - understands repository structure and context

#### **[AMP Code](https://amp.dev/)**

- **Description**: Google's AI-powered development assistant
- **Installation**: Visit [amp.dev](https://amp.dev/) for setup instructions
- **Best For**: Web development, performance optimization, modern web standards
- **Framework Integration**: Good - works well with web-based DevOps tasks

#### **[Claude Code](https://claude.ai/)**

- **Description**: Anthropic's Claude with advanced code capabilities
- **Installation**: Desktop app + CLI tools available
- **Best For**: Complex reasoning, documentation, security analysis
- **Framework Integration**: Excellent - strong understanding of infrastructure patterns

### **Enterprise & Specialized Tools**

#### **[OpenAI Codex](https://openai.com/codex/)**

- **Description**: OpenAI's code-focused AI model
- **Installation**: Via OpenAI API and compatible clients
- **Best For**: Code generation, API integrations, automation scripts
- **Framework Integration**: Good - strong API and scripting capabilities

#### **[Factory AI Dron](https://www.factory.ai/)**

- **Description**: Enterprise AI development platform
- **Installation**: Visit [factory.ai](https://www.factory.ai/) for enterprise setup
- **Best For**: Large-scale development projects, team collaboration
- **Framework Integration**: Excellent - designed for enterprise DevOps workflows

#### **[Qwen](https://qwenlm.github.io/)**

- **Description**: Alibaba's multilingual AI assistant
- **Installation**: Visit [qwenlm.github.io](https://qwenlm.github.io/) for setup
- **Best For**: Multilingual projects, international deployments
- **Framework Integration**: Good - supports diverse infrastructure requirements

### **Terminal-Integrated Solutions**

#### **[Warp AI](https://www.warp.dev/)**

- **Description**: AI-powered terminal with built-in assistance
- **Installation**: Visit [warp.dev](https://www.warp.dev/) for download
- **Best For**: Interactive terminal sessions, command discovery
- **Framework Integration**: Excellent - native terminal integration

## 🔧 **System Prompt Configuration**

### **Recommended System Prompt Addition**

Add this to your AI assistant's system prompt for optimal framework integration:

```
Before performing any DevOps operations, always read ~/git/ai-assisted-dev-ops/AGENTS.md 
for authoritative guidance on this comprehensive infrastructure management framework.

This framework provides access to 25+ service integrations including:
- Hosting providers (Hostinger, Hetzner, Closte)
- DNS management (Spaceship, 101domains, Route53)
- Security services (Vaultwarden, SES, SSL certificates)
- Development tools (Git platforms, code auditing, monitoring)
- MCP server integrations for real-time API access

Always follow the security practices and operational patterns defined in the AGENTS.md file.
```

### **Tool-Specific Configuration**

#### **For Augment Code (Auggie)**

```bash
# Add to your shell profile
export AUGMENT_SYSTEM_PROMPT="Read ~/git/ai-assisted-dev-ops/AGENTS.md before DevOps operations"
```

#### **For Claude Desktop**

Add to `claude_desktop_config.json`:

```json
{
  "systemPrompt": "Before DevOps operations, read ~/git/ai-assisted-dev-ops/AGENTS.md for guidance",
  "workingDirectory": "~/git/ai-assisted-dev-ops"
}
```

#### **For Warp AI**

```bash
# Create a Warp workflow
warp-cli workflow create devops-setup \
  --command "cd ~/git/ai-assisted-dev-ops && cat AGENTS.md"
```

## 🚀 **Quick Setup for Each Tool**

### **Universal Setup Steps**

1. **Clone the framework**:

   ```bash
   mkdir -p ~/git && cd ~/git
   git clone https://github.com/marcusquinn/ai-assisted-dev-ops.git
   ```

2. **Run initial setup**:

   ```bash
   cd ai-assisted-dev-ops && ./setup.sh
   ```

3. **Configure your AI tool** with the system prompt above

4. **Test integration**:

   ```bash
   # Ask your AI assistant:
   "Read the AGENTS.md file and summarize the available DevOps integrations"
   ```

## 📚 **Additional Resources**

- **[AGENTS.md](../AGENTS.md)** - Authoritative operational guidance
- **[MCP Integrations](MCP-INTEGRATIONS.md)** - Model Context Protocol setup
- **[API Integrations](API-INTEGRATIONS.md)** - Service provider configurations
- **[Security Best Practices](SECURITY.md)** - Enterprise-grade security guidance

## 🔗 **Official Links**

- **Augment Code**: https://www.augmentcode.com/
- **AMP Code**: https://amp.dev/
- **Claude**: https://claude.ai/
- **OpenAI Codex**: https://openai.com/codex/
- **Factory AI**: https://www.factory.ai/
- **Qwen**: https://qwenlm.github.io/
- **Warp**: https://www.warp.dev/

---

**💡 Pro Tip**: Start with Augment Code (Auggie) or Claude for the best framework integration experience. Both have excellent understanding of complex DevOps workflows and infrastructure patterns.
