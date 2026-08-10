---
description: Terminal tab/window title integration for git context
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

# Terminal Title Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Sync terminal tab titles with git repo/branch via OSC escape sequences
- **Script**: `~/.aidevops/agents/scripts/terminal-title-helper.sh`
- **Auto-sync**: Runs via `pre-edit-check.sh` on task refs in linked worktrees
- **Session sync**: For issue/PR work, OpenCode session titles should begin with `Issue #123:` or `PR #456:` plus a succinct description; branch auto-sync is only the fallback when no issue/PR context exists. Force branch sync via `session-rename_sync_branch`.
- **Session status**: Interactive OpenCode root sessions prefix the terminal-only title with ⚪ from the first submitted user message and retain it across descriptive title updates, 🔴 for `retry`, 🟡 while awaiting permission, and 🟢 for `idle`. Stored OpenCode session titles remain unchanged.

**Commands**:

```bash
terminal-title-helper.sh sync              # Sync tab with current repo/branch
terminal-title-helper.sh rename "My Project"  # Set custom title
terminal-title-helper.sh reset             # Reset to default
terminal-title-helper.sh detect            # Check terminal compatibility
```

**Title Formats** (set via `TERMINAL_TITLE_FORMAT`):

| Format | Example |
|--------|---------|
| `repo/branch` (default) | `aidevops/feature/xyz` |
| `branch` | `feature/xyz` |
| `repo` | `aidevops` |
| `branch/repo` | `feature/xyz (aidevops)` |

**Environment Variables**:

| Variable | Default | Description |
|----------|---------|-------------|
| `TERMINAL_TITLE_FORMAT` | `repo/branch` | Title format |
| `TERMINAL_TITLE_ENABLED` | `true` | Set `false` to disable |
| `AIDEVOPS_TAB_STATUS_ENABLED` | `true` | Set `false` to retain dynamic titles without OpenCode status glyphs |
| `AIDEVOPS_TERMINAL_TITLE_OWNER` | `aidevops` | Managed OpenCode launches use one aidevops OSC writer; set `native` to delegate in-TUI OSC exclusively to OpenCode |
| `OPENCODE_DISABLE_TERMINAL_TITLE` | `1` when aidevops owns titles | Prevent OpenCode from racing the status-decorated title; an explicit value is preserved |

<!-- AI-CONTEXT-END -->

## How It Works

Uses OSC escape sequences (`printf '\033]0;%s\007' "title"`). **Full support**: Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, WezTerm, Hyper, GNOME Terminal, Konsole, VS Code Terminal, xterm. **Partial**: Apple Terminal (basic), tmux/screen (requires config).

The OpenCode plugin consumes the first root-user `message.updated` event plus `session.status`, `permission.asked`, and `permission.replied` events only for the active interactive root session. Subagent and headless-worker events are ignored. Managed launchers disable OpenCode's competing native terminal-title writer, shell helpers yield while OpenCode is active, and native session-rename tools share the plugin controller so status remains applied across title changes.

## Shell Integration

| Shell | Config file | Hook |
|-------|-------------|------|
| Bash | `~/.bashrc` | `PROMPT_COMMAND='terminal-title-helper.sh sync 2>/dev/null'` |
| Zsh | `~/.zshrc` | `precmd() { terminal-title-helper.sh sync 2>/dev/null }` |
| Fish | `~/.config/fish/config.fish` | `function fish_prompt; terminal-title-helper.sh sync 2>/dev/null; end` |

## Troubleshooting

- **Not updating**: Run `terminal-title-helper.sh detect`. Verify git repo (`git rev-parse --is-inside-work-tree`) and `TERMINAL_TITLE_ENABLED != false`.
- **Wrong format**: `echo $TERMINAL_TITLE_FORMAT`
- **tmux** (`~/.tmux.conf`): `set -g set-titles on` + `set -g set-titles-string "#T"`
- **screen** (`~/.screenrc`): `termcapinfo xterm* ti@:te@`
- **VS Code**: Enable "Terminal > Integrated: Allow Workspace Shell"

## Related

- `workflows/git-workflow.md` - Git workflow with branch naming
- `workflows/branch.md` - Branch creation and lifecycle
- `tools/opencode/opencode.md` - OpenCode session management
