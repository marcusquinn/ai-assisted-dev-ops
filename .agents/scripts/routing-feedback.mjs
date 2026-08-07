#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Provider-neutral routing outcome analysis shared by plugins and shell flows. */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const TIER_ORDER = ["simple", "standard", "thinking"];
const SUCCESS_RESULTS = new Set([
  "complete", "completed", "full_loop_complete", "merged", "post_merge_cleanup_deferred",
  "post_pr_handoff", "success", "succeeded",
]);

function integer(value, fallback = 0) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function number(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function truthy(value) {
  return value === true || value === 1 || value === "1" || value === "true";
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
  return truthy(firstValue(record, "routing_escalated", "routingEscalated", "escalated"));
}

function normalizedModel(record) {
  const fullModel = firstValue(record, "model", "routed_model", "routedModel");
  if (fullModel) return String(fullModel);
  const provider = firstValue(record, "provider_id", "providerID", "provider");
  const model = firstValue(record, "model_id", "modelID");
  return provider && model ? `${provider}/${model}` : String(model || "");
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

function requestFailed(record) {
  return Boolean(firstValue(record, "error_type", "errorType", "error_message", "errorMessage"));
}

function attemptFailed(record) {
  const result = String(firstValue(record, "result", "outcome")).toLowerCase();
  if (result) return !SUCCESS_RESULTS.has(result);
  return integer(firstValue(record, "exit_code", "exitCode"), 0) !== 0;
}

function lowerTier(tier) {
  const index = TIER_ORDER.indexOf(tier);
  return index > 0 ? TIER_ORDER[index - 1] : "";
}

function buildRecommendations(summary) {
  const recommendations = [];
  const finalTier = summary.tierPath[summary.tierPath.length - 1] || summary.dominantTier;

  if (summary.escalationCount > 0 && finalTier) {
    if (summary.terminalAttemptSucceeded && summary.requestErrorCount === 0) {
      recommendations.push(
        `For similar verified workloads, consider starting at \`${finalTier}\`; this sample needed capability escalation to finish.`,
      );
    } else {
      recommendations.push(
        `Keep automatic capability escalation enabled; this sample reached \`${finalTier}\` and still recorded failures.`,
      );
    }
  }

  if (summary.candidateFallbackCount >= 2) {
    recommendations.push(
      `Review same-tier candidate health and ordering; ${summary.candidateFallbackCount} routed attempts used non-primary candidates.`,
    );
  } else if (
    summary.attemptCount >= 3 &&
    summary.failedAttemptCount / summary.attemptCount >= 0.5 &&
    summary.escalationCount === 0
  ) {
    recommendations.push(
      "Provider/runtime failures dominated retries; keep the workload tier and review candidate health before raising capability.",
    );
  }

  if (
    summary.distinctSessionCount >= 3 &&
    summary.requestCount >= 6 &&
    summary.requestErrorCount === 0 &&
    summary.failedAttemptCount === 0 &&
    summary.escalationCount === 0 &&
    summary.tiersUsed.length === 1
  ) {
    const trialTier = lowerTier(summary.tiersUsed[0]);
    if (trialTier) {
      recommendations.push(
        `Trial \`${trialTier}\` on similar low-risk work; ${summary.distinctSessionCount} sessions completed without escalation, then compare verification outcomes.`,
      );
    }
  }

  if (recommendations.length === 0) {
    recommendations.push("No routing change is recommended from this sample.");
  }
  return recommendations;
}

/**
 * Summarize persisted request and attempt records without provider assumptions.
 *
 * @param {{ requests?: object[], attempts?: object[] }} input
 * @returns {object}
 */
export function summarizeRoutingFeedback({ requests = [], attempts = [] } = {}) {
  const routedRequests = requests.filter((record) => normalizedTier(record));
  const routedAttempts = attempts.filter((record) => normalizedTier(record));
  const routeRecords = routedAttempts.length > 0 ? routedAttempts : routedRequests;
  const counts = tierCounts(routeRecords);
  const tiersUsed = TIER_ORDER.filter((tier) => counts[tier] > 0);
  const dominantTier = tiersUsed.reduce(
    (best, tier) => (!best || counts[tier] > counts[best] ? tier : best),
    "",
  );
  const path = routePath(routeRecords);
  const reasons = routeRecords.map(normalizedReason);
  const explicitEscalations = reasons.filter((reason) => reason === "capability_escalation").length;
  const escalationCount = explicitEscalations || (routeRecords.some(normalizedEscalated) ? 1 : 0);
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

  const models = [...new Set([...routedRequests, ...routedAttempts].map(normalizedModel).filter(Boolean))];
  const summary = {
    hasData: routeRecords.length > 0,
    requestCount: routedRequests.length,
    attemptCount: routedAttempts.length,
    routeEventCount: routeRecords.length,
    distinctSessionCount: sessions.size,
    tiers: counts,
    tiersUsed,
    tierPath: path,
    dominantTier,
    models,
    candidateFallbackCount: routeRecords.filter((record) => normalizedCandidateIndex(record) > 0).length,
    retryCount: routeRecords.filter((record) => normalizedAttempt(record) > 1).length,
    escalationCount,
    requestErrorCount: routedRequests.filter(requestFailed).length,
    failedAttemptCount: routedAttempts.filter(attemptFailed).length,
    terminalAttemptSucceeded: routedAttempts.length === 0
      ? routedRequests.length > 0 && routedRequests.every((record) => !requestFailed(record))
      : !attemptFailed(routedAttempts[routedAttempts.length - 1]),
    tokensTotal: routedRequests.reduce(
      (total, record) => total + integer(firstValue(record, "tokens_total", "tokensTotal"), 0),
      0,
    ),
    costTotal: routedRequests.reduce(
      (total, record) => total + number(firstValue(record, "cost", "cost_total", "costTotal"), 0),
      0,
    ),
  };
  summary.recommendations = buildRecommendations(summary);
  return summary;
}

function plural(count, singular, pluralValue = `${singular}s`) {
  return `${count} ${count === 1 ? singular : pluralValue}`;
}

function routeLabel(summary) {
  return (summary.tierPath.length > 0 ? summary.tierPath : summary.tiersUsed)
    .map((tier) => `\`${tier}\``)
    .join(" → ");
}

/** Format a bounded GitHub/routine body section. */
export function formatRoutingFeedbackMarkdown(summary, { headingLevel = 3 } = {}) {
  if (!summary?.hasData) return "";
  const counts = [];
  if (summary.attemptCount > 0) counts.push(plural(summary.attemptCount, "attempt"));
  if (summary.requestCount > 0) counts.push(plural(summary.requestCount, "LLM request"));
  counts.push(plural(summary.escalationCount, "capability escalation"));
  counts.push(plural(summary.candidateFallbackCount, "same-tier fallback"));

  const lines = [
    `${"#".repeat(Math.max(1, Math.min(6, headingLevel)))} Routing feedback`,
    "",
    `- Route: ${routeLabel(summary) || "unknown"}; ${counts.join(", ")}.`,
  ];
  if (summary.tokensTotal > 0 || summary.costTotal > 0) {
    lines.push(`- Usage: ${summary.tokensTotal.toLocaleString("en-US")} tokens; $${summary.costTotal.toFixed(4)} estimated cost.`);
  }
  for (const recommendation of summary.recommendations) {
    lines.push(`- Recommendation: ${recommendation}`);
  }
  return lines.join("\n");
}

/** Format a compact interactive completion toast. */
export function formatRoutingFeedbackToast(summary) {
  if (!summary?.hasData) return "";
  const sampleCount = summary.attemptCount || summary.requestCount;
  const sampleLabel = summary.attemptCount > 0 ? "attempts" : "requests";
  const usage = summary.costTotal > 0 ? `, $${summary.costTotal.toFixed(4)}` : "";
  return [
    `Route ${routeLabel(summary).replaceAll("`", "")}: ${sampleCount} ${sampleLabel}${usage}, ${summary.escalationCount} escalations.`,
    summary.recommendations[0],
  ].join(" ");
}

/** Stable duplicate-suppression key for completion surfaces. */
export function routingFeedbackFingerprint(summary) {
  if (!summary?.hasData) return "";
  return JSON.stringify([
    summary.requestCount,
    summary.attemptCount,
    summary.tierPath,
    summary.candidateFallbackCount,
    summary.escalationCount,
    summary.requestErrorCount,
    summary.failedAttemptCount,
    summary.tokensTotal,
  ]);
}

function parseArgs(argv) {
  const options = {
    db: process.env.AIDEVOPS_OBS_DB_OVERRIDE || join(homedir(), ".aidevops", ".agent-workspace", "observability", "llm-requests.db"),
    metricsFile: process.env.AIDEVOPS_HEADLESS_METRICS_FILE || join(homedir(), ".aidevops", "logs", "headless-runtime-metrics.jsonl"),
    format: "markdown",
    headingLevel: 3,
    session: "",
    sessionKey: "",
    repo: "",
    issue: "",
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === "--session") options.session = argv[++index] || "";
    else if (flag === "--session-key") options.sessionKey = argv[++index] || "";
    else if (flag === "--routine") options.sessionKey = `routine-${argv[++index] || ""}`;
    else if (flag === "--repo") options.repo = argv[++index] || "";
    else if (flag === "--issue") options.issue = argv[++index] || "";
    else if (flag === "--db") options.db = argv[++index] || "";
    else if (flag === "--metrics-file") options.metricsFile = argv[++index] || "";
    else if (flag === "--format") options.format = argv[++index] || "markdown";
    else if (flag === "--heading-level") options.headingLevel = integer(argv[++index], 3);
  }
  return options;
}

function loadMetrics(options) {
  if (!options.metricsFile || !existsSync(options.metricsFile)) return [];
  const records = [];
  for (const line of readFileSync(options.metricsFile, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      const record = JSON.parse(line);
      const recordSessionKey = String(firstValue(record, "session_key", "sessionKey"));
      const recordSessionID = String(firstValue(record, "session_id", "sessionID"));
      const issueMatches = options.issue && (
        String(firstValue(record, "issue_number", "issueNumber")) === String(options.issue) ||
        recordSessionKey === `issue-${options.issue}`
      );
      const repoMatches = !options.repo || String(firstValue(record, "repo_slug", "repoSlug")) === options.repo;
      const sessionMatches = options.sessionKey && (
        recordSessionKey === options.sessionKey || recordSessionID === options.sessionKey
      );
      const directSessionMatches = options.session && (
        recordSessionID === options.session || recordSessionKey === options.session
      );
      if ((issueMatches && repoMatches) || sessionMatches || directSessionMatches) records.push(record);
    } catch {
      // Ignore partial/corrupt JSONL records; telemetry analysis is fail-open.
    }
  }
  return records;
}

function sqlString(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function loadRequests(options, attempts) {
  if (!options.db || !existsSync(options.db)) return [];
  const sessionIDs = new Set();
  if (options.session) sessionIDs.add(options.session);
  for (const record of attempts) {
    const sessionID = firstValue(record, "session_id", "sessionID");
    if (sessionID) sessionIDs.add(String(sessionID));
  }
  if (sessionIDs.size === 0) return [];
  const values = [...sessionIDs].map(sqlString).join(",");
  const sql = `SELECT session_id, parent_session_id, provider_id, model_id, tokens_total, cost, error_type, finish_reason, variant, routing_tier, routing_candidate_index, routing_attempt, routing_reason, routing_escalated FROM llm_requests WHERE session_id IN (${values}) OR parent_session_id IN (${values}) ORDER BY id;`;
  try {
    const output = execFileSync("sqlite3", ["-readonly", "-json", options.db, sql], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 3000,
    }).trim();
    return output ? JSON.parse(output) : [];
  } catch {
    return [];
  }
}

export function runRoutingFeedbackCli(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const attempts = loadMetrics(options);
  const requests = loadRequests(options, attempts);
  const summary = summarizeRoutingFeedback({ requests, attempts });
  if (options.format === "json") return JSON.stringify(summary);
  if (options.format === "toast") return formatRoutingFeedbackToast(summary);
  return formatRoutingFeedbackMarkdown(summary, { headingLevel: options.headingLevel });
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === resolve(fileURLToPath(import.meta.url))) {
  const output = runRoutingFeedbackCli();
  if (output) process.stdout.write(`${output}\n`);
}
