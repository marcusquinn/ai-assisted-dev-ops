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
  PRICING_VERSION,
  UNKNOWN_PRICING_MODELS,
} from "./observability-pricing.mjs";
import { sqliteExecSync, sqlEscape } from "./observability-sqlite.mjs";

const LEGACY_UNVERIFIED_VERSION = "legacy-unverified";
const LEGACY_PRICING = {
  "gpt-5.6-terra": { input: 2.50, output: 15.0, cacheRead: 0.25, cacheWrite: 3.125 },
  "gpt-5.6-luna": { input: 1.0, output: 6.0, cacheRead: 0.10, cacheWrite: 1.25 },
};

function costExpression(pricing) {
  return `ROUND((COALESCE(tokens_input, 0) * ${pricing.input} ` +
    `+ (COALESCE(tokens_output, 0) + COALESCE(tokens_reasoning, 0)) * ${pricing.output} ` +
    `+ COALESCE(tokens_cache_read, 0) * ${pricing.cacheRead} ` +
    `+ COALESCE(tokens_cache_write, 0) * ${pricing.cacheWrite}) / 1000000.0, 8)`;
}

function publishedModelCondition(model) {
  return `(lower(provider_id) = 'openai' AND lower(model_id) LIKE '%${model}%')`;
}

function unversionedPublishedCondition() {
  return Object.keys(LEGACY_PRICING)
    .map((model) => `${publishedModelCondition(model)} AND pricing_version IS NULL`)
    .map((condition) => `(${condition})`)
    .join(" OR ");
}

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
  const predicates = [`(${unversionedPublishedCondition()})`];
  if (!existsSync(markerPath)) {
    predicates.unshift("(cost = 0.0 AND tokens_total > 0)");
  }

  const result = sqliteExecSync(
    `SELECT 1 FROM llm_requests WHERE ${predicates.join(" OR ")} LIMIT 1;`,
    5000,
  );
  if (result === null) return false;

  const hasCandidates = result === "1";
  if (!hasCandidates && !existsSync(markerPath)) markCostBackfillComplete(markerPath);
  return hasCandidates;
}

/** Schedule historical backfill and mixed-version tail repair outside startup. */
export function scheduleCostBackfill(markerPath) {
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
 * Backfill zero-cost rows and known stale GPT-5.6 estimates.
 * Uses SQL CASE expressions matching the JS pricing table to avoid
 * round-tripping each row through JS. Runs in a single UPDATE statement.
 * Idempotent — stale-price rewrites require an exact legacy formula match.
 */
export function backfillCosts(markerPath) {
  if (!hasCostBackfillCandidates(markerPath)) return;

  // Build SQL CASE expression from the pricing table
  const unknownCases = UNKNOWN_PRICING_MODELS.map((model) =>
    `WHEN lower(model_id) LIKE '%${model}%' THEN ` +
    costExpression(DEFAULT_PRICING)
  ).join("\n    ");
  const cases = Object.entries(MODEL_PRICING).map(([key, pricing]) =>
    `WHEN lower(model_id) LIKE '%${key}%' THEN ` +
    costExpression(pricing)
  ).join("\n    ");

  const zeroCostSql = `
UPDATE llm_requests
SET cost = CASE
    ${unknownCases}
    ${cases}
    ELSE ${costExpression(DEFAULT_PRICING)}
  END,
  pricing_version = ${sqlEscape(PRICING_VERSION)}
WHERE cost = 0.0 AND tokens_total > 0;
`;

  const zeroCount = updateCount(zeroCostSql);
  let staleCount = 0;
  for (const [model, legacyPricing] of Object.entries(LEGACY_PRICING)) {
    const currentPricing = MODEL_PRICING[model];
    if (!currentPricing) continue;
    const staleSql = `
UPDATE llm_requests
SET cost = ${costExpression(currentPricing)},
  pricing_version = ${sqlEscape(PRICING_VERSION)}
WHERE ${publishedModelCondition(model)}
  AND pricing_version IS NULL
  AND ABS(cost - ${costExpression(legacyPricing)}) < 0.00000001;
`;
    staleCount += updateCount(staleSql);
  }

  sqliteExecSync(`
UPDATE llm_requests
SET pricing_version = ${sqlEscape(LEGACY_UNVERIFIED_VERSION)}
WHERE pricing_version IS NULL
  AND (${unversionedPublishedCondition()});
  `, 30000);

  const changedCount = zeroCount + staleCount;
  if (changedCount > 0) {
    console.error(`[aidevops] Observability: backfilled cost for ${changedCount} rows`);

    rebuildSessionSummaries();
    console.error("[aidevops] Observability: rebuilt session_summaries with corrected costs");
  }
  markCostBackfillComplete(markerPath);
}

function updateCount(sql) {
  const countRaw = sqliteExecSync(`${sql}\nSELECT changes();`, 30000);
  const count = countRaw?.split("\n").pop() ?? "0";
  return parseInt(count, 10) || 0;
}

function rebuildSessionSummaries() {
  // Hold the writer lock across replacement so concurrent request upserts
  // cannot leave the aggregate table partially rebuilt.
  sqliteExecSync(`
BEGIN IMMEDIATE;
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
COMMIT;
  `, 30000);
}
