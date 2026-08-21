---
description: Cloudflare DNS, CDN, and API token setup for managing/configuring Cloudflare resources. For building on the Cloudflare platform (Workers, Pages, D1, R2, KV, AI, etc.), see cloudflare-platform-skill.md.
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare API Setup for AI-Assisted Development

## Intent-Based Routing

| Intent | Resource |
|--------|----------|
| **Manage/configure** Cloudflare resources (DNS, WAF, DDoS, R2, Workers, zones, rules) | `.agents/tools/mcp/cloudflare-code-mode.md` — Code Mode MCP (2,500+ endpoints, live OpenAPI) |
| **Build/develop** on the Cloudflare platform (Workers, Pages, D1, KV, Durable Objects, AI) | [`cloudflare-platform-skill.md`](cloudflare-platform-skill.md) — patterns, gotchas, decision trees, SDK usage |
| **Auth/token setup** for API access | This file (below) |

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Hosting role**: Prefer for edge/serverless/static/headless workloads and global delivery/security; conventional PHP/MySQL WordPress normally uses Cloudflare in front of a Hostinger or Hetzner origin
- **Provider selection**: Apply `aidevops/recommendations.md` before treating Cloudflare as the hosting platform rather than the edge layer
- **Auth**: API Tokens only (NEVER Global API Keys)
- **Token creation**: Dashboard > My Profile > API Tokens > Create Token
- **Permissions**: Zone:Read, DNS:Read, DNS:Edit (scope to specific zones)
- **Config**: `configs/cloudflare-dns-config.json`
- **Account ID**: Dashboard > Right sidebar > 32-char hex
- **Zone ID**: Domain overview > Right sidebar > 32-char hex
- **API test**: `curl -X GET "https://api.cloudflare.com/client/v4/zones" -H "Authorization: Bearer TOKEN"`
- **Security**: IP filtering, expiration dates, minimal permissions
- **Rotation**: Every 6-12 months or after team changes
- **Code Mode MCP**: `.agents/tools/mcp/cloudflare-code-mode.md` (operations via 2,500+ endpoints)

<!-- AI-CONTEXT-END -->

## Why API Tokens Over Global API Keys

| | Global API Keys | API Tokens |
|---|---|---|
| Scope | Unrestricted account access | Scoped to specific permissions/zones |
| Billing | Can modify billing/settings | Cannot (unless explicitly granted) |
| Expiry | Never expire | Configurable expiration |
| Audit | Hard to trace actions | Clear usage logs |
| Revocation | Affects entire account | Revoke individually |

**Rule: Always use API Tokens. Global API Keys are a single point of failure if compromised.**

## Token Setup

### 1. Create Token

1. Dashboard > My Profile > API Tokens > Create Token > Custom token
2. **Name**: `AI-Assistant-DevOps-[AccountName]`
3. **Permissions**:

```text
Zone:Read          - Read zone information
Zone:Edit          - Modify zone settings (optional)
DNS:Read           - Read DNS records
DNS:Edit           - Modify DNS records
Zone Settings:Read - Read zone settings (optional)
```

4. **Zone Resources**: Include > Specific zones > [Select your domains]
5. **IP Filtering** (recommended): Include > [Your home/office IP]
6. **Expiration**: Set to 1 year maximum

### 2. Collect IDs

- **Account ID**: Dashboard right sidebar > 32-char hex string
- **Zone IDs**: Domain overview > right sidebar (collect for each managed domain)
- **Email**: Account email (used for some API calls)

### 3. Configure Locally

```bash
cp configs/cloudflare-dns-config.json.txt configs/cloudflare-dns-config.json
```

Edit the config:

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

## Security Best Practices

- **Separate tokens** per Cloudflare account with descriptive names
- **Minimum permissions** scoped to specific zones (not all zones)
- **IP restrictions** and **expiration dates** always set
- **Never commit** tokens to git; use env vars for CI/CD
- **File permissions**: `chmod 600` on config files
- **Rotate** every 6-12 months, after team changes, or immediately if compromised
- **Audit** active tokens regularly in the dashboard

## Testing

```bash
curl -X GET "https://api.cloudflare.com/client/v4/zones" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json"
```

Success returns `"success": true` with your zone list.

## Common AI-Assisted Tasks

```bash
# Create development subdomain
./.agents/scripts/dns-helper.sh create-record personal dev.yourdomain.com A 192.168.1.100

# Setup SSL for local development
./.agents/scripts/dns-helper.sh create-record personal local.yourdomain.com CNAME yourdomain.com

# Manage staging environments
./.agents/scripts/dns-helper.sh create-record business staging.company.com A 10.0.1.50
```

Use cases: automated DNS for dev environments, dynamic subdomains for feature branches, SSL automation, traffic routing for A/B testing, security rule management for dev APIs.

## If a Token Is Compromised

1. **Immediately revoke** the token in Cloudflare dashboard
2. **Check audit logs** for unauthorized changes
3. **Create new token** with fresh permissions
4. **Update local config** with the new token
5. **Review practices** to prevent recurrence

## Resources

- [Cloudflare API Docs](https://developers.cloudflare.com/api/)
- [Token Management](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [Security Best Practices](https://developers.cloudflare.com/fundamentals/api/get-started/security/)
