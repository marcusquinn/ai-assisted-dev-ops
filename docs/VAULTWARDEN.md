# Vaultwarden (Self-hosted Bitwarden) Guide

Vaultwarden is a self-hosted, lightweight implementation of the Bitwarden server API, providing secure password and secrets management with full API access and MCP integration.

## 🏢 **Provider Overview**

### **Vaultwarden Characteristics:**

- **Service Type**: Self-hosted password and secrets management
- **Compatibility**: Full Bitwarden API compatibility
- **Architecture**: Lightweight Rust implementation
- **Security**: End-to-end encryption with zero-knowledge architecture
- **API Support**: Complete REST API for automation
- **MCP Integration**: Real-time vault access for AI assistants
- **Multi-platform**: Web, desktop, mobile, and CLI access

### **Best Use Cases:**

- **DevOps credential management** with secure API access
- **Team password sharing** with organization support
- **Development secrets** management and rotation
- **Infrastructure credentials** with automated access
- **Secure note storage** for configuration and documentation
- **API key management** with audit trails and access control

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/vaultwarden-config.json.txt configs/vaultwarden-config.json

# Edit with your Vaultwarden instance details
```

### **Multi-Instance Configuration:**

```json
{
  "instances": {
    "production": {
      "server_url": "https://vault.yourdomain.com",
      "description": "Production Vaultwarden instance",
      "users_count": 25,
      "organizations": [
        {
          "name": "Company Organization",
          "id": "org-uuid-here"
        }
      ]
    },
    "development": {
      "server_url": "https://dev-vault.yourdomain.com",
      "description": "Development Vaultwarden instance",
      "users_count": 10
    }
  }
}
```

### **Bitwarden CLI Setup:**

```bash
# Install Bitwarden CLI
npm install -g @bitwarden/cli

# Or download binary from:
# https://bitwarden.com/download/

# Verify installation
bw --version
```

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all Vaultwarden instances
./providers/vaultwarden-helper.sh instances

# Get vault status
./providers/vaultwarden-helper.sh status production

# Login to vault
./providers/vaultwarden-helper.sh login production user@example.com

# Unlock vault (after login)
./providers/vaultwarden-helper.sh unlock
```

### **Vault Management:**

```bash
# List all vault items
./providers/vaultwarden-helper.sh list production

# Search vault items
./providers/vaultwarden-helper.sh search production "github"

# Get specific item
./providers/vaultwarden-helper.sh get production item-uuid

# Get password for item
./providers/vaultwarden-helper.sh get-password production "GitHub Account"

# Get username for item
./providers/vaultwarden-helper.sh get-username production "GitHub Account"
```

### **Item Management:**

```bash
# Create new vault item
./providers/vaultwarden-helper.sh create production "New Service" username password123 https://service.com

# Update vault item
./providers/vaultwarden-helper.sh update production item-uuid password newpassword123

# Delete vault item
./providers/vaultwarden-helper.sh delete production item-uuid

# Generate secure password
./providers/vaultwarden-helper.sh generate 20 true
```

### **Organization Management:**

```bash
# List organization vault items
./providers/vaultwarden-helper.sh org-list production org-uuid

# Sync vault with server
./providers/vaultwarden-helper.sh sync production

# Export vault (encrypted)
./providers/vaultwarden-helper.sh export production json vault-backup.json
```

### **Security & Auditing:**

```bash
# Audit vault security
./providers/vaultwarden-helper.sh audit production

# Lock vault
./providers/vaultwarden-helper.sh lock

# Start MCP server for AI access
./providers/vaultwarden-helper.sh start-mcp production 3002

# Test MCP connection
./providers/vaultwarden-helper.sh test-mcp 3002
```

## 🛡️ **Security Best Practices**

### **Instance Security:**

- **HTTPS only**: Always use HTTPS for Vaultwarden instances
- **Strong master passwords**: Enforce strong master password policies
- **Two-factor authentication**: Enable 2FA for all users
- **Regular backups**: Maintain encrypted backups of vault data
- **Access monitoring**: Monitor and audit vault access

### **API Security:**

```bash
# Use secure session management
export BW_SESSION=$(bw unlock --raw)

# Clear session when done
unset BW_SESSION
bw lock

# Regular security audits
./providers/vaultwarden-helper.sh audit production
```

### **Organizational Security:**

- **Role-based access**: Implement proper role-based access control
- **Shared vault policies**: Define clear policies for shared vaults
- **Regular audits**: Perform regular security audits
- **Access reviews**: Review user access regularly
- **Incident response**: Have incident response procedures

## 🔍 **Troubleshooting**

### **Common Issues:**

#### **Connection Issues:**

```bash
# Test server connectivity
curl -I https://vault.yourdomain.com

# Check Bitwarden CLI configuration
bw config

# Verify server URL
bw config server https://vault.yourdomain.com
```

#### **Authentication Issues:**

```bash
# Check login status
bw status

# Re-login if needed
bw logout
bw login user@example.com

# Unlock vault
bw unlock
```

#### **Sync Issues:**

```bash
# Force sync with server
bw sync --force

# Check sync status
bw status

# Clear local cache if needed
bw logout
bw login user@example.com
```

## 📊 **MCP Integration**

### **Bitwarden MCP Server:**

```bash
# Start Bitwarden MCP server
./providers/vaultwarden-helper.sh start-mcp production 3002

# Test MCP server
./providers/vaultwarden-helper.sh test-mcp 3002

# Configure in AI assistant
# Add to MCP servers configuration:
{
  "bitwarden": {
    "command": "bitwarden-mcp-server",
    "args": ["--port", "3002"],
    "env": {
      "BW_SERVER": "https://vault.yourdomain.com"
    }
  }
}
```

### **AI Assistant Integration:**

The MCP server enables AI assistants to:

- **Retrieve credentials** securely for automation tasks
- **Generate secure passwords** with custom policies
- **Audit vault security** and identify weak passwords
- **Manage vault items** with proper authentication
- **Access shared organization** vaults for team credentials

## 🔄 **Backup & Recovery**

### **Vault Backup:**

```bash
# Export encrypted vault
./providers/vaultwarden-helper.sh export production json vault-backup-$(date +%Y%m%d).json

# Secure backup file
chmod 600 vault-backup-*.json

# Store backup securely (encrypted storage recommended)
```

### **Automated Backup:**

```bash
#!/bin/bash
# Automated vault backup script
INSTANCE="production"
BACKUP_DIR="/secure/backups/vaultwarden"
DATE=$(date +%Y%m%d-%H%M%S)

# Create backup
./providers/vaultwarden-helper.sh export $INSTANCE json "$BACKUP_DIR/vault-$DATE.json"

# Encrypt backup
gpg --cipher-algo AES256 --compress-algo 1 --s2k-mode 3 \
    --s2k-digest-algo SHA512 --s2k-count 65536 --symmetric \
    "$BACKUP_DIR/vault-$DATE.json"

# Remove unencrypted backup
rm "$BACKUP_DIR/vault-$DATE.json"

# Cleanup old backups (keep 30 days)
find "$BACKUP_DIR" -name "vault-*.json.gpg" -mtime +30 -delete
```

## 📚 **Best Practices**

### **Vault Organization:**

1. **Logical categorization**: Organize items by service, environment, or team
2. **Consistent naming**: Use consistent naming conventions
3. **Regular cleanup**: Remove unused or outdated credentials
4. **Documentation**: Document credential purposes and rotation schedules
5. **Access control**: Implement proper access controls for shared items

### **Password Management:**

- **Strong passwords**: Use generated passwords with high entropy
- **Regular rotation**: Rotate passwords regularly, especially for critical services
- **Unique passwords**: Never reuse passwords across services
- **Secure sharing**: Use organization vaults for team credential sharing
- **Audit regularly**: Regular security audits to identify weak passwords

### **Automation Integration:**

- **API access**: Use API access for automated credential retrieval
- **Session management**: Properly manage CLI sessions and tokens
- **Error handling**: Implement proper error handling for automation
- **Logging**: Log credential access for audit purposes
- **Rate limiting**: Respect API rate limits in automation

## 🎯 **AI Assistant Integration**

### **Automated Credential Management:**

- **Secure retrieval**: AI can securely retrieve credentials for automation
- **Password generation**: AI can generate secure passwords with policies
- **Vault auditing**: AI can audit vault security and identify issues
- **Credential rotation**: AI can assist with credential rotation workflows
- **Access monitoring**: AI can monitor and report on credential access

### **DevOps Workflows:**

- **Infrastructure deployment**: Secure credential access for deployments
- **CI/CD integration**: Secure credential injection into pipelines
- **Service configuration**: Automated service configuration with credentials
- **Monitoring integration**: Secure access to monitoring service credentials
- **Incident response**: Quick access to emergency credentials

---

**Vaultwarden provides enterprise-grade password and secrets management with comprehensive API access, making it ideal for secure DevOps workflows and AI-assisted credential management.** 🚀
