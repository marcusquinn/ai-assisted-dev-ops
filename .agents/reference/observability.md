<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Observability

Three complementary layers — cost tracking, execution forensics, and mid-session self-diagnosis. Each is independently useful; together they cover full agent activity.

## Layers

### 1. Plugin SQLite (always on)

The opencode-aidevops plugin captures every LLM request and tool call to
`~/.aidevops/.agent-workspace/observability/llm-requests.db`.

Tables:

- `llm_requests` — per-message tokens, cost, model, duration, finish reason,
  routing decision, route attempt, and `aidevops_version`
- `tool_calls` — per-tool call session_id, tool_name, intent (from the
  `agent__intent` field), duration_ms, success, metadata JSON
- `session_summaries` — aggregate totals keyed by session_id
- `runtime_events` — versioned, append-only runtime evidence with event,
  correlation, causation, subject, session, worker, root, and parent IDs

Query with `.agents/scripts/observability-helper.sh` (cost dashboards,
rate-limit telemetry, cache health). No configuration required — the
plugin auto-creates the DB on first tool call.

Routing feedback reads the same request rows. `routing_attempt` is stable across
ordinary turns in one child route and increments only for an actual retry or
capability escalation. Use `aidevops_version` to segment request, token, cost,
error, and escalation outcomes before and after routing-policy releases.

### Runtime-event contract

`.agents/scripts/runtime-events.mjs` owns the runtime-neutral envelope and uses
the same `llm-requests.db`; it does not create another database or state store.
`llm_requests`, `tool_calls`, and `session_summaries` remain compatible. Runtime
events are evidence and projections, not a task, mailbox, audit, transcript, or
worker-state authority.

Envelope version 1 stores `event_id`, `event_type`, `correlation_id`,
`causation_id`, `subject_id`, `session_id`, `worker_id`, `parent_worker_id`,
`root_worker_id`, `root_event_id`, and `parent_event_id`. The supervisor emits
the root `worker.dispatched` observation before launch and passes its event IDs
to the child. Worker emissions carry `source=worker_self_reported`; supervisor
observations carry `source=supervisor_observed`. Interactive shell hooks clear
inherited worker/event lineage instead of attaching stale worker ancestry.

Update and delete triggers make rows append-only. Ordinary payloads use a
small top-level allowlist rather than persisting arbitrary hook payloads. All
payloads are canonical JSON capped at 16 KiB, with bounded depth, keys, arrays,
and strings. AWS access/secret keys, bearer/basic credentials, JWTs, PEM blocks,
credential-shaped values, absolute/file paths, configured private roots, and
repository-like identifiers are redacted before persistence. CamelCase and
snake_case path/repository keys receive the same treatment.

The plugin additionally bounds two host-runtime amplification surfaces before
they reach SQLite:

- ordinary `message.part.delta` and `message.part.updated` streams are counted
  and measured in memory, then represented by `suppressed_part_events` and
  `suppressed_part_bytes` on the terminal `message.completed` event. Part
  errors and terminal statuses bypass suppression and remain individual rows;
- raw host-tool metadata is never persisted. `tool_calls.metadata` contains a
  versioned outcome summary capped at 1 KiB (status, exit code, timeout,
  truncation, and aggregate byte/line counts). Unknown keys, paths, output
  fragments, and error text are omitted. The dedicated `success` and
  `duration_ms` columns remain the primary tool outcome evidence.

Use `appendRuntimeEvent()` for ordinary evidence. Evidence writes fail open:
validation, queue, lock, or disk failures never change the runtime action's
result. Use `appendStateSnapshot()` and `appendStateDelta()` for bounded state
evidence. They allocate each subject's `state_version` inside a
`BEGIN IMMEDIATE` transaction, so concurrent writers cannot receive the same
version. `appendProjectedState()` uses an optimistic expected-version
transaction across its read/derive/write sequence and retries stale bases.
It suppresses unchanged projections. Deltas use RFC 7396 JSON Merge Patch and
are round-trip checked; when a merge patch cannot represent the desired state
(including an object property whose desired value is `null`), the writer emits
a snapshot instead. `reconstructRuntimeState()` sorts by state version, starts
from the latest applicable snapshot, rejects version gaps, and returns
canonically ordered state.

`.agents/scripts/sqlite-process.mjs` is the shared runtime-neutral sqlite3
transport. It canonicalises absolute database overrides and invokes sqlite3
with argv (`execFileSync`/`spawn`), never shell-interpolated database paths.
`runtime-events.mjs` is the sole runtime-event schema and migration authority;
the OpenCode plugin consumes it.

Runtime-event maintenance uses an explicit archive boundary rather than
ordinary row deletion. The minimum retained envelope includes state-recovery
rows and lifecycle, terminal, error, permission, security, audit, release,
deploy, and subagent evidence. The default 30-day active window is a soft
candidate threshold; state snapshots/deltas stay active because current-state
reconstruction depends on them.

`observability-helper.sh retention` is a dry run by default. `--apply` writes a
bounded JSONL partition plus an immutable sidecar manifest under
`runtime-events-archive/`, verifies SHA-256, bytes, source/event counts, and the
protected/compacted split, and only then removes the verified source range in
one `BEGIN IMMEDIATE` transaction. Protected rows are archived verbatim;
unprotected rows become per-event-type count/byte/time summaries. The
transaction rechecks the exact source range, temporarily suspends only the
delete guard, restores it, and appends an immutable `runtime_event_archives`
manifest row. A failed/corrupt archive leaves source rows intact. Interruption
after file verification is resumable and reuses the verified partition.

Core routine `r918` runs producer-owned maintenance daily through the shared
Pulse scheduler. It repeatedly applies the same verified partition primitive
until the backlog is clear or the default 20-partition/120-second run bound is
reached; any residual backlog is reported and left for the next run. It does
not install a dedicated launchd plist or systemd unit. The one-partition
`retention` command remains explicit and dry-run-first.

```bash
# Physical and classified bytes; never prints raw payloads
observability-helper.sh storage --json

# Explain one bounded candidate partition without writing
observability-helper.sh retention --dry-run

# Explicit maintenance after reviewing the dry run
observability-helper.sh retention --apply --max-rows 5000

# Bounded catch-up used by shared-Pulse routine r918
observability-helper.sh retention-maintenance --apply --max-partitions 20 --max-duration-seconds 120
```

The shared storage inventory reports active, archive, protected, reclaimable,
candidate, and unknown bytes. Unattributed files and unavailable verification
remain unknown; a verified archive or pinned state row is required before any
byte is classified as protected, and source bytes are never called reclaimable
before the archive transaction commits.

Full-loop keeps authoritative resumable state in `.agents/loop-state/full-loop.local.state` and appends local transition evidence to `full-loop-events.jsonl`. Schema v2 records the run ID, state revision, phase status/start/end/attempt, terminal evidence, next safe action, observed executor status/PID/heartbeat, manual resumes, reused subagent units, and duplicate work avoided. Status must validate executor liveness instead of trusting a stale PID. These records drive lifecycle recovery; runtime events and plugin cost/tool data remain fail-open reporting evidence. Aggregate phase wall time, active compute, CI wait/repair, release/cleanup time, calls by tier, retries/outcomes, reuse, false-positive gates, and manual resumes when producing performance reports.

### Worker progress-blocker log

Headless permission and approval stops append redacted lifecycle records to
`~/.aidevops/logs/worker-progress-blockers.jsonl`. Records use schema
`aidevops-worker-blocker/v1` and correlate `issue_number`, `repo_slug`,
`session_key`, and `request_id` with the event, reason, source, risk class, and
whether the condition is still blocking. Exact permission patterns, model
intent, credentials, and raw tool metadata are not stored in this log.

The default cap is 5 MiB. Each append acquires a short-lived local lock and,
when the incoming record would exceed the cap, atomically keeps only the newest
complete JSONL records that fit before appending. Override the path with
`AIDEVOPS_WORKER_BLOCKER_LOG_FILE` or the cap with
`AIDEVOPS_WORKER_BLOCKER_LOG_MAX_BYTES`. The writer is fail-open: logging or
trimming failures never grant a permission or change the worker action.

Writers cover permission capture/non-grantable scope, handoff persistence,
awaiting maintainer approval, approval persistence, expired or replay-rejected
grants, and successful grant application. Query through bounded diagnostics
instead of recursively searching worker logs:

```bash
worker-activity-helper.sh summary --since 24h
pulse-diagnose-helper.sh issue <N> --repo <owner/repo>
```

Inspect recent events without exposing any other store:

```bash
observability-helper.sh runtime-events 20
```

### 2. OpenTelemetry spans (opt-in, opencode v1.4.7+)

opencode emits OTLP spans for AI SDK calls, tool execution, and server
routes. Activated by pointing the runtime at a local collector:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
# Optional auth for hosted sinks:
export OTEL_EXPORTER_OTLP_HEADERS="x-token=..."
```

The opencode-aidevops plugin shell-env hook forwards these variables to
every subprocess opencode spawns — headless workers and helper scripts
inherit the trace endpoint without per-script plumbing.

The plugin enriches each active tool span with bounded, low-cardinality
aidevops attributes via `@opentelemetry/api` (dynamic import, no-op when
absent):

| Attribute                   | Value                                    |
|-----------------------------|------------------------------------------|
| `aidevops.tool_name`        | Tool name (Read, Edit, Bash, …)          |
| `aidevops.task_id`          | `tNNN` / `GH#NNN` detected from cwd/env  |
| `aidevops.session_origin`   | `worker` or `interactive`                |
| `aidevops.runtime`          | `opencode`                               |
| `aidevops.runtime_event.type` | Runtime-event type                     |
| `aidevops.runtime_event.envelope_version` | Envelope version             |

Namespace `aidevops.*` avoids collision with OpenTelemetry's standard
semantic conventions (which opencode already populates as `session.id`,
`message.id`, etc.). Free-form intent remains available in `tool_calls` but is
not exported. Runtime payloads, state, paths, and causal identifiers are never
projected to OTEL. SQLite remains the complete local evidence layer; OTEL is
optional.

### 3. Session introspect (offline self-diagnosis)

`session-introspect-helper.sh` reads the plugin SQLite directly — no OTEL
required — and surfaces stuck-worker anti-patterns for the current session.

## Running a local OTLP collector

Any OTLP HTTP sink works:

- **kit motel** — the dedicated opencode/aidevops OTel TUI, still maturing
  (tweeted preview 2026-04). Check the opencode repo for install docs when
  the video/release lands.
- **Jaeger all-in-one** — one-line Docker run, web UI at localhost:16686:

  ```bash
  docker run --rm --name jaeger \
    -p 4318:4318 -p 16686:16686 \
    jaegertracing/all-in-one:latest
  ```

- **OpenTelemetry Collector** — for forwarding to Grafana Tempo, Honeycomb,
  Datadog, or any OTLP-compatible destination.

Point opencode at whichever collector via the env var above and restart
the session. No further aidevops configuration is needed.

## Self-diagnosis

`session-introspect-helper.sh` diagnoses stuck workers offline — reads local
SQLite, no OTEL required:

```bash
# What have I been doing?
session-introspect-helper.sh recent 30

# Am I in a file-reread loop?
session-introspect-helper.sh patterns

# What errors have I hit?
session-introspect-helper.sh errors

# Recent sessions with cost summary
session-introspect-helper.sh sessions 5
```

The `patterns` subcommand flags files read/edited more than 3× in the
current session — a common stuck-worker signature when file comprehension
isn't landing. When this fires, break out of the loop: `git diff`,
`git status`, or step back to re-read the brief.

`patterns` also reports populated and missing `agent__intent` totals plus a
coverage percentage in text and JSON. Null, empty, and whitespace-only legacy
values count as missing. `errors` renders missing values as `<missing>` rather
than exposing commands, arguments, prompts, paths, or other transcript content;
the helper never infers intent from those private inputs.

Stuck-worker thresholds (informational):

| Signal                  | Value         | Interpretation                      |
|-------------------------|---------------|-------------------------------------|
| Calls/minute            | > 30          | Excessive tool chatter              |
| Same file read          | > 3× / session| Re-read loop                         |
| Consecutive errors      | 3+ on same tool | Not learning from feedback        |

The helper exposes data for course-correction; it does not kill the session.

### 4. Output sandbox (noisy command evidence)

`output-sandbox-helper.sh` stores noisy raw command output in
`~/.aidevops/.agent-workspace/output-sandbox/` with a SQLite index and WAL mode.
The assistant receives a compact receipt instead of full logs: output ID,
outcome, process/verified exit codes, decision basis, byte/line counts, and
redaction state. Raw storage paths are never model-visible. Failure defaults to
bounded diagnostic lines; exact evidence remains retrievable deliberately with
`output-sandbox-helper.sh show OUTPUT_ID --offset N --limit N`.

Use it for repeatable noisy flows such as diagnostics, CI logs, worker output,
and browser/tool logs. Do not use it for file reads, JSON assertions, security
scans, exact diffs, or credential-sensitive commands where verbatim output must
stay directly visible or be handled by a dedicated redaction path. The helper
also bypasses common exact-output commands and redacts simple secret patterns
before storage.

Maintenance: `output-sandbox-helper.sh cleanup --max-age-days 14` removes old
raw files, deletes matching SQLite rows, and runs `VACUUM` to keep the local
store bounded.

### 5. Session output-efficiency evidence

`session-review-helper.sh output-efficiency --session ID --json` reads the exact
local OpenCode or Claude Code transcript through the Vault-managed history gate.
It reports only aggregate, model-visible tool-output evidence: unchanged
snapshots, duplicate results, repeated lines/blocks, successful oversized
results, raw fallbacks, and exact-output bypasses. Receipt-declared background
evidence bytes are reported separately; background content is not scanned or
copied into model context. Inputs, commands, outputs, transcript paths, and raw
fragments remain omitted.

The report is a diagnostic lead, not a policy verdict. Correlate fingerprints
with the conversation timeline before changing a safeguard or exact-output path.

## Known limitation: `run` mode does not emit per-tool OTEL spans (t2187)

**Verified against:** opencode v1.4.11 (Bun-compiled), Jaeger all-in-one,
2026-04-18. 471 spans / 108 unique operations observed; zero `Tool.execute`
spans among them.

**What works in `run` mode:** outer orchestration spans — `Config.*`,
`FileSystem.*`, `Session.*`, `ToolRegistry.*`, `Auth.*`, `SessionPrompt.*`,
`Git.*`, `Npm.*`, `Bus.*`. These confirm the `@effect/opentelemetry` bridge
and `OTLPTraceExporter` are active.

**What is missing:** per-tool-call `Tool.execute` spans. The span IS
declared in opencode source at `packages/opencode/src/tool/tool.ts` —
every tool is wrapped via
`.pipe(Effect.orDie, Effect.withSpan("Tool.execute", { attributes: attrs }))`.
It simply does not appear in the OTEL export in `run` mode.

**What is NOT the cause** (falsified against `anomalyco/opencode` source on
2026-04-18 as part of t2212):

- NOT an `AsyncLocalStorageContextManager` gap. `packages/opencode/src/effect/observability.ts`
  explicitly installs one via `context.setGlobalContextManager(mgr)` with
  an in-source comment stating the intent is "so non-Effect code (like
  the AI SDK) that calls `tracer.startActiveSpan()` relies on
  `context.active()` to find the parent span" — opencode ships with
  the fix for the exact bridging mechanism earlier drafts of this doc
  blamed. (PR #19677 had already corrected the `Effect.promise` →
  `Effect.runPromise` terminology; t2212 retires the underlying
  attribution that `runPromise` was still somehow the culprit.)
- NOT a Promise-boundary issue. The tool invocation path in
  `packages/opencode/src/session/prompt.ts::resolveTools()` uses
  `run.promise(Effect.gen(...))` where `run` comes from
  `EffectBridge.make()` in `packages/opencode/src/effect/bridge.ts`.
  The bridge's `promise` calls `Effect.runPromise(wrap(effect))` with
  `wrap = attach(effect).pipe(Effect.provide(ctx))` — the outer Effect
  context (including the tracer layer) IS provided to the inner effect.
  Empirical counter-evidence observable in the local Jaeger: `Plugin.trigger`,
  `Plugin.list`, `Plugin.init`, and `Plugin.state` spans ALL appear and
  go through the same bridge as `Tool.execute`. If the bridge were the
  root cause, they would all be missing — they are not.

**What IS the cause:** not yet identified. Candidate hypotheses for
future investigation: (a) the `Effect.withSpan("Tool.execute")`
attach point interacts specifically with `Effect.orDie` and the AI
SDK's `tool({ execute })` Promise contract in a way plugin-trigger
spans do not; (b) the Tool.execute span lifetime ends before OTEL's
`BatchSpanProcessor` flushes because the AI SDK moves on without
awaiting span completion; (c) a tracer-layer lookup difference
between how `Effect.withSpan` resolves inside the tool-level Effect
vs the plugin-level Effect. These are specific enough to be testable
by someone reading opencode internals; they are not specific enough
to edit today.

**Classification:** architectural consequence (outcome (a) from the
t2187 brief). Not a config flag to toggle, not a simple bug — it is
a structural gap in how `run` mode integrates with the AI SDK's
tool interface.

**Impact on aidevops plugin:** the plugin's `enrichActiveSpan()` in
`otel-enrichment.mjs` calls `trace.getActiveSpan()` inside
`tool.execute.before` / `tool.execute.after` hooks. When opencode
does not create a `Tool.execute` span, `getActiveSpan()` returns
`undefined` and the enrichment silently no-ops. The `aidevops.*`
attributes (`tool_name`, `task_id`, `session_origin`, `runtime`, and bounded
runtime-event type/version) are
therefore invisible in OTEL traces for headless `run` mode sessions.
Plugin-side SQLite (`tool_calls` table) is unaffected — it records
independently of OTEL.

**Decision on plugin-owned fallback spans:** creating plugin-owned
spans when opencode does not provide one would produce orphan traces
under a separate service name (`opencode-aidevops`), disconnected
from the Session/Config trace tree. The cost of implementation is low
but the value is marginal — orphan spans without parent context are
hard to correlate in Jaeger/Tempo and do not meaningfully improve the
audit trail over what plugin SQLite already provides. **Status quo
accepted**: rely on plugin SQLite for per-tool observability in `run`
mode. Re-evaluate if opencode fixes the span gap upstream or if a
future version exposes a tracer handle to plugins.

**Upstream status:** the active opencode upstream is `anomalyco/opencode`
(not archived, default branch `dev`, Bun-compiled TypeScript, public
issue tracker active, verified 2026-04-18 via `gh api`). A separate,
legacy Go codebase exists at `opencode-ai/opencode` (archived, last
push 2025-09-18) — that is NOT the same project as the v1.4.x
Bun-compiled TypeScript binary users actually run. The span gap may
be resolved in a future `anomalyco/opencode` release if a contributor lands
an explicit span-export in the tool execution path or the AI SDK
switches to a span-preserving execution model. File OTEL-related
issues at `https://github.com/anomalyco/opencode/issues`; monitor release
notes there for changes.

## Verifying the OTEL integration

After pointing opencode at a collector and restarting:

1. Run any tool call in opencode (e.g. `ls`).
2. Check the collector received spans (look for `Config.*`,
   `Session.*`, `ToolRegistry.*` — these confirm the bridge works).
3. Expand a span's attributes — verify opencode-native keys
   (`session.id`, `message.id`) are present.
4. Check for `aidevops.*` attributes. **In TUI/server mode**, these
   should appear on `Tool.execute` spans. **In `run` mode**, they
   will be absent due to the known limitation above — verify via
   plugin SQLite instead (`session-introspect-helper.sh recent 10`).

If aidevops attributes are missing in a mode where they should work:

- Verify the plugin loaded: `AIDEVOPS_PLUGIN_DEBUG=1 opencode run ...`
  should emit `[aidevops]` startup lines.
- Verify `@opentelemetry/api` is resolvable from the plugin's load path
  (opencode bundles it as a transitive dependency).
- The enrichment path fails silent by design — a plugin error never
  breaks tool execution. Check opencode's stderr for SDK warnings.

## Relationship to other observability tooling

- `observability-helper.sh cache-health` — prompt cache hit rate per model
- `observability-helper.sh rate-limits` — provider quota telemetry
- `pulse-current-state-helper.sh --window 15m [--json]` — live pulse throughput
  snapshot. It aggregates recent dispatch stages, worker outcomes, resource
  context, GraphQL-budget counters, and top recent examples so “is work
  happening now?” can be answered from current evidence.
- `worker-activity-helper.sh summary --since 1h [--json]` — historical worker
  outcome and progress-blocker summary. JSON output includes
  `metrics.result_counts`, `progress_blockers.active_blockers`,
  `metrics.timing_ms`, and `metrics.recent_examples` with load context from
  `headless-runtime-metrics.jsonl`.
- `session-miner` routine — post-hoc mining of successful/failed sessions
  into the shared memory (SQLite FTS5). Different layer: session-miner
  extracts *lessons* across sessions; OTEL captures per-call *traces*
  within a session; session-introspect gives the *running* session a
  read-through to its own plugin SQLite data.
