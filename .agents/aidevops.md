---
name: aidevops
description: Framework operations subagent - use @aidevops for setup, configuration, troubleshooting (Build+ is the primary agent)
mode: subagent
subagents:
  # Framework internals
  - setup
  - troubleshooting
  - routines-health
  - architecture
  - add-new-mcp-to-aidevops
  - mcp-integrations
  - mcp-troubleshooting
  - configs
  - providers
  # Agent development
  - build-agent
  - agent-review
  - build-mcp
  - server-patterns
  - api-wrapper
  - transports
  - deployment
  # Workflows
  - git-workflow
  - release
  - version-bump
  - preflight
  - postflight
  # Code quality
  - code-standards
  - linters-local
  - secretlint
  # Credentials
  - api-key-setup
  - api-key-management
  - vaultwarden
  - list-keys
  # Built-in
  - general
  - explore
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI DevOps - Framework Operations Subagent

## Quick Reference

- **Repo**: `~/Git/aidevops/` | **Install**: `~/.aidevops/agents/`
- **Setup**: `./setup.sh` | **Quality**: `.agents/scripts/linters-local.sh` | **Release**: `.agents/scripts/version-manager.sh release [major|minor|patch]`
- **Scripts**: `.agents/scripts/[service]-helper.sh [command] [account] [target]`
- **Subagents**: `aidevops/setup.md`, `aidevops/troubleshooting.md`, `aidevops/architecture.md`
- **Agent dev**: `tools/build-agent/` | **MCP dev**: `tools/build-mcp/`

**Services**: Hostinger, Hetzner, Cloudflare, Closte (legacy operations), Cloudron, Coolify, Vercel, WordPress (MainWP/LocalWP), SonarCloud, Codacy, CodeRabbit, Snyk, Secretlint, GitHub/GitLab/Gitea, Spaceship, 101domains, Route53, Vaultwarden, Amazon SES, Crawl4AI

**MCP ports**: 3001 LocalWP DB · 3002 Vaultwarden · + Chrome DevTools, Playwright, Ahrefs, Context7, GSC

**Testing**: `opencode run "Test query" --agent AI-DevOps` — see `tools/opencode/opencode.md`

## Configuration

```bash
configs/[service]-config.json.txt   # Templates (committed)
configs/[service]-config.json       # Working configs (gitignored)
~/.config/aidevops/credentials.sh   # Credentials
```

## Quality Standards

- aidevops framework repository: SonarCloud A-grade (zero vulnerabilities, bugs)
- ShellCheck: Zero violations
- Pattern: `local var="$1"` not `$1` directly; explicit `return 0/1` in all functions

## Extending the Framework

See `aidevops/extension.md`:

1. Create helper script following existing patterns
2. Add config template
3. Create agent documentation
4. Update service index
5. Verify through the shipped framework path and applicable existing checks; do not add tests or test infrastructure by default (`reference/ci-gate-policy.md`)

## OpenCode Plugins

**Anthropic OAuth** (built-in since OpenCode v1.1.36+): Enables Claude Pro/Max authentication.

```bash
opencode auth login   # Select: Anthropic → Claude Pro/Max
```
