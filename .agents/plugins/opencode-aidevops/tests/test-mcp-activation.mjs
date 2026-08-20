// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { createMcpActivationTool } from "../mcp-activation-tool.mjs";
import { registerMcpServers } from "../mcp-registry.mjs";

const TEST_DIR = fileURLToPath(new URL(".", import.meta.url));
const AGENTS_DIR = join(TEST_DIR, "../../..");
const schemaNode = { describe() { return this; } };
const z = { enum() { return schemaNode; } };
const tool = (definition) => definition;

test("registers only the explicit browser MCP activation profiles", () => {
  const config = {};
  const count = registerOnDemandMcpAgents(config, AGENTS_DIR);

  assert.equal(count, 2);
  assert.deepEqual(Object.keys(config.agent), ["playwriter", "playwright"]);
  assert.equal(config.tools.aidevops_mcp, false);
  assert.equal(config.agent.playwriter.mode, "subagent");
  assert.equal(config.agent.playwriter.tools.aidevops_mcp, true);
  assert.equal(config.agent.playwriter.tools["playwriter_*"], true);
  assert.equal(config.agent.playwriter.permission.aidevops_mcp, "allow");
  assert.equal(config.agent.playwriter.permission["playwriter_*"], "allow");
  assert.match(config.agent.playwriter.prompt, /connect.*playwriter/);
  assert.match(config.agent.playwriter.prompt, /no browser tab is approved/i);
  assert.match(config.agent.playwriter.prompt, /# Playwriter - Browser Extension MCP/);
  assert.equal(config.agent.playwright.mode, "subagent");
  assert.equal(config.agent.playwright.tools.aidevops_mcp, true);
  assert.equal(config.agent.playwright.tools["playwright_*"], true);
  assert.equal(config.agent.playwright.permission.aidevops_mcp, "allow");
  assert.equal(config.agent.playwright.permission["playwright_*"], "allow");
  assert.match(config.agent.playwright.prompt, /connect.*playwright/);
  assert.match(config.agent.playwright.prompt, /# Playwright MCP/);
});

test("migrates browser MCPs to disconnected and globally denied", () => {
  const config = {
    mcp: {
      playwriter: {
        type: "local",
        command: ["npx", "playwriter@latest"],
        enabled: true,
      },
      playwright: {
        type: "local",
        command: ["npx", "-y", "@playwright/mcp@latest"],
        enabled: true,
      },
    },
    tools: { "playwriter_*": true, "playwright_*": true },
  };

  registerMcpServers(config);

  assert.equal(config.mcp.playwriter.enabled, false);
  assert.equal(config.mcp.playwright.enabled, false);
  assert.equal(config.tools["playwriter_*"], false);
  assert.equal(config.tools["playwright_*"], false);
});

test("connects and disconnects only registry-approved MCP names", async () => {
  const calls = [];
  const client = {
    async connect(args) { calls.push(["connect", args]); },
    async disconnect(args) { calls.push(["disconnect", args]); },
  };
  const activation = createMcpActivationTool(tool, z, {
    client,
    directory: "/workspace",
    allowedNames: ["playwriter"],
  });

  assert.match(
    await activation.execute({ action: "connect", name: "unknown" }),
    /only registry-approved/,
  );
  assert.equal(calls.length, 0);
  assert.match(
    await activation.execute({ action: "connect", name: "playwriter" }),
    /Connected MCP playwriter/,
  );
  assert.match(
    await activation.execute({ action: "disconnect", name: "playwriter" }),
    /Disconnected MCP playwriter/,
  );
  assert.deepEqual(calls, [
    ["connect", { path: { name: "playwriter" }, query: { directory: "/workspace" } }],
    ["disconnect", { path: { name: "playwriter" }, query: { directory: "/workspace" } }],
  ]);
});

test("omits the optional SDK query when no directory is available", async () => {
  const calls = [];
  const activation = createMcpActivationTool(tool, z, {
    client: { async connect(args) { calls.push(args); } },
    allowedNames: ["playwright"],
  });

  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /Connected MCP playwright/,
  );
  assert.deepEqual(calls, [{ path: { name: "playwright" } }]);
});

test("waits until an asynchronously connecting MCP reports ready", async () => {
  const statuses = ["disabled", "connecting", "connected"];
  const calls = [];
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect(args) { calls.push(["connect", args]); },
      async status(args) {
        calls.push(["status", args]);
        return { data: { playwright: { status: statuses.shift() } } };
      },
    },
    directory: "/workspace",
    allowedNames: ["playwright"],
    pause: async () => {},
  });

  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /Connected MCP playwright/,
  );
  assert.deepEqual(calls, [
    ["connect", { path: { name: "playwright" }, query: { directory: "/workspace" } }],
    ["status", { query: { directory: "/workspace" } }],
    ["status", { query: { directory: "/workspace" } }],
    ["status", { query: { directory: "/workspace" } }],
  ]);
});

test("returns OpenCode MCP lifecycle failures to the agent", async () => {
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect() { return { error: { message: "connection unavailable" } }; },
    },
    allowedNames: ["playwriter"],
  });

  assert.equal(
    await activation.execute({ action: "connect", name: "playwriter" }),
    "Error: MCP connect failed for playwriter: connection unavailable",
  );
  assert.equal(
    await activation.execute({ action: "disconnect", name: "playwriter" }),
    "Error: OpenCode does not expose MCP disconnect in this runtime.",
  );
});
