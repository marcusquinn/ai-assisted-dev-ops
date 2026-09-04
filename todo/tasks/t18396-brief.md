<!-- aidevops:brief-schema=v2 -->

# t18396: Detect Codacy index and configuration drift before remediation

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `Codacy indexing quality findings issue creation worker briefs task lifecycle` → 0 hits — no relevant reusable lesson
- [x] Discovery pass: 0 recent target-file commits / 2 relevant merged PRs (#19637, #19647) / 0 open related PRs; neither historical PR added durable drift detection
- [x] File refs verified: 5 existing refs plus the test parent directory checked at `c2347f0b222e6ac88804f85a6a495fc05ee51f47`
- [x] Tier: `tier:standard` — telemetry behavior, drift thresholds, failure policy, and verification are resolved; implementation still requires bounded integration work
- [x] Seeded draft PR decision recorded: skipped — issue-only avoids anchoring the worker before the state-file shape is implemented

## Origin

- **Created:** 2026-09-04
- **Session:** OpenCode `ses_f9595a114ffe165mBLWoXbpLl2`
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** A manual Codacy reanalysis reached current `main` but left analysed LOC far below its historical level. The user authorized durable remediation briefs rather than code changes intended only to improve the badge.

## What

Make the daily quality sweep report enough Codacy state to distinguish genuine code-quality changes from stale analysis, index-denominator collapse, and documented coding-standard drift. Persist a per-repository last-healthy sample, render an explicit health classification, and prevent degraded Codacy telemetry from being described as a code regression.

## Why

At current `main` (`c2347f0b222e6ac88804f85a6a495fc05ee51f47`), Codacy reports grade 81/B, 2,421 issues, 371,010 analysed LOC, and 14 complex files. Historical analysed LOC was about 815,000; repeated reanalysis did not restore it. The existing `_sweep_codacy()` reports only issue count, so operators and automation cannot see denominator or coding-standard drift. It also cannot detect that B404 has returned with 69 findings despite the repository policy in `.bandit`.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The task changes observability and fail-closed classification, not external Codacy settings. The required states and negative guarantees are specified, while the worker must fit them into existing sweep serialization.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The work needs a cohesive state shape and focused fixtures; speculative code would constrain that implementation unnecessarily.
- **Status:** `not-created`
- **Freshness evidence:** Dashboard/API state and target files were checked against current analysed `main` on 2026-09-04.
- **Verification run:** `UNVERIFIED — brief only`
- **Stale-assumption warning:** Re-read Codacy API response fields and the current sweep serialization if either target script changes before implementation.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/stats-quality-sweep-tools.sh:333-365` — expand `_sweep_codacy()` from issue-count-only output to repository health telemetry and rule-policy drift evidence.
- `EDIT: .agents/scripts/stats-quality-sweep.sh:650-692,726-829` — pass the scanned repository path, persist/read Codacy health state, and preserve the multi-line section contract.
- `EDIT: .agents/tools/code-review/codacy.md:32-55,59-91` — document the health states, thresholds, and operator response.
- `NEW: .agents/scripts/tests/test-codacy-health-sweep.sh` — hermetic API/state fixtures for healthy, stale, index-degraded, and policy-drift states.

### Complete Write Surface

- **Callers/readers:** `_run_sweep_tools()` calls `_sweep_codacy()` and `_quality_sweep_for_repo()` renders its section; the persistent Code Audit Routines issue is the human reader.
- **Writers/mutation paths:** Store Codacy state under the existing `QUALITY_SWEEP_STATE_DIR` using atomic replacement. Do not change Sonar/Qlty fields in `_save_sweep_state()` or mutate Codacy settings.
- **Tests/fixtures:** Extend the existing per-tool stubbing/serialization pattern in `.agents/scripts/tests/test-quality-sweep-serialization.sh:107-166`; add focused JSON fixtures in the new test rather than live API calls.
- **Schemas/config:** Preserve current quality-sweep section files and state backward compatibility. New Codacy state must tolerate missing/legacy files as `BASELINE_UNKNOWN`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/**`; edit repository sources only.
- **Migrations/backfills:** `QUALITY_SWEEP_STATE_DIR` needs no destructive migration because a first observation without a trustworthy baseline records telemetry but must not claim the index is healthy.
- **Cleanup/rollback paths:** Reverting `.agents/scripts/stats-quality-sweep-tools.sh` and the new state fields must leave the existing issue-count-only Codacy section functional; malformed state is ignored and rebuilt.

### Implementation Steps

1. Fetch the repository summary already verified at `/api/v3/analysis/organizations/gh/{owner}/repositories/{repo}?branch=main` and the issue overview endpoint in bounded requests. Parse grade, issue count, analysed LOC, complex-file count, last analysed SHA, and pattern totals.
2. Compare the last analysed SHA with the remote default SHA. Classify a mismatch as `STALE_ANALYSIS` and never advance the healthy baseline from it.
3. Once a trustworthy baseline exists, classify analysed LOC below 80% of the last healthy value as `INDEX_DEGRADED`. Keep the previous healthy baseline so a bad sample cannot ratchet the expected denominator downward.
4. Classify non-zero counts for repository-documented noise patterns as `POLICY_DRIFT`; initially cover `Bandit_B404`, `ESLint8_es-x_no-modules`, `ESLint8_es-x_no-block-scoped-variables`, and `ESLint8_es-x_no-trailing-commas`.
5. Render grade, issue count, LOC, complex files, analysed SHA, health state, and drift-rule counts in the Codacy section. API, parse, or state errors must render `UNKNOWN`, not zero or healthy.
6. Keep this task observational: do not change `.bandit`, `.codacy.yml`, external coding-standard settings, issue thresholds, or source exclusions.

### Hazards and Compatibility

- **Concurrency/atomicity:** Sweep instances may overlap; write state through a same-directory temporary file and atomic rename so readers never consume partial JSON.
- **Migration/rollback:** Missing or old state initializes as unknown. Do not overwrite a last-healthy baseline with stale, malformed, or index-degraded samples.
- **Mixed-version/backward compatibility:** Existing callers expecting one multi-line `codacy_section` remain valid; new state fields are additive.
- **Idempotency/retry:** Repeating the same sample produces the same classification and state. API rate limits/errors remain non-destructive.
- **Partial failure/recovery:** If one Codacy endpoint succeeds and another fails, render available telemetry with `UNKNOWN` health and retain the prior healthy state.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-codacy-health-sweep.sh
bash .agents/scripts/tests/test-quality-sweep-serialization.sh
shellcheck .agents/scripts/stats-quality-sweep-tools.sh .agents/scripts/stats-quality-sweep.sh .agents/scripts/tests/test-codacy-health-sweep.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The focused test covers API parsing and state transitions; serialization coverage protects the dashboard transport; ShellCheck and changed-file lint cover Bash portability and repository policy.
- **Broad verification trigger:** Run the full stats quality-sweep test group only if shared state or section serialization changes beyond Codacy-specific fields.

### Files Scope

- `.agents/scripts/stats-quality-sweep-tools.sh`
- `.agents/scripts/stats-quality-sweep.sh`
- `.agents/tools/code-review/codacy.md`
- `.agents/scripts/tests/test-codacy-health-sweep.sh`
- `.agents/scripts/tests/test-quality-sweep-serialization.sh`

## Acceptance Criteria

- [ ] A current-head healthy fixture renders grade, issue count, LOC, complex files, analysed SHA, and `HEALTHY`, then atomically records it as the last healthy sample.
- [ ] A stale SHA, malformed response, or API failure cannot render `HEALTHY` or overwrite the prior healthy baseline.
- [ ] A current-head sample below 80% of the prior healthy LOC renders `INDEX_DEGRADED` while retaining the prior baseline.
- [ ] Any configured documented-noise rule with a non-zero overview count renders `POLICY_DRIFT` and the exact rule/count without changing external settings.
- [ ] Existing multi-line quality-sweep serialization and non-Codacy tool sections remain byte-stable.

## Context & Decisions

- This task improves trustworthiness; it must not hide genuine findings or weaken quality gates merely to raise the badge.
- The current index collapse remains an external incident handled separately by t18399.
- B404 and legacy ESLint counts are drift signals because repository policy already identifies them as noise; subprocess usage rules B603/B607 remain enabled.

## Dependencies

- **Blocked by:** none.
- **Blocks:** none.
- **External:** Read-only Codacy API access; fixtures must keep tests independent of credentials and network availability.

## Estimate Breakdown

| Phase | Time |
|---|---:|
| API/state integration | 1.5h |
| Rendering and documentation | 45m |
| Focused verification | 1.5h |
| Review buffer | 15m |
| **Total** | **~4h** |
