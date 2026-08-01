<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Lifecycle

Source: extracted from `.agents/AGENTS.md` Task Lifecycle and Git Workflow sections (Phase 2 of #22616 — progressive-disclosure decomposition). Read this file before filing or queueing tasks, changing task/issue/PR lifecycle labels, creating cross-repo tasks, reasoning about parent-task decomposition, or diagnosing auto-dispatch, auto-merge, cryptographic approval, and NMR behaviour.

When to load:

- Creating tasks with `/define`, `/new-task`, or `claim-task-id.sh`.
- Deciding whether a task should be auto-dispatched, parent-blocked, or implemented interactively.
- Updating task completion state or linking verification evidence.
- Creating tasks in another registered repo or editing `repos.json`.
- Diagnosing issue/PR lifecycle labels, origin labels, auto-merge eligibility, cryptographic approvals, or NMR automation.

For prompt-economy reasons these rules live here rather than in always-on AGENTS.md context. The pointer in AGENTS.md (`## Task Lifecycle`) names the key lifecycle topics so a `grep` in AGENTS.md still finds this forwarding address.

## Task Creation

The proposed atomicity contract between issue dispatchability and protected-
branch planning publication is documented in
`reference/planning-publication-lifecycle.md`. Follow that decision record when
implementing the pending-publication state and its reconciliation phases.

1. Define the task: `/define` (interactive interview) or `/new-task` (quick creation)
2. Brief file at `todo/tasks/{task_id}-brief.md` is MANDATORY (see `templates/brief-template.md`)
3. Brief must include: session origin, what, why, how, acceptance criteria, context
4. Resolve the execution route before publication: implement now, create a worker-ready implementation issue and auto-dispatch it, or save a local TODO/plan for later. Creating the implementation issue is itself approval to implement; do not seek a second dispatch decision afterward.
5. Full-loop: keep canonical repo on `main` → create/use linked worktree → implement → test → verify → commit/PR
6. Queue: add to TODO.md for supervisor dispatch
7. Never skip testing. Never declare "done" without verification.
8. **Performance/optimization issues require evidence** (GH#17832-17835): actual measurements (timing, profiling), verified line references, and data scale assessment. "May cause O(n^2)" without data is not actionable — use the "Performance Optimization" issue template. See "Framework Rules > AI-Generated Issue Quality" above.

Format: `- [ ] t001 Description @owner #tag ~4h started:ISO blocked-by:t002`

Dependency rule: when a TODO/issue declares ordered work with `blocked-by:*`
or `blocks:*`, preserve the text marker for human/reconciliation context and
sync it into GitHub's native issue relationship field. The native `blockedBy`
relationship is the primary dispatch gate; body/TODO markers are fallback intent
and repair signals. Worker-ready ordered leaves retain `#auto-dispatch`: the
first ready leaf is `status:available`, while every unresolved dependent is
`status:blocked` after its native edge is verified. If an edge cannot be created
or verified, fail closed by retaining `status:blocked` and never exposing the
dependent to the available queue. `issue-sync-relationships.sh` performs the
normal TODO-to-GitHub relationship backfill and status normalization; Pulse
changes the next leaf to `status:available` after all blockers close. Workers
complete only their own leaf and do not manually edit successors.

Task IDs: `/new-task` or `claim-task-id.sh`. NEVER grep TODO.md for next ID.

## Safety-Stop Recovery

A resource, security, cost, timeout, or process fuse stops only the current
execution path. It does not satisfy or cancel the task. Keep the task unchecked
and in `recovering` or `blocked`, preserve the objective and evidence in a
durable checkpoint, and create the next safer action before yielding. Never use
`skipped` or `completed` solely because a fuse fired. Full checkpoint fields,
recovery ladder, terminal exceptions, and completion review:
`reference/safety-stop-recovery.md`.

## Briefs, Tiers, and Dispatchability

- **Task briefs:** Every task must have `todo/tasks/{task_id}-brief.md` (via `/define` or `/new-task`). A task without a brief is undevelopable because it loses the implementation context needed for autonomous execution. See `workflows/plans.md` and `scripts/commands/new-task.md`.

- **`### Files Scope` field:** Section in the brief template (nested under `## How`) for declaring allowed file paths (globs supported). The `scope-guard-pre-push.sh` hook uses this to block out-of-scope pushes, preventing accidental scope-leak. One path or glob per bullet line. Older briefs may use `## Files Scope`; both heading levels are accepted by the guard.

- **`### Complexity Impact` field (t2803):** Section for tasks modifying shell functions. Author must estimate growth: 80-100 lines projected post-change requires a warning; >100 lines (the `function-complexity` gate) REQUIRES a pre-planned refactor. Prevents the recurring pattern where workers grow a function past the gate threshold and trigger repeated dispatch failures (canonical: 8 workers on GH#20702). Include this section for any `EDIT:` targeting an existing function body; delete it when the task creates only new files or new functions. Full guidance: `reference/large-file-split.md §0`.

- **Worker-ready issue body heuristic (t2417):** Before creating a full brief, `/define`, `/new-task`, and `task-brief-helper.sh` check whether the linked issue body is already worker-ready — i.e., it contains 4+ of the 7 known heading signals (`## Task`, `## Why`, `## How`, `## Acceptance`, `## What`, `## Session Origin`, `## Files to modify`). When the issue body is worker-ready, the brief file is either skipped (headless default) or replaced with a stub that links to the issue as the canonical brief. This prevents brief/issue body duplication and the collision surface it creates (see GH#20015). Helper: `scripts/brief-readiness-helper.sh`. Threshold override: `BRIEF_READINESS_THRESHOLD` env var.

**Brief composition**: All GitHub-written content (issue bodies, briefs, PR descriptions, comments, escalation reports, worker guidance) follows `workflows/brief.md` — the centralised formatting workflow. Load it before publishing; optional seeded draft PRs are governed there, not in this root guide.

**Workload tiers and dispatchability**: Use GitHub `tier:*` labels and the canonical decision order in `reference/task-taxonomy.md`; default to `tier:standard` unless a thinking trigger or complete simple contract is proven. Before recommending a tier or queueing work, run `task-dispatchability-helper.sh check --task-id tNNN [--issue N]`. `tier-simple-body-shape-helper.sh` enforces only explicit simple-contract invariants pre-dispatch.

## Conversation Intent Routing

**Issue-start override:** A user's interactive implementation or `/full-loop` turn
makes that primary conversation authoritative through completion. Do not move its
critical path to a subagent, headless worker, or background executor unless the
user explicitly requests background execution. `interactive-start-helper.sh`
exports `AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION=1`, claims with
`--implementing`, and starts in the foreground by default; explicit `--background`
remains local asynchronous work. Generic background/worker intent must not
redispatch that issue; headless and remote-worker routes reject the marker.
Sessions that only inspect an issue do not set the marker and remain eligible for
ordinary pulse dispatch.

Natural-language task capture must be as explicit as slash commands. When a user gives work that could become a TODO or issue, first classify the intent:

| User signal | Route | Confirmation |
|-------------|-------|--------------|
| `/full-loop ...`, issue/task number after `/full-loop`, "do/work/fix/implement this now", "in this session" | Execute `/full-loop` in the primary conversation | Do not ask whether to start or delegate; proceed unless blocked by safety/secret/destructive gates |
| "background", "worker", "auto-dispatch", "have an agent do this" | Compose with `workflows/brief.md`, create TODO/issue with `#auto-dispatch` when readiness passes, and queue/dispatch | Ask only for missing secrets, destructive approval, unknown repo, or unavailable verification |
| "save", "log", "for later", `/save-todo`, `/aidevops-save-todo` | Compose with `workflows/brief.md`; save as a local TODO/plan without creating an implementation issue | Do not ask again; explicit later intent is the decision |
| "create/file/open an issue", or a session identifies a fixable out-of-scope finding | Compose with `workflows/brief.md`; create a worker-ready implementation issue with `#auto-dispatch` | Do not ask for separate dispatch approval; issue creation authorizes implementation |
| Ambiguous "we need to...", "should add...", "can you note..." | Infer the safest productive route from the established objective: implement in scope now, otherwise create a worker-ready auto-dispatch issue | Ask before publication only when human input is materially irreplaceable under `reference/self-improvement.md` |

Never offer "create an issue" and "create an issue and auto-dispatch" as separate
choices for implementation work. Decide whether an issue should exist before
publishing it; once created, automatic implementation is the default. Explicit
save/later intent stays local and needs no follow-up question. If a brief cannot
meet auto-dispatch readiness, repair it autonomously when possible; otherwise
record the concrete blocker and missing irreplaceable input without converting
routine uncertainty into `#no-auto-dispatch`.

## Auto-Dispatch and Completion

- **Auto-dispatch default**: Worker-ready implementation issues/tasks created by interactive agents (user-facing sessions) or workers default to `#auto-dispatch`; issue creation is the implementation decision, so no second dispatch confirmation is allowed. Readiness is the gate, not an opt-in. Add the tag only when the brief/body has:
  - a clear deliverable in the `What` section;
  - referenced files or patterns in the `How` section;
  - automatable verification; and
  - 2+ acceptance criteria beyond generic tests/lint.

  If readiness is missing, improve the brief when practical, but do not suppress useful issue publication or ask the user to perform routine triage. Publish without `#auto-dispatch`, state the missing information, and leave the issue recorded for autonomous enrichment; use `#parent`/blocked only when those semantics are true. Do not add `#no-auto-dispatch` merely because readiness is incomplete—that label is reserved for explicit durable manual intent with its reason recorded on the issue. See `workflows/plans.md` "Auto-Dispatch Tagging".
- **Exclusions**: Omit `#auto-dispatch` only for:
  - blocker labels;
  - credentials, accounts, or purchases;
  - decomposition or human-decision work;
  - hardware or external service setup;
  - investigation/evaluation without a clear deliverable;
  - dependencies that cannot yet be resolved to verified native relationships; or
  - explicit user preference for interactive/manual handling.

  Dispatch-path files are **not** excluded post-t2920; they auto-dispatch with opus-4-7 elevation. Canonical blocker label set: `reference/dispatch-blockers.md`.
- **Dispatch-path advisory (t2821, t2832, t2920)**: When a task's `### Files Scope` or `## How` section references a file in `.agents/configs/self-hosting-files.conf`, use `#auto-dispatch` as normal. The t2819 detector auto-elevates these workers to `tier:thinking`; runtime routing chooses the concrete model and reasoning level. Worker isolation, CI gates, watchdog kills, and the t2690 circuit breaker replace the historical `no-auto-dispatch` default. Interactive implementation keeps `#auto-dispatch`; its active claim is the temporary deduplication gate. **Durable opt-out (rare):** use `#no-auto-dispatch` only for explicit manual intent or a recorded unresolved safety/authority decision, never merely because the creating session will not implement the issue itself. Full decision tree: `reference/auto-dispatch.md` "Dispatch-Path Default (t2821 / t2920)".
- **Quality gate**: Same readiness definition as `#auto-dispatch` above; do not maintain a second criteria list.
- **Dispatch-label mutual exclusion**: `#auto-dispatch` and `#no-auto-dispatch` must never coexist. Managed issue-create/edit paths normalize conflicts without suppressing publication: an explicit manual hold wins a same-command conflict, and adding either label removes its opposite.
- **Interactive workflow**: Keep worker-ready issues tagged `#auto-dispatch`; claim with `status:in-review` + assignment while working, then release with unassignment so unfinished work resumes automatically.
- **Server-side safety net (t2798)**: `.github/workflows/apply-status-available-default.yml` applies `status:available` to issues that carry `auto-dispatch` but have no `status:*` label — catches bypass-path creations (bare `gh issue create`, web UI) that skip `claim-task-id.sh`.

**Session origin labels are provenance only**: Issues and PRs are automatically tagged with `origin:worker` (headless/pulse dispatch) or `origin:interactive` (user session). Applied by `claim-task-id.sh`, `issue-sync-helper.sh`, and `pulse-wrapper.sh`. In TODO.md, use `#worker` or `#interactive` tags to set origin explicitly; these map to the corresponding labels on push. Do not treat `origin:*` labels as workflow permission: `auto-dispatch` controls worker pickup on issues, and PR merge throughput is controlled by draft/hold state plus explicit merge-throughput preferences.

**Origin label mutual exclusion (t2200)**: `origin:interactive`, `origin:worker`, and `origin:worker-takeover` are mutually exclusive. Use `set_origin_label <num> <slug> <kind>` from `shared-constants.sh` to change an existing label atomically. One-shot reconciliation: `reconcile-origin-labels.sh`. Full detail: `reference/auto-dispatch.md`.

**`#auto-dispatch` skips `origin:interactive` self-assignment**: Issues tagged `#auto-dispatch` are NOT self-assigned even from interactive sessions — self-assignment creates a permanent dispatch block. For heal after the fact: `interactive-session-helper.sh post-merge <PR>` (t2225). Full rule and background: `reference/auto-dispatch.md`.

**`origin:interactive` implies maintainer approval, not merge consent**: PRs tagged `origin:interactive` pass the maintainer gate automatically when the PR author is `OWNER` or `MEMBER` — the maintainer was present and directing the work. No separate `sudo aidevops approve` is needed. Contributors (`COLLABORATOR`) with `origin:interactive` still go through the normal gate — the label alone is not sufficient. The pulse also never auto-closes `origin:interactive` PRs via the deterministic merge pass, even if the task ID appears in recent commits (incremental work on the same issue is legitimate).

**Auto-merge timing (t2411/GH#23238):** `origin:interactive` PRs from `OWNER`/`MEMBER` auto-merge only when CI passes, no CHANGES_REQUESTED, not draft, no `hold-for-review`, and merge throughput is explicitly opted in by `allow-auto-merge`, `AIDEVOPS_INTERACTIVE_PR_AUTO_MERGE=1`, global `orchestration.interactive_pr_auto_merge=true`, or per-repo `repos.json` `interactive_pr_auto_merge=true`. Default is manual/draft. `/pr-loop` or an explicit finalise/ready request is the normal signal to make a draft PR ready. Full checklist and user preference precedence: `reference/auto-merge.md`.

**Auto-merge timing (t2449, t3052, t3062) — `origin:worker` (worker-briefed):** `origin:worker` PRs auto-merge when the linked issue was filed by `OWNER`/`MEMBER` OR the issue author login is in the trusted-issue-author allowlist (`.agents/configs/trusted-issue-authors.conf`, t3062) OR the linked issue has a cryptographic approval signature from a maintainer (`sudo aidevops approve issue N`), NMR was never applied OR was cleared via **cryptographic** approval (not `auto_approve_maintainer_issues`), and CI passes. Feature flag: `AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE` (default 1=on). Full 9-criterion checklist + security rationale: `reference/auto-merge.md`.

**Admin merge authority:** Interactive sessions run as the repo admin/owner. For maintainer-owned or maintainer-approved work (`OWNER`/`MEMBER` PR author, maintainer-authored linked issue, trusted issue author, or valid crypto approval), `REVIEW_REQUIRED`, stale branch-protection state, or a self-blocking framework gate is not a user-action blocker once non-gate CI is green and no human `CHANGES_REQUESTED` review exists. Use `gh pr merge <N> --repo <slug> --admin --squash --delete-branch` when needed and record the evidence. Only keep the merge gated when the issue/PR originates from a non-maintainer and lacks cryptographic maintainer approval.

**`origin:interactive` also skips pulse dispatch (GH#18352)**: When an issue carries `origin:interactive` AND has any human assignee, the pulse's deterministic dedup guard (`dispatch-dedup-helper.sh is-assigned`) treats the assignee as blocking — even if that assignee is the repo owner or maintainer, and regardless of the current `status:*` label. This closes the race where an interactive session claimed a task via `claim-task-id.sh` (applying `status:claimed` + owner assignment) and the pulse dispatched a duplicate worker before the session could open its PR. The full active lifecycle is now recognised: `status:queued`, `status:in-progress`, `status:in-review`, and `status:claimed` all keep owner/maintainer assignees in the blocking set.

**Implementing a `#auto-dispatch` task interactively (MANDATORY):** Start with `interactive-start-helper.sh --issue N --repo owner/repo --task "description" --auto-dispatch`. Add `--background` only when the user explicitly requested it. All issue-started implementations claim with `--implementing`, export the local-only implementation marker, run the pre-edit loop check, and start full-loop before any code is written. External repositories skip managed issue mutations but still continue local implementation and the normal contribution PR flow.

**General dedup rule — combined signal (t1996):** The dispatch dedup signal is `(active status label) AND (non-self assignee)` — both required, neither sufficient alone. Every code path that emits a dispatch claim must consult `dispatch-dedup-helper.sh is-assigned` (or apply an equivalent combined check inline) before assigning a worker. Label-only or assignee-only filters are not safe in multi-operator conditions. Specifically:
- A status label without an assignee = degraded state (worker died mid-claim) — safe to reclaim after `normalize_active_issue_assignments` / stale recovery.
- A non-owner/maintainer assignee without a status label = active contributor claim — always blocks dispatch regardless of labels.
- An owner/maintainer assignee with an active status label = active pulse claim — blocks dispatch (GH#18352).
- An owner/maintainer assignee without an active status label = passive backlog bookkeeping — allows dispatch (GH#10521).

Architecture: `dispatch_with_dedup` → `check_dispatch_dedup` Layer 6 is the canonical enforcement point. Full detail: `reference/auto-dispatch.md`.

**Parent / meta tasks (`#parent` tag, t1986)**: Mark planning-only or roadmap-tracker tasks with the `#parent` (alias: `#parent-task`, `#meta`) TODO tag. The tag maps to the protected `parent-task` label, which: (1) survives reconciliation — `_is_protected_label` prevents cleanup from stripping it; (2) blocks dispatch unconditionally — pulse will never run a worker on a `parent-task` issue; (3) is applied synchronously at creation (t2436) — before the issue is created, closing the race window.

Use for: decomposition epics, roadmap trackers, research summaries. **Do not use for:** issues that should be implemented as a single unit.

**Maintainer-authored research tasks MUST use `#parent` (t2211):** if a maintainer files an issue without `#auto-dispatch` and it later escalates to `needs-maintainer-review` (e.g. because a worker picked it up anyway via stale-recovery or a TODO-first flow), `auto_approve_maintainer_issues()` at `pulse-nmr-approval.sh:468-470` unconditionally adds the `auto-dispatch` label when removing NMR. Body prose like "Do NOT `#auto-dispatch`" is silently overridden — the auto-approval path intentionally converts NMR'd maintainer-authored issues into dispatchable ones (approver intent wins). `#parent` is the only reliable dispatch block in this case because its `parent-task` label short-circuits `dispatch-dedup-helper.sh is-assigned` with `PARENT_TASK_BLOCKED` upstream of the approval path. Practical rule: any investigation, research, or "think-before-acting" issue the maintainer files should carry `#parent` from the start.

**Parent-task decomposition lifecycle (t2442):** A `parent-task` label must be paired with a decomposition plan or it becomes backlog rot. Five cooperating enforcement mechanisms: no-markers warning at creation, prose-pattern child extraction, advisory nudge (posted on next pulse cycle after ≥4h, env `PARENT_TASK_NUDGE_SECONDS`), auto-decomposer scanner (every pulse cycle, 4h nudge-age threshold, 4h re-file gate, env `PARENT_TASK_REFILE_GATE_SECONDS`), and 7-day NMR escalation. Escalation never removes `parent-task`. Full detail: `reference/parent-task-lifecycle.md`.

Completion: NEVER mark `[x]` without merged PR (`pr:#NNN`) or `verified:YYYY-MM-DD`. Use `task-complete-helper.sh`. Every completed task must link to its verification evidence — work without an audit trail is unverifiable and may be reverted.

**Known limitation — issue-sync TODO auto-completion (t2029 → t2166):** `issue-sync.yml` cannot auto-push to `main` without `SYNC_PAT` (fine-grained PAT, Contents: Read and write). **Guided fix:** run `/setup-git` in your AI assistant — it walks all affected repos with pre-filled token-creation URLs (see `reference/sync-pat-platforms.md`). Manual fix per repo: create the PAT, then `gh secret set SYNC_PAT --repo <owner>/<repo>` (interactive prompt, NOT `--body` which leaks to shell history). Without SYNC_PAT, the workflow posts a remediation comment with a `task-complete-helper.sh` workaround. `SYNC_PAT` is per-repo. Full setup and known false-positive (t2252): `reference/auto-dispatch.md`.

Code changes need worktree + PR. Implementation workers do not edit `TODO.md` as part of code fixes; supervisor/routine/issue-sync bookkeeping may update planning files under the allowlist below.

**Main-branch planning exception (headless bookkeeping only, t1990):** `TODO.md`, `todo/*`, and `README.md` may go direct to `main` only for headless supervisor/routine/issue-sync bookkeeping or an explicitly planning-only worker task. **Interactive sessions have NO such exception** — every edit, including planning files, goes through a linked worktree under `${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}`. Enforced by `pre-edit-check.sh` `is_main_allowlisted_path()`.

**Simplification state policy:** Keep all changes to `.agents/configs/simplification-state.json`. It is the shared hash registry used by the simplification routine to detect unchanged vs changed files and decide when recheck/re-processing is needed.

## Routines

Recurring operational jobs live in `TODO.md` under `## Routines`, not in a separate registry. Use `r`-prefixed IDs (`r001`, `r002`) to distinguish them from `t`-prefixed tasks.

- `repeat:` defines the schedule with `daily(@HH:MM)`, `weekly(day@HH:MM)`, `monthly(N@HH:MM)`, or `cron(expr)`
- `run:` points to a deterministic script relative to `~/.aidevops/agents/`
- `agent:` names the LLM agent to dispatch with `headless-runtime-helper.sh`
- `[x]` means enabled; `[ ]` means disabled/paused and should be skipped
- Dispatch rule: prefer `run:` when present; otherwise use `agent:`; if neither is set, default to `run:custom/scripts/{routine_id}.sh` (e.g. `r001.sh`) when it exists, else `agent:Build+`

Use `/routine` to design, dry-run, and schedule these definitions. Reference: `.agents/reference/routines.md`.

## Cross-Repo Task Management

**Cross-repo awareness**: The supervisor manages tasks across all repos in `~/.config/aidevops/repos.json` where `pulse: true`. Each repo entry has a `slug` field (`owner/repo`) — ALWAYS use this for `gh` commands, never guess org names. Use `gh issue list --repo <slug>` and `gh pr list --repo <slug>` for each pulse-enabled repo to get the full picture. Repos with `"local_only": true` have no GitHub remote — skip `gh` operations on them. Repo paths may be nested (e.g., `~/Git/cloudron/netbird-app`), not just `~/Git/<name>`.

**Repo registration**: When you create or clone a new repo (via `gh repo create`, `git clone`, `git init`, etc.), add it to `~/.config/aidevops/repos.json` immediately. Every repo the user works with should be registered — unregistered repos are invisible to cross-repo tools (pulse, health dashboard, session time, contributor stats). After registering, run `/setup-git` to apply per-repo platform secrets (currently `SYNC_PAT` for GitHub, with GitLab/Gitea/Bitbucket coming) — see `reference/sync-pat-platforms.md`.

**repos.json structure (CRITICAL):** The file is `{"initialized_repos": [...], "git_parent_dirs": [...]}`. New repo entries MUST be appended inside the `initialized_repos` array — NEVER as top-level keys. After ANY write, validate: `jq . ~/.config/aidevops/repos.json > /dev/null`. A malformed file silently breaks the pulse for ALL repos.

Set fields based on the repo's purpose. Full field reference — `pulse`, `pulse_hours`, `pulse_interval`, `pulse_expires`, `contributed`, `foss`, `foss_config`, `review_gate`, `platform`, `role`, `init_scope`, `priority`, `maintainer`, `local_only`: `reference/repos-json-fields.md`.

**Cross-repo task creation**: When creating a task in a *different* repo, follow the full workflow — not just the TODO edit:

1. **Claim the ID atomically**: `claim-task-id.sh --repo-path <target-repo> --title "description"` — allocates via CAS. NEVER grep TODO.md for the next ID; concurrent sessions collide.
2. **Create the GitHub issue BEFORE pushing TODO.md**: Let `claim-task-id.sh` create it (default) or run `gh issue create` manually. Get the issue number first.
3. **Add the TODO entry WITH `ref:GH#NNN` in a single commit+push**: issue-sync triggers on TODO.md pushes and creates issues for entries missing `ref:GH#`. A second commit creates a duplicate. Always include the ref in the same commit.
4. **Code changes still need a worktree + PR**: TODO/issue creation is planning; direct-to-main applies only to headless bookkeeping flows. Interactive sessions still use a linked worktree/PR for planning edits.

Full rules: `reference/planning-detail.md`

For multi-runner coordination (concurrent pulse runners across machines), see `reference/cross-runner-coordination.md`.

## Cryptographic approval and NMR automation

**Cryptographic issue/PR approval (human-only gate):** `sudo aidevops approve issue <number> [owner/repo]` — SSH-signed approval comment; workers cannot forge it (private key is root-only). Setup once with `sudo aidevops approve setup`. Verify: `aidevops approve verify <number>`. This is distinct from the `ai-approved` label (which is a simple collaborator gate, not cryptographic).

**NMR automation signatures (t2386, split semantics):** `auto_approve_maintainer_issues` in `pulse-nmr-approval.sh` distinguishes three cases:
- **Creation-default** (`source:review-scanner` marker/label) → auto-approval CLEARS NMR so the issue can dispatch.
- **Circuit-breaker trip** (`stale-recovery-tick:escalated`, `cost-circuit-breaker:fired` markers) → auto-approval PRESERVES NMR. Clear with `sudo aidevops approve issue <N>` once the problem is fixed.
- **Manual hold** (no markers) → auto-approval PRESERVES NMR.

Background and infinite-loop root cause (t2386): `reference/auto-merge.md` (NMR section).
