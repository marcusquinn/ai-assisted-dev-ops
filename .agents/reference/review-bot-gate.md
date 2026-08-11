<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Review Bot Add-on Policy (t1382, GH#3827, GH#17541)

**Permanent default:** required project CI controls merge readiness. Code-quality
add-ons such as CodeRabbit are advisory: absent, pending, unavailable,
rate-limited, or late results never delay a trusted maintainer-controlled PR.
Late feedback is swept after merge and filed as worker-ready follow-up issues.

Gemini Code Assist's retired GitHub review integration is legacy-only. The
framework still recognizes its historical comments, reviews, and threads, but
does not advertise it as active, accept new per-tool policy, or let stale
`gemini-code-assist` wait/strict overrides block current merges. Use
`aidevops review-gate <repo> --tool gemini-code-assist unset` to remove each
legacy field. The retained identity filters make a future restoration reversible.

Repositories with an exceptional sensitivity requirement may explicitly opt into
review-before-merge with `review_gate.completion_behavior: strict`. Strict is
never the framework default. Mirror strict CI intent with the repository Actions
variable `AIDEVOPS_REVIEW_GATE_COMPLETION_BEHAVIOR=strict`. The GH#17671
external-contributor trust boundary remains fail-closed independently.

## Enforcement Layers

1. **CI**: `.github/workflows/review-bot-gate.yml` may remain a required compatibility
   status, but default missing/late review emits `PASS_ADVISORY` and succeeds. It
   blocks for missing completion only under explicit strict policy or the external
   trust boundary.
2. **Pulse merge path**: `review-bot-gate-helper.sh status-json` supplies typed,
   exact-head evidence. `PASS_ADVISORY` is valid only for trusted authors.
3. **Worker merge path**: `full-loop-helper.sh merge` accepts the same default
   advisory outcome after required CI succeeds.
4. **Branch protection**: a required `review-bot-gate` context is compatible with
   this policy because it reports success for advisory outcomes.

All layers share the same `review-bot-gate-helper.sh` implementation — the settlement
check and completion behaviour are consistent across CI and in-agent merge paths (GH#20493).

## Merge Commands

| Context | Command | Gate |
|---------|---------|------|
| Worker (full-loop) | `full-loop-helper.sh merge <PR> [REPO]` | Advisory by default; strict opt-in blocks |
| Pulse (deterministic) | Internal `_merge_ready_prs_for_repo` | Typed advisory/strict evidence |
| Manual (interactive) | `review-bot-gate-helper.sh check <PR> [REPO]` | Read available feedback without default delay |

Workers MUST use `full-loop-helper.sh merge` — direct `gh pr merge` bypasses the gate (GH#17541).

## Superseded CodeRabbit change requests

The full-loop readiness gate may dismiss a stale CodeRabbit `CHANGES_REQUESTED`
review only when every active blocker is the exact `coderabbitai[bot]` identity,
each blocking review names a non-current commit, and the trusted bot subsequently
posts both the addressed marker and the deterministic “no blocking findings”
message for the exact current SHA. The current SHA must also have a terminal-
success `CodeRabbit` status context from a trusted PR author.

The helper reduces each reviewer's history to their latest state-changing review,
re-reads the head immediately before each dismissal, and re-reads the aggregate
review decision afterward. The merge transport checks the exact-head aggregate
again immediately before mutation. Human or mixed reviewers, current-head
requests, head drift, malformed evidence, missing/failed/pending status, and
untrusted authors remain blocking. This is separate from the maintainer-applied
`coderabbit-nits-ok` cosmetic override; the shared helper independently verifies
that label while reusing reviewer enumeration and dismissal mechanics.

## Workflow

- Before merging, run `review-bot-gate-helper.sh check <PR_NUMBER>` to collect
  available feedback. Default no-response output is `PASS_ADVISORY`, not `WAITING`.
- `WAITING` means the repository explicitly selected strict/wait behavior or the
  external-contributor trust boundary applies.
- `skip-review-gate` remains an auditable internal exception for strict setups;
  default advisory repositories do not need it.
- ALWAYS read bot reviews that are available before merging. Address critical/security findings; note non-critical suggestions for follow-up.
- `PASS_ADVISORY` means no completed add-on review was required under the permanent
  default. `PASS_RATE_LIMITED` is the narrower true-rate-limit outcome. Both
  delegate late feedback to the post-merge scanner for trusted exact-head PRs.
  API-exhausted runs do not retry immediately. External/unknown authors and
  explicit `wait` or `strict` policies remain fail-closed.
- When many PRs are rate-limited simultaneously, use `request-retry` on the highest-priority PRs first. Stagger retries to avoid re-triggering rate limits.

## Additive suggestion decision tree

When a review bot comments with a suggestion that isn't a correctness issue in the PR's own code:

1. **Is the suggestion a correctness fix for code introduced by this PR?**
   - Yes → expand the PR, add a commit, re-request review.
   - No → go to 2.

2. **Is the suggestion adding coverage, generality, new behaviour, or cosmetic improvements?**
   - Yes → file as follow-up task with `ref:GH#<current-PR>`.
   - No → skip (may be a nit; see the `coderabbit-nits-ok` rule in AGENTS.md "Review Bot Gate").

3. **File follow-up via:**
   - Claim task ID (`claim-task-id.sh`).
   - Write brief in the current planning worktree.
   - File issue with worker-ready body + `Source: review comment on PR #<N> by @<bot>` citation.

### Example

PR #19712 (t2209) Gemini review suggested extending the duplicate-ID regex to cover declined tasks and routine IDs. This is additive (broader coverage), not a correctness fix for the PR's shipped behaviour. Filed as t2222 / #19723.

See also: AGENTS.md "Review Bot Gate (t1382)" for the authoritative rule and rationale.

The same follow-up pattern applies to advisory CI: slow E2E, visual, performance,
or integration checks that are not required for the target branch should file
worker-ready follow-up tasks unless they prove a defect introduced by the PR.
See `ci-gate-policy.md`.

## Composition with auto-merge paths

The review add-on check runs after the `origin:interactive` (t2411) and
`origin:worker` worker-briefed (t2449) gates. This means:

- **Default trusted PRs**: `PASS_ADVISORY` clears the add-on check once required
  project CI and independent trust gates pass; bot response time is irrelevant.
- **Strict repositories**: `completion_behavior: strict` requires settled review
  evidence. `min_edit_lag_seconds` still protects CodeRabbit's two-phase pattern.
- **Repository-generated Issue Sync PRs**: GitHub reports the official Actions bot
  as `CONTRIBUTOR`. The reusable CI gate and shared review helper normalize it as
  internal only when the immutable bot ID/type, same-repository head and base,
  deterministic `aidevops/issue-sync-todo` branch, and generated body marker all
  match. For `issue_comment` events that omit head/base metadata, CI asks the
  shared helper to classify one live REST pull payload. This keeps CI,
  interactive merge, and Pulse decisions aligned. Any missing or mismatched
  field remains external and fail-closed.
- **External contributors**: advisory, rate-limit, and skip outcomes remain
  fail-closed; completed review evidence is required in addition to independent
  maintainer/cryptographic authority.

The helper is still evaluated and audited on every merge path; advisory is an
explicit successful policy outcome, not a bypass. Draft, `hold-for-review`, human
`CHANGES_REQUESTED`, required CI, exact-head, and maintainer gates remain independent.
