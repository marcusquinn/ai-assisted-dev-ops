# API Key Setup Guide - Secure Local Storage

## 🔐 **SECURE API KEY MANAGEMENT**

### **🎯 SECURITY PRINCIPLE:**

**API keys are stored ONLY in your private user directory (`~/.config/ai-assisted-devops/`), NEVER in repository files.**

## 🛠️ **SETUP INSTRUCTIONS**

### **1. Initialize Secure Storage**

```bash
cd git/aidevops
bash .agent/scripts/setup-local-api-keys.sh setup
```

### **2. Store API Keys Securely**

#### **Codacy (Code Quality Analysis):**

```bash
# Get API key from: https://app.codacy.com/account/api-tokens
bash .agent/scripts/setup-local-api-keys.sh set codacy YOUR_CODACY_API_TOKEN
```

#### **SonarCloud (Code Quality Analysis):**

```bash
# Get token from: https://sonarcloud.io/account/security
bash .agent/scripts/setup-local-api-keys.sh set sonar YOUR_SONAR_TOKEN
```

#### **GitHub (Git Platform Integration):**

```bash
# Get token from: Settings → Developer settings → Personal access tokens
bash .agent/scripts/setup-local-api-keys.sh set github YOUR_GITHUB_TOKEN
```

#### **GitLab (Git Platform Integration):**

```bash
# Get token from: User Settings → Access Tokens
bash .agent/scripts/setup-local-api-keys.sh set gitlab YOUR_GITLAB_TOKEN
```

#### **Spaceship (Domain Management):**

```bash
# Get API key from: Spaceship Dashboard → API Settings
bash .agent/scripts/setup-local-api-keys.sh set spaceship YOUR_SPACESHIP_API_KEY
```

### **3. Verify Storage**

```bash
# List configured services (without showing keys)
bash .agent/scripts/setup-local-api-keys.sh list

# Load all keys into environment (when needed)
bash .agent/scripts/setup-local-api-keys.sh load
```

## 🔍 **STORAGE LOCATIONS**

### **✅ SECURE (USER-PRIVATE ONLY):**

- **Unified Storage**: `~/.config/ai-assisted-devops/api-keys` (permissions: 600)
- **Directory**: `~/.config/ai-assisted-devops/` (permissions: 700)
- **Legacy CodeRabbit**: `~/.config/coderabbit/api_key` (fallback support)

### **❌ NEVER STORE IN:**

- Repository files (any `.json`, `.sh`, `.md` files in the repo)
- Environment variables visible to other processes
- Configuration files tracked by Git
- Documentation or code examples

## 🚀 **CLI INTEGRATION**

### **Automatic Loading:**

All CLI scripts automatically load API keys from unified secure storage:

- **Codacy CLI**: Loads from unified storage automatically
- **CodeRabbit CLI**: Loads from unified storage (with legacy fallback)
- **SonarScanner CLI**: Loads from unified storage automatically
- **Git Platform helpers**: Load tokens as needed

### **Manual Loading:**

```bash
# Load all API keys into current shell environment
bash .agent/scripts/setup-local-api-keys.sh load

# Verify environment variables are set
echo "Codacy: ${CODACY_API_TOKEN:0:10}..."
echo "Sonar: ${SONAR_API_TOKEN:0:10}..."
```

## 🛡️ **SECURITY FEATURES**

### **File Permissions:**

- **Directory**: `700` (owner read/write/execute only)
- **API key file**: `600` (owner read/write only)
- **No group or world access**

### **Automatic Security:**

- CLI scripts check secure storage first
- Fallback to environment variables if needed
- Never expose keys in process lists
- Secure file creation and updates

## 🔧 **TROUBLESHOOTING**

### **API Key Not Found:**

```bash
# Check if key is stored
bash .agent/scripts/setup-local-api-keys.sh get codacy

# Re-store if missing
bash .agent/scripts/setup-local-api-keys.sh set codacy YOUR_NEW_TOKEN
```

### **Permission Issues:**

```bash
# Fix directory permissions
chmod 700 ~/.config/ai-assisted-devops
chmod 600 ~/.config/ai-assisted-devops/api-keys
```

### **CLI Not Loading Keys:**

```bash
# Manually load into environment
bash .agent/scripts/setup-local-api-keys.sh load

# Test CLI with loaded environment
bash .agent/scripts/codacy-cli.sh analyze
```

## 🎯 **BEST PRACTICES**

1. **Regular Rotation**: Rotate API keys every 90 days
2. **Minimal Permissions**: Use tokens with minimal required scopes
3. **Monitor Usage**: Check API usage in provider dashboards
4. **Secure Backup**: Document token sources for regeneration
5. **Never Share**: API keys are personal and should never be shared

**Remember: Security is not optional - it's mandatory for professional development.**
