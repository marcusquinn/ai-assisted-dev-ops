# Dispatch-Blocker Vocabulary (t2754)

This is the **single source of truth** for labels, states, and conditions that block automated worker dispatch or auto-merge. Maintained here to support Phase 4 of [#20402](https://github.com/marcusquinn/aidevops/issues/20402) (inverting the dispatch default from opt-in to opt-out).

For the `#auto-dispatch` positive opt-in criteria, see `workflows/plans.md` "Auto-Dispatch Tagging". For enforcement architecture, see `reference/auto-dispatch.md`.

---

## Label-Level Blockers

Applied to GitHub issues. The pulse checks these before spawning a worker.

### Unconditional Dispatch Blocks (no assignee required)

| Label | Enforced by | Rationale |
|-------|-------------|-----------|
| `parent-task` | `dispatch-dedup-helper.sh` `_is_assigned_check_parent_task` | Epics/trackers — children implement, not this issue. Permanent until explicitly removed; review-label normalization cannot override it (t2211). |
| `meta` | Same as `parent-task` — treated as an alias | Alternative spelling of `parent-task`. |
| `publication:pending` | `pulse-wrapper-cycle-gates.sh`, `dispatch-dedup-helper.sh` `_is_assigned_check_publication_pending`, and `pulse-dispatch-core.sh` `_has_publication_pending_label` | Canonical TODO/brief publication is still pending. It blocks candidate discovery, dedup, and direct dispatch until exact default-branch reconciliation validates the task/issue mapping and removes it last. |
| `no-auto-dispatch` | `dispatch-dedup-helper.sh` `_is_assigned_check_no_auto_dispatch` (t2832), `issue-sync-lib.sh`, `interactive-session-helper.sh` lockdown | Durable explicit manual hold for issues. Blocks dispatch (`NO_AUTO_DISPATCH_BLOCKED`), ordinary/bulk/pulse enrich, and decomposition. Routine interactive ownership uses `status:in-review` + assignment instead. The explicit maintainer-only `issue-sync-helper.sh sync-body tNNN` exception can update only the authoritative body while continuously verifying the hold and all metadata; it cannot dispatch, change labels, or bypass a genuine claim. Applied by `interactive-session-helper.sh lockdown`. |
| `hold-for-review` | `dispatch-dedup-helper.sh` `_is_assigned_check_hold_for_review`, `issue-sync-lib.sh`; PR merge checks below | Confirmed unresolved internal, manual, policy, or security review hold backed by explicit durable decision evidence. On issues, same dispatch-block intent as `no-auto-dispatch` (`HOLD_FOR_REVIEW_BLOCKED` signal). On PRs, blocks auto-merge until a maintainer removes the label. It does not represent missing author authority and needs no cryptographic self-approval. Label actor, timing, or missing automation provenance alone is insufficient. Scanner availability, temporary-file, input, and execution failures are infrastructure retries and must not apply this label. |
| `needs-maintainer-review` | `pulse-nmr-approval.sh` `auto_approve_maintainer_issues`, external-author workflows | External-author authority gate. Authors without verified write authority require maintainer cryptographic approval (`sudo aidevops approve issue <N>`) before dispatch. Write-authorized authors never self-approve: explicit durable human-decision evidence normalizes to `hold-for-review`, machine-breaker evidence becomes `status:blocked`, and unreasoned residue is removed without replacing active `status:*`. Unknown authority or incomplete required evidence fails closed by retaining NMR unchanged. |
| `needs-maintainer-permissions` | `worker-permission-helper.sh`, `dispatch-dedup-helper.sh`, `pulse-dispatch-core.sh`, candidate filters | Worker paused after requesting a capability outside its sandbox. Only the request-specific signed permission command clears this label; dispatch also verifies historical applications against the matching unexpired grant, so removing the label alone cannot bypass the hold. It is distinct from scope/trust approval. |
| `needs-credentials` | `label-sync-helper.sh` SYSTEM_LABELS | Task requires credentials, API keys, or account access — cannot be completed by a headless worker autonomously. Add when the TODO entry has `#no-auto-dispatch` due to credential dependency. |
| `persistent` | `pulse-issue-reconcile.sh` | Monitoring/tracking issue — must not be dispatched as a code task. |
| `supervisor` | `pulse-issue-reconcile.sh` | Supervisor health dashboard — pulse-managed, not a dispatch target. |
| `contributor` | `pulse-issue-reconcile.sh` | Contributor health dashboard — pulse-managed, not a dispatch target. |
| `quality-review` | `pulse-issue-reconcile.sh` | Daily quality review tracker — pulse-managed. |
| `routine-tracking` | `pulse-issue-reconcile.sh` | Routine execution tracking — pulse skips these unconditionally. |
| `status:blocked` | `dispatch-dedup-helper.sh`, dependency and circuit-breaker recovery | Machine-recoverable structural block: incomplete dependencies, exhausted retry/cost limits, or infrastructure repair. Restore `status:available` only after the blocker is verified resolved. |

Permission grants are limited to exact-pattern `bash` and `external_directory` requests, bound to the issue, request digest, worker session, branch, and worktree hash, and expire after four hours. Action-only permissions and credential-bearing or unbounded paths remain non-grantable.

The permission broker, approval flow, and grant verifier append blocker-state
transitions to `~/.aidevops/logs/worker-progress-blockers.jsonl`. Diagnose the
label and its exact local reason with `pulse-diagnose-helper.sh issue <N> --repo
<owner/repo>`; removing the label does not alter or bypass grant verification.

### Conditional Dispatch Blocks (require active claim state)

These labels DO NOT block dispatch on their own. They become blockers only when combined with an active claim signal — see "Claim-State Blockers" below.

| Label | Block condition |
|-------|----------------|
| `origin:interactive` + any assignee | GH#18352: interactive session claimed this issue — blocks dispatch until `interactive-session-helper.sh release` |
| `status:queued` / `status:in-progress` / `status:in-review` / `status:claimed` + non-passive assignee | Active lifecycle state with owner — safe to dispatch only when `_has_active_claim` returns false |

### PR Auto-Merge Blockers (block merge, not dispatch)

Applied to pull requests. The merge pass checks these before merging.

| Label | Enforced by | Rationale |
|-------|-------------|-----------|
| `hold-for-review` | `pulse-merge.sh` `_check_interactive_pr_gates` (t2411), `_check_pr_merge_gates` (t2449) | Opt-out of auto-merge — holds PR for explicit maintainer review. Same label also blocks issue dispatch when applied to issues. |
| Draft PR status | `pulse-merge.sh` | Draft PRs are never auto-merged. |
| CHANGES_REQUESTED review | `review-bot-gate-helper.sh` | Unresolved review blocks merge. Exception: `coderabbit-nits-ok` label dismisses CodeRabbit-only CHANGES_REQUESTED (t2179). |

---

## Claim-State Blockers

These are not labels — they are runtime state signals checked by `dispatch-dedup-helper.sh is-assigned`.

| Signal | Exit code | Meaning |
|--------|-----------|---------|
| `PARENT_TASK_BLOCKED` | 0 (blocked) | `parent-task` / `meta` label — unconditional block |
| `PUBLICATION_PENDING_BLOCKED` | 0 (blocked) | `publication:pending` label — canonical planning publication is incomplete |
| `NO_AUTO_DISPATCH_BLOCKED` | 0 (blocked) | `no-auto-dispatch` label — unconditional block (t2832) |
| `HOLD_FOR_REVIEW_BLOCKED` | 0 (blocked) | `hold-for-review` label — unconditional issue dispatch block and PR auto-merge hold |
| `ASSIGNED: issue #N in repo` | 0 (blocked) | Active assignee with blocking claim state |
| `GUARD_UNCERTAIN` | 0 (blocked, fail-closed) | API or jq failure — dispatch refused to avoid collision |
| No assignees | 1 (allow dispatch) | Safe to dispatch |
| Passive assignees only (owner/maintainer without active claim) | 1 (allow dispatch) | Owner bookkeeping — not a live claim |

Stale assignment recovery: if the blocking assignee has no live worker process AND the last dispatch comment is >1h old AND no progress in the last hour, `_is_stale_assignment` clears the block and allows re-dispatch (GH#15060).

---

## Validator-State Blockers

Checked by `pre-dispatch-validator-helper.sh` and the pre-dispatch eligibility gate (t2424) before spawning a worker.

| Condition | Exit | Enforced by |
|-----------|------|-------------|
| Issue already CLOSED | 10 (close + skip) | `pre-dispatch-validator-helper.sh` |
| `status:done` / `status:resolved` label | 10 (skip) | Pre-dispatch eligibility gate |
| Linked PR merged in last 5 min | 10 (skip) | Pre-dispatch eligibility gate |
| Cost circuit breaker fired (t2007) | 0 (blocked) | `dispatch-dedup-helper.sh` `_is_assigned_check_cost_budget` |
| Hydration window active <30s (t2436) | 0 (blocked) | `dispatch-dedup-helper.sh` `_is_assigned_check_hydration_window` |
| GraphQL budget < 30% (t2690) | pause all dispatch | Pulse circuit breaker in `pulse-wrapper.sh` |

---

## Adding a New Blocker

To add a new label-level dispatch blocker:

1. **Register in `label-sync-helper.sh`** — add to `SYSTEM_LABELS` array with a description starting "Opt-out:" or "Block:". The `cmd_sync` command will create it on all admin repos.
2. **Protect in `issue-sync-helper.sh`** — add to `_is_protected_label()` exact-match list so the enrich path cannot strip it.
3. **Enforce in `dispatch-dedup-helper.sh`** (if unconditional) — add label check to the pre-assignee block, before `_is_assigned_compute_blocking`, plus candidate and direct-dispatch guards when the label prevents launch. Or for conditional blockers, update `_has_active_claim`.
4. **Document here** — add a row to the relevant table above with the enforcement point.

---

## Cross-References

- `reference/auto-dispatch.md` — combined signal rule (`(active status label) AND (non-self assignee)`) and full dispatch lifecycle
- `reference/auto-merge.md` — auto-merge timing rules (t2411, t2449) and external-author NMR semantics
- `reference/parent-task-lifecycle.md` — `parent-task` label lifecycle in detail (t2442)
- `reference/worker-diagnostics.md` — pre-dispatch eligibility gate (t2424) and circuit breakers
- `.agents/scripts/dispatch-dedup-helper.sh` — `is-assigned` command and all layer checks
- `.agents/scripts/label-sync-helper.sh` — `SYSTEM_LABELS` canonical registry + `cmd_sync`
- `.agents/scripts/issue-sync-helper.sh` — `_is_protected_label()` enrich-survivor set
- `.agents/scripts/pulse-merge.sh` — `_check_interactive_pr_gates` and `_check_pr_merge_gates`
