# Parent-Task Decomposition Lifecycle (t2442)

A `parent-task` label is a *permanent dispatch block* — it must be paired with a concrete decomposition plan, or it becomes backlog rot.

**Key rule:** `#parent` is the permanent structural dispatch block for a roadmap or decomposition issue. Authority-label normalization cannot override it: `parent-task` short-circuits `dispatch-dedup-helper.sh is-assigned` with `PARENT_TASK_BLOCKED`. (t2211)

## Five Cooperating Enforcement Mechanisms

### 1. No-Markers Warning at Label-Application Time (Fix #2)

When `parent-task` is applied to an issue whose body contains none of the recognised decomposition headings — `## Children`, `## Child Issues`, `## Sub-tasks`, `## Phases`, or `## Phase N[: ...]` — `_post_parent_task_no_markers_warning` (in `issue-sync-lib.sh`) posts a one-time comment pointing the author at the four remediation paths.

Called from both `issue-sync-helper.sh cmd_push` and `claim-task-id.sh create_github_issue`. Dedup via `<!-- parent-task-no-markers-warning -->` marker.

### 2. Prose-Pattern Children Extraction (Fix #3)

`_extract_children_from_prose` in `pulse-issue-reconcile.sh` is the third fallback (after graph-based and heading-scoped extraction) for recognising decomposition in issue bodies that don't use formal headings.

Narrow patterns only: `Phase N ... #NNNN`, `filed as #NNNN`, `tracks #NNNN`, `Blocked by: #NNNN`. Widening this set is forbidden — CodeRabbit disqualified "any `#NNN` = child" matching in PR #19810 (t2244).

### 3. 4-Hour Advisory Nudge (t2388, tightened t2949)

`reconcile_completed_parent_tasks` posts `_post_parent_task_decomposition_nudge` on parent-tasks with 0 children where ≥4h have elapsed since label application (env `PARENT_TASK_NUDGE_SECONDS`, default 14400s; was 86400s/24h). Dedup via `<!-- parent-task-decomposition-nudge -->` marker.

### 4. Auto-Decomposer Scanner (Fix #1, tightened t2573)

`auto-decomposer-scanner.sh` runs on every pulse cycle via `_run_auto_decomposer_scanner` (in `pulse-simplification.sh`) — the former global 24h run gate was removed in t2573 to allow multiple parents to be cleared per day (t2949 reduced the per-parent re-file gate further from 1d/86400s to 4h/14400s).

For each open parent-task with 0 children and an eligible nudge, it files a fresh `tier:thinking` worker issue with generator marker `<!-- aidevops:generator=auto-decompose -->`.

Age thresholds (t2949 defaults — reduced from GH#20532 zero-delay to 4h):
- **Fresh parents** (0 non-nudge comments): ≥`SCANNER_FRESH_PARENT_HOURS` (default 4h, driven by `PARENT_TASK_NUDGE_SECONDS`)
- **Aged parents** (≥1 non-nudge comments): ≥`SCANNER_NUDGE_AGE_HOURS` (default 4h, driven by `PARENT_TASK_NUDGE_SECONDS`)

The comparison is `age_hours >= threshold_hours` (`-lt` guard). Set `PARENT_TASK_NUDGE_SECONDS=0` to restore zero-delay (AI-throughput) mode.

Per-parent state file (`AUTO_DECOMPOSER_PARENT_STATE`) prevents re-filing the same parent within `AUTO_DECOMPOSER_INTERVAL` (default 4h / 14400s; was 1d/86400s before t2949; env `PARENT_TASK_REFILE_GATE_SECONDS`). The worker's job: read the parent, propose a decomposition plan as children, and stop. Dedup via `source:auto-decomposer` label.

Constants in `pulse-wrapper.sh`: `AUTO_DECOMPOSER_INTERVAL`, `AUTO_DECOMPOSER_PARENT_STATE`. Maintainer-only (skips `role: contributor` repos).

### 5. 7-Day Advisory Escalation (Fix #4)

If the advisory nudge is ≥7 days old and still zero children exist, `_post_parent_decomposition_escalation` posts an idempotent advisory comment listing the four paths forward:

1. Decompose into children
2. Drop the `parent-task` label
3. Close the issue
4. Let the auto-decomposer handle it

The escalation adds no second blocker: `parent-task` already blocks direct implementation and must remain visible to the auto-decomposer. It never removes `parent-task`; the label removal instruction appears only as user-facing guidance inside a markdown code fence.

Env override: `PARENT_DECOMPOSITION_ESCALATION_HOURS` (default 168). Capped at `max_escalations` per reconcile pass. Dedup via `<!-- parent-needs-decomposition-escalated -->` marker.

## Test Coverage

`.agents/scripts/tests/test-parent-prose-child-detection.sh`, `test-parent-task-application-warn.sh`, `test-parent-decomposition-escalation.sh`, `test-auto-decomposer-scanner.sh`, `test-auto-decomposer-per-parent-gate.sh` (84+ structural assertions total).

## Child Dispatch Contract

- The roadmap issue keeps `parent-task` and never receives `auto-dispatch`.
- Independent worker-ready children use `auto-dispatch,status:available` and may
  run in parallel.
- In an ordered chain, only the first ready child is available. Every later
  worker-ready child keeps `auto-dispatch,status:blocked` plus a verified native
  `blockedBy` relationship and an auditable textual marker.
- Issue publication must fail closed: never expose a dependent child as
  available before its native edge is verified.
- Pulse owns the handoff. When every blocker closes, dependency reconciliation
  changes the next child to `status:available`; the completing worker closes
  only its own issue and does not remove successor blockers or labels manually.

## Sequential Phase Auto-File (t2740, enabled by default since t2787)

The sequential phase auto-file mechanism reads phase declarations from the parent-task issue body and files the **next unfiled phase** as a child issue automatically once the prior phase's PR merges.

Parent reconciliation also bootstraps phase-only parents with zero filed children: when a `parent-task` issue has a parseable `## Phases` section but no `## Children`, GraphQL sub-issues, or prose child references, the reconcile pass files the first unfiled phase as a worker-dispatchable child before falling back to advisory decomposition nudges. This prevents phase-only parents from sitting open forever with `parent-task` blocking dispatch and `auto-decomposer-scanner.sh` skipping because a phase plan exists.

**Feature flag:** `AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE` — defaults to `1` (ON) since t2787. Set to `0` to disable.

### Canonical Phase Formats

Two formats are supported. Both are parsed by `_extract_sequential_phases` in `shared-phase-filing.sh`.

**List format (preferred — auto-fire enabled by default):**

```markdown
- Phase 1 - description [auto-fire:on-prior-merge]
- Phase 2 - description [auto-fire:on-prior-merge]
- Phase 3 - description
```

Bullet-wrapped bold headings are also accepted, which is the common parent-brief style:

```markdown
- **Phase 1 — description**: optional detail text.
- **Phase 2 — design CLI `new|list|status` surface**: pipes in CLI prose are text, not child references.
```

**Narrative bold-heading format (for prose-style decomposition plans):**

```markdown
**Phase 1 — description [auto-fire:on-prior-merge]**
Detailed implementation notes for Phase 1...

**Phase 2 — description**
Detailed implementation notes for Phase 2...
```

### Auto-Fire Markers

| Marker | Behaviour |
|--------|-----------|
| `[auto-fire:on-prior-merge]` | File this phase when the prior phase PR merges (recommended) |
| `[auto-fire:on]` | File immediately — no wait for prior merge |
| *(no marker — list/bullet-bold format)* | Eligible for the initial zero-child bootstrap; post-merge sequencing still requires an explicit auto-fire marker |
| *(no marker — narrative format)* | NOT auto-filed unless `<!-- phase-auto-fire:on -->` appears in the issue body |

The `<!-- phase-auto-fire:on -->` HTML comment is the opt-in for narrative phases without per-phase markers. It applies the `on-prior-merge` behaviour to every unmarked narrative phase in the issue.

### Close Guard

The close guard (t2755 Phase 2) prevents premature parent-task closure while any declared phase is still unfiled or open. If a PR uses a closing keyword (`Closes #NNN`) on a parent-task issue that still has pending phases, the merge is accepted but the issue is re-opened with an explanatory comment. Deterministic incomplete close-contract repairs use `hold-for-review`; the ordinary 7-day decomposition escalation remains advisory-only.

## Use Cases

**Use `#parent` for:** decomposition epics with child implementation tasks, roadmap trackers, research summaries that spawn separate work items, any investigation or "think-before-acting" issue.

**Do NOT use for:** issues that should eventually be implemented as a single unit — those are normal tasks. The point of `#parent` is "this issue will never be implemented directly; only its children will."
