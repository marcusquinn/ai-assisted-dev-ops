<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# External Tool Evaluation

Use this reference when evaluating an external tool, product, framework, or
repository against aidevops: for example, “do we already do this?”, “what can
we learn?”, or “should we adopt it?”. Route those questions to Research; keep
implementation as a separately authorised task.

## Decision workflow

1. State the inspection depth before making implementation claims:
   documentation only; repository metadata; immutable source/test snapshot; or
   operational issues and releases. Report unavailable sources as uncertainty.
2. Start with official claims, then distinguish them from source behaviour and
   operational reports. Do not execute installation commands or repository
   code; scan untrusted external content and keep research read-only.
3. Compare the upstream implementation with aidevops' actual code and
   enforcement, not feature names or guidance alone. Classify overlap as
   equivalent, partial, complementary, absent, or deliberately omitted.
4. Assess marginal value: model/API-call amplification, serial or queue
   latency, CPU/RAM/API pressure, retry and false-positive-verification cost,
   human/agent attention, upgrade burden, and duplicate authority or state.
5. Check failure semantics where decision-relevant: fail-open or blocking
   behaviour, retry/convergence bounds, cancellation and crash recovery,
   deduplication boundaries, sandboxing, and credential exposure.
6. Choose one outcome: adopt, adapt existing machinery, reference-only, defer,
   or reject/no action. Name evidence-backed reconsideration triggers such as
   observed failures or measurable waste.

## Evidence and decision guard

Label conclusions as source-backed fact, maintainer claim, user issue report,
inference, or absent evidence. Issue reports are reports, not confirmed defects
without corroboration. Stop once the evidence can change the decision; source
inspection is decision-relevant, not ceremonial archaeology.

Parity is not value, and a missing feature is not automatically a gap. Do not
recommend an implementation issue from another project's feature list alone:
require an observed failure, measurable waste, or credible expected benefit.
Deliberate omission, no action, and reusing already-sufficient machinery are
successful outcomes. An experiment is justified only when its result can change
the decision.
