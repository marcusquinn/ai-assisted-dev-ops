<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Freshness-safe GitHub API efficiency

## Objective and authority

Implement the reviewed GitHub API efficiency improvements in the primary
interactive session through verified PR, merge, and explicitly authorised
release. No background implementation workers. Reduce requests per completed
unit of work, not merely requests per hour by suppressing useful work.

## Evidence and constraints

The reviewed observation window recorded 148,398 transport attempts, including
126,595 REST-core attempts and 17,190 unknown quota costs. These are not exact
HTTP totals or proven single-principal usage. A live `/rate_limit` projection
disagreed with the headers of an actual REST request; resource-owned response
headers take precedence. Existing conditional snapshots, single-flight, check
caches and verified webhook invalidation must be reused rather than duplicated.

Freshness invariants:

- Unknown, failed, incomplete, truncated or out-of-order state is never an empty
  result, a permission grant, a satisfied dependency or a successful check.
- Discovery snapshots are not final action-boundary attestations. Keep fresh
  lock/trust/dependency/check/head verification before dispatch or merge.
- Permission-scoped cache identity is distinct from shared quota-owner identity.
  Token rotation must neither grant a fresh user allowance nor cross visibility.
- Honour primary resets and secondary Retry-After; an error must not trigger an
  alternate transport or a mutation retry whose outcome is unknown.
- Event-driven fast paths retain bounded authoritative polling recovery. Event
  absence is not evidence of freshness without verified coverage and a repair
  deadline. Do not lengthen safety-sensitive cache TTLs.
- Preserve CLI stdout, exit status, signatures, auth policy and pagination
  completeness. Raw requests and wrapper requests share transport controls
  without duplicate reservation or recursive probes.
- Never claim measured quota savings from unknown counters. Keep benchmark
  completeness and correctness gates; separate live diagnostics from immutable
  completed-cycle evidence.

## Implementation units

All units are owned by the primary session. Implementation concurrency is one;
independent bounded research/review may use at most two read-only children.

| Unit | Scope / owning files | Dependencies | Tier | Verification |
|---|---|---|---|---|
| API-01 | Central transport cooldown, scoped authoritative admission and response reconciliation: `gh`, `gh-native-transport-lib.sh`, `gh-quota-attribution-lib.sh`, shared request/cooldown state | None | thinking | Existing shim/cooldown/request-state suites plus focused fake-transport checks for raw-call suppression, scope isolation, stale observations and concurrent admission |
| API-02 | Idempotent conversation locks: `pulse-dispatch-core.sh`, `approval-helper.sh` | None | standard | Existing conversation-lock and approval suites; unchanged locked issue makes no mutation while launch still verifies the lock |
| API-03 | Bounded shared reconciliation/comment/peer projections: `pulse-issue-reconcile.sh`, `pulse-dispatch-lib.sh`, `peer-productivity-monitor.sh` | API-01 | thinking | Existing suites and request-count assertions; failure/partial data cannot authorise action or replace prior valid state |
| API-04 | Durable event-driven fast scheduling: webhook receiver/server, merge routine/pass | API-01 | thinking | Existing webhook/replay/merge suites; duplicate coalescing, concurrent new event, missing coverage, stale entries and polling repair |
| API-05 | Cost-aware semantically equivalent read routing using existing projections/fallbacks | API-01, API-03 | thinking | Existing REST equivalence suites; cached/no-op path and bounded query cost; no GraphQL-only fields silently dropped |
| API-06 | Attribution and publication ownership: transport instrumentation, batch prefetch, efficiency evidence/report docs | API-01 | standard | Existing instrumentation, fixed-cutoff and benchmark suites; in-progress diagnostics cannot overwrite completed-cycle proof |
| API-07 | Integrated runtime verification, independent review, PR/CI/merge/release/deploy | All | thinking | Scoped ShellCheck/Python checks, exact-head required CI, independent high-risk review, observed release/deployment receipts |

Paths in the table are relative to `.agents/scripts/` unless qualified.
Any newly required helper will live beside its owning script; its exact name
will be recorded with implementation evidence before review.

## Rollout and proof

Ship independently reviewable commits with existing conservative TTL and
freshness limits. Do not enable remote/fleet authority without a configured
trusted coordinator; expose unknown or unsupported transport cost honestly.
Retain rollback controls and polling wherever coverage cannot be proven.
Verify functional request reductions with deterministic call counts, then use
matched non-overlapping production windows for performance claims. A release
is not a claim that a multi-day efficiency soak has passed.
