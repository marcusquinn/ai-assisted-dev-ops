// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";

import {
  clampReasoningVariant,
  createSubagentEffortHooks,
  inferSubagentEffort,
  normalizeEffortTier,
  resolveTierReasoning,
} from "../subagent-effort.mjs";

const TIER_REASONING = {
  simple: { openai: "low" },
  standard: { openai: "max" },
  thinking: { openai: "xhigh" },
};

test("only provider-neutral workload tiers are recognized", () => {
  assert.equal(normalizeEffortTier("simple"), "simple");
  assert.equal(normalizeEffortTier("standard"), "standard");
  assert.equal(normalizeEffortTier("thinking"), "thinking");
  assert.equal(normalizeEffortTier("unknown"), "standard");
});

test("routing policy chooses provider reasoning independently of tier names", () => {
  assert.equal(resolveTierReasoning("simple", "openai", "gpt-5.6-sol", TIER_REASONING), "low");
  assert.equal(resolveTierReasoning("standard", "openai", "gpt-5.6-sol", TIER_REASONING), "max");
  assert.equal(resolveTierReasoning("thinking", "openai", "gpt-5.6-sol", TIER_REASONING), "xhigh");
  assert.equal(resolveTierReasoning("thinking", "anthropic", "claude-opus-4-6", TIER_REASONING), "");
});

test("child reasoning never exceeds the parent variant", () => {
  assert.equal(clampReasoningVariant("xhigh", "high"), "high");
  assert.equal(clampReasoningVariant("medium", "xhigh"), "medium");
  assert.equal(clampReasoningVariant("low", "medium"), "low");
  assert.equal(clampReasoningVariant("high", "low"), "low");
  assert.equal(clampReasoningVariant("max", "max"), "max");
  assert.equal(clampReasoningVariant("max", "xhigh"), "xhigh");
  assert.equal(clampReasoningVariant("xhigh", "max"), "xhigh");
});

test("explicit effort marker overrides agent fallback", () => {
  assert.equal(inferSubagentEffort("auditing", "[effort:simple] quick check"), "simple");
  assert.equal(inferSubagentEffort("auditing"), "thinking");
  assert.equal(inferSubagentEffort("explore"), "simple");
  assert.equal(inferSubagentEffort("general"), "standard");
});

test("OpenAI child effort is task-appropriate and clamped to parent", async () => {
  const client = {
    session: {
      get: async ({ path }) => ({
        data: path.id === "child"
          ? { id: "child", parentID: "parent", agent: "auditing" }
          : { id: "parent" },
      }),
      messages: async () => ({
        data: [{ info: { role: "assistant", variant: "high" }, parts: [] }],
      }),
    },
  };
  const hooks = createSubagentEffortHooks(client, { tierReasoning: TIER_REASONING });
  await hooks.chatMessage({}, {
    message: { sessionID: "child", agent: "auditing" },
    parts: [{ type: "text", text: "[effort:thinking] audit this change" }],
  });

  const output = { temperature: 0, topP: 1, options: {} };
  await hooks.chatParams({
    provider: { id: "openai" },
    model: { options: {} },
    message: { sessionID: "child", agent: "auditing" },
  }, output);

  assert.equal(output.options.reasoningEffort, "high");
});

test("simple child stays below a thinking parent", async () => {
  const client = {
    session: {
      get: async ({ path }) => ({
        data: path.id === "child"
          ? { id: "child", parentID: "parent", agent: "explore" }
          : { id: "parent", model: { variant: "xhigh" } },
      }),
      messages: async () => ({ data: [] }),
    },
  };
  const hooks = createSubagentEffortHooks(client, { tierReasoning: TIER_REASONING });
  const output = { temperature: 0, topP: 1, options: {} };

  await hooks.chatParams({
    provider: { id: "openai" },
    model: { options: {} },
    message: { sessionID: "child", agent: "explore" },
  }, output);

  assert.equal(output.options.reasoningEffort, "low");
});

test("primary and non-OpenAI sessions remain unchanged", async () => {
  const client = {
    session: {
      get: async () => ({ data: { id: "primary" } }),
      messages: async () => ({ data: [] }),
    },
  };
  const hooks = createSubagentEffortHooks(client, { tierReasoning: TIER_REASONING });
  const primaryOutput = { options: {} };
  await hooks.chatParams({
    provider: { id: "openai" },
    message: { sessionID: "primary" },
  }, primaryOutput);
  assert.deepEqual(primaryOutput.options, {});

  const anthropicOutput = { options: {} };
  await hooks.chatParams({
    provider: { id: "anthropic" },
    message: { sessionID: "child" },
  }, anthropicOutput);
  assert.deepEqual(anthropicOutput.options, {});
});

test("missing parent variant preserves native inheritance", async () => {
  const client = {
    session: {
      get: async ({ path }) => ({
        data: path.id === "child"
          ? { id: "child", parentID: "parent", agent: "auditing" }
          : { id: "parent" },
      }),
      messages: async () => ({ data: [] }),
    },
  };
  const hooks = createSubagentEffortHooks(client, { tierReasoning: TIER_REASONING });
  const output = { options: {} };
  await hooks.chatParams({
    provider: { id: "openai" },
    model: { id: "gpt-5.6-sol", options: {} },
    message: { sessionID: "child", agent: "auditing" },
  }, output);
  assert.deepEqual(output.options, {});
});
