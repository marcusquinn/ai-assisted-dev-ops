// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * LLM Observability Module (t1308)
 *
 * Captures LLM request metadata from OpenCode plugin hooks and writes
 * to a SQLite database for cost tracking, performance analysis, and
 * debugging. Each session appends incrementally — no full reparse needed.
 *
 * Data sources:
 *   - `event` hook: message.updated (assistant messages with cost/tokens)
 *   - `tool.execute.after` hook: tool call counts per session
 *
 * Schema is forward-compatible with t1307 (observability-helper.sh CLI).
 *
 * @module observability
 */

import { mkdirSync, existsSync } from "fs";
import { join, dirname } from "path";
import { homedir } from "os";
import {
  canonicalizeSqliteDbPath, setDbPath, sqliteAvailable, sqliteExec, sqliteExecSync,
  shutdownSqlite as _shutdownSqlite, sqlEscape,
} from "./observability-sqlite.mjs";
import {
  createSchema as _createSchema,
  isSchemaInitialized as _isSchemaInitialized,
  withInitLock as _withInitLock,
} from "./observability-init.mjs";
import {
  calculateCost,
  getPricing,
} from "./observability-pricing.mjs";
import { scheduleCostBackfill } from "./observability-cost-backfill.mjs";
import {
  appendRuntimeEvent,
  initialiseRuntimeEventStore,
} from "../../scripts/runtime-events.mjs";
import {
  enrichActiveSpan,
  runtimeEventOtelAttributes,
} from "./otel-enrichment.mjs";
import {
  PartStreamSummaryTracker,
  summarizeToolMetadata,
} from "./observability-retention.mjs";
import { toolOutcomeFailed } from "./session-continuation-guard.mjs";
import {
  consumeRoutingDecision,
  getRoutingFeedback,
  recordRoutingDecision,
  rememberRoutingFeedback,
} from "./observability-routing.mjs";

const HOME = homedir();
const DEFAULT_OBS_DIR = join(HOME, ".aidevops", ".agent-workspace", "observability");
// AIDEVOPS_OBS_DB_OVERRIDE lets tests redirect to a temp DB without touching
// the prod observability DB. Module-load semantics — set the env var BEFORE
// importing this module. See tests/test-observability-concurrent-init.sh (t2900).
const DB_PATH = canonicalizeSqliteDbPath(
  process.env.AIDEVOPS_OBS_DB_OVERRIDE || join(DEFAULT_OBS_DIR, "llm-requests.db"),
);
const OBS_DIR = dirname(DB_PATH);
const COST_BACKFILL_MARKER = `${DB_PATH}.cost-backfill-v1.done`;

export { getPricing };
export { getRoutingFeedback, recordRoutingDecision };

/**
 * Initialise the observability database with WAL mode and schema.
 * Idempotent — safe to call on every plugin load.
 * @returns {boolean} true if initialisation succeeded
 */
function initDatabase() {
  try {
    mkdirSync(OBS_DIR, { recursive: true });
  } catch {
    console.error("[aidevops] Failed to create observability directory");
    return false;
  }

  // Check sqlite3 is available
  if (!sqliteAvailable()) {
    console.error("[aidevops] sqlite3 not found — observability disabled");
    return false;
  }

  // Set the DB path for the SQLite process manager
  setDbPath(DB_PATH);

  // FAST PATH (t2900): the schema includes `PRAGMA journal_mode=WAL` and
  // `CREATE TABLE/INDEX IF NOT EXISTS`. Even though the CREATEs are
  // idempotent, all of them require the writer lock. With 24 concurrent
  // workers (see `MAX_WORKERS` in pulse-wrapper.sh), the writer queue grew
  // beyond the 5s `.timeout` and produced `database is locked (5)` on
  // 100% of worker startups. Read-only check first — no lock contention,
  // skips the slow path entirely once the DB is ready.
  if (existsSync(DB_PATH) && _isSchemaInitialized(DB_PATH)) {
    return _runDataMigrations({ intentColumnReady: true, routingColumnsReady: true });
  }

  // SLOW PATH (t2900): serialise schema creation across concurrent workers
  // via mkdir-based advisory lock. mkdir is POSIX-atomic on every fs we
  // care about, so we don't need flock (which has FD-inheritance footguns).
  // Pattern follows oauth-pool-storage::withPoolLock.
  return _withInitLock(DB_PATH, () => {
    // DOUBLE-CHECKED LOCKING: another worker may have completed init while
    // we waited. If schema is now ready, skip the writer-lock-heavy path.
    if (existsSync(DB_PATH) && _isSchemaInitialized(DB_PATH)) {
      return _runDataMigrations({ intentColumnReady: true, routingColumnsReady: true });
    }
    if (!_createSchema()) return false;
    return _runDataMigrations();
  });
}

/**
 * Idempotent data migrations that run on every plugin init.
 *
 * Schema migrations stay synchronous because later writes depend on them.
 * Historical data backfills are scheduled after startup so large observability
 * databases do not block the OpenCode TUI on table scans or writer locks.
 *
 * @param {{ intentColumnReady?: boolean, routingColumnsReady?: boolean }} [options]
 * @returns {boolean} true on success (best-effort — never returns false)
 */
function _runDataMigrations(options = {}) {
  // Migration: add intent column to tool_calls if it doesn't exist (t1309).
  // Check first to avoid noisy "duplicate column" errors in logs.
  // Fresh DBs already have the column from the CREATE TABLE above.
  const hasIntentCol = options.intentColumnReady
    ? "1"
    : sqliteExecSync(
      "SELECT COUNT(*) FROM pragma_table_info('tool_calls') WHERE name='intent';",
      5000,
    );
  if (hasIntentCol === "0") {
    sqliteExecSync("ALTER TABLE tool_calls ADD COLUMN intent TEXT;", 5000);
  }

  if (!options.routingColumnsReady) {
    const routingColumns = [
      ["parent_session_id", "TEXT"],
      ["routing_tier", "TEXT"],
      ["routing_candidate_index", "INTEGER"],
      ["routing_attempt", "INTEGER"],
      ["routing_reason", "TEXT"],
      ["routing_escalated", "INTEGER DEFAULT 0"],
    ];
    for (const [column, definition] of routingColumns) {
      const exists = sqliteExecSync(
        `SELECT COUNT(*) FROM pragma_table_info('llm_requests') WHERE name=${sqlEscape(column)};`,
        5000,
      );
      if (exists === "0") {
        sqliteExecSync(`ALTER TABLE llm_requests ADD COLUMN ${column} ${definition};`, 5000);
      }
    }
  }
  // These indexes must be created after the migration above. On an existing
  // pre-routing database, createSchema() sees the old llm_requests table and
  // cannot reference columns that ALTER TABLE has not added yet.
  sqliteExecSync("CREATE INDEX IF NOT EXISTS idx_llm_requests_parent_session ON llm_requests(parent_session_id);", 5000);
  sqliteExecSync("CREATE INDEX IF NOT EXISTS idx_llm_requests_routing_tier ON llm_requests(routing_tier);", 5000);

  // runtime-events.mjs is the sole runtime-event schema/migration authority.
  if (!initialiseRuntimeEventStore(DB_PATH)) return false;

  // Migration: backfill cost for rows where cost=0 but tokens exist.
  // OpenCode never provided msg.cost — all historical rows have cost=0.
  // Non-critical historical cleanup; never block the TUI startup path on it.
  scheduleCostBackfill(COST_BACKFILL_MARKER);

  return true;
}

// ---------------------------------------------------------------------------
// In-memory session state (avoids DB round-trips for counting)
// ---------------------------------------------------------------------------

/**
 * Per-session tool call counter.
 * Maps sessionID → { total: number, byTool: Map<string, number> }
 * @type {Map<string, { total: number, byTool: Map<string, number> }>}
 */
const sessionToolCounts = new Map();

/**
 * Track which message IDs we've already recorded to avoid duplicates.
 * The event hook may fire multiple times for the same message as it updates.
 * We only record once — when time.completed is set.
 * @type {Set<string>}
 */
const recordedMessages = new Set();
const partStreamSummaries = new PartStreamSummaryTracker();

/**
 * Whether the database was successfully initialised.
 * @type {boolean}
 */
let dbReady = false;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Initialise the observability system.
 * Call once at plugin startup.
 * @returns {boolean} Whether initialisation succeeded
 */
export function initObservability() {
  dbReady = initDatabase();
  if (dbReady) {
    console.error("[aidevops] Observability: SQLite DB ready at " + DB_PATH);
    // Shut down the persistent sqlite3 process on exit
    process.on("exit", _shutdownSqlite);
  }
  return dbReady;
}

/**
 * Handle an OpenCode event for LLM observability.
 * Filters for assistant message completions and records metadata.
 *
 * @param {{ event: import("@opencode-ai/sdk").Event }} input
 */
export function handleEvent(input) {
  if (!dbReady) return;

  const event = input.event;
  if (!event || !event.type) return;

  if (event.type === "message.updated") {
    handleMessageUpdated(event);
    return;
  }

  // Text/reasoning part streams can emit hundreds of redundant updates for a
  // single response. Keep terminal/error parts, but summarize ordinary deltas
  // into the eventual message.completed envelope.
  if (partStreamSummaries.observe(event)) return;

  recordOpenCodeRuntimeEvent(event);
}

function projectRuntimeEvent(envelope) {
  if (!envelope) return;
  enrichActiveSpan(runtimeEventOtelAttributes(envelope)).catch(() => {});
}

function firstTruthy(values, fallback = null) {
  return values.find(Boolean) || fallback;
}

function recordOpenCodeRuntimeEvent(event, eventType = event.type, additionalPayload = {}) {
  const properties = event.properties || {};
  const info = properties.info || {};
  const part = properties.part || {};
  const sessionId = firstTruthy([
    info.sessionID, part.sessionID, part.sessionId, properties.sessionID, properties.sessionId,
  ]);
  const subjectId = firstTruthy([
    info.id, part.id, part.messageID, part.messageId, properties.id, sessionId,
  ], "runtime:opencode");
  const envelope = appendRuntimeEvent({
    eventType,
    subjectId,
    sessionId,
    correlationId: properties.correlationID || sessionId || undefined,
    causationId: properties.causationID,
    rootEventId: properties.rootEventID,
    parentEventId: properties.parentEventID,
    payload: {
      error_type: firstTruthy([
        info.error?.name, properties.error?.name, part.error?.name, part.state?.error?.name,
      ]),
      finish_reason: info.finish || part.finish || part.state?.status || null,
      model_id: info.modelID || null,
      provider_id: info.providerID || null,
      role: info.role || null,
      source: "opencode",
      ...additionalPayload,
    },
  });
  projectRuntimeEvent(envelope);
}

/**
 * Process a message.updated event.
 * Records LLM request data when an assistant message completes.
 *
 * @param {{ type: string, properties: { info: object } }} event
 */
function handleMessageUpdated(event) {
  const msg = event.properties?.info;
  if (!msg) return;

  // Only record assistant messages (LLM responses)
  if (msg.role !== "assistant") return;

  // Only record when the message is completed (has time.completed)
  if (!msg.time?.completed) return;

  // Deduplicate — event may fire multiple times for same message
  if (recordedMessages.has(msg.id)) return;
  recordedMessages.add(msg.id);

  const routing = consumeRoutingDecision(msg);
  recordOpenCodeRuntimeEvent(event, "message.completed", {
    ...partStreamSummaries.consume(msg),
    routing_tier: routing.tier || null,
    routing_candidate_index: routing.candidateIndex,
    routing_attempt: routing.attempt,
    routing_reason: routing.reason || null,
    routing_escalated: routing.escalated === 1,
  });

  // Prevent unbounded memory growth — prune old entries periodically
  if (recordedMessages.size > 10000) {
    const entries = Array.from(recordedMessages);
    const toRemove = entries.slice(0, 5000);
    for (const id of toRemove) {
      recordedMessages.delete(id);
    }
  }

  const durationMs = msg.time.completed && msg.time.created
    ? Math.round(msg.time.completed - msg.time.created)
    : null;

  const errorType = msg.error?.name || null;
  const errorMessage = msg.error?.data?.message || null;

  // Get tool call count for this session from our in-memory tracker
  const sessionState = sessionToolCounts.get(msg.sessionID);
  const toolCallCount = sessionState?.total || 0;

  const projectPath = msg.path?.root || msg.path?.cwd || null;

  // Calculate cost from tokens — OpenCode does not provide msg.cost
  const cost = calculateCost(msg.tokens, msg.modelID);
  rememberRoutingFeedback(msg, routing, cost, errorType);

  const sql = `INSERT INTO llm_requests (
    session_id, message_id, provider_id, model_id, agent,
    tokens_input, tokens_output, tokens_reasoning,
    tokens_cache_read, tokens_cache_write, tokens_total,
    cost, duration_ms, finish_reason, error_type, error_message,
    tool_call_count, project_path, variant, parent_session_id,
    routing_tier, routing_candidate_index, routing_attempt, routing_reason,
    routing_escalated
  ) VALUES (
    ${sqlEscape(msg.sessionID)},
    ${sqlEscape(msg.id)},
    ${sqlEscape(msg.providerID)},
    ${sqlEscape(msg.modelID)},
    ${sqlEscape(msg.agent)},
    ${msg.tokens?.input || 0},
    ${msg.tokens?.output || 0},
    ${msg.tokens?.reasoning || 0},
    ${msg.tokens?.cache?.read || 0},
    ${msg.tokens?.cache?.write || 0},
    ${msg.tokens?.total || 0},
    ${cost},
    ${durationMs !== null ? durationMs : "NULL"},
    ${sqlEscape(msg.finish || null)},
    ${sqlEscape(errorType)},
    ${sqlEscape(errorMessage)},
    ${toolCallCount},
    ${sqlEscape(projectPath)},
    ${sqlEscape(msg.variant || routing.variant || null)},
    ${sqlEscape(routing.parentSessionID || null)},
    ${sqlEscape(routing.tier || null)},
    ${Number.isInteger(routing.candidateIndex) ? routing.candidateIndex : -1},
    ${Number.isInteger(routing.attempt) ? routing.attempt : 1},
    ${sqlEscape(routing.reason || null)},
    ${routing.escalated === 1 ? 1 : 0}
  );`;

  sqliteExec(sql);

  // Update session summary (upsert)
  updateSessionSummary(msg, cost, toolCallCount);
}

/**
 * Update the session_summaries table with aggregated data.
 * Uses INSERT OR REPLACE with accumulated values.
 *
 * @param {object} msg - Assistant message
 * @param {number} cost - Pre-calculated cost for this request
 * @param {number} toolCallCount - Current tool call count for session
 */
function updateSessionSummary(msg, cost, toolCallCount) {
  const now = new Date().toISOString();
  const projectPath = msg.path?.root || msg.path?.cwd || null;
  const hasError = msg.error ? 1 : 0;

  const sql = `
INSERT INTO session_summaries (
  session_id, first_seen, last_seen, request_count,
  total_tokens_input, total_tokens_output, total_cost,
  total_tool_calls, total_errors, project_path, models_used
) VALUES (
  ${sqlEscape(msg.sessionID)},
  ${sqlEscape(now)},
  ${sqlEscape(now)},
  1,
  ${msg.tokens?.input || 0},
  ${msg.tokens?.output || 0},
  ${cost},
  ${toolCallCount},
  ${hasError},
  ${sqlEscape(projectPath)},
  ${sqlEscape(msg.modelID || "")}
)
ON CONFLICT(session_id) DO UPDATE SET
  last_seen = ${sqlEscape(now)},
  request_count = request_count + 1,
  total_tokens_input = total_tokens_input + ${msg.tokens?.input || 0},
  total_tokens_output = total_tokens_output + ${msg.tokens?.output || 0},
  total_cost = total_cost + ${cost},
  total_tool_calls = ${toolCallCount},
  total_errors = total_errors + ${hasError},
  models_used = CASE
    WHEN instr(',' || models_used || ',', ',' || ${sqlEscape(msg.modelID || "")} || ',') = 0
    THEN models_used || ',' || ${sqlEscape(msg.modelID || "")}
    ELSE models_used
  END;
`;

  sqliteExec(sql);
}

/**
 * Build the INSERT SQL for a tool_calls row. Pure function — no DB access,
 * no global state — so it is exhaustively testable without sqlite3.
 *
 * Column order must stay aligned with the `tool_calls` CREATE TABLE in
 * initDatabase(). If you add or reorder columns there, update this
 * builder and its test suite (test-observability-tool-calls.mjs) in the
 * same commit.
 *
 * @param {object} args
 * @param {string} args.sessionID
 * @param {string} args.callID
 * @param {string} args.toolName
 * @param {string | null | undefined} args.intent
 * @param {0 | 1} args.isSuccess
 * @param {number | null | undefined} args.durationMs - Elapsed ms, or null/undefined to store SQL NULL
 * @param {object | null | undefined} args.metadata - Raw metadata object; summarized before persistence
 * @returns {string} INSERT statement ready for sqliteExec
 */
export function buildToolCallInsertSql({ sessionID, callID, toolName, intent, isSuccess, durationMs, metadata }) {
  const durationSql = (durationMs !== null && durationMs !== undefined)
    ? String(durationMs)
    : "NULL";
  // sqlEscape(null) returns the literal string "NULL" — we exploit that
  // so the metadata column renders as SQL NULL when metadata is absent.
  const metadataSummary = summarizeToolMetadata(metadata);
  const metadataValue = metadataSummary === null ? null : JSON.stringify(metadataSummary);

  return `INSERT INTO tool_calls (
    session_id, call_id, tool_name, intent, success, duration_ms, metadata
  ) VALUES (
    ${sqlEscape(sessionID)},
    ${sqlEscape(callID)},
    ${sqlEscape(toolName)},
    ${sqlEscape(intent || null)},
    ${isSuccess},
    ${durationSql},
    ${sqlEscape(metadataValue)}
  );`;
}

/**
 * Record a tool call from the tool.execute.after hook.
 * Increments the in-memory counter and writes to the tool_calls table.
 *
 * @param {object} input - { tool, sessionID, callID, args }
 * @param {object} output - { title, output, metadata }
 * @param {string | undefined} intent - LLM-provided intent string (from agent__intent field)
 * @param {number | null | undefined} [durationMs] - Elapsed milliseconds from tool.execute.before (t2184)
 */
export function toolCallSucceeded(output) {
  return !toolOutcomeFailed(output);
}

export function recordToolCall(input, output, intent, durationMs) {
  if (!dbReady) return;

  const toolName = input.tool || "";
  const sessionID = input.sessionID || "";
  const callID = input.callID || "";

  if (!sessionID || !toolName) return;

  // Update in-memory counter
  if (!sessionToolCounts.has(sessionID)) {
    sessionToolCounts.set(sessionID, { total: 0, byTool: new Map() });
  }
  const state = sessionToolCounts.get(sessionID);
  state.total++;
  state.byTool.set(toolName, (state.byTool.get(toolName) || 0) + 1);

  // Prune old sessions to prevent unbounded memory growth
  if (sessionToolCounts.size > 1000) {
    const keys = Array.from(sessionToolCounts.keys());
    for (const k of keys.slice(0, 500)) {
      sessionToolCounts.delete(k);
    }
  }

  const isSuccess = toolCallSucceeded(output) ? 1 : 0;

  const sql = buildToolCallInsertSql({
    sessionID,
    callID,
    toolName,
    intent,
    isSuccess,
    durationMs,
    metadata: output?.metadata,
  });

  sqliteExec(sql);

  const runtimeEnvelope = appendRuntimeEvent({
    eventType: "tool.completed",
    subjectId: callID || `${sessionID}:${toolName}`,
    sessionId: sessionID,
    correlationId: sessionID,
    payload: {
      call_id: callID || null,
      duration_ms: durationMs ?? null,
      success: isSuccess === 1,
      tool_name: toolName,
    },
  });
  projectRuntimeEvent(runtimeEnvelope);
}

/** Persist a bounded cancellation receipt without making termination depend on telemetry. */
export function recordSubagentCancellationReceipt(receipt, context = {}) {
  const envelope = appendRuntimeEvent({
    eventType: "subagent.cancellation.receipt",
    subjectId: context.childSessionID || receipt?.child || "unknown-child",
    sessionId: context.parentSessionID || null,
    correlationId: context.parentSessionID || context.childSessionID || "subagent-cancellation",
    payload: {
      classification: "subagent_cancellation",
      observation: JSON.stringify({
        complete: Boolean(receipt?.complete),
        ledger: receipt?.ledger || [],
        reaped: Boolean(receipt?.reaped),
        termination: receipt?.termination || "unconfirmed",
        truncated: Boolean(receipt?.truncated),
      }),
      reason: (receipt?.incomplete_reasons || []).join(",") || "confirmed",
      status: receipt?.termination || "unconfirmed",
      success: Boolean(receipt?.complete),
    },
  });
  if (envelope) projectRuntimeEvent(envelope);
  return envelope;
}

/**
 * Get the database path for external tools (e.g., observability-helper.sh).
 * @returns {string}
 */
export function getDbPath() {
  return DB_PATH;
}

/**
 * Get the observability directory path.
 * @returns {string}
 */
export function getObsDir() {
  return OBS_DIR;
}
