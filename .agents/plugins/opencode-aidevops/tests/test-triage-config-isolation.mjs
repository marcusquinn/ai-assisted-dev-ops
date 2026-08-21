// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";

import { enforcePublicTriageIsolation } from "../config-hook.mjs";

test("public triage disables every built-in, custom, and MCP tool after config expansion", () => {
  const config = {
    agent: {
      "triage-review": {
        description: "restricted triage",
        mode: "subagent",
        tools: { aidevops: true, read: true },
        permission: "allow",
      },
      build: { tools: { bash: true } },
      arbitrary: { tools: { custom_tool: true } },
    },
    tools: { "*": true, aidevops: true, mcp_example: true },
    permission: "allow",
    mcp: { example: { type: "local", command: ["unsafe-command"] } },
    formatter: { example: { command: ["unsafe-formatter"] } },
    lsp: { example: { command: ["unsafe-lsp"] } },
    share: "auto",
    subagent_depth: 2,
  };

  assert.equal(enforcePublicTriageIsolation(config, "triage"), 1);
  assert.deepEqual(config.tools, { "*": false });
  assert.deepEqual(config.permission, { "*": "deny" });
  assert.deepEqual(config.mcp, {});
  assert.equal(config.formatter, false);
  assert.equal(config.lsp, false);
  assert.equal(config.share, "disabled");
  assert.equal(config.subagent_depth, 0);
  assert.equal(config.default_agent, "triage-review");
  assert.equal(config.agent["triage-review"].mode, "primary");
  assert.deepEqual(config.agent["triage-review"].tools, { "*": false });
  assert.deepEqual(config.agent["triage-review"].permission, { "*": "deny" });
  for (const name of ["build", "plan", "general", "explore", "arbitrary"]) {
    assert.deepEqual(config.agent[name], { disable: true }, `${name} retains an active profile`);
  }
});

test("non-triage sessions are not changed", () => {
  const config = { agent: {}, tools: { bash: true } };
  const original = structuredClone(config);
  assert.equal(enforcePublicTriageIsolation(config, "worker"), 0);
  assert.deepEqual(config, original);
});

test("focused research selects only the inference-only research profile", () => {
  const config = {
    agent: {
      "triage-review": { tools: { read: true } },
      "research-only": {
        description: "restricted research",
        mode: "subagent",
        tools: { read: true, webfetch: true },
        permission: { read: "allow", webfetch: "allow" },
      },
      arbitrary: { tools: { bash: true } },
    },
    tools: { "*": true },
    permission: "allow",
    mcp: { example: { type: "local", command: ["unsafe-command"] } },
    subagent_depth: 2,
  };

  assert.equal(enforcePublicTriageIsolation(config, "ai-research"), 1);
  assert.deepEqual(config.tools, { "*": false });
  assert.deepEqual(config.permission, { "*": "deny" });
  assert.deepEqual(config.mcp, {});
  assert.equal(config.subagent_depth, 0);
  assert.equal(config.default_agent, "research-only");
  assert.equal(config.agent["research-only"].mode, "primary");
  assert.deepEqual(config.agent["research-only"].tools, { "*": false });
  assert.deepEqual(config.agent["research-only"].permission, { "*": "deny" });
  for (const name of ["triage-review", "build", "plan", "general", "explore", "arbitrary"]) {
    assert.deepEqual(config.agent[name], { disable: true }, `${name} retains an active profile`);
  }
});

test("public triage fails closed when its trusted profile is unavailable", () => {
  assert.throws(
    () => enforcePublicTriageIsolation({ agent: {} }, "triage"),
    /Public triage agent profile is unavailable/,
  );
});

test("focused research fails closed when its trusted profile is unavailable", () => {
  assert.throws(
    () => enforcePublicTriageIsolation({ agent: {} }, "ai-research"),
    /Focused research agent profile is unavailable/,
  );
});
