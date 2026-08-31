<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Recovery Plan: {objective}

## Recovery Contract

- **Parent task/issue:** {task ID or issue reference}
- **Trigger:** {resource, security, cost, timeout, process, or external blocker}
- **Created (UTC):** {YYYY-MM-DDTHH:MM:SSZ}
- **Deadline (UTC):** {created + 24 hours by default}
- **Attempt budget:** {3 attempts by default}
- **Attempts used:** 0
- **Plan owner:** {runner or accountable person}
- **Current state:** recovering
- **Stop condition:** {verified recovery outcome or explicit escalation condition}

## Objective and Constraints

**Objective:** {the original unfinished objective; do not replace it with the recovery action}

**Known evidence:**

- {observable symptom, command result, artifact, or metric}

**Constraints and safety boundaries:**

- {authority, data-loss, billing, secret, rate-limit, or resource boundary}

## Attempt Checkpoints

Append one row after every attempt. Do not rewrite previous rows.

| Attempt | Timestamp (UTC) | Action and command/product path | Observable result and evidence | Attempts remaining | Exact next action |
|---------|-----------------|---------------------------------|--------------------------------|--------------------|-------------------|
| 1 | {timestamp} | {bounded action} | {result plus log/artifact/reference} | 2 | {next action} |

## Follower Tasks

Every follower must use exactly one classification: `worker-available` or
`human-only`.

| ID/reference | Deliverable and files/scope | Classification | Dependency or human blocker | Verification | Owner |
|--------------|-----------------------------|----------------|-----------------------------|--------------|-------|
| {ID} | {worker-ready action and target files} | worker-available | {dependency or none} | {automatable command/product path} | {runner} |
| {ID} | {specific human action} | human-only | {authority/secret/destructive decision and unblock evidence} | {evidence that permits reclassification} | {person/role} |

Classification rules:

- **`worker-available`:** scope and inputs are accessible, dependencies are
  resolved, verification is automatable, and no human-only authority remains.
- **`human-only`:** a named human action is genuinely required. Record the
  reason, owner, and evidence that will unblock automation. Reclassify promptly
  when that evidence exists.

## Deadline or Budget Exhaustion

When the deadline arrives or the attempt budget reaches zero:

1. Stop automatic retries and preserve the latest checkpoint.
2. Record the remaining objective, current evidence, and safest next action.
3. Escalate through `reference/safety-stop-recovery.md`; do not mark the parent
   completed, skipped, or cancelled solely because recovery expired.
4. Keep `worker-available` followers dispatchable and identify the exact blocker
   for each `human-only` follower.

## Verification Checklist

- [ ] Deadline is absolute UTC and no later than 24 hours by default.
- [ ] Attempt budget is explicit and no more than 3 by default.
- [ ] Every used attempt has an immutable observable checkpoint.
- [ ] Each checkpoint records evidence, remaining budget, and the next action.
- [ ] Every follower has one classification and an accountable owner.
- [ ] Every `worker-available` follower has files/scope and automatable verification.
- [ ] Every `human-only` follower names the human action and unblock evidence.
- [ ] Parent objective and dependency links remain open until independently verified.
- [ ] Exhaustion routes to escalation without continuing an unchanged retry loop.
