# Provider Scripts AI Context

This folder contains helper scripts for all 25+ service integrations in the AI DevOps Framework.

## 🛠️ **Script Categories**

### **Infrastructure & Hosting**

- `hostinger-helper.sh` - Shared hosting management
- `hetzner-helper.sh` - Cloud VPS management
- `closte-helper.sh` - VPS hosting management
- `cloudron-helper.sh` - App platform management

### **Deployment & Orchestration**

- `coolify-helper.sh` - Self-hosted PaaS deployment

### **Content Management**

- `mainwp-helper.sh` - WordPress management platform

### **Security & Secrets**

- `vaultwarden-helper.sh` - Password and secrets management

### **Code Quality & Auditing**

- `code-audit-helper.sh` - Multi-platform code auditing

### **Version Control & Git Platforms**

- `git-platforms-helper.sh` - GitHub, GitLab, Gitea, Local Git

### **Email Services**

- `ses-helper.sh` - Amazon SES email delivery

### **Domain & DNS**

- `spaceship-helper.sh` - Domain registrar with purchasing
- `101domains-helper.sh` - Domain registrar management
- `dns-helper.sh` - Multi-provider DNS management

### **Development & Local**

- `localhost-helper.sh` - Local development with .local domains

### **Setup & Configuration**

- `setup-wizard-helper.sh` - Intelligent setup wizard

## 🔧 **Standard Script Structure**

All helper scripts follow this consistent pattern:

```bash
#!/bin/bash
# [Service Name] Helper Script
# [Brief description]

# Standard color definitions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Standard print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration file path
CONFIG_FILE="../configs/[service]-config.json"

# Standard functions (all scripts implement these):
# - check_dependencies()
# - load_config()
# - get_account_config() or get_instance_config()
# - api_request() (for API-based services)
# - list_accounts() or list_instances()
# - show_help()
# - main() with case statement

# Service-specific functions
# - [service_specific_functions]

# Main execution
main "$@"
```

## 🚀 **Usage Patterns**

### **Standard Commands**

```bash
# Help and information
./[service]-helper.sh help
./[service]-helper.sh accounts|instances|servers

# Management operations
./[service]-helper.sh [action] [account] [target] [options]

# Monitoring and auditing
./[service]-helper.sh monitor|audit|status [account]
```

### **Common Parameters**

- `account/instance` - Configuration account or instance name
- `target` - Specific resource (server, domain, repository, etc.)
- `options` - Additional parameters specific to the operation

## 🛡️ **Security Considerations**

### **Credential Handling**

- All scripts load credentials from `../configs/[service]-config.json`
- No credentials are hardcoded in scripts
- API tokens are validated before use
- Secure credential storage patterns are followed

### **Confirmation Prompts**

- Destructive operations require confirmation
- Purchase operations require explicit confirmation
- Production environment changes require verification

### **Error Handling**

- All scripts implement proper error handling
- Exit codes are consistent (0 = success, 1 = error)
- Error messages are informative but don't expose sensitive data

## 🔍 **Troubleshooting Scripts**

### **Common Issues**

```bash
# Check script permissions
ls -la [service]-helper.sh
chmod +x [service]-helper.sh

# Verify configuration
./[service]-helper.sh accounts

# Test connectivity
./[service]-helper.sh help
```

### **Debug Mode**

Most scripts support verbose output for debugging:

```bash
# Enable debug output (if supported)
DEBUG=1 ./[service]-helper.sh [command]
```

## 📚 **Adding New Provider Scripts**

When adding new provider scripts, follow these guidelines:

1. **Use existing scripts as templates** for consistency
2. **Follow naming conventions**: `[service-name]-helper.sh`
3. **Implement all standard functions** listed above
4. **Include comprehensive help** with examples
5. **Add proper error handling** and validation
6. **Test thoroughly** before integration
7. **Update this context file** with the new script

## 🎯 **AI Assistant Usage**

AI assistants should:

- **Use helper scripts** instead of direct API calls when possible
- **Follow confirmation patterns** for destructive operations
- **Provide clear feedback** to users about operations
- **Handle errors gracefully** and provide helpful guidance
- **Respect rate limits** and service constraints
- **Log important operations** for audit purposes

---

**All provider scripts are designed for AI assistant automation while maintaining security, consistency, and user control.** 🤖🛡️
