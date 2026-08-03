// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Delayed historical cost backfill for the OpenCode observability database.
 *
 * @module observability-cost-backfill
 */

import { existsSync, writeFileSync } from "fs";

import {
  DEFAULT_PRICING,
  MODEL_PRICING,
  UNKNOWN_PRICING_MODELS,
} from "./observability-pricing.mjs";
import { sqliteExecSync } from "./observability-sqlite.mjs";

/**
 * Return true when historical rows still need the cost backfill.
 *
 * This runs only from the delayed background migration path. On large SQLite
 * DBs even this read-only probe can take seconds without a completion marker.
 *
 * @param {string} markerPath
 * @returns {boolean}
 */
function hasCostBackfillCandidates(markerPath) {
  if (existsSync(markerPath)) return false;

  const result = sqliteExecSync(
    "SELECT 1 FROM llm_requests WHERE cost = 0.0 AND tokens_total > 0 LIMIT 1;",
    5000,
  );
  if (result === null) return false;

  const hasCandidates = result === "1";
  if (!hasCandidates) markCostBackfillComplete(markerPath);
  return hasCandidates;
}

/** Schedule the one-time historical cost backfill outside plugin startup. */
export function scheduleCostBackfill(markerPath) {
  if (existsSync(markerPath)) return;

  const timer = setTimeout(() => {
    try {
      backfillCosts(markerPath);
    } catch (error) {
      if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
        console.error(`[aidevops] Observability: delayed cost backfill failed: ${error.message}`);
      }
    }
  }, 2500);
  timer.unref?.();
}

/** Record that the one-time historical cost migration is complete. */
function markCostBackfillComplete(markerPath) {
  try {
    writeFileSync(markerPath, `${new Date().toISOString()}\n`, { mode: 0o600 });
  } catch {
    // best-effort marker only; migration remains safe without it
  }
}

/**
 * Backfill cost for historical rows where cost=0 but tokens exist.
 * Uses SQL CASE expressions matching the JS pricing table to avoid
 * round-tripping each row through JS. Runs in a single UPDATE statement.
 * Idempotent — only updates rows where cost=0 AND tokens_total>0.
 */
function backfillCosts(markerPath) {
  if (!hasCostBackfillCandidates(markerPath)) return;

  // Build SQL CASE expression from the pricing table
  const unknownCases = UNKNOWN_PRICING_MODELS.map((model) =>
    `WHEN lower(model_id) LIKE '%${model}%' THEN ` +
    `(tokens_input * ${DEFAULT_PRICING.input} + (tokens_output + tokens_reasoning) * ${DEFAULT_PRICING.output} ` +
    `+ tokens_cache_read * ${DEFAULT_PRICING.cacheRead} + tokens_cache_write * ${DEFAULT_PRICING.cacheWrite}) / 1000000.0`
  ).join("\n    ");
  const cases = Object.entries(MODEL_PRICING).map(([key, pricing]) =>
    `WHEN lower(model_id) LIKE '%${key}%' THEN ` +
    `(tokens_input * ${pricing.input} + (tokens_output + tokens_reasoning) * ${pricing.output} ` +
    `+ tokens_cache_read * ${pricing.cacheRead} + tokens_cache_write * ${pricing.cacheWrite}) / 1000000.0`
  ).join("\n    ");

  const sql = `
UPDATE llm_requests
SET cost = CASE
    ${unknownCases}
    ${cases}
    ELSE (tokens_input * ${DEFAULT_PRICING.input} + (tokens_output + tokens_reasoning) * ${DEFAULT_PRICING.output}
      + tokens_cache_read * ${DEFAULT_PRICING.cacheRead} + tokens_cache_write * ${DEFAULT_PRICING.cacheWrite}) / 1000000.0
  END
WHERE cost = 0.0 AND tokens_total > 0;
`;

  // Combine UPDATE and SELECT changes() in a single sqliteExecSync call so
  // they run on the same sqlite3 connection — a separate call returns 0.
  const countRaw = sqliteExecSync(`${sql}\nSELECT changes();`, 30000);
  const count = countRaw?.split("\n").pop() ?? "0";
  if (parseInt(count, 10) > 0) {
    console.error(`[aidevops] Observability: backfilled cost for ${count} rows`);

    // Rebuild session_summaries from the corrected data.
    // Compute total_errors from actual error columns instead of hardcoding 0.
    sqliteExecSync(`
DELETE FROM session_summaries;
INSERT INTO session_summaries (session_id, first_seen, last_seen, request_count,
  total_tokens_input, total_tokens_output, total_cost, total_tool_calls, total_errors,
  project_path, models_used)
SELECT session_id, MIN(timestamp), MAX(timestamp), COUNT(*),
  SUM(tokens_input), SUM(tokens_output), SUM(cost), MAX(tool_call_count),
  SUM(CASE WHEN error_type IS NOT NULL OR error_message IS NOT NULL THEN 1 ELSE 0 END),
  MAX(project_path), GROUP_CONCAT(DISTINCT model_id)
FROM llm_requests
GROUP BY session_id;
    `, 30000);
    console.error("[aidevops] Observability: rebuilt session_summaries with corrected costs");
  }
  markCostBackfillComplete(markerPath);
}
