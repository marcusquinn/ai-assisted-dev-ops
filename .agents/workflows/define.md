---
description: Decision-complete brief generation — resolve only consequential unknowns before creating a task brief
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Resolve consequential unknowns, then generate a complete brief from `templates/brief-template.md`. Surface assumptions that can change the result without spending user attention on information already supplied or safely inferable.

Topic: $ARGUMENTS

## Workflow

### Step 1: Classify Task Type

| Type | Signal Words | Default Assumptions |
|------|-------------|---------------------|
| **feature** | add, create, build, implement, new | Minimal footprint, no new deps without discussion |
| **bugfix** | fix, broken, wrong, error, crash, regression | Preserve all other behaviour, add regression test |
| **refactor** | clean, restructure, improve, simplify, extract | No behaviour changes, all tests must still pass |
| **docs** | document, readme, guide, explain, describe | Accurate, concise, follows existing doc patterns |
| **research** | investigate, explore, evaluate, compare, spike | Time-boxed, deliverable is a written recommendation |

Also classify **agent domain** and **model tier** using `reference/task-taxonomy.md`. Include domain tag (e.g., `#seo`) in TODO.md entry and as GitHub label. Omit for code tasks.

**Tier (cascade dispatch):** Default to `tier:standard`. Only use `tier:simple` when the brief meets ALL disqualifier checks (see `reference/task-taxonomy.md` "tier:simple Disqualifiers"). The cascade model handles mis-classification, but defaulting too low wastes worker turns on guaranteed failures.

- `tier:simple` — single-file under 500 lines, <100 lines changed, pattern-following. Brief MUST provide verbatim `oldString`/`newString` for every edit. No judgment, no codebase exploration, no error handling to design.
- `tier:standard` — bug fixes, refactors, feature implementation, multi-file or large-file edits. **Use when uncertain** — this is the default tier.
- `tier:thinking` — architecture decisions, novel design, complex multi-system trade-offs, security audits.

If task type is ambiguous, offer numbered options (1–5 matching table) with a recommendation.

### Step 2: Evidence-First, Sufficiency-Driven Interview

Extract the goal, constraints, decisions, and acceptance evidence already present in `$ARGUMENTS`, linked issues, conversation context, and repository discovery. Do not ask the user to repeat known information. Ask one question at a time only when its answer could materially change **scope, architecture, trust/security boundaries, user-visible behaviour, or acceptance criteria**. When an unknown has a safe reversible default, infer it and record the assumption when it helps the implementer.

When a question is necessary, offer 2–4 concrete options with one evidence-backed recommendation. Candidate questions, not a quota:

- **Goal**: "What must this task produce?" — ask only when multiple materially different outcomes remain plausible.
- **Scope boundary**: "What is explicitly not in scope?" — ask when an exclusion changes blast radius or delivery.
- **Success criteria**: "Which observable result proves completion?" — ask when verification or user-visible behaviour is unresolved.
- **Implementation anchor** (t1901): discover likely files and reference patterns with `git ls-files` and exact search. Ask the user only when multiple plausible boundaries require a product or architecture choice. The brief must name concrete paths when knowable; use evidence-backed "not yet knowable" only for `tier:thinking` decisions that genuinely determine the files.

Load `reference/define-probes/${task_type}.md` as a candidate pool, not a mandatory questionnaire.

### Step 3: Targeted Latent-Criteria Probing

Use zero or more probes only for unresolved, consequential unknowns:

| Technique | Pattern | When |
|-----------|---------|------|
| **Domain grounding** | "In [domain], the usual pitfall is X. Does that apply?" | Existing domain practice could change the approach |
| **Pre-mortem** | "Imagine this ships and fails. What went wrong?" | Features, refactors |
| **Backcasting** | "Working backwards from 'done' — what's the last thing you'd verify?" | Features, research |
| **Outside view** | "Similar tasks in this codebase took N approach. Follow or diverge?" | Refactors, features |
| **Negative space** | "What would make a correct solution unacceptable?" | All types |
| **Assumption surfacing** | "I'm assuming X — correct, or should it be Y?" | All types |

Present any necessary probe as a concrete question with options, not an open-ended prompt. Stop probing when the brief is decision-complete; a fixed question count is not evidence of sufficiency.

### Step 4: Sufficiency Gate

For each remaining unknown:

1. If its answer cannot materially change scope, architecture, trust/security boundaries, user-visible behaviour, or acceptance criteria, omit the question and infer a safe default when needed.
2. If it can, first try repository evidence or an explicit safe default.
3. If neither resolves it, ask one targeted question. When the decision belongs to the future `tier:thinking` worker, record the decision to make, evidence to inspect, and acceptance boundary instead of inventing an answer.

Before generating, confirm: "Do I know enough to predict what a review would reject, or have I made the unresolved decisions explicit?" Do not enforce a minimum or maximum question count.

After drafting, run one compact blind-spot pass across assumptions, affected surfaces, trust boundaries, user-visible behaviour, non-goals, and verification. Revise or ask only for a material omission; do not add an empty checklist to the brief.

### Step 5: Generate Brief

**Worker-ready issue body detection (t2417):** If the task has a linked issue (from `$ARGUMENTS` or a prior `/new-task` allocation), check `brief-readiness-helper.sh check <issue-number> <slug>` before generating. If the issue body is already worker-ready (4+ known headings), offer:

1. Skip brief — point to issue as canonical brief (recommended)
2. Stub brief — minimal file linking to issue + session-specific context
3. Full brief anyway

In headless mode, default to option 1 (skip). See `scripts/brief-readiness-helper.sh` for the scoring logic.

Read `templates/brief-template.md` and format using `workflows/brief.md` for the classified tier. Populate from interview answers:

For auto-dispatch, use the single `workflows/brief.md` "Dispatch Readiness Contract (brief schema v2)" checklist and run `verify-brief-helper.sh check-readiness <brief>` before queueing.

| Interview Data | Brief Section |
|---------------|---------------|
| Task type + goal | **What** |
| Why this matters (from evidence or probes) | **Why** |
| Scope + exclusions | **Context & Decisions** (non-goals) |
| Success criteria | **Acceptance Criteria** |
| Decision-relevant domain grounding | **How (Approach)** |
| Material pre-mortem / negative space finding | **Acceptance Criteria** (negative criteria) |
| Files discovered or mentioned | **Relevant Files** |

**Tier-aware implementation context (preserves t1901 mentorship):**

- `tier:simple`: provide every exact file and complete verbatim `oldString`/`newString` or new-file content plus verification. No unresolved choice remains.
- `tier:standard`: provide verified files, reference patterns, resolved boundaries, and implementation-ready skeletons where they reduce invention. Do not pretend unresolved logic is exact.
- `tier:thinking`: keep the brief problem-first — problem, hard/soft constraints, prior art and evidence to inspect, decisions to make, non-goals, and acceptance boundaries. Do not invent speculative file-by-file skeletons before architecture or design decisions are resolved; add scaffolding later if the decision becomes implementation-ready.

### Step 6: Present and Confirm

Show the generated brief in full, then offer:

1. Save brief and create task (`/new-task`) (recommended)
2. Edit brief before saving
3. Save brief only (no TODO.md entry)
4. Start over with different answers

If user chooses 1, delegate to `/new-task` with brief content pre-populated.

## Headless Mode

When `--headless` or `$ARGUMENTS` contains ` -- ` (supervisor dispatch), skip interview:

```text
/define --headless -- Add retry logic to API client with exponential backoff
```

1. Auto-classify task type from description
2. Apply safe defaults only after the same consequence test; record consequential unresolved decisions rather than inventing answers
3. **(t2417) Check worker-readiness** — if linked issue body scores 4+ on the heading heuristic, write a stub brief linking to the issue instead of generating a full brief. Default: skip.
4. Generate brief with `Created by: ai-supervisor` in Origin (only if step 3 did not skip)
5. Write to `todo/tasks/{task_id}-brief.md`
6. Add `#worker` tag to TODO.md entry
7. No confirmation — save immediately

## Related

- `templates/brief-template.md` — Output template
- `reference/define-probes/` — Per-type candidate questions
- `scripts/commands/new-task.md` — Task creation (called after brief generation)
- `workflows/plans.md` — Planning workflow integration
