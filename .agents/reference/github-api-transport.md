<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# GitHub API transport and freshness

These controls reduce unnecessary work while preserving fresh action-boundary
checks. They do not establish a production savings percentage; use the matched
windows and completeness gates in [the efficiency benchmark](github-api-efficiency.md).

## Correct queries before more caching

- CLI `--state closed` means **closed but unmerged**. REST `/pulls?state=closed`
  contains merged and unmerged PRs. The REST adapter filters before satisfying
  `--limit`, so a closed-only request can scan a large merged history. Merged-PR
  reconciliation requests `--state merged` and still validates `mergedAt`.
- Healthy closed-only list reads prefer native server-side filtering rather
  than unconditional REST-first. Explicit/low-GraphQL REST fallback retains
  equivalent semantics. This is a query-shape decision, not an assumed quota
  balance or a relaxation of JSON-field equivalence.
- Peer monitoring reuses per-repository observations instead of three requests
  per peer. Preserve the upstream dispatch-ownership, device-freshness and
  unknown-observation contract: creation origin is not current ownership.
  Invalid time configuration or failed collection cannot become a zero-work
  observation or overwrite the previous state and dispatch overrides.
- Dirty-worktree checks request comments updated within the active hold window,
  with a boundary margin, and paginate all relevant pages. They do not inspect
  only the first hundred old comments. Failed/malformed evidence is a hold, not
  a clear result. A later resolution is determined by timestamps, not response
  order; ambiguous timestamps do not grant resume or clearance.

No additional persistent comment or historical-PR body cache is required by
these changes. Existing TTLs are not lengthened, future-dated discovery cache
entries miss, and discovery data never replaces final lock/trust/head/check
verification.

## Common native boundary

The PATH shim applies the shared cooldown before ordinary native requests,
including raw agent commands. Wrapper-admitted boot/recovery reads are not
charged twice, but cooldown is rechecked immediately before dispatch. Local-only
commands remain usable without fabricated HTTP attempts. `gh search` is a REST
search operation, not a GraphQL query.

Native execution errors without a usable HTTP response stop alternate
transports. A successful HTTP response which cannot reproduce a requested local
projection retains the existing semantically equivalent read fallback. Native
exit `125` is not an unsupported-shape signal after execution: an explicit
handled receipt prevents replaying the request.

## Bounded authenticated REST reads

`gh-transport-governor.py` and `gh_transport_budget.py` admit supported
non-interactive authenticated `GET` shapes using private local SQLite state.
They inspect included final-response headers without enabling `GH_DEBUG` and
never cache a response body. Explicit REST pagination uses the same boundary
per page. The credential fingerprint and native request use the same pinned
child environment; credentials are never exported to a long-lived parent.

- Resource-owned response headers establish remaining quota. `/rate_limit`
  JSON is not treated as an admission balance.
- In-flight reservations are atomic, with a bounded local concurrency ceiling
  and protected reserve. Brief local contention waits without sending HTTP;
  quota/reset stops do not spin or retry against another transport.
- Missing/stale observations permit one serialized observation, not an assumed
  new allowance. Unknown execution remains debt until a later response from
  the same credential covers it. Out-of-order responses cannot restore spent
  quota inside a live reset window.
- PID birth identity protects recovery. A credential changing owner
  configuration cannot obtain an independent second budget: live scope state
  and reservations are merged conservatively.
- `AIDEVOPS_GH_QUOTA_OWNER` may identify a trusted user/installation owner.
  Multiple PATs for that owner share an allowance. Unresolved callers share a
  conservative host scope. This is local coordination, **not distributed fleet
  admission**. Permission-scoped cache identity remains a separate concern.

Mutations, streamed inputs, inherited file descriptors, anonymous requests,
GraphQL, interactive terminals and unsupported CLI shapes retain native
execution plus common cooldown. The adapter must not break an unlinked signed
body's inherited descriptor or turn injected headers into application data.

Normal observations describe a native invocation and its final response; do not
claim complete wire-level accounting for hidden native redirects/retries.
Explicit `AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1` retains the existing multi-response
recorder and serialization instead of this read adapter. Consequently, an
exact-capture query-efficiency window is not alone proof of the new admission
controller's normal-mode latency. Retain unknowns and require profile-appropriate
evidence before tuning defaults or claiming an integrated benchmark pass.

Rollback: `AIDEVOPS_GH_TRANSPORT_GOVERNOR_DISABLE=1` disables the read adapter,
not shared cooldown. It does not authorize bypassing signatures or safety gates.

## Durable PR wake hints

`pulse-merge-dirty-queue.py` stores repo/PR identifiers, generation, wake and
lease metadata under a private state directory. It stores no PR/check/review
contents and grants no merge authority.

- Signed receiver events invalidate first. A failed invalidation remains
  latched for the whole delivery; a later successful invalidation cannot erase
  that failure.
- Repeated wakes coalesce, with a short debounce. Event and ordinary Pulse
  processing share per-PR logical leases. No lock descriptor is inherited by
  Git hooks. A live owner is not displaced merely because time elapsed.
- Acknowledgement is generation-fenced. An event arriving during processing
  survives the older completion. Unhandled hints remain available to polling.
- Dirty poll candidates refresh initial PR metadata. The targeted event path
  fetches once and lends its owned context to the existing pipeline; it does
  not fetch the same initial object twice. All final safety gates still run.
- Hints only break ties inside existing readiness categories. They do not move
  a blocked PR ahead of merge-ready work, skip repositories, or replace polling.
- Capacity is bounded at 4096 rows; unleased hints expire after seven days.
  Expiry removes scheduling hints, not GitHub work. Queue failure disables the
  event fast path while the authoritative polling path remains available.

Runtime entrypoints enable `AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_ENABLED` by default;
explicit `0` is the rollback switch. Sourcing merge helpers alone does not opt
in. Before the queue is present, ordinary polling creates no queue state.
Dry-run processing does not claim or acknowledge hints. The private directory
can be isolated with `AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_DIR`.

**Do not slow the polling backstop without verified webhook coverage.** A
configured listener is not proof that GitHub, the tunnel, all needed events and
the receiver are working. Missing secret/configuration retains polling;
configure secrets with `aidevops secret set GITHUB_WEBHOOK_SECRET`, never in chat.

## Focused verification

```bash
python3 .agents/scripts/tests/test-gh-transport-budget.py
bash .agents/scripts/tests/test-gh-shim.sh
bash .agents/scripts/tests/test-gh-api-instrument.sh
bash .agents/scripts/tests/test-gh-wrapper-rest-fallback.sh
bash .agents/scripts/tests/test-pulse-issue-reconcile.sh
bash tests/test-peer-productivity-monitor.sh
bash .agents/scripts/tests/test-pulse-dispatch-dirty-worktree-marker.sh
python3 .agents/scripts/tests/test-pulse-merge-dirty-queue.py
python3 .agents/scripts/tests/test-pulse-merge-webhook-invalidation.py
bash .agents/scripts/tests/test-pulse-merge-pr-backlog-priority.sh
bash .agents/scripts/tests/test-pulse-merge-pr-json-fields.sh
bash .agents/scripts/tests/test-pulse-merge-preflight-snapshot.sh
```
