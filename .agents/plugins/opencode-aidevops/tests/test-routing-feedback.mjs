// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  formatRoutingFeedbackMarkdown,
  formatRoutingFeedbackToast,
  routingFeedbackFingerprint,
  runRoutingFeedbackCli,
  summarizeRoutingFeedback,
} from "../../../scripts/routing-feedback.mjs";

describe("routing feedback analysis", () => {
  test("summarizes capability escalation and joined usage", () => {
    const summary = summarizeRoutingFeedback({
      requests: [
        {
          session_id: "child-1",
          routing_tier: "simple",
          routing_attempt: 1,
          aidevops_version: "3.32.239",
          tokens_total: 120,
          cost: 0.01,
        },
        {
          session_id: "child-1",
          routing_tier: "standard",
          routing_attempt: 2,
          routing_reason: "capability_escalation",
          routing_escalated: 1,
          aidevops_version: "3.32.240",
          tokens_total: 80,
          cost: 0.02,
        },
      ],
    });

    assert.equal(summary.hasData, true);
    assert.deepEqual(summary.tierPath, ["simple", "standard"]);
    assert.equal(summary.escalationCount, 1);
    assert.equal(summary.tokensTotal, 200);
    assert.equal(summary.costTotal, 0.03);
    assert.deepEqual(summary.aidevopsVersions, ["3.32.239", "3.32.240"]);
    assert.match(summary.recommendations[0], /starting at `standard`/);
    assert.match(formatRoutingFeedbackMarkdown(summary), /### Routing feedback/);
    assert.match(formatRoutingFeedbackToast(summary), /simple → standard/);
  });

  test("counts repeated conversation turns as one route attempt", () => {
    const requests = Array.from({ length: 18 }, () => ({
      session_id: "child-1",
      routing_tier: "simple",
      routing_attempt: 1,
    }));
    requests.push({
      session_id: "child-1",
      routing_tier: "standard",
      routing_attempt: 2,
      routing_reason: "capability_escalation",
      routing_escalated: 1,
    });

    const summary = summarizeRoutingFeedback({ requests });

    assert.equal(summary.routeEventCount, 19);
    assert.equal(summary.retryCount, 1);
    assert.equal(summary.escalationCount, 1);
  });

  test("recommends candidate review only after repeated fallback evidence", () => {
    const summary = summarizeRoutingFeedback({
      attempts: [
        { session_key: "issue-42", routing_tier: "standard", routing_candidate_index: 0, result: "failed" },
        { session_key: "issue-42", routing_tier: "standard", routing_candidate_index: 1, result: "failed" },
        { session_key: "issue-42", routing_tier: "standard", routing_candidate_index: 2, result: "complete" },
      ],
    });

    assert.equal(summary.candidateFallbackCount, 2);
    assert.equal(summary.failedAttemptCount, 2);
    assert.match(summary.recommendations[0], /candidate health and ordering/);
  });

  test("requires multiple clean sessions before suggesting a lower-tier trial", () => {
    const requests = ["a", "b", "c"].flatMap((sessionID) => [
      { session_id: sessionID, routing_tier: "standard", tokens_total: 10 },
      { session_id: sessionID, routing_tier: "standard", tokens_total: 10 },
    ]);
    const summary = summarizeRoutingFeedback({ requests });

    assert.equal(summary.distinctSessionCount, 3);
    assert.match(summary.recommendations[0], /Trial `simple`/);
  });

  test("counts sibling child requests as one parent work session", () => {
    const requests = ["child-a", "child-b", "child-c"].flatMap((sessionID) => [
      { session_id: sessionID, parent_session_id: "root", routing_tier: "standard" },
      { session_id: sessionID, parent_session_id: "root", routing_tier: "standard" },
    ]);
    const summary = summarizeRoutingFeedback({ requests });

    assert.equal(summary.distinctSessionCount, 1);
    assert.match(summary.recommendations[0], /No routing change/);
  });

  test("counts distinct delegated children by their first valid tier", () => {
    const summary = summarizeRoutingFeedback({
      requests: [
        { session_id: "child-a", parent_session_id: "root", routing_tier: "simple" },
        { session_id: "child-a", parent_session_id: "root", routing_tier: "standard", routing_escalated: 1 },
        { session_id: "child-b", parent_session_id: "root", routing_tier: "standard" },
        { session_id: "parentless", routing_tier: "thinking" },
        { parent_session_id: "root", routing_tier: "thinking" },
      ],
    });
    const firstChildOnly = summarizeRoutingFeedback({
      requests: [{ session_id: "child-a", parent_session_id: "root", routing_tier: "simple" }],
    });

    assert.equal(summary.delegationCount, 2);
    assert.deepEqual(summary.delegationTiers, { simple: 1, standard: 1, thinking: 0 });
    assert.match(formatRoutingFeedbackMarkdown(summary), /2 delegated children \(1 simple, 1 standard\)/);
    assert.match(formatRoutingFeedbackToast(summary), /2 delegated children \(1 simple, 1 standard\)/);
    assert.notEqual(routingFeedbackFingerprint(summary), routingFeedbackFingerprint(firstChildOnly));
  });

  test("joins persisted requests and headless attempts under one session key", () => {
    const summary = summarizeRoutingFeedback({
      requests: [{ session_id: "ses-a", routing_tier: "standard" }],
      attempts: [{
        session_id: "ses-a",
        session_key: "issue-42",
        routing_tier: "standard",
        result: "post_pr_handoff",
      }],
    });

    assert.equal(summary.distinctSessionCount, 1);
    assert.equal(summary.failedAttemptCount, 0);
    assert.equal(summary.terminalAttemptSucceeded, true);
  });

  test("CLI session selectors match concrete runtime session IDs", () => {
    const root = mkdtempSync(join(tmpdir(), "aidevops-routing-feedback-"));
    const metricsFile = join(root, "metrics.jsonl");
    try {
      writeFileSync(metricsFile, `${JSON.stringify({
        session_key: "issue-42",
        session_id: "ses-a",
        routing_tier: "standard",
        result: "success",
      })}\n`);
      const summary = JSON.parse(runRoutingFeedbackCli([
        "--session", "ses-a",
        "--metrics-file", metricsFile,
        "--db", join(root, "missing.db"),
        "--format", "json",
      ]));
      assert.equal(summary.attemptCount, 1);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("suppresses output and fingerprints when no routed evidence exists", () => {
    const summary = summarizeRoutingFeedback({ requests: [{ session_id: "root" }] });
    assert.equal(summary.hasData, false);
    assert.equal(formatRoutingFeedbackMarkdown(summary), "");
    assert.equal(formatRoutingFeedbackToast(summary), "");
    assert.equal(routingFeedbackFingerprint(summary), "");
  });
});
