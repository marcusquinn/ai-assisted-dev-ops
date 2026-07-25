---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# {task_id}: {Title}

## Pre-flight (auto-populated by briefing workflow)

<!-- MANDATORY (t2409): The briefing workflow populates these checkboxes during
     composition. verify-brief.sh rejects briefs with unchecked Pre-flight boxes.
     Each checkbox records that a specific pre-composition check was performed
     and what it found. This is the audit trail that prevents reality-blind,
     collision-blind, and phantom-ref briefs from reaching workers. -->

- [ ] Memory recall: `<query>` → `<N>` hits — `<one-line skim summary or "no relevant lessons">`
- [ ] Discovery pass: `<N>` commits / `<N>` merged PRs / `<N>` open PRs touch target files in last 48h
- [ ] File refs verified: `<N>` refs checked, all present at HEAD
- [ ] Tier: `<tier>` — disqualifier check clean (`<1-line rationale>`)
- [ ] Seeded draft PR decision recorded: `<created draft PR #N | skipped — rationale>`

## Origin

- **Created:** {YYYY-MM-DD}
- **Session:** {app}:{session-id}
- **Created by:** {author} (human | ai-supervisor | ai-interactive)
- **Parent task:** {parent_id} (if subtask)
- **Blocked by:** {GitHub issue relationship(s) + optional `blocked-by:tNNN/#NNN` marker; if unresolved, keep `status:blocked` and omit `#auto-dispatch`}
- **Conversation context:** {1-2 sentence summary of what was discussed that led to this task}

## What

{Clear description of the deliverable. Not "implement X" but what the implementation must produce, what it must do, and what the user/system will experience when it's done.}

## Why

{Problem being solved, user need, business value, or dependency chain that requires this. Why now? What breaks or stalls without it?}

## Tier

<!-- Recommended model tier. Determines cascade dispatch starting point.
     See reference/task-taxonomy.md for full criteria, disqualifiers, and cascade model.
     The checklist below is MANDATORY — it prevents mis-tagging that wastes
     compute on guaranteed-to-fail dispatches (see t1921). -->

### Tier checklist (verify before assigning)

Answer each question for `tier:simple`. If **any** answer is "no", use `tier:standard` or higher.

- [ ] **2 or fewer files to modify?** (count the Files to Modify section below)
- [ ] **Every target file under 500 lines?** (large files require codebase navigation — that is judgment work, not transcription)
- [ ] **Exact `oldString`/`newString` for every edit?** (not skeletons, not descriptions of changes — literal copy-pasteable replacement blocks)
- [ ] **No judgment or design decisions?** (no "choose between", "design", "coordinate", "compatible with")
- [ ] **No error handling or fallback logic to design?** (no "graceful", "retry", "fallback")
- [ ] **No cross-package or cross-module changes?** (no `packages/a/` + `packages/b/`, no changes spanning unrelated subsystems)
- [ ] **Estimate 1h or less?**
- [ ] **4 or fewer acceptance criteria?**
- [ ] **Dispatch-path classification (t2821/t2920):** Does the `### Files Scope` or `## How` section reference a file in `.agents/configs/self-hosting-files.conf`? If yes, keep the normal `#auto-dispatch` default and use `tier:thinking`; runtime routing chooses the model and reasoning level. Opt out only with `#no-auto-dispatch #interactive` when intentionally implementing interactively. See `.agents/reference/task-taxonomy.md` and `.agents/reference/auto-dispatch.md`.

All checked = `tier:simple`. Any unchecked = `tier:standard` (default) or `tier:thinking` (no existing pattern to follow).

**Selected tier:** `tier:simple` | `tier:standard` | `tier:thinking`

**Tier rationale:** {1-2 sentences justifying the tier choice, referencing which checklist items
drove the decision. e.g., "6 files across 3 packages, fallback retry logic needed -> tier:standard"
or "Single-file config edit with exact code block provided -> tier:simple"}

## PR Conventions

<!-- PR KEYWORD RULE (t2046 — MANDATORY for parent-task issues):

     **Parent-task PRs.** When a PR delivers ANY work for an issue tagged `parent-task`
     — including the initial plan-filing PR — the PR body MUST use `For #NNN` or
     `Ref #NNN`, NEVER `Closes`/`Resolves`/`Fixes`. The parent issue must stay open
     until ALL phase children merge. The final phase PR uses `Closes #NNN` to close
     the parent. `full-loop-helper.sh commit-and-pr` enforces this in --strict mode
     (aborts if the PR body uses a closing keyword on a parent-task issue).
     CI also checks via `.github/workflows/parent-task-keyword-check.yml`.

     If you wrote `Resolves` and the parent auto-closed, reopen it manually with
     a comment explaining the convention.

     Leaf (non-parent) issue PRs: use `Resolves #NNN` or `Closes #NNN` as normal.

     MARKDOWN DOES NOT SHIELD KEYWORDS (t2204). pulse-merge's extraction regex
     is a plain grep on the raw PR body — backticks, code fences, blockquotes,
     HTML comments, and link text all let the keyword through. Writing
     `Closes #NNN` in backticks as reference text ("the fix PR will use
     `Closes #NNN`") still auto-closes the issue on merge. Rephrase to avoid
     the literal keyword+hash+number sequence: "will use a closing keyword",
     "will resolve with a Closes-hash-NNN", or split the `#` from the number.
     Canonical foot-gun: t2190 session PR #19680. -->

<!-- TODO(t2219): delete this comment block once t2219 (GH#19719) merges.

     **Planning PR title-collision warning (active until t2219 ships).**

     If this task spawns a PR that (a) references future-work issues via
     `For #NNN` or `Ref #NNN` (not `Closes/Fixes/Resolves`) AND (b) has a
     title starting with a `tNNN:` that matches any of those referenced
     issues' title prefixes, the `issue-sync.yml::sync-on-pr-merge`
     title-fallback at lines 412-414 will apply `status:done` to the
     matching issue on merge — a false positive. The t2137 carve-out
     only protects `parent-task` issues; normal `tier:standard`/`simple`
     issues are vulnerable.

     Reproductions: PR #19701 (title `t2206:`) falsely closed #19692
     (title `t2206:`); PR #19724 (title `t2218:`) falsely closed #19718
     (title `t2218:`).

     **Workaround:** after merging such a PR, run
     `interactive-session-helper.sh post-merge <PR>` (t2225) which heals
     this automatically. If t2225 has not landed yet, manually:
     `gh issue edit <N> --repo <slug> --remove-label status:done --add-label status:available`. -->

{If this task is for a `parent-task`-labeled issue, confirm: PR body will use `For #NNN`, not `Resolves`.}
{If leaf task: use `Resolves #NNN` as normal — delete this section or leave it blank.}

## Seeded Draft PR

<!-- Optional seeded draft PR record, governed by workflows/brief.md "Seeded Draft PR Decision".
     Use only when current-session discovery produced high-confidence implementation
     context and the seed will reduce duplicate exploration without anchoring the
     next worker to stale or unverified assumptions. Draft means not merge-ready. -->

- **Decision:** Created draft PR `{#N}` | Skipped
- **Rationale:** {Why this is safe and useful, or why issue-only is better}
- **Status:** `draft` | `blocked` | `unverified` | `not-created`
- **Freshness evidence:** {memory/discovery/file verification performed against current HEAD}
- **Verification run:** {commands and results, or `UNVERIFIED — not run`}
- **Stale-assumption warning:** {What changed code, failed checks, or design uncertainty would make the seed wrong}

## Phases

<!-- markdownlint-disable MD046 -->
<!-- For `parent-task`-labeled issues only. Delete this section for leaf tasks.

     The sequential phase auto-file mechanism (t2740) is ON by default since t2787.
     It reads phase declarations from the parent-task issue body and auto-files the
     next phase as a child issue once the prior phase's PR merges.

     Override to disable: AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=0

     **List format (preferred — auto-fire works out of the box):**

     - Phase 1 - description [auto-fire:on-prior-merge]
     - Phase 2 - description [auto-fire:on-prior-merge]
     - Phase 3 - description

     **Narrative bold-heading format (for prose-style decomposition plans):**

     **Phase 1 — description [auto-fire:on-prior-merge]**
     Detailed implementation notes...

     **Phase 2 — description**
     Detailed implementation notes...

     Available markers:
     - `[auto-fire:on-prior-merge]` — file this phase when the prior phase PR merges (recommended)
     - `[auto-fire:on]` — file immediately (no wait for prior merge)
     - No marker — not auto-filed unless `<!-- phase-auto-fire:on -->` appears in the issue body

     The close guard (t2755 Phase 2) prevents premature parent closure while any declared
     phase is still unfiled or open.

     **Filing children manually outside auto-fire (t2838):** if you create a child
     issue with `claim-task-id.sh` directly (not through auto-fire), pass
     `--parent-issue N` to inject a `Parent: #N` body line AND populate GitHub's
     sub-issue relationship field. This is the canonical decomposition pattern —
     without it, children appear in the parent body but the GitHub UI does not
     show them as sub-issues. The pulse also runs a periodic backfill
     (`AIDEVOPS_PARENT_BACKFILL_INTERVAL_SECS`, default 3600s) so any
      missed links are reconciled within an hour. -->
<!-- markdownlint-enable MD046 -->

{Delete this section for leaf tasks. For parent tasks, list phases here.}

<!-- HEADING LOCK (t2063): the `## How` heading below must remain exactly
     "## How" (optionally with " (Approach)" suffix). The subsection headings
     MUST include "### Files to Modify", "### Complete Write Surface",
     "### Implementation Steps", "### Hazards and Compatibility", and
     "### Verification Before Dispatch". The issue-sync-lib.sh `_compose_issue_worker_guidance`
     helper extracts these sections and promotes them to a top-level
     "Worker Guidance" block in the issue body so workers see actionable
     context without hunting for the brief. The matcher is case-insensitive
     as of t2063, but stick to the canonical casing for consistency. -->

## How (Approach)

<!-- Worker-ready implementation context (t1900): every section below is required
     for auto-dispatch issues. Vague "How" sections waste worker tokens on exploration.
     If files/patterns cannot be determined, state that explicitly.

     TIER-AWARE DETAIL LEVEL:
     - tier:simple: Code blocks must be COMPLETE — exact oldString/newString for edits,
       full file content for new files. No unresolved choice remains.
     - tier:standard: Verified files/reference patterns and skeletons for resolved
       boundaries. Do not fabricate precision for decisions the worker must make.
     - tier:thinking: Problem, hard/soft constraints, prior art/evidence, decisions,
       non-goals, and acceptance boundaries. No speculative file-by-file skeletons.

     INLINE DATA RULE (GH#18458 — worker token budget protection):
     When a brief references data from a large file (plan doc, source file, config),
     include the data INLINE rather than saying "see Plan section X" or "see file Y".
     Workers that must read 500+ line files just to extract a 50-line data list burn
     tokens on reading before implementing. Examples:
       BAD:  "Use the 48 function names from Plan section 3.1"
       GOOD: List all 48 function names directly in the brief
       BAD:  "Model on test-pulse-wrapper-characterization.sh"
       GOOD: "Model on test-pulse-wrapper-characterization.sh — key structure:
              setup_sandbox(), EXPECTED_FUNCTIONS array, declare -F loop, print_result
              helper, main() calling all test_* functions"

      PLAN-SKETCH VERIFICATION (GH#18458):
      When code sketches from a plan document are included in a brief, verify every
      function call against the actual source file signatures BEFORE filing the child
      task. Plan sketches are written during planning (before implementation); function
      signatures may have been updated since. A wrong signature in a brief causes the
      worker to write broken code and burn tokens debugging.

      THIRD-PARTY API/ERROR MAPPING COMPATIBILITY (GH#24812):
      If the task changes mappings, translations, or tests for third-party API or error
      codes, require the worker to verify the installed dependency version plus local
      exported symbols/source from the package manifest, lockfile, and installed package
      before implementing upstream-reported values. If the local version does not expose
      the upstream value, add a compatibility regression test or an explicit upgrade task
      instead of adding unavailable mappings.

      ALWAYS-LOADED PROMPT BUDGET RULE (Phase 8 of #22616):
      If this task edits AGENTS.md, .agents/AGENTS.md, prompts/build.txt, or another
      always-loaded instruction surface, require progressive disclosure by default:
      keep the startup file to a short rule/pointer, move long rationale/examples to
      a reference or workflow doc, and verify `.agents/AGENTS.md` stays under the
      agents-md-size-check CI ratchet unless the PR explicitly justifies a baseline
      bump.

      UI/UX CONTEXT PROMPT:
      For layout, styling, component, or UX tasks, add compact design context where
      it helps the worker choose the right pattern: repo `DESIGN.md` status/path;
      relevant rule or canonical example; similar-but-different alternatives that
      were considered and why they do/do not apply; and responsive/accessibility
      evidence expected. Reference `.agents/tools/design/design-md.md` and
      `.agents/workflows/ui-verification.md` instead of expanding a mandatory design essay. -->

### Progressive Context Plan

<!-- REQUIRED when the brief cites 3+ workflow/reference/command docs OR the
     Research/read estimate exceeds ~2,000 lines. Keep this section inside
     `## How` so issue-sync promotes it into `## Worker Guidance` for headless
     workers. Purpose: tell the worker what to load, when, why, and when to stop
     instead of expanding always-loaded AGENTS.md guidance. Delete for simple
     tasks where Implementation Steps are enough. -->

- **Read first:** `{path:line-range or section}` — {decision this unlocks}
- **Load only if:** `{path or doc}` — {trigger condition; e.g., conflict, CI failure, shell complexity gate}
- **Why:** {the implementation choice or safety constraint this context informs}
- **Stop when:** {evidence gathered; e.g., target function, reference pattern, constraints, and verification command are clear}
- **For UI/UX tasks:** {DESIGN.md path/status, rule/example to follow, close alternatives to avoid, and responsive/accessibility evidence needed}

### Worker Quick-Start

<!-- OPTIONAL but RECOMMENDED for tasks with 3+ reference files or >2,000 lines of
     total reference material. Gives the worker the 5-10 most critical commands/facts
     to start implementing immediately, without reading all reference files first.
     Workers dispatched at tier:standard have limited context budgets —
     front-loading the critical data here prevents token exhaustion during reading.
     Omit for simple tasks where Implementation Steps are sufficient. -->

{Delete this section if the task is straightforward. For complex tasks:}

```bash
# 1. Extract key data (e.g., function names from a large file):
{grep/awk command that extracts the critical data the worker needs}

# 2. Key structural pattern to follow:
{1-3 line description of the reference file's structure, not "read the whole file"}

# 3. Critical gotchas (verified signatures, known quirks):
{e.g., "_persist_role_cache takes 3 args (runner_user, repo_slug, role), not 2"}
```

### Files to Modify

<!-- Prefix NEW: for new files, EDIT: for existing. Include line ranges where relevant. -->

- `NEW: path/to/new-file.ts` — {purpose, model on `path/to/reference-file.ts`}
- `EDIT: path/to/existing.ts:45-60` — {what to change and why}

### Complete Write Surface

<!-- Search every category before dispatch. Each line must name concrete paths
     or give evidence for N/A/not-yet-knowable. "N/A" alone is not sufficient.
     Documentation-only and new-file-only tasks may use evidence-backed N/A. -->

- **Callers/readers:** {paths and reference flow, or evidence-backed N/A}
- **Writers/mutation paths:** {every known write path, or evidence-backed N/A}
- **Tests/fixtures:** {tests, fixtures, and mocks that encode the behavior}
- **Schemas/config:** {schema, config, serialization, or evidence-backed N/A}
- **Generated/deployed mirrors:** {generated output, deployed copy, or evidence-backed N/A}
- **Migrations/backfills:** {ordering and backfill paths, or evidence-backed N/A}
- **Cleanup/rollback paths:** {cleanup, rollback, and deletion paths, or evidence-backed N/A}

### Implementation Steps

<!-- Match detail to the selected tier. tier:simple gets complete oldString/newString
     blocks or full new-file content. tier:standard gets verified reference patterns
     and skeletons where resolved structure reduces invention. tier:thinking gets
     evidence-gathering and decision steps; add code only after the relevant design
     choice is resolved. -->

1. {Tier-appropriate exact edit, resolved implementation step, or evidence/decision step}

<!-- Include a fenced code block below only for complete tier:simple edits or a
     tier:standard skeleton whose boundary is resolved. Delete it for unresolved
     tier:thinking decisions. -->
```{language}
{Code skeleton for new file — or exact diff block for edits.
 Include imports, function signatures, inline comments for logic.
 The worker copies this and fills in implementation details.}
```

2. {Next step with code skeleton if applicable}
3. {Final step — e.g., "Run `shellcheck` on new file, verify hook fires with test harness"}

### Hazards and Compatibility

<!-- Assess every category. Record the preserved behavior and evidence when a
     hazard is not applicable; do not use a bare N/A. -->

- **Concurrency/atomicity:** {races, locking, transactions, or evidence-backed N/A}
- **Migration/rollback:** {ordering, rollback, and partial migration behavior}
- **Mixed-version/backward compatibility:** {old/new producer-consumer behavior}
- **Idempotency/retry:** {safe replay, duplicate work, and retry behavior}
- **Partial failure/recovery:** {interrupted writes, cleanup, and resume behavior}

### Complexity Impact

<!-- MANDATORY for tasks that modify existing functions in shell scripts.
     Delete this section only when the task creates new files or new functions
     exclusively — no edits to existing function bodies.

     Purpose: flag upfront when adding code to an existing function is likely to
     trip the function-complexity, nesting-depth, or file-size regression gates.
     When projected growth pushes a function past ~80% of the threshold, plan an
     extract-helpers refactor BEFORE writing the new logic.

     Canonical failure class (t2803): 8 workers on GH#20702 all hit the Complexity
     Analysis wall on `_parse_phases_section` because the brief said "add an elif
     branch" without mentioning the 100-line function-complexity gate or the
     extract-helpers precedent (GH#20496 / PR #20503). Every worker copied the same
     shape and got the same red build. See `reference/large-file-split.md §0`.

     Gate thresholds (complexity-regression-helper.sh):
     - function-complexity: 100 lines — flag when current + growth > 80 lines
     - nesting-depth: 4 levels — flag when adding deeply nested if/case/while blocks
     - file-size: 1500 lines (shell) — flag when file is approaching the limit

     Decision rule:
     - Projected post-change < 80 lines → no action, delete section.
     - Projected post-change 80-100 lines → add a warning; note in steps to watch growth.
     - Projected post-change > 100 lines →
       MANDATORY: plan extract-helpers refactor first (prevents dispatch failures). List helpers below.
       Model on `reference/large-file-split.md` §2, GH#20496 / PR #20503. -->

- **Target function:** `{function_name}` in `{file}`
- **Current line count:** {N} lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +{N} lines
- **Projected post-change:** {N} lines ({N}% of threshold)
- **Action required:** {None — delete this section | Watch — monitor during review | Extract helpers first}

{If "Extract helpers first": list the helpers to extract with approximate line counts.
Worker MUST extract before adding new logic. Example:
`_parse_phase_markers()` (~25 lines), `_validate_phase_entry()` (~15 lines) extracted
from `_parse_phases_section` — then add new logic to the slimmed parent function.}

### Verification Before Dispatch

<!-- CI gate policy: prefer fast required develop gates (format, lint,
     typecheck, unit tests). Mark E2E/visual/performance checks as advisory
     unless this task targets staging/release promotion or directly changes a
     critical tested path. Advisory failures should become follow-up issues with
     evidence, not hidden blockers. See `.agents/reference/ci-gate-policy.md`.

      Generated-type lint trap: when changed files depend on generated Content
      Collections or route/content types, include the CI changed-file lint path
      when available: `node .github/scripts/lint-changed-files.mjs --base-ref <base>`.
      Prefer runtime validation, local schemas, or typed wrappers that lint before
      generation; avoid unused blanket eslint disables.

      UI/UX verification prompt: for layout-affecting changes, require evidence at
      mobile/tablet/desktop widths when practical, name accessibility checks, and
      state whether repo DESIGN.md was checked, updated, or intentionally left for
      a follow-up. -->

```bash
{Focused test(s) covering the changed behaviour}
{Changed-file or affected-package lint/typecheck/build; for aidevops use .agents/scripts/linters-local.sh --changed}
```

- **Surface mapping:** {map each command to the files, write paths, hazards, and acceptance criteria it proves}

- **Broad verification trigger:** {Not required | exact evidence that shared config, root tooling, dependency graph, cross-package contracts, or release infrastructure requires a full-repository gate}
- **Broad verification command:** {Delete when not triggered; never add `linters-local.sh --full` merely as generic completion evidence}

### Recoverability Checkpoint

<!-- REQUIRED for long-running shell/framework tasks, dispatch-path changes, or
     tasks touching 4+ files. After focused tests pass, commit a WIP checkpoint
     before broad lint/release gates so watchdog/runtime failures leave a
     recoverable branch instead of only dirty runner-local edits. Delete for
     small single-pass tasks. -->

- [ ] Focused tests pass: `{command}`
- [ ] WIP commit created before broad gates: `wip: {short description}`
- [ ] Evidence-triggered broad verification then run: `{command or not required — reason}`

### Safety-Stop Recovery

<!-- REQUIRED when resource, timeout, cost, rate-limit, security, or process
     fuses can interrupt the task. A fuse pauses only the unsafe route; it never
     satisfies acceptance criteria. Keep the task open and use the recovery
     ladder in reference/safety-stop-recovery.md. Delete only when no fuse can
     interrupt this task. -->

- **Original objective:** {verbatim outcome to preserve}
- **Preserved user directions:** {constraints and requested value}
- **Trigger and evidence:** {or `not triggered`}
- **Completed and verified:** {durable evidence}
- **Remaining acceptance criteria:** {all unfinished criteria}
- **Unsafe route not to repeat:** {exact route or `none`}
- **Next safe route:** {narrower/decomposed/alternate-resource continuation}
- **Resume condition:** {specific condition}
- **Owner and status:** {owner}; {recovering | blocked | not-triggered}

### Files Scope

<!-- Declares the file paths this task is allowed to modify.
     The scope-guard pre-push hook (scope-guard-pre-push.sh) reads this list
     and blocks pushes that include files outside the declared scope,
     preventing accidental scope-leak during rebase or implementation drift.
     Glob patterns are supported (e.g., `.agents/hooks/*.sh`).
     One path or glob pattern per `- ` line.

     CRITICAL RULES:
     1. Paths MUST be relative to the repository root (e.g., `.agents/hooks/foo.sh`,
        NOT `~/Git/aidevops/.agents/hooks/foo.sh` or `./hooks/foo.sh`).
        Technical reason: scope-guard-pre-push.sh resolves all declared paths against
        the repository root via `git rev-parse --show-toplevel`. Paths not anchored to
        the root will silently fail to match — the guard will not fire and unintended
        files can pass through without review.
     2. Do NOT use overly-permissive globs (e.g., `**/*` or `*.sh` without a prefix).
        Overly-broad scope declarations create a path traversal risk: files outside
        the intended scope may be committed and pushed without triggering a block,
        undermining the entire guard. Declare the narrowest scope that covers the
        intended changes. -->

- `{path/to/file-or-glob}`

## Acceptance Criteria

Each criterion may include an optional `verify:` block (YAML in a fenced code block)
that defines how to machine-check the criterion. See `.agents/scripts/verify-brief.sh` for the runner.
Schema-v2 briefs require at least two observable criteria: one positive behavior
and one explicit negative/regression guarantee.

- [ ] {Specific, testable criterion — e.g., "User can toggle sidebar with Cmd+B"}

  ```yaml
  verify:
    method: bash
    run: "{shell command — pass if exit 0}"
  ```

- [ ] {Another criterion — e.g., "Conversation history persists across page reloads"}

  ```yaml
  verify:
    method: codebase
    pattern: "{regex pattern to search for}"
    path: "{directory or file to search in}"
  ```

- [ ] {Negative criterion — e.g., "Org A's data never appears in Org B's context"}

  ```yaml
  verify:
    method: codebase
    pattern: "{pattern that must NOT match}"
    path: "{search scope}"
    expect: absent
  ```

- [ ] {Criterion requiring AI review}

  ```yaml
  verify:
    method: subagent
    prompt: "{review prompt for AI to evaluate}"
    files: "{optional: files to include as context}"
  ```

- [ ] {Criterion requiring human review}

  ```yaml
  verify:
    method: manual
    prompt: "{what the human should check}"
  ```

- [ ] Task-relevant tests pass (`npm test -- <target>` / `bun test <target>` / project-specific affected test command)
- [ ] Changed-file or affected-package lint is clean (`linters-local.sh --changed` / scoped `eslint` / `shellcheck`; React/TypeScript ESLint warnings such as `react-hooks/exhaustive-deps` count as actionable even when lint exits `0`)
- [ ] UI changes cite the checked/updated DESIGN.md source or a follow-up issue; layout changes include mobile/tablet/desktop responsive evidence and named accessibility checks.
- [ ] Qlty smells resolved (for `#simplification` tasks): `~/.qlty/bin/qlty smells --all 2>&1 | grep '<target_file>' | grep -c . | grep -q '^0$'`

  ```yaml
  verify:
    method: bash
    run: "~/.qlty/bin/qlty smells --all 2>&1 | grep '<target_file>' | grep -c '.' | xargs test 0 -eq"
  ```

<!-- Verify block reference:
  Methods:
    bash     — run shell command, pass if exit 0
    codebase — rg pattern search, pass if match found (or absent with expect: absent)
    subagent — spawn AI review prompt via ai-research
    manual   — flag for human, always reports SKIP (never blocks automation)

  Verify blocks are optional. Criteria without them are reported as UNVERIFIED.
  Runner: .agents/scripts/verify-brief.sh <brief-file>
-->

## Context & Decisions

{Key decisions from the conversation that created this task:}
{- Why approach A was chosen over B}
{- Constraints discovered during discussion}
{- Things explicitly ruled out (non-goals)}
{- Prior art or references consulted}

## Relevant Files

- `path/to/file.ts:45` — {why relevant, what to change}
- `path/to/related.ts` — {dependency or pattern to follow}
- `path/to/test.test.ts` — {existing test patterns}

## Dependencies

- **Blocked by:** {task_ids or external requirements}
- **Blocks:** {what this unblocks when complete}
- **External:** {APIs, services, credentials, purchases needed}

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | {Xm} | {what to read} |
| Implementation | {Xh} | {scope} |
| Testing | {Xm} | {test strategy} |
| **Total** | **{Xh}** | |

<!-- READING BUDGET CHECK (GH#18458):
     If the Research/read phase lists >2,000 lines of reference material across all
     files, the task is at HIGH RISK of worker timeout (token exhaustion before
     implementation starts). Mitigations:
     1. Use the Worker Quick-Start section to front-load critical data
     2. Include extracted data inline (don't just point to large files)
     3. Consider tier:thinking if the task requires synthesizing across 5+ files
     4. For decomposition Phase 0 tasks specifically, use tier:thinking — these
        require reading the plan + model file + target file + wrapper file, which
        routinely exceeds 4,000 lines of reference material.
-->
