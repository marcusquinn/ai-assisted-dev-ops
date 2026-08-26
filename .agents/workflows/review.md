---
description: Review an issue, PR, local patch, branch, or commit through the shared review core
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Unified Review

Review target: `$ARGUMENTS`

Read `reference/review-core.md` first. Select exactly one target and policy:

| Invocation | Policy |
|---|---|
| `/review issue <number-or-URL>` | maintainer |
| `/review pr <number-or-URL>` | maintainer |
| `/review local` | closeout |
| `/review branch [base-ref]` | closeout |
| `/review commit <ref>` | closeout |

Optional behavior flags:

- `--report-only`: never edit; return findings and repair guidance.
- `--fix`: repair verified in-scope findings when the current session has edit
  authority. This is already the default inside a workflow-owned change.
- `--max-priority P1|P2|P3`: widen the default P0-only closeout review.

With no explicit target, prefer uncommitted changes; otherwise use the current
branch against its open PR base or configured remote default. If neither resolves
unambiguously, ask for a target rather than reviewing an empty or guessed diff.

## Issue and PR targets

Follow `workflows/review-issue-pr.md`. That workflow owns problem validation,
temporal duplicates, root cause, architecture, disposition, and durable comments.
The legacy `/review-issue-pr` command remains an alias for this policy.

### External PR authority preflight

Before requesting cryptographic approval for an external or fork PR, complete
every approval-bound body, closing-linkage, and metadata repair. Then run:

```bash
full-loop-helper.sh pre-merge-gate <PR_NUMBER> <OWNER/REPO>
```

When the read-only preflight reports missing targets, provide its one mixed
`sudo aidevops approve batch issue:N pr:N... OWNER/REPO` command unchanged.
Regenerate the command after any PR head, body, linkage, or metadata change;
the final merge-time guard independently rechecks the live snapshot. Do not
request approval when the preflight reports that no authority is required.

## Local, branch, and commit targets

1. Build the exact bundle:

   ```bash
   review-evidence-helper.sh bundle local
   review-evidence-helper.sh bundle branch --base origin/main
   review-evidence-helper.sh bundle commit --commit HEAD
   ```

2. Freeze the scope baseline from the request and bundle.
3. Review for introduced P0 blockers by default: correctness, concrete security
   exposure, data loss, broken normal flow, install/upgrade failure, or crash.
4. Verify each candidate against the real source, tests, dependency contracts,
   and adjacent ownership boundary.
5. In a workflow-owned change or with `--fix`, repair accepted in-scope findings
   autonomously, rerun focused proof, and rebuild/review the changed bundle. With
   `--report-only`, recommend the repair without modifying files.
6. Apply the shared two-cycle and scope-growth limits. Additive findings become
   follow-up work instead of expanding the current change.

## Output

Report:

- target, policy, and evidence bundle digest;
- focused tests or proof inspected;
- accepted findings with priority and `file:line`;
- rejected findings with a brief evidence-based reason;
- final result: `clean`, `blocked`, or `needs-decision`;
- any autonomous fixes and the resulting new bundle digest.

Do not claim independent review when the implementing model reviewed its own
change. State the reviewer source accurately. Use an independent model only when
risk or explicit user intent justifies its latency and cost.
