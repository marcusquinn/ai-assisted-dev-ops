// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { applyAgentMcpTools } from "../agent-mcp-tools.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { createMcpActivationTool } from "../mcp-activation-tool.mjs";
import { getOnDemandMcpAgents, registerMcpServers } from "../mcp-registry.mjs";

test("Blender registers disabled without executing or installing anything", () => {
  const config = { mcp: {}, tools: {} };
  registerMcpServers(config);
  assert.deepEqual(config.mcp["blender-lab"], {
    type: "local",
    command: ["python3", "-I", join(homedir(), ".aidevops", "agents", "scripts", "blender-lab-mcp-launcher.py")],
    enabled: false,
  });
  assert.equal(config.tools["blender-lab_*"], false);
  config.mcp["blender-lab"].enabled = true;
  registerMcpServers(config);
  assert.equal(config.mcp["blender-lab"].enabled, false);
});

test("only the bounded Blender agent gets Blender tools", () => {
  const config = { agent: { build: { tools: {} } } };
  registerOnDemandMcpAgents(config, fileURLToPath(new URL("../../..", import.meta.url)));
  applyAgentMcpTools(config);
  assert.equal(config.agent.blender.tools["blender-lab_*"], true);
  assert.equal(config.agent.blender.tools.aidevops_mcp, true);
  assert.equal(config.agent.build.tools["blender-lab_*"], undefined);
  assert.match(config.agent.blender.prompt, /never set the launcher consent flags yourself/);
  assert.match(config.agent.blender.prompt, /prepare/);
  assert.equal(config.tools.aidevops_mcp, false);
});

test("Blender is allowlisted for explicit connect and disconnect", async () => {
  const calls = [];
  const schema = { describe() { return this; } };
  const activation = createMcpActivationTool((definition) => definition, {
    enum() { return schema; },
  }, {
    allowedNames: getOnDemandMcpAgents().map((entry) => entry.name),
    client: {
      async connect(request) { calls.push(["connect", request.path.name]); return {}; },
      async disconnect(request) { calls.push(["disconnect", request.path.name]); return {}; },
      async status() { return { data: { "blender-lab": { status: "connected" } } }; },
    },
  });
  assert.match(await activation.execute({ action: "connect", name: "blender-lab" }), /Connected MCP/);
  assert.match(await activation.execute({ action: "disconnect", name: "blender-lab" }), /Disconnected MCP/);
  assert.deepEqual(calls, [["connect", "blender-lab"], ["disconnect", "blender-lab"]]);
});
