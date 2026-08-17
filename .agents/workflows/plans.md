---
description: Planning workflow with auto-complexity detection
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Plans Workflow

## Quick Reference

- **Commands**: `/save-todo` (auto-detects complexity), `/ready` (show unblocked), `/sync-beads` (sync to Beads)
- **Principle**: Don't make user think about where to save

| File | Purpose |
|------|---------|
| `TODO.md` | All tasks (simple + plan references) with dependencies |
| `todo/PLANS.md` | Complex execution plans with context |
| `todo/tasks/prd-{name}.md` | Product requirement documents |
| `todo/tasks/tasks-{name}.md` | Implementation task lists |
| `.beads/` | Beads database (synced from TODO.md) |

**Task ID Format**: `tNNN` (top-level), `tNNN.N` (subtask), `tNNN.N.N` (sub-subtask)

**Dependency Syntax**: `blocked-by:t001,t002` | `blocks:t003` | 2-space indentation = parent-child

## Auto-Detection Logic

Analyze conversation for complexity signals when `/save-todo` is invoked:

| Signal | Indicates | Action |
|--------|-----------|--------|
| Single action / < 2h / "quick" or "simple" | Simple | TODO.md only |
| Multiple steps / research / >= 2h / multi-session / PRD needed | Complex | PLANS.md + TODO.md |

## Ralph Classification

"Ralph-able" = suitable for autonomous iterative AI loops. **Criteria** (all required): clear success criteria, automated verification, bounded scope, no human judgment needed.

| Signal | Ralph-able? |
|--------|-------------|
| "Make all tests pass" / "Fix linting errors" / "Implement feature X with tests" | Yes |
| "Refactor until clean" | Maybe (needs specific criteria) |
| "Make it look better" / "Design the API" / "Debug production issue" | No |

**Tagging**: `- [ ] t042 Fix all ShellCheck violations #ralph(SHELLCHECK_CLEAN) ~1h` with optional `ralph-promise:`, `ralph-verify:`, `ralph-max:` fields.

**Running**: `/ralph-task t042` or `/ralph-loop "$(grep -E '^- \[ \] t042\s' TODO.md | head -n1)" --completion-promise "SHELLCHECK_CLEAN" --max-iterations 10`

**Quality loop integration**: Preflight (`/preflight-loop`, `PREFLIGHT_PASS`), PR Review (`/pr-loop`, `PR_APPROVED`), Postflight (`/postflight-loop`, `RELEASE_HEALTHY`).

## Auto-Dispatch Tagging

Worker-ready implementation tasks created by interactive agents (user-facing sessions) or workers default to `#auto-dispatch`; readiness is the gate. Add the tag when ALL Include column criteria pass and NO exclusion criteria apply. If readiness is missing, finish the brief/body first or mark the item `#parent`/blocked instead of saving a non-dispatchable implementation issue:

| Include (ALL required) | Exclude (ANY blocks) |
|------------------------|----------------------|
| Clear fix/feature with specific files or patterns | Requires credentials, accounts, or purchases (`needs-credentials` label) |
| Bounded scope (~1h or less) | Is a `#plan`/`#parent` needing decomposition first |
| No design decisions requiring human preference/approval | Requires hardware or external service setup |
| Verification is automatable (tests, ShellCheck, syntax, browser) | Description says "investigate"/"evaluate" without clear deliverable |
| 2+ acceptance criteria beyond generic tests/lint | Has `blocked-by:` dependencies on incomplete tasks |
| | User explicitly prefers interactive/manual handling |

Full canonical dispatch-blocker label set (labels + claim-states + validator-states): `reference/dispatch-blockers.md`.

## Saving Work

### MANDATORY: Task Brief Requirement

Every task MUST have `todo/tasks/{task_id}-brief.md`. Use `~/.aidevops/agents/templates/brief-template.md`. Captures: origin (session ID, date, author), what, why, how (with file refs), acceptance criteria, context. Detect runtime: `$OPENCODE_SESSION_ID`, `$CLAUDE_SESSION_ID`, or `{app}:unknown-{date}`.

**Tier-aware implementation context (t1901):** Preserve the mentorship goal without inventing certainty. `tier:simple` briefs provide complete exact edits or new-file content. `tier:standard` briefs name verified files/reference patterns and add skeletons for resolved boundaries where they reduce worker invention. `tier:thinking` briefs stay problem-first with constraints, prior art/evidence, decisions, non-goals, and acceptance boundaries; add file-level scaffolding only after the design determines it.

### Task Description Quality (GH#6419)

Task descriptions in TODO.md become GitHub issue titles — primary input to pulse duplicate detection. Include **what** (action), **where** (component/file/feature area), **when/why** (triggering condition). Exception: persistent/pinned monitoring issues keep concise titles.

**Good**: `Add WooCommerce tax fallback when no tax class matches product category` | **Bad**: `Tax fallback`

### Save Flow

Extract from conversation: title, description, estimate (`~Xh (ai:Xh test:Xh read:Xm)`), tags, context, session ID.

**Simple** — present: `Saving to TODO.md: "{title}" ~{estimate} | Creating brief: todo/tasks/{task_id}-brief.md | 1. Confirm  2. Add more details  3. Create full plan instead`

1. Create brief at `todo/tasks/{task_id}-brief.md`
2. Add to TODO.md Backlog: `- [ ] t{NNN} {title} #{tag} ~{estimate} logged:{YYYY-MM-DD}`

Format elements (all optional except id and description): `@owner`, `#tag`, `~estimate`, `logged:YYYY-MM-DD`, `blocked-by:t001,t002`, `blocks:t003`.

**Auto-dispatch gate**: Add `#auto-dispatch` for worker-ready implementation tasks once the brief has:

- At least 2 specific acceptance criteria
- A non-empty How section with file references
- A clear What section
- Automatable verification

If any element is missing, complete the brief before saving. Omit `#auto-dispatch` for:

- Blocker labels
- Decomposition or human-decision work
- Credentials, accounts, or purchases
- Hardware or external service setup
- Investigation/evaluation without a clear deliverable
- Incomplete dependencies, including unresolved `blocked-by:` tasks
- Explicit user preference for interactive/manual handling

**Complex** — present: `This looks like complex work. Creating execution plan. Title: {title} | Estimate: ~{estimate} | Phases: {count} | Creating brief: todo/tasks/{task_id}-brief.md | 1. Confirm and create plan + brief  2. Simplify to TODO.md + brief  3. Add more context`

1. Create PLANS.md entry using `templates/plans-template.md`. Required sections: **Status/Estimate**, **Purpose**, **Progress** (timestamped phases), **Context from Discussion**, **Decision Log**, **Surprises & Discoveries**.
2. Add reference to TODO.md: `- [ ] {title} #plan -> [todo/PLANS.md#{slug}] ~{estimate} logged:{YYYY-MM-DD}`
3. Optionally create PRD/tasks if scope warrants (`/create-prd`, `/generate-tasks`)

## Starting Work from Plans

1. **Find**: `grep -i "{keyword}" TODO.md todo/PLANS.md`
2. **Load context**: Read PRD/tasks files if they exist
3. **Present**: `Found: "{title}" (~{estimate}) -- 1. Start working  2. View details  3. Different task`
4. **Follow**: `git-workflow.md` after branch creation

## During Implementation

Update PLANS.md in place: check off Progress items with timestamps, add Decision Log entries (`Decision:`, `Rationale:`, `Date:`), record Surprises & Discoveries (`Observation:`, `Evidence:`, `Impact:`).

## Completing a Plan

1. Ensure all tasks in `todo/tasks/tasks-{slug}.md` are checked
2. Record time at commit (offer: accept session duration, enter different time, or skip)
3. Update PLANS.md status to `Completed` with outcomes and time summary
4. Mark TODO.md reference done: `- [x] {title} #plan -> [todo/PLANS.md#{slug}] ~4h actual:3h15m completed:2025-01-15`
5. Update CHANGELOG.md following `workflows/changelog.md` format

## PRD and Task Generation

**Generate PRD** (`/create-prd`): Ask clarifying questions with numbered options. Create PRD in `todo/tasks/prd-{slug}.md` using `templates/prd-template.md`.

**Generate Tasks** (`/generate-tasks`): Phase 1 — present high-level tasks with estimates, ask "Go". Phase 2 — create in `todo/tasks/tasks-{slug}.md` with numbered hierarchy (`0.0`, `1.0`, `1.1`, etc.) using `templates/tasks-template.md`.

## Time Estimation

Use calibrated tiers from `reference/planning-detail.md` (based on 340 completed tasks). Default `~30m` for most tasks. Estimates >= 2h trigger auto-subtasking.

## Dependencies and Blocking

```markdown
- [ ] t001 Parent task ~4h
  - [ ] t001.1 Subtask ~2h blocked-by:t002
    - [ ] t001.1.1 Sub-subtask ~1h
  - [ ] t001.2 Another subtask ~1h blocks:t003
```

**TOON machine-readable format**: `<!--TOON:dependencies[N]{from_id,to_id,type}: t019.2,t019.1,blocked-by -->`

**`/ready` command**: `~/.aidevops/agents/scripts/todo-ready.sh` — shows tasks with no open blockers and lists blocked tasks with their dependencies.

## Beads Integration

`/sync-beads push` (TODO→Beads) | `/sync-beads pull` (Beads→TODO) | `/sync-beads` (two-way with conflict detection). Script: `beads-sync-helper.sh [push|pull|sync]`. Guarantees: lock file, checksum verification, audit trail in `.beads/sync.log`, command-led only.

**Beads UIs**: `bv` (graph analytics), `npx beads-ui start` (web dashboard), `bdui` (terminal), `perles` (BQL queries), `M-x beads-list` (Emacs).

## Time Tracking Configuration

Configure per-repo in `.aidevops.json`: `{ "time_tracking": "prompt", "features": ["planning", "time-tracking", "beads"] }`. Values: `true` = always prompt | `false` = never | `prompt` = ask once per session. Use `/log-time-spent` to manually log time.

## Distributed Task Claiming (t164/t165)

**TODO.md is the master source of truth** for task ownership. GitHub issues are a public interface — bi-directionally synced but never authoritative over TODO.md.

| Step | What happens |
|------|-------------|
| **Claim** | `git pull` → check `assignee:` → add `assignee:identity started:ISO` → commit+push → sync to GH issue |
| **Check** | `grep "assignee:"` on task line — instant, offline |
| **Unclaim** | Remove `assignee:` + `started:` → commit+push → sync to GH issue |
| **Race protection** | Git push rejection = someone else claimed first. Pull, re-check, abort. |

**Identity**: Set `AIDEVOPS_IDENTITY` env var, or defaults to `$(whoami)@$(hostname -s)`. **Status labels**: `status:available` → `status:claimed` → `status:in-review` → `status:done`

## MANDATORY: Worker TODO.md Restriction

**Workers (headless dispatch runners) must NEVER edit TODO.md directly.** Primary cause of merge conflicts when multiple workers + supervisor push to TODO.md on main simultaneously.

| Actor | May edit TODO.md? | How they report status |
|-------|-------------------|----------------------|
| **Supervisor** (cron pulse) | Yes (via `todo_commit_push()`) | Directly updates TODO.md |
| **Interactive user session** | Yes (via `planning-commit-helper.sh`) | Directly updates TODO.md |
| **Worker** (headless runner) | **NO** | Exit code + log output + mailbox + PR creation |

## MANDATORY: Commit and Push After TODO Changes

After ANY edit to TODO.md, todo/PLANS.md, or todo/tasks/*, commit and push immediately. **Interactive sessions and supervisor only — not workers.**

| Condition | Action |
|-----------|--------|
| TODO.md-only changes | Use `planning-commit-helper.sh "chore: add {description} to backlog"`; it pushes directly when allowed or opens a planning-only PR on protected default branches. |
| Mixed changes (TODO + code/agent files) | Create a worktree (`wt switch -c chore/todo-{slug}`), make changes, commit, push, PR, merge |
| Adding 3+ unrelated items while in a task worktree | Suggest a separate planning-only main commit instead |

**NEVER use `git checkout -b` or `git stash` in the main repo directory.**

**Commit message conventions**: New backlog item: `chore: add t{NNN} {short description} to backlog` | Multiple items: `chore: add t{NNN}-t{NNN} backlog items` | Status update: `chore: update task t{NNN} status` | Plan creation: `chore: add plan for {title}`

## GitHub Issue Sync

- **GitHub issue titles** MUST be prefixed with their TODO.md task ID: `t{NNN}: {title}`
- **TODO.md tasks** MUST reference their GitHub issue: `ref:GH#{NNN}`
- When creating both together: assign t-number → create GitHub issue → add TODO entry with `ref:GH#` → commit and push immediately.

Example: `- [ ] t146 bug: supervisor no_pr retry counter #bugfix ~15m logged:2026-02-07 ref:GH#439`

## Integration with Other Workflows

| Workflow | Integration |
|----------|-------------|
| `git-workflow.md` | Branch names derived from tasks/plans |
| `branch.md` | Task 0.0 creates branch |
| `preflight.md` | Run before marking plan complete |
| `changelog.md` | Update on plan completion |

## Templates

- `templates/prd-template.md` — PRD structure
- `templates/tasks-template.md` — Task list format
- `templates/todo-template.md` — TODO.md for new repos
- `templates/plans-template.md` — PLANS.md for new repos
