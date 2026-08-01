---
description: Recommend a canonical workload tier using task evidence and pattern history
agent: Build+
mode: subagent
model: standard
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Recommend the lowest canonical workload tier with a credible one-pass path to a
safe, complete result.

Task: $ARGUMENTS

## Instructions

1. Recall cross-session pattern history:

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --type SUCCESS_PATTERN --limit 10
~/.aidevops/agents/scripts/memory-helper.sh recall --type FAILURE_PATTERN --limit 10
```

2. Read `reference/task-taxonomy.md` "Canonical Assignment Policy". It is the
   single source for issue-tier semantics; runtime model mapping is separate.
3. Assess specification, novelty, consequence/reversibility, trust boundaries,
   coordination/recovery, context burden, and verification evidence.
4. Apply the policy in order:
   - consequential unresolved decision or dispatch-path override → `thinking`
   - complete, verified, low-consequence execution contract → `simple`
   - otherwise → `standard`
   Counts, estimates, and isolated keywords are not standalone gates.
5. Combine the policy with pattern data:
   - >75% success with 3+ samples: weight pattern history heavily
   - sparse or inconclusive data: use the canonical policy
   - conflict between data and policy: preserve safety/authority gates, recommend
     a tier, and explain the conflict
6. Output:

```text
Recommended: {simple|standard|thinking}
Reason: {one-line justification naming the decisive policy evidence}
Safety/authority gate: {none | blocker that tier escalation cannot bypass}
Pattern data: {success_rate}% success rate from {N} samples (or "no data")
```

7. If ambiguity remains, distinguish its kind:

```text
Defaulted to standard because: {missing proof of a complete simple contract}
Thinking trigger if confirmed: {consequential unresolved decision, if any}
```
