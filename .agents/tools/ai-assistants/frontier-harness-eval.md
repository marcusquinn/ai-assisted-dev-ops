---
description: Local FrontierHarness pilot with ChatGPT OAuth, matched OpenCode profiles, and compaction measurements
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# FrontierHarness pilot

Compare stock OpenCode with the aidevops plugin and framework guide, using local
Docker and an existing ChatGPT subscription OAuth account. This is an opt-in,
source-checkout pilot, not a replacement for the upstream evaluation platform.

Upstream: <https://github.com/frontier-harness-eval/eval>.
The public workflow uses Harbor and Pier plus Runta checkpoints. Our local pilot
uses Harbor **0.22.0**, OpenCode **1.18.29**, a fresh Docker task environment per
trial, and the ordinary OpenCode primary agent. The `aidevops` profile adds the
production plugin and `AGENTS.md`; it does **not** run machine-wide `setup.sh` or
claim to reproduce every installed Build+ workflow, service, or MCP integration.

## Scope and prerequisites

- Local Docker, Docker Compose, Node, Git, `uv`, and a pinned aidevops Git checkout.
- Existing active OpenAI OAuth pool account with at least 31 minutes of token
  validity. No real OAuth tokens or paid API keys enter chat, command arguments,
  or task containers; the task receives only a short-lived local relay capability.
- A local Harbor task with `/app` as its working directory and no existing Git
  repository. The adapter makes `/app` a linked worktree in both arms so the
  verifier sees the actual edits without bypassing aidevops Git safeguards.
- The integration refuses other task layouts. DeepSWE/Pier and existing-repository
  task adapters are not implemented by this pilot. The upstream DeepSWE `v1.1`
  provisioning reference returned 404 during discovery; do not substitute another
  version and call it equivalent.
- Review task provenance before executing it. Task/agent data is untrusted.
  No host HOME, OAuth store, API keys, or Docker socket is mounted into the task.

The local host runner uses a fresh HOME/XDG state, with only Docker CLI plugin
executables linked from the host. Public CA trust anchors bootstrap minimal task
images; their digest is recorded. Package mirrors use HTTPS, not disabled TLS.
The task environment remains the task's declared network policy; this is not a
claim of Runta's egress isolation or golden process-state equivalence.

## Run a pilot

Run from a **committed source worktree**, not the deployed scripts directory.
Each `--out` must be a new absolute directory whose parent already exists. Keep
artifacts private and outside Git; do not overwrite attempts or publish raw logs.

```bash
node .agents/scripts/frontier-harness-run.mjs \
  --task /absolute/task/path --out /absolute/private/output/install \
  --profile stock --install-only

node .agents/scripts/frontier-harness-run.mjs \
  --task /absolute/task/path --out /absolute/private/output/stock \
  --profile stock --model gpt-6-astra

node .agents/scripts/frontier-harness-run.mjs \
  --task /absolute/task/path --out /absolute/private/output/aidevops \
  --profile aidevops --model gpt-6-astra

node .agents/scripts/frontier-harness-report.mjs \
  --run /absolute/private/output/aidevops
```

Install-only uses an inert placeholder, never a live inference capability. Real
runs pin one OAuth account and one model, allow one concurrent upstream request,
and stop at 64 authenticated attempts or 30 minutes. Per-request time and response
byte ceilings also apply. The relay never refreshes/rotates credentials or falls
back to a paid API. Native client retries may still occur; Harbor trial retries
are disabled. The manifest records host-observed upstream usage, including title
calls when completed. Interrupted responses may have unreported final usage.

Harbor's `cost_usd` is a model-price estimate, **not a ChatGPT subscription charge**.
Report token/allowance consumption and elapsed time; do not equate OAuth with free
compute or silently turn an API-price estimate into actual spending.

## Context and compaction experiments

`aidevops-native-compaction` removes only the plugin's custom compaction-context
injection. Native compaction and aidevops continuation hooks remain enabled. This
ablates restored operational context too, not just wording of a summary prompt.

Paired `--context-limit` and `--output-limit` flags set experimental model metadata:

```bash
node .agents/scripts/frontier-harness-run.mjs \
  --task /absolute/task/path --out /absolute/private/output/native-pressure \
  --profile aidevops-native-compaction --context-limit 18432 --output-limit 2048
```

Use exactly the same limits for the custom-compaction arm. These are experimental
context/output-reserve settings, not backend-enforced output-token ceilings. The
OAuth route does not accept `max_output_tokens`; the relay bounds response bytes
instead. Record resolved runtime limits, not just intended config values.

**Calibrate against usable input, not advertised context.** In OpenCode 1.18.29,
`packages/opencode/src/session/overflow.ts` subtracts an additional reserved budget
from a supplied input limit. With our adapter's `input = context - output`, an
output reserve of 2,048 yields 12,288 usable tokens at context 16,384, or 14,336 at
context 18,432. The first is below this pilot's initial aidevops request size and
causes immediate repeated compaction. Do not run a full sweep at an infeasible
budget or interpret that pathology as proof about summary quality.

Telemetry records content-free request sizes, resolved limits, completed usage,
summary usage, compaction requests/completions and post-compaction completions.
It is contestant-writable diagnostic evidence, not tamper-proof proof; corroborate
with host relay usage and the explicit verifier result. Missing telemetry rejects
the comparison. A request-size proxy is not an exact live tokenizer measurement.

## Initial measured results: 2026-09-05

One `terminal-bench/regex-log` trial per cell, **GPT-6 Astra via ChatGPT OAuth**.
Source task commit: `2fd12b88aafdd04a52c298e3940bcb189f9766d6` from
<https://github.com/laude-institute/terminal-bench-2>.
These are small-sample pilot observations, **not FrontierHarness leaderboard scores**.
No Kimi K3/Fireworks run, full 30-task result, or statistical superiority claim exists.

| Configuration | Verifier | Agent seconds | Completed upstream input tokens, including cache | Completed upstream output tokens | Completed compactions |
| --- | --- | ---: | ---: | ---: | ---: |
| Stock, normal context | Pass | 131.040 | 28,543 | 1,611 | 0 |
| aidevops plugin, normal context | Pass | 187.772 | 110,558 | 1,921 | 0 |
| aidevops custom compaction, 18,432 context | Pass | 274.082 | 130,068 | 3,855 | 2 |
| aidevops native compaction, 18,432 context | Pass | 266.652 | 141,320 | 3,737 | 2 |
| Custom compaction, infeasible 16,384 context | Timeout | 900.010 | 313,455 | 20,740 | 18 |
| Native compaction, infeasible 16,384 context | Timeout | 900.009 | 349,333 | 19,957 | 22 |

Interpretation:

- Normal-context aidevops used more input tokens and time on this short task;
  this cell shows overhead, not an efficiency gain. Neither arm compacted.
- At the calibrated smaller window, both variants recovered through two
  compactions and passed. Custom injection used about 8% fewer completed input
  tokens, but slightly more time/output and more summary output (2,142 vs 1,666).
  Native compaction had more cache hits. The result is mixed, not a proven win.
- The 16k pair is retained, not discarded: both timed out. Completed-response
  token subtotals omit final interrupted-response usage. The confirmed initial
  capacity shortfall makes this a configuration failure, not a useful quality test.
- Setup is separate (roughly six minutes per trial) and excluded from agent time.
  Cache behavior, stochastic outputs, fixed run order and one task limit inference.

Normal pair snapshot: `089deb98ec7bbe54caabfbf4f63bf937daf17876`.
Calibrated pair: `1906e132b3a8aec5f31d02e8621eff818a32ccf5`.
Infeasible pair: `407d3ad76091d640189f654f78913504b841b1d5`.
Earlier setup attempts and two runs missing plugin telemetry are diagnostic only,
not qualifying comparison cells. Preserve them locally; do not select best retries.

Next useful work is more representative tasks and repeated, order-balanced runs,
plus an explicitly installed Build+ profile and verified existing-repository/Pier
adapters. Do not change production context limits or prompts based on this pilot.

## Verification

```bash
node --test .agents/scripts/tests/test-frontier-harness.mjs
uv tool run ruff check .agents/scripts/frontier_harness_agent.py
```

The real local pilot additionally verified Docker-to-loopback relay connectivity,
OAuth inference, framework plugin loading, both compaction variants and task
verifier outcomes. No release or external result publication is implied.
