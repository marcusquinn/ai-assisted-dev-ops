<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# FrontierHarness evaluation integration

## Aim and authority

Implement a reusable comparison of stock OpenCode and OpenCode with aidevops,
including the effects of context constraints and custom compaction guidance.
Interactive full-loop implementation and PR/merge are authorized. Release,
public benchmark claims, and an unbounded paid benchmark run are not authorized.
No benchmark has run and no performance improvement has been established.

## Source evidence (2026-09-05)

- Upstream: <https://github.com/frontier-harness-eval/eval>, inspected commit
  `8f11b130c30bbf76ca1f3edeea70abc773bd8d2c`.
- Upstream supplies provisioning, trial execution, normalization and reporting
  under `skills/frontierharness-eval/`; do not recreate that platform.
- Provisioning pins Harbor 0.22.0, datacurve-pier 0.3.1 and DeepSWE `v1.1`.
  GitHub API lookup of `datacurve-ai/deep-swe` ref `v1.1` returned 404; tags
  exposed only `v1.0.0`. Resolve the correct benchmark corpus with evidence,
  rather than substituting a different dataset or claiming comparability.
- Runta, Harbor and Pier are not installed in the development environment.
  OpenCode reports 1.18.29. The published OpenCode baseline is 1.18.19.
- The upstream Terminal-Bench template uses `-r 2` exception retries. Audit the
  installed runner semantics and preserve every attempted run and its spend;
  do not describe this as an unconditional single-attempt runner.
- The public normalizer cannot reproduce private first-turn cache repricing.
  Use raw total spend / passes and leave unavailable metrics null.

## Experiments

1. Primary matched comparison: stock OpenCode versus aidevops, identical pinned
   runtime, Kimi K3, provider, task set, budgets, hardware and checkpoint policy.
   Preserve normal aidevops behavior within the declared offline environment.
2. Compaction ablation: same aidevops configuration with only its custom
   compaction-context injection removed. Keep native automatic compaction and
   continuation behavior unchanged. Label this a context-injection ablation,
   not a pure prompt-wording experiment: the hook also restores operational state.
3. Context-policy experiment: declare explicit native and constrained windows,
   crossed with custom compaction on/off if pilot evidence justifies the spend.
   Keep model/provider fixed within each experiment. Never attribute a model
   swap to the harness or call a non-K3 run leaderboard-compatible.

The inspected production caps are model-specific, not a universal K3 cap:
`.agents/plugins/opencode-aidevops/config-hook.mjs` registers Claude limits and
the GPT-5.6 cap. Read `model-limits.mjs` and resolved runtime configuration before
selecting experimental windows. An artificial smaller K3 window is a stress
experiment, not evidence of a current production K3 optimization.

## Implementation units (primary session owns the critical path)

- [ ] Resolve pinned Harbor/Pier agent interfaces and corpus availability.
- [ ] Add an evaluation workflow under `.agents/tools/ai-assistants/`, with a
  discoverability link and explicit spend, privacy and comparability gates.
- [ ] Implement the smallest adapter compatible with both pinned runners.
  Upstream Harbor's current OpenCode adapter accepts a config overlay, but its
  current API must not be assumed to match 0.22.0 or Pier 0.3.1.
- [ ] Ensure aidevops is installed inside task execution environments, not just
  the outer runtime; verify plugin/instruction loading from runtime evidence.
- [ ] Preserve linked-worktree safety and ensure the verifier receives edits
  at its expected task path. Do not disable guards to manufacture a pass.
- [ ] Add symmetric, content-free context/compaction telemetry to both arms.
- [ ] Add an analysis helper reusing upstream trial records, not a new scorer.
- [ ] Run existing scoped checks and a focused contract check where necessary.
- [ ] Obtain provider/runtime access and a finite paid pilot cap, then smoke-test
  one Terminal-Bench and one DeepSWE task per arm from fresh restores.
- [ ] Forecast full-run cost from measured all-attempt usage and infrastructure.
- [ ] Review exact diff, commit, PR, remote checks, merge; no release requested.

## Measurement contract

Record versions/commits, resolved model/provider/context limits, config hashes,
task/image identifiers, checkpoint, retry policy, attempt identifiers and budget.
Isolate HOME/XDG/session/memory state per trial. Retain within-trial memory and
compaction behavior; never import personal state or credentials into checkpoints.

Measure verifier pass/fail, all-attempt cost, duration, input/output/cache usage,
request and tool counts, compaction requests/completions/failures, summary usage,
and request-size proxy before and after compaction. Do not confuse cumulative
tokens with live context occupancy or character counts with tokenizer counts.
Avoid logging prompt, summary, tool-output or credential content in telemetry.

Report telemetry coverage and missing values explicitly. Zero compactions means
the trial did not exercise compaction, not that custom compaction is ineffective.
Post-compaction success is descriptive, not causal proof; use matched ablations
to estimate effects. Report every task, including crashes and timeouts, and keep
confirmed infrastructure failures separate. No cherry-picking or selecting the
best retry. Preserve immutable attempts rather than overwriting upstream run IDs.

## Current checkpoint

Discovery and safe worktree setup are complete; implementation remains open.
No adapter, telemetry or report helper has been implemented. No live trials,
model calls by benchmark contestants or Runta provisioning have been performed.
Next: settle paid pilot authorization/provider access and resolve the unavailable
corpus ref, then implement against the verified pinned runner interfaces.
