# Framework Extension Guidelines

## 🎯 **Extension Principles**

### **Core Principles**

- **Consistency**: Follow established patterns and conventions
- **Security**: Implement security measures from the start
- **Documentation**: Comprehensive documentation for all additions
- **Testing**: Thorough testing before integration
- **Maintainability**: Code that is easy to understand and maintain

### **Quality Standards**

- **Code review**: All additions must pass code review
- **Security review**: Security implications must be assessed
- **Documentation review**: Documentation must be complete and accurate
- **Integration testing**: Must integrate properly with existing services
- **User experience**: Must maintain or improve user experience

## 🛠️ **Adding New Service Providers**

### **Step 1: Research & Planning**

```bash
# Research checklist:
□ Service has public API with documentation
□ API supports required operations (list, create, update, delete)
□ Authentication method is supported (token, OAuth, etc.)
□ Rate limits and usage policies are acceptable
□ Service has MCP server available or can be created
□ Service fits into existing framework categories
```

### **Step 2: Create Helper Script**

```bash
# File: providers/[service-name]-helper.sh
#!/bin/bash

# [Service Name] Helper Script
# [Brief description of service and capabilities]

# Standard header (copy from existing script)
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

# Required functions (implement all):
check_dependencies() { ... }
load_config() { ... }
get_account_config() { ... }
api_request() { ... }
list_accounts() { ... }
show_help() { ... }
main() { ... }

# Service-specific functions
[service_specific_functions]() { ... }

main "$@"
```

### **Step 3: Create Configuration Template**

```bash
# File: configs/[service-name]-config.json.txt
{
  "accounts": {
    "personal": {
      "api_token": "YOUR_[SERVICE]_API_TOKEN_HERE",
      "base_url": "https://api.[service].com",
      "description": "Personal [service] account",
      "username": "your-username"
    },
    "work": {
      "api_token": "YOUR_WORK_[SERVICE]_API_TOKEN_HERE",
      "base_url": "https://api.[service].com",
      "description": "Work [service] account",
      "username": "work-username"
    }
  },
  "default_settings": {
    "timeout": 30,
    "rate_limit": 60,
    "retry_attempts": 3,
    "page_size": 50
  },
  "mcp_servers": {
    "[service]": {
      "enabled": true,
      "port": 30XX,
      "host": "localhost",
      "auth_required": true
    }
  },
  "features": {
    "bulk_operations": true,
    "webhooks": false,
    "real_time_updates": true
  }
}
```

### **Step 4: Create Comprehensive Documentation**

```bash
# File: docs/[SERVICE-NAME].md
# [Service Name] Guide

## 🏢 **Provider Overview**
### **[Service] Characteristics:**
- **Service Type**: [Description]
- **Strengths**: [Key benefits and features]
- **API Support**: [API capabilities and limitations]
- **MCP Integration**: [MCP server availability]
- **Use Case**: [Primary use cases and scenarios]

## 🔧 **Configuration**
[Detailed setup instructions]

## 🚀 **Usage Examples**
[Real command examples with expected output]

## 🛡️ **Security Best Practices**
[Service-specific security guidelines]

## 📊 **MCP Integration**
[MCP server setup and capabilities]

## 🔍 **Troubleshooting**
[Common issues and solutions]

## 📚 **Best Practices**
[Service-specific best practices]

## 🎯 **AI Assistant Integration**
[AI automation capabilities and patterns]
```

### **Step 5: Update Framework Files**

```bash
# Update .gitignore
echo "configs/[service-name]-config.json" >> .gitignore

# Update README.md
# - Add to service list
# - Add to helper scripts list
# - Add to file structure
# - Add to documentation list

# Update AGENTS.md
# - Add to appropriate service category
# - Update service count

# Update docs/BEST-PRACTICES.md
# - Add to appropriate category with description

# Update providers/setup-wizard-helper.sh
# - Add to service recommendations logic
# - Add to API keys guide
# - Add to configuration generation
```

## 🔐 **Security Implementation**

### **Required Security Features**

```bash
# All new services must implement:
1. API token validation before use
2. Input validation and sanitization
3. Secure error messages (no credential exposure)
4. Rate limiting awareness and backoff
5. Confirmation prompts for destructive operations
6. Audit logging for important operations
7. Encrypted credential storage
8. Secure temporary file handling
```

### **Security Testing Checklist**

```bash
□ No credentials exposed in logs or output
□ All inputs properly validated
□ Error messages don't reveal sensitive information
□ Destructive operations require confirmation
□ API rate limits are respected
□ Temporary files are cleaned up
□ File permissions are properly set
□ Configuration files are gitignored
```

## 📊 **Testing Requirements**

### **Functional Testing**

```bash
# Test all major functions:
□ Configuration loading and validation
□ API connectivity and authentication
□ List operations (accounts, resources)
□ Create operations (if applicable)
□ Update operations (if applicable)
□ Delete operations (if applicable)
□ Error handling and recovery
□ Help and documentation
```

### **Integration Testing**

```bash
# Test framework integration:
□ Helper script follows naming conventions
□ Configuration follows standard structure
□ Documentation follows standard format
□ MCP server integration (if applicable)
□ Setup wizard integration
□ Cross-service workflows (if applicable)
```

### **Security Testing**

```bash
# Security validation:
□ No credential exposure in any output
□ Proper input validation
□ Secure error handling
□ File permission verification
□ Configuration security
□ API security best practices
```

## 🔄 **Maintenance Guidelines**

### **Ongoing Maintenance**

- **API updates**: Monitor service API changes and update accordingly
- **Security updates**: Regular security reviews and updates
- **Documentation updates**: Keep documentation current with service changes
- **Performance optimization**: Monitor and optimize performance
- **User feedback**: Incorporate user feedback and feature requests

### **Version Management**

- **Semantic versioning**: Use semantic versioning for major changes
- **Backward compatibility**: Maintain backward compatibility when possible
- **Migration guides**: Provide migration guides for breaking changes
- **Deprecation notices**: Provide adequate notice for deprecated features
- **Change logs**: Maintain detailed change logs

## 🎯 **Quality Assurance**

### **Code Quality Standards**

- **Consistent formatting**: Follow established code formatting
- **Clear naming**: Use descriptive function and variable names
- **Comprehensive comments**: Comment complex logic and decisions
- **Error handling**: Implement robust error handling
- **Performance**: Optimize for performance and resource usage

### **Documentation Quality**

- **Completeness**: Cover all features and capabilities
- **Accuracy**: Ensure all examples and instructions work
- **Clarity**: Write clear, understandable documentation
- **Examples**: Provide real, working examples
- **Troubleshooting**: Include common issues and solutions

---

**Following these guidelines ensures new services integrate seamlessly with the framework while maintaining security, quality, and consistency standards.** 🛠️🔒✨
