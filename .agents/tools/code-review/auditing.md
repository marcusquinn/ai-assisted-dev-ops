---
description: Code auditing services and security analysis
mode: subagent
steps: 12
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Code Auditing Services Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `.agents/scripts/code-audit-helper.sh`
- **Services**: CodeRabbit (AI reviews), CodeFactor (quality), Codacy (enterprise), SonarCloud (security)
- **Config**: `configs/code-audit-config.json`
- **Commands**: `services` | `audit [repo]` | `report [repo] [file]` | `start-mcp [service] [port]`
- **MCP Ports**: CodeRabbit (3003), Codacy (3004), SonarCloud (3005)
- **Quality Gates**: repository-configured coverage policy (if any), 0 major bugs, 0 high vulnerabilities, <3% duplication

<!-- AI-CONTEXT-END -->

## Services

| Service | Focus | Strengths | MCP |
|---------|-------|-----------|-----|
| **CodeRabbit** | AI-powered code reviews | Context-aware reviews, security analysis | Port 3003 |
| **CodeFactor** | Automated quality analysis | Simple setup, clear metrics, GitHub integration | — |
| **Codacy** | Quality + security analysis | Comprehensive metrics, team collaboration | Port 3004 |
| **SonarCloud** | Industry-standard analysis | Comprehensive rules, quality gates | Port 3005 |

## Configuration

```bash
cp configs/code-audit-config.json.txt configs/code-audit-config.json
# Edit with your service API tokens — store via `aidevops secret set NAME` (gopass) or `~/.config/aidevops/credentials.sh` (600 perms)
```

Config structure (per service): `{ "accounts": { "<account>": { "api_token": "...", "base_url": "...", "organization": "..." } } }`

## Usage

```bash
# Core
./.agents/scripts/code-audit-helper.sh services                    # list services
./.agents/scripts/code-audit-helper.sh audit my-repository         # run audit
./.agents/scripts/code-audit-helper.sh report my-repo report.json  # generate report

# Service-specific pattern: {service}-repos <account> | {service}-{action} <account> <target>
./.agents/scripts/code-audit-helper.sh coderabbit-repos personal
./.agents/scripts/code-audit-helper.sh coderabbit-analysis personal repo-id
./.agents/scripts/code-audit-helper.sh codacy-repos organization
./.agents/scripts/code-audit-helper.sh codacy-quality organization my-repo
./.agents/scripts/code-audit-helper.sh codefactor-repos personal
./.agents/scripts/code-audit-helper.sh codefactor-issues personal my-repo
./.agents/scripts/code-audit-helper.sh sonarcloud-projects personal
./.agents/scripts/code-audit-helper.sh sonarcloud-measures personal project-key

# MCP servers (codacy: https://github.com/codacy/codacy-mcp-server, sonarcloud: https://github.com/SonarSource/sonarqube-mcp-server)
./.agents/scripts/code-audit-helper.sh start-mcp coderabbit 3003
./.agents/scripts/code-audit-helper.sh start-mcp codacy 3004
./.agents/scripts/code-audit-helper.sh start-mcp sonarcloud 3005
```

## Quality Gates

| Metric | Threshold | Fail Build |
|--------|-----------|------------|
| Code Coverage | Repository-configured threshold only; no aidevops default | Only when already required |
| Major Bugs | 0 | Yes |
| High Vulnerabilities | 0 | Yes |
| Security Hotspots | 0 high-severity | Yes |
| Duplicated Lines | ≤3% | No |

## CI/CD Integration

```yaml
run: |
  ./.agents/scripts/code-audit-helper.sh audit ${{ github.repository }}
  ./.agents/scripts/code-audit-helper.sh report ${{ github.repository }} audit-report.json
```

Upload `audit-report.json` as an artifact via `actions/upload-artifact@v4`. See `AGENTS.md` "Security Rules" and `reference/secret-handling.md` for full secret-handling rules.

## Review Categories

For structured code review issue classification (severity levels, examples, exceptions), see `tools/code-review/review-categories.md`. Use these categories when triaging audit findings to ensure consistent severity assignment across reviews.
