// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { homedir } from "node:os";
import { delimiter } from "node:path";

export const RUNTIME_EVENT_PAYLOAD_MAX_BYTES = 16 * 1024;

const MAX_DEPTH = 8;
const MAX_KEYS = 128;
const MAX_ARRAY_ITEMS = 128;
const MAX_STRING_LENGTH = 2048;
const SECRET_KEY_PATTERN = /^(auth|authorization|cookie|set_cookie|credentials?|password|passwd|secret|token|[a-z0-9]+_token|api_key|client_secret|private_key|database_url|dsn)$/i;
const PATH_KEY_PATTERN = /(^|_)(cwd|dir|directory|file|path|root|worktree)(_|$)/i;
const REPOSITORY_KEY_PATTERN = /^(project_name|repo|repository|repo_slug|repository_slug)$/i;
const CREDENTIAL_PATTERN = /(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;
const AWS_ACCESS_KEY_PATTERN = /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g;
const AWS_SECRET_KEY_PATTERN = /\b[A-Za-z0-9/+=]{40}\b/g;
const JWT_PATTERN = /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g;
const BASIC_AUTH_PATTERN = /\bBasic\s+[A-Za-z0-9+/=_-]{8,}/gi;
const PEM_PATTERN = /-----BEGIN [A-Z0-9 ]+-----[\s\S]*?-----END [A-Z0-9 ]+-----/g;
const FILE_URL_PATTERN = /\bfile:\/\/\/[^\s"',)}\]]+/gi;
const ABSOLUTE_PATH_PATTERN = /(^|[\s("'=])(?:\/[^\s"',)}\]]+|[A-Za-z]:[\\/][^\s"',)}\]]+)/gm;
const REPOSITORY_LIKE_PATTERN = /\b[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\b/g;
const ORDINARY_PAYLOAD_KEYS = new Set([
  "aidevops_version", "attempt_id", "call_id", "classification", "duration_ms", "error_type", "exit_code",
  "finish_reason", "model_id", "observation", "outcome_category", "provider_id", "reason", "result",
  "pricing_version", "role", "routing_attempt", "routing_candidate_index", "routing_escalated",
  "routing_population", "routing_reason", "routing_tier", "run_id", "source", "status", "success",
  "suppressed_part_bytes", "suppressed_part_events", "tool_name",
]);
const NOT_SCALAR = Symbol("not-scalar");

function replaceSensitivePattern(value, pattern, replacement, counters) {
  return value.replace(pattern, (...args) => {
    counters.redactions++;
    return typeof replacement === "function" ? replacement(...args) : replacement;
  });
}

function configuredPrivateRoots() {
  const values = [process.env.HOME || homedir()];
  if (process.env.AIDEVOPS_PRIVATE_ROOTS) {
    values.push(...process.env.AIDEVOPS_PRIVATE_ROOTS.split(delimiter));
  }
  return values.filter((value) => value && value.startsWith("/"));
}

function redactPrivateRoots(value, counters, privateRoots) {
  let result = value;
  for (const root of privateRoots) {
    if (!result.includes(root)) continue;
    counters.redactions++;
    result = result.split(root).join("[redacted-root]");
  }
  return result;
}

function redactString(value, redactPaths, counters, privateRoots) {
  let result = value;
  result = replaceSensitivePattern(result, CREDENTIAL_PATTERN,
    (_match, boundary) => `${boundary}[redacted-credential]`, counters);
  result = replaceSensitivePattern(result, AWS_ACCESS_KEY_PATTERN, "[redacted-aws-key]", counters);
  result = replaceSensitivePattern(result, AWS_SECRET_KEY_PATTERN, "[redacted-aws-secret]", counters);
  result = replaceSensitivePattern(result, JWT_PATTERN, "[redacted-jwt]", counters);
  result = replaceSensitivePattern(result, BASIC_AUTH_PATTERN, "Basic [redacted]", counters);
  result = replaceSensitivePattern(result, PEM_PATTERN, "[redacted-pem]", counters);
  result = replaceSensitivePattern(result, /\bBearer\s+[^\s,"']+/gi, "Bearer [redacted]", counters);
  result = replaceSensitivePattern(result, /(https?:\/\/)[^/@:\s]+:[^/@\s]+@/gi,
    (_match, scheme) => `${scheme}[redacted]@`, counters);
  result = redactPrivateRoots(result, counters, privateRoots);
  if (redactPaths) {
    result = replaceSensitivePattern(result, FILE_URL_PATTERN, "[redacted-file-url]", counters);
    result = replaceSensitivePattern(result, ABSOLUTE_PATH_PATTERN,
      (_match, boundary) => `${boundary}[redacted-path]`, counters);
  }
  result = replaceSensitivePattern(result, REPOSITORY_LIKE_PATTERN, "[redacted-repository]", counters);
  if (result.length > MAX_STRING_LENGTH) {
    counters.truncations++;
    result = `${result.slice(0, MAX_STRING_LENGTH)}[truncated]`;
  }
  return result;
}

function sanitizedScalar(value, normalizedKey, context) {
  let result = NOT_SCALAR;
  if (value === null) {
    result = null;
  } else if (SECRET_KEY_PATTERN.test(normalizedKey)) {
    context.counters.redactions++;
    result = "[redacted]";
  } else if (context.redactPaths && PATH_KEY_PATTERN.test(normalizedKey)) {
    context.counters.redactions++;
    result = "[redacted-path]";
  } else if (context.redactPaths && REPOSITORY_KEY_PATTERN.test(normalizedKey)) {
    context.counters.redactions++;
    result = "[redacted-repository]";
  } else if (typeof value === "boolean" || typeof value === "number") {
    result = Number.isFinite(value) || typeof value === "boolean" ? value : null;
  } else if (typeof value === "string") {
    result = redactString(value, context.redactPaths, context.counters, context.privateRoots);
  } else if (typeof value === "bigint") {
    result = value.toString();
  } else if (typeof value !== "object") {
    result = null;
  }
  return result;
}

function sanitizeArray(value, context, depth) {
  const items = value.slice(0, MAX_ARRAY_ITEMS)
    .map((item) => sanitizeValue(item, context, depth + 1, ""));
  if (value.length > MAX_ARRAY_ITEMS) {
    context.counters.truncations++;
    items.push("[truncated-items]");
  }
  return items;
}

function sanitizeObject(value, context, depth) {
  const output = {};
  const keys = Object.keys(value).sort();
  for (const objectKey of keys.slice(0, MAX_KEYS)) {
    if (depth === 0 && context.strictTopLevel && !ORDINARY_PAYLOAD_KEYS.has(objectKey)) {
      context.counters.redactions++;
      continue;
    }
    output[objectKey] = sanitizeValue(value[objectKey], context, depth + 1, objectKey);
  }
  if (keys.length > MAX_KEYS) {
    context.counters.truncations++;
    output._truncated_keys = keys.length - MAX_KEYS;
  }
  return output;
}

function sanitizeValue(value, context, depth = 0, key = "") {
  const normalizedKey = key.replace(/([a-z0-9])([A-Z])/g, "$1_$2").replace(/-/g, "_");
  const scalar = sanitizedScalar(value, normalizedKey, context);
  if (scalar !== NOT_SCALAR) return scalar;
  if (depth >= MAX_DEPTH) {
    context.counters.truncations++;
    return "[max-depth]";
  }
  if (context.seen.has(value)) {
    context.counters.truncations++;
    return "[circular]";
  }
  context.seen.add(value);
  return Array.isArray(value)
    ? sanitizeArray(value, context, depth)
    : sanitizeObject(value, context, depth);
}

function boundedPayload(value, counters, redactPaths) {
  let json = JSON.stringify(value);
  let bytes = Buffer.byteLength(json, "utf8");
  if (bytes > RUNTIME_EVENT_PAYLOAD_MAX_BYTES) {
    counters.truncations++;
    const marker = { _original_bytes: bytes, _truncated: true };
    const stateKey = redactPaths && value !== null && typeof value === "object" && !Array.isArray(value)
      ? ["state", "patch"].find((candidate) => Object.hasOwn(value, candidate))
      : null;
    json = JSON.stringify(stateKey ? { [stateKey]: marker } : marker);
    bytes = Buffer.byteLength(json, "utf8");
  }
  return { bytes, json };
}

/** Redact and bound a payload before persistence. */
export function prepareRuntimePayload(payload, { redactPaths = true, strictTopLevel = true } = {}) {
  const counters = { redactions: 0, truncations: 0 };
  const value = sanitizeValue(payload ?? {}, {
    counters,
    privateRoots: configuredPrivateRoots(),
    redactPaths,
    seen: new WeakSet(),
    strictTopLevel,
  });
  const { bytes, json } = boundedPayload(value, counters, redactPaths);
  return {
    bytes,
    json,
    redactionCount: counters.redactions,
    truncated: counters.truncations > 0,
    value: JSON.parse(json),
  };
}
