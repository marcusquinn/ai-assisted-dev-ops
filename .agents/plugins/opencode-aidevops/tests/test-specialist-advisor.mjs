// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { loadModelRouting, mergeModelRouting, nextRoutingTier, routingProfile } from "../model-routing.mjs";
import { registerAgents } from "../config-agent-profiles.mjs";
import { createSubagentEffortHooks, loadTierReasoningPolicies } from "../subagent-effort.mjs";
import { registerSpecialistAdvisor, validateSpecialistRequest, applyDailyDriverDefaults } from "../specialist-advisor.mjs";

const agentsDir = fileURLToPath(new URL("../../../", import.meta.url));
const table = fileURLToPath(new URL("../../../configs/model-routing-table.json", import.meta.url));
const routing = loadModelRouting([table]);
const envelope = JSON.stringify({
  objective: "Resolve a supplied ordering failure", scope: "Advice only; no tools",
  evidence: "Two concurrent updates overwrite each other; current check fails",
  escalation_reason: "Cheaper analysis did not resolve the supplied failing interleaving",
  output: "Propose an invariant and parent-verifiable check",
});

test("shipped routes keep Sol medium in charge and Astra outside automatic escalation", () => {
  assert.deepEqual(routingProfile(routing, "simple"), { tier: "simple", model: "openai/gpt-5.6-luna", variant: "low" });
  assert.deepEqual(routingProfile(routing, "standard"), { tier: "standard", model: "openai/gpt-5.6-terra", variant: "low" });
  assert.deepEqual(routingProfile(routing, "thinking"), { tier: "thinking", model: "openai/gpt-5.6-sol", variant: "medium" });
  assert.equal(nextRoutingTier(routing, "thinking"), "");
  assert.deepEqual(routing.specialistAdvisor, { model: "openai/gpt-6-astra", variant: "low" });
  assert.equal(mergeModelRouting(routing, { specialist_advisor: null }).specialistAdvisor, null);
  assert.equal(mergeModelRouting(routing, { specialist_advisor: { model: "invalid", variant: "low" } }).specialistAdvisor, null);
  assert.deepEqual(mergeModelRouting(routing, { tiers: {} }).specialistAdvisor, routing.specialistAdvisor);
});

test("registration supplies canonical tool-free adviser and defaults without replacing user pins", () => {
  const state = { tiers: new Map(), pinned: new Set() };
  const config = { agent: { "Build+": { mode: "primary" } } };
  registerAgents(config, agentsDir, routing, state);
  assert.equal(config.model, "openai/gpt-5.6-sol");
  assert.equal(config.agent["Build+"].variant, "medium");
  const advisor = config.agent["specialist-advisor"];
  assert.equal(advisor.model, "openai/gpt-6-astra");
  assert.equal(advisor.variant, "low");
  assert.deepEqual(advisor.tools, { "*": false });
  assert.deepEqual(advisor.permission, { "*": "deny" });
  assert.match(advisor.prompt, /no tools, network, credentials/);
  assert.ok(state.pinned.has("specialist-advisor"));
  assert.equal(registerSpecialistAdvisor(config, agentsDir, routing, state), 0);
  const custom = { model: "other/model", agent: {
    "Build+": { mode: "primary", variant: "high" },
    "specialist-advisor": { disable: true },
  } };
  const before = structuredClone(custom);
  applyDailyDriverDefaults(custom, routing);
  registerSpecialistAdvisor(custom, agentsDir, routing, state);
  assert.deepEqual(custom, before);
  assert.equal(registerSpecialistAdvisor({ agent: {} }, "/nonexistent", routing, state), 0);
});

test("specialist request requires evidence and an explicit escalation reason", () => {
  assert.doesNotThrow(() => validateSpecialistRequest(`[effort:thinking] ${envelope}`));
  assert.throws(() => validateSpecialistRequest("audit everything"), /JSON evidence envelope/);
  const invalid = JSON.parse(envelope);
  delete invalid.escalation_reason;
  assert.throws(() => validateSpecialistRequest(JSON.stringify(invalid)), /escalation_reason/);
  assert.throws(() => validateSpecialistRequest("null"), /requires objective/);
});

test("Sol parent can explicitly request Astra advice in interactive and headless hooks", async () => {
  for (const isHeadless of [false, true]) {
    const state = { tiers: new Map(), pinned: new Set() };
    const config = { agent: {} };
    registerAgents(config, agentsDir, routing, state);
    const client = { session: {
      get: async ({ path }) => ({ data: path.id === "child"
        ? { id: "child", parentID: "parent" }
        : { id: "parent", model: { providerID: "openai", modelID: "gpt-5.6-sol" }, variant: "medium" } }),
    } };
    const hooks = createSubagentEffortHooks(client, {
      modelRouting: routing, tierReasoning: loadTierReasoningPolicies([table]), agentRoutingState: state, isHeadless,
    });
    const output = {
      message: { sessionID: "child", agent: "specialist-advisor", variant: "low",
        model: { providerID: "openai", modelID: "gpt-6-astra" } },
      parts: [{ type: "text", text: envelope }],
    };
    await hooks.chatMessage({}, output);
    assert.equal(output.message.model.modelID, "gpt-6-astra");
    const params = { options: {} };
    await hooks.chatParams({ message: output.message, provider: { id: "openai" }, model: { id: "gpt-6-astra" } }, params);
    assert.equal(params.options.reasoningEffort, "low");
    output.parts[0].text = "Use Astra for no stated reason";
    await assert.rejects(hooks.chatMessage({}, output), /JSON evidence envelope/);
  }
});
