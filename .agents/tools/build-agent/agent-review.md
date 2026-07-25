---
description: Systematic review and improvement of agent instructions
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agent Review

<!-- AI-CONTEXT-START -->

**Trigger**: Creating or reviewing an instruction surface, user correction, observable failure, session-end learning, or periodic maintenance.
**Owns**: Semantic review of agents, prompts, workflow instructions, command bodies, and their generated/runtime adapters.
**Excludes**: Source-code simplification belongs to `tools/code-review/code-simplifier.md`; behavioural validation belongs to `agent-testing.md`; automated optimisers may propose candidates but must satisfy this rubric before changing instruction semantics.
**Self-Assessment**: Observe failure → complete task → cite evidence → search for `"pattern"` under `.agents/` with Grep → review the assembled context stack → propose the smallest evidenced fix.
**Exact Search**: Use the Grep tool for content searches; when Bash is available, `rg "pattern" <path>` is an optional equivalent.
**Write Restrictions (MANDATORY)**: Interactive sessions use a linked worktree for every edit, including planning files. Headless bookkeeping and explicitly planning-only workers may use only the narrow `main`/`master` exception enforced by `pre-edit-check.sh`; all other headless edits require a linked worktree. Follow `workflows/pre-edit.md` rather than copying its path allowlist here.

<!-- AI-CONTEXT-END -->

## Canonical Review Flow

1. **Assemble the delivered context.** Identify the canonical source, always-loaded instructions, triggered references, generated command wrappers, runtime overlays, and adjacent agents that can reach the target task. Generated/runtime wrappers are adapters; their prose must not override or fork the canonical guide.
2. **Define activation and exclusion boundaries.** State the signal that loads or invokes the instruction, the decision point by which it must arrive, what adjacent agent or workflow owns nearby work, and what this surface must not do. Ambiguous overlap is a routing defect even when each file is individually reasonable.
3. **Classify retained context.** Give each directive one primary role before deciding its placement:
   - **Invariant** — must be known before relevance or risk is established; keep the actionable rule inline.
   - **Judgment rule** — requires model comparison, prioritisation, or trade-offs; keep at the owning decision point.
   - **Interface** — exact schema, command, template, `oldString`/`newString`, or hand-off contract; preserve executable shape.
   - **Triggered pointer** — concise rule plus trigger and exact path to detail loaded before its decision point.
   - **Rationale** — failure history or explanation needed for maintenance; retain with traceable provenance, usually in a reference.
   - **Deterministic enforcement candidate** — syntax or policy mechanics suitable for a hook, validator, wrapper, or CI gate; keep the invariant until enforcement and delivery are verified.
4. **Recover provenance and scan for conflicts.** Search task IDs, issue/PR context, recent file history, related surfaces, and current enforcement. Compare the assembled stack for contradictory requirements, stale paths or capabilities, shadowed canonical rules, and provider/model names used as abstract workload tiers. Record each conflict and resolution; do not silently rely on prompt order.
5. **Choose the smallest safe treatment.** Keep, tighten, relocate, enforce, or remove. Incomplete provenance, delivery, or behavioural evidence defaults to preservation. Counts and line length identify review pressure, not a desired semantic result.
6. **Verify the delivered behaviour.** Test the canonical source and every generated/runtime route affected. Use deterministic contract tests for structure and Agent Testing or comprehension scenarios for judgment. A smaller file or unchanged aggregate score is not proof that a protected lesson still reaches its decision point.

## Review Checklist

| # | Check | Action if failing |
|---|-------|-------------------|
| 1 | **Activation/exclusion boundaries** | Name the trigger, delivery point, owner, adjacent owner, and excluded behaviour |
| 2 | **Assembled context stack** | Inspect canonical, always-loaded, triggered, generated, and runtime-delivered forms together |
| 3 | **Directive classification** | Classify each retained rule before changing placement or wording |
| 4 | **Instruction count** (~50-100 per agent; maintainability heuristic) | Investigate load; counts are heuristics, never standalone removal evidence |
| 5 | **Universal applicability** (>80% tasks) | Investigate whether a reliable task-specific trigger supports extraction |
| 6 | **Duplicate detection** (Grep for `"pattern"` under `.agents/`) | Classify exact duplicates vs boundary reinforcement or variants |
| 7 | **Code examples** (authoritative/working) | Keep only when authoritative; otherwise use Grep references for `"pattern"` under `.agents/scripts/` or stable section headings |
| 8 | **AI-CONTEXT block** (standalone essentials) | Rewrite if an AI would get stuck with only this |
| 9 | **Slash commands** | Keep as thin adapters under `scripts/commands/` or the owning domain subagent |
| 10 | **Target-specific verification** | Test canonical semantics plus every changed delivery route |

Before consolidating, relocating, or removing a directive, recover the protected failure/rationale from nearby task IDs, issue/PR context, and recent file history. Record its current enforcement or routing, and distinguish exact duplication from reinforcement at another decision boundary, runtime-specific variants, and similar-but-different hazards. Relocation must name the reliable trigger that delivers the lesson at its decision point. Removal requires evidence that the knowledge is obsolete or fully superseded and identifies any mechanism that preserves or enforces it.

## Improvement Proposal Format

```markdown
## Agent Improvement Proposal
**File**: `.agents/[path]/[file].md`
**Issue**: [Description]
**Evidence**: [Failure, contradiction, or feedback]
**Provenance**: [Protected failure/rationale and recent history inspected]
**Related Files**: `.agents/[other-file].md` (checked for duplicates)
**Context Stack**: [Canonical source, wrappers/overlays, triggered references inspected]
**Classification**: [Invariant, judgment rule, interface, triggered pointer, rationale, or deterministic enforcement candidate]
**Activation/Exclusion**: [Trigger and decision point; adjacent owner and behaviour excluded here]
**Proposed Change**: [Specific before/after]
**Boundary Analysis**: [Exact duplicate, reinforcement, runtime variant, or similar-but-different hazard]
**Delivery/Preservation**: [Reliable relocation trigger or superseding enforcement mechanism]
**Verification**: [How retained behaviour and routing were tested]
**Impact**: [ ] No conflicts [ ] Instruction count (diagnostic): [+/- N] [ ] Tested
```

## Review Categories

When flagging code issues, use the structured categories in `tools/code-review/review-categories.md` for consistent severity assignment. Categories include: `commit-message-mismatch`, `instruction-file-disobeyed`, `fails-silently`, `security-violation`, `logic-error`, `runtime-error-risk`, and 8 others — each with examples, exceptions, and CRITICAL/MAJOR/MINOR/NITPICK severity guidance.

## Contributing

Create proposal → edit in a linked worktree → run target-specific tests and `.agents/scripts/linters-local.sh --changed` → commit/PR. Ref: `workflows/git-workflow.md`.
