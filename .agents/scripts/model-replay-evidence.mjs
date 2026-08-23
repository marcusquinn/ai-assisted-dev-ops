// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { combinedUsage, csvValues } from "./model-replay-usage.mjs";

function latestMetric(metricsPath, sessionKey, startedAt = 0, finishedAt = Date.now()) {
  if (!existsSync(metricsPath)) return {};
  const records = readFileSync(metricsPath, "utf8").split("\n").filter(Boolean)
    .map((line) => {
      try { return JSON.parse(line); } catch { return null; }
    })
    .filter(Boolean)
    .filter((record) => String(record.session_key || "") === sessionKey)
    .filter((record) => Number(record.ts || 0) >= Math.floor(startedAt / 1000) - 1)
    .filter((record) => Number(record.ts || 0) <= Math.ceil(finishedAt / 1000) + 1);
  return records.at(-1) || {};
}

function metricsPath(name, override) {
  return process.env[override] || join(homedir(), ".aidevops", "logs", name);
}

function effectiveEffort(observedVariants, requestedEffort) {
  if (observedVariants.length === 1) return observedVariants[0];
  if (observedVariants.length === 0 && requestedEffort === "default") return "default";
  return "unknown";
}

function metricMatchesSession(metric, sessionKey, expectedProvider) {
  const checks = [
    String(metric.session_key || "") === sessionKey,
    metric.role === "model-replay",
    metric.provider === expectedProvider,
  ];
  return checks.every(Boolean);
}

function resourceMatchesSession(resource, sessionKey) {
  const checks = [
    String(resource.session_key || "") === sessionKey,
    resource.role === "model-replay",
    Number.isInteger(Number(resource.sample_count)),
    Number(resource.sample_count) > 0,
  ];
  return checks.every(Boolean);
}

function completeCost(usage, requestCount) {
  const checks = [
    requestCount > 0,
    Number(usage.cost_count || 0) === requestCount,
    Number.isFinite(Number(usage.cost_usd)),
  ];
  return checks.every(Boolean) ? Number(usage.cost_usd) : null;
}

function replayMetrics({ runtimePaths, sessionKey, startedAt, finishedAt }) {
  const metric = latestMetric(
    runtimePaths.metrics
      || metricsPath("headless-runtime-metrics.jsonl", "AIDEVOPS_HEADLESS_METRICS_FILE"),
    sessionKey,
    startedAt,
    finishedAt,
  );
  const resource = latestMetric(
    runtimePaths.resources
      || metricsPath("resource-metrics.jsonl", "AIDEVOPS_RESOURCE_METRICS_FILE"),
    sessionKey,
    startedAt,
    finishedAt,
  );
  return { metric, resource };
}

function runtimeIdentity(metric, usage, cell, sessionKey) {
  const expectedProvider = cell.model.slice(0, cell.model.indexOf("/"));
  const metricObserved = metricMatchesSession(metric, sessionKey, expectedProvider);
  const routingTier = String(metric.routing_tier || "");
  const modelEvidence = [
    ...new Set([...csvValues(metric.observed_model), ...csvValues(usage.models)]),
  ];
  const observedVariants = [
    ...new Set([...csvValues(metric.observed_variant), ...csvValues(usage.variants)]),
  ];
  return {
    metricObserved,
    routingTier,
    tierMatched: metricObserved && routingTier === cell.candidate_tier,
    concreteModel: modelEvidence.length === 1 ? modelEvidence[0] : "unknown",
    observedEffort: effectiveEffort(observedVariants, cell.requested_effort),
  };
}

function requestEvidence(metric, usage, metricObserved) {
  const requestCount = Number(metric.observed_request_count || 0);
  const requestObserved = metricObserved && Number.isInteger(requestCount) && requestCount > 0;
  return {
    requestCount,
    requestObserved,
    completeUsage: requestObserved && Number(usage.request_count || 0) === requestCount,
  };
}

function observedDuration(metric, startedAt, finishedAt) {
  if (Number(metric.duration_ms) > 0) return Number(metric.duration_ms) / 1000;
  return (finishedAt - startedAt) / 1000;
}

export function runtimeEvidence({
  sessionKey,
  cell,
  startedAt,
  finishedAt,
  runtimeOutput,
  runtimePaths = {},
}) {
  const { metric, resource } = replayMetrics({
    runtimePaths,
    sessionKey,
    startedAt,
    finishedAt,
  });
  const usage = combinedUsage(metric, runtimeOutput);
  const identity = runtimeIdentity(metric, usage, cell, sessionKey);
  const requests = requestEvidence(metric, usage, identity.metricObserved);
  const resourceObserved = resourceMatchesSession(resource, sessionKey);
  const runtimeChecks = [
    identity.metricObserved,
    metric.result === "success",
    Number(metric.exit_code) === 0,
    identity.tierMatched,
    requests.requestObserved,
    resourceObserved,
  ];
  return {
    metric,
    usage,
    resource,
    concreteModel: identity.concreteModel,
    modelMatched: identity.metricObserved && identity.concreteModel === cell.model,
    routingTier: identity.routingTier,
    tierMatched: identity.tierMatched,
    runtimeSucceeded: runtimeChecks.every(Boolean),
    effectiveEffort: identity.observedEffort,
    effortSupported: identity.metricObserved && identity.observedEffort !== "unknown"
      && identity.observedEffort === cell.requested_effort,
    requestCount: requests.requestObserved ? requests.requestCount : 0,
    requestObserved: requests.requestObserved,
    resourceObserved,
    durationSeconds: observedDuration(metric, startedAt, finishedAt),
    tokensTotal: requests.completeUsage ? Number(usage.tokens_total || 0) : null,
    costUsd: requests.completeUsage ? completeCost(usage, requests.requestCount) : null,
  };
}

export function classifyFailure(run, grade, evidence) {
  const failures = [
    [run.timedOut, "timeout"],
    [!evidence.requestObserved, "provider_request_unverified"],
    [!evidence.resourceObserved, "resource_metric_unverified"],
    [!evidence.tierMatched, "routing_tier_unverified"],
    [!evidence.modelMatched, "model_identity_unverified"],
    [!evidence.effortSupported, "effort_not_honored"],
    [!grade.pass_to_pass_passed, "regression"],
    [!grade.fail_to_pass_passed, "target_not_solved"],
    [run.status !== 0, "runtime_error_after_functional_patch"],
    [!evidence.runtimeSucceeded, "runtime_metric_not_successful"],
  ];
  return failures.find(([failed]) => failed)?.[1] || "";
}
