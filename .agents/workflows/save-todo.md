---
description: Save current discussion as task or plan (auto-detects complexity)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Analyze the current conversation, compose a worker-ready brief, and save appropriately based on complexity and execution intent.

Topic/context: $ARGUMENTS

## Core Rule

All TODOs, plans, and issues created by this workflow MUST use `workflows/brief.md` and `~/.aidevops/agents/templates/brief-template.md` so future workers can execute without the original chat. For auto-dispatch, use only the shared "Dispatch Readiness Contract (brief schema v2)" checklist and its `verify-brief-helper.sh check-readiness <brief>` gate. Saving is explicit later intent: keep the work as a local TODO/plan and do not ask whether to dispatch it. If an implementation issue is created, that creation authorizes implementation, so add `auto-dispatch` when readiness passes. If the user says `/full-loop`, "work on it now", or equivalent, route to `/full-loop` instead of stopping after capture.

## Intent Routing

An issue-started interactive implementation context overrides generic
"background" wording: continue implementation locally and interpret background
only as local asynchronous execution. Never create or dispatch a worker for that
issue from the active interactive implementation session.

| Signal | Action |
|--------|--------|
| `/full-loop`, "work on this now", "fix/implement/do this in this session" | Start `/full-loop $ARGUMENTS`; do not ask whether to begin |
| "background", "worker", "auto-dispatch" | Create a briefed TODO/issue and add `#auto-dispatch` when readiness passes |
| "save", "log", "for later", `/save-todo`, `/aidevops-save-todo` | Save a local briefed TODO/plan; do not create an implementation issue or ask about dispatch |
| "create/file/open an issue", or a fixable out-of-scope finding | Create a worker-ready implementation issue with `#auto-dispatch`; do not seek separate dispatch approval |
| Ambiguous "we need to", "should add", "can you note" | Infer the safest productive route; ask only when human input is materially irreplaceable |

Never offer "create an issue" and "create an issue and auto-dispatch" as
separate choices. Decide whether an issue should exist before publishing it;
once created, automatic implementation is the default.

## Auto-Detection

| Signal | Indicates | Action |
|--------|-----------|--------|
| Single action item / <2h / "quick" | Simple | TODO.md only |
| Multiple steps / >2h / multi-session | Complex | PLANS.md + TODO.md |
| PRD mentioned or needed | Complex | PLANS.md + TODO.md + PRD |

## Step 1: Extract from Conversation

- **Title**: Concise task/plan name
- **Estimate**: `~Xh (ai:Xh test:Xh read:Xm)`
- **Tags**: #feature, #bugfix, #enhancement, #docs, etc.
- **Context**: Decisions, findings, constraints, open questions, links
- **Brief**: Create `todo/tasks/{task_id}-brief.md` from `~/.aidevops/agents/templates/brief-template.md` using `workflows/brief.md` pre-composition checks.

## Step 1b: Dispatch Tags (MANDATORY)

**`#auto-dispatch`** — For background intent or a published implementation issue, add when ALL true: clear description with specific files/patterns, ≤2h scope, no credentials/purchases needed, no user-preference design decisions, automatable verification. **Default published implementation issues to `#auto-dispatch`** — omit only when a specific exclusion applies. Explicit save/later intent remains a local TODO/plan without this tag. Full criteria: `workflows/plans.md` "Auto-Dispatch Tagging". Canonical blocker labels: `reference/dispatch-blockers.md`.

**`#plan`** — Add when decomposition needed before implementation (multi-phase, >2h, research/design).

**Model tier / agent domain tags** — classify via `reference/task-taxonomy.md`. Omit for standard code tasks.

## Step 2: Save

**Simple** → create `todo/tasks/{task_id}-brief.md`, add to TODO.md Backlog, and report:

```markdown
- [ ] t{NNN} {title} #{tag} ~{estimate} logged:{YYYY-MM-DD}
```

**Complex** → create the plan without a routine confirmation, then:

1. Create entry in `todo/PLANS.md`:

```markdown
### [{YYYY-MM-DD}] {Title}

**Status:** Planning
**Estimate:** ~{estimate}
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md) (if needed)
**Tasks:** [todo/tasks/tasks-{slug}.md](tasks/tasks-{slug}.md) (if needed)

#### Purpose

{Why this work matters}

#### Progress

- [ ] ({timestamp}) Phase 1: {description} ~{est}
- [ ] ({timestamp}) Phase 2: {description} ~{est}

#### Context from Discussion

{Key decisions, research findings, constraints, open questions}

#### Decision Log

(To be populated during implementation)

#### Surprises & Discoveries

(To be populated during implementation)
```

2. Create `todo/tasks/{task_id}-brief.md` with implementation context or a plan handoff.
3. Add reference to TODO.md Backlog:

```markdown
- [ ] {title} #plan → [todo/PLANS.md#{slug}] ~{estimate} logged:{YYYY-MM-DD}
```

4. Optionally create PRD/tasks files if scope warrants.

## Completion Message

When available context is sufficient, save directly instead of asking for a
routine confirmation. Ask one specific question only when irreplaceable context
or a consequential choice is missing. After saving, report the durable state
without reopening the dispatch decision:

```text
Saved as {task_id}: "{title}" with brief {brief_path}.
```

If the task was created with explicit background/worker intent or as a GitHub
implementation issue and dispatch readiness passes, report the queued/dispatch
action instead of asking.

## Example

```text
User: /save-todo We discussed the authentication overhaul with OAuth, session management, and migration
AI:   Saved as t123: "Authentication Overhaul" with brief todo/tasks/t123-brief.md
      - Plan: todo/PLANS.md
      - Reference: TODO.md
      - PRD: todo/tasks/prd-auth-overhaul.md
```
