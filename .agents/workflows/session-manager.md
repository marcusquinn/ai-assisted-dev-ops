---
description: Session lifecycle management and parallel work coordination
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Session Manager

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Detect session completion, suggest new sessions, spawn parallel work
- **Triggers**: PR merge, release, topic shift, context limits
- **Actions**: Continue active work in-session through its linked worktree; suggest @agent-review or spawn only for a completed task, explicit parallel request, topic shift, or context limit. Loop agents (`/preflight-loop`, `/pr-loop`, `/postflight-loop`) detect completion and offer spawning.

<!-- AI-CONTEXT-END -->

## Session Completion Detection

| Signal | Detection | Confidence |
|--------|-----------|------------|
| Tasks complete | `grep -c '^\s*- \[ \]' TODO.md` returns 0 | High |
| PR merged | `gh pr view --json state` returns "MERGED" | High |
| Release published | `gh release view` succeeds for new version | High |
| User gratitude | "thanks", "done", "that's all", "finished" | Medium |
| Topic shift | New unrelated task requested | Medium |

**Trigger prefixes:** PR merge+release: `[x] {PR title} (PR #{number} merged), v{version} released`. Topic shift: `Topic shift: {new topic} differs from {current focus} — new session recommended`. Context window: `Long session with significant context — risk of degradation`.

## Spawning New Sessions

Creating or opening a linked worktree for the active objective does not change
the OpenCode session root and does not require a new chat. Re-run the pre-edit
check against the linked path, then use absolute paths for file tools and set
Bash `workdir` to that worktree. A canonical session root is not a blocker when
the target passes policy. Stop only for a verified permission or ownership
failure; never infer one from the unchanged session root.

### Parallel Worktree + New Session

Use only for an explicit parallel task, unrelated topic, or requested handoff:

```bash
~/.aidevops/agents/scripts/worktree-helper.sh add feature/parallel-task
# Output: ~/Git/<project>-feature-parallel-task/
# macOS: osascript -e 'tell application "Terminal" to do script "cd ~/Git/<project>-feature-parallel-task && opencode"'
# macOS iTerm: osascript -e 'tell application "iTerm" to tell current window to create tab with default profile command "cd ... && opencode"'
# Linux: gnome-terminal --tab -- bash -c "cd ~/Git/<project> && opencode; exec bash"
# Linux: konsole --new-tab -e bash -c "cd ~/Git/<project> && opencode"
# Linux: kitty @ launch --type=tab --cwd=~/Git/<project> opencode
```

### Background / Headless

```bash
opencode run "Continue with task X" --agent Build+ &
opencode serve --port 4097 &  # Persistent server
opencode run --attach http://localhost:4097 "Task description" --agent Build+
```

## Session Handoff

```bash
cat > .session-handoff.md << EOF
# Session Handoff
**Branch**: $(git branch --show-current) | **Last commit**: $(git log -1 --oneline)
## Completed
- {list completed items}
## Continue With
- {next task}
EOF
opencode run "Read .session-handoff.md and continue the work" --agent Build+
```

## When to Suggest @agent-review

After: PR merge (document what worked), release (capture learnings), fixing multiple issues (pattern recognition), user correction (immediate improvement), before unrelated work (clean context boundary), long session (document accumulated learnings).

## Compaction Resilience (Long Autonomous Sessions)

Context compaction in 1h+ sessions can lose task state. Checkpoint to disk after each task.

```bash
session-checkpoint-helper.sh save \
  --task "t135.9" --next "t135.11,t014,t025" \
  --worktree "/path/to/worktree" --batch "batch2-quality" \
  --note "Completed trap cleanup for 29 scripts" \
  --elapsed "90" --target "240"
session-checkpoint-helper.sh load        # Reload before any new task (esp. after compaction)
session-checkpoint-helper.sh status      # Check staleness
session-checkpoint-helper.sh continuation # Generate continuation prompt
session-checkpoint-helper.sh auto-save --task "t135.9" --note "Completed X"
```

**When to checkpoint:** Task completed → `save` with updated --task/--next. PR created/merged → `save` with --note. Batch committed → `save` with --note. Before large operation → `save` as recovery point. After context compaction → `load` to re-orient.

State sources: git (branch, uncommitted changes, commits, worktrees), GitHub (open PRs), supervisor (batch state), TODO.md (in-progress tasks), checkpoint file, memory. The continuation prompt is the highest-impact factor for session continuity — AGENTS.md provides the "how", the continuation prompt provides the "where we are".

## Related

**AGENTS.md is the single source of truth for agent behavior.** This document is supplementary.

- `AGENTS.md` — Root agent instructions (authoritative)
- `workflows/worktree.md` — Parallel branch development
- `workflows/ralph-loop.md` — Iterative development loops
- `tools/build-agent/agent-review.md` — Session review process
- `tools/opencode/opencode.md` — OpenCode CLI reference
