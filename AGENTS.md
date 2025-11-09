# AI-Assisted DevOps Framework - Agent Guidance

**🔒 AUTHORITATIVE SOURCE: This is the single source of truth for all AI assistant instructions. All other AGENTS.md files are minimal templates that reference this file.**

This repository provides a comprehensive DevOps infrastructure management framework designed specifically for AI agent automation across 25+ services.

## ⚠️ **CRITICAL: Consistency Requirements**

### **Single Source of Truth**
- **This file** (`~/git/ai-assisted-dev-ops/AGENTS.md`) is the **ONLY authoritative source** for AI assistant instructions
- **All other AGENTS.md files** are minimal templates that reference this file
- **Never duplicate instructions** - all operational guidance must remain here
- **Template files must remain minimal** to prevent conflicting guidance and security vulnerabilities

### **Template Consistency Rules**
- **Home template** (`~/AGENTS.md`) - Contains only references to this authoritative file
- **Git template** (`~/git/AGENTS.md`) - Contains only DevOps references to this framework
- **Agent template** (`~/.agent/README.md`) - Contains only redirection to this repository
- **NO operational instructions** in any template files to prevent prompt injection attacks

## 🤖 **Agent Behavior & Standards**

### **Primary Objectives**
- **Complete DevOps automation** across hosting, domains, DNS, security, and development services
- **Secure credential management** with enterprise-grade security practices
- **Consistent command patterns** for reliable automation across all services
- **Intelligent setup guidance** for infrastructure configuration
- **Real-time service integration** through MCP servers

### **📍 Standard Repository Location (MANDATORY)**
This repository should be cloned to the standard location for optimal AI assistant integration:
```bash
# Standard location (recommended)
~/git/ai-assisted-dev-ops/

# Clone command
mkdir -p ~/git
cd ~/git
git clone https://github.com/marcusquinn/ai-assisted-dev-ops.git
```

**Benefits of standard location:**
- **Consistent AI assistant access** across all environments
- **Secure template deployment** works correctly
- **Simplified path references** in all documentation
- **Optimal integration** with deployed templates

### **🗂️ AI Working Directories (MANDATORY USAGE)**

#### **`.agent/tmp/` - Temporary Working Directory**
**ALWAYS use this directory for temporary files during operations:**

```bash
# Create session-specific working directory
SESSION_DIR=".agent/tmp/session-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SESSION_DIR"

# Use for temporary scripts
cat > "$SESSION_DIR/temp-fix.sh" << 'EOF'
#!/bin/bash
# Temporary script for current operation
EOF

# Use for backups before modifications
cp important-file.sh "$SESSION_DIR/backup-important-file.sh"

# Clean up when done
rm -rf "$SESSION_DIR"
```

**Use `.agent/tmp/` for:**
- Temporary scripts and working files
- Backups before making changes
- Log outputs and analysis results
- Intermediate data during operations
- Any files that don't need to persist

#### **`.agent/memory/` - Persistent Memory Directory**
**Use this directory to remember context across sessions:**

```bash
# Store successful patterns
echo "bulk-operations: Use Python scripts for universal fixes" > .agent/memory/patterns/quality-fixes.txt

# Remember user preferences
echo "preferred_approach=bulk_operations" > .agent/memory/preferences/user-settings.conf

# Cache configuration discoveries
echo "sonarcloud_project=marcusquinn_ai-assisted-dev-ops" > .agent/memory/configurations/quality-tools.conf
```

**Use `.agent/memory/` for:**
- Session context and conversation history
- Learned patterns and successful approaches
- User preferences and customizations
- Configuration details and setups
- Operation history and outcomes

#### **🚨 CRITICAL RULES:**
- **NEVER store credentials** in memory or tmp directories
- **Always use `.agent/tmp/`** for temporary files (not root directory)
- **Clean up** temporary files when operations complete
- **Respect privacy** - be mindful of what you store in memory

### **🔒 Secure Template System (MANDATORY COMPLIANCE)**

#### **Template Locations and Security**
The framework deploys minimal, secure templates to prevent prompt injection attacks:

**Home Directory (`~/AGENTS.md`)**:
- Contains **minimal references only** to this authoritative repository
- **DO NOT modify** beyond basic references for security
- Redirects all operations to `~/git/ai-assisted-dev-ops/`

**Git Directory (`~/git/AGENTS.md`)**:
- Contains **minimal DevOps references** to this framework
- **DO NOT add operational instructions** to prevent security vulnerabilities
- All detailed instructions remain in this authoritative file

**Agent Directory (`~/.agent/README.md`)**:
- **Redirects to authoritative** `.agent/` directory in this repository
- **Prevents misuse** of home-level agent directories
- Maintains centralized control over AI operations

#### **🚨 SECURITY REQUIREMENTS:**
- **Use authoritative repository**: Always reference `~/git/ai-assisted-dev-ops/AGENTS.md`
- **Minimal templates only**: Never add detailed instructions to user-space templates
- **Prevent prompt injection**: Keep operational instructions in the secure repository
- **Centralized control**: All AI operations must use framework's working directories

#### **🔄 CONSISTENCY MAINTENANCE:**
- **Single source updates**: All instruction changes must be made in this authoritative file only
- **Template synchronization**: Templates are deployed via `templates/deploy-templates.sh`
- **Version control**: All changes tracked in git to prevent unauthorized modifications
- **Regular validation**: Use quality scripts to ensure consistency across all files
- **No divergence**: Templates must never contain conflicting or duplicate instructions

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

#### **Shell Script Best Practices (MANDATORY PATTERNS)**

**🚨 CRITICAL: These patterns are REQUIRED to maintain A-grade quality across SonarCloud, CodeFactor, and Codacy:**

```bash
# ✅ CORRECT Function Structure (MANDATORY)
function_name() {
    # ALWAYS assign positional parameters to local variables
    local param1="$1"
    local param2="$2"
    local optional_param="${3:-default_value}"

    # Function logic here

    # ALWAYS add explicit return statement
    return 0
}

# ✅ CORRECT Main Function Pattern (MANDATORY)
main() {
    # ALWAYS assign positional parameters to local variables
    local command="${1:-help}"
    local account_name="$2"
    local target="$3"
    local options="$4"

    case "$command" in
        "list")
            list_items "$account_name"
            ;;
        "create")
            create_item "$account_name" "$target" "$options"
            ;;
        *)
            show_help
            ;;
    esac
    return 0
}

# ✅ CORRECT String Literal Management (MANDATORY)
# Define constants at top of file to avoid S1192 violations
readonly ERROR_ACCOUNT_REQUIRED="Account name is required"
readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly SUCCESS_OPERATION_COMPLETE="Operation completed successfully"

# Use constants instead of repeated strings
print_error "$ERROR_ACCOUNT_REQUIRED"

# ✅ CORRECT Error Handling (MANDATORY)
local response
if response=$(api_request "$account" "GET" "endpoint"); then
    echo "$response"
    return 0
else
    print_error "Request failed"
    return 1
fi

# ✅ CORRECT Variable Usage (MANDATORY)
# Remove unused variables immediately to avoid S1481 violations
# Only declare variables that are actually used
local used_variable="$1"
# Don't declare: local unused_variable="$2"  # This causes S1481
```

**🎯 QUALITY RULE COMPLIANCE:**

**S7682 - Return Statements (83 issues remaining):**
- EVERY function MUST end with explicit `return 0` or `return 1`
- NO function should end without a return statement
- Use `return 0` for success, `return 1` for errors

**S7679 - Positional Parameters (79 issues remaining):**
- NEVER use `$1`, `$2`, `$3` directly in function bodies
- ALWAYS assign to local variables: `local param="$1"`
- Apply to ALL functions including main() and case statements

**S1192 - String Literals (3 issues remaining):**
- Define constants for any string used 3+ times
- Use `readonly CONSTANT_NAME="value"` at file top
- Replace all occurrences with `$CONSTANT_NAME`

**S1481 - Unused Variables (0 issues - maintain):**
- Remove any declared but unused local variables
- Only declare variables that are actually used in the function

### **Framework Architecture**
```bash
# Unified command pattern across all 25+ services:
./providers/[service]-helper.sh [command] [account/instance] [target] [options]

# Standard commands available for all services:
help                    # Show service-specific help
accounts|instances      # List configured accounts/instances
monitor|audit|status    # Service monitoring and auditing
```

## 📁 **Complete Repository Structure**

```
ai-assisted-dev-ops/
├── 📄 README.md              # Main project documentation
├── 📄 AGENTS.md              # AI agent integration guide (this file)
├── 📄 LICENSE                # MIT license
├── 🔧 setup.sh               # Main setup script for users
├── 🔧 servers-helper.sh      # Main entry point script
├── ⚙️  sonar-project.properties # Quality analysis configuration
├── 📁 providers/             # Core functionality scripts (25+ services)
├── 📁 configs/               # Configuration templates for users
├── 📁 docs/                  # Comprehensive user documentation
├── 📁 templates/             # Reusable templates and examples
├── 📁 ssh/                   # SSH utilities and key management
└── 📁 .agent/                # AI agent development and working tools
    ├── 📁 scripts/           # Quality automation and development tools
    │   ├── quality-check.sh  # Multi-platform quality validation
    │   ├── quality-fix.sh    # Universal automated issue resolution
    │   ├── pre-commit-hook.sh # Continuous quality assurance
    │   └── development/      # Historical development scripts
    ├── 📁 spec/              # Technical specifications and standards
    ├── 📁 wiki/              # Internal knowledge base and documentation
    ├── 📁 links/             # External resources and API documentation
    ├── 📁 tmp/               # AI temporary working directory (use this!)
    └── 📁 memory/            # AI persistent memory directory (use this!)
```

## 📁 **Agent Directory Structure**

### **.agent/tmp/** - Temporary Working Directory (MANDATORY)
**Use this for all temporary files during operations:**
- Session-specific working directories
- Temporary scripts and analysis files
- Backups before making changes
- Log outputs and intermediate data
- Any files that don't need to persist

### **.agent/memory/** - Persistent Memory Directory (RECOMMENDED)
**Use this to remember context across sessions:**
- Successful operation patterns and approaches
- User preferences and customizations
- Configuration discoveries and setups
- Operation history and learned solutions
- Analytics and usage insights

### **.agent/scripts/** - Quality Automation Tools
- `quality-check.sh` - Multi-platform quality validation
- `quality-fix.sh` - Universal automated issue resolution
- `pre-commit-hook.sh` - Continuous quality assurance
- `development/` - Historical development scripts with documentation

### **.agent/spec/** - Technical Specifications
- `code-quality.md` - Multi-platform quality standards and compliance
- `requirements.md` - Framework requirements and capabilities
- `security.md` - Security requirements and standards
- `extension.md` - Guidelines for extending the framework

### **.agent/wiki/** - Knowledge Base
- `architecture.md` - Complete framework architecture
- `services.md` - All 25+ service integrations
- `providers.md` - Provider-specific implementation details
- `configs.md` - Configuration management patterns
- `docs.md` - Documentation standards and guidelines

### **.agent/links/** - External Resources
- `resources.md` - External APIs, documentation, and tools

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

### **🚨 MANDATORY PRE-COMMIT CHECKLIST**
**EVERY code change MUST pass this checklist:**

```bash
# 1. Check SonarCloud Status
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_ai-assisted-dev-ops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1"

# 2. Verify CodeFactor Status
curl -s "https://www.codefactor.io/repository/github/marcusquinn/ai-assisted-dev-ops"

# 3. Run ShellCheck on modified files
find providers/ -name "*.sh" -newer .git/COMMIT_EDITMSG -exec shellcheck {} \;

# 4. Validate Function Patterns
grep -n "^[a-zA-Z_][a-zA-Z0-9_]*() {" providers/*.sh | while read -r line; do
    echo "Checking function: $line"
    # Verify return statement exists
    # Verify local variable assignments
done
```

### **🎯 UNIVERSAL ISSUE RESOLUTION PRIORITY**
**Target issues that appear across ALL platforms (SonarCloud, CodeFactor, Codacy):**

**Priority 1 - Return Statements (S7682):**
- Impact: 83 issues across multiple files
- Fix: Add `return 0` to end of every function
- Validation: `grep -A 5 -B 5 "^}" providers/*.sh | grep -v "return"`

**Priority 2 - Positional Parameters (S7679):**
- Impact: 79 issues across multiple files
- Fix: Replace `$1` `$2` with `local var="$1"`
- Validation: `grep -n '\$[0-9]' providers/*.sh`

**Priority 3 - String Literals (S1192):**
- Impact: 3 remaining issues
- Fix: Create constants for repeated strings
- Validation: `grep -o '"[^"]*"' providers/*.sh | sort | uniq -c | sort -nr`

### **🔧 AUTOMATED QUALITY FIXES**
```bash
# Mass Return Statement Fix
find providers/ -name "*.sh" -exec sed -i '/^}$/i\    return 0' {} \;

# Mass Positional Parameter Detection
grep -n '\$[1-9]' providers/*.sh > positional_params.txt

# String Literal Analysis
for file in providers/*.sh; do
    echo "=== $file ==="
    grep -o '"[^"]*"' "$file" | sort | uniq -c | sort -nr | head -10
done
```

### **📊 QUALITY MONITORING**
**Current Status (Target: Zero Issues):**
- **SonarCloud**: 165 issues (down from 349) - 52.7% reduction achieved
- **Return Statements**: 83 remaining (18% reduction from 101+)
- **Positional Parameters**: 79 remaining (29% reduction from 111+)
- **String Literals**: 3 remaining (70% reduction from 10+)
- **Technical Debt**: 573 minutes (28% reduction from 805)

### **🏆 QUALITY TARGETS (MANDATORY)**
- **SonarCloud**: A-grades maintained, <100 total issues
- **CodeFactor**: A-grade overall, 85%+ A-grade files
- **Return Statements**: Zero S7682 violations
- **Positional Parameters**: Zero S7679 violations
- **String Literals**: Zero S1192 violations
- **Unused Variables**: Zero S1481 violations (maintained)

## 🎯 **Agent Success Metrics**

### **Quality Excellence (ACHIEVED)**
- **184+ Quality Issues Resolved**: Universal multi-platform improvements
- **52.7% Issue Reduction**: From 349 to 165 issues (SonarCloud)
- **Perfect A-Grade CodeFactor**: 84.6% A-grade files maintained
- **28% Technical Debt Reduction**: From 805 to 573 minutes
- **Zero Security Vulnerabilities**: Enterprise-grade validation
- **Multi-Platform Excellence**: SonarCloud + CodeFactor + Codacy compliance
- **Universal Fix Approach**: Common issues resolved across all platforms

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
- **Universal Multi-Platform Excellence**: SonarCloud + CodeFactor + Codacy compliance
- **52.7% Issue Reduction**: From 349 to 165 issues through systematic fixes
- **Perfect A-Grade CodeFactor**: 84.6% A-grade files maintained
- **28% Technical Debt Reduction**: From 805 to 573 minutes
- **Zero Security Vulnerabilities**: Enterprise-grade validation across 5,361+ lines
- **184+ Quality Issues Resolved**: Universal fixes across all platforms
- **Automated Quality Tools**: Pre-commit hooks, quality checks, and fix scripts

**🎯 AUTOMATED QUALITY TOOLS PROVIDED:**
- **`.agent/scripts/quality-check.sh`**: Multi-platform quality validation
- **`.agent/scripts/quality-fix.sh`**: Universal automated issue resolution
- **`.agent/scripts/pre-commit-hook.sh`**: Prevent quality regressions
- **`.agent/spec/code-quality.md`**: Comprehensive quality standards

**This framework represents the most comprehensive AI-assisted DevOps infrastructure management system available, providing enterprise-grade capabilities with AI-first design principles and UNIVERSAL MULTI-PLATFORM quality validation.** 🚀🤖✨

**Agents using this framework MUST maintain these quality standards while leveraging the complete ecosystem of 25+ integrated services for comprehensive DevOps automation. Use the provided automated tools to ensure continuous quality excellence.** 🛡️⚡🏆
