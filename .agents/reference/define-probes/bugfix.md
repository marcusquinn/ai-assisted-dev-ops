---
description: Probing questions for bugfix tasks — surfaces reproduction context and regression risks
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Bugfix Probes

Use this file as a candidate pool during `/define` for **bugfix** tasks. Reuse supplied reproduction and expected-behaviour evidence; ask only when an unanswered point can materially change scope, root-cause strategy, user-visible behaviour, or regression acceptance.

## Default Assumptions

Apply unless overridden:

- Preserve all behavior except the bug.
- Reproduce and verify the failure through the existing production-facing path, logs, or framework diagnostics.
- Add a focused regression test only when explicitly requested or when it is the lowest-cost way to resolve material uncertainty; see `reference/ci-gate-policy.md`.
- Prefer root-cause fix over symptom suppression.
- No scope creep — fix the reported bug only.

## Decision-Relevant Candidates

### Reproduction

```text
Can you reproduce this reliably?
1. Yes (steps provided)
2. Intermittent (under specific conditions)
3. Reported by others (not yet reproduced)
4. Environment-specific (e.g., production only)
```

### Expected vs Actual

```text
What is the expected behavior vs actual?
1. Inferred from description (recommended)
2. Explicitly described
```

## Optional Specialist Probes

### Root Cause vs Symptom

```text
Is the fix addressing the root cause or a symptom?
1. Root cause (recommended)
2. Symptom/workaround
3. Not sure (investigate first)
```

### Blast Radius

```text
What else could break?
1. Nothing (isolated fix - recommended)
2. Related features sharing code path
3. Not sure (trace dependencies)
4. User-specified risks
```

### Regression Context

```text
Did this work before?
1. Yes (regression)
2. Never (latent bug)
3. Environment-specific
4. Unknown start
```

### Assumption Surfacing

```text
I'm assuming this affects [inferred scope]. Correct?
1. Yes
2. No (narrower)
3. No (broader)
```

### Pre-mortem

```text
If the bug returns in a different form, what's most likely?
1. Same root cause, different trigger (recommended)
2. New bug in adjacent code
3. Environment-specific failure
4. Deeper issue (original report incomplete)
```

## Sufficiency Test

Verify before generating brief:

- Reproduction steps clear?
- Root cause identified or investigation path set?
- Regression test defined?
- Blast radius assessed?

Ask one targeted question only when an unknown above is consequential and cannot be resolved from evidence or a safe default.
