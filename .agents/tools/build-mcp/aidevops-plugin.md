---
description: Architecture design for aidevops-opencode plugin
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# aidevops-opencode Plugin Architecture

- **Status**: Implemented (`t008.1` PR #1138, `t008.2` PR #1149, `t008.3` PR #1150)
- **Purpose**: Native OpenCode plugin wrapper for aidevops
- **Implementation**: Modular ESM plugin rooted at `.agents/plugins/opencode-aidevops/index.mjs`
- **SDK**: `@opencode-ai/plugin` v1.1.56+ (`index.d.ts` on npm)
- **Boundary**: `generate-opencode-agents.sh` and `setup.sh` own static config; the plugin owns runtime hooks and tools. Shell-generated config wins on conflicts.

## Runtime surface

| Surface | Mechanism | Purpose |
|---|---|---|
| Agent loading + MCP registration | `config` hook | Adds runtime-only agent and MCP state |
| Custom tools | `tool` registration | Exposes aidevops-specific tools |
| Quality gates | `tool.execute.before` / `tool.execute.after` | Runs checks, tracking, and audit logging |
| Shell environment | `shell.env` hook | Exports aidevops paths and version |
| Session compaction | `experimental.session.compacting` hook | Adds a structured continuation handoff and preserves scoped operational state |

## Hooks

### `config`

- Loads subagents from `~/.aidevops/agents/`, parses YAML frontmatter, injects into `config.agent`, skips shell-generated entries (`t008.1`).
- Registers MCP servers from a data-driven registry instead of re-running `generate-opencode-agents.sh` (`t008.2`).
- Registry fields: `name`, `type` (`local`/`remote`), `command` or `url`, `eager`, `toolPattern`, `globallyEnabled`, `requiresBinary`, `macOnly`.
- `AGENT_MCP_TOOLS` maps agents to tool globs (e.g. `@dataforseo` → `dataforseo_*`). All 11 MCPs lazy-loaded, saving ~7K startup tokens.

| MCP | Type | Global tools |
|---|---|---|
| `playwriter` | local | yes |
| `context7` | remote | no |
| `outscraper` | local | no |
| `dataforseo` | local | no |
| `shadcn` | local | no |
| `claude-code-mcp` | local | no |
| `macos-automator` | local | no (macOS only) |
| `ios-simulator` | local | no (macOS only) |
| `sentry` | remote | no |
| `socket` | remote | no |

### Other hooks

| Hook | Coverage |
|---|---|
| `tool` registration | `aidevops`, `aidevops_memory`, `aidevops_pre_edit_check`, `model-accounts-pool` |
| `tool.execute.before` (`t008.3`) | ShellCheck (`-x -S warning`), return validation, `local var="$1"`, Markdown MD031, trailing whitespace, write-time secret scanning |
| `tool.execute.after` (`t008.3`) | Git operation detection, pattern tracking via cross-session memory, audit logging to `~/.aidevops/logs/quality-hooks.log` |
| `shell.env` | Prepends `~/.aidevops/agents/scripts/` to `PATH`; exports `AIDEVOPS_AGENTS_DIR`, `AIDEVOPS_WORKSPACE_DIR`, `AIDEVOPS_VERSION` |
| `experimental.session.compacting` | Adds a structured aim/continuation handoff and preserves active agent state, loop guardrails, session checkpoint, project-scoped memories (limit 5), git context, pending mailbox messages |

## Design decisions

| Decision | Why |
|---|---|
| Modular ESM, no build step | OpenCode loads the root `file://` ESM directly; focused modules need no TypeScript build |
| Zero runtime dependencies | Uses built-in Node.js APIs plus a lightweight YAML parser, not `gray-matter` or `zod` |
| Plugin complements shell setup | Shell owns primary config; plugin adds runtime behavior |
| Subagents load only in `config` | Avoids overriding intentional primary-agent config |
| Data-driven MCP registry | Captures runtime binary checks and platform logic that static JSON cannot |
| All MCPs lazy-loaded | Cuts startup cost by ~7K tokens |

## References

- [OpenCode Plugin SDK](https://opencode.ai/docs/plugins)
- Implementation: `.agents/plugins/opencode-aidevops/index.mjs`
- Plan: `todo/PLANS.md` section `aidevops-opencode Plugin` (`p001`)
