<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI DevOps Framework - Developer Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **User Guide**: `.agents/AGENTS.md` (deployed to `~/.aidevops/agents/`)
- **Commands**: `./setup.sh` (deploy) | `.agents/scripts/linters-local.sh` (quality) | `.agents/scripts/version-manager.sh release [major|minor|patch]`
- **Config**: Runtime-specific (see `.agents/AGENTS.md` "Runtime References")
- **Quality**: `.agents/AGENTS.md` "Framework Rules"

**File Structure**: `TODO.md` (tasks), `todo/` (plans, PRDs), `.agents/` (agents, tools, services, workflows, scripts).

**Before extending**: Read `.agents/aidevops/architecture.md` (design patterns, conventions, extension guide) and `.agents/aidevops/purpose.md` (value, ownership, and decision criteria).

<!-- AI-CONTEXT-END -->

## Two AGENTS.md Files

| File | Purpose | Audience |
|------|---------|----------|
| `~/Git/aidevops/AGENTS.md` | Development guide | Contributors |
| `~/Git/aidevops/.agents/AGENTS.md` | User guide | Users of aidevops |

The `.agents/AGENTS.md` is copied to `~/.aidevops/agents/AGENTS.md` by `setup.sh`.

## Development Lifecycle

See `.agents/AGENTS.md` "Operational Routines" for code-change routing and
`.agents/AGENTS.md` "Git Workflow" for the full lifecycle.
Completion self-check: see `.agents/AGENTS.md` "Framework Rules > Task and completion discipline".

## Contributing

See `.agents/aidevops/` (architecture, setup) and `.agents/tools/` (agent/MCP authoring) for framework development guidance:

| File | Purpose |
|------|---------|
| `.agents/tools/build-agent/build-agent.md` | Composing efficient agents |
| `.agents/tools/build-agent/agent-review.md` | Reviewing and improving agents |
| `.agents/tools/build-mcp/build-mcp.md` | MCP server development |
| `.agents/tools/mcp-toolkit/mcporter.md` | MCP runtime toolkit (discover, call, generate CLIs) |
| `.agents/aidevops/architecture.md` | Framework structure |
| `.agents/aidevops/setup.md` | AI guide to setup.sh |

## Agent Design Principles

From `.agents/tools/build-agent/build-agent.md`:

1. **Instruction budget**: ~50-100 per agent is a maintainability heuristic; investigate overages, but do not cut solely to hit the count
2. **Universal applicability**: Every instruction relevant to >80% of tasks
3. **Progressive disclosure**: Pointers to subagents, not inline content
4. **Code examples**: Only when authoritative; otherwise use stable `rg "pattern"` search references or section headings
5. **Ambient self-improvement**: Inherit `reference/self-improvement.md`; preserve the current outcome, then capture or fix evidenced lessons without requiring a command

Contributor rule: changes that add or expand always-loaded guidance (`AGENTS.md`,
`.agents/AGENTS.md`, `.agents/prompts/build.txt`) must prefer a short pointer plus a
reference/workflow document, keep `.agents/AGENTS.md` under the CI size ratchet,
and justify any intentional baseline increase in the PR body.

## Security

Security rules: see `.agents/AGENTS.md` "Framework Rules > Security and external content". Additional contributor rule:
- Use placeholders in examples, note secure storage location

## Quality Workflow

```bash
# Before committing
.agents/scripts/linters-local.sh

# ShellCheck all scripts
find .agents/scripts/ -name "*.sh" -exec shellcheck {} \;

# Release new version
.agents/scripts/version-manager.sh release [major|minor|patch]
```

## Self-Assessment Protocol

From `.agents/tools/build-agent/build-agent.md`:

- **Triggers**: Observable failure, user correction, contradiction, staleness, repeated friction, reusable success
- **Process**: Preserve the outcome, cite evidence, classify scope/sensitivity, check duplicates, then fix and verify or route
- **Duplicates**: Always `rg "pattern" .agents/` before adding instructions
