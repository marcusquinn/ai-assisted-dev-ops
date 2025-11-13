# AI DevOps Framework Context

This file provides comprehensive context for AI assistants to understand, manage, and extend the AI DevOps Framework.

## 🎯 **Framework Overview**

### **Complete DevOps Ecosystem (25+ Services)**

The AI DevOps Framework provides unified management across:

**🏗️ Infrastructure & Hosting (4 services):**

- Hostinger (shared hosting), Hetzner Cloud (VPS/cloud), Closte (VPS), Cloudron (app platform)

**🚀 Deployment & Orchestration (1 service):**

- Coolify (self-hosted PaaS)

**🎯 Content Management (1 service):**

- MainWP (WordPress management)

**🔐 Security & Secrets (1 service):**

- Vaultwarden (password/secrets management)

**🔍 Code Quality & Auditing (4 services):**

- CodeRabbit (AI reviews), CodeFactor (quality), Codacy (quality & security), SonarCloud (professional)

**📚 Version Control & Git Platforms (4 services):**

- GitHub, GitLab, Gitea, Local Git

**📧 Email Services (1 service):**

- Amazon SES (email delivery)

**🌐 Domain & DNS (5 services):**

- Spaceship (with purchasing), 101domains, Cloudflare DNS, Namecheap DNS, Route 53

**🏠 Development & Local (4 services):**

- Localhost (.local domains), LocalWP (WordPress dev), Context7 MCP (docs), MCP Servers

**🧙‍♂️ Setup & Configuration (1 service):**

- Intelligent Setup Wizard

## 🛠️ **Framework Architecture**

### **Unified Command Patterns**

All services follow consistent patterns for AI assistant efficiency:

```bash
# Standard pattern: ./providers/[service]-helper.sh [command] [account/instance] [target] [options]

# List/Status Commands
./providers/[service]-helper.sh [accounts|instances|servers|sites]

# Management Commands
./providers/[service]-helper.sh [action] [account/instance] [target] [options]

# Monitoring Commands
./providers/[service]-helper.sh [monitor|audit|status] [account/instance]

# Help Commands
./providers/[service]-helper.sh help
```

### **Configuration Structure**

```bash
# Configuration pattern:
configs/[service]-config.json.txt  # Template (committed)
configs/[service]-config.json      # Working config (gitignored)

# All configs follow consistent JSON structure:
{
  "accounts": {
    "account-name": {
      "api_token": "TOKEN_HERE",
      "base_url": "https://api.service.com",
      "description": "Account description"
    }
  },
  "default_settings": { ... },
  "mcp_servers": { ... }
}
```

### **Documentation Structure**

```bash
docs/[SERVICE].md                   # Complete service guide
docs/BEST-PRACTICES.md              # Provider selection guide
ai-context.md                       # AI assistant framework context (this file)
```

## 🚀 **Framework Usage Examples**

### **Complete Project Setup Workflow**

```bash
# 1. Setup wizard for intelligent guidance
./providers/setup-wizard-helper.sh full-setup

# 2. Domain research and purchase
./providers/spaceship-helper.sh bulk-check personal myproject.com myproject.dev
./providers/spaceship-helper.sh purchase personal myproject.com 1 true

# 3. Git repository creation
./providers/git-platforms-helper.sh github-create personal myproject "Description" false
./providers/git-platforms-helper.sh local-init ~/projects myproject

# 4. Infrastructure provisioning
./providers/hetzner-helper.sh create-server production myproject

# 5. DNS configuration
./providers/dns-helper.sh add cloudflare personal myproject.com @ A 192.168.1.100

# 6. Application deployment
./providers/coolify-helper.sh deploy production myproject

# 7. Security setup
./providers/vaultwarden-helper.sh create production "MyProject Creds" user pass

# 8. Code quality setup
./providers/code-audit-helper.sh audit myproject

# 9. Monitoring setup
./providers/ses-helper.sh monitor production
```

### **Multi-Service Operations**

```bash
# Comprehensive infrastructure audit
for service in hostinger hetzner coolify mainwp; do
    ./providers/${service}-helper.sh monitor production
done

# Bulk domain management
./providers/spaceship-helper.sh bulk-check personal \
  project1.com project2.com project3.com

# Cross-platform Git management
./providers/git-platforms-helper.sh audit github personal
./providers/git-platforms-helper.sh audit gitlab personal
```

## 🔧 **MCP Server Ecosystem**

### **Available MCP Servers**

```bash
# Complete MCP server stack for AI assistants:
./providers/localhost-helper.sh start-mcp          # Port 3001 - LocalWP access
./providers/vaultwarden-helper.sh start-mcp production 3002  # Secure credentials
./providers/code-audit-helper.sh start-mcp coderabbit 3003   # Code analysis
./providers/code-audit-helper.sh start-mcp codacy 3004       # Quality metrics
./providers/code-audit-helper.sh start-mcp sonarcloud 3005   # Security analysis
./providers/git-platforms-helper.sh start-mcp github 3006    # Git management
./providers/git-platforms-helper.sh start-mcp gitlab 3007    # GitLab access
./providers/git-platforms-helper.sh start-mcp gitea 3008     # Gitea access
```

### **MCP Integration Benefits**

- **Real-time data access** from all services
- **Contextual AI responses** based on current infrastructure state
- **Secure credential retrieval** through Vaultwarden MCP
- **Live code analysis** through code auditing MCPs
- **Dynamic documentation** through Context7 MCP

## 📊 **Framework Extension Guide**

### **Adding New Providers/Services**

#### **1. Create Helper Script**

```bash
# File: providers/[service-name]-helper.sh
#!/bin/bash

# [Service Name] Helper Script
# [Brief description of service]

# Standard header with colors and functions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CONFIG_FILE="../configs/[service-name]-config.json"

# Standard functions:
# - check_dependencies()
# - load_config()
# - get_account_config()
# - api_request()
# - list_accounts()
# - [service-specific functions]
# - show_help()
# - main()
```

#### **2. Create Configuration Template**

```bash
# File: configs/[service-name]-config.json.txt
{
  "accounts": {
    "personal": {
      "api_token": "YOUR_[SERVICE]_API_TOKEN_HERE",
      "base_url": "https://api.[service].com",
      "description": "Personal [service] account"
    }
  },
  "default_settings": {
    "timeout": 30,
    "rate_limit": 60
  },
  "mcp_servers": {
    "[service]": {
      "enabled": true,
      "port": 30XX,
      "host": "localhost"
    }
  }
}
```

#### **3. Create Comprehensive Documentation**

```bash
# File: docs/[SERVICE-NAME].md
# [Service Name] Guide

## 🏢 **Provider Overview**
### **[Service] Characteristics:**
- **Service Type**: [Description]
- **Strengths**: [Key benefits]
- **API Support**: [API capabilities]
- **MCP Integration**: [MCP availability]
- **Use Case**: [Primary use cases]

## 🔧 **Configuration**
[Setup instructions]

## 🚀 **Usage Examples**
[Command examples]

## 🛡️ **Security Best Practices**
[Security guidelines]

## 📊 **MCP Integration**
[MCP setup and capabilities]

## 🔍 **Troubleshooting**
[Common issues and solutions]

## 📚 **Best Practices**
[Service-specific best practices]

## 🎯 **AI Assistant Integration**
[AI automation capabilities]
```

#### **4. Update Framework Files**

```bash
# Update .gitignore
echo "configs/[service-name]-config.json" >> .gitignore

# Update README.md
# Add service to provider list and file structure

# Update BEST-PRACTICES.md
# Add service to appropriate category

# Update setup-wizard-helper.sh
# Add service to recommendations logic
```

### **Framework Standards & Conventions**

#### **Naming Conventions**

```bash
# Helper scripts: [service-name]-helper.sh (lowercase, hyphenated)
# Config files: [service-name]-config.json.txt (template)
# Config files: [service-name]-config.json (working, gitignored)
# Documentation: [SERVICE-NAME].md (uppercase, hyphenated)
# Functions: [action_description] (lowercase, underscored)
# Variables: [CONSTANT_NAME] (uppercase, underscored)
```

#### **Code Standards**

```bash
# All helper scripts must include:
1. Shebang: #!/bin/bash
2. Description comment block
3. Color definitions and print functions
4. CONFIG_FILE variable
5. check_dependencies() function
6. load_config() function
7. show_help() function
8. main() function with case statement
9. Consistent error handling
10. Proper exit codes
```

#### **Security Standards**

```bash
# All services must implement:
1. API token validation
2. Rate limiting awareness
3. Secure credential storage
4. Input validation
5. Error message sanitization
6. Audit logging capabilities
7. Confirmation prompts for destructive operations
8. Encrypted data handling where applicable
```

#### **Documentation Standards**

```bash
# All documentation must include:
1. Provider overview with characteristics
2. Configuration setup instructions
3. Usage examples with real commands
4. Security best practices
5. MCP integration details
6. Troubleshooting section
7. Best practices section
8. AI assistant integration capabilities
```

## 📋 **AI Assistant Operational Guidelines**

### **Framework Usage Principles**

1. **Consistency First**: Always use framework patterns and conventions
2. **Security Awareness**: Never expose credentials or sensitive data
3. **Confirmation Required**: Confirm destructive operations and purchases
4. **Context Utilization**: Use Context7 MCP for latest service documentation
5. **Error Handling**: Implement robust error handling and user feedback
6. **Audit Trails**: Log important operations for accountability

### **Extension Best Practices**

1. **Research First**: Check if service already has API and MCP support
2. **Follow Patterns**: Use existing helpers as templates for consistency
3. **Security Focus**: Implement security measures from the start
4. **Documentation**: Create comprehensive documentation alongside code
5. **Testing**: Test all functions before integration
6. **Integration**: Update all framework files for complete integration

### **Maintenance Guidelines**

1. **Regular Updates**: Keep service APIs and MCPs current
2. **Security Audits**: Regular security reviews of all integrations
3. **Documentation Sync**: Keep documentation synchronized with code
4. **Dependency Management**: Monitor and update dependencies
5. **Performance Optimization**: Optimize for AI assistant efficiency

### **Quality Assurance**

1. **Code Review**: All additions should follow framework standards
2. **Security Review**: Security implications of all new integrations
3. **Documentation Review**: Ensure documentation completeness
4. **Integration Testing**: Test integration with existing services
5. **User Experience**: Optimize for AI assistant and user experience

## 🌟 **Framework Evolution Strategy**

### **Continuous Improvement**

- **Service Monitoring**: Monitor for new services and APIs
- **Technology Adoption**: Adopt new technologies that enhance capabilities
- **User Feedback**: Incorporate user feedback for improvements
- **AI Advancement**: Adapt to new AI assistant capabilities
- **Security Evolution**: Stay current with security best practices

### **Scalability Considerations**

- **Modular Design**: Maintain modular architecture for easy extension
- **Performance**: Optimize for performance at scale
- **Resource Management**: Efficient resource utilization
- **Error Recovery**: Robust error recovery mechanisms
- **Load Distribution**: Distribute load across services appropriately

---

**This comprehensive context enables AI assistants to not only use the framework effectively but also extend and maintain it following established patterns, security practices, and quality standards. The framework is designed to evolve continuously while maintaining consistency, security, and usability.** 🚀🤖✨
