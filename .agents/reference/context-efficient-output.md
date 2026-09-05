<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Context-Efficient Tool Output

RTK reduces context load for noisy terminal summaries. It is an efficiency layer,
not an evidence boundary: capability, correctness, and exact output take priority
over token savings.

## Evidence receipts for noisy operations

Use `output-sandbox-helper.sh run` when a deterministic operation may produce
large setup, build, migration, or deployment output but the immediate decision
needs only the outcome and bounded evidence:

```bash
output-sandbox-helper.sh run --tag setup --expect-text '[SETUP_COMPLETE]' -- ./setup.sh --non-interactive
```

Success defaults to a compact receipt; failure defaults to bounded diagnostic
lines. The text receipt and `--format json` contract (`aidevops.operation-result/v1`)
include the operation outcome, process exit, decision basis, byte/line counts,
sensitivity-redaction state, and an opaque `output_id`. Raw content remains in a
private `0700`/`0600` local evidence store and can be retrieved deliberately with
`output-sandbox-helper.sh show OUTPUT_ID`. Receipts never expose the raw storage
path.

Use `--success-mode summary|full` or `--failure-mode summary|full` only when the
next decision requires content. Exact reads, JSON, diffs, security, secret, and
credential commands bypass the store and retain native output semantics. Storage
failure also fails open to native execution rather than blocking the operation.

`aidevops update` applies this contract automatically for non-TTY setup output.
Use `--compact` to request it explicitly or `--verbose` to retain native streaming.
The compact path verifies the setup completion sentinel before reporting success.

## Delta-aware required-check waits

Do not repeatedly print unchanged `gh pr checks` snapshots. Use:

```bash
full-loop-helper.sh wait-checks 123 --repo owner/repo
```

The wait prints the initial required-check state once, then only transitions,
sparse heartbeats, and the terminal result. Its polling interval backs off while
state is unchanged and resets after a transition. Failed-check links are emitted
once; PR-head changes and API loss remain explicit. Exit `8` means checks are
still pending at timeout, `1` means terminal failure, and `2` means indeterminate
API failure. These states must not be collapsed into a generic failure.

## Bounded interactive operations

OpenCode exposes `aidevops_bounded_operation` for a command expected to outlast
the next useful progress update. Start it with argv arrays rather than shell
text, retain the opaque `operation_id`, and poll `status` no later than the
configured progress interval. The start action returns after the owned process
spawns, so the primary session remains available for progress reports and
scoped cancellation.

The receipt distinguishes running, failed, timed-out, cancelled, and
restoration-failed states. `AIDEVOPS_PROGRESS: ...` lines count as explicit
meaningful progress; ordinary output is not a heartbeat substitute and is not
copied into status receipts. An optional restoration argv runs after every
terminal command path, and its exit remains independently visible. Raw output
is represented only by an opaque output ID when terminal evidence storage is
available.

Cancellation is restricted to the runtime session that started the operation
and signals only the retained detached process group. The implementation is an
OpenCode process-lifetime adapter, not a durable scheduler: restarting or
forcibly terminating OpenCode expires the in-memory operation generation.
Commands must remain in the supervisor-owned process group; self-daemonizing or
new-session (`setsid`) commands are unsupported and belong in a purpose-built
service or the headless scheduler rather than this interactive adapter.
Deleting the owning session cancels primary work. A restoration explicitly
authorized at start still runs to its separate bound—even if primary work has
not closed yet—then the adapter expires the unreachable operation record.
Continue to use `deferred-job-helper.sh` for explicitly headless/scheduled work.

## Session output-efficiency evidence

Session review gathers aggregate transcript evidence automatically when a current
runtime session is available. Run it directly when investigating token or output
noise:

```bash
session-review-helper.sh output-efficiency --json
```

The `aidevops.session-output-efficiency/v1` report distinguishes model-visible
output from receipt-declared background evidence. It detects unchanged snapshots,
duplicate results, repeated lines/blocks, successful oversized results, raw
fallbacks, and exact-output bypasses, then estimates avoidable context from byte
counts. It emits only tool names, metrics, and opaque fingerprints; tool inputs,
commands, outputs, transcript paths, and background content remain omitted.
The additive `category_summary` covers every non-zero finding kind independently
of `max_findings`, with a finding count, occurrence count, aggregate bytes, and
leading tool class in stable category order. Aggregate bytes use redundant bytes
for repetition categories and total bytes for size categories; categories can
overlap and must not be summed into a session-wide total.
Findings are deterministic candidates for session-analysis judgment, not
automatic proof that a safeguard or exact evidence should be removed.

## Default workflow

1. **Start narrow** with `rtk-helper.sh` for supported summary commands:
   - `rtk-helper.sh git status`
   - `rtk-helper.sh git log --oneline -20`
   - `rtk-helper.sh gh pr list --repo owner/repo --limit N`
   - `rtk-helper.sh gh issue list --repo owner/repo --limit N`
   - In interactive discovery, use these RTK forms instead of raw `gh pr list`
     or `gh issue list` unless the command needs structured/exact output.
   - RTK v0.41.0 also adds upstream Gradle wrapper support, `rtk init --agent hermes`, `rtk init --dry-run`, `transparent_prefixes` for wrapper command passthrough, tee tail hints, Docker Compose log tail forwarding, compact Kubernetes pod/service summaries, and git push/status filtering fixes; prefer those upstream features over custom aidevops shims when integrating supported runtimes, build tools, or noisy terminal summaries.
2. **Assess sufficiency**: proceed only if the filtered output contains every
   fact needed for the next decision.
3. **Broaden immediately** when output is incomplete, ambiguous, expanded rather
   than reduced, or exact evidence is needed:
   - rerun the raw/direct command;
   - use a narrower raw command with explicit fields;
   - read exact files with the Read tool;
   - request logs/check output directly for terminal failures.

## Diagnostics workflow

When RTK output seems misleading, too large, too small, or insufficient for a
decision, record a comparison before changing guidance:

```bash
rtk-helper.sh --compare gh pr list --repo owner/repo --limit 10
```

The comparison reports raw vs RTK-filtered exit codes, bytes, approximate token
counts, line counts, and a first-pass recommendation. It intentionally omits the
command output to avoid copying noisy or sensitive data into diagnostics. Rerun
the raw command directly when exact evidence is needed.

To verify adoption in recent OpenCode sessions, run:

```bash
rtk-helper.sh --adoption-report
```

The report counts sessions, Bash tool calls, RTK helper calls, raw eligible list
commands that should have started through RTK, and structured/exact list commands
that correctly bypass RTK.

For pulse/GitHub API-budget symptoms, start with the compact, sanitized local
summary before reading long logs or running more `gh` calls:

```bash
pulse-diagnose-helper.sh api-budget
pulse-current-state-helper.sh --window 15m --json
```

Then broaden only when the summary cannot prove whether the path is REST-first
or GraphQL-only, whether shared cache priming exists, or whether `gh_pr_view`
misses are duplicate same-PR misses rather than unique PR reads. Do not broaden
`gh_pr_view` cache semantics before that hit/miss evidence exists.

Use comparison results to classify a command:

- **Good first-pass RTK candidate**: exit codes match, output shrinks, and the
  summary preserves all facts needed for the next decision.
- **Raw or narrower command preferred**: output expands, output is unchanged, or
  structured fields can answer the question more precisely.
- **Unsafe for RTK**: exit codes differ, omitted lines could alter diagnosis, or
  exact evidence/security/JSON/diff semantics are required.
- `git status` expansion is a regression signal: RTK v0.41.0 dropped the
  compact-status `-uall` flag, so tracked-file paths remain visible while
  untracked directories stay summarized as they appear in raw
  `git status --short` output. Rerun raw status and verify RTK version when
  comparison shows expansion; older RTK versions still use the noisier
  compact-status behavior.

Do not judge an optimisation by token reduction alone. In session review, check
whether filtered output was sufficient on the first pass, required raw fallback,
caused repeated discovery, omitted causal evidence, or weakened requirement and
verification coverage. Compare similar tasks when evidence exists; do not impose
arbitrary global thresholds. Preserve unexpected outliers for model judgment.

## Always bypass RTK

- File reads and source inspection.
- JSON used for assertions, parsing, or automation decisions.
- Exact/verbatim diffs, patches, or blame output.
- Security scans, credential-sensitive output, or prompt-injection checks.
- Terminal failures where omitted lines could change diagnosis.
- Any command whose output must be cited byte-for-byte in an issue, PR, review,
  or audit trail.

## Validation notes

Initial validation for GH#23212 found RTK useful for list-style GitHub context
(`gh issue list`, `gh pr list`) and only situational for tiny `git status`,
already compact `git log --oneline`, or full issue bodies. The v0.41.0 release
fixes the compact-status expansion regression, preserves full status paths, and
streams git push output to avoid spurious timeout symptoms. Prefer RTK for
discovery and triage summaries; prefer raw output or structured fields for exact
task briefs.

For future regressions, capture:

1. the exact command;
2. `rtk-helper.sh --compare ...` output;
3. whether the RTK-filtered response was sufficient, required fallback, or was
   unsafe for RTK;
4. the raw command output only when it is safe and necessary to prove the issue.
