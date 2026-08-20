// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";

const MAX_TASKS = 20;
const MAX_TEXT_LENGTH = 240;

export function boundedText(value) {
  return String(value ?? "")
    .replace(/(?:sk-|gh[pousr]_|github_pat_|glpat-|xox[baprs]-)[A-Za-z0-9_.-]{8,}/gi, "[redacted]")
    .replace(/\b(?:password|secret|token|api[_-]?key)\s*[:=]\s*\S+/gi, "credential=[redacted]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAX_TEXT_LENGTH);
}

function normalizedShape(value, key = "") {
  let normalized = null;
  if (/intent|password|secret|token|authorization|api.?key/i.test(key)) {
    normalized = "[redacted]";
  } else if (Array.isArray(value)) {
    normalized = value.slice(0, 20).map((item) => normalizedShape(item));
  } else if (value && typeof value === "object") {
    normalized = Object.fromEntries(
      Object.keys(value)
        .sort()
        .slice(0, 40)
        .map((childKey) => [childKey, normalizedShape(value[childKey], childKey)]),
    );
  } else if (typeof value === "string") {
    normalized = boundedText(value);
  } else if (["number", "boolean"].includes(typeof value)) {
    normalized = value;
  }
  return normalized;
}

export function operationFingerprint(toolName, args) {
  const shape = JSON.stringify({ tool: String(toolName || "unknown").toLowerCase(), args: normalizedShape(args || {}) });
  return createHash("sha256").update(shape).digest("hex");
}

export function classifyToolOutcome(output) {
  const text = String(output?.output || "").trim();
  if (/^BLOCKED by shared command policy\b/i.test(text)) return "policy_block";

  const status = String(output?.metadata?.status || output?.status || "").toLowerCase();
  const failedStatuses = [
    "aborted", "blocked", "cancelled", "canceled", "denied", "error", "failed",
    "rejected", "timed_out", "timeout",
  ];
  if (failedStatuses.includes(status) || output?.error || output?.metadata?.error) return "tool_error";

  const exitCode = [output?.metadata?.exit, output?.metadata?.exitCode, output?.metadata?.exit_code]
    .find((value) => Number.isInteger(value));
  if (exitCode !== undefined) return exitCode === 0 ? "success" : "command_failure";
  if (["completed", "success", "succeeded"].includes(status)) return "success";
  if (/^(?:error|failed|aborted|cancelled|canceled|tool execution aborted|operation timed out)\b/i.test(text)) {
    return "tool_error";
  }
  return "success";
}

export function toolOutcomeFailed(output) {
  return classifyToolOutcome(output) !== "success";
}

export function isExplicitCompletionClaim(text) {
  const normalized = String(text || "").replace(/`[^`]*`/g, " ");
  if (/\b(?:not|isn't|is not|aren't|are not)\s+(?:done|complete|completed|finished)\b/i.test(normalized)) return false;
  return /(?:^|[.!?]\s+)(?:FULL_LOOP_COMPLETE\b|(?:the\s+)?(?:task|work|implementation|objective|issue|request)\s+(?:is|has been)\s+(?:now\s+)?(?:done|complete|completed|finished)|(?:all|everything)\s+(?:is|has been)\s+(?:done|complete|completed|finished))/im.test(normalized);
}

export function sessionId(input) {
  return String(input?.sessionID || input?.sessionId || input?.session?.id || "unknown-session");
}

function terminalTodoStatus(status) {
  return ["completed", "cancelled", "canceled"].includes(String(status || "").toLowerCase());
}

export function activeTodos(todos) {
  if (!Array.isArray(todos)) return [];
  return todos
    .filter((todo) => !terminalTodoStatus(todo?.status))
    .slice(0, MAX_TASKS)
    .map((todo) => boundedText(todo?.content || todo?.title || "Unresolved task"));
}

export function capMap(map, maxEntries) {
  while (map.size > maxEntries) map.delete(map.keys().next().value);
}
