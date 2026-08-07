#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/** Provider-neutral routing outcome analysis shared by plugins and shell flows. */

import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runRoutingFeedbackCommand } from "./routing-feedback-cli.mjs";
import { summarizeRoutingMetrics } from "./routing-feedback-summary.mjs";

const TIER_ORDER = ["simple", "standard", "thinking"];

function lowerTier(tier) {
  const index = TIER_ORDER.indexOf(tier);
  return index > 0 ? TIER_ORDER[index - 1] : "";
}

function providerFailuresDominated(summary) {
  return [
    summary.attemptCount >= 3,
    summary.failedAttemptCount / summary.attemptCount >= 0.5,
    summary.escalationCount === 0,
  ].every(Boolean);
}

function supportsLowerTierTrial(summary) {
  return [
    summary.distinctSessionCount >= 3,
    summary.requestCount >= 6,
    summary.requestErrorCount === 0,
    summary.failedAttemptCount === 0,
    summary.escalationCount === 0,
    summary.tiersUsed.length === 1,
  ].every(Boolean);
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
  } else if (providerFailuresDominated(summary)) {
    recommendations.push(
      "Provider/runtime failures dominated retries; keep the workload tier and review candidate health before raising capability.",
    );
  }

  if (supportsLowerTierTrial(summary)) {
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
  const summary = summarizeRoutingMetrics({ requests, attempts });
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

export function runRoutingFeedbackCli(argv = process.argv.slice(2)) {
  return runRoutingFeedbackCommand(argv, {
    summarizeRoutingFeedback,
    formatRoutingFeedbackMarkdown,
    formatRoutingFeedbackToast,
  });
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === resolve(fileURLToPath(import.meta.url))) {
  const output = runRoutingFeedbackCli();
  if (output) process.stdout.write(`${output}\n`);
}
