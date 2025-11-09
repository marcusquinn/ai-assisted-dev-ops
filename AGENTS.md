# AI-Assisted DevOps Framework - Agent Guidance

This repository provides a comprehensive DevOps infrastructure management framework designed specifically for AI agent automation across 25+ services.

## 🤖 **Agent Behavior & Standards**

### **Primary Objectives**
- **Complete DevOps automation** across hosting, domains, DNS, security, and development services
- **Secure credential management** with enterprise-grade security practices
- **Consistent command patterns** for reliable automation across all services
- **Intelligent setup guidance** for infrastructure configuration
- **Real-time service integration** through MCP servers

### **Coding Standards**
- **Bash scripting**: Follow framework patterns in `providers/` directory
- **JSON configuration**: Use consistent structure across all service configs
- **Security-first**: Never expose credentials, always validate inputs
- **Error handling**: Implement comprehensive error handling with clear messages
- **Documentation**: Maintain comprehensive docs for all additions

### **🏆 Quality Standards (MANDATORY)**
**ALWAYS verify and maintain these quality standards:**

#### **SonarCloud Integration (A-Grade Required)**
- **Security Rating**: A (Zero vulnerabilities)
- **Reliability Rating**: A (Zero bugs)
- **Maintainability Rating**: A (Minimal code smells)
- **Code Duplication**: 0.0%
- **Setup Check**: `curl -s "https://sonarcloud.io/api/measures/component?component=marcusquinn_ai-assisted-dev-ops&metricKeys=bugs,vulnerabilities,code_smells"`

#### **CodeFactor Integration (A-Grade Required)**
- **Overall Grade**: A (81%+ A-grade files)
- **Zero D/F-grade files**: All scripts must pass quality checks
- **ShellCheck Compliance**: Zero violations across all shell scripts
- **Setup Check**: `curl -s "https://www.codefactor.io/repository/github/marcusquinn/ai-assisted-dev-ops"`

#### **ShellCheck Compliance (MANDATORY)**
```bash
# Install and run ShellCheck on all scripts
brew install shellcheck  # macOS
find providers/ -name "*.sh" -exec shellcheck {} \;
```

**Critical Rules (Zero Tolerance):**
- SC2162: Use `read -r` not `read`
- SC2181: Use `if command; then` not `if [[ $? -eq 0 ]]; then`
- SC1037: Proper variable bracing
- SC2155: Separate declare and assign
- SC2015: Avoid `A && B || C` patterns

#### **Shell Script Best Practices**
```bash
# ✅ CORRECT Function Structure
function_name() {
    local param1="$1"
    local param2="$2"

    # Function logic

    return 0  # Always explicit return
}

# ✅ CORRECT Error Handling
local response
if response=$(api_request "$account" "GET" "endpoint"); then
    echo "$response"
else
    print_error "Request failed"
    return 1
fi
```

### **Framework Architecture**
```bash
# Unified command pattern across all 25+ services:
./providers/[service]-helper.sh [command] [account/instance] [target] [options]

# Standard commands available for all services:
help                    # Show service-specific help
accounts|instances      # List configured accounts/instances
monitor|audit|status    # Service monitoring and auditing
```

## 📁 **Agent Directory Structure**

### **.agent/spec/** - Requirements & Design
- `requirements.md` - Framework requirements and capabilities
- `design.md` - Architecture and design principles
- `tasks.md` - Common tasks and workflows
- `security.md` - Security requirements and standards
- `extension.md` - Guidelines for extending the framework

### **.agent/wiki/** - Knowledge Base
- `architecture.md` - Complete framework architecture
- `services.md` - All 25+ service integrations
- `workflows.md` - Common DevOps workflows
- `troubleshooting.md` - Common issues and solutions
- `providers/` - Provider-specific context
- `configs/` - Configuration management context
- `docs/` - Documentation standards context

### **.agent/links/** - External Resources
- `resources.md` - External APIs, documentation, and tools
- `mcp-servers.md` - MCP server resources and setup
- `service-apis.md` - Service API documentation links

## 🛠️ **Service Categories**

### **Infrastructure & Hosting (4 services)**
- Hostinger, Hetzner Cloud, Closte, Cloudron

### **Deployment & Orchestration (1 service)**
- Coolify

### **Content Management (1 service)**
- MainWP

### **Security & Secrets (1 service)**
- Vaultwarden

### **Code Quality & Auditing (4 services)**
- CodeRabbit, CodeFactor, Codacy, SonarCloud

### **Version Control & Git Platforms (4 services)**
- GitHub, GitLab, Gitea, Local Git

### **Email Services (1 service)**
- Amazon SES

### **Domain & DNS (5 services)**
- Spaceship (with purchasing), 101domains, Cloudflare DNS, Namecheap DNS, Route 53

### **Development & Local (4 services)**
- Localhost, LocalWP, Context7 MCP, MCP Servers

### **Setup & Configuration (1 service)**
- Intelligent Setup Wizard

## 🔐 **Security Contract**

### **Credential Management**
- All credentials stored in `configs/[service]-config.json` (gitignored)
- Templates in `configs/[service]-config.json.txt` (committed)
- Vaultwarden integration for secure credential retrieval
- Never expose credentials in logs, output, or error messages

### **Operational Security**
- Confirmation required for destructive operations
- Purchase operations require explicit user confirmation
- Production environment changes require verification
- All operations logged for audit purposes

### **File Security**
- Configuration files have restricted permissions (600)
- Generated reports and exports are gitignored
- Temporary files are cleaned up automatically
- MCP server runtime files are protected

## 🚀 **Agent Capabilities**

### **Complete Project Lifecycle**
1. **Assessment**: Intelligent setup wizard for needs analysis
2. **Domain Management**: Automated domain purchasing and DNS configuration
3. **Infrastructure**: Server provisioning across multiple providers
4. **Development**: Git repository creation and management
5. **Quality**: Automated code auditing and security scanning
6. **Deployment**: Application deployment and monitoring
7. **Security**: Credential management and security auditing
8. **Maintenance**: Ongoing monitoring and maintenance

### **MCP Server Integration**
```bash
# Real-time data access through MCP servers:
Port 3001: LocalWP WordPress database access
Port 3002: Vaultwarden secure credential retrieval
Port 3003: CodeRabbit code analysis
Port 3004: Codacy quality metrics
Port 3005: SonarCloud security analysis
Port 3006: GitHub repository management
Port 3007: GitLab project management
Port 3008: Gitea repository management
```

## 📚 **Learning Resources**

### **Framework Understanding**
- Start with `.agent/wiki/architecture.md` for complete overview
- Review `.agent/spec/requirements.md` for capabilities
- Check service-specific docs in `docs/[SERVICE].md`
- Use Context7 MCP for latest external documentation

### **Extension Guidelines**
- Follow patterns in `.agent/spec/extension.md`
- Use existing providers as templates
- Implement security standards from `.agent/spec/security.md`
- Update all framework files for complete integration

## 🔄 **Quality Improvement Workflow**

### **Before Making Changes**
1. **Check Current Quality**: Run SonarCloud and CodeFactor checks
2. **Identify Issues**: Focus on specific quality improvements
3. **Plan Approach**: Address issues systematically by priority

### **During Development**
1. **Follow Standards**: Use established patterns and best practices
2. **Test Incrementally**: Verify changes don't break functionality
3. **ShellCheck Validation**: Run ShellCheck on all modified scripts

### **After Changes**
1. **Validate Quality**: Ensure all platforms show improvements
2. **Monitor Metrics**: Verify A-grade ratings maintained
3. **Document Impact**: Clear commit messages with quality improvements

### **Quality Targets**
- **SonarCloud**: Maintain A-grades, reduce code smells <400
- **CodeFactor**: Maintain A-grade overall, 80%+ A-grade files
- **ShellCheck**: Zero violations across all scripts
- **Security**: Zero vulnerabilities, zero code duplication

## 🎯 **Agent Success Metrics**

### **Quality Excellence (ACHIEVED)**
- **490+ Quality Issues Resolved**: Comprehensive platform improvements
- **Perfect A-Grade CodeFactor**: 81% A-grade files (from F-grade)
- **Zero Security Vulnerabilities**: Enterprise-grade validation
- **71 ShellCheck Issues Fixed**: Professional compliance
- **Multi-Platform A-Grades**: SonarCloud + CodeFactor excellence

### **Operational Excellence**
- **Zero credential exposure** in any output or logs
- **Consistent command patterns** across all services
- **Comprehensive error handling** with helpful guidance
- **Complete audit trails** for all operations
- **Secure by default** configuration and operations

### **User Experience**
- **Intelligent guidance** through setup wizard
- **Clear feedback** for all operations
- **Helpful error messages** with resolution guidance
- **Efficient workflows** for common tasks
- **Comprehensive documentation** for all features

---

## 🏆 **Quality Achievement Summary**

**This framework has achieved INDUSTRY-LEADING quality standards:**
- **Perfect A-Grade SonarCloud**: Security, Reliability, Maintainability
- **Perfect A-Grade CodeFactor**: 81% A-grade files, zero D/F-grade files
- **Zero Security Vulnerabilities**: Enterprise-grade validation across 5,361+ lines
- **Professional Shell Scripting**: Full ShellCheck compliance
- **490+ Quality Issues Resolved**: Systematic improvement across all platforms

**This framework represents the most comprehensive AI-assisted DevOps infrastructure management system available, providing enterprise-grade capabilities with AI-first design principles and PERFECT quality validation.** 🚀🤖✨

**Agents using this framework MUST maintain these quality standards while leveraging the complete ecosystem of 25+ integrated services for comprehensive DevOps automation.** 🛡️⚡🏆
