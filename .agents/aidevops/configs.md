---
description: Configuration files AI context
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Configuration Files AI Context

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Templates**: `configs/[service]-config.json.txt` (safe to commit)
- **Working files**: `configs/[service]-config.json` (gitignored, NEVER COMMIT)
- **Setup wizard**: `.agents/scripts/setup-wizard-helper.sh full-setup`
- **Generate configs**: `.agents/scripts/setup-wizard-helper.sh generate-configs`
- **Test connections**: `.agents/scripts/setup-wizard-helper.sh test-connections`
- **Validate JSON**: `jq '.' [service]-config.json`
- **Secure permissions**: `chmod 600 configs/*-config.json`
- **Structure**: `{"accounts": {...}, "default_settings": {...}, "mcp_servers": {...}}`
- **Multi-account**: personal/work/client accounts per service

<!-- AI-CONTEXT-END -->

## File Structure

| Type | Pattern | Committed? |
|------|---------|-----------|
| Template | `[service]-config.json.txt` | Yes — placeholders only |
| Working | `[service]-config.json` | **NEVER** — contains credentials |
| Wizard responses | `setup-wizard-responses.json` | **NEVER** |

## Configuration Categories

| Category | Files |
|----------|-------|
| Infrastructure & Hosting | `hostinger`, `hetzner`, `cloudron`; `closte` (legacy compatibility) |
| Deployment | `coolify` |
| Content Management | `mainwp` |
| Security & Secrets | `vaultwarden` |
| Code Quality | `code-audit` |
| Version Control | `git-platforms` |
| Email | `ses` |
| Domain & DNS | `spaceship`, `101domains`, `cloudflare-dns`, `namecheap-dns`, `route53-dns`, `other-dns-providers` |
| Development & Local | `localhost`, `mcp-servers`, `context7-mcp` |

All filenames follow `[service]-config.json.txt` (template) / `[service]-config.json` (working).

## Standard JSON Structure

```json
{
  "accounts": {
    "personal": { "api_token": "YOUR_TOKEN_HERE", "base_url": "https://api.service.com" },
    "work":     { "api_token": "YOUR_TOKEN_HERE" }
  },
  "default_settings": { "timeout": 30, "rate_limit": 60, "retry_attempts": 3 },
  "mcp_servers": { "service": { "enabled": true, "port": 3001, "host": "localhost" } }
}
```

## Setup

```bash
# Manual
cp [service]-config.json.txt [service]-config.json
nano [service]-config.json
chmod 600 [service]-config.json
../.agents/scripts/[service]-helper.sh accounts   # verify

# Automated
../.agents/scripts/setup-wizard-helper.sh full-setup
```

## Security Rules

- **NEVER COMMIT** working `.json` files — `.gitignore` covers them, but verify: `git status --porcelain configs/`
- **Restrict permissions**: `chmod 600 configs/*-config.json`
- **Never expose credentials** in logs, output, or error messages
- **Validate before operations**: `jq '.' [service]-config.json`
- **Credential rotation**: every 6-12 months; remove unused accounts
- **Verify coverage**: `git check-ignore configs/*-config.json`
