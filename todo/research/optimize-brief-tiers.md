---
name: optimize-brief-tiers
mode: in-repo
target_repo: .
status: superseded
superseded_by: issue-30560-historical-model-replay
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Superseded research: optimise brief tiers

## Status

This proposal is retained only as a decision record. Do not execute its commands.
Issue #30560 replaced the provider-branded autoresearch scaffold with the sealed,
provider-neutral historical replay workflow in `.agents/workflows/optimize-tiers.md`.

## Why it was superseded

The original design could not support trustworthy routing decisions because it:

- fixed the researcher and evaluator to branded model families;
- treated reference-diff similarity as correctness evidence;
- mixed brief generation, implementation, and evaluation;
- lacked hidden deterministic verification and repeated case qualification;
- had no pre-run plan or prediction seal;
- did not isolate historical base state from later Git history;
- did not prove the concrete model or effective reasoning effort;
- proposed automatic template mutation before confirming route-changing results.

The replacement uses exact or explicitly reconstructed historical prompts,
immutable base commits, hidden fail-to-pass and pass-to-pass checks, synthetic
one-commit worktrees, provider allowlists, sealed predictions, runtime evidence,
separate autonomous and prescriptive modes, and staged confirmation.

## Command migration

| Original command or concept | Current replacement |
|---|---|
| `extract` | Local curation with `init` and `add-case` |
| `enrich` | Optional prescriptive prompt recorded by `add-case` |
| `test` | `plan`, `seal`, then `run` |
| `score` | Deterministic `report` output |
| Haiku pass rate | Candidate configuration independent of provider branding |
| Diff similarity | Hidden deterministic verification |
| Automatic template loop | Separate reviewed change after confirmation |

The old `extract`, `enrich`, `test`, and `score` CLI commands now fail with a
migration message. Raw corpora and all benchmark artifacts remain local-only.

## Preserved research question

The useful question remains: which task and brief characteristics permit a lower
model tier or effort without reducing verified completion? Answer it by comparing
sealed predictions with repeated quick/full replay and production telemetry. Any
change to `reference/task-taxonomy.md`, model routing, or brief templates requires
a separate reviewed implementation after the evidence is confirmed.
