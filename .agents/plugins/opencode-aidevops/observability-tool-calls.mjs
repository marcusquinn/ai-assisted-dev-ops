// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { summarizeToolMetadata } from "./observability-retention.mjs";
import { sqlEscape } from "./observability-sqlite.mjs";
import { classifyToolOutcome } from "./session-continuation-guard.mjs";

export { classifyToolOutcome };

/** Return whether a tool result is safe to record as successful. */
export function toolCallSucceeded(output) {
  return classifyToolOutcome(output) === "success";
}

/**
 * Build the INSERT SQL for a tool_calls row. Pure function — no DB access or
 * global state — so it is exhaustively testable without sqlite3.
 *
 * Column and value order must stay aligned within this explicit INSERT.
 *
 * @param {object} args
 * @param {string} args.sessionID
 * @param {string} args.callID
 * @param {string} args.toolName
 * @param {string | null | undefined} args.intent
 * @param {0 | 1} args.isSuccess
 * @param {number | null | undefined} args.durationMs - Elapsed ms, or null/undefined to store SQL NULL
 * @param {object | null | undefined} args.metadata - Raw metadata object; summarized before persistence
 * @param {string | null | undefined} args.outcomeCategory - Bounded outcome classification
 * @returns {string} INSERT statement ready for sqliteExec
 */
export function buildToolCallInsertSql({
  sessionID, callID, toolName, intent, isSuccess, durationMs, metadata, outcomeCategory,
}) {
  const durationSql = (durationMs !== null && durationMs !== undefined)
    ? String(durationMs)
    : "NULL";
  const metadataSummary = summarizeToolMetadata(metadata);
  const metadataValue = metadataSummary === null ? null : JSON.stringify(metadataSummary);

  return `INSERT INTO tool_calls (
    session_id, call_id, tool_name, intent, success, duration_ms, metadata, outcome_category
  ) VALUES (
    ${sqlEscape(sessionID)},
    ${sqlEscape(callID)},
    ${sqlEscape(toolName)},
    ${sqlEscape(intent || null)},
    ${isSuccess},
    ${durationSql},
    ${sqlEscape(metadataValue)},
    ${sqlEscape(outcomeCategory || null)}
  );`;
}
