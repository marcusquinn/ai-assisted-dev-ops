// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync } from "node:fs";

import {
  acquireWorkerBlockerLock as acquireLock,
} from "./worker-blocker-lock.mjs";
import {
  cleanWorkerBlockerIssueNumber,
  normalizeWorkerBlockerRepoSlug,
  resolveWorkerBlockerLogPath,
} from "./worker-blocker-log.mjs";
import {
  activeWorkerBlockerEventsMatching,
  reconcileWorkerBlockers,
  releaseWorkerBlockerLockSafely,
  safeWorkerBlockerLog,
} from "./worker-blocker-reconcile-common.mjs";

export { workerBlockerIdentity } from "./worker-blocker-reconcile-common.mjs";
export { resolveWorkerBlockersForSession } from "./worker-blocker-session-reconcile.mjs";

function activeWorkerBlockerEvents(logPath, repoSlug, issueNumber = null) {
  return activeWorkerBlockerEventsMatching(logPath, (event) => {
    const eventRepo = String(event.repo_slug || "").toLowerCase();
    const eventIssue = cleanWorkerBlockerIssueNumber(event.issue_number);
    return eventRepo === repoSlug && eventIssue !== null
      && (issueNumber === null || eventIssue === issueNumber);
  });
}

function workerBlockerScope(input, options) {
  const issueNumber = cleanWorkerBlockerIssueNumber(input.issue_number);
  const repoSlug = normalizeWorkerBlockerRepoSlug(input.repo_slug, options);
  if (issueNumber === null || !repoSlug.includes("/")) throw new Error("Invalid worker blocker scope");
  return { issueNumber, repoSlug };
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

function issueActiveEvents(logPath, scope) {
  return activeWorkerBlockerEvents(logPath, scope.repoSlug, scope.issueNumber);
}

function issueTerminalEvents(active, input, scope) {
  return terminalWorkerBlockerEvents(active, input, scope.issueNumber, scope.repoSlug);
}

const ISSUE_RECONCILIATION_CONTRACT = {
  resolveScope: workerBlockerScope,
  activeEvents: issueActiveEvents,
  terminalEvents: issueTerminalEvents,
};

export function resolveWorkerBlockersForIssue(input = {}, options = {}) {
  return reconcileWorkerBlockers(input, options, ISSUE_RECONCILIATION_CONTRACT);
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
    releaseWorkerBlockerLockSafely(lockPath, lockToken);
  }
  return result;
}
