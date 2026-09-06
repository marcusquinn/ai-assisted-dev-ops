---
name: beads
description: This subagent should only be called manually by the user.
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Beads - Task Graph Visualization

Task dependency tracking and graph visualization for TODO.md and PLANS.md.

**Key principle**: aidevops markdown files are the source of truth. Beads syncs from them.

Keep plans, material progress and evidence in committed `TODO.md`/`todo/` records.
The ignored Beads database/JSONL is not a forge-loss backup. Preserve and reconcile
Beads-only fields before rebuilding; `sync --force` is not a recovery procedure.
See `reference/forge-portability.md` for adapter coverage, offline proof and
acknowledgement limits. Restored task state does not restore execution authority.

## Architecture

```text
TODO.md / PLANS.md → .beads/beads.db (SQLite + JSONL) → Graph visualization (bd CLI, TUIs)
```

## Task ID Format

```markdown
- [ ] t001 Task description
- [ ] t001.1 Subtask of t001
- [ ] t001.1.1 Sub-subtask
```

## Dependency Syntax

```markdown
- [ ] t002 Implement feature blocked-by:t001
- [ ] t003 Deploy blocks:t004,t005
```

| Syntax | Meaning |
|--------|---------|
| `blocked-by:t001` | This task waits for t001 (no spaces around colon) |
| `blocked-by:t001,t002` | Waits for multiple tasks |
| `blocks:t003` | This task blocks t003 |

## CLI Commands

```bash
bd init                                          # Initialize Beads in project
bd create "Implement login"                      # Create task
bd create "Deploy" --description="Deploy to production"
bd dep add <issue2-id> <issue1-id>               # Make issue2 depend on issue1
bd list                                          # List all tasks
bd list --status open
bd ready                                         # Show tasks with no blockers
bd graph <issue-id>                              # Show dependency graph
bd close <id>                                    # Close task
bd mcp                                           # MCP server (for AI tools)
```

## Sync Commands

```bash
~/.aidevops/agents/scripts/beads-sync-helper.sh push [/path/to/project]  # TODO.md → Beads
~/.aidevops/agents/scripts/beads-sync-helper.sh pull                      # Beads → TODO.md (manual merge required)
~/.aidevops/agents/scripts/beads-sync-helper.sh status                    # Check sync status
~/.aidevops/agents/scripts/beads-sync-helper.sh sync                      # Two-way sync with conflict detection
~/.aidevops/agents/scripts/beads-sync-helper.sh sync --force              # Force sync (TODO.md wins on conflict)
~/.aidevops/agents/scripts/todo-ready.sh                                  # Show unblocked tasks
~/.aidevops/agents/scripts/todo-ready.sh --json                           # JSON output
~/.aidevops/agents/scripts/todo-ready.sh --count                          # Count only
```

**Conflict resolution**: Run `status` first; use `sync --force` to resolve (TODO.md wins). `pull` exports Beads data but does not auto-update TODO.md — manual merge required.

## Viewers

| Tool | Type | Features | Install |
|------|------|----------|---------|
| `bd` | CLI | Core commands, MCP server | `brew install steveyegge/beads/bd` or `go install github.com/steveyegge/beads/cmd/bd@latest` |
| `bv` | TUI | PageRank, critical path, graph analytics | `brew tap dicklesworthstone/tap && brew install dicklesworthstone/tap/bv` |
| `beads-ui` | Web | Live updates, browser-based | `npm install -g beads-ui` (or `npx beads-ui`) |
| `bdui` | TUI | React/Ink interface | `npm install -g bdui` |
| `perles` | TUI | BQL query language | `cargo install perles` |

Repos: [bv](https://github.com/Dicklesworthstone/beads_viewer) · [beads-ui](https://github.com/mantoni/beads-ui) · [bdui](https://github.com/assimelha/bdui) · [perles](https://github.com/zjrosen/perles)

```bash
bv                        # Interactive mode
bv --robot-triage         # Agent mode: triage overview
bv --robot-next           # Agent mode: next task to work on
beads-ui                  # Starts on http://localhost:3000
beads-ui --port 8080
bdui                      # Interactive mode
perles                    # Interactive REPL
perles "SELECT * FROM issues WHERE status = 'open'"
```

## Installation

```bash
./setup.sh                                      # Via aidevops setup (installs bd automatically)
brew install steveyegge/beads/bd                # Manual
go install github.com/steveyegge/beads/cmd/bd@latest
aidevops init beads                             # Init project: creates .beads/, syncs TODO.md/PLANS.md, adds .beads to .gitignore
```

## Integration with Workflows

| Workflow | Status Change | TODO.md Section | Attributes Added |
|----------|--------------|-----------------|-----------------|
| `/branch create` | → In Progress | `## In Progress` | `started:2025-01-15T10:30Z` |
| `/pr create` | → In Review | `## In Review` | `pr:123` |
| `/pr merge` | → Done | `## Done` | `completed:2025-01-16T14:00Z`, `actual:5h` |
| `/release` | → Done (all) | `## Done` | — |

All workflow commands run `beads-sync-helper.sh push` after updating TODO.md.

| Command | Action |
|---------|--------|
| `/ready` | Show tasks with no blockers |
| `/sync-beads` | Sync TODO.md ↔ Beads |
| `/branch` | Create safe linked worktree, move task to In Progress |
| `/pr` | Create PR, move task to In Review |
| `/release` | Release version, move tasks to Done |

**Planning**: Add tasks to TODO.md with `blocked-by:`/`blocks:` → `/sync-beads` → `bd graph` to visualize; `bd ready` or `todo-ready.sh` for unblocked tasks.

## TOON Blocks

TODO.md includes TOON blocks for structured dependency data:

```markdown
<!--TOON:dependencies-->
t002|blocked-by|t001
t003|blocks|t004
<!--/TOON:dependencies-->

<!--TOON:subtasks-->
t001|t001.1,t001.2
t001.1|t001.1.1
<!--/TOON:subtasks-->
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Sync fails (lock file) | `rm .beads/sync.lock` then check `cat .beads/sync.log` |
| Beads not initialized | `bd init` or `rm -rf .beads && bd init` |
| Dependencies not showing | No spaces around colon: `blocked-by:t001,t002`; task IDs must exist |
