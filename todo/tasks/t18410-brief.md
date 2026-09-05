<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18410: Reduce operation-output and helper-discovery round trips

## Pre-flight

- [x] Memory recall: parent plan preserves session output evidence and repeated interface/setup friction.
- [x] Discovery pass: existing output-sandbox receipts, delta-aware CI waits and session efficiency reporting already work; adoption/interface gaps are the target.
- [x] File refs verified: output helpers, context-efficient-output guide, full-loop interface and focused tests checked at `5393632ee`.
- [x] Tier: standard; bounded existing interface/receipt patterns, with no matched self-hosting file fragment among the listed targets.
- [x] Seeded draft PR decision recorded: skipped; choose only measured production-facing paths.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18403.

## What

Apply existing bounded operation receipts and consistent read-only helper
discovery to a small set of observed costly paths, preserving exact evidence and
correct outcome/exit semantics. Do not create another output framework.

## Why

This session reported 870,911 model-visible tool-output bytes, 26 oversized results
and 25 successful oversized results. Those categories overlap and some exact
output was necessary. Unsupported help/status probes and a runner exiting zero
despite failed trials also forced extra source reading and recovery. Optimise
decision sufficiency and human time, not output bytes indiscriminately.

## Tier

**Selected tier:** `tier:standard` — measured adoption of existing interface/receipt contracts while preserving truthful lifecycle evidence.

## How (Approach)

### Files to Modify

- `EDIT: .agents/reference/context-efficient-output.md`, `EDIT: .agents/scripts/output-sandbox-helper.sh`, `EDIT: .agents/scripts/session-review-helper.sh` only for proven receipt/adoption gaps.
- `EDIT: .agents/scripts/full-loop-helper.sh` and narrowly affected helper subcommands — consistent read-only `help`/`--help` discovery without executing the operation; do not refactor the whole lifecycle.
- `.agents/plugins/opencode-aidevops/output-compaction.mjs` and `.agents/scripts/planning-commit-helper.sh` are related consumers/interfaces to inspect before choosing any change.

### Complete Write Surface

- **Callers/readers:** interactive tool wrappers, `.agents/scripts/commands/full-loop.md`, planning/task helpers and operation receipt consumers.
- **Writers/mutation paths:** receipt generation in `output-sandbox-helper.sh` and bounded command dispatch/help paths in `full-loop-helper.sh`.
- **Tests/fixtures:** `.agents/scripts/tests/test-output-sandbox-helper.sh`; reuse existing full-loop command policy tests when a dispatch path changes.
- **Schemas/config:** preserve `aidevops.operation-result/v1` described in `.agents/reference/context-efficient-output.md`; status/help must not mutate lifecycle state.
- **Generated/deployed mirrors:** source scripts and `.agents/` runtime command descriptions; no independent command catalogue that can drift from the parser.
- **Migrations/backfills:** N/A because this bounded `output-sandbox-helper.sh` adoption/interface change preserves private output stores and opaque IDs without changing their data schema.
- **Cleanup/rollback paths:** existing output-store retention and `.agents/scripts/output-sandbox-helper.sh` recovery remain authoritative; help cannot initiate cleanup.

### Implementation Steps

1. Reproduce a small set of oversized-success/interface-friction cases with content-free metrics; classify exact/security/JSON/diff output that must remain native.
2. Use existing receipt paths where the next decision needs outcome plus bounded diagnostics; verify failures and incomplete completion sentinels stay visible.
3. Make selected helper help forms discoverable and side-effect free, including unknown subcommand diagnostics. Derive interface information from the existing parser where practical.
4. Reuse current lifecycle state as evidence for actual progress/blockers; do not add another reminder telling the model to continue work.
5. Compare before/after sufficiency, fallback reads and repeated calls, not just smaller output. No suppressing warnings or weakening gates to improve the metric.

### Hazards and Compatibility

- **Concurrency/atomicity:** keep receipt/state IDs scoped and safe under parallel sessions; helper introspection must not mutate shared state.
- **Migration/rollback:** additive help/receipt adoption must preserve existing command flags, exit codes and native fallback.
- **Mixed-version/backward compatibility:** older callers still get their expected result shape; unavailable storage falls back honestly.
- **Idempotency/retry:** repeated read-only help/status produces no GitHub writes, branches, processes or duplicate events.
- **Partial failure/recovery:** preserve raw evidence for terminal failures and mark missing/unverified outcome signals explicitly.

### Complexity Impact

`full-loop-helper.sh` contains historically long orchestration functions. Do not
grow `cmd_commit_and_pr()` for help handling; use the existing argument-dispatch
boundary or a small helper. Measure chosen function lengths before edits; if
projected growth exceeds the gate, extract a scoped helper rather than changing
thresholds. Exact added functions depend on the reproduced interface gap.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-output-sandbox-helper.sh
.agents/scripts/full-loop-helper.sh help
.agents/scripts/planning-commit-helper.sh --status
.agents/scripts/session-review-helper.sh output-efficiency --json
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** receipt tests cover truth/fallback semantics; help/status calls must be read-only; efficiency reports support before/after measurements without raw private content; scoped lint protects changed code. Exercise new help aliases only after they exist.

### Recoverability Checkpoint

After a focused production-facing check, commit the bounded change before broad
gates. A resource fuse leaves remaining criteria open; resume with a narrower
command or existing receipt rather than retrying the same noisy shape.

## Acceptance Criteria

- [ ] Selected noisy successful operations use sufficient compact evidence, while security/exact/JSON and failed-operation details remain accessible and truthful.
- [ ] Selected help/status forms are predictable and demonstrably cause no execution or lifecycle mutation.
- [ ] Measured repeated discovery/fallback work does not increase, and no new output framework, global checklist or weakened gate is introduced.

## Seeded Draft PR

Skipped — select the smallest production-path change from observed evidence.

Parent: #31280
