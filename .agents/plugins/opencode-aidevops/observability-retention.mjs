// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Bounded ingestion primitives for high-volume OpenCode observability data. */

export const TOOL_METADATA_MAX_BYTES = 1024;

const PART_STREAM_TYPES = new Set(["message.part.delta", "message.part.updated"]);
const TERMINAL_STATUSES = new Set([
  "blocked", "cancelled", "completed", "denied", "error", "failed", "rejected",
  "success", "succeeded", "timed_out", "timeout",
]);
const SAFE_STATUSES = new Set([
  ...TERMINAL_STATUSES,
  "pending", "running", "started",
]);

function jsonByteLength(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value), "utf8");
  } catch {
    return 0;
  }
}

function safeInteger(value) {
  return Number.isSafeInteger(value) ? value : undefined;
}

function firstDefined(object, keys) {
  for (const key of keys) {
    if (object?.[key] !== undefined) return object[key];
  }
  return undefined;
}

function normalizedStatus(value) {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (!normalized) return undefined;
  return SAFE_STATUSES.has(normalized) ? normalized : "other";
}

function firstTruthy(values, fallback) {
  return values.find(Boolean) || fallback;
}

/**
 * Replace raw host-tool metadata with a small outcome envelope. Raw values,
 * paths, output fragments, and unknown keys never cross the storage boundary.
 */
export function summarizeToolMetadata(metadata, { intentSource } = {}) {
  const retainedIntentSource = ["explicit", "fallback"].includes(intentSource)
    ? intentSource
    : undefined;
  if ((metadata === null || metadata === undefined) && !retainedIntentSource) return null;
  const source = metadata && typeof metadata === "object" && !Array.isArray(metadata)
    ? metadata
    : {};
  const summary = {
    schema_version: 1,
    original_bytes: jsonByteLength(metadata),
    omitted_keys: Object.keys(source).length,
  };
  const status = normalizedStatus(firstDefined(source, ["status", "state", "outcome"]));
  const exitCode = safeInteger(firstDefined(source, ["exit", "exitCode", "exit_code"]));
  const outputBytes = safeInteger(firstDefined(source, ["outputBytes", "output_bytes", "bytes"]));
  const outputLines = safeInteger(firstDefined(source, ["outputLines", "output_lines", "lineCount"]));
  const truncated = firstDefined(source, ["truncated", "isTruncated"]);
  const timedOut = firstDefined(source, ["timedOut", "timed_out", "timeout"]);

  if (status !== undefined) summary.status = status;
  if (exitCode !== undefined) summary.exit_code = exitCode;
  if (outputBytes !== undefined && outputBytes >= 0) summary.output_bytes = outputBytes;
  if (outputLines !== undefined && outputLines >= 0) summary.output_lines = outputLines;
  if (typeof truncated === "boolean") summary.truncated = truncated;
  if (typeof timedOut === "boolean") summary.timed_out = timedOut;
  if (source.error !== undefined) summary.has_error = Boolean(source.error);
  if (retainedIntentSource) summary.intent_source = retainedIntentSource;

  const retainedSourceKeys = [
    "status", "state", "outcome", "exit", "exitCode", "exit_code", "outputBytes",
    "output_bytes", "bytes", "outputLines", "output_lines", "lineCount",
    "truncated", "isTruncated", "timedOut", "timed_out", "timeout", "error",
  ].filter((key) => Object.hasOwn(source, key)).length;
  summary.omitted_keys = Math.max(0, summary.omitted_keys - retainedSourceKeys);

  if (jsonByteLength(summary) > TOOL_METADATA_MAX_BYTES) {
    return Object.freeze({
      schema_version: 1,
      original_bytes: summary.original_bytes,
      truncated: true,
    });
  }
  return Object.freeze(summary);
}

function partStreamKey(event) {
  const properties = event?.properties || {};
  const part = properties.part || {};
  const info = properties.info || {};
  const sessionId = firstTruthy([
    part.sessionID, part.sessionId, info.sessionID, properties.sessionID, properties.sessionId,
  ], "unknown-session");
  const messageId = firstTruthy([
    part.messageID, part.messageId, info.messageID, info.messageId,
    properties.messageID, properties.messageId,
  ], "unknown-message");
  return `${sessionId}:${messageId}`;
}

function partHasProtectedSignal(event) {
  const properties = event?.properties || {};
  const part = properties.part || {};
  const state = part.state || {};
  if (properties.error || part.error || state.error) return true;
  const statuses = [properties.status, part.status, state.status, part.finish, state.finish]
    .map(normalizedStatus)
    .filter(Boolean);
  return statuses.some((status) => TERMINAL_STATUSES.has(status));
}

/** Track suppressed stream amplification without retaining raw stream content. */
export class PartStreamSummaryTracker {
  constructor({ maxEntries = 1000 } = {}) {
    this.maxEntries = maxEntries;
    this.summaries = new Map();
  }

  observe(event) {
    if (!PART_STREAM_TYPES.has(event?.type) || partHasProtectedSignal(event)) return false;
    const key = partStreamKey(event);
    const existing = this.summaries.get(key) || { bytes: 0, events: 0 };
    existing.bytes += jsonByteLength(event);
    existing.events += 1;
    this.summaries.delete(key);
    this.summaries.set(key, existing);
    if (this.summaries.size > this.maxEntries) {
      const oldest = this.summaries.keys().next().value;
      this.summaries.delete(oldest);
    }
    return true;
  }

  consume(message) {
    const synthetic = {
      properties: {
        info: {
          messageID: message?.id,
          sessionID: message?.sessionID,
        },
      },
    };
    const key = partStreamKey(synthetic);
    const summary = this.summaries.get(key);
    if (!summary) return Object.freeze({ suppressed_part_bytes: 0, suppressed_part_events: 0 });
    this.summaries.delete(key);
    return Object.freeze({
      suppressed_part_bytes: summary.bytes,
      suppressed_part_events: summary.events,
    });
  }
}
