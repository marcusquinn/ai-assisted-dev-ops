---
description: Tier optimisation from production telemetry and sealed historical model replay
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# /optimize-tiers

Use production dispatch telemetry and deterministic historical replay to evaluate
model-tier and reasoning-effort changes. Do not change routing from benchmark
results until the result is confirmed and consistent with production evidence.

Topic: $ARGUMENTS

## Production telemetry

### `/optimize-tiers report`

Show current tier dispatch telemetry from production data:

```bash
~/.aidevops/agents/scripts/dispatch-ledger-helper.sh tier-report
```

Outputs include dispatches, outcomes, escalation counts, pass rates, and dominant
failure reasons by tier. Telemetry is recorded automatically by:

- `dispatch-ledger-helper.sh register` — records tier + model at dispatch time
- `dispatch-ledger-helper.sh record-outcome` — records outcome + escalation reason
- Append-only log: `~/.aidevops/.agent-workspace/tmp/tier-telemetry.jsonl`

## Historical replay

Keep corpora, repository catalogs, candidate files, prompts, patches, artifacts,
results, and reports outside Git under a private local directory. Never publish
private repository identities or archived prompts.

The local benchmark operator and curated checks are trusted. Integrity hashes,
read-only prediction files, exclusive result appends, and run locks detect drift
and ordinary tampering; they are not cryptographic attestation against a
malicious process already running as the same local account.

```bash
ROOT="${HOME}/.aidevops/.agent-workspace/work/model-replay"
CORPUS="${ROOT}/corpus"
CATALOG="${ROOT}/repositories.json"
CANDIDATES="${ROOT}/candidates.json"
EXPERIMENT="${ROOT}/experiments/quick-primary-autonomous"
HELPER="${HOME}/.aidevops/agents/scripts/brief-tier-test-helper.sh"
```

### 1. Initialise and populate the corpus

```bash
"$HELPER" init --corpus "$CORPUS"
```

The default design requires three repository profiles, nine quick cases, and
eighteen full cases. For each case, archive:

- the exact historical prompt, or explicitly mark a reconstruction;
- an immutable full base commit SHA;
- a reference patch kept unavailable to the model;
- deterministic `fail_to_pass` and `pass_to_pass` command arrays;
- provenance, visibility, merge date, expected tier, and supported replay modes.

Register each case with `add-case`, then edit the generated local repository
catalog so each repository key resolves to a local canonical checkout. The
catalog is never passed to the model.

```bash
"$HELPER" add-case \
  --corpus "$CORPUS" \
  --case-id CASE_ID \
  --repo-key REPOSITORY_KEY \
  --profile PROFILE \
  --tier simple \
  --base-sha FULL_COMMIT_SHA \
  --prompt-file ARCHIVED_PROMPT \
  --gold-patch REFERENCE_PATCH \
  --checks-file HIDDEN_CHECKS_JSON \
  --visibility private \
  --quick

"$HELPER" qualify \
  --corpus "$CORPUS" \
  --catalog "$CATALOG" \
  --repetitions 3
```

Qualification fails closed unless the target checks fail on the base, regression
checks pass on the base, all checks pass after the reference patch, prompt scans
pass, and repeated outcomes are deterministic. It resolves the exact full commit,
rejects base symlinks and gitlinks, and runs checks with a minimal environment
that excludes parent credentials and Git overrides.

### 2. Configure candidates

Create a local candidate JSON file using schema
`aidevops-model-replay-candidates/v1`. It requires:

- an explicit provider allowlist;
- one `provider/model`, tier, primary effort, and supported effort list per model;
- the `opencode` runtime and a bounded timeout;
- a knowledge cutoff for public cases.

Anthropic-family providers and models are rejected by policy, including Claude
models exposed through another provider. Use only providers explicitly approved
for the experiment.

### 3. Plan and seal predictions

Create separate experiment directories for autonomous and prescriptive replay.
The modes must never be aggregated.

```bash
"$HELPER" plan \
  --corpus "$CORPUS" \
  --candidates "$CANDIDATES" \
  --experiment "$EXPERIMENT" \
  --experiment-id quick-primary-autonomous \
  --suite quick \
  --stage primary \
  --mode autonomous
```

Fill every field in `prediction-template.json` before any provider call, then
seal it. The CLI will not replace or reseal an existing prediction ledger.

```bash
"$HELPER" seal \
  --experiment "$EXPERIMENT" \
  --input "${ROOT}/predictions/quick-primary-autonomous.json"

"$HELPER" run \
  --experiment "$EXPERIMENT" \
  --corpus "$CORPUS" \
  --catalog "$CATALOG" \
  --dry-run
```

The dry run holds the experiment lock, validates the corpus, catalog, exact base
trees, plan, candidate, prediction, and runtime seals, makes zero provider calls,
and writes a reproducible report.

### 4. Execute and interpret

```bash
"$HELPER" run \
  --experiment "$EXPERIMENT" \
  --corpus "$CORPUS" \
  --catalog "$CATALOG"

"$HELPER" report --experiment "$EXPERIMENT"
```

Each cell runs in a fresh synthetic one-commit linked worktree with no remote or
later history. Correctness comes only from hidden deterministic checks; diff
similarity and LLM grading are excluded. Reports compare completion, functional
correctness, model/effort evidence, duration, cost when observed, failure class,
pairwise separation, and sealed-prediction calibration.

Model execution requires the restricted OpenCode profile, scoped provider auth,
an isolated sandbox, and enforced provider-only whole-process egress. A pass also
requires a concrete structured provider-request record and resource metric. The
captured patch is reapplied to another clean synthetic base and regraded; prompt,
log, metrics, and patch hashes remain bound to the append-only result record.
Dry runs never contact providers and do not require an egress backend. Before a
real run, set `AIDEVOPS_WORKER_EGRESS_BACKEND` to an absolute executable that
implements the v1 kernel/equivalent contract documented by
`sandbox-exec-helper.sh`; model replay fails before provider execution when this
trusted operator prerequisite is absent. Never use a test fixture backend.
Each deterministic check receives a disposable patch snapshot in a separate
filesystem-deny sandbox, so check-time writes cannot affect later checks. The
current enforcing backend is macOS Seatbelt; qualification fails closed on hosts
without `/usr/bin/sandbox-exec` rather than exposing hidden corpus or operator
state.

Use stages in order:

1. `canary` — one simple case per profile; stop if no candidate passes.
2. `primary` — quick-suite comparison at each candidate's primary effort.
3. `sweep` — effort variants on discriminator cases when primary is unresolved.
4. `confirm` — repeated route-changing candidates before a full-suite run.

Non-fresh cases admitted by explicit override remain quarantined from routing
recommendations. Unknown model identity or unsupported effective effort cannot
produce a passing result.

## Migration from the placeholder harness

The former `extract`, `enrich`, `test`, and `score` commands intentionally fail.
They relied on provider-branded assumptions, diff similarity, and unsealed
results. Replace them as follows:

| Removed command | Replacement |
|---|---|
| `extract` | Curate locally, then `init` and `add-case` |
| `enrich` | Optional `--prescriptive-file` on `add-case` |
| `test` | `plan`, `seal`, `run` |
| `score` | `report` |

Do not automatically mutate brief templates or routing. First confirm the result
on repeated quick and full replay, then compare it with production telemetry and
review the proposed routing change separately.

## Related

- `tools/context/model-routing.md` — current model and effort routing
- `reference/task-taxonomy.md` — tier definitions and cascade model
- `scripts/brief-tier-test-helper.sh` — replay benchmark entry point
- `workflows/model-replay.md` — isolated implementation-agent contract
- `todo/research/optimize-brief-tiers.md` — superseded proposal and migration record
