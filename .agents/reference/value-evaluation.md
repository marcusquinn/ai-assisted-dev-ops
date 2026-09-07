<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Value evaluation

Evaluate aidevops profiles by verified user value, not by task, token, or cache
counts alone. This bounded protocol reuses existing immutable evidence, records
missing evidence, and does not create another telemetry database.

## Measures

Every report states the unit, source, coverage, and confidence for each measure.
`null` means unknown; it never means zero.

| Measure | Unit | Required evidence |
| --- | --- | --- |
| Verified outcome | Boolean plus verifier identity | Independent product/task verifier and retained source digest |
| User active time | Seconds | Direct bounded observation or user-provided measurement |
| User interruptions | Count | Requests requiring otherwise avoidable user attention |
| User corrections | Count | Corrections needed to obtain the accepted outcome |
| Elapsed delivery | Seconds | Stable start and terminal timestamps for the complete workflow |
| Recurring work eliminated | Named recurrence and estimated occurrences | Reusable artifact plus observed or explicitly modelled baseline |
| Maintenance effort | Seconds per stated period | Repairs, updates, and review attributable to the capability |
| Monetary benefit | Currency and period | Observed change or labelled model with assumptions |
| Actual paid charges | Currency | Provider/cloud invoice or account-owned metering |
| Fixed subscription cost | Currency and period | Subscription record and stated allocation method |
| Allowance consumption | Provider-native units | Account-owned usage evidence |
| Hypothetical API cost | Currency | Versioned price model, labelled as an estimate |

Machine duration, requests, tokens, compactions, and estimated API prices are
supporting diagnostics. They do not establish user time, benefit, or actual cost.

## Protocol

1. Select a small matrix containing a short task, longer systems work, and a
   non-code information workflow. State the installed profile and required
   capability before each run.
2. Define the accepted outcome and independent verifier before execution. Never
   use model self-report, token use, or process exit alone as outcome evidence.
3. Match model, provider, limits, tools, task input, and verifier. Alternate order
   and repeat cells where affordable; otherwise mark the sample limitation.
4. Keep attempts immutable. Retain failures, timeouts, interruptions, partial
   usage, and missing measurements; do not select the best retry.
5. Record user-active time separately from machine and elapsed time. Count
   interruptions and corrections only when their definitions are observable.
6. Separate actual charges, fixed subscriptions, allowance consumption, and
   hypothetical API-price estimates. Unknown cost is not free usage.
7. Record reusable output and maintenance only where evidence ties them to future
   work. State recurrence and attribution assumptions.
8. Compare matched cells only. Profile, runtime, and provider differences remain
   visible and prevent unsupported causal claims.

Raw prompts, account identifiers, OAuth material, invoices, and private logs stay
outside Git. Repo evidence contains only redacted measures, configuration identity,
verifier references, coverage, confidence, and source digests.

## Representative matrix

| Workflow | Intended outcome | Profiles | Minimum verifier | Current evidence |
| --- | --- | --- | --- | --- |
| Short terminal task | Correct repository change | Stock and aidevops | Task verifier | One matched trial per cell |
| Longer systems work | Accepted multi-step change through lifecycle | Installed and focused/lighter | Tests, review, and merged outcome | Not yet measured |
| Non-code information work | Accepted decision-ready artifact | Domain-primary and lighter delegated | Human acceptance plus factual/source checks | Not yet measured |

The unmeasured rows are protocol commitments, not failed or zero-value results.
No outreach, financial mutation, purchase, or production deployment is authorised
merely to fill a report cell.

## Initial bounded report: 2026-09-05 pilot

Source: `.agents/tools/ai-assistants/frontier-harness-pilot.json`, six immutable
`terminal-bench/regex-log` cells, one trial per cell, GPT-6 Astra through a local
ChatGPT OAuth relay, OpenCode 1.18.29, and Harbor 0.22.0. Source result, event, and
manifest SHA-256 digests are retained per cell.

| Finding | Evidence | Coverage/confidence |
| --- | --- | --- |
| Normal stock outcome | Verifier pass; 131.040 agent seconds | Measured, one trial; limited |
| Normal aidevops outcome | Verifier pass; 187.772 agent seconds | Measured, one trial; limited |
| Calibrated 18,432-context outcomes | Both variants passed after two compactions | Measured, one trial each; limited |
| Infeasible 16,384-context outcomes | Both variants timed out and were retained | Measured failures; configuration not comparative |
| User active time, interruptions, and corrections | No source measurement | Unknown |
| Elapsed delivery and recurring work eliminated | No complete workflow baseline | Unknown |
| Maintenance effort and monetary benefit | No attributable source evidence | Unknown |
| Actual charges, subscription allocation, and allowance use | OAuth route recorded; account economics absent | Unknown |
| Hypothetical API cost | Harbor estimate is not an actual charge | Excluded from actual-spend conclusions |

The normal aidevops cell used more agent time and completed input tokens on this
single short task. That is observed overhead, not evidence of lower user value.
The pilot does not cover longer systems work or non-code information workflows,
does not measure human attention or money, and cannot support broad superiority
or a 100x claim.

## Report contract

`frontier-harness-report.mjs --run` keeps schema-1 consumers compatible and adds a
`value_metrics` object. The independent verifier supplies `verified_outcome`.
Unmeasured attention, elapsed-delivery, recurrence, maintenance, and economic
fields are `null` with explicit coverage. Existing agent/setup duration and usage
fields remain supporting metrics outside this value object.

The next information gap is user-attention evidence for accepted longer systems
and non-code outcomes—not another token-only sweep.

## Verification

```bash
node --test .agents/scripts/tests/test-frontier-harness.mjs
node --test .agents/scripts/tests/test-model-replay-benchmark.mjs
.agents/scripts/linters-local.sh --changed
```
