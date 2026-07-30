---
description: Iterate on PR until ready for upstream hand-off, approved, or merged
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Monitor and iterate on a PR until it is ready for external upstream hand-off or, with maintainer-equivalent target-repository access, approved/merged.

## Usage

```bash
/pr-loop [--pr N] [--wait-for-ci] [--max-iterations N] [--no-auto-trigger]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--pr <n>` | auto | PR number (auto-detects from current branch) |
| `--wait-for-ci` | false | Wait for CI before checking review status |
| `--max-iterations <n>` | 10 | Max check iterations |
| `--no-auto-trigger` | false | Disable auto re-review for stale reviews |

## Workflow

Each iteration checks: CI Status → Review Add-on Status (t1382) → Review Status → Merge/Hand-off Readiness.

Invocation is explicit finalisation consent. Classify permission against the PR's target/upstream repository: `admin`, `maintain`, or `write` is maintainer-equivalent on GitHub; lower or ambiguous permission is external. If the PR is draft and local/session evidence says it is ready, run `gh pr ready <PR>`; otherwise report the blocker and leave it draft. Maintainer-equivalent loops may continue to merge polling (with the normal auto-merge opt-in for `origin:interactive`). External loops never merge: once the exact ready head has terminal-success required CI and actionable review findings are resolved, hand the open PR to upstream maintainers and stop. Pending upstream human approval is a successful hand-off state, not an indefinite polling condition.

**On issues:** CI failures → report and wait. Changes requested → verify, address valid feedback. Stale review → auto-trigger re-review (unless `--no-auto-trigger`).

**COMMENTED reviews:** Some review add-ons post as `COMMENTED` rather than `CHANGES_REQUESTED`, so `reviewDecision` stays `NONE`. The loop detects unresolved review threads and surfaces them, including historical Gemini Code Assist threads.

### Review Add-on Policy (t1382)

Required project CI controls merge readiness. Collect any available AI review
feedback, but under the permanent default do not wait for an add-on to respond.
Only explicit `completion_behavior: strict` or the external-contributor trust
boundary requires completed review evidence.

```bash
RESULT=$(~/.aidevops/agents/scripts/review-bot-gate-helper.sh check "$PR_NUMBER" "$REPO")
# Returns: PASS, PASS_ADVISORY, PASS_RATE_LIMITED, WAITING, or SKIP
```

| Result | Action |
|--------|--------|
| `PASS_ADVISORY` | Proceed after required CI; late add-on feedback becomes post-merge follow-up work. |
| `PASS_RATE_LIMITED` | Proceed for a trusted PR under pass-on-rate-limit policy; sweep late feedback. |
| `WAITING` | Poll only because strict policy or the external trust boundary explicitly requires completed review. |
| `PASS` | Read bot reviews; address critical/security findings before merge. Non-critical → follow-up. |
| `SKIP` | Trusted internal PR has `skip-review-gate` label — proceed. |

AI review verification rules: `reference/session.md` "Bot Reviewer Feedback" and `AGENTS.md` "AI Suggestion Verification".

### Gate Failure Playbook

When `Maintainer Review & Assignee Gate` fails, the `maintainer-gate` status-context description and the auto-posted gate comment on the PR say why. Map the reason to the fix path below — do not re-read `maintainer-gate.yml` to re-derive it.

| Failure reason (observable in gate output) | Fix path | Who runs it |
|---|---|---|
| `Issue #N has needs-maintainer-review label` | `sudo aidevops approve issue N` — cryptographic, posts signed comment, removes label | **User only** — requires sudo + root-protected SSH key; LLM cannot forge |
| `Issue #N has no assignee` | `gh issue edit N --add-assignee USER` | LLM or user |
| `PR #N has needs-maintainer-review label` | `sudo aidevops approve pr N` | **User only** |
| `Title-based issue lookup failed` | Either fix PR title to `tNNN: ...` format or add `Closes #NNN` to PR body | LLM |

After user-only fixes, the required `Maintainer Review & Assignee Gate` CheckRun auto-refreshes via the `retrigger-pr-checks` job in `maintainer-gate.yml` (t2018). That job observes issue label/assignee changes and calls the `rerun-failed-jobs` REST API endpoint to re-run the failed `check-pr` job. Expect SUCCESS within ~20 seconds of the approval comment being posted (approximate — not explicitly time-bound in the code); the PR becomes mergeable without manual `gh run rerun`.

If the required CheckRun does NOT refresh within ~60 seconds after an approval, fall back to manual: `gh run rerun <run_id> --failed` against the latest `Maintainer Gate` workflow run for the PR's HEAD SHA.

**Hard rule:** NEVER remove `needs-maintainer-review` by direct `gh issue edit --remove-label`. The `protect-labels` job in `maintainer-gate.yml` re-applies it ~7 seconds later (webhook trigger delay) unless a `<!-- aidevops-signed-approval -->` comment exists on the issue. Removing the label without the signed comment is a guaranteed-to-fail path that wastes tool calls.

## Completion Promises

| Outcome | Promise |
|---------|---------|
| External PR ready for upstream maintainers | `<promise>PR_READY_EXTERNAL</promise>` |
| PR approved | `<promise>PR_APPROVED</promise>` |
| PR merged | `<promise>PR_MERGED</promise>` |
| Max iterations reached | Exit with status report |

## Timing

| Service | Initial Wait | Poll Interval |
|---------|--------------|---------------|
| Fast (CodeFactor, Version) | 10s | 5s |
| Medium (SonarCloud, Codacy, Qlty) | 60s | 15s |
| Slow (CodeRabbit) | 120s | 30s |

## Recovery

State: `.agents/loop-state/quality-loop.local.state`. Blockers: CI running (wait), review pending (ping reviewer), failing checks (fix). Resume: `/pr review` (single cycle) or `/pr-loop` (restart).

```bash
gh pr view --json state,reviewDecision,statusCheckRollup
```

## Related

| Command | Purpose |
|---------|---------|
| `/pr review` | Single PR review cycle |
| `/pr create` | Create PR with pre-checks |
| `/preflight-loop` | Iterative preflight until passing |
| `/postflight-loop` | Monitor release health |
| `/full-loop` | Complete development cycle |
