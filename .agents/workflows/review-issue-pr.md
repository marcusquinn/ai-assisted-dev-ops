---
description: Interactively review issues and PRs - validate problems, evaluate solutions, and choose the next executable disposition.
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Review External Issues and PRs

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Triage and review issues/PRs — interactive or pulse-automated
- **Focus**: Validate the problem exists, evaluate if the solution is optimal
- **When**: Before approving/merging contributions, or automatically by the pulse for `needs-maintainer-review` items
- **Session title**: For interactive reviews, rename the session with the target first: `Issue #123: review <short topic>` or `PR #456: review <short topic>`.
- **Brief readiness**: When promoting reviewed work to auto-dispatch, use the single `workflows/brief.md` "Dispatch Readiness Contract (brief schema v2)" checklist and `verify-brief-helper.sh check-readiness`; do not restate the checklist here.
- **Outcome ownership**: Resolve the root cause and choose the next executable action; do not turn discoverable implementation decisions into questions for the contributor.

**Core Questions**:
1. **Is the issue real?** — Reproducible? Bug or expected behavior?
2. **Is this the best solution?** — Simpler alternatives? Fits architecture?
3. **Is the scope appropriate?** — PR does exactly what's needed, no more?

<!-- AI-CONTEXT-END -->

## 0. Pre-Review Discovery (MANDATORY)

This is the interactive `maintainer` policy defined in
`reference/review-core.md`. Use its shared evidence and finding contract. The
sandboxed Pulse path is owned separately by `workflows/triage-review.md`.

After resolving the target repository and issue/PR number, build the immutable
baseline before evaluating the proposal:

```bash
review-evidence-helper.sh bundle issue <number> --repo <owner/repo>
review-evidence-helper.sh bundle pr <number> --repo <owner/repo>
```

The bundle does not replace freshness, duplicate, provenance, reproduction, or
architecture discovery below. Reuse its digest when the target evidence is
unchanged; rebuild it after a new PR head or material issue/comment update.

Before reading the proposed fix, establish the current state of the codebase and the issue landscape. Skipping this step is how reviewers rubber-stamp fixes for problems that have already been solved, endorse caches that defeat recently-added invariants, or approve symptom-patches whose root cause lives elsewhere. The review verdict is only as good as this discovery step — if it's weak, the rest is decoration.

**Implementer-side mirror (t2046):** The same discipline applies at implementation time — see `AGENTS.md` "Pre-implementation discovery" for the rule every agent runs before writing code. Reviewers and implementers share the discovery habit; this section is the reviewer-side version of the same check.

### 0.0 Checkout freshness and report provenance

Before treating local files as current evidence, compare the checked-out commit with the remote default branch. A clean checkout can still be materially stale.

```bash
git fetch origin
git status --short --branch
git rev-list --left-right --count HEAD...origin/$(git remote show origin | sed -n '/HEAD branch/s/.*: //p')
```

If the checkout is behind, inspect the cited file at `origin/<default-branch>` or create a fresh linked worktree from that ref. Never reject or approve an issue from stale local code. Preserve dirty canonical work; do not reset, clean, or switch it.

Establish what triggered the report before drawing a verdict: correlate the issue creation time and reported version with recent commits, merged PRs, releases, and the exact causal lines. A mismatch between local code and the report is a prompt to investigate provenance, not evidence that the report is stale.

### 0.1 Duplicate and temporal-duplicate check

Two distinct checks, both required. The second is what's usually missed: an issue filed last week may have been silently solved by unrelated work that landed yesterday.

| Check | What to Run | What to Look For |
|-------|-------------|------------------|
| **Pre-existing duplicate** | `gh issue list --repo <slug> --search "<keywords>" --state all --limit 20` | Another open or closed issue reporting the same problem |
| **Superseded by in-flight PR** | `gh pr list --repo <slug> --state merged --search "<keywords>" --limit 10` then `gh pr list --state open --search "<keywords>"` | A recently-merged or in-review fix that already addresses this — the issue may be stale even if nobody marked it so |
| **Superseded by landed commit** | `git log --all --since="<issue date>" --oneline -- <affected files>` + `git log --all --since="<issue date>" --grep="<keywords>"` | A commit on any branch that addresses the same symptom or root cause |

If the issue is superseded, **stop and recommend closure** instead of reviewing the proposed fix. A fix for an already-solved problem is at best wasted effort and at worst a regression of the correct fix.

### 0.2 Affected-files discovery

Identify the files the issue or PR actually touches and read their **current** state — not the state described in the issue body, which may predate recent changes. A proposal that cites `file.sh:716` may now be wrong if unrelated work bumped the line numbers or refactored the surrounding function.

```bash
# Files mentioned in the issue body
gh issue view <num> --repo <slug> --json body --jq '.body' | rg -oE '[-.a-zA-Z0-9_/]+\.(sh|py|ts|js|md|json|yaml)'

# Their recent git activity (30 days is usually sufficient to catch drift)
git log --oneline --since="30 days ago" -- <files>

# Verify the issue's code quotes match current reality
sed -n 'START,ENDp' <file>
```

### 0.3 Framing critique

Verify the issue's cited symptoms actually match the codebase's behaviour. A reviewer who accepts the reporter's framing at face value can end up solving the wrong problem. Framing errors to catch:

- **"X keeps happening"** → grep the logs/state — is X actually happening, or is the reporter describing a pre-fix behaviour?
- **"Y is too expensive"** → measure the actual cost — is the expense real, or a hypothetical based on misreading the code path?
- **"Z is broken"** → check if Z is invoked at all — the cited path may be dead code, or the function may return early before reaching it.
- **"A locks/unlocks repeatedly"** → grep for the specific events — the observed "churn" may be a different mechanism entirely (e.g., the user may mean "cycles repeatedly" but frame it as "lock/unlock").
- **Producer/consumer mismatch** → when one helper writes state and another validates it, test the full chain. A validator-only fixture can pass while the writer still emits data the validator rejects (e.g., `sync-workflows` output later flagged by `check-workflows`).
- **Security/setup advisory suppression** → identify the actual credential principal and require positive-path evidence before approving suppression. Known hazard: `SYNC_PAT` authenticates as the maintainer/admin PAT owner; `bypass_pull_request_allowances` only describes the classic `github-actions[bot]`/app bypass list. A missing or empty bypass list is not enough to prove the `SYNC_PAT` advisory is a false positive.

If the framing doesn't match reality, the review documents the mismatch before proposing changes. "The cited symptom doesn't reproduce, but here's what's actually happening" is more useful than reviewing a fix for a non-existent problem.

## Issue Review Checklist

### 1. Problem Validation

| Check | Question | How to Verify |
|-------|----------|---------------|
| **Reproducible** | Can we reproduce? | Follow steps, test locally |
| **Version confirmed** | Occurs on latest? | Check reporter's version vs current |
| **Not a pre-existing duplicate** | Already reported (open or closed)? | `gh issue list --search "<keywords>" --state all` |
| **Not superseded by recent work** | Solved or addressed since this was posted? | `git log --since="<issue date>"` + `gh pr list --state merged --search "<keywords>"` |
| **Actual bug** | Bug or expected behavior? | Check docs, design decisions |
| **In scope** | Within project scope? | Check project goals, roadmap |

### 2. Root Cause Analysis

- Actual root cause? (Surface symptoms may hide deeper issues)
- Symptom of a larger problem? (Fixing symptoms creates tech debt)
- Why wasn't this caught earlier? (Missing tests or docs?)
- Related issues? (Batch fixes may be more efficient)

### 2.1 Decision and execution ownership (MANDATORY)

The reviewer owns the technical decision. Trace the root cause far enough to select one canonical fix, then state the exact files, pattern, tests, and disposition. Do not use contributor questions as a substitute for code/history inspection, reproduction, or architectural judgment.

- **Correct and actionable issue**: recommend issue approval even when its linked PR needs repair. Issue validity and PR readiness are separate decisions.
- **Salvageable PR in a managed repo**: choose the exact repair and route it to the active maintainer/worker path; when the interactive session is authorised to implement, repair and verify it in the same session instead of waiting on the contributor.
- **Wrong-direction or high-churn PR**: recommend a replacement implementation against the root cause and close the old PR as superseded after the replacement lands. Do not keep both paths open.
- **External repo or unwritable branch**: provide a complete patch plan in one review. Request changes only when repository authority prevents direct repair, and never end with “would you” or an open design question.
- **Questions are exceptional**: ask only for decision-critical facts unavailable from code, tests, history, logs, or documented behaviour. Taste, scope preference, and implementation choice belong to the reviewer/maintainer.

`Request Changes` is a PR state, not an issue-triage holding pattern. Never leave a valid issue in `needs-maintainer-review` merely because its current PR needs corrections.

## PR Review Checklist

### 3. Solution Evaluation

| Criterion | Questions to Ask |
|-----------|------------------|
| **Simplicity** | Simpler way? One-liner? Existing utility or stdlib? |
| **Correctness** | Fixes root cause, not just symptom? |
| **Completeness** | Edge cases and error conditions handled? |
| **Consistency** | Follows existing codebase patterns? Right abstraction level? |
| **Performance** | Introduces regressions? |
| **Maintainability** | Easy to maintain, understand, debug? |

### 4. Scope Assessment

| Red Flag | What It Indicates |
|----------|-------------------|
| Unrelated file changes | Scope creep — should be separate PR |
| Refactoring mixed with fixes | Hard to review, may hide issues |
| "While I was here" changes | Increases risk, harder to revert |
| Missing from PR description | Undocumented changes are suspicious |

### 5. Architecture Alignment

| Check | Question |
|-------|----------|
| **Patterns** | Follows existing code patterns? |
| **Dependencies** | New deps added? Are they justified? |
| **API surface** | Changes public APIs intentionally? |
| **Breaking changes** | Breaks backward compatibility? |
| **Test coverage** | Adequate tests for the right things? |

### 6. Second-Order Effects and Safety Gates

A fix that looks right in isolation can defeat invariants elsewhere. Every non-trivial review must answer these four questions explicitly — "I considered it and there are no concerns" is a valid answer, but the questions must be asked.

#### 6.1 Architectural intent

| Check | Question | Why It Matters |
|-------|----------|----------------|
| **Recent decisions** | Does this contradict an architectural change landed in the last 30 days? | A new cache can defeat a just-added invalidation; a new retry can defeat a just-added idempotency guard. Read the last 30 days of commits on affected files. |
| **Design rationale** | Why does the current behaviour exist? Is this "optimization" removing something load-bearing? | Comments and commit messages usually explain why — read them before proposing removal. |
| **Invariants** | What invariants does the current code maintain? Does the proposed change preserve them? | E.g., "content hash must invalidate on file change" — a proposed cache must honour this. |

#### 6.2 Safety gate interaction

aidevops has several safety gates. Every non-trivial change must be mapped against them:

| Gate | Trigger | Review Question |
|------|---------|-----------------|
| **Maintainer approval** (`needs-maintainer-review`, `ai-approved`, cryptographic) | Non-maintainer contributions | Does this bypass, weaken, or strengthen the approval chain? |
| **Sandbox boundary** (sandboxed agents, no-network execution) | Triage review, external content | Does this leak untrusted data into a trusted context, or vice versa? |
| **Dispatch dedup** (`dispatch-dedup-helper.sh`, origin labels, combined signal t1996) | Worker dispatch | Does this create or allow a race? |
| **Prompt injection scanner** | External-content processing | Does this accept untrusted content into a context that acts on instructions? |
| **Privacy guard** (pre-push hook, sanitiser) | Cross-repo work | Does this leak private repo names into public artifacts? |
| **Review bot gate** | PR merge | Does this lower the bar for merging external PRs? |
| **Origin labels** (`origin:interactive` / `origin:worker`) | Session provenance | Does this change behaviour based on provenance in a way that could be spoofed? |

If the change touches any gate, the review must call it out explicitly. "Does not touch any gate" is a valid answer — but the question must be asked.

For security or setup-advisory suppression proposals, require reproduction against
the fully configured positive path before approval. Identify the credential
principal being tested, the repo protection mechanism, and the bypass semantics
that apply to that principal. For `SYNC_PAT`, require evidence that a correctly
scoped admin/maintainer PAT cannot bypass the repo's actual protection settings;
do not accept missing/empty `bypass_pull_request_allowances` as sufficient proof.

#### 6.3 Symptom vs root cause

A fix that makes broken behaviour cheaper is not the same as a fix that makes the behaviour correct. These anti-patterns indicate the proposal is papering over a deeper bug:

| Signal | Indicates | Reviewer Action |
|--------|-----------|-----------------|
| Fix reduces cost without eliminating the failure | Symptom patch on broken behaviour | Identify and recommend the root-cause fix; classify the cost reduction separately |
| Fix works around an error instead of preventing it | Defensive code masking a real bug | Trace the producer and choose the prevention point |
| Fix reduces a retry/backoff counter | Possibly papering over broken retries | Determine whether attempts differ and whether any succeed; fix the repeated failure first |
| Fix adds a cache to something that re-runs every cycle | Possibly defeating an intentional re-check | Recover the re-check invariant and design invalidation that preserves it |
| Fix raises a timeout or retry budget | Possibly masking a hang or an infinite loop | Locate the stalled operation and fix or bound it before changing the budget |

It is often correct to ship both: the cheaper symptom patch AND a separate issue for the root cause. The review should make the root cause visible even when endorsing the symptom fix.

#### 6.4 Ripple effects

For every non-trivial change, enumerate the downstream code paths that will behave differently after it lands. If the list is empty, you haven't looked hard enough. Common ripple targets:

- Tests that pin the current behaviour — will they start failing, and is that the right signal?
- Documentation that describes the current behaviour — will it become wrong?
- Metrics and dashboards that depend on the current signal — will they be misleading?
- Integration points where upstream/downstream code has assumptions — will they break?
- Rollback path — can we revert this cleanly if it goes wrong?
- Related features that share state or configuration with the changed code — will they be affected?

**Red flag**: if the reviewer cannot enumerate ripple effects, continue bounded discovery. If evidence is genuinely inaccessible, identify the exact missing source and route a focused investigation; do not hand the analysis back to the author as an open question.

## Review Output Format

Heading MUST contain `## Review:` or `## Issue/PR Review:` — pulse idempotency guard uses this marker to detect existing triage reviews.

### Approval sequencing (MANDATORY)

For interactive maintainer review, complete the full checklist and post the structured review comment before presenting or running any maintainer-approval command. The order is fail-closed:

1. Verify checkout freshness and report provenance.
2. Complete duplicate, temporal, root-cause, safety, and dispatchability checks.
3. Post the review using the format below so the decision has durable evidence.
4. Only after an `Approve` recommendation is posted, state that cryptographic approval is appropriate and provide the approval command if the user requests it.

Before claiming approval is missing or asking the maintainer to approve again,
query the authoritative current state with
`approval-helper.sh verify issue <number> <owner/repo>`. Never infer approval
state from local `sudo` availability, an earlier label snapshot, or a failed
attempt to invoke the signing command.

Do not expose an approval command as the next action merely because a dispatch helper reports `needs-maintainer-review`; that gate identifies missing authority, not review quality. If review evidence is incomplete, recommend investigation rather than approval.

Assessment language describes a recommendation, not an exercised authority action. Use `Recommendation: Approve`, never `Approved`, until a trusted maintainer actually performs the approval step. Apply the same distinction in the task-tool result and user-facing summary.

For an issue with an imperfect linked PR, recommend issue approval when the problem and root-cause direction are valid, then record a separate PR disposition: `merge`, `repair`, `replace`, or `close`. Do not downgrade the issue to `Request Changes` because implementation needs work.

```markdown
## Review: Recommendation: Approve / Request Changes / Decline

### Pre-Review Context

| Check | Result |
|-------|--------|
| Pre-existing duplicates | [list issue numbers, or "None"] |
| Superseded by recent work | [list merged PRs or commits since the issue was posted, or "None"] |
| Framing matches reality | [Yes / Partial / No — with one-line evidence] |
| Current file state matches issue body references | [Yes / Drifted — cite specific drifted line numbers] |

### Issue Validation

| Check | Status | Notes |
|-------|--------|-------|
| Reproducible | Yes/No | [details] |
| Not a pre-existing duplicate | Yes/No | [related issues, if any] |
| Not superseded by recent work | Yes/No | [recent PRs/commits checked] |
| Actual bug | Yes/No | [or expected behavior?] |
| In scope | Yes/No | [project goal alignment] |

**Root Cause**: [Brief description]

### Solution Evaluation (if PR)

| Criterion | Assessment | Notes |
|-----------|------------|-------|
| Simplicity | Good/Needs Work | [simpler alternatives?] |
| Correctness | Good/Needs Work | [fixes root cause?] |
| Completeness | Good/Needs Work | [edge cases?] |
| Consistency | Good/Needs Work | [follows patterns?] |

**Alternatives**: [Recommended approach] - [why]

**Resolution plan**: [one canonical root-cause fix with files, pattern, and verification]

### Second-Order Effects

| Dimension | Finding |
|-----------|---------|
| Architectural intent | [Aligned / Contradicts / Unclear — cite recent commits if relevant] |
| Safety gates touched | [list gates from Section 6.2, or "None"] |
| Symptom vs root cause | [Root cause / Symptom patch — justify; if symptom, link or propose a root-cause issue] |
| Ripple effects | [enumerated list of downstream impacts; "None identified" requires explicit justification] |
| Rollback path | [how to revert; "trivial revert" is fine for small changes] |

### Scope & Recommendation

- Scope creep: Low/Medium/High
- Complexity: Low (`tier:simple`) / Medium (`tier:standard`) / High (`tier:thinking`)
- **Recommendation**: APPROVE / REQUEST CHANGES / DECLINE
- **PR disposition**: MERGE / REPAIR / REPLACE / CLOSE / NOT APPLICABLE — [owner and immediate next action]
- **Labels**: [e.g., `tier:simple`, `bug`, `status:available`]
- **Implementation guidance**: [key steps, test cases to add]

### Dispatchability Assessment

| Check | Status | Notes |
|-------|--------|-------|
| Brief exists | Yes/No | `todo/tasks/{id}-brief.md` |
| Brief has code blocks | Yes/No | Required for `tier:simple` |
| TODO entry with ref | Yes/No | `ref:GH#NNN` in TODO.md |
| Task ID claimed | Yes/No | via `claim-task-id.sh` |

**Tier prerequisite met**: Yes/No — [does brief quality match the recommended tier? See AGENTS.md "Briefs, Tiers, and Dispatchability"]
**What's needed to dispatch**: [list missing prerequisites, or "Ready for dispatch"]
```

**Why this section exists**: Tier recommendations without brief verification led to issues being labelled `tier:simple` when no brief with code blocks existed — making them undispatchable at that tier. This section forces the reviewer to check prerequisites before recommending a tier, whether invoked via `/review-issue-pr` or encountered mid-session. See AGENTS.md "Briefs, Tiers, and Dispatchability" for the full prerequisite chain.

## Closing the Loop with the Reporter

After a verdict is reached, the reporter must always be informed — regardless of outcome. This step is mandatory, not optional.

| Outcome | Action |
|---------|--------|
| Recommend APPROVE → internal task created | Comment on source issue: thank reporter, link to internal task/PR, set expectation on timeline |
| Recommend APPROVE → PR merged same session | Comment on source issue: thank reporter, link to merged PR, close issue |
| Recommend REQUEST CHANGES | Post the exact repair plan and route it to the responsible maintainer/worker; ask no discoverable questions and do not wait passively on the contributor |
| Recommend DECLINE | Comment explaining why (out of scope, by design, duplicate) and close issue |

**Template — issue converted to internal task:**

```markdown
Thanks for the report, @{reporter}.

Accepted. Tracked internally as #{internal_issue} and implemented in PR #{pr_number} (now merged). This will be included in the next `aidevops update`.

Closing this as resolved.
```

**Template — issue approved but pending implementation:**

```markdown
Thanks for the report, @{reporter}.

Accepted and queued for implementation as #{internal_issue}. We'll link back here when the fix ships.
```

**When to skip:** Pulse-automated triage only (headless mode without a human session). The pulse posts its own review comment; the maintainer closes the loop after approving.

## Sandboxed Pulse Relationship

> **Note (t1894):** Pulse-dispatched triage reviews use the sandboxed
> `triage-review.md` agent with no Bash/network access. This file is only used
> for interactive `/review issue`, `/review pr`, and legacy
> `/review-issue-pr` sessions. The sandboxed agent receives all GitHub data
> pre-fetched by deterministic code.
>
> **Closed by t2886 / GH#20987:** The prefetch in `pulse-ancillary-dispatch.sh` now supplies `EVIDENCE_RECENT_MERGED_PRS`, `EVIDENCE_RECENT_COMMITS_ON_CITED_FILES`, and `EVIDENCE_CITED_FILE_CONTENTS` — enabling the sandboxed `triage-review.md` agent to verify `file:line` claims and detect already-fixed issues without Bash or network access.

The Pulse path performs these operations outside this interactive workflow:

1. Fetch issue/PR: `gh issue view` or `gh pr view`
2. Read codebase files referenced in the issue body
3. Run full review checklist (validation, root cause, solution, scope)
4. Post review comment: `gh issue comment` or `gh pr comment`
5. Do NOT modify labels — pulse handles label transitions
6. Exit cleanly — no worktree, no PR, no commit

The review comment is the only output. Pulse detects it next cycle; maintainer responds with "approved", "declined", or direction. If dispatch prompt includes prior maintainer comments, address those concerns specifically.

## Common Scenarios

### Issue is Not a Bug

```markdown
After investigation, this is expected behavior:
- [Why this is by design]
- [Link to docs]

To request different behavior, open a feature request. Closing as "not a bug" — reopen with additional context if needed.
```

### PR Fixes Symptom, Not Cause

```markdown
The fix works for the reported case, but the root cause should be addressed:
- **Current approach**: [what the PR does]
- **Root cause**: [underlying issue]
- **Suggested approach**: [better solution]

**Disposition: REPAIR** — the maintainer/worker should replace the symptom patch with the suggested root-cause change and run [verification].
```

### PR Has Scope Creep

```markdown
Core fix looks good, but some changes should be separate PRs:
- **In scope** (keep): [change 1], [change 2]
- **Out of scope** (separate PR): [change 3] — [reason]

**Disposition: REPAIR** — retain the in-scope diff and remove [change 3]. File a follow-up only if [change 3] remains independently necessary.
```

### Better Alternative Exists

```markdown
There's a simpler approach:
- **Your approach**: [summary]
- **Alternative**: [simpler solution] — preferable because [reason]

**Disposition: REPAIR** — implement the alternative in [files], preserve [invariant], and verify with [commands].
```

### Issue Already Superseded by Recent Work

```markdown
Thanks for the report, @{reporter}. This is no longer reproducible after #{recent_pr} ({recent_pr_title}), which landed on {date} and addresses the same root cause. I verified by {verification}.

Closing as superseded. If you still see this on {latest_version}, please reopen with a fresh reproduction against the current code.
```

### Fix Addresses Symptom, Root Cause Lives Elsewhere

```markdown
The proposed fix works for the reported symptom, but the root cause is {root_cause_description}, which would still produce failures in {other_affected_paths} even after this lands.

**Disposition: REPLACE** — fix the root cause in {correct_location}, following {file:line}; the proposed symptom change then becomes unnecessary. Ship both only when verified constraints make the root-cause fix infeasible, and record that evidence in the review.
```

### Fix Defeats a Recent Architectural Decision

```markdown
The proposed change conflicts with #{recent_decision_pr} ({title}), which intentionally {what_it_added}. The fix proposed here would defeat that invariant because {mechanism}.

**Disposition: REPLACE** — close this implementation path and produce a fix that preserves the invariant from #{recent_decision_pr}. Reopen the design decision separately only when current evidence falsifies its rationale.
```

## CLI Commands

```bash
gh issue view 123 --json title,body,labels,author,createdAt,comments
gh issue list --search "keyword" --state all
gh pr view 456 --json title,body,files,additions,deletions,author
gh pr diff 456 --stat
gh pr checks 456
gh pr review 456 --comment --body-file /absolute/path/to/review.md
gh pr review 456 --request-changes --body-file /absolute/path/to/review.md
gh pr review 456 --approve --body-file /absolute/path/to/review.md
gh issue comment 123 --body-file /absolute/path/to/closing-comment.md && gh issue close 123
rg "relevant_function" --type js --type ts --type py --type sh
git log --oneline -20 -- path/to/affected/file
```

## Labels for Triage

| Label | Meaning |
|-------|---------|
| `needs-reproduction` | Cannot reproduce, need more info |
| `needs-investigation` | Valid issue, needs root cause analysis |
| `good-first-issue` | Simple fix, good for new contributors |
| `help-wanted` | We'd welcome a PR for this |
| `wontfix` | By design or out of scope |
| `duplicate` | Already reported |
| `invalid` | Not a real issue |

## Related Workflows

| Workflow | When to Use |
|----------|-------------|
| `workflows/pr.md` | After approving, run full quality checks |
| `tools/code-review/code-standards.md` | Evaluating code quality |
| `/linters-local` | Run before final approval |
| `tools/git/github-cli.md` | GitHub CLI reference |
