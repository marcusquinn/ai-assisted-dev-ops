#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  closeSync,
  constants,
  existsSync,
  fchmodSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

import {
  acquireWorkerBlockerLock as acquireLock,
  releaseWorkerBlockerLock as releaseLock,
} from "./worker-blocker-lock.mjs";

export const WORKER_BLOCKER_SCHEMA = "aidevops-worker-blocker/v1";
export const DEFAULT_WORKER_BLOCKER_LOG_MAX_BYTES = 5 * 1024 * 1024;

const MIN_LOG_MAX_BYTES = 512;
const MAX_DETAIL_LENGTH = 500;
const MAX_FIELD_LENGTH = 200;
const CREDENTIAL_PATTERN = /(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;

function cleanText(value, maxLength, options = {}) {
  if (value === null || value === undefined) return "";
  const home = options.home || homedir();
  const workDir = options.workDir || process.env.WORKER_WORKTREE_PATH || "";
  let text = String(value)
    .replace(CREDENTIAL_PATTERN, "$1[redacted-credential]")
    .replace(/(authorization\s*:\s*bearer\s+)[^\s,;]+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|token|secret|password|authorization|credential)\s*[:=]\s*)[^\s,;]+/gi, "$1[REDACTED]")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .trim();
  if (home && text.includes(home)) text = text.split(home).join("~");
  if (workDir && text.includes(workDir)) text = text.split(workDir).join("$WORKTREE");
  return text.slice(0, maxLength);
}

function cleanIssueNumber(value) {
  const text = String(value ?? "");
  if (!/^[0-9]+$/.test(text)) return null;
  const parsed = Number(text);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function resolveLogPath(options = {}) {
  return options.logPath
    || process.env.AIDEVOPS_WORKER_BLOCKER_LOG_FILE
    || resolve(homedir(), ".aidevops", "logs", "worker-progress-blockers.jsonl");
}

function resolveMaxBytes(options = {}) {
  const raw = options.maxBytes ?? process.env.AIDEVOPS_WORKER_BLOCKER_LOG_MAX_BYTES;
  const parsed = Number(raw || DEFAULT_WORKER_BLOCKER_LOG_MAX_BYTES);
  if (!Number.isSafeInteger(parsed) || parsed < MIN_LOG_MAX_BYTES) {
    return DEFAULT_WORKER_BLOCKER_LOG_MAX_BYTES;
  }
  return parsed;
}

export function normalizeWorkerBlockerEvent(input = {}, options = {}) {
  const now = options.now instanceof Date ? options.now : new Date();
  const issueNumber = cleanIssueNumber(input.issue_number ?? process.env.WORKER_ISSUE_NUMBER);
  const grantable = typeof input.grantable === "boolean" ? input.grantable : null;
  return {
    schema: WORKER_BLOCKER_SCHEMA,
    ts: Math.floor(now.getTime() / 1000),
    timestamp: now.toISOString(),
    event: cleanText(input.event || "worker_progress_blocked", MAX_FIELD_LENGTH, options),
    status: cleanText(input.status || "blocked", 50, options),
    reason: cleanText(input.reason || "unknown", MAX_FIELD_LENGTH, options),
    blocking: input.blocking !== false,
    source: cleanText(input.source || "unknown", MAX_FIELD_LENGTH, options),
    issue_number: issueNumber,
    repo_slug: cleanText(input.repo_slug || process.env.WORKER_REPO_SLUG || process.env.DISPATCH_REPO_SLUG || "", MAX_FIELD_LENGTH, options).toLowerCase(),
    session_key: cleanText(input.session_key || process.env.WORKER_SESSION_KEY || "", MAX_FIELD_LENGTH, options),
    request_id: cleanText(input.request_id || process.env.AIDEVOPS_PERMISSION_REQUEST_ID || "", MAX_FIELD_LENGTH, options),
    permission: cleanText(input.permission || "", 100, options),
    tool: cleanText(input.tool || "", 100, options),
    risk_level: cleanText(input.risk_level || "", 20, options),
    grantable,
    detail: cleanText(input.detail || "", MAX_DETAIL_LENGTH, options),
  };
}

function newestCompleteLinesWithinBudget(content, budget) {
  if (budget <= 0) return "";
  const lines = content.toString("utf8").split("\n").filter(Boolean);
  const kept = [];
  let bytes = 0;
  for (let index = lines.length - 1; index >= 0; index--) {
    const line = `${lines[index]}\n`;
    const lineBytes = Buffer.byteLength(line);
    if (lineBytes > budget - bytes) break;
    kept.push(line);
    bytes += lineBytes;
  }
  return kept.reverse().join("");
}

function trimBeforeAppend(logPath, incomingBytes, maxBytes) {
  if (!existsSync(logPath)) return;
  if (lstatSync(logPath).isSymbolicLink()) throw new Error("Refusing symlinked blocker log");
  const currentSize = statSync(logPath).size;
  if (currentSize + incomingBytes <= maxBytes) return;
  const retained = newestCompleteLinesWithinBudget(readFileSync(logPath), maxBytes - incomingBytes);
  const temporary = `${logPath}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(temporary, retained, { mode: 0o600 });
  renameSync(temporary, logPath);
}

function parseWorkerBlockerEvents(content) {
  const events = [];
  for (const line of content.toString("utf8").split("\n")) {
    if (!line) continue;
    try {
      const event = JSON.parse(line);
      if (event?.schema === WORKER_BLOCKER_SCHEMA) events.push(event);
    } catch {
      // Malformed historical rows are ignored, matching the fail-open readers.
    }
  }
  return events;
}

function workerBlockerIdentity(event) {
  const sessionKey = typeof event.session_key === "string" ? event.session_key : "";
  const requestId = event.request_id === null || event.request_id === undefined
    ? "unknown"
    : String(event.request_id);
  return `${event.repo_slug || ""}|${event.issue_number ?? ""}|${sessionKey || requestId}`;
}

function latestWorkerBlockerEvents(events) {
  const latest = new Map();
  for (const event of events) {
    const identity = workerBlockerIdentity(event);
    const timestamp = Number.isFinite(Number(event.ts)) ? Number(event.ts) : 0;
    const current = latest.get(identity);
    if (!current || timestamp >= current.timestamp) latest.set(identity, { event, timestamp });
  }
  return [...latest.values()].map(({ event }) => event);
}

function scopedWorkerBlockerEvents(content, repoSlug, issueNumber = null) {
  return parseWorkerBlockerEvents(content).filter((event) => {
    const eventRepo = String(event.repo_slug || "").toLowerCase();
    const eventIssue = cleanIssueNumber(event.issue_number);
    return eventRepo === repoSlug && eventIssue !== null
      && (issueNumber === null || eventIssue === issueNumber);
  });
}

function appendNormalizedEventsUnlocked(logPath, inputs, options, maxBytes) {
  const content = inputs
    .map((input) => `${JSON.stringify(normalizeWorkerBlockerEvent(input, options))}\n`)
    .join("");
  const incomingBytes = Buffer.byteLength(content);
  if (!content || incomingBytes > maxBytes) return false;
  trimBeforeAppend(logPath, incomingBytes, maxBytes);
  const descriptor = openSync(logPath, constants.O_APPEND | constants.O_CREAT | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
  try {
    writeFileSync(descriptor, content);
    fchmodSync(descriptor, 0o600);
  } finally {
    closeSync(descriptor);
  }
  return true;
}

export function appendWorkerBlockerEvent(input, options = {}) {
  let lockPath = "";
  let lockToken = "";
  try {
    const logPath = resolveLogPath(options);
    const maxBytes = resolveMaxBytes(options);
    mkdirSync(dirname(logPath), { recursive: true, mode: 0o700 });
    if (existsSync(logPath) && lstatSync(logPath).isSymbolicLink()) return false;
    lockPath = `${logPath}.lock`;
    lockToken = acquireLock(lockPath);
    if (!lockToken) return false;
    return appendNormalizedEventsUnlocked(logPath, [input], options, maxBytes);
  } catch {
    return false;
  } finally {
    if (lockToken) {
      try {
        releaseLock(lockPath, lockToken);
      } catch {
        // Logging remains best effort and must never stop worker execution.
      }
    }
  }
}

export function resolveWorkerBlockersForIssue(input = {}, options = {}) {
  let lockPath = "";
  let lockToken = "";
  try {
    const issueNumber = cleanIssueNumber(input.issue_number);
    const repoSlug = cleanText(input.repo_slug || "", MAX_FIELD_LENGTH, options).toLowerCase();
    if (issueNumber === null || !repoSlug.includes("/")) return { ok: false, resolvedCount: 0 };

    const logPath = resolveLogPath(options);
    const maxBytes = resolveMaxBytes(options);
    mkdirSync(dirname(logPath), { recursive: true, mode: 0o700 });
    if (existsSync(logPath) && lstatSync(logPath).isSymbolicLink()) return { ok: false, resolvedCount: 0 };
    lockPath = `${logPath}.lock`;
    lockToken = acquireLock(lockPath);
    if (!lockToken) return { ok: false, resolvedCount: 0 };
    if (!existsSync(logPath)) return { ok: true, resolvedCount: 0 };
    if (lstatSync(logPath).isSymbolicLink()) return { ok: false, resolvedCount: 0 };

    const latest = latestWorkerBlockerEvents(
      scopedWorkerBlockerEvents(readFileSync(logPath), repoSlug, issueNumber),
    );
    const active = latest.filter((event) => event.blocking === true);
    if (active.length === 0) return { ok: true, resolvedCount: 0 };

    const requestedNow = options.now instanceof Date ? options.now : new Date();
    const latestActiveTimestamp = active.reduce((maximum, event) => {
      const timestamp = Number.isFinite(Number(event.ts)) ? Number(event.ts) : 0;
      return Math.max(maximum, timestamp);
    }, 0);
    const resolutionEpoch = Math.max(Math.floor(requestedNow.getTime() / 1000), latestActiveTimestamp + 1);
    const resolutionOptions = { ...options, now: new Date(resolutionEpoch * 1000) };
    const terminalEvents = active.map((event) => ({
      event: input.event || "issue_terminal_reconciled",
      status: input.status || "resolved",
      reason: input.reason || "issue_terminal",
      blocking: false,
      source: input.source || "worker-blocker-log",
      issue_number: issueNumber,
      repo_slug: repoSlug,
      session_key: event.session_key || "",
      request_id: event.request_id ?? "",
      permission: event.permission || "",
      tool: event.tool || "",
      risk_level: event.risk_level || "",
      grantable: typeof event.grantable === "boolean" ? event.grantable : null,
      detail: input.detail || "",
    }));
    if (!appendNormalizedEventsUnlocked(logPath, terminalEvents, resolutionOptions, maxBytes)) {
      return { ok: false, resolvedCount: 0 };
    }
    return { ok: true, resolvedCount: terminalEvents.length };
  } catch {
    return { ok: false, resolvedCount: 0 };
  } finally {
    if (lockToken) {
      try {
        releaseLock(lockPath, lockToken);
      } catch {
        // Reconciliation remains best effort and must not block closure paths.
      }
    }
  }
}

export function listActiveWorkerBlockerIssues(input = {}, options = {}) {
  let lockPath = "";
  let lockToken = "";
  try {
    const repoSlug = cleanText(input.repo_slug || "", MAX_FIELD_LENGTH, options).toLowerCase();
    const requestedLimit = Number(input.limit ?? 50);
    const limit = Number.isSafeInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : 50;
    if (!repoSlug.includes("/")) return { ok: false, issues: [] };

    const logPath = resolveLogPath(options);
    if (!existsSync(logPath)) return { ok: true, issues: [] };
    if (lstatSync(logPath).isSymbolicLink()) return { ok: false, issues: [] };
    lockPath = `${logPath}.lock`;
    lockToken = acquireLock(lockPath);
    if (!lockToken) return { ok: false, issues: [] };
    if (!existsSync(logPath) || lstatSync(logPath).isSymbolicLink()) return { ok: false, issues: [] };

    const latest = latestWorkerBlockerEvents(
      scopedWorkerBlockerEvents(readFileSync(logPath), repoSlug),
    );
    const issues = [...new Set(latest
      .filter((event) => event.blocking === true)
      .map((event) => cleanIssueNumber(event.issue_number))
      .filter((issueNumber) => issueNumber !== null))]
      .sort((left, right) => left - right)
      .slice(0, limit);
    return { ok: true, issues };
  } catch {
    return { ok: false, issues: [] };
  } finally {
    if (lockToken) {
      try {
        releaseLock(lockPath, lockToken);
      } catch {
        // Read-only candidate discovery remains fail open.
      }
    }
  }
}

function parseCliArguments(argv) {
  const event = {};
  const options = {};
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--blocking") {
      event.blocking = value !== "false";
      index++;
    } else if (flag === "--log-file") {
      options.logPath = value;
      index++;
    } else if (flag === "--max-bytes") {
      options.maxBytes = Number(value);
      index++;
    } else if (flag?.startsWith("--")) {
      const key = flag.slice(2).replaceAll("-", "_");
      event[key] = value ?? "";
      index++;
    }
  }
  return { event, options };
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  const { event, options } = parseCliArguments(args);
  if (command === "append") return appendWorkerBlockerEvent(event, options) ? 0 : 1;
  if (command === "resolve-issue") {
    const result = resolveWorkerBlockersForIssue(event, options);
    if (result.ok) process.stdout.write(`${result.resolvedCount}\n`);
    return result.ok ? 0 : 1;
  }
  if (command === "list-active-issues") {
    const result = listActiveWorkerBlockerIssues(event, options);
    if (result.ok && result.issues.length > 0) process.stdout.write(`${result.issues.join("\n")}\n`);
    return result.ok ? 0 : 1;
  }
  return 2;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = main();
}
