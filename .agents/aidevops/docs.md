---
description: Documentation AI context and guidelines
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

# Documentation AI Context

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Location**: `.agents/*.md` (lowercase filenames)
- **Discovery**: `git ls-files '.agents/*.md'` — never hardcode guide lists
- **Guide shape**: Overview → Configuration → Usage → Security → Troubleshooting → MCP/AI integration
- **Quick-load block**: `<!-- AI-CONTEXT-START -->` for stable high-signal context
- **Config templates**: `configs/[service]-config.json.txt`
- **Setup docs**: `*-setup.md` for multi-step integrations
- **Provider guidance**: `aidevops/recommendations.md`
- **Cross-service flows**: Domain → DNS → Hosting; Dev → Quality → Deploy
- **Priority**: service guide → framework context → best-practices guide → setup guide → Context7 MCP for latest external docs

<!-- AI-CONTEXT-END -->

## Service Guide Categories

| Category | Guides |
|----------|--------|
| Infrastructure & Hosting | services/hosting/hostinger.md, services/hosting/hetzner.md, services/hosting/cloudflare.md, services/hosting/closte.md (legacy), services/hosting/cloudron.md |
| Deployment & Content | coolify.md, mainwp.md |
| Security & Quality | vaultwarden.md, code-auditing.md |
| Version Control & Domains | git-platforms.md, domain-purchasing.md, spaceship.md, 101domains.md |
| Email & DNS | ses.md, dns-providers.md |
| Development & Local | localhost.md, localwp-mcp.md, mcp-servers.md, context7-mcp-setup.md |
| Framework | aidevops/recommendations.md, services/hosting/cloudflare.md, tools/deployment/coolify.md |

## Standard Guide Structure

Sections in order: `# [Service Name] Guide` → `## Provider Overview` (type, strengths, API, use cases) → `## Configuration` → `## Usage Examples` → `## Security Best Practices` → `## Troubleshooting` → `## MCP Integration` / `## AI Assistant Integration` (when relevant) → `## Best Practices`

## Standards & Maintenance

Cover core features, working examples, security concerns, troubleshooting, and AI integration patterns. Use clear technical language, consistent formatting, syntax-highlighted code, and cross-references. Keep commands accurate, examples sanitized, API details current (version notes when they matter). Update on API changes, new features, and security advisories.
