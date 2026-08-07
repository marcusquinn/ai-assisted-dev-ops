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
  assert.equal(resolveTierReasoning("standard", "custom", "model", {
    standard: { default: "medium" },
  }), "medium");
});

test("child reasoning never exceeds the parent variant", () => {
  assert.equal(clampReasoningVariant("xhigh", "high"), "high");
  assert.equal(clampReasoningVariant("medium", "xhigh"), "medium");
  assert.equal(clampReasoningVariant("low", "medium"), "low");
  assert.equal(clampReasoningVariant("high", "low"), "low");
  assert.equal(clampReasoningVariant("max", "max"), "max");
  assert.equal(clampReasoningVariant("max", "xhigh"), "xhigh");
  assert.equal(clampReasoningVariant("xhigh", "max"), "xhigh");
  assert.equal(clampReasoningVariant("provider-ultra", "high"), "provider-ultra");
});

test("explicit effort marker overrides agent fallback", () => {
  assert.equal(inferSubagentEffort("auditing", "[effort:simple] quick check"), "simple");
  assert.equal(inferSubagentEffort("auditing"), "thinking");
  assert.equal(inferSubagentEffort("explore"), "simple");
  assert.equal(inferSubagentEffort("general"), "standard");
});

test("interactive routing selects an authenticated same-tier fallback", async () => {
  const client = {
    provider: {
      list: async () => ({ data: {
        connected: ["anthropic"],
        all: [
          { id: "openai", models: { terra: { id: "terra" } } },
          { id: "anthropic", models: { sonnet: { id: "sonnet" } } },
        ],
      } }),
    },
    session: {
      get: async () => ({ data: { id: "child", parentID: "parent", agent: "general" } }),
    },
  };
  const modelRouting = {
    tiers: {
      simple: { models: [], reasoning: {} },
      standard: { models: ["openai/terra", "anthropic/sonnet"], reasoning: {} },
      thinking: { models: [], reasoning: {} },
    },
  };
  const hooks = createSubagentEffortHooks(client, {
    modelRouting,
    agentRoutingState: { tiers: new Map([["general", "standard"]]), pinned: new Set() },
  });
  const output = {
    message: {
      sessionID: "child",
      agent: "general",
      model: { providerID: "openai", modelID: "terra" },
    },
    parts: [{ type: "text", text: "implement the established plan" }],
  };

  await hooks.chatMessage({}, output);
  assert.deepEqual(output.message.model, { providerID: "anthropic", modelID: "sonnet" });
});

test("an explicit thinking marker changes the actual child request model", async () => {
  const client = {
    provider: {
      list: async () => ({ data: {
        connected: ["openai"],
        all: [{
          id: "openai",
          models: { terra: { id: "terra" }, sol: { id: "sol" } },
        }],
      } }),
    },
    session: {
      get: async () => ({ data: { id: "child", parentID: "parent", agent: "general" } }),
    },
  };
  const modelRouting = {
    tiers: {
      simple: { models: [], reasoning: {} },
      standard: { models: ["openai/terra"], reasoning: {} },
      thinking: { models: ["openai/sol"], reasoning: {} },
    },
  };
  const hooks = createSubagentEffortHooks(client, {
    modelRouting,
    agentRoutingState: { tiers: new Map([["general", "standard"]]), pinned: new Set() },
  });
  const output = {
    message: {
      sessionID: "child",
      agent: "general",
      model: { providerID: "openai", modelID: "terra" },
    },
    parts: [{ type: "text", text: "[effort:thinking] resolve the architecture" }],
  };

  await hooks.chatMessage({}, output);
  assert.deepEqual(output.message.model, { providerID: "openai", modelID: "sol" });
});

test("an explicitly disabled child tier fails closed", async () => {
  const client = {
    provider: { list: async () => ({ data: { connected: [], all: [] } }) },
    session: {
      get: async () => ({ data: { id: "child", parentID: "parent", agent: "explore" } }),
    },
  };
  const hooks = createSubagentEffortHooks(client, {
    modelRouting: {
      tiers: {
        simple: { models: [], reasoning: {} },
        standard: { models: ["openai/terra"], reasoning: {} },
        thinking: { models: ["openai/sol"], reasoning: {} },
      },
    },
    agentRoutingState: { tiers: new Map([["explore", "simple"]]), pinned: new Set() },
  });

  await assert.rejects(
    hooks.chatMessage({}, {
      message: { sessionID: "child", agent: "explore" },
      parts: [{ type: "text", text: "inspect this" }],
    }),
    /routing tier 'simple' is disabled/,
  );
});

test("a disabled tier fails closed before child-session metadata lookup", async () => {
  let providerListCalls = 0;
  const client = {
    provider: {
      list: async () => {
        providerListCalls += 1;
        return { data: { connected: [], all: [] } };
      },
    },
    session: {
      get: async () => {
        throw new Error("session metadata unavailable");
      },
    },
  };
  const hooks = createSubagentEffortHooks(client, {
    modelRouting: {
      tiers: {
        simple: { models: [], reasoning: {} },
        standard: { models: ["openai/terra"], reasoning: {} },
        thinking: { models: ["openai/sol"], reasoning: {} },
      },
    },
    agentRoutingState: { tiers: new Map([["explore", "simple"]]), pinned: new Set() },
  });

  await assert.rejects(
    hooks.chatMessage({}, {
      message: { sessionID: "child", agent: "explore" },
      parts: [{ type: "text", text: "inspect this" }],
    }),
    /routing tier 'simple' is disabled/,
  );
  assert.equal(providerListCalls, 0);
});

test("OpenAI child effort is task-appropriate and clamped to parent", async () => {
  const client = {
    session: {
      get: async ({ path }) => ({
        data: path.id === "child"
          ? { id: "child", parentID: "parent", agent: "auditing" }
          : { id: "parent", model: { providerID: "openai", id: "gpt-5.6-sol" } },
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
    model: { id: "gpt-5.6-sol", options: {} },
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
  assert.equal(output.options.reasoningEffort, "xhigh");
});

test("provider-specific variants are not clamped across different models", async () => {
  const client = {
    session: {
      get: async ({ path }) => ({
        data: path.id === "child"
          ? { id: "child", parentID: "parent", agent: "auditing" }
          : {
            id: "parent",
            model: { providerID: "openai", id: "gpt-5.6-luna" },
            variant: "low",
          },
      }),
      messages: async () => ({ data: [] }),
    },
  };
  const hooks = createSubagentEffortHooks(client, { tierReasoning: TIER_REASONING });
  const output = { options: {} };
  await hooks.chatParams({
    provider: { id: "openai" },
    model: { id: "gpt-5.6-sol" },
    message: { sessionID: "child", agent: "auditing" },
  }, output);

  assert.equal(output.options.reasoningEffort, "xhigh");
});

test("root requests matching routed profiles record telemetry without changing params", async () => {
  const decisions = [];
  const client = {
    session: {
      get: async () => ({ data: { id: "root" } }),
      messages: async () => ({ data: [] }),
    },
  };
  const modelRouting = {
    tiers: {
      simple: { models: ["openai/gpt-5.6-luna"], reasoning: { openai: "max" } },
      standard: { models: ["openai/gpt-5.6-terra"], reasoning: { openai: "high" } },
      thinking: { models: ["openai/gpt-5.6-sol"], reasoning: { openai: "medium" } },
    },
    escalationOrder: ["simple", "standard", "thinking"],
  };
  const hooks = createSubagentEffortHooks(client, {
    tierReasoning: Object.fromEntries(
      Object.entries(modelRouting.tiers).map(([tier, route]) => [tier, route.reasoning]),
    ),
    modelRouting,
    onRoutingDecision: async (sessionID, decision) => decisions.push({ sessionID, ...decision }),
  });
  const output = { options: {} };
  await hooks.chatParams({
    provider: { id: "openai" },
    model: { id: "gpt-5.6-terra" },
    message: { sessionID: "root" },
  }, output);

  assert.deepEqual(output.options, {});
  assert.deepEqual(decisions, [{
    sessionID: "root",
    tier: "standard",
    model: "openai/gpt-5.6-terra",
    variant: "high",
    candidateIndex: 0,
    attempt: 1,
    reason: "model_profile",
  }]);
});

test("headless dispatch metadata takes precedence over inferred root profiles", async () => {
  const decisions = [];
  const client = {
    session: {
      get: async () => ({ data: { id: "root" } }),
      messages: async () => ({ data: [] }),
    },
  };
  const modelRouting = {
    tiers: {
      simple: { models: [], reasoning: {} },
      standard: { models: ["openai/gpt-5.6-terra"], reasoning: { openai: "high" } },
      thinking: { models: [], reasoning: {} },
    },
    escalationOrder: ["simple", "standard", "thinking"],
  };
  const previousTier = process.env.AIDEVOPS_DISPATCH_TIER;
  process.env.AIDEVOPS_DISPATCH_TIER = "standard";
  try {
    const hooks = createSubagentEffortHooks(client, {
      tierReasoning: { standard: { openai: "high" } },
      modelRouting,
      onRoutingDecision: async (sessionID, decision) => decisions.push({ sessionID, ...decision }),
    });
    const output = { options: {} };
    await hooks.chatParams({
      provider: { id: "openai" },
      model: { id: "gpt-5.6-terra" },
      message: { sessionID: "root" },
    }, output);

    assert.deepEqual(output.options, {});
    assert.deepEqual(decisions, []);
  } finally {
    if (previousTier === undefined) delete process.env.AIDEVOPS_DISPATCH_TIER;
    else process.env.AIDEVOPS_DISPATCH_TIER = previousTier;
  }
});
