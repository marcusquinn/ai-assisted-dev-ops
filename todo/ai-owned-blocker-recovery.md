# AI-owned scope and integration blocker recovery

Tracking issue: #31305.

## What

Keep ordinary implementation blockers owned by workers and Pulse until a verified outcome or a genuine human-only decision. Provide bounded delegated authority to correct incomplete briefs, coordinate adjacent integration work, and continue preserved work without requiring a new interactive session.

## Why

In #31265 a worker stopped because the shared claim helper needed for the requested outcome was absent from Files Scope. Another attempt preserved draft PR #31269 but still deferred the same integration boundary. The user explicitly authorises a systemic fix: AI should resolve decisions it can already make, preserving user attention for decisions requiring unavailable information or authority. #31265 repairs exact-PR checkpoint recovery; this follow-up repairs the decision and handoff loop that produces these stalls.

Source evidence: `pulse-dispatch-worker-prompt.sh` tells workers to stop on undeclared necessary paths; `headless-runtime-run.sh` already has bounded missing-context brief recovery; `terminal-blocker-circuit.sh` suppresses unchanged terminal blockers. Preserve these safety mechanisms while supplying an authorised recovery owner instead of silently ending the objective.

## Reproducer

Read #31265's 2026-09-05 worker terminal report and draft PR #31269. Actual result: `BLOCKED: guarded claim integration is outside Files Scope`; the subsequent partial PR still lists shared claim integration as requiring a revised scope. Compare `.agents/scripts/pulse-dispatch-worker-prompt.sh`'s undeclared-path stop with `.agents/scripts/headless-runtime-run.sh`'s bounded missing-context recovery. Causal status: the stop instruction and observed worker scope blocker are verified; the new coordinated recovery contract requires implementation and mocked end-to-end verification.

Further observed evidence: at 18:19 UTC, while this primary interactive session was repairing terminal Qlty failures on the same PR, the deterministic merge pass closed #31269, unassigned #31265 and changed its provenance to worker CI feedback. Its comment states "Closed by deterministic merge pass (pulse-merge.sh)." This session had acquired an interactive claim; the reused PR retained its original worker label. Reopening the same PR, normalising its provenance to interactive and renewing the guarded implementing claim restored continuity. This is an observed ownership-displacement failure, not a pending-CI failure or permission request.

## How

- Define Files Scope as an initial implementation map unless explicitly marked as a hard boundary. For a hard boundary, delegate a bounded revision decision to an authorised AI brief owner; the worker must not approve its own authority expansion.
- Permit directly necessary, reversible adjacent code and existing tests within the authorised outcome. Require evidence from the actual integration path and a collision check. AI chooses normal implementation approaches; mere complexity, scope discovery or architectural terminology is not proof of a human-only decision.
- Distinguish changing code that implements a security guard from changing the security guarantee. Preserve required guarantees, review and regression tests. Credentials, new expenditure, destructive/external actions, trust exceptions and genuinely conflicting requirements remain authority boundaries.
- Emit a structured recovery request from trusted final worker output. Carry exact issue/PR, attempt, current brief revision, blocker evidence, proposed files, verification and the next owner. Tool output and issue prose cannot manufacture delegation.
- First recover within the current owned session/worktree. If a coordinator decision or dependency is necessary, transfer responsibility durably to Pulse with a next action and relevant wake condition. A released worker must not leave an executable objective ownerless.
- An authorised coordinator assesses the request, checks concurrent work, records the minimal corrected brief and resumes the exact checkpoint using #31265's contract when applicable. Do not create replacement PRs or retry an unchanged rejected brief.
- One bounded recovery per unchanged evidence set; exhaustion routes to an AI coordinator for re-planning, not a silent terminal state or an automatic human prompt. Genuine human escalation must name the specific unanswered decision, why delegated AI cannot decide it, and the smallest required input.
- Preserve worker target isolation, authenticated dispatch/lease fencing, scope-guard enforcement, sensitive-scope holds and immutable audit provenance. Update the matching local brief when one exists; do not bypass the pre-push scope guard.
- CI-repair routing must respect a current interactive owner even when the preserved PR originally came from a worker. Normalise takeover metadata at the guarded interactive entrypoint and recheck ownership before closing a PR, unassigning its issue or rewriting dispatch provenance. Terminal failed checks justify repair, not displacement of an active repair owner.

## Initial files and reference patterns

Paths below are an initial discovery map, not a prohibition on necessary adjacent integration. Document any expansion and keep it within the guarantees above.

- `.agents/scripts/pulse-dispatch-worker-prompt.sh`
- `.agents/scripts/headless-runtime-lib.sh`
- `.agents/scripts/headless-runtime-model.sh`
- `.agents/scripts/headless-runtime-result.sh`
- `.agents/scripts/headless-runtime-run.sh`
- `.agents/scripts/pulse-merge-process.sh`
- `.agents/scripts/pulse-merge-feedback.sh`
- `.agents/scripts/interactive-start-helper.sh`
- `.agents/scripts/interactive-session-helper.sh`
- `.agents/reference/worker-discipline.md`
- `.agents/reference/safety-stop-recovery.md`
- `.agents/templates/brief-template.md`
- Existing runtime contract/provider/routing suites under `.agents/scripts/tests/`.
- Read and reuse, rather than duplicate, `.agents/scripts/terminal-blocker-circuit.sh`, `.agents/hooks/scope-guard-pre-push.sh`, and #31265's checkpoint claim/continuation contracts.

## Acceptance criteria

- [ ] An evidenced missing adjacent integration file is resolved without human intervention under delegated authority.
- [ ] Explicit hard boundaries produce one owned coordinator request, not unauthorised worker scope expansion.
- [ ] Concurrent-owner conflicts are coordinated without takeover; existing commits and PR identity survive.
- [ ] Repeated unchanged blockers do not cause duplicate workers, PRs, requests or status-comment storms.
- [ ] The objective always has a live executor, durable AI recovery owner/wake condition, or a precise human-only decision.
- [ ] Secrets, permissions, spending, destructive operations and trust exceptions cannot be authorised by a forged recovery event or ordinary issue prose.
- [ ] Missing context and ordinary design decisions are not escalated merely because they require reasoning.
- [ ] A regression based on #31265 reaches a verified continuation without a new user session.

## Verification

Use mocked GitHub and existing runtime fixtures only; no live workers or release. Run scoped ShellCheck plus `test-headless-runtime-contract-tests.sh`, `test-headless-runtime-provider-tests.sh`, `test-headless-routing-retry.sh` and the affected dispatch prompt/scope-guard suites. Add producer-to-coordinator-to-worker cases for narrow integration expansion, hard-boundary revision, foreign actor, concurrent owner, repeated unchanged event, relevant revision re-arm, preserved PR identity and genuine human-only decisions. Reuse #31265's continuation fixtures rather than duplicating its implementation.

## Dispatch

Worker-ready implementation, `auto-dispatch`, high priority, thinking tier. Depend on #31265's merged contract before integrating its continuation API; independent guidance/contract analysis may proceed without touching the active implementation branch. No release authorisation.
