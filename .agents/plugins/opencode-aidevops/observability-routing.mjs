// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { summarizeRoutingFeedback } from "../../scripts/routing-feedback.mjs";

const routingDecisions = new Map();
const sessionRoutingRecords = new Map();

function routingPopulation(msg, decision) {
  let population = "unknown";
  if (msg?.summary === true || msg?.mode === "compaction") population = "compaction";
  else if (process.env.AIDEVOPS_HEADLESS || process.env.AIDEVOPS_DISPATCH_TIER) population = "headless";
  else if (decision.parentSessionID) population = "interactive_child";
  else if (decision.population) population = decision.population;
  else if (decision.reason === "model_profile") population = "top_level_profile";
  return population;
}

/** Queue the routing choice that will be joined to the next completed response. */
export function recordRoutingDecision(sessionID, decision = {}) {
  if (!sessionID) return;
  const queue = routingDecisions.get(sessionID) || [];
  queue.push({
    parentSessionID: decision.parentSessionID || "",
    tier: decision.tier || "",
    model: decision.model || "",
    variant: decision.variant || "",
    candidateIndex: Number.isInteger(decision.candidateIndex) ? decision.candidateIndex : -1,
    attempt: Number.isInteger(decision.attempt) ? decision.attempt : 1,
    reason: decision.reason || "",
    escalated: decision.escalated ? 1 : 0,
    population: decision.population || "",
  });
  if (queue.length > 32) queue.splice(0, queue.length - 32);
  routingDecisions.set(sessionID, queue);
  if (routingDecisions.size > 1000) {
    for (const key of [...routingDecisions.keys()].slice(0, 500)) routingDecisions.delete(key);
  }
}

/** Return current-process routed request feedback for a root or child session. */
export function getRoutingFeedback(sessionID) {
  if (!sessionID) return summarizeRoutingFeedback();
  return summarizeRoutingFeedback({ requests: sessionRoutingRecords.get(sessionID) || [] });
}

export function rememberRoutingFeedback(
  msg,
  routing,
  cost,
  errorType,
  ...versions
) {
  const [aidevopsVersion = "", pricingVersion = ""] = versions;
  if (!routing.tier) return;
  const record = {
    session_id: msg.sessionID,
    parent_session_id: routing.parentSessionID || "",
    provider_id: msg.providerID || "",
    model_id: msg.modelID || routing.model || "",
    tokens_total: msg.tokens?.total || 0,
    cost,
    error_type: errorType || "",
    finish_reason: msg.finish || "",
    routing_tier: routing.tier,
    routing_candidate_index: routing.candidateIndex,
    routing_attempt: routing.attempt,
    routing_reason: routing.reason,
    routing_escalated: routing.escalated,
    routing_population: routing.population,
    aidevops_version: aidevopsVersion,
    pricing_version: pricingVersion,
  };
  const keys = new Set([msg.sessionID, routing.parentSessionID].filter(Boolean));
  for (const key of keys) {
    const records = sessionRoutingRecords.get(key) || [];
    records.push(record);
    if (records.length > 200) records.splice(0, records.length - 200);
    sessionRoutingRecords.set(key, records);
  }
  if (sessionRoutingRecords.size > 1000) {
    for (const key of [...sessionRoutingRecords.keys()].slice(0, 500)) sessionRoutingRecords.delete(key);
  }
}

export function consumeRoutingDecision(msg) {
  const queue = routingDecisions.get(msg.sessionID) || [];
  const decision = queue.shift();
  if (queue.length === 0) routingDecisions.delete(msg.sessionID);
  const envTier = process.env.AIDEVOPS_DISPATCH_TIER || "";
  const route = decision || {
    parentSessionID: "",
    tier: envTier,
    model: `${msg.providerID || ""}/${msg.modelID || ""}`,
    variant: msg.variant || "",
    candidateIndex: Number.parseInt(process.env.AIDEVOPS_ROUTING_CANDIDATE_INDEX || "-1", 10),
    attempt: Number.parseInt(process.env.AIDEVOPS_ROUTING_ATTEMPT || "1", 10),
    reason: process.env.AIDEVOPS_ROUTING_REASON || (envTier ? "headless_dispatch" : ""),
    escalated: process.env.AIDEVOPS_ROUTING_ESCALATED === "1" ? 1 : 0,
  };
  return { ...route, population: routingPopulation(msg, route) };
}
