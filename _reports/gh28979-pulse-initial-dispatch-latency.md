# Issue #28979 Pulse initial-dispatch latency report

## Decision

**Inconclusive sample.** The measured post-deployment cohort has one completed
cycle on one runner. This is below the required 28 aggregate cycles and eight
cycles per participating runner, so the observed latency changes are not
evidence of improvement or regression.

## Deployment boundary

- Release `v3.32.199` was published at `2026-07-31T04:53:15Z`.
- The release tag contains merge `09ce15164d576012c030cc11f9c8feb05b80d752`
  from #28976 (`git merge-base --is-ancestor` returned success).
- The measured runner reports deployed aidevops `3.32.199`.
- The deployed `pulse-dispatch-preflight-lib.sh` and
  `pulse-diagnose-helper.sh` are byte-identical to the corresponding source at
  the measurement head (`git diff --no-index --quiet` returned success for
  both).
- The deployed `VERSION` file mtime is epoch `1785506173`, or
  `2026-07-31T13:56:13Z`. This later local deployment boundary, rather than the
  release publication time, defines the cohort cutoff.

## Runner coverage

Sanitized aliases deliberately avoid machine identifiers.

| Runner | Deployment proof | Completed cohort cycles | Status |
|---|---|---:|---|
| runner-a | v3.32.199 plus source equality | 1 | measured |
| runner-b | unavailable to this worker | 0 | excluded; Pulse participation not proven |
| runner-c | unavailable to this worker | 0 | excluded; Pulse participation not proven |
| **Aggregate measured cohort** | runner-a only | **1** | below minimum |

Pulse runners do not share local telemetry, so missing runner-b/runner-c data
is not interpreted as zero latency or as proof that those machines did not run
Pulse.

## Before/after latency

The post-deployment command used an explicit clock and cutoff so no
pre-deployment cycle entered the cohort:

```bash
PULSE_DIAGNOSE_NOW_EPOCH=1785513846 \
  .agents/scripts/pulse-diagnose-helper.sh cycle-health \
  --window 7673 --json
```

This produced cutoff `2026-07-31T13:56:13Z` and one completed fill-floor cycle.

| Stage | Cohort | Runs | Timeouts | p50 | p95 | Change from baseline p50 | Change from baseline p95 |
|---|---|---:|---:|---:|---:|---:|---:|
| `preflight_early_dispatch` | baseline | 28 | not recorded | 601s | 1,251s | — | — |
| `preflight_early_dispatch` | post-deploy | 1 | 0 | 552s | 552s | -8.2% | -55.9% |
| `preflight_post_label_refill` | baseline | 28 | not recorded | 489s | 960s | — | — |
| `preflight_post_label_refill` | post-deploy | 1 | 0 | 746s | 746s | +52.6% | -22.3% |

With one observation, p50 and p95 are the same value. The percentages are
descriptive only; they cannot establish a material code-path effect.

## Throughput and guardrails

The current-state snapshot generated at `2026-07-31T16:10:33Z` is reported
separately because its 15-minute window does not equal the completed-cycle
cohort:

| Signal | Value |
|---|---:|
| Maximum workers | 24 |
| Active workers | 2 |
| Available slots | 22 |
| Dispatch-eligible available/unassigned issues | 5 |
| Worker launches in the 15-minute snapshot | 4 |
| Launch-validation failures | 0 |
| Guardrail successes | 1 |
| Guardrail no-dispatchable outcomes | 3 |
| Guardrail failures | 0 |

`cycle-health` does not currently emit launches per cycle, idle-slot cycles,
or zero-launch cycles with runnable authorized candidates. Those three cohort
metrics are therefore **not available**, rather than inferred from the
differently bounded current-state snapshot. No dominant pre-launch blocker was
reported in that snapshot.

## Dependency safety

Focused verification against the deployed source contract passed:

- `test-dependency-readiness-normalization.sh`: 46 passed, 0 failed. This
  includes keeping a blocked child out of the fast candidate mode and making a
  newly ready child reach the shared candidate stream after normalization.
- `test-pulse-dispatch-engine-stage-wiring.sh`: 38 passed, 0 failed. This
  includes initial-fill normalization skip and default normalized refill.

The one-cycle operational cohort contains no recorded dependency-safety
failure, but it is too small and the cycle-health schema does not encode
per-candidate dependency relationships. The test evidence therefore confirms
the deterministic contract, not production incidence across three runners.

## Competing-pressure checks

- GitHub GraphQL headroom at the current-state snapshot was 3,327/5,000 with
  zero circuit-breaker trips, zero reserve-mode cycles, and cadence risk `ok`.
- Provider state showed one available OpenAI account, 24 capacity slots, zero
  rate-limited events, and zero auth errors.
- Dispatch capacity recorded zero load-pressure points and 22 available slots.
- Queue scanning completed with zero errors.

These checks do not show API, provider, host-load, or queue-scan pressure that
would explain the single observed cycle. They also do not remove the sample-size
limitation.

## Recommendation

Keep the result **inconclusive**. Repeat the exact deployment-bounded
collection when telemetry from each participating runner is available and the
cohort reaches at least 28 completed cycles in aggregate and eight per runner.
Do not file a regression repair issue from this sample: no safety invariant
failed, timeout frequency did not rise in the measured cohort, and the latency
sample is insufficient for causal attribution.
