---
description: AI assistant guide for setup.sh script
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Setup Guide - AI Assistant for setup.sh

## Quick Reference

- **Script**: `~/Git/aidevops/setup.sh`
- **Run**: `cd ~/Git/aidevops && ./setup.sh`
- **Update**: `git pull && ./setup.sh` (backs up existing configs automatically)
- **Scoped deploy**: `./setup.sh --stage agents` or `aidevops setup --scope agents`
- **AI-session update**: `./setup.sh --stage ai-session` applies changed deploy stages and falls back to full setup when unsafe
- **Agents**: `~/.aidevops/agents/` | **Backups**: `~/.aidevops/config-backups/` | **Credentials**: `~/.config/aidevops/credentials.sh`

**What setup.sh does**: checks required deps (`jq`, `curl`, `ssh`, `sqlite3`) and optional deps (`sshpass`, `gh`, `glab`, `tea`); copies `.agents/` → `~/.aidevops/agents/` with timestamped config backups; injects AGENTS.md pointer into `~/.opencode/AGENTS.md`, `~/.cursor/AGENTS.md`, `~/.claude/AGENTS.md`, `~/.config/cursor/AGENTS.md`; updates OpenCode agent paths in `~/.config/opencode/opencode.json`.

**Deployed structure**: `~/.aidevops/agents/` (AGENTS.md, aidevops/, tools/, services/, workflows/, scripts/) + `~/.aidevops/config-backups/[YYYYMMDD_HHMMSS]/`

## Scoped Setup / Deploy

Use full setup for first installs, migrations, config schema changes, or broad release validation:

```bash
./setup.sh --non-interactive
aidevops setup --scope full
```

Use scoped setup when the change is isolated and a full deploy would add avoidable time or lock-wait surface:

| Change type | Minimal command |
|---|---|
| Agent/script-only change | `./setup.sh --stage agents` or `aidevops setup --scope agents` |
| OpenCode CLI/shim/setup logic | `./setup.sh --stage opencode` or `aidevops setup --scope opencode` |
| Hook change | `./setup.sh --stage hooks` or `aidevops setup --scope hooks` |
| Tabby profile change | `./setup.sh --stage tabby` or `aidevops setup --scope tabby` |
| Pulse or merge-scheduler plist change | `./setup.sh --stage pulse` or `aidevops setup --scope pulse` |
| AI session after release/update | `./setup.sh --stage ai-session` or `aidevops setup --scope ai-session` |

`./setup.sh --stage` also accepts the canonical stage names: `setup_opencode_cli`,
`deploy_aidevops_agents`, `setup_safety_hooks`, `setup_tabby`, and
`setup_supervisor_pulse`. The `ai-session` scope compares `~/.aidevops/.deployed-sha`
with the current checkout, runs the changed deploy stages, verifies `VERSION` and
`.deployed-sha`, and then runs full non-interactive setup only when incremental setup
is unsafe or fails. The Pulse scope refreshes both the main supervisor and the
dedicated merge scheduler. Unknown stages fail non-zero and print the valid list.

## Manual Configuration

If setup.sh doesn't support your AI assistant, add to its AGENTS.md or config:

```text
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.
```

Then point agent configurations to `~/.aidevops/agents/[agent].md`.

## Troubleshooting

**Missing deps:**

```bash
brew install jq curl sqlite3    # macOS
apt-get install jq curl sqlite3 # Ubuntu/Debian
```

**OpenCode not finding agents:** Check `~/.config/opencode/opencode.json` paths; verify `~/.aidevops/agents/` exists. See `tools/opencode/opencode.md`.

**Permissions:**

```bash
chmod 600 ~/.config/aidevops/credentials.sh
chmod 755 ~/.aidevops/agents/scripts/*.sh
```
