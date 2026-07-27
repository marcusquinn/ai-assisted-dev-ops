// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  cleanWorkerBlockerIssueNumber,
  normalizeWorkerBlockerRepoSlug,
  normalizeWorkerBlockerRequestId,
  normalizeWorkerBlockerSessionKey,
} from "./worker-blocker-log.mjs";
import {
  activeWorkerBlockerEventsMatching,
  reconcileWorkerBlockers,
} from "./worker-blocker-reconcile-common.mjs";

function workerBlockerSessionScope(input, options) {
  const issueNumber = cleanWorkerBlockerIssueNumber(input.issue_number);
  const repoSlug = normalizeWorkerBlockerRepoSlug(input.repo_slug, options);
  const sessionKey = normalizeWorkerBlockerSessionKey(input.session_key, options);
  const requestId = normalizeWorkerBlockerRequestId(input.request_id, options);
  if (!repoSlug.includes("/") || !sessionKey) throw new Error("Invalid worker blocker session scope");
  return { issueNumber, repoSlug, sessionKey, requestId };
}

function sessionEventMatchesScope(event, scope) {
  const eventRepo = String(event.repo_slug || "").toLowerCase();
  const eventIssue = cleanWorkerBlockerIssueNumber(event.issue_number);
  const eventSession = typeof event.session_key === "string" ? event.session_key : "";
  const eventRequest = event.request_id === null || event.request_id === undefined
    ? ""
    : String(event.request_id);
  return eventRepo === scope.repoSlug
    && eventIssue === scope.issueNumber
    && eventSession === scope.sessionKey
    && (!scope.requestId || eventRequest === scope.requestId);
}

function activeWorkerBlockerSessionEvents(logPath, scope) {
  return activeWorkerBlockerEventsMatching(
    logPath,
    (event) => sessionEventMatchesScope(event, scope),
  );
}

function terminalSessionWorkerBlockerEvents(active, input) {
  return active.map((event) => ({
    event: input.event || "session_terminal_reconciled",
    status: input.status || "resolved",
    reason: input.reason || "session_terminal",
    blocking: false,
    source: input.source || "worker-blocker-log",
    issue_number: event.issue_number ?? null,
    repo_slug: event.repo_slug || "",
    session_key: event.session_key || "",
    request_id: event.request_id ?? "",
    permission: event.permission || "",
    tool: event.tool || "",
    risk_level: event.risk_level || "",
    grantable: typeof event.grantable === "boolean" ? event.grantable : null,
    detail: input.detail || "",
  }));
}

const SESSION_RECONCILIATION_CONTRACT = {
  resolveScope: workerBlockerSessionScope,
  activeEvents: activeWorkerBlockerSessionEvents,
  terminalEvents: terminalSessionWorkerBlockerEvents,
};

export function resolveWorkerBlockersForSession(input = {}, options = {}) {
  return reconcileWorkerBlockers(input, options, SESSION_RECONCILIATION_CONTRACT);
}
