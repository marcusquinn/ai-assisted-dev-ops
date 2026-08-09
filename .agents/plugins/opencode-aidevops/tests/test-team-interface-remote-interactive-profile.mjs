// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

import {
  applyRemoteInteractiveAgentSelection,
  canonicalJson,
  conversationSystemBlock,
  createOverlayDocument,
  isRemoteInteractiveConversation,
  loadCanonicalAgentRoster,
  loadTeamInterfaceConversation,
  REMOTE_INTERACTIVE_PERMISSION_PROFILE,
} from "../team-interface-context.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../../..");
const agentsDirectory = path.join(repositoryRoot, ".agents");
const pluginEntryPath = path.join(agentsDirectory, "plugins/opencode-aidevops/index.mjs");

function contextFixture() {
  return {
    actor_ref: "actor:synthetic-owner",
    app_team_ref: "app-team:ai-devops",
    community_ref: "community:synthetic",
    conversation_ref: "conversation:synthetic",
    correlation_ref: "correlation:synthetic",
    provider_ref: "provider:buzz",
    trust_ref: "trust:buzz-owner-only",
  };
}

function createFixture() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-buzz-remote-")));
  const projectRoot = path.join(root, "project");
  const dataRoot = path.join(root, "data");
  const homeRoot = path.join(root, "home");
  fs.mkdirSync(projectRoot, {mode: 0o700});
  fs.mkdirSync(dataRoot, {mode: 0o700});
  fs.mkdirSync(homeRoot, {mode: 0o700});
  const roster = loadCanonicalAgentRoster(agentsDirectory);
  const agent = roster.agents.find(({agent_id: agentID}) => agentID === "agent.build-plus");
  assert.ok(agent, "canonical Build+ agent is unavailable");
  const overlay = createOverlayDocument({
    roster,
    agent,
    workloadTier: agent.workload_tier,
    context: contextFixture(),
    permissionProfile: REMOTE_INTERACTIVE_PERMISSION_PROFILE,
  });
  const overlayPath = path.join(root, "overlay.json");
  fs.writeFileSync(overlayPath, `${canonicalJson(overlay)}\n`, {mode: 0o600});
  const env = {
    AIDEVOPS_REMOTE_INTERFACE: "1",
    AIDEVOPS_OPENCODE_ISOLATED_DB: "1",
    AIDEVOPS_REMOTE_PROJECT_ROOT: projectRoot,
    AIDEVOPS_SESSION_ORIGIN: "interactive",
    AIDEVOPS_TEAM_INTERFACE_OVERLAY: overlayPath,
    HOME: homeRoot,
    XDG_DATA_HOME: dataRoot,
  };
  const conversation = loadTeamInterfaceConversation(env, agentsDirectory, {
    canonicalRoster: roster,
    pluginEntryPath,
    repositoryDir: projectRoot,
  });
  return {conversation, env, homeRoot, overlay, overlayPath, projectRoot, root};
}

test("remote interactive selection preserves full configured capabilities", () => {
  const fixture = createFixture();
  try {
    assert.equal(isRemoteInteractiveConversation(fixture.conversation), true);
    const config = {
      agent: {
        "Build+": {
          mode: "primary",
          permission: {"*": "allow"},
          tools: {bash: true, edit: true, task: true, write: true},
        },
        SEO: {mode: "primary", tools: {bash: true}},
      },
      default_agent: "SEO",
      mcp: {github: {enabled: true}},
      share: "manual",
      subagent_depth: 4,
      tools: {"*": true},
    };
    assert.equal(applyRemoteInteractiveAgentSelection(config, fixture.conversation), 1);
    assert.equal(config.default_agent, "Build+");
    assert.equal(config.share, "disabled");
    assert.deepEqual(config.agent["Build+"].tools, {
      bash: true,
      edit: true,
      task: true,
      write: true,
    });
    assert.deepEqual(config.agent["Build+"].permission, {"*": "allow"});
    assert.deepEqual(config.mcp, {github: {enabled: true}});
    assert.equal(config.subagent_depth, 4);
    assert.equal(config.agent.SEO.mode, "primary");
    assert.equal(config.agent["Build+"].prompt, fixture.conversation.sourceContent);

    const block = conversationSystemBlock(fixture.conversation);
    assert.match(block, /full remote interactive aidevops session/);
    assert.match(block, /normal tools, MCPs, subagents, model routing, observability, and compaction/);
    assert.match(block, /do not downgrade to advice-only behavior/i);
    assert.match(block, /Buzz credentials and direct publication authority are not available/);
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("remote interactive boundary rejects credential leakage and disabled compaction", () => {
  const fixture = createFixture();
  const load = (overrides) => loadTeamInterfaceConversation(
    {...fixture.env, ...overrides},
    agentsDirectory,
    {pluginEntryPath, repositoryDir: fixture.projectRoot},
  );
  try {
    assert.throws(() => load({BUZZ_PRIVATE_KEY: "fixture-secret"}), /control-plane environment crossed|forbidden/);
    assert.throws(() => load({OPENCODE_DISABLE_AUTOCOMPACT: "1"}), /forbidden in remote interactive mode/);
    assert.throws(() => load({AIDEVOPS_SESSION_ORIGIN: "worker"}), /trusted interactive Buzz origin/);
    assert.throws(
      () => load({AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME: "1"}),
      /runtime anchor is required/,
    );
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("remote interactive plugin keeps the normal full hook surface and compaction", () => {
  const fixture = createFixture();
  const childScript = [
    "const pluginModule = await import(process.argv[2]);",
    "const hooks = await pluginModule.AidevopsPlugin({directory: process.argv[1], client: {session: {}}});",
    "const config = {agent: {'Build+': {mode: 'primary', tools: {bash: true, edit: true, task: true, write: true}, permission: {'*': 'allow'}}}, mcp: {}, provider: {}};",
    "await hooks.config(config);",
    "process.stdout.write(JSON.stringify({",
    "  agent: config.default_agent,",
    "  compaction: typeof hooks['experimental.session.compacting'],",
    "  event: typeof hooks.event,",
    "  shell: typeof hooks['shell.env'],",
    "  task: config.agent['Build+'].tools.task,",
    "  write: config.agent['Build+'].tools.write,",
    "}));",
  ].join("\n");
  const cleanEnvironment = Object.fromEntries(
    Object.entries(process.env).filter(([name]) => !name.startsWith("BUZZ_")
      && !name.startsWith("AIDEVOPS_BUZZ_")
      && !["NOSTR_PRIVATE_KEY", "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_DIR", "OPENCODE_DISABLE_AUTOCOMPACT", "OPENCODE_DISABLE_DEFAULT_PLUGINS", "OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_MODEL", "OPENCODE_PURE"].includes(name)),
  );
  try {
    const result = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", childScript, fixture.projectRoot, pathToFileURL(pluginEntryPath).href],
      {
        cwd: fixture.projectRoot,
        encoding: "utf8",
        env: {...cleanEnvironment, ...fixture.env},
        timeout: 30000,
      },
    );
    assert.equal(result.status, 0, result.stderr);
    const evidence = JSON.parse(result.stdout);
    assert.equal(evidence.agent, "Build+");
    assert.equal(evidence.compaction, "function");
    assert.equal(evidence.event, "function");
    assert.equal(evidence.shell, "function");
    assert.equal(evidence.task, true);
    assert.equal(evidence.write, true);
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});
