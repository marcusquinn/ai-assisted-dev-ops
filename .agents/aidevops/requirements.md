---
description: Framework requirements and capabilities
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Framework Requirements & Capabilities

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Services**: 25+ providers with unified command patterns
- **Quality**: SonarCloud A-grade, CodeFactor A-grade, ShellCheck zero violations
- **Security**: Zero credential exposure, encrypted storage, confirmation prompts
- **Performance**: <1s local ops, <5s API calls, 10+ concurrent operations
- **MCP**: Real-time data access via MCP servers
- **Quality check**: `curl -s "https://sonarcloud.io/api/measures/component?component=marcusquinn_aidevops&metricKeys=bugs,vulnerabilities,code_smells"`
- **ShellCheck**: `find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;`

<!-- AI-CONTEXT-END -->

## Core Requirements

### Functional

- **Multi-provider support**: 25+ services through unified interfaces
- **Secure credential management**: Enterprise-grade security (details: `security-requirements.md`)
- **Consistent command patterns**: Helper scripts follow `scripts/[service]-helper.sh [command] [account] [target]` as the base convention, but individual scripts accept service-specific positional parameters (e.g., `url`, `report_type`, `issue_number`, `repo_slug`, `tenant`). A fully standardized CLI interface across all helpers is a planned future framework improvement.
- **Real-time integration**: MCP server support for live data access
- **Intelligent setup**: Guided configuration via setup wizard
- **Comprehensive monitoring**: Health checks across all services
- **Automated operations**: DevOps workflow automation
- **Error recovery**: Robust error handling with retry and backoff

### Non-Functional

- **Security**: Zero credential exposure, secure by default (details: `security-requirements.md`)
- **Performance**: Sub-second local ops, <5s API calls, <500ms MCP responses
- **Scalability**: Unlimited service accounts, 1000+ resources per service, 10+ concurrent ops
- **Maintainability**: Modular architecture (details: `architecture.md`)
- **Compatibility**: Cross-platform (macOS, Linux, Windows)
- **Auditability**: Complete audit trails for all operations

## Quality Standards (Mandatory)

All code changes must maintain these standards. Also enforced in `AGENTS.md` "Quality Standards".

**Platforms**: SonarCloud (A-grade), CodeFactor (A-grade), GitHub Actions (all checks pass), ShellCheck (zero violations)

**Metrics**: Zero security vulnerabilities, 0.0% code duplication, <400 code smells

**Validation process**:

1. Pre-commit: ShellCheck on modified shell scripts
2. Post-commit: Verify SonarCloud/CodeFactor improvements
3. Continuous: Monitor quality platforms for regressions

```bash
# SonarCloud status
curl -s "https://sonarcloud.io/api/measures/component?component=marcusquinn_aidevops&metricKeys=bugs,vulnerabilities,code_smells"

# CodeFactor status
curl -s "https://www.codefactor.io/repository/github/marcusquinn/aidevops"

# ShellCheck validation
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;
```

## Service Categories

| Category | Services | Key Capabilities |
|----------|----------|-----------------|
| Infrastructure & Hosting | Hostinger, Hetzner Cloud, Cloudflare, Closte (legacy operations), Cloudron | Provisioning, monitoring, scaling, backup, SSL |
| Deployment & Orchestration | Coolify | App deployment, container orchestration, CI/CD, rollback |
| Content Management | MainWP | WordPress at scale, plugin/theme updates, security scanning |
| Security & Secrets | Vaultwarden | Credential storage, password generation, team sharing, audit logging |
| Code Quality & Auditing | CodeRabbit, CodeFactor, Codacy, SonarCloud | Automated analysis, vulnerability detection, quality gates |
| Version Control | GitHub, GitLab, Gitea, Local Git | Repo management, PR automation, CI/CD integration |
| Email | Amazon SES | Delivery, bounce handling, reputation management |
| Domain & DNS | Spaceship, 101domains, Cloudflare, Namecheap, Route 53 | Domain management, DNS records, SSL, CDN |
| Development & Local | Localhost, LocalWP, Context7 MCP, MCP Servers | Local dev environments, real-time docs, AI integration |

## Cross-Cutting Concerns

Detailed requirements for these areas live in dedicated files:

- **Security**: `security-requirements.md` -- credential management, incident response, compliance
- **Architecture**: `architecture.md` -- service patterns, extension guide, naming conventions
- **Quality enforcement**: `AGENTS.md` -- write-time linting, pre-commit checks
- **Monitoring & observability**: Health checks, error alerting, and audit logging are implemented per-service in each `*-helper.sh` script
