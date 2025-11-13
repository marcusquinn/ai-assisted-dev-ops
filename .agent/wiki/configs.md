# Configuration Files AI Context

This folder contains configuration templates and working configuration files for all services in the AI DevOps Framework.

## 📁 **File Structure**

### **Template Files (Committed)**

```bash
# Template files (.txt extension) - safe to commit
[service]-config.json.txt           # Configuration template
```

### **Working Files (Gitignored)**

```bash
# Working configuration files - contain actual credentials
[service]-config.json               # Active configuration (NEVER COMMIT)
setup-wizard-responses.json         # Setup wizard responses (NEVER COMMIT)
```

## 🔧 **Configuration Categories**

### **Infrastructure & Hosting**

- `hostinger-config.json.txt` - Shared hosting credentials
- `hetzner-config.json.txt` - Cloud VPS API tokens
- `closte-config.json.txt` - VPS hosting credentials
- `cloudron-config.json.txt` - App platform tokens

### **Deployment & Orchestration**

- `coolify-config.json.txt` - Self-hosted PaaS tokens

### **Content Management**

- `mainwp-config.json.txt` - WordPress management API tokens

### **Security & Secrets**

- `vaultwarden-config.json.txt` - Password manager instance configs

### **Code Quality & Auditing**

- `code-audit-config.json.txt` - Multi-platform auditing service tokens

### **Version Control & Git Platforms**

- `git-platforms-config.json.txt` - GitHub, GitLab, Gitea tokens

### **Email Services**

- `ses-config.json.txt` - Amazon SES credentials

### **Domain & DNS**

- `spaceship-config.json.txt` - Domain registrar API tokens
- `101domains-config.json.txt` - Domain registrar credentials
- `cloudflare-dns-config.json.txt` - Cloudflare DNS tokens
- `namecheap-dns-config.json.txt` - Namecheap DNS credentials
- `route53-dns-config.json.txt` - AWS Route 53 credentials
- `other-dns-providers-config.json.txt` - Other DNS providers

### **Development & Local**

- `localhost-config.json.txt` - Local development settings
- `mcp-servers-config.json.txt` - MCP server configurations
- `context7-mcp-config.json.txt` - Context7 MCP settings

## 🔒 **Security Standards**

### **Template Files (.txt)**

- **Safe to commit** - contain no actual credentials
- **Use placeholder values** like `YOUR_API_TOKEN_HERE`
- **Include example configurations** for reference
- **Document all required fields** with comments

### **Working Files (.json)**

- **NEVER COMMIT** - contain actual credentials
- **Protected by .gitignore** automatically
- **Should have restricted permissions** (600 or 640)
- **Regular backup** to secure location recommended

### **Credential Management**

```bash
# Secure file permissions
chmod 600 configs/*-config.json

# Verify no credentials in git
git status --porcelain configs/

# Check .gitignore coverage
git check-ignore configs/*-config.json
```

## 🛠️ **Configuration Structure**

### **Standard JSON Structure**

```json
{
  "accounts": {
    "account-name": {
      "api_token": "YOUR_TOKEN_HERE",
      "base_url": "https://api.service.com",
      "description": "Account description",
      "username": "your-username"
    }
  },
  "default_settings": {
    "timeout": 30,
    "rate_limit": 60,
    "retry_attempts": 3
  },
  "mcp_servers": {
    "service": {
      "enabled": true,
      "port": 3001,
      "host": "localhost"
    }
  }
}
```

### **Multi-Account Support**

Most services support multiple accounts:

```json
{
  "accounts": {
    "personal": { "api_token": "personal_token" },
    "work": { "api_token": "work_token" },
    "client": { "api_token": "client_token" }
  }
}
```

## 🚀 **Setup Process**

### **Initial Configuration**

```bash
# 1. Copy templates to working files
cp [service]-config.json.txt [service]-config.json

# 2. Edit with actual credentials
nano [service]-config.json

# 3. Test configuration
../providers/[service]-helper.sh accounts

# 4. Verify security
chmod 600 [service]-config.json
```

### **Using Setup Wizard**

```bash
# Automated setup with guidance
../providers/setup-wizard-helper.sh full-setup

# Generate all config files from templates
../providers/setup-wizard-helper.sh generate-configs

# Test all connections
../providers/setup-wizard-helper.sh test-connections
```

## 🔍 **Validation & Testing**

### **Configuration Validation**

```bash
# Validate JSON syntax
jq '.' [service]-config.json

# Test service connectivity
../providers/[service]-helper.sh accounts

# Verify API permissions
../providers/[service]-helper.sh help
```

### **Security Validation**

```bash
# Check file permissions
ls -la *-config.json

# Verify .gitignore protection
git status --porcelain

# Scan for exposed credentials
grep -r "token\|password\|secret" . --exclude="*.txt"
```

## 📚 **Best Practices**

### **Configuration Management**

1. **Always use templates** as starting point
2. **Never commit working configs** with credentials
3. **Use descriptive account names** (personal, work, client)
4. **Document custom settings** with comments
5. **Regular credential rotation** for security

### **Security Practices**

1. **Restrict file permissions** (600 for config files)
2. **Use separate accounts** for different environments
3. **Enable MFA** on all service accounts where possible
4. **Monitor API usage** for unusual activity
5. **Backup configurations** securely

### **Maintenance**

1. **Regular updates** of API endpoints and settings
2. **Credential rotation** every 6-12 months
3. **Remove unused accounts** and configurations
4. **Update templates** when services change APIs
5. **Document changes** in service-specific docs

## 🎯 **AI Assistant Guidelines**

### **Configuration Handling**

- **Never expose credentials** in logs or output
- **Use configuration validation** before operations
- **Provide clear setup guidance** for missing configs
- **Respect account separation** (don't mix personal/work)
- **Validate permissions** before destructive operations

### **Error Handling**

- **Clear error messages** for configuration issues
- **Guidance for fixing** common configuration problems
- **Security-aware messaging** (don't expose tokens in errors)
- **Helpful suggestions** for missing or invalid configs

---

**All configuration files are designed for security-first credential management while maintaining ease of use and AI assistant automation capabilities.** 🔒🤖
