// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
} from "node:fs";
import { dirname } from "node:path";

import {
  acquireWorkerBlockerLock as acquireLock,
  releaseWorkerBlockerLock as releaseLock,
} from "./worker-blocker-lock.mjs";
import {
  appendNormalizedWorkerBlockerEventsUnlocked,
  cleanWorkerBlockerIssueNumber,
  normalizeWorkerBlockerRepoSlug,
  resolveWorkerBlockerLogPath,
  resolveWorkerBlockerMaxBytes,
  WORKER_BLOCKER_SCHEMA,
} from "./worker-blocker-log.mjs";

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
    const eventIssue = cleanWorkerBlockerIssueNumber(event.issue_number);
    return eventRepo === repoSlug && eventIssue !== null
      && (issueNumber === null || eventIssue === issueNumber);
  });
}

function activeWorkerBlockerEvents(logPath, repoSlug, issueNumber = null) {
  const scoped = scopedWorkerBlockerEvents(readFileSync(logPath), repoSlug, issueNumber);
  return latestWorkerBlockerEvents(scoped).filter((event) => event.blocking === true);
}

function workerBlockerScope(input, options) {
  const issueNumber = cleanWorkerBlockerIssueNumber(input.issue_number);
  const repoSlug = normalizeWorkerBlockerRepoSlug(input.repo_slug, options);
  if (issueNumber === null || !repoSlug.includes("/")) throw new Error("Invalid worker blocker scope");
  return { issueNumber, repoSlug };
}

function safeWorkerBlockerLog(logPath) {
  if (lstatSync(logPath).isSymbolicLink()) throw new Error("Refusing symlinked blocker log");
}

function terminalResolutionOptions(active, options) {
  const requestedNow = options.now instanceof Date ? options.now : new Date();
  const latestActiveTimestamp = active.reduce((maximum, event) => {
    const timestamp = Number.isFinite(Number(event.ts)) ? Number(event.ts) : 0;
    return Math.max(maximum, timestamp);
  }, 0);
  const resolutionEpoch = Math.max(Math.floor(requestedNow.getTime() / 1000), latestActiveTimestamp + 1);
  return { ...options, now: new Date(resolutionEpoch * 1000) };
}

function terminalWorkerBlockerEvents(active, input, issueNumber, repoSlug) {
  return active.map((event) => ({
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
}

function releaseLockSafely(lockPath, lockToken) {
  if (!lockToken) return;
  try {
    releaseLock(lockPath, lockToken);
  } catch {
    // Reconciliation is best effort and must not block issue closure.
  }
}

function resolutionResult(ok, resolvedCount = 0) {
  return { ok, resolvedCount };
}

export function resolveWorkerBlockersForIssue(input = {}, options = {}) {
  let result = resolutionResult(false);
  let lockPath = "";
  let lockToken = "";
  try {
    const { issueNumber, repoSlug } = workerBlockerScope(input, options);
    const logPath = resolveWorkerBlockerLogPath(options);
    const maxBytes = resolveWorkerBlockerMaxBytes(options);
    mkdirSync(dirname(logPath), { recursive: true, mode: 0o700 });
    if (existsSync(logPath)) safeWorkerBlockerLog(logPath);
    lockPath = `${logPath}.lock`;
    lockToken = acquireLock(lockPath);
    if (!lockToken) throw new Error("Worker blocker lock unavailable");

    if (!existsSync(logPath)) {
      result = resolutionResult(true);
    } else {
      safeWorkerBlockerLog(logPath);
      const active = activeWorkerBlockerEvents(logPath, repoSlug, issueNumber);
      if (active.length === 0) {
        result = resolutionResult(true);
      } else {
        const terminalEvents = terminalWorkerBlockerEvents(active, input, issueNumber, repoSlug);
        const resolutionOptions = terminalResolutionOptions(active, options);
        if (appendNormalizedWorkerBlockerEventsUnlocked(
          logPath,
          terminalEvents,
          resolutionOptions,
          maxBytes,
        )) result = resolutionResult(true, terminalEvents.length);
      }
    }
  } catch {
    // Fail open: closure paths continue while the active record stays visible.
  } finally {
    releaseLockSafely(lockPath, lockToken);
  }
  return result;
}

function activeIssueNumbers(logPath, repoSlug, limit) {
  return [...new Set(activeWorkerBlockerEvents(logPath, repoSlug)
    .map((event) => cleanWorkerBlockerIssueNumber(event.issue_number))
    .filter((issueNumber) => issueNumber !== null))]
    .sort((left, right) => left - right)
    .slice(0, limit);
}

function workerBlockerCandidateLimit(value) {
  const requestedLimit = Number(value ?? 50);
  return Number.isSafeInteger(requestedLimit) && requestedLimit > 0 ? requestedLimit : 50;
}

export function listActiveWorkerBlockerIssues(input = {}, options = {}) {
  let result = { ok: false, issues: [] };
  let lockPath = "";
  let lockToken = "";
  try {
    const repoSlug = normalizeWorkerBlockerRepoSlug(input.repo_slug, options);
    if (!repoSlug.includes("/")) throw new Error("Invalid worker blocker repository");
    const logPath = resolveWorkerBlockerLogPath(options);
    if (!existsSync(logPath)) {
      result = { ok: true, issues: [] };
    } else {
      safeWorkerBlockerLog(logPath);
      lockPath = `${logPath}.lock`;
      lockToken = acquireLock(lockPath);
      if (!lockToken || !existsSync(logPath)) throw new Error("Worker blocker log unavailable");
      safeWorkerBlockerLog(logPath);
      result = {
        ok: true,
        issues: activeIssueNumbers(logPath, repoSlug, workerBlockerCandidateLimit(input.limit)),
      };
    }
  } catch {
    // Fail open: callers skip ambiguous candidate discovery.
  } finally {
    releaseLockSafely(lockPath, lockToken);
  }
  return result;
}
