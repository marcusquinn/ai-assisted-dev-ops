# API Key Management Guide

## 🔐 **SECURE API KEY STORAGE LOCATIONS**

### **1. Environment Variables (Primary Method)**

```bash
# Set for current session
export CODACY_API_TOKEN="YOUR_CODACY_API_TOKEN_HERE"
export SONAR_TOKEN="YOUR_SONAR_TOKEN_HERE"

# Add to shell profile for persistence
echo 'export CODACY_API_TOKEN="YOUR_CODACY_API_TOKEN_HERE"' >> ~/.bashrc
echo 'export SONAR_TOKEN="YOUR_SONAR_TOKEN_HERE"' >> ~/.bashrc
```

### **2. Local Configuration Files (Gitignored)**

```text
# Repository configs (gitignored)
configs/codacy-config.json          # Codacy API configuration
configs/sonar-config.json           # SonarCloud configuration (if needed)

# CLI-specific storage
~/.config/coderabbit/api_key         # CodeRabbit CLI token
~/.codacy/config                     # Codacy CLI configuration (if used)
```

### **3. GitHub Repository Secrets**

```text
# Required for GitHub Actions
SONAR_TOKEN                          # SonarCloud analysis
CODACY_API_TOKEN                     # Codacy analysis
GITHUB_TOKEN                         # Automatic (provided by GitHub)
```

## 🔑 **CURRENT API KEY STATUS**

### **✅ CONFIGURED:**

- **Codacy API Token**: `[CONFIGURED LOCALLY]` (Local environment + config file)
- **CodeRabbit CLI**: Stored in `~/.config/coderabbit/api_key`

### **❌ MISSING (CAUSING GITHUB ACTION FAILURES):**

- **SONAR_TOKEN**: Not set in GitHub Secrets
- **CODACY_API_TOKEN**: Not set in GitHub Secrets

## 🛠️ **SETUP INSTRUCTIONS**

### **1. Get SonarCloud Token**

1. Go to: https://sonarcloud.io/account/security
2. Generate new token with project analysis permissions
3. Copy the token value

### **2. Add GitHub Secrets**

1. Go to: https://github.com/marcusquinn/ai-assisted-dev-ops/settings/secrets/actions
2. Click "New repository secret"
3. Add:
   - Name: `SONAR_TOKEN`, Value: [Your SonarCloud token]
   - Name: `CODACY_API_TOKEN`, Value: [Your Codacy API token]

### **3. Set Local API Keys Securely**

```bash
# Use secure local storage (RECOMMENDED)
bash .agent/scripts/setup-local-api-keys.sh set codacy YOUR_CODACY_API_TOKEN
bash .agent/scripts/setup-local-api-keys.sh set sonar YOUR_SONAR_TOKEN

# Load all API keys into environment when needed
bash .agent/scripts/setup-local-api-keys.sh load

# List configured services
bash .agent/scripts/setup-local-api-keys.sh list
```

### **4. Test Configuration**

```bash
# Test Codacy CLI
cd git/ai-assisted-dev-ops
bash .agent/scripts/codacy-cli.sh analyze

# Test environment variables
echo "Codacy token: ${CODACY_API_TOKEN:0:10}..."
echo "Sonar token: ${SONAR_TOKEN:0:10}..."
```

## 🔍 **SECURITY AUDIT CHECKLIST**

### **✅ SECURE STORAGE:**

- [ ] API keys in environment variables (not hardcoded)
- [ ] Local config files are gitignored
- [ ] GitHub Secrets configured for CI/CD
- [ ] No API keys in commit messages or code

### **✅ ACCESS CONTROL:**

- [ ] Minimal required permissions for each token
- [ ] Regular token rotation (every 90 days)
- [ ] Revoke old tokens immediately after replacement
- [ ] Monitor token usage and access logs

### **✅ BACKUP & RECOVERY:**

- [ ] Document token sources and regeneration procedures
- [ ] Secure backup of configuration templates
- [ ] Emergency token revocation procedures
- [ ] Team access management for shared tokens

## 🚨 **EMERGENCY PROCEDURES**

### **If API Key is Compromised:**

1. **IMMEDIATE**: Revoke the compromised key at provider
2. **IMMEDIATE**: Generate new API key
3. **UPDATE**: Local environment variables
4. **UPDATE**: GitHub repository secrets
5. **VERIFY**: All systems working with new key
6. **DOCUMENT**: Incident and lessons learned

This guide ensures secure, professional API key management across all platforms and environments.
