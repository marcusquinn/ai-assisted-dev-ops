# Cloudflare API Setup for AI-Assisted Development

This guide shows you how to securely set up Cloudflare API access for local AI-assisted development, DevOps, and system administration.

## 🚨 **SECURITY FIRST: Never Use Global API Keys!**

### **❌ DON'T Use Global API Keys Because:**

- **Unrestricted access** to your entire Cloudflare account
- **Can modify billing** and account settings
- **Can delete zones** and critical configurations
- **Never expire** automatically
- **Hard to audit** what actions were performed
- **Single point of failure** if compromised

### **✅ DO Use API Tokens Because:**

- **Scoped permissions** - only access what you need
- **Zone-specific** - limit to specific domains
- **Time-limited** - set expiration dates
- **Auditable** - clear logs of token usage
- **Revocable** - easy to disable without affecting other services

## 🔧 **Step-by-Step API Token Setup**

### **1. Create API Tokens for Each Account**

#### **For Each Cloudflare Account:**

1. **Log into Cloudflare Dashboard**
2. **Go to**: My Profile → API Tokens
3. **Click**: "Create Token"
4. **Use**: "Custom token" template

#### **Recommended Token Configuration:**

**Token Name**: `AI-Assistant-DevOps-[AccountName]`

**Permissions**:

```
Zone:Read          - Read zone information
Zone:Edit          - Modify zone settings (optional)
DNS:Read           - Read DNS records
DNS:Edit           - Modify DNS records
Zone Settings:Read - Read zone settings (optional)
```

**Zone Resources**:

```
Include: Specific zones → [Select your domains]
```

**Client IP Address Filtering** (Recommended):

```
Include: [Your home/office IP address]
```

**TTL (Time to Live)**:

```
Set expiration: 1 year maximum
```

### **2. Get Required Information**

For each account, collect:

#### **Account ID**:

- **Dashboard**: Right sidebar → Account ID
- **Copy**: The 32-character hex string

#### **Zone IDs**:

- **Go to**: Domain overview page
- **Right sidebar**: Zone ID
- **Copy**: For each domain you'll manage

#### **Email Address**:

- **Account email**: Used for some API calls

### **3. Configure Your Local Setup**

#### **Copy Template**:

```bash
cp configs/cloudflare-dns-config.json.txt configs/cloudflare-dns-config.json
```

#### **Edit Configuration**:

```json
{
  "providers": {
    "cloudflare": {
      "accounts": {
        "personal": {
          "api_token": "your-actual-api-token-here",
          "email": "your-email@domain.com",
          "account_id": "your-32-char-account-id",
          "zones": {
            "yourdomain.com": "your-zone-id-here",
            "subdomain.yourdomain.com": "your-zone-id-here"
          }
        },
        "business": {
          "api_token": "business-api-token-here",
          "email": "business@company.com",
          "account_id": "business-32-char-account-id",
          "zones": {
            "company.com": "company-zone-id-here"
          }
        }
      }
    }
  }
}
```

## 🛡️ **Security Best Practices**

### **Token Management**:

- **Separate tokens** for each Cloudflare account
- **Descriptive names** for easy identification
- **Regular rotation** (every 6-12 months)
- **Immediate revocation** if compromised

### **Permission Scoping**:

- **Minimum required permissions** only
- **Specific zones** rather than all zones
- **IP restrictions** when possible
- **Expiration dates** always set

### **Local Security**:

- **Never commit** actual tokens to git
- **Use environment variables** for CI/CD
- **Secure file permissions** (600) on config files
- **Regular audits** of active tokens

## 🔍 **Testing Your Setup**

### **Test API Access**:

```bash
# Test with curl
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json"
```

### **Expected Response**:

```json
{
  "success": true,
  "errors": [],
  "messages": [],
  "result": [
    {
      "id": "zone-id-here",
      "name": "yourdomain.com",
      "status": "active"
    }
  ]
}
```

## 🤖 **AI Assistant Integration**

### **Benefits for AI Development**:

- **Automated DNS management** for development environments
- **Dynamic subdomain creation** for feature branches
- **SSL certificate automation** via Cloudflare
- **Traffic routing** for A/B testing
- **Security rule management** for development APIs

### **Common AI-Assisted Tasks**:

```bash
# Create development subdomain
./providers/dns-helper.sh create-record personal dev.yourdomain.com A 192.168.1.100

# Setup SSL for local development
./providers/dns-helper.sh create-record personal local.yourdomain.com CNAME yourdomain.com

# Manage staging environments
./providers/dns-helper.sh create-record business staging.company.com A 10.0.1.50
```

## 🚨 **Emergency Procedures**

### **If Token is Compromised**:

1. **Immediately revoke** the token in Cloudflare dashboard
2. **Check audit logs** for unauthorized changes
3. **Create new token** with fresh permissions
4. **Update local configuration** with new token
5. **Review security practices** to prevent future issues

### **Token Rotation Schedule**:

- **Every 6 months**: Rotate all API tokens
- **Before major deployments**: Verify token validity
- **After team changes**: Review and rotate shared access
- **Security incidents**: Immediate rotation

## 📚 **Additional Resources**

- **Cloudflare API Docs**: https://developers.cloudflare.com/api/
- **Token Management**: https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
- **Security Best Practices**: https://developers.cloudflare.com/fundamentals/api/get-started/security/

---

**Remember: Security first! Always use API tokens with minimal required permissions.** 🔒
