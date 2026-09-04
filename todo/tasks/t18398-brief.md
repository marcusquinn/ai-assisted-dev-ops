<!-- aidevops:brief-schema=v2 -->

# t18398: Harden high-signal Python subprocess boundaries reported by Codacy

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `Codacy indexing quality findings issue creation worker briefs task lifecycle` → 0 hits — no relevant reusable lesson
- [x] Discovery pass: 0 recent target-file commits / 0 merged related PRs / 0 open related PRs
- [x] File refs verified: 12 source/test refs checked at `c2347f0b222e6ac88804f85a6a495fc05ee51f47`
- [x] Tier: `tier:standard` — the trust boundary and no-global-suppression policy are decided; each bounded callsite still needs source-aware validation
- [x] Seeded draft PR decision recorded: skipped — security-adjacent callsite classification should precede edits

## Origin

- **Created:** 2026-09-04
- **Session:** OpenCode `ses_f9595a114ffe165mBLWoXbpLl2`
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** Current Codacy analysis reports 74 Opengrep dangerous-subprocess findings, 35 Bandit B603 findings, and 37 Bandit B607 findings. This brief selects the six highest-density production files rather than opening one issue per annotation or suppressing the tools globally.

## What

Harden or precisely document the subprocess trust boundary at the 14 unique callsites in the six scoped production files. Resolve their current 26 overlapping Codacy findings while preserving command behavior, fail-closed handling, process cleanup, and platform compatibility.

## Why

The selected files account for the highest-density production findings: `_knowledge_collector_process.py` (6), `session-miner/extract_git.py` (6), `managed_readme.py` (4), `report-token-use-helper.py` (4), `cch-sign.py` (3), and `deployment-copy-helper.py` (3). Some callsites already validate argv and carry Bandit rationale but remain visible to Opengrep; others invoke partial executable paths or accept command vectors whose origin must be made explicit.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** This is a bounded security-adjacent implementation inside existing command boundaries. No trust-policy redesign is authorized, but the worker must classify each argv source before choosing validation, absolute resolution, or narrow suppression.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Pre-writing annotations would risk blessing unverified command provenance.
- **Status:** `not-created`
- **Freshness evidence:** All Codacy findings were fetched for current analysed `main`; target callsites and related PR activity were then checked locally.
- **Verification run:** `UNVERIFIED — brief only`
- **Stale-assumption warning:** Re-query or inspect current callsites if any scoped file changes before work starts; annotation line numbers are not stable identifiers.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/_knowledge_collector_process.py:20-24,107-142` — resolve the fixed process-inspection executable and validate/document the collector command boundary without weakening termination safety.
- `EDIT: .agents/scripts/session-miner/extract_git.py:17-27,49-67,84-99` — resolve Git safely and preserve current timeout/error semantics.
- `EDIT: .agents/scripts/managed_readme.py:72-87,129-148` — make `gh`, `bash`, and helper-path provenance explicit.
- `EDIT: .agents/scripts/report-token-use-helper.py:758-764` — resolve platform opener executables before invocation and retain non-fatal open behavior.
- `EDIT: .agents/scripts/cch-sign.py:60-101` — keep the absolute helper call and resolve optional `claude` execution without changing fallback constants.
- `EDIT: .agents/scripts/deployment-copy-helper.py:109-118,379-417,468-477` — preserve validated Git provenance and add exact Opengrep suppression only where code-level checks already prove safety.
- Existing focused tests listed below may be updated only when assertions must reflect unchanged command resolution behavior.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/_knowledge_collector_process.py` and the other five scoped helpers are invoked by knowledge collection, session mining, managed README sync, token reports, CCH signing, and deployment-copy workflows. Their subprocess return codes/stdout/stderr are consumed by existing control flow.
- **Writers/mutation paths:** Changes in `.agents/scripts/deployment-copy-helper.py` and the other scoped helpers are limited to executable resolution, argv validation, and exact finding annotations; do not alter destination files, Git operations, process-group termination, report opening, signing constants, or deployment state.
- **Tests/fixtures:** Reuse `.agents/scripts/tests/test-deployment-copy-helper.sh`, `test-managed-readme-helper.sh`, `test-report-token-use-helper.sh`, session-miner tests, and `.agents/tests/test-knowledge-collector-routine.sh`. Add assertions to existing files rather than introduce a new harness.
- **Schemas/config:** N/A because evidence shows the scoped subprocess boundaries change no persisted schema or global security configuration.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/**`; do not edit installed copies.
- **Migrations/backfills:** N/A because the scoped helpers persist no subprocess-boundary schema or records requiring migration.
- **Cleanup/rollback paths:** Revert each scoped `.agents/scripts/*.py` change independently if behavior regresses. Never “recover” by disabling B603, B607, or the Opengrep rule repository-wide.

### Implementation Steps

1. For each scoped callsite, record whether the executable is absolute, resolved through a trusted lookup, or caller-controlled; record whether each argument is fixed, validated, or data-only.
2. Resolve partial executable names with `shutil.which()` or an existing trusted path pattern, and preserve existing optional-tool behavior when an executable is absent.
3. Keep argv arrays and `shell=False`. Add validation before execution wherever a command or executable can cross the function boundary.
4. Where existing validation already proves a finding false positive, use the exact tool-native suppression with an inline reason tied to that validation. Use the full Opengrep rule identifier when required; do not add blanket file/tool exclusions.
5. Preserve all current timeouts, capture modes, return-code checks, fallback ordering, and process-tree cleanup.
6. Run the focused product-path tests, then confirm the scoped files no longer emit the targeted rules through the available local scanner or post-merge Codacy reanalysis.

### Hazards and Compatibility

- **Concurrency/atomicity:** `_knowledge_collector_process.py` signal masks and process-group cleanup are concurrency-sensitive; executable validation must occur before launch without changing cleanup ordering.
- **Migration/rollback:** No data migration. Each file can be reverted without state conversion.
- **Mixed-version/backward compatibility:** Preserve macOS/Linux opener behavior, optional `claude` fallback, Git CLI compatibility, and existing Python versions.
- **Idempotency/retry:** Command invocations retain current retry/fallback behavior. Resolution must not cache stale paths across unrelated runs.
- **Partial failure/recovery:** Missing executables must follow current graceful failure paths; deployment and signing helpers must continue to fail closed where provenance cannot be verified.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-deployment-copy-helper.sh
bash .agents/scripts/tests/test-managed-readme-helper.sh
bash .agents/scripts/tests/test-report-token-use-helper.sh
bash .agents/scripts/tests/test-session-miner-repo-scope.sh
bash .agents/tests/test-knowledge-collector-routine.sh
python3 -m compileall -q .agents/scripts/_knowledge_collector_process.py .agents/scripts/session-miner/extract_git.py .agents/scripts/managed_readme.py .agents/scripts/report-token-use-helper.py .agents/scripts/cch-sign.py .agents/scripts/deployment-copy-helper.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Existing helper tests cover command behavior and failure handling; compileall checks every scoped Python source; changed-file lint covers repository quality gates.
- **Broad verification trigger:** Run a broader subsystem suite only if the implementation changes shared command wrappers or trust policy outside these files.

### Files Scope

- `.agents/scripts/_knowledge_collector_process.py`
- `.agents/scripts/session-miner/extract_git.py`
- `.agents/scripts/managed_readme.py`
- `.agents/scripts/report-token-use-helper.py`
- `.agents/scripts/cch-sign.py`
- `.agents/scripts/deployment-copy-helper.py`
- `.agents/scripts/tests/test-deployment-copy-helper.sh`
- `.agents/scripts/tests/test-managed-readme-helper.sh`
- `.agents/scripts/tests/test-report-token-use-helper.sh`
- `.agents/scripts/tests/test-session-miner-repo-scope.sh`
- `.agents/tests/test-knowledge-collector-routine.sh`

## Acceptance Criteria

- [ ] Every scoped subprocess call has explicit executable and argv provenance enforced in code or documented by an exact narrow suppression after validation.
- [ ] Partial executables are resolved safely or retain a documented graceful-absence path; no implementation introduces `shell=True` or string command execution.
- [ ] The 26 current overlapping B603/B607/dangerous-subprocess findings in the six scoped files are eliminated without disabling those rules globally.
- [ ] Knowledge-collector interruption cleanup, deployment provenance checks, managed README fallback, session mining, report opening, and CCH fallback behavior remain unchanged.
- [ ] Focused tests, compileall, and changed-file lint pass.

## Context & Decisions

- This is the first production batch, selected by finding density. Test-only subprocess findings and the remaining lower-density files are intentionally out of scope.
- Existing `# nosec B603` comments are evidence to verify, not proof to copy blindly.
- Security behavior outranks badge improvement; retain a finding when safe remediation or precise justification cannot be established.

## Dependencies

- **Blocked by:** none.
- **Blocks:** none.
- **External:** Codacy reanalysis confirms remote-rule clearance after merge; local product tests remain authoritative for behavior.

## Estimate Breakdown

| Phase | Time |
|---|---:|
| Callsite classification | 1h |
| Hardening/annotations | 2h |
| Focused verification | 1.5h |
| Review buffer | 30m |
| **Total** | **~5h** |
