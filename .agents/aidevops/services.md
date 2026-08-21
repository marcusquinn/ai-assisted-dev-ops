---
description: Complete service integration guide
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

# Service Integration Guide

<!-- AI-CONTEXT-START -->

**Pattern**: `[service]-helper.sh` + `[service]-config.json` + `.agents/[service].md` per service.

## Service Catalogue

| Category | Service | Helper | Config | Docs |
|----------|---------|--------|--------|------|
| Infrastructure | Hostinger (preferred conventional WordPress hosting) | `hostinger-helper.sh` | `hostinger-config.json` | `.agents/services/hosting/hostinger.md` |
| Infrastructure | Hetzner Cloud (self-managed VPS/dedicated infrastructure) | `hetzner-helper.sh` | `hetzner-config.json` | `.agents/services/hosting/hetzner.md` |
| Infrastructure | Closte (legacy managed WordPress estates) | `closte-helper.sh` | `closte-config.json` | `.agents/services/hosting/closte.md` |
| Infrastructure | Cloudron (self-hosted app platform, auto-updates, backups) | `cloudron-helper.sh` | `cloudron-config.json` | `.agents/cloudron.md` |
| Deployment | Coolify (self-hosted PaaS, Docker, Git integration) | `coolify-helper.sh` | `coolify-config.json` | `.agents/coolify.md` |
| Content | MainWP (centralised WordPress management, bulk ops) | `mainwp-helper.sh` | `mainwp-config.json` | `.agents/mainwp.md` |
| Security | Vaultwarden (self-hosted Bitwarden, MCP server available) | `vaultwarden-helper.sh` | `vaultwarden-config.json` | `.agents/vaultwarden.md` |
| Email | Amazon SES (scalable delivery, high deliverability) | `ses-helper.sh` | `ses-config.json` | `.agents/services/email/ses.md` |
| Communications | Twilio (CPaaS — SMS, voice, WhatsApp, 2FA; comply with AUP) | `twilio-helper.sh` | `twilio-config.json` | `.agents/services/communications/twilio.md` |
| Communications | Telfon (Twilio-powered softphone, iOS/Android/Chrome/Edge) | — | — | `.agents/services/communications/telfon.md` |
| Domains | Spaceship (API purchasing, transparent pricing) | `spaceship-helper.sh` | `spaceship-config.json` | `.agents/spaceship.md`, `.agents/domain-purchasing.md` |
| Domains | 101domains (1000+ TLDs, bulk ops, reseller) | `101domains-helper.sh` | `101domains-config.json` | `.agents/101DOMAINS.md` |
| DNS | Cloudflare (CDN + DNS, DDoS protection) | `dns-helper.sh` | `cloudflare-dns-config.json` | `.agents/dns-providers.md` |
| DNS | Namecheap DNS (integrated with registration) | `dns-helper.sh` | `namecheap-dns-config.json` | `.agents/dns-providers.md` |
| DNS | Route 53 (AWS DNS, advanced routing, health checks) | `dns-helper.sh` | `route53-dns-config.json` | `.agents/dns-providers.md` |
| Dev/Local | Localhost (`.local` domain support) | `localhost-helper.sh` | `localhost-config.json` | `.agents/localhost.md` |
| Dev/Local | LocalWP (WordPress dev, DB access, MCP server) | `localhost-helper.sh` | `localhost-config.json` | `.agents/localwp-mcp.md` |
| Dev/Local | Context7 MCP (real-time docs for AI assistants) | integrated | `context7-mcp-config.json` | `.agents/context7-mcp-setup.md` |
| Dev/Local | MCP Servers (protocol server management) | integrated | `mcp-servers-config.json` | `.agents/mcp-servers.md` |
| Dev/Local | Crawl4AI (AI web crawler, LLM-ready output, RAG) | `crawl4ai-helper.sh` | `crawl4ai-config.json` | `.agents/crawl4ai.md` |
| Setup | Intelligent Setup Wizard (AI-guided infrastructure setup) | `setup-wizard-helper.sh` | `setup-wizard-responses.json` (generated) | integrated in service docs |

## Code Quality & Auditing

All four share `code-audit-helper.sh`, `code-audit-config.json`, and `.agents/code-auditing.md`.

| Service | Notes |
|---------|-------|
| CodeRabbit | AI-powered code review, context-aware analysis, security scanning. MCP server available. |
| CodeFactor | Automated quality, simple setup, clear metrics, GitHub integration. |
| Codacy | Comprehensive quality + security, custom rules, team collaboration. MCP server available. |
| SonarCloud | Industry-standard quality gates, security compliance. SonarQube MCP server available. |

## Version Control & Git Platforms

All four share `git-platforms-helper.sh`, `git-platforms-config.json`, and `.agents/git-platforms.md`.

| Service | Notes |
|---------|-------|
| GitHub | REST API v4 + GraphQL. Official MCP server available. |
| GitLab | Built-in CI/CD, security scanning, self-hosted option. Community MCP servers available. |
| Gitea | Lightweight self-hosted Git, minimal resources, GitHub-compatible API. Community MCP servers available. |
| Local Git | Offline development, no external dependencies. |

<!-- AI-CONTEXT-END -->
