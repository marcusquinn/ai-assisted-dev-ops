<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Feedback Plane

The `_feedback/` plane retains qualitative signal before it becomes durable
knowledge, campaign research, project requirements, case notes, performance
context, or TODO/GitHub work. It is separate from `_inbox/` staging queues and
from `_knowledge/` approved insights.

Agents may use this plane opportunistically through the inherited ambient
contract in `reference/self-improvement.md`. The planned CLI is an optional
deterministic interface, not the trigger for observing or retaining feedback.

For shared plane metadata, use `.agents/configs/data-planes.json` when a registry
entry exists. This index owns the feedback-plane reading path; detailed capture,
retention, mining, promotion, CLI, and routine contracts live in the chapters
below.

## Read Order

| Need | Read | Contains |
|------|------|----------|
| Capturing or classifying raw feedback | `.agents/aidevops/feedback/capture-retention.md` | Required capture metadata, examples, sensitivity tiers, retention outcomes, consent/provenance constraints, placeholder examples. |
| Mining feedback or promoting themes | `.agents/aidevops/feedback/mining-promotion.md` | Cold-start mining loop, evidence thresholds, review gates, destination-specific promotion paths, no-promote/retire outcomes, provenance/privacy rules. |
| Designing commands or recurring operations | `.agents/aidevops/feedback/cli-routines.md` | `aidevops feedback` command contract, capture/list/mine/promote/retire IO, routine examples, implementation boundary. |

## Core Contract

- A feedback capture is evidence, not interpretation. Store enough normalized
  metadata to re-check provenance, consent, sensitivity, and context before any
  mining or promotion.
- Raw feedback MUST have a sensitivity tier, consent/provenance note, and
  retention outcome before mining or promotion.
- Mining MUST be recoverable from cold start: each stage reads current captures
  and writes reviewed intermediate records or promotion decisions.
- Signal strength is based on independent evidence units after deduplication, not
  raw comment count.
- Promotion is a copy-with-pointer operation. The destination receives the
  smallest useful summary plus a pointer back to `_feedback/`; the original
  remains governed by feedback retention and sensitivity rules.
- TODO/GitHub tasks receive only a public-safe summary: problem, segment,
  evidence count, severity, affected files or decision surface, and verification.
  Raw captures, private repo names, personal details, and privileged notes stay in
  `_feedback/` or the scoped case/project store.

## Privacy Rules for Public Artifacts

Public GitHub tasks, PRs, TODO entries, and docs must never include private repo
names, client names, personal data, email addresses, local paths, screenshots, raw
sensitive quotes, or privileged context. Replace identifiers with placeholders
such as `<client>`, `<user-segment>`, `<private-repo>`, and `<case-id>`. If
redaction would remove implementation context, keep the item private or leave it
in `_feedback/` until a maintainer can route it.

## Reach Feedback

Reach/capture telemetry uses the same promotion gates as qualitative feedback.
Thresholds and dry-run issue rules live in
`.agents/aidevops/feedback/mining-promotion.md` under "Reach Feedback
Thresholds".

## CLI Implementation Boundary

The deterministic CLI is design-only. Do not wire `aidevops feedback` into
`.agents/scripts/aidevops.sh` until the phase contracts in the chapters are
stable. The first implementation task should create `.agents/scripts/feedback-helper.sh`
and have `aidevops.sh` delegate to it, mirroring other plane helpers rather than
growing the main CLI file. This does not prevent authorized agents from using
the documented folders directly when the plane is initialized.
