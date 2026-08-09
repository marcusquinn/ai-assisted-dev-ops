// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const TIER_ORDER = ["simple", "standard", "thinking"];
const SUCCESS_RESULTS = new Set([
  "complete", "completed", "full_loop_complete", "merged", "post_merge_cleanup_deferred",
  "post_pr_handoff", "success", "succeeded",
]);
const TRUTHY_VALUES = new Set([true, 1, "1", "true"]);

function integer(value, fallback = 0) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function number(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function firstValue(record, ...keys) {
  for (const key of keys) {
    const value = record?.[key];
    if (value !== undefined && value !== null && value !== "") return value;
  }
  return "";
}

function normalizedTier(record) {
  const tier = String(firstValue(record, "routing_tier", "routingTier", "tier")).toLowerCase();
  return TIER_ORDER.includes(tier) ? tier : "";
}

function normalizedCandidateIndex(record) {
  return integer(firstValue(record, "routing_candidate_index", "routingCandidateIndex", "candidateIndex"), -1);
}

function normalizedAttempt(record) {
  return integer(firstValue(record, "routing_attempt", "routingAttempt", "attempt"), 1);
}

function normalizedReason(record) {
  return String(firstValue(record, "routing_reason", "routingReason", "reason")).toLowerCase();
}

function normalizedEscalated(record) {
  return TRUTHY_VALUES.has(firstValue(record, "routing_escalated", "routingEscalated", "escalated"));
}

function normalizedModel(record) {
  const fullModel = firstValue(record, "model", "routed_model", "routedModel");
  if (fullModel) return String(fullModel);
  const provider = firstValue(record, "provider_id", "providerID", "provider");
  const model = firstValue(record, "model_id", "modelID");
  return provider && model ? `${provider}/${model}` : String(model || "");
}

function normalizedAidevopsVersion(record) {
  return String(firstValue(record, "aidevops_version", "aidevopsVersion"));
}

function routeAttemptKey(record, index) {
  const session = firstValue(record, "session_key", "sessionKey", "session_id", "sessionID");
  const attempt = normalizedAttempt(record);
  return session ? `${session}:${attempt}` : `anonymous:${index}`;
}

function distinctRouteAttemptCount(records, predicate) {
  const attempts = new Set();
  records.forEach((record, index) => {
    if (predicate(record)) attempts.add(routeAttemptKey(record, index));
  });
  return attempts.size;
}

function routePath(records) {
  const path = [];
  for (const record of records) {
    const tier = normalizedTier(record);
    if (tier && path[path.length - 1] !== tier) path.push(tier);
  }
  return path;
}

function tierCounts(records) {
  const counts = Object.fromEntries(TIER_ORDER.map((tier) => [tier, 0]));
  for (const record of records) {
    const tier = normalizedTier(record);
    if (tier) counts[tier] += 1;
  }
  return counts;
}

function delegationCounts(records) {
  const children = new Map();
  for (const record of records) {
    const parentSessionID = firstValue(record, "parent_session_id", "parentSessionID");
    const childSessionID = firstValue(record, "session_id", "sessionID");
    const tier = normalizedTier(record);
    if (!parentSessionID || !childSessionID || !tier) continue;

    const parentChildren = children.get(String(parentSessionID)) || new Map();
    if (!parentChildren.has(String(childSessionID))) {
      parentChildren.set(String(childSessionID), tier);
    }
    children.set(String(parentSessionID), parentChildren);
  }

  const delegationTiers = Object.fromEntries(TIER_ORDER.map((tier) => [tier, 0]));
  let delegationCount = 0;
  for (const parentChildren of children.values()) {
    for (const tier of parentChildren.values()) {
      delegationCount += 1;
      delegationTiers[tier] += 1;
    }
  }
  return { delegationCount, delegationTiers };
}

function requestFailed(record) {
  return Boolean(firstValue(record, "error_type", "errorType", "error_message", "errorMessage"));
}

function attemptFailed(record) {
  const result = String(firstValue(record, "result", "outcome")).toLowerCase();
  if (result) return !SUCCESS_RESULTS.has(result);
  return integer(firstValue(record, "exit_code", "exitCode"), 0) !== 0;
}

function collectSessions(routedRequests, routedAttempts) {
  const attemptSessionKeys = new Map();
  for (const record of routedAttempts) {
    const sessionID = firstValue(record, "session_id", "sessionID");
    const sessionKey = firstValue(record, "session_key", "sessionKey");
    if (sessionID && sessionKey) attemptSessionKeys.set(String(sessionID), String(sessionKey));
  }

  const sessions = new Set();
  for (const record of routedRequests) {
    const directSession = firstValue(record, "session_id", "sessionID");
    const session = firstValue(record, "parent_session_id", "parentSessionID")
      || attemptSessionKeys.get(String(directSession || ""))
      || directSession;
    if (session) sessions.add(String(session));
  }
  for (const record of routedAttempts) {
    const session = firstValue(record, "session_key", "sessionKey", "session_id", "sessionID");
    if (session) sessions.add(String(session));
  }
  return sessions;
}

function terminalAttemptSucceeded(routedRequests, routedAttempts) {
  if (routedAttempts.length === 0) {
    return routedRequests.length > 0 && routedRequests.every((record) => !requestFailed(record));
  }
  return !attemptFailed(routedAttempts[routedAttempts.length - 1]);
}

/** Summarize persisted request and attempt records without provider assumptions. */
export function summarizeRoutingMetrics({ requests = [], attempts = [] } = {}) {
  const routedRequests = requests.filter((record) => normalizedTier(record));
  const routedAttempts = attempts.filter((record) => normalizedTier(record));
  const routeRecords = routedAttempts.length > 0 ? routedAttempts : routedRequests;
  const counts = tierCounts(routeRecords);
  const delegations = delegationCounts(routedRequests);
  const tiersUsed = TIER_ORDER.filter((tier) => counts[tier] > 0);
  const dominantTier = tiersUsed.reduce(
    (best, tier) => (!best || counts[tier] > counts[best] ? tier : best),
    "",
  );
  const escalationCount = distinctRouteAttemptCount(
    routeRecords,
    (record) => normalizedReason(record) === "capability_escalation"
      || normalizedEscalated(record),
  );
  const sessions = collectSessions(routedRequests, routedAttempts);
  const models = [...new Set([...routedRequests, ...routedAttempts].map(normalizedModel).filter(Boolean))];
  const aidevopsVersions = [...new Set(
    [...routedRequests, ...routedAttempts].map(normalizedAidevopsVersion).filter(Boolean),
  )];

  return {
    hasData: routeRecords.length > 0,
    requestCount: routedRequests.length,
    attemptCount: routedAttempts.length,
    routeEventCount: routeRecords.length,
    distinctSessionCount: sessions.size,
    tiers: counts,
    ...delegations,
    tiersUsed,
    tierPath: routePath(routeRecords),
    dominantTier,
    models,
    aidevopsVersions,
    candidateFallbackCount: routeRecords.filter((record) => normalizedCandidateIndex(record) > 0).length,
    retryCount: distinctRouteAttemptCount(
      routeRecords,
      (record) => normalizedAttempt(record) > 1,
    ),
    escalationCount,
    requestErrorCount: routedRequests.filter(requestFailed).length,
    failedAttemptCount: routedAttempts.filter(attemptFailed).length,
    terminalAttemptSucceeded: terminalAttemptSucceeded(routedRequests, routedAttempts),
    tokensTotal: routedRequests.reduce(
      (total, record) => total + integer(firstValue(record, "tokens_total", "tokensTotal"), 0),
      0,
    ),
    costTotal: routedRequests.reduce(
      (total, record) => total + number(firstValue(record, "cost", "cost_total", "costTotal"), 0),
      0,
    ),
  };
}
