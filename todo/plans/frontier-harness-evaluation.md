<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# FrontierHarness evaluation integration

## Aim and authority

Implement a reusable comparison of stock OpenCode and OpenCode with aidevops,
including the effects of context constraints and custom compaction guidance.
Interactive full-loop implementation and PR/merge are authorized. Release,
external leaderboard submission and paid API/cloud spending are not authorized.
The user selected existing ChatGPT Pro OAuth and local infrastructure for the
pilot. Six qualifying pilot cells have run; no general superiority is established.

## Source evidence (2026-09-05)

- Upstream: <https://github.com/frontier-harness-eval/eval>, inspected commit
  `8f11b130c30bbf76ca1f3edeea70abc773bd8d2c`.
- Upstream supplies provisioning, trial execution, normalization and reporting
  under `skills/frontierharness-eval/`; do not recreate that platform.
- Provisioning pins Harbor 0.22.0, datacurve-pier 0.3.1 and DeepSWE `v1.1`.
  GitHub API lookup of `datacurve-ai/deep-swe` ref `v1.1` returned 404; tags
  exposed only `v1.0.0`. Resolve the correct benchmark corpus with evidence,
  rather than substituting a different dataset or claiming comparability.
- Harbor 0.22.0 is available via `uv tool run`; local Docker is operational.
  Runta and Pier are not used in this pilot. OpenCode is pinned to 1.18.29;
  the published OpenCode baseline is 1.18.19.
- The upstream Terminal-Bench template uses `-r 2` exception retries. Audit the
  installed runner semantics and preserve every attempted run and its spend;
  do not describe this as an unconditional single-attempt runner.
- The public normalizer cannot reproduce private first-turn cache repricing.
  Use raw total spend / passes and leave unavailable metrics null.

## Experiments

1. Primary matched comparison: stock OpenCode versus the aidevops plugin and
   framework guide, identical pinned runtime, GPT-6 Astra through ChatGPT OAuth,
   task, budgets and local Docker preparation. This is not K3 leaderboard-equivalent
   or a claim to reproduce every installed Build+ service/workflow.
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

- [x] Resolve and exercise the pinned Harbor 0.22.0 interface.
- [ ] Resolve Pier and the unavailable DeepSWE ref before extending beyond the pilot.
- [x] Add an evaluation workflow under `.agents/tools/ai-assistants/`, with a
  discoverability link and explicit spend, privacy and comparability gates.
- [x] Implement a local Harbor adapter for non-repository `/app` tasks.
- [ ] Extend to existing-repository layouts and Pier with verified interfaces.
- [x] Ensure aidevops is installed inside task execution environments, not just
  the outer runtime; verify plugin/instruction loading from runtime evidence.
- [x] Preserve linked-worktree safety and ensure the verifier receives edits
  at its expected task path. Do not disable guards to manufacture a pass.
- [x] Add symmetric, content-free context/compaction telemetry to both arms.
- [x] Add an analysis helper reusing upstream trial records, not a new scorer.
- [x] Run scoped checks, focused contract tests and real OAuth-backed Docker trials.
- [x] Run normal, infeasible-pressure and calibrated-pressure matched pilot pairs.
- [ ] Establish repeated, representative-task results before forecasting a full sweep.

PR/review/merge state is tracked by the interactive full-loop lifecycle, not by a
premature completion checkbox in this plan. No release is requested.

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

The pilot implementation and real local verification are complete. See
`.agents/tools/ai-assistants/frontier-harness-eval.md` for methods and conclusions,
and `frontier-harness-pilot.json` beside it for measurements and evidence digests.
Both normal arms passed, with higher overhead for aidevops on this short task.
Both calibrated-pressure arms passed after two compactions; resource results were
mixed. Both deliberately overconstrained 16k runs timed out and remain recorded.
Earlier runs with missing plugin telemetry are diagnostic, not qualifying cells.
No paid API fallback, Runta provisioning, release or leaderboard submission occurred.
Remaining broader-suite work is explicitly unchecked above.
