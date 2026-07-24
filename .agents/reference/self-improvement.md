<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Self-Improvement

Every session should deliver verified value or leave an auditable signal. Fix the process, not the symptom, but promote only scoped, reusable, evidence-backed learning rather than preserving every observation.

## Human Attention and Responsibility

Optimise for **verified value per unit of human attention**. Human time is a constrained, high-value input, not a routine approval mechanism.

- **AI owns routine leverage:** remember details, inspect accumulated context, discover opportunities, compare options, estimate risk, implement and verify reversible improvements, measure outcomes, and maintain consistency across the harness.
- **Humans supply exclusive inputs:** taste, lived experience, inaccessible or offline context, personal values, feedback from reality, and authority for consequential or irreversible commitments.
- **Escalate by expected value:** before interrupting, determine whether existing evidence, a safe test, a reversible action, or a scoped inference can resolve the question. Ask only when human input is materially irreplaceable.
- **Learn preferences autonomously:** infer and apply low-risk, reversible preferences within the narrowest supported scope. Seek confirmation when preferences conflict, scope is materially uncertain, or consequences are difficult to reverse. Personal evidence must not silently become universal policy.
- **Make autonomous work observable:** launch long checks, CI waits, and worker monitoring in the background when possible; poll at bounded intervals, process results as soon as they are terminal, and report meaningful gate transitions. A synchronous foreground wait that leaves the user unable to distinguish work from a stall wastes attention.
- **Measure returned time:** track useful work completed, recurring work eliminated, interruptions avoided, correction rate, and free time created—not merely tasks, tokens, or memories accumulated.

## Core Workflow

**State observation.** `TODO.md`, `todo/PLANS.md`, and GitHub issues/PRs are canonical state. Never duplicate into separate files/logs.

**Signals** (check via `gh` CLI): PR open 6h+ with no progress; PR closed without merge (worker failure); repeated CI failures or duplicate PRs.

**Response: file an issue.** Describe pattern, root cause, and proposed fix. Never patch around broken processes.

## Routing & Filing

**Framework-level** (`~/.aidevops/`, scripts, prompts, orchestration) → `marcusquinn/aidevops`. **Project-specific** (CI, code, deps) → current repo. Test: "Does this apply to all repos?" Never file framework tasks in project repos.

### Filing framework issues (GH#5149)

Use `framework-issue-helper.sh`, not `claim-task-id.sh`:

```bash
# Detect framework vs project (exit 0=framework, 1=project)
~/.aidevops/agents/scripts/framework-issue-helper.sh detect "description"

# File on marcusquinn/aidevops (auto-deduplicates)
~/.aidevops/agents/scripts/framework-issue-helper.sh log \
  --title "Bug: supervisor pipeline fails..." --body "Observed in..." --label "bug"
```

## Constraints & Quality

**Scope boundary (t1405, GH#2928):** `PULSE_SCOPE_REPOS` limits worktrees/PRs. Filing issues is always allowed. Outside scope → file issue and stop.

**Issue quality filter (GH#6508):** Enhancements require (1) observed failure (no preemptive bloat), (2) no deterministic alternative, (3) not a deliberate framework choice. Bar: **observed failure first, minimal guidance**.

**Intelligence over determinism:** See `.agents/AGENTS.md` "Framework Rules > Intelligence Over Determinism". Use deterministic rules for CLI/paths/security; judgment for everything else. Use cheapest capable model.

## What to Improve

- Repeated failure patterns, prompt misunderstandings, or missing automation.
- Stale blocked tasks or **information gaps (t1416)** (missing tier/branch/diagnosis).
- Run session miner pulse (`scripts/session-miner-pulse.sh`).

## Session Learning Capture

Treat valuable session learning as system input, not disposable transcript context. Outliers are expensive to find intentionally; when one appears during normal work, convert it into reusable system knowledge before it evaporates.

- **Apply now by default:** repair an observed failure, efficiency loss, or productivity gap in the current session when it is safe, authorized, and in scope; verify the repair before moving on.
- **Preserve context momentum:** when the session has enough evidence, authorization, and safe execution paths, continue through implementation and verification instead of handing reconstruction cost to a future session. Defer only for a real dependency, safety boundary, resource fuse, or explicit user choice.
- **File larger work separately** when the repair would materially widen scope or delay the active objective. Deduplicate first, then create a dedicated issue with files, pattern, evidence, verification, and an explicit note when paths are unknown; do not leave an actionable lesson only in chat or memory. When the authenticated creator has maintainer/admin authority and the issue is worker-ready, apply the `auto-dispatch` label at creation under `reference/task-lifecycle.md`; maintainer authorship or `origin:interactive` provenance does not substitute for that label. Do not auto-dispatch contributor-authored issues at creation; leave them on the existing external-issue triage path in `workflows/triage-review.md`.
- **Store memory/reference** when the lesson is reusable but not immediately dispatchable, especially diagnostics, edge cases, duplicate patterns, and "similar but different" hazards.
- **Route design learning by scope:** durable repo-specific UI patterns belong in that repo's `DESIGN.md`; generic aidevops briefing/verification patterns become aidevops issues with anonymised evidence; uncertain or broad design lessons become worker-ready follow-ups instead of bloating global docs.
- **Avoid speculative bloat:** capture observed examples and evidence; do not add global guidance for hypothetical failures.

### Session friction and efficiency retrospective

At the end of significant interactive work, review the actual path from request
to verified outcome. Use `session-introspect-helper.sh patterns`,
`report-token-use-helper.sh`, RTK comparison/adoption evidence, lifecycle state,
and the conversation itself; do not create a parallel telemetry plane.

- Record permission prompts, policy false positives, retries, equivalent-command
  workarounds, duplicate workers/worktrees, manual lifecycle steps, repeated CI
  output, version drift, and repeated rediscovery.
- Do not invent universal numeric thresholds. Compare like-for-like sessions and
  lifecycle stages where useful, but retain unexpected qualitative outliers that
  do not fit the existing categories.
- Audit existing token-saving mechanisms before proposing another one. Establish
  whether filtering, caching, summarisation, subagents, or compaction reduced
  discarded output and duplicate work, or instead forced raw fallback and
  reconstruction.
- Optimise for tokens per verified outcome and human attention returned—not the
  lowest token count. Extra context is justified when it materially improves
  correctness, security, review coverage, or durable understanding.
- Check comprehension explicitly: missed requirements, incorrect assumptions,
  repeated rediscovery, incomplete review, weak verification, or loss of causal
  context are regressions even when token use falls.
- Route only evidence-backed findings: fix safe in-scope defects now; otherwise
  deduplicate against memory, tasks, issues, merged fixes, and active work before
  creating one worker-ready improvement brief.

### Similar-but-different hazards

- When two patterns look related but differ in contract, scope, or trust boundary, do not merge them mentally or create a third near-duplicate pattern.
- Standardize when evidence supports one canonical path; otherwise record the distinction and route cleanup as a task.
- Good captures name the files/functions, the conflicting conventions, why one path is safer or preferred, and how to verify the chosen convention.

### Auditable failures

Failure information is valuable when it helps future sessions diagnose and avoid wasted work. Capture failures with: symptom, command/check evidence, affected file/PR/issue, suspected versus verified cause, next action, and whether the lesson belongs in a hook, validator, worker task, memory, or reference doc. Do not publish blame until diagnostics evidence supports it; see `reference/diagnostics-discipline.md`.

## Autonomous Operation

"continue"/"monitor"/"keep going" → autonomous mode: sleep/wait loops, perpetual todo for compaction survival. Interrupt only for blocking errors requiring user input.
