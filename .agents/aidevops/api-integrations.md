---
description: API service catalog — auth, config, and helper script reference for 28+ integrations
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

# API Integration Guide

<!-- AI-CONTEXT-START -->

**Pattern**: `configs/[service]-config.json` + `scripts/[service]-helper.sh`

```bash
setup-local-api-keys.sh set [service]-api-key YOUR_KEY
setup-local-api-keys.sh list
test-all-apis.sh
```

<!-- AI-CONTEXT-END -->

## Setup

```bash
bash setup.sh  # Full setup

# Single service
cp configs/[service]-config.json.txt configs/[service]-config.json
scripts/[service]-helper.sh test-connection
```

## Service Catalog

### Security & Code Quality

| Service | Auth | Notes |
|---------|------|-------|
| Vaultwarden | API Token | Credential storage, secure sharing, audit logs |
| CodeRabbit | API Key | AI code review (`coderabbit-cli.sh`), security scanning |
| Codacy | API Token | Quality metrics, coverage tracking (`codacy-cli.sh`) |
| SonarCloud | API Token | Security hotspots, code smells, coverage (GitHub Actions) |
| CodeFactor | GitHub integration | Quality scoring, trend analysis (automatic) |

### Git Platforms

Shared helper: `git-platforms-helper.sh`.

| Service | Auth | Notes |
|---------|------|-------|
| GitHub | Personal Access Token | Repos, Actions, security scanning |
| GitLab | Personal Access Token | Projects, CI/CD pipelines, security features |
| Gitea | API Token | Self-hosted repos, user admin, webhooks |

### Infrastructure & Hosting

| Service | Auth | Notes |
|---------|------|-------|
| Hostinger | API Token | VPS, domains, hosting plans |
| Hetzner Cloud | API Token | Servers, networking, snapshots, load balancers |
| Closte (legacy) | API Key | Existing managed WordPress estates and migration only |
| Coolify | API Token | Self-hosted PaaS, Docker, service management |

### Domain & DNS

| Service | Auth | Notes |
|---------|------|-------|
| Cloudflare | API Token (scoped) | DNS, security rules, analytics (`cloudflare-dns-config.json`, `dns-helper.sh`) |
| Spaceship | API Key | Registration, WHOIS, transfers (`spaceship-helper.sh`) |
| 101domains | API Credentials | Bulk operations, pricing, availability (`101domains-helper.sh`) |
| AWS Route 53 | AWS Access Keys | DNS hosting, health checks, traffic routing (`route53-dns-config.json`, `dns-helper.sh`) |
| Namecheap | API Key + Username | Domain management, DNS, SSL certificates (`namecheap-dns-config.json`, `dns-helper.sh`) |

### Communication

| Service | Auth | Notes |
|---------|------|-------|
| Amazon SES | AWS Access Keys | Email delivery, bounce tracking, reputation |
| Twilio | SID + Token | SMS, voice, WhatsApp, 2FA. AUP required. UI: https://mytelfon.com/ |
| MainWP | API Key | WordPress site management, updates, backups |

### SEO & Analytics

| Service | Auth | Notes |
|---------|------|-------|
| Ahrefs | API Key | Backlink analysis, keyword research (`mcp-server-ahrefs`) |
| Google Search Console | Service Account (GCP) | Search analytics, Core Web Vitals (`mcp-server-gsc`) |
| Perplexity | API Key | Research queries, fact-checking (`perplexity-mcp`) |

### Development Tools

| Service | Auth | Notes |
|---------|------|-------|
| Context7 | API Key | Real-time library docs, code examples (`@context7/mcp-server`) |
| LocalWP | Local access | WordPress DB queries, site management (custom MCP server) |
| Pandoc | None (local) | Multi-format to markdown conversion, 20+ formats (`pandoc-helper.sh`) |
| Agno AgentOS | LLM keys | Multi-agent framework, production runtime (`agno-setup.sh`) |
| Playwright/Selenium | Site credentials | Local browser automation only — no cloud services (`agno-setup.sh`) |

## References

- [Security Best Practices](security.md)
- [Configuration Templates](../configs/)
- [Helper Scripts](../scripts/)
