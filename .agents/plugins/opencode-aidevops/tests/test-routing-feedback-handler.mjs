// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import { createRoutingFeedbackHandler } from "../routing-feedback-handler.mjs";
import { summarizeRoutingFeedback } from "../../../scripts/routing-feedback.mjs";

function event(type, sessionID = "root") {
  return { event: { type, properties: { sessionID } } };
}

test("routing feedback handler emits changed idle summaries once", async () => {
  const toasts = [];
  let requests = [{ session_id: "child-a", parent_session_id: "root", routing_tier: "simple", tokens_total: 10 }];
  const handler = createRoutingFeedbackHandler({
    client: { tui: { showToast: async (toast) => toasts.push(toast) } },
    isHeadless: () => false,
    getFeedback: () => summarizeRoutingFeedback({ requests }),
  });

  await handler(event("message.updated"));
  await handler(event("session.idle"));
  await handler(event("session.idle"));
  requests = [...requests, { session_id: "child-b", parent_session_id: "root", routing_tier: "standard", tokens_total: 10 }];
  await handler(event("session.idle"));

  assert.equal(toasts.length, 2);
  assert.equal(toasts[0].body.title, "Routing feedback");
  assert.match(toasts[0].body.message, /1 delegated child \(1 simple\)/);
  assert.match(toasts[1].body.message, /2 delegated children \(1 simple, 1 standard\)/);
});

test("routing feedback handler stays silent headlessly and without routed data", async () => {
  const toasts = [];
  const client = { tui: { showToast: async (toast) => toasts.push(toast) } };
  const empty = summarizeRoutingFeedback();
  const interactive = createRoutingFeedbackHandler({ client, isHeadless: () => false, getFeedback: () => empty });
  const headless = createRoutingFeedbackHandler({
    client,
    isHeadless: () => true,
    getFeedback: () => summarizeRoutingFeedback({ requests: [{ routing_tier: "simple" }] }),
  });

  await interactive(event("session.idle"));
  await headless(event("session.idle"));
  assert.equal(toasts.length, 0);
});
