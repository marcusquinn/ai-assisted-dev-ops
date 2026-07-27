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

export function workerBlockerIdentity(event) {
  const sessionKey = typeof event.session_key === "string" ? event.session_key : "";
  const requestId = event.request_id === null || event.request_id === undefined
    ? ""
    : String(event.request_id);
  return `${event.repo_slug || ""}|${event.issue_number ?? ""}|${sessionKey || "unknown"}|${requestId || "unknown"}`;
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

export function activeWorkerBlockerEventsMatching(logPath, matchesScope) {
  const scoped = parseWorkerBlockerEvents(readFileSync(logPath)).filter(matchesScope);
  return latestWorkerBlockerEvents(scoped).filter((event) => event.blocking === true);
}

export function safeWorkerBlockerLog(logPath) {
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

export function releaseWorkerBlockerLockSafely(lockPath, lockToken) {
  if (!lockToken) return;
  try {
    releaseLock(lockPath, lockToken);
  } catch {
    // Reconciliation is best effort and must not block terminal paths.
  }
}

function resolutionResult(ok, resolvedCount = 0) {
  return { ok, resolvedCount };
}

export function reconcileWorkerBlockers(input, options, contract) {
  let result = resolutionResult(false);
  let lockPath = "";
  let lockToken = "";
  try {
    const scope = contract.resolveScope(input, options);
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
      const active = contract.activeEvents(logPath, scope);
      if (active.length === 0) {
        result = resolutionResult(true);
      } else {
        const terminalEvents = contract.terminalEvents(active, input, scope);
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
    // Fail open: terminal paths continue while ambiguous records stay visible.
  } finally {
    releaseWorkerBlockerLockSafely(lockPath, lockToken);
  }
  return result;
}
