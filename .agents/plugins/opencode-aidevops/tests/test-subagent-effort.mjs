// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { registerDelegatedDomainProfiles } from "../config-agent-profiles.mjs";
import { loadAgentIndex, loadDelegatedDomainKnowledge } from "../agent-loader.mjs";

import {
  clampReasoningVariant,
  createSubagentEffortHooks,
  inferSubagentEffort,
  normalizeEffortTier,
  resolveTierReasoning,
} from "../subagent-effort.mjs";
import {
  appendCapabilityEscalationContract,
  capabilityEscalationEvidence,
} from "../subagent-effort-escalation.mjs";
import { SubagentLifecycleTracker, eventSessionID } from "../subagent-lifecycle-tracker.mjs";

const TIER_REASONING = {
  simple: { openai: "low" },
  standard: { openai: "max" },
  thinking: { openai: "xhigh" },
};

test("missing and legacy indexes cannot recursively register leaf profiles", () => {
  assert.deepEqual(loadAgentIndex(".agents", () => ""), []);
  assert.deepEqual(loadAgentIndex(".agents", () =>
    "<!--TOON:subagents[1]{folder,purpose,key_files}:\ntools,tools,unexpected-leaf\n-->"), []);
  assert.deepEqual(loadAgentIndex(".agents", () =>
    "<!--TOON:agents[1]{name,file,purpose,model_tier}:\nSEO,seo.md,Search,standard\n-->"),
  [{ name: "SEO", description: "Search", modelTier: "standard" }]);
});

function domainFixture(t, variant = "low") {
  const root = mkdtempSync(join(process.env.AIDEVOPS_TEMP_DIR || tmpdir(), "domain-profile-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const source = readFileSync(new URL("../../../marketing-sales.md", import.meta.url), "utf8").trim();
  writeFileSync(join(root, "marketing-sales.md"), source);
  const config = { agent: { "Marketing-Sales": {
    mode: "primary", description: "Read ~/.aidevops/agents/marketing-sales.md", prompt: source,
  } } };
  const state = { tiers: new Map(), pinned: new Set() };
  assert.equal(registerDelegatedDomainProfiles(config, root, state), 2);
  const outcomes = [];
  const retries = [];
  const client = { session: {
    get: async ({ path }) => ({ data: path.id === "parent"
      ? { model: { providerID: "openai", modelID: "parent" }, variant }
      : { id: path.id, parentID: "parent" } }),
    messages: async () => ({ data: [] }),
    prompt: async (request) => { retries.push(request); return { data: {} }; },
  } };
  const hooks = createSubagentEffortHooks(client, {
    agentRoutingState: state, onSubagentOutcome: (value) => outcomes.push(value),
    modelRouting: { tiers: {} }, isHeadless: () => false,
  });
  const envelope = {
    task: "campaign-analysis", objective: "Compare supplied conversion rates", scope: "Advisory arithmetic only",
    source: "marketing-sales.md", decisions: "No publishing or causal claims",
    evidence: "A: 20/1000 conversions; B: 30/1000 conversions", output: "Rates, uncertainty, next action",
    tools: [], authority: "inference-only", effort: "standard",
  };
  const output = (name = "domain-focused", changes = {}) => ({
    message: { sessionID: "child", agent: name },
    parts: [{ type: "text", text: JSON.stringify({ ...envelope, ...changes }) }],
  });
  return { root, config, state, hooks, output, outcomes, retries };
}

test("focused and light domain captures deliver canonical knowledge with parent ceilings", async (t) => {
  const fixture = domainFixture(t);
  for (const name of ["domain-focused", "domain-light"]) {
    const output = fixture.output(name);
    await fixture.hooks.chatMessage({}, output);
    const capture = output.parts[0].text;
    assert.match(capture, /campaign-analysis/);
    assert.match(capture, /SHA256: [a-f0-9]{64}/);
    assert.match(capture, /20\/1000 conversions/);
    const expected = loadDelegatedDomainKnowledge(fixture.state.domainDelegation, "marketing-sales.md", name === "domain-light");
    assert.ok(capture.endsWith(expected.knowledge));
    assert.deepEqual(output.message.model, { providerID: "openai", modelID: "parent" });
    await fixture.hooks.chatMessage({}, output);
    assert.equal(output.parts[0].text, capture);
    const params = { options: { reasoning_effort: "max" } };
    await fixture.hooks.chatParams({ message: output.message, model: output.message.model }, params);
    assert.deepEqual(params.options, { reasoning_effort: "low", reasoningEffort: "low" });
    assert.deepEqual(fixture.config.agent[name].tools, { "*": false });
    assert.deepEqual(fixture.config.agent[name].permission, { "*": "deny" });
  }
  const full = loadDelegatedDomainKnowledge(fixture.state.domainDelegation, "marketing-sales.md");
  const light = loadDelegatedDomainKnowledge(fixture.state.domainDelegation, "marketing-sales.md", true);
  assert.ok(full.knowledge.length > light.knowledge.length);
  assert.equal(registerDelegatedDomainProfiles(fixture.config, fixture.root, fixture.state), 0);
  assert.equal(Object.keys(fixture.config.agent).length, 3);
});

test("domain registration preserves user profiles and isolates canonical source registries", (t) => {
  const fixture = domainFixture(t);
  const custom = { prompt: "User-owned", disable: true };
  fixture.config.agent["domain-light"] = custom;
  registerDelegatedDomainProfiles(fixture.config, fixture.root, fixture.state);
  assert.equal(fixture.config.agent["domain-light"], custom);
  assert.equal(fixture.state.domainDelegation.profiles.has("domain-light"), false);
  const other = { tiers: new Map(), pinned: new Set() };
  registerDelegatedDomainProfiles({ agent: {} }, fixture.root, other);
  assert.equal(other.domainDelegation.sources.size, 0);
  assert.equal(fixture.state.domainDelegation.sources.size, 1);
});

test("domain delegation rejects missing authority, unsafe paths, drift and unknown parent effort", async (t) => {
  const fixture = domainFixture(t);
  for (const changes of [{ tools: ["bash"] }, { authority: "publish" }, { effort: "thinking" },
    { objective: "" }, { source: "../marketing-sales.md" }, { source: "unknown.md" }]) {
    await assert.rejects(fixture.hooks.chatMessage({}, fixture.output("domain-focused", changes)));
  }
  writeFileSync(join(fixture.root, "marketing-sales.md"), "changed source");
  await assert.rejects(fixture.hooks.chatMessage({}, fixture.output()), /source changed/);
  const unknown = domainFixture(t, "");
  await assert.rejects(unknown.hooks.chatMessage({}, unknown.output()), /ceiling unavailable/);
});

test("cancelled domain children retain host ownership and never report acceptance", async (t) => {
  const fixture = domainFixture(t);
  await fixture.hooks.chatMessage({}, fixture.output());
  fixture.hooks.beforeTool({ tool: "task", callID: "call", sessionID: "parent" }, {});
  fixture.hooks.handleEvent({ event: { type: "session.created", properties: {
    info: { id: "child", parentID: "parent" },
  } } });
  await fixture.hooks.afterTool({ tool: "task", callID: "call", sessionID: "parent" }, {
    metadata: { sessionId: "child", status: "cancelled" }, output: "cancelled",
  });
  const outcome = fixture.outcomes.find((entry) => entry.stage === "host_outcome");
  assert.equal(outcome.parentSessionID, "parent");
  assert.equal(outcome.success, false);
  assert.equal(outcome.status, "cancelled");
});

test("domain policies enforce ceilings without agent metadata and never escalate", async (t) => {
  const fixture = domainFixture(t, "high");
  const output = fixture.output();
  await fixture.hooks.chatMessage({}, output);
  const params = { options: { reasoningEffort: "max" } };
  await fixture.hooks.chatParams({ message: { sessionID: "child" }, model: output.message.model }, params);
  assert.equal(params.options.reasoningEffort, "medium");
  await assert.rejects(fixture.hooks.chatParams({ message: output.message,
    model: { providerID: "other", modelID: "larger" } }, params), /model changed/);
  fixture.hooks.beforeTool({ tool: "task", callID: "call", sessionID: "parent" }, {});
  await fixture.hooks.afterTool({ tool: "task", callID: "call", sessionID: "parent" }, {
    metadata: { sessionId: "child" }, output: "BLOCKED: capability limit - insufficient reasoning",
  });
  assert.equal(fixture.retries.length, 0);
});

test("missing light section and shadowed primary prompts are unavailable", async (t) => {
  const fixture = domainFixture(t);
  const primary = fixture.config.agent["Marketing-Sales"];
  const source = "---\nmode: primary\n---\nCanonical source without a light section";
  writeFileSync(join(fixture.root, "marketing-sales.md"), source);
  primary.prompt = source;
  registerDelegatedDomainProfiles(fixture.config, fixture.root, fixture.state);
  await assert.rejects(fixture.hooks.chatMessage({}, fixture.output("domain-light")), /knowledge unavailable/);
  primary.prompt = "user override";
  registerDelegatedDomainProfiles(fixture.config, fixture.root, fixture.state);
  await assert.rejects(fixture.hooks.chatMessage({}, fixture.output()), /unverified/);
});

test("aggregate Task session metadata falls back without coercing child identity", () => {
  const lifecycle = new SubagentLifecycleTracker();
  lifecycle.beforeTask("aggregate-call", "parent");
  lifecycle.handleEvent({
    type: "session.created",
    properties: { info: { id: "child", parentID: "parent" } },
  });

  const identity = lifecycle.takeChildIdentity(
    { callID: "aggregate-call", sessionID: "parent" },
    { metadata: { sessionID: { aggregate: "child" } } },
  );

  assert.deepEqual(identity, {
    callID: "aggregate-call",
    childID: "child",
    reason: "lifecycle",
  });
  assert.equal(eventSessionID({ properties: { sessionID: ["child"] } }), "");
});

test("only one matching scalar Task child identity is accepted", () => {
  const lifecycle = new SubagentLifecycleTracker();
  lifecycle.beforeTask("scalar-call", "parent");
  assert.deepEqual(
    lifecycle.takeChildIdentity(
      { callID: "scalar-call", sessionID: "parent" },
      { metadata: { sessionId: "child", sessionID: "child", session_id: "child" } },
    ),
    { callID: "scalar-call", childID: "child", reason: "metadata" },
  );

  lifecycle.beforeTask("mismatch-call", "parent");
  lifecycle.handleEvent({
    type: "session.created",
    properties: { info: { id: "other-parent-child", parentID: "other-parent" } },
  });
  assert.deepEqual(
    lifecycle.takeChildIdentity(
      { callID: "mismatch-call", sessionID: "parent" },
      { metadata: { sessionId: "other-parent-child" } },
    ),
    { callID: "mismatch-call", childID: "", reason: "child_parent_mismatch" },
  );
});

test("native resumable task IDs win over lifecycle inference", () => {
  const lifecycle = new SubagentLifecycleTracker();
  lifecycle.beforeTask("native-call", "parent");
  lifecycle.handleEvent({
    type: "message.part.updated",
    properties: {
      part: {
        id: "native-call",
        type: "tool",
        tool: "task",
        state: { status: "running", metadata: { sessionId: "native-child" } },
      },
    },
  });
  lifecycle.handleEvent({
    type: "session.created",
    properties: { info: { id: "native-child", parentID: "parent" } },
  });
  lifecycle.handleEvent({
    type: "session.created",
    properties: { info: { id: "newer-inferred-child", parentID: "parent" } },
  });

  assert.deepEqual(
    lifecycle.takeChildIdentity(
      { callID: "native-call", sessionID: "parent" },
      undefined,
    ),
    { callID: "native-call", childID: "native-child", reason: "native_task_id" },
  );

  lifecycle.beforeTask("native-error-call", "parent");
  lifecycle.handleEvent({
    type: "message.part.updated",
    properties: {
      part: {
        id: "native-error-call",
        type: "tool",
        tool: "task",
        state: {
          status: "error",
          error: "Tool execution failed: Subagent failed (task_id: failed-child): Network connection lost",
        },
      },
    },
  });
  assert.deepEqual(
    lifecycle.takeChildIdentity(
      { callID: "native-error-call", sessionID: "parent" },
      undefined,
    ),
    { callID: "native-error-call", childID: "failed-child", reason: "native_task_id" },
  );

  lifecycle.beforeTask("native-conflict-call", "parent");
  for (const sessionId of ["first-child", "conflicting-child"]) {
    lifecycle.handleEvent({
      type: "message.part.updated",
      properties: {
        part: {
          id: "native-conflict-call",
          type: "tool",
          tool: "task",
          state: { status: "running", metadata: { sessionId } },
        },
      },
    });
  }
  assert.deepEqual(
    lifecycle.takeChildIdentity(
      { callID: "native-conflict-call", sessionID: "parent" },
      { metadata: { sessionId: "first-child" } },
    ),
    { callID: "native-conflict-call", childID: "", reason: "child_identity_conflict" },
  );

  lifecycle.beforeTask("same-output-conflict-call", "parent");
  assert.deepEqual(
    lifecycle.takeChildIdentity(
      { callID: "same-output-conflict-call", sessionID: "parent" },
      {
        metadata: { sessionId: "metadata-child" },
        output: '<task id="rendered-child" state="completed">\n<task_result>done</task_result>\n</task>',
      },
    ),
    { callID: "same-output-conflict-call", childID: "", reason: "child_identity_conflict" },
  );
});

test("aggregate Task metadata preserves host fields and records routing evidence", async () => {
  const hooks = createSubagentEffortHooks({ session: { prompt: async () => ({}) } }, {
    modelRouting: { tiers: {} },
    isHeadless: () => false,
  });
  hooks.beforeTool(
    { tool: "task", callID: "aggregate-evidence", sessionID: "parent" },
    { args: {} },
  );
  const output = {
    output: "Task result",
    metadata: { session_id: [], hostValue: { preserved: true } },
  };

  await hooks.afterTool(
    { tool: "task", callID: "aggregate-evidence", sessionID: "parent" },
    output,
  );

  assert.deepEqual(output.metadata.session_id, []);
  assert.deepEqual(output.metadata.hostValue, { preserved: true });
  assert.deepEqual(output.metadata.aidevopsRoutingIdentity, { reason: "child_identity_missing" });
});

test("headless task hooks record host lifecycle evidence without semantic claims", async () => {
  const evidence = [];
  const hooks = createSubagentEffortHooks({}, {
    isHeadless: () => true,
    onSubagentOutcome: (item) => evidence.push(item),
  });
  const input = { tool: "task", callID: "call-1", sessionID: "parent" };
  hooks.beforeTool(input, { args: {} });
  hooks.handleEvent({
    event: {
      type: "session.created",
      properties: { info: { id: "child", parentID: "parent" } },
    },
  });
  hooks.handleEvent({
    event: {
      type: "message.updated",
      properties: { info: { role: "assistant", sessionID: "child", finish: "stop" } },
    },
  });
  await hooks.afterTool(input, { output: "bounded result", metadata: { status: "completed" } });

  assert.equal(evidence.length, 2);
  assert.deepEqual(evidence[0], {
    stage: "dispatch_requested",
    callID: "call-1",
    parentSessionID: "parent",
    status: "requested",
  });
  assert.deepEqual(evidence[1], {
    stage: "host_outcome",
    callID: "call-1",
    parentSessionID: "parent",
    childSessionID: "child",
    childSessionObserved: true,
    identityReason: "lifecycle",
    terminalEvidence: "stop",
    outcomeCategory: "host_completed",
    status: "completed",
    success: true,
  });
  assert.equal(Object.hasOwn(evidence[1], "semanticAcceptance"), false);
});

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
  const previousDispatchTier = process.env.AIDEVOPS_DISPATCH_TIER;
  delete process.env.AIDEVOPS_DISPATCH_TIER;
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
  try {
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
      population: "top_level_profile",
    }]);
  } finally {
    if (previousDispatchTier === undefined) {
      delete process.env.AIDEVOPS_DISPATCH_TIER;
    } else {
      process.env.AIDEVOPS_DISPATCH_TIER = previousDispatchTier;
    }
  }
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

test("conversation turns keep one route attempt and capability escalation reuses the child", async () => {
  const decisions = [];
  const prompts = [];
  let hooks;
  const client = {
    provider: {
      list: async () => ({ data: {
        connected: ["openai"],
        all: [{
          id: "openai",
          models: {
            "gpt-5.6-luna": { id: "gpt-5.6-luna" },
            "gpt-5.6-terra": { id: "gpt-5.6-terra" },
            "gpt-5.6-sol": { id: "gpt-5.6-sol" },
          },
        }],
      } }),
    },
    session: {
      get: async ({ path }) => ({ data: path.id === "child"
        ? { id: "child", parentID: "parent", agent: "explore" }
        : {
          id: "parent",
          model: { providerID: "openai", modelID: "gpt-5.6-sol" },
          variant: "high",
        } }),
      messages: async () => ({ data: [] }),
      prompt: async (request) => {
        prompts.push(request);
        const promptOutput = {
          message: { sessionID: "child", agent: "explore" },
          parts: request.body.parts,
        };
        await hooks.chatMessage({}, promptOutput);
        assert.deepEqual(promptOutput.message.model, {
          providerID: "openai",
          modelID: "gpt-5.6-terra",
        });
        await hooks.chatParams({
          provider: { id: "openai" },
          model: { id: "gpt-5.6-terra" },
          message: { sessionID: "child", agent: "explore" },
        }, { options: {} });
        return { data: { parts: [{ type: "text", text: "verified standard-tier result" }] } };
      },
    },
  };
  const modelRouting = {
    tiers: {
      simple: { models: ["openai/gpt-5.6-luna"], reasoning: {} },
      standard: { models: ["openai/gpt-5.6-terra"], reasoning: {} },
      thinking: { models: ["openai/gpt-5.6-sol"], reasoning: {} },
    },
    escalationOrder: ["simple", "standard", "thinking"],
  };
  hooks = createSubagentEffortHooks(client, {
    modelRouting,
    agentRoutingState: { tiers: new Map([["explore", "simple"]]), pinned: new Set() },
    onRoutingDecision: async (sessionID, decision) => decisions.push({ sessionID, ...decision }),
    isHeadless: () => false,
  });

  const initialOutput = {
    message: { sessionID: "child", agent: "explore" },
    parts: [{
      id: "part-initial",
      sessionID: "child",
      messageID: "message-initial",
      type: "text",
      text: "Inspect this bounded implementation detail.",
    }],
  };
  await hooks.chatMessage({}, initialOutput);
  assert.equal(initialOutput.parts.length, 1);
  assert.deepEqual(
    {
      id: initialOutput.parts[0].id,
      sessionID: initialOutput.parts[0].sessionID,
      messageID: initialOutput.parts[0].messageID,
    },
    { id: "part-initial", sessionID: "child", messageID: "message-initial" },
  );
  assert.match(initialOutput.parts[0].text, /capability escalation contract/);
  for (let turn = 0; turn < 18; turn += 1) {
    await hooks.chatParams({
      provider: { id: "openai" },
      model: { id: "gpt-5.6-luna" },
      message: { sessionID: "child", agent: "explore" },
    }, { options: {} });
  }

  hooks.beforeTool(
    { tool: "task", callID: "call-1", sessionID: "parent" },
    { args: { description: "bounded inspection" } },
  );
  const taskOutput = {
    output: "BLOCKED: capability limit - the bounded cross-file inference remains unresolved",
    metadata: { sessionId: "child", status: "completed" },
  };
  await hooks.afterTool(
    { tool: "task", callID: "call-1", sessionID: "parent" },
    taskOutput,
  );

  assert.equal(prompts.length, 1);
  assert.equal(prompts[0].path.id, "child");
  assert.deepEqual(prompts[0].body.model, {
    providerID: "openai",
    modelID: "gpt-5.6-terra",
  });
  assert.equal(decisions.length, 19);
  assert.ok(decisions.slice(0, 18).every((decision) => decision.attempt === 1));
  assert.deepEqual(decisions.at(-1), {
    sessionID: "child",
    parentSessionID: "parent",
    tier: "standard",
    model: "openai/gpt-5.6-terra",
    variant: "",
    candidateIndex: 0,
    attempt: 2,
    reason: "capability_escalation",
    escalated: true,
    population: "interactive_child",
  });
  assert.match(taskOutput.output, /simple → standard/);
  assert.match(taskOutput.output, /verified standard-tier result/);
});

test("automatic escalation stops when the retried child attempts side effects", async () => {
  let hooks;
  let promptCalls = 0;
  const client = {
    provider: {
      list: async () => ({ data: {
        connected: ["openai"],
        all: [{
          id: "openai",
          models: {
            luna: { id: "luna" },
            terra: { id: "terra" },
            sol: { id: "sol" },
          },
        }],
      } }),
    },
    session: {
      get: async () => ({ data: { id: "child", parentID: "parent", agent: "explore" } }),
      prompt: async () => {
        promptCalls += 1;
        hooks.beforeTool(
          { tool: "apply_patch", callID: "write-1", sessionID: "child" },
          { args: {} },
        );
        return { data: { parts: [{
          type: "text",
          text: "BLOCKED: capability limit - deeper reasoning is still required",
        }] } };
      },
    },
  };
  hooks = createSubagentEffortHooks(client, {
    modelRouting: {
      tiers: {
        simple: { models: ["openai/luna"], reasoning: {} },
        standard: { models: ["openai/terra"], reasoning: {} },
        thinking: { models: ["openai/sol"], reasoning: {} },
      },
      escalationOrder: ["simple", "standard", "thinking"],
    },
    agentRoutingState: { tiers: new Map([["explore", "simple"]]), pinned: new Set() },
    isHeadless: () => false,
  });
  hooks.beforeTool(
    { tool: "task", callID: "call-side-effect", sessionID: "parent" },
    { args: {} },
  );
  await hooks.chatMessage({}, {
    message: { sessionID: "child", agent: "explore" },
    parts: [{ type: "text", text: "Inspect only." }],
  });
  const taskOutput = {
    output: "BLOCKED: capability limit - initial analysis is insufficient",
    metadata: { sessionId: "child", status: "completed" },
  };

  await hooks.afterTool(
    { tool: "task", callID: "call-side-effect", sessionID: "parent" },
    taskOutput,
  );

  assert.equal(promptCalls, 1);
  assert.match(taskOutput.output, /simple → standard/);
  assert.match(taskOutput.output, /attempted side effects/);
});

test("non-capability blockers and headless tasks never auto-escalate", async () => {
  assert.equal(
    capabilityEscalationEvidence("BLOCKED: capability limit - provider authentication is unavailable"),
    "",
  );
  assert.equal(
    capabilityEscalationEvidence("BLOCKED: capability limit - bounded inference exceeded this model"),
    "bounded inference exceeded this model",
  );

  let promptCalls = 0;
  const client = {
    provider: { list: async () => ({ data: { connected: ["openai"], all: [] } }) },
    session: {
      get: async () => ({ data: { id: "child", parentID: "parent", agent: "explore" } }),
      prompt: async () => { promptCalls += 1; },
    },
  };
  const hooks = createSubagentEffortHooks(client, {
    modelRouting: {
      tiers: {
        simple: { models: ["openai/luna"], reasoning: {} },
        standard: { models: ["openai/terra"], reasoning: {} },
        thinking: { models: [], reasoning: {} },
      },
      escalationOrder: ["simple", "standard", "thinking"],
    },
    agentRoutingState: { tiers: new Map([["explore", "simple"]]), pinned: new Set() },
    isHeadless: () => true,
  });
  hooks.beforeTool({ tool: "task", callID: "headless-call", sessionID: "parent" }, { args: {} });
  const taskOutput = {
    output: "BLOCKED: capability limit - bounded inference exceeded this model",
    metadata: { sessionId: "child", status: "completed" },
  };
  await hooks.afterTool(
    { tool: "task", callID: "headless-call", sessionID: "parent" },
    taskOutput,
  );

  assert.equal(promptCalls, 0);
  assert.equal(taskOutput.metadata.aidevopsRoutingEscalation, undefined);
});

test("capability contract preserves persisted part identity and fails open", () => {
  const completeOutput = {
    parts: [{
      id: "part-1",
      sessionID: "session-1",
      messageID: "message-1",
      type: "text",
      text: "Original prompt",
      synthetic: false,
    }],
  };

  appendCapabilityEscalationContract(completeOutput);
  appendCapabilityEscalationContract(completeOutput);

  assert.equal(completeOutput.parts.length, 1);
  assert.deepEqual(
    completeOutput.parts[0],
    {
      id: "part-1",
      sessionID: "session-1",
      messageID: "message-1",
      type: "text",
      text: completeOutput.parts[0].text,
      synthetic: false,
    },
  );
  assert.equal(
    completeOutput.parts[0].text.match(/\[AIDEvOps capability escalation contract\]/g)?.length,
    1,
  );
  assert.match(completeOutput.parts[0].text, /^Original prompt\n\n/);

  const incompleteOutput = { parts: [{ type: "text", text: "Incomplete host part" }] };
  appendCapabilityEscalationContract(incompleteOutput);
  assert.deepEqual(incompleteOutput, { parts: [{ type: "text", text: "Incomplete host part" }] });
});
