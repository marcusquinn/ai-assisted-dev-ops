---
description: Provider scripts and configuration context
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Provider Scripts AI Context

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Location**: `.agents/scripts/[service]-helper.sh`
- **Pattern**: `./[service]-helper.sh [command] [account] [target] [options]`
- **Standard commands**: `help | accounts | monitor | audit | status`
- **Config**: `configs/[service]-config.json`
- **Debug**: `DEBUG=1 ./[service]-helper.sh [command]`
- **Services**: hostinger, hetzner, closte, cloudron, coolify, mainwp, vaultwarden, ses, spaceship, 101domains, dns, git-platforms, localhost, code-audit, setup-wizard, toon, crawl4ai
- **Legacy-only**: Retain `closte` for existing estates, migration, and offboarding; use `aidevops/recommendations.md` for new hosting decisions
- **Security**: credentials from config files only; confirmation required for destructive/purchase ops

<!-- AI-CONTEXT-END -->

## Script Categories

| Category | Scripts |
|----------|---------|
| Infrastructure & Hosting | hostinger, hetzner, cloudron; closte (legacy compatibility) |
| Deployment | coolify |
| Content Management | mainwp |
| Security & Secrets | vaultwarden |
| Code Quality | code-audit |
| Data/LLM Exchange | toon (TOON format) |
| Version Control | git-platforms (GitHub, GitLab, Gitea, Local) |
| Email | ses (Amazon SES) |
| Domain & DNS | spaceship, 101domains, dns |
| Development | localhost (.local domains) |
| Setup | setup-wizard |

## Standard Script Structure

All scripts follow this pattern:

```bash
#!/bin/bash
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

CONFIG_FILE="../configs/[service]-config.json"

# Required functions: check_dependencies, load_config,
# get_account_config, api_request, list_accounts, show_help, main
main "$@"
```

## Security

- Credentials loaded from `configs/[service]-config.json` — never hardcoded
- Destructive, purchase, and production ops require explicit confirmation
- Exit codes: 0 = success, 1 = error; errors never expose credential values

## Adding New Scripts

1. Use an existing script as template; name: `[service-name]-helper.sh`
2. Implement all standard functions listed above
3. Add to the categories table in this file

## AI Usage Rules

- Prefer helper scripts over direct API calls
- Always follow confirmation patterns for destructive ops
- Respect rate limits; log important operations for audit
