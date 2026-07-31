---
description: Canonical routing taxonomy — domain labels and workload tier labels for task creation and dispatch
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Taxonomy: Domain and Workload Tier Classification

Canonical source for `/new-task`, `/save-todo`, `/define`, and `/pulse`. When a domain or tier changes, update **only this file** — command docs point here, not duplicate the tables.

## Domain Routing Table

Apply a domain tag only when the task clearly belongs to a specialist agent. Code work stays unlabeled and routes to Build+.

| Domain Signal | TODO Tag | GitHub Label | Agent |
|--------------|----------|--------------|-------|
| SEO audit, keywords, GSC, schema markup, rankings | `#seo` | `seo` | SEO |
| Blog posts, articles, newsletters, video scripts, social copy | `#content` | `content` | Content |
| Email campaigns, FluentCRM, landing pages | `#marketing` | `marketing` | Marketing |
| Invoicing, receipts, financial ops, bookkeeping | `#accounts` | `accounts` | Accounts |
| Compliance, terms of service, privacy policy, GDPR | `#legal` | `legal` | Legal |
| Tech research, competitive analysis, market research, spikes | `#research` | `research` | Research |
| CRM pipeline, proposals, outreach | `#sales` | `sales` | Sales |
| Social media scheduling, posting, engagement | `#social-media` | `social-media` | Social-Media |
| Video generation, editing, animation, prompts | `#video` | `video` | Video |
| Health and wellness content, nutrition | `#health` | `health` | Health |
| Code: features, bug fixes, refactors, CI, tests | *(none)* | *(none)* | Build+ (default) |

**Rule:** Omit the domain tag for code tasks. Build+ is the default.

## Workload Tier Table

Tiers describe the work and route it through centrally configured model chains.
The pulse resolves labels via `model-availability-helper.sh resolve <tier>`; runtime
configuration owns concrete provider/model selection. Label every task so cascade
dispatch can start with the lowest capable tier and escalate with accumulated context.

| Tier | TODO Tag | GitHub Label | Workload contract |
|------|----------|--------------|-------------------|
| simple | `tier:simple` | `tier:simple` | Mechanically complete brief with exact edits; bounded changes following an existing pattern |
| standard | `tier:standard` | `tier:standard` | Implementation-ready work requiring local judgment, recovery, or coordinated changes |
| thinking | `tier:thinking` | `tier:thinking` | Problem/constraint-led work requiring architecture, novel design, or complex trade-offs |

**Rules:**
- Default to `tier:standard` when uncertain. Use `tier:simple` for prescriptive work, `tier:thinking` for deep reasoning.
- **Cascade dispatch:** The pulse may start at `tier:simple` and escalate through `tier:standard` → `tier:thinking` if the worker fails. Each tier's attempt produces a structured escalation report (see `templates/escalation-report-template.md`) that gives the next tier pre-digested context.

## Tier Assignment Validation

The cascade model tolerates initial mis-classification, but obvious mis-tiers waste compute on guaranteed failures. A 6-file task tagged `tier:simple` will fail at every simple-tier attempt before escalating — burning dispatches for no value. Apply these hard rules at task creation time.

### tier:simple Disqualifiers

If **any** of the following are true, the task is **not** `tier:simple`. Use `tier:standard` or higher.

| # | Disqualifier | Rationale |
|---|-------------|-----------|
| 1 | >2 files to modify | Simple-tier work should not require non-trivial multi-file coordination |
| 2 | Code blocks are skeletons, not complete | `tier:simple` requires exact oldString/newString or full file content; if the worker must invent logic, it needs judgment |
| 3 | Conditional logic or branching to design | "if enabled, do X; if gateway fails, fall back to Y" requires reasoning about states |
| 4 | Error handling, retry, or fallback logic | Designing resilience patterns is not copy-paste work |
| 5 | Estimate >1h | Simple tasks are mechanical; longer estimates signal reasoning work |
| 6 | >4 acceptance criteria | Many criteria = many things to coordinate and verify |
| 7 | Keywords in brief: "graceful degradation", "fallback", "retry", "conditional", "coordinate", "design" | These signal judgment, not transcription |
| 8 | Cross-package changes (multiple `packages/` dirs, multiple apps) | Cross-boundary reasoning exceeds simple-tier capability |
| 9 | Target file is large (>500 lines) and brief lacks verbatim `oldString`/`newString` | Worker must navigate and locate the edit target — that is judgment work, not transcription. Large files with only a description of what to change require `tier:standard` to read context and identify the correct location |

### tier:standard vs tier:thinking Signals

| Signal | tier:standard | tier:thinking |
|--------|--------------|----------------|
| Files | 2-8, within one package/module | Many, cross-cutting, or unknown at brief time |
| Pattern | Follow existing patterns with adaptation | No existing pattern; must design from scratch |
| Decisions | Implementation choices (which API, which pattern) | Architectural choices (what abstraction, what trade-offs) |
| Error modes | Known error modes with documented recovery | Novel failure modes requiring analysis |
| Brief detail | Code skeletons with function signatures | Approach description with constraints |
| Reference material | <2,000 lines total across all files | >2,000 lines, or 5+ files to synthesize |

### High-Reference Tasks (GH#18458 — context budget awareness)

Some tasks require reading large volumes of reference material before implementation
can begin. These are systematically prone to worker timeout at `tier:standard`
because reference loading consumes the context budget before implementation.
Indicators:

| Indicator | Example | Mitigation |
|-----------|---------|------------|
| >2,000 lines of reference files | Plan doc (649L) + model file (674L) + target file (3,164L) | Use Worker Quick-Start section, inline critical data |
| 5+ files must be read before first edit | Plan, model test, target, wrapper, CI workflow | Use `tier:thinking` or split into smaller tasks |
| Plan sketches reference function signatures | Plan says `fn(a, b)` but actual is `fn(a, b, c)` | Verify sketches against source before filing task |
| Data must be extracted from large files | "48 function names from Plan section 3.1" | Include the data directly in the brief |

**Decomposition Phase 0 tasks** are a specific high-risk pattern: they require reading the plan document, the model/reference test file, the target source file, and the wrapper/orchestrator file. This routinely exceeds 4,000 lines. Dispatch Phase 0 tasks at `tier:thinking`. Subsequent phases (1-N) are pure mechanical moves and can use `tier:standard`.

### Quick-Check at Creation Time

Before assigning a tier, verify these in order. Stop at the first failure:

1. **Count files in "Files to Modify"** — >2 files disqualifies `tier:simple`
2. **Check code blocks** — skeletons or pseudocode disqualifies `tier:simple`; must be exact, copy-pasteable edits
3. **Scan for judgment keywords** — fallback, retry, graceful, conditional, coordinate, design in the brief disqualifies `tier:simple`
4. **Check estimate** — >1h disqualifies `tier:simple`
5. **Check file size** — if the target file is >500 lines and the brief does not include verbatim `oldString`/`newString`, disqualifies `tier:simple`
6. **Check reference budget** — if the brief's "Research/read" phase totals >2,000 lines, consider `tier:thinking`
7. **When uncertain** — `tier:standard` (the default exists for this reason)

See `templates/brief-template.md` "Tier checklist" for the structured version used during task creation.

### Server-side enforcement (t2389)

Creation-time discipline is primary; `tier-simple-body-shape-helper.sh` is defence-in-depth. The helper runs between `_ensure_issue_body_has_brief` and `_run_predispatch_validator` in `pulse-dispatch-core.sh::dispatch_with_dedup` and inspects any `tier:simple`-labelled issue for four **high-precision** disqualifiers:

| # | Check | Trigger |
|---|-------|---------|
| 1 | File count | `NEW:` / `EDIT:` markers OR file-path bullets under `## Files to modify` / `## How` > 2 |
| 4 | Estimate | `~Nh` / `~Nm` / `~Nd` token resolves to > 60 minutes (1d = 8h) |
| 6 | Acceptance criteria | `- [ ]` / `- [x]` checkboxes inside `## Acceptance` (or `## Acceptance criteria`) > 4 |
| 7 | Judgment keywords | case-insensitive match for `graceful degradation`, `fallback`, `retry logic`, `conditional logic`, `coordinate`, `design a`, `design the`, `architecture`, `trade-off`, `strategy` — excluding signature footer, provenance markers, and the brief's own `## Tier checklist` section |

On hit the helper swaps `tier:simple` → `tier:standard` and posts an idempotent feedback comment (marker: `<!-- tier-simple-auto-downgrade -->`) explaining the disqualifier. **Non-blocking** — dispatch always proceeds, at the corrected tier on hit or at `tier:simple` otherwise. The worker never sees the mis-tier.

The helper enforces only rows 1, 4, 6, 7 from the disqualifier table — rows 2, 3, 5, 8, 9 (skeleton code, conditional logic, error handling, cross-package changes, large-file + no verbatim) require fuzzier heuristics that risk false positives and remain a task-creation-time discipline item.

Bypass (emergency recovery): `AIDEVOPS_SKIP_TIER_VALIDATOR=1`.

Tests: `.agents/scripts/tests/test-tier-simple-body-shape.sh` (18 fixture cases covering every disqualifier + negative cases for the section-scoped exclusions).

## Cascade Dispatch Model

Instead of classifying tasks to the "correct" tier upfront, the cascade model starts cheap and escalates with knowledge:

```text
tier:simple (lowest-cost configured route)
  ✓ Success → done (cheapest resolution)
  ✗ Failure → structured escalation report on issue → re-dispatch at tier:standard

tier:standard (general implementation route)
  ✓ Success → done (saved exploration tokens via escalation context)
  ✗ Failure → richer escalation report → re-dispatch at tier:thinking

tier:thinking (deep-reasoning route)
  ✓ Success → done (had full diagnostic context from both prior attempts)
  ✗ Sol high capability blocker → retry same session once at Sol max
      ✓ Success → done
      ✗ Persistent blocker → human review with complete attempt history
```

Each escalation report captures: what was attempted, where it got stuck, what was unclear in the brief, and what was discovered. The next tier starts with this context instead of exploring from zero. See `templates/escalation-report-template.md` for the structured format.

### Escalation Reason Taxonomy

Structured reasons feed back into brief template optimisation:

| Reason | Meaning | Brief improvement |
|--------|---------|-------------------|
| `AMBIGUOUS_BRIEF` | Multiple valid interpretations | More specific code blocks |
| `STALE_REFERENCES` | File paths/lines don't match current state | Verify file state at dispatch time |
| `JUDGMENT_NEEDED` | Multiple valid approaches, can't choose | Specify pattern to follow |
| `MULTI_FILE_COORDINATION` | Non-obvious cross-file dependencies | Add dependency map to brief |
| `ERROR_RECOVERY` | Hit unexpected error, can't self-recover | Add fallback instructions |
| `TOOL_CHAIN_COMPLEXITY` | Too many sequential tool calls | Pre-compute intermediate state |
| `MISSING_CONTEXT` | Brief lacks background for the decision | Add "Context & Decisions" section |
| `CONTEXT_BUDGET_EXCEEDED` | Too much reference material to read before implementing | Inline critical data in brief, add Worker Quick-Start section, consider tier:thinking |

## Command Use

- `/new-task` — classify after brief creation; apply labels via `gh issue edit`
- `/save-todo` — classify during dispatch tag evaluation
- `/define` — classify during task type detection
- `/pulse` — consume labels for agent routing, workload tier selection, and cascade dispatch

See `scripts/commands/pulse.md` "Agent routing from labels" and "Model tier selection" for dispatch behaviour.
