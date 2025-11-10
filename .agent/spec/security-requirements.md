# Security Requirements - CRITICAL COMPLIANCE

## 🚨 **ZERO TOLERANCE SECURITY POLICIES**

### **API Key Management (MANDATORY)**

#### **❌ NEVER ALLOWED:**

- Hardcoding API keys in source code
- Committing credentials to repository
- Storing secrets in configuration files tracked by Git
- Sharing API keys in documentation or comments
- **Including API keys in commit messages** (CRITICAL VIOLATION)
- Exposing credentials in Git history or commit metadata

#### **✅ REQUIRED PRACTICES:**

**Local Development:**

```bash
# Store in environment variables
export CODACY_API_TOKEN="your_token_here"
export SONAR_TOKEN="your_token_here"
export GITHUB_TOKEN="your_token_here"

# Add to shell profile for persistence
echo 'export CODACY_API_TOKEN="your_token_here"' >> ~/.bashrc
```

**GitHub Actions:**

```yaml
# Use GitHub Secrets
env:
  CODACY_API_TOKEN: ${{ secrets.CODACY_API_TOKEN }}
  SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
```

**Configuration Files:**

```json
{
  "api_token": "YOUR_API_TOKEN_HERE",  // Template placeholder
  "api_token": "${CODACY_API_TOKEN}"   // Environment variable reference
}
```

### **File Security Requirements**

#### **Protected Files (.gitignore):**

```text
# Security - Never commit sensitive information
configs/*-config.json
.env
.env.local
*.key
*.pem
secrets/
```

#### **Template Files (Safe to commit):**

```text
configs/service-config.json.txt  // Template with placeholders
configs/service-config.json      // Actual config (gitignored)
```

### **Security Incident Response**

#### **If API Key is Exposed:**

1. **IMMEDIATE**: Revoke the exposed key at provider
2. **IMMEDIATE**: Generate new API key
3. **IMMEDIATE**: Update local environment variables
4. **IMMEDIATE**: Update GitHub Secrets
5. **IMMEDIATE**: Remove key from Git history if committed
6. **DOCUMENT**: Log incident and remediation steps

#### **Git History Cleanup:**

```bash
# Remove sensitive file from history
git filter-branch --force --index-filter \
  'git rm --cached --ignore-unmatch path/to/sensitive/file' \
  --prune-empty --tag-name-filter cat -- --all

# Fix commit message with API key
git reset --hard COMMIT_HASH
git commit --amend -F secure-message.txt
git cherry-pick SUBSEQUENT_COMMITS
git push --force-with-lease origin main

# Force push to rewrite history
git push origin --force --all
```

### **Compliance Verification**

#### **Pre-Commit Checks:**

```bash
# Scan for potential secrets
grep -r "api_token.*:" . --include="*.sh" --include="*.json"
grep -r "API_TOKEN.*=" . --include="*.sh" --include="*.yml"

# Verify .gitignore coverage
git status --ignored
```

#### **Regular Security Audits:**

- Monthly review of all API keys and rotation
- Quarterly access review for all service accounts
- Annual security policy review and updates

### **Provider-Specific Security**

#### **Codacy:**

- API tokens from: https://app.codacy.com/account/api-tokens
- Scope: Repository analysis only
- Rotation: Every 90 days

#### **SonarCloud:**

- Tokens from: https://sonarcloud.io/account/security
- Scope: Project analysis only
- Rotation: Every 90 days

#### **GitHub:**

- Personal Access Tokens with minimal required scopes
- Fine-grained tokens preferred over classic tokens
- Regular review of token usage and permissions

## 🎯 **SECURITY COMPLIANCE CHECKLIST**

- [ ] No API keys in source code
- [ ] All sensitive configs in .gitignore
- [ ] Environment variables configured locally
- [ ] GitHub Secrets configured for CI/CD
- [ ] Regular key rotation schedule established
- [ ] Incident response procedures documented
- [ ] Security audit schedule implemented

**REMEMBER: Security is not optional - it's mandatory for professional development.**
