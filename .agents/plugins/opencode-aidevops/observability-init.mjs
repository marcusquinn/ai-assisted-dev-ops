// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Schema creation and cross-process initialisation locking for observability.
 *
 * @module observability-init
 */

import {
  mkdirSync, readFileSync, rmdirSync, statSync, unlinkSync, writeFileSync,
} from "fs";
import { execFileSync } from "child_process";
import { dirname } from "path";

import { sqliteExecSync } from "./observability-sqlite.mjs";

/**
 * Read-only check: are all expected tables present and is the t1309 `intent`
 * column on `tool_calls`, and are routing/version columns present on
 * `llm_requests`?
 * Uses `sqlite3 -readonly` so it never contends on
 * the writer lock — safe to call from N concurrent workers without race.
 *
 * Returns false on any error (DB doesn't exist, sqlite3 fails, schema is
 * incomplete) so the caller falls through to the slow path.
 *
 * @param {string} dbPath
 * @returns {boolean}
 */
export function isSchemaInitialized(dbPath) {
  try {
    const result = execFileSync(
      "sqlite3",
      ["-readonly", "-separator", "|", dbPath,
       "SELECT " +
      "(SELECT COUNT(*) FROM sqlite_master WHERE type='table' " +
       "AND name IN ('llm_requests','tool_calls','session_summaries','runtime_events','runtime_event_archives')) AS tbls, " +
       "(SELECT COUNT(*) FROM pragma_table_info('tool_calls') WHERE name='intent') AS intent_col, " +
       "(SELECT COUNT(*) FROM pragma_table_info('llm_requests') WHERE name IN " +
        "('parent_session_id','routing_tier','routing_candidate_index','routing_attempt','routing_reason','routing_escalated','aidevops_version')) AS routing_cols, " +
       "(SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' " +
       "AND name IN ('runtime_events_reject_update','runtime_events_reject_delete'," +
       "'runtime_event_archives_reject_update','runtime_event_archives_reject_delete')) AS guards;"],
      {
        encoding: "utf-8",
        timeout: 2000,
        stdio: ["pipe", "pipe", "pipe"],
      },
    ).trim();
    if (!result) return false;
    const [tbls, intentCol, routingCols, guards] = result.split("|");
    return tbls === "5" && intentCol === "1" && routingCols === "7" && guards === "4";
  } catch {
    return false;
  }
}

/**
 * Run the heavy schema CREATE block (the writer-lock contention point).
 * Caller is responsible for serialising this via `withInitLock`.
 *
 * @returns {boolean} true on success
 */
export function createSchema() {
  const schema = `
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS llm_requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  session_id TEXT NOT NULL,
  message_id TEXT,
  provider_id TEXT,
  model_id TEXT,
  agent TEXT,
  tokens_input INTEGER DEFAULT 0,
  tokens_output INTEGER DEFAULT 0,
  tokens_reasoning INTEGER DEFAULT 0,
  tokens_cache_read INTEGER DEFAULT 0,
  tokens_cache_write INTEGER DEFAULT 0,
  tokens_total INTEGER DEFAULT 0,
  cost REAL DEFAULT 0.0,
  duration_ms INTEGER,
  finish_reason TEXT,
  error_type TEXT,
  error_message TEXT,
  tool_call_count INTEGER DEFAULT 0,
  project_path TEXT,
  variant TEXT,
  parent_session_id TEXT,
  routing_tier TEXT,
  routing_candidate_index INTEGER,
  routing_attempt INTEGER,
  routing_reason TEXT,
  routing_escalated INTEGER DEFAULT 0,
  aidevops_version TEXT
);

CREATE INDEX IF NOT EXISTS idx_llm_requests_session
  ON llm_requests(session_id);
CREATE INDEX IF NOT EXISTS idx_llm_requests_timestamp
  ON llm_requests(timestamp);
CREATE INDEX IF NOT EXISTS idx_llm_requests_model
  ON llm_requests(model_id);
CREATE INDEX IF NOT EXISTS idx_llm_requests_provider
  ON llm_requests(provider_id);

CREATE TABLE IF NOT EXISTS tool_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  session_id TEXT NOT NULL,
  message_id TEXT,
  call_id TEXT,
  tool_name TEXT NOT NULL,
  intent TEXT,
  success INTEGER DEFAULT 1,
  duration_ms INTEGER,
  metadata TEXT
);

CREATE INDEX IF NOT EXISTS idx_tool_calls_session
  ON tool_calls(session_id);
CREATE INDEX IF NOT EXISTS idx_tool_calls_tool
  ON tool_calls(tool_name);

CREATE TABLE IF NOT EXISTS session_summaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL UNIQUE,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  request_count INTEGER DEFAULT 0,
  total_tokens_input INTEGER DEFAULT 0,
  total_tokens_output INTEGER DEFAULT 0,
  total_cost REAL DEFAULT 0.0,
  total_tool_calls INTEGER DEFAULT 0,
  total_errors INTEGER DEFAULT 0,
  project_path TEXT,
  models_used TEXT
);

CREATE INDEX IF NOT EXISTS idx_session_summaries_session
  ON session_summaries(session_id);

`;

  const result = sqliteExecSync(schema, 10000);
  if (result === null) {
    console.error("[aidevops] Observability: schema creation failed");
    return false;
  }
  return true;
}

/**
 * Run a schema initialiser under a mkdir-based advisory lock (t2900).
 *
 * Locking is per database path. On timeout, the callback runs without the
 * advisory lock and retains SQLite's own busy-timeout protection.
 *
 * @template T
 * @param {string} dbPath
 * @param {() => T} fn
 * @returns {T}
 */
export function withInitLock(dbPath, fn) {
  const lockDir = `${dbPath}.init.lock.d`;
  const ownerFile = `${lockDir}/owner`;
  const staleMs = 30000; // schema init has historically taken <2s
  const deadline = Date.now() + 30000;

  if (!acquireInitLock(lockDir, ownerFile, staleMs, deadline)) {
    console.error("[aidevops] Observability: init lock timeout — proceeding without lock");
    return fn();
  }

  try {
    return fn();
  } finally {
    releaseInitLock(lockDir, ownerFile);
  }
}

/** Block until the init lock is acquired, reclaimed, or times out. */
function acquireInitLock(lockDir, ownerFile, staleMs, deadline) {
  const sleepBuf = new Int32Array(new SharedArrayBuffer(4));
  while (Date.now() < deadline) {
    try {
      mkdirSync(lockDir);
      writeFileSync(ownerFile, JSON.stringify({ pid: process.pid, ts: Date.now() }), { mode: 0o600 });
      return true;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (isInitLockStale(ownerFile, staleMs)) {
        removeStaleLockFiles(lockDir, ownerFile);
        continue;
      }
      Atomics.wait(sleepBuf, 0, 0, 100);
    }
  }
  return false;
}

/** Best-effort removal of a stale lock during a concurrent reclaim race. */
function removeStaleLockFiles(lockDir, ownerFile) {
  try { unlinkSync(ownerFile); } catch { /* race */ }
  try { rmdirSync(lockDir); } catch { /* race */ }
}

/** Return whether a lock owner is gone or its lock is older than `staleMs`. */
function isInitLockStale(ownerFile, staleMs) {
  try {
    const { pid, ts } = JSON.parse(readFileSync(ownerFile, "utf-8"));
    const processGone = (() => {
      try {
        process.kill(pid, 0);
        return false;
      } catch (error) {
        // ESRCH = no such process (gone); EPERM = exists but owned by another user
        return error.code === "ESRCH";
      }
    })();
    return processGone || (Date.now() - ts > staleMs);
  } catch {
    // Owner file may be missing or corrupt if a process dies after mkdirSync.
    try {
      const stats = statSync(dirname(ownerFile));
      return (Date.now() - stats.mtimeMs) > staleMs;
    } catch {
      return false;
    }
  }
}

/** Release the init lock only when its owner PID still matches this process. */
function releaseInitLock(lockDir, ownerFile) {
  try {
    const { pid } = JSON.parse(readFileSync(ownerFile, "utf-8"));
    if (pid !== process.pid) return;
    try { unlinkSync(ownerFile); } catch { /* race */ }
    try { rmdirSync(lockDir); } catch { /* race */ }
  } catch { /* lock dir already gone */ }
}
