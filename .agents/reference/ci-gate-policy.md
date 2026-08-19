<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# CI Gate Policy

Use CI as a throughput control, not a progress trap. Required merge gates should
match the risk of the target branch; slower integration checks should create
feedback loops when they find defects.

## Evidence-guided verification

Tests and checks are evidence-gathering methods, not independent objectives.
Even when the user requests a testing deliverable, tie it to the behaviour,
decision, or risk it is intended to protect. Start from the session aim and the
uncertainty blocking it.

Time-to-functional is the default priority. Running existing checks and creating
new test assets are separate decisions:

1. Start with the production-facing behaviour through the existing app, API,
   CLI, integration, or deployment path. Prefer standard logs, telemetry,
   framework diagnostics, and existing targeted checks over synthetic machinery.
2. Run explicit repository-required gates directly. Before adding or broadening
   test code, or running a non-required broad suite, identify what decision its
   result can change or what material uncertainty it reduces. Do not create a
   test for information already supported by sufficient existing evidence.
3. Do not add or expand test code merely because code changed or a suite exists.
   Add a focused test only when the user or acceptance criteria explicitly asks
   for it, a repository policy specifically requires the coverage, or it is the
   lowest-cost way to resolve material uncertainty. A required test command
   requires running existing tests, not automatically writing more.
4. New runners, harnesses, mock systems, fixture frameworks, test-only product
   interfaces, coverage thresholds, and CI test gates are scope expansion. Get
   explicit user approval unless the task itself explicitly requests that
   infrastructure. Keep one-off diagnostic probes temporary and out of the
   committed diff.
5. Missing new coverage is not itself a defect or an automatic follow-up task.
   Durable regression protection may be back-filled after behaviour and design
   stabilise; named security, destructive-operation, portability, or repository
   contract requirements remain scoped exceptions.
6. Review retained tests against the outcome that justified them. Keep coverage
   that protects an important contract; narrow, update, or remove tests whose
   signal no longer justifies their maintenance or execution cost.
7. Treat observed behaviour, user reports, production and usage logs, existing
   contracts, targeted reproductions, and tests as complementary evidence.
   Compare provenance, freshness, relevance, and reliability; synthetic tests
   do not automatically outrank live evidence.
8. Stop gathering evidence and make the reasoned improvement once the available
   information is sufficient for a safe decision. Still satisfy explicit
   acceptance criteria and repository-required gates, reconsider conclusions
   when material new evidence appears, and report any remaining uncertainty.
   Passing tests alone do not prove the user-visible outcome.

## Default policy

| Target | Required gates | E2E role | Merge posture |
|---|---|---|---|
| `develop` / integration work branch | Format, lint, typecheck, configured unit tests, cheap security/secret checks | Skipped or advisory by default | Optimise for continual progress and rapid worker feedback. |
| `staging` / release candidate | Core gates plus E2E/smoke tests relevant to promoted areas | Required when it protects the promotion path | Optimise for integrated confidence before production-like deployment. |
| `main` / production release | Core gates, release checks, required E2E/smoke/security checks | Required where branch rules declare it | Optimise for release assurance and auditability. |

## Design rules

1. Keep develop PR required checks fast and deterministic. Prefer format, lint,
   typecheck, and existing configured unit tests over broad browser suites.
2. Do not require "branch up to date" on high-throughput develop queues unless
   the repository has a merge queue that batches/revalidates automatically.
3. Run E2E at staging or release-promotion boundaries, where integrated state is
   the product under test.
4. Treat develop E2E as advisory unless the PR directly changes the exact
   critical path under test and the test is stable enough to provide useful
   signal.
5. Convert advisory E2E, visual, performance, and flaky integration findings
   into follow-up tasks with worker-ready evidence instead of blocking unrelated
   develop PRs or spawning duplicate worker attempts.
6. If an E2E failure is required by branch protection, fix or explicitly
   quarantine the failing path before merge; do not bypass production/release
   gates silently.
7. In JS/TS monorepos, make affected-package checks non-recursive. For Turbo,
   a broad filter such as `--filter="...[origin/<base>]"` can include the
   workspace root; if root `lint`/`typecheck` scripts call Turbo, exclude root
   with `--filter="!//"` or run root checks in a separate job.
8. Keep local/headless quality gates resource-aware: scoped checks for the
   active package during the inner loop; affected-package checks before PR;
   full-repo checks only for shared tooling/contracts or final confidence.
   Background runs should avoid TUI output and cap concurrency explicitly.
   aidevops `linters-local.sh` therefore defaults to changed-file scope and
   reserves uncached `--full` execution for release boundaries.
9. Repositories with broad root scripts should expose safe defaults and override
   knobs (for example Turbo `--ui=stream --concurrency=${TURBO_LINT_CONCURRENCY:-4}`)
   so parallel workers do not exhaust local CPU/RAM.
10. Vault changes require the fast deterministic security suite on develop/main
   PRs. Broad reboot, fleet, migration-recovery, and manual crypto-review drills
   are staging/release advisory until stable enough for every PR. See
   `reference/vault-security-review.md`.
11. Before refreshing a PR branch from its base branch, check required checks on
   the current head SHA. If required checks are queued or in progress and the PR
   is not conflicted or explicitly blocked by an up-to-date ruleset, keep the
   head stable: wait for the current run or enable platform-native auto-merge.
12. Repositories that require testing the exact merge result should use merge
   queue or platform-native queued merge behaviour instead of repeatedly mutating
   PR branches while CI is active.
13. Code-quality add-on apps are advisory by default. Missing, pending,
    unavailable, rate-limited, or late add-on results never delay a trusted PR
    after required project CI passes. Sweep late findings into worker-ready
    follow-up issues. Repositories with exceptional sensitivity may explicitly
    opt into `review_gate.completion_behavior: strict`; never make that the
    framework default.

## Ruleset checklist

- Develop ruleset:
  - required status checks: core gates only;
  - strict required status checks: off, or replaced by a merge queue;
  - E2E contexts: not required.
- Staging/release ruleset:
  - strict status checks or merge queue: on;
  - E2E/smoke checks: required for the promotion surface;
  - deployment and environment gates: explicit and auditable.

## Follow-up issue pattern

When an advisory check discovers a defect:

1. Verify the failure is reproducible or cite the exact CI run/check URL and
   first failing assertion.
2. File a task with:
   - files/specs implicated;
   - expected vs actual behaviour;
   - branch/check context where it was observed;
   - reproduction or artifact path;
   - verification command.
3. Reference the source PR/check using `For #NNN` or `Ref #NNN`, not a closing
   keyword unless the new task is the direct fix.
4. Let the original PR proceed if its required gates are green and the advisory
   finding is not a defect introduced by that PR.

This mirrors review-bot handling: additive or broader findings become follow-up
work; only defects in the PR's own code block the PR.

## Anti-patterns

- Full E2E on every develop PR when most failures are unrelated flakes.
- Parallel update/rerun of many PRs when each merge invalidates the next one's
  strict up-to-date checks.
- Updating a PR branch during active required CI just to "refresh" it; this
  starts a new check suite for the new head and can discard nearly-finished work.
- Diagnosing or redispatching from a failed check without first verifying that
  the failure belongs to the current PR head SHA.
- Redispatching new workers for advisory E2E failures instead of filing focused
  follow-up tasks.
- Treating delayed, pending, cancelled, or infrastructure-timed-out checks as
  proof of a source-code defect.
- Broad affected Turbo lint/typecheck filters that include a recursive root
  script, making CI look hung or quiet instead of testing changed packages.
- Unbounded local `format:fix && lint:fix && typecheck && test` chains across
  several active sessions; they preserve quality intent but destroy throughput
  by oversubscribing CPU/RAM.
- Creating a standalone harness, mock system, coverage gate, or test-only product
  path for ordinary feature or bug work without explicit scope and evidence.
