# Scripts Security Guide

## 🔐 **SECURE SCRIPT DIRECTORY STRUCTURE**

### **📁 DIRECTORY ORGANIZATION:**

```text
.agent/
├── scripts/              # ✅ SHARED (committed to Git)
│   ├── codacy-cli.sh
│   ├── coderabbit-cli.sh
│   ├── setup-local-api-keys.sh
│   └── sonarscanner-cli.sh
└── scripts-private/      # 🔒 PRIVATE (never committed)
    ├── clean-git-history-template.sh
    └── [your-custom-scripts.sh]
```

### **🛡️ SECURITY PRINCIPLES:**

#### **✅ SHARED SCRIPTS (scripts/):**

- **Purpose**: General-purpose scripts safe for public repositories
- **Security**: Never contain actual API keys or sensitive data
- **Usage**: Use placeholders like `YOUR_API_KEY_HERE`
- **Git Status**: ✅ **COMMITTED** to repository

#### **🔒 PRIVATE SCRIPTS (scripts-private/):**

- **Purpose**: Scripts containing actual API keys or sensitive operations
- **Security**: Never committed to Git (protected by .gitignore)
- **Usage**: Customized with real API keys for local operations
- **Git Status**: ❌ **NEVER COMMITTED** (gitignored)

## 🔧 **USAGE GUIDELINES**

### **Creating Secure Scripts:**

#### **1. For General Scripts (Shared):**

```bash
# ✅ CORRECT: Use placeholders
readonly API_TOKEN="YOUR_API_TOKEN_HERE"

# ✅ CORRECT: Load from secure storage
api_key=$(.agent/scripts/setup-local-api-keys.sh get service)

# ❌ NEVER: Hardcode actual API keys
readonly API_TOKEN="abc123xyz789"  # SECURITY BREACH!
```

#### **2. For Sensitive Scripts (Private):**

```bash
# Create in scripts-private/ directory
cp .agent/scripts-private/clean-git-history-template.sh \
   .agent/scripts-private/my-cleanup.sh

# Customize with actual API keys (safe because never committed)
readonly API_KEYS=(
    "actual_api_key_1"
    "actual_api_key_2"
)
```

### **Security Verification:**

```bash
# Verify private scripts are gitignored
git status --ignored | grep scripts-private

# Should show: .agent/scripts-private/ (ignored)
```

## 🚨 **SECURITY VIOLATIONS TO AVOID**

### **❌ NEVER DO:**

1. **Hardcode API keys** in shared scripts
2. **Commit scripts-private/** directory to Git
3. **Include actual credentials** in any committed files
4. **Share private scripts** outside secure channels

### **✅ ALWAYS DO:**

1. **Use placeholders** in shared scripts
2. **Keep sensitive scripts** in scripts-private/
3. **Verify .gitignore** protects private directory
4. **Use secure storage** for API keys

## 🔄 **MIGRATION PROCESS**

### **Moving Sensitive Scripts:**

```bash
# Move sensitive script to private directory
mv .agent/scripts/sensitive-script.sh \
   .agent/scripts-private/sensitive-script.sh

# Create safe template in shared directory
cp .agent/scripts-private/sensitive-script.sh \
   .agent/scripts/sensitive-script-template.sh

# Replace API keys with placeholders in template
sed -i 's/actual_api_key/YOUR_API_KEY_HERE/g' \
   .agent/scripts/sensitive-script-template.sh
```

## 🎯 **BEST PRACTICES**

### **Script Development Workflow:**

1. **Start with template** in scripts-private/
2. **Customize with real data** for testing
3. **Create sanitized version** for scripts/
4. **Verify no secrets** in shared version
5. **Commit only safe template** to Git

### **Security Checklist:**

- [ ] No API keys in shared scripts
- [ ] Private directory properly gitignored
- [ ] Templates use placeholders only
- [ ] Sensitive scripts never committed
- [ ] Regular security audits performed

**Remember: Security is not optional - it's mandatory for professional development.**
