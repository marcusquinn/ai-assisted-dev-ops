# Pulse productivity recovery

Tracking issue: #31343. Related scope-recovery work: #31305.

## Goal and authority

Restore useful dispatch and delivery within real GitHub quotas. The user explicitly
requests interactive full-loop implementation through release. Preserve trust,
ownership, credentials, explicit scope boundaries and protected publication.

## Evidence and work units

- Q1 (high risk): REST transport refuses at its stored reserve while the status
  endpoint reports a different allowance. Inspect resource-owned evidence; provide
  bounded, serialized recovery and diagnostic status without treating status JSON
  as spendable quota or resetting local state. Primary owns
  `.agents/scripts/gh_transport_budget.py`, `gh-transport-governor.py`, and tests.
- Q2 (medium): queue reporting calls label eligibility executable eligibility.
  Report structural holds and REST pressure explicitly; reuse existing progress
  observations rather than adding per-issue API polling. Primary owns
  `pulse-check-queue-scan.py`, `pulse-check-report.jq`, and related tests.
- Q3 (high): unchanged file-scope blockers re-arm on unrelated base commits.
  Distinguish scope revision from target-code revision and retain an AI recovery
  next action. Integrate with existing #31305 rather than duplicate its full
  coordinator implementation. Primary owns `terminal-blocker-circuit.sh`, runtime
  recovery/prompt references, and affected tests. Explicit hard boundaries remain.
- Q4 (medium): slow optional maintenance delays the next refill. Inspect current
  scheduling and keep cleanup bounded without killing preservation transactions.
  Primary owns pulse housekeeping scheduling and existing tests.
- Q5: exact-head review, PR checks, merge, canonical release and live postflight.
  Release-only local delegation is permitted by the framework; implementation
  remains primary-owned. Never claim a launch as a solved issue.

Concurrency: one implementation owner; independent advisory review only. Reuse
verified merged overlap from #31221, #31241 and #31265. No blanket hold removal.

## Verification

Use existing hermetic transport, pulse-check, terminal-blocker, runtime-contract
and scheduling tests plus scoped Python lint and ShellCheck. Verify quota cooldown,
out-of-order observations, concurrent reservations, explicit scope boundaries and
malformed evidence continue to fail safely. After canonical release, compare a
fresh 15-minute pulse snapshot, actual launches and delivery state. No new test
infrastructure or model-provider billing changes.

## Reproducer

Before the fix, `Budget.acquire` rejects a stored core balance of 100 with a
future reset even after its observation becomes stale; no governed request can
refresh it. The focused fixture seeds that exact state. The repaired path permits
one serialized accounted observation, and the real response reported 4823 core
requests remaining (HTTP 200). Subsequent ordinary guarded reads succeeded;
neither `/rate_limit` JSON nor deleting/resetting state was used as a quota grant.

The scope reproducer emits a final `files_scope_excluded` dossier, changes the base
revision without changing the brief, and verifies retry remains held. Correcting
the brief changes the revision. Candidate snapshot fixtures verify expiry,
future-date rejection and that failed enumeration is not cached as an empty queue.

Scheduling inspection: early dispatch and asynchronous post-dispatch housekeeping
already exist; 54 existing stage-wiring tests pass. No redundant maintenance
scheduler or destructive timeout change is needed. Long cycles instead exposed
the unbounded age of their candidate snapshots, now bounded to 120 seconds.

## Files Scope

Initial implementation map: the files above and directly necessary existing
supporting modules/tests/docs. Additional discovery must remain within the stated
outcome and guarantees; no authority to change other sessions' worktrees.
