// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";

import {createConfigHook, enforceTeamInterfaceConversationIsolation} from "../config-hook.mjs";
import {loadTierReasoningPolicies, resolveTierReasoning} from "../subagent-effort.mjs";
import {
  appendConversationSystemContext,
  applyConversationRootVariant,
  canonicalDigest,
  canonicalJson,
  conversationConfigEvidence,
  conversationSystemBlock,
  createOverlayDocument,
  loadTeamInterfaceConversation,
} from "../team-interface-context.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../../..");
const routingTable = path.join(repositoryRoot, ".agents/configs/model-routing-table.json");
const tierReasoning = loadTierReasoningPolicies([routingTable]);

function sourceDigest(source) {
  return `sha256:${crypto.createHash("sha256").update(source).digest("hex")}`;
}

function contextFixture() {
  return {
    actor_ref: "actor:synthetic-owner",
    app_team_ref: "app-team:synthetic-team",
    community_ref: "community:synthetic-community",
    conversation_ref: "conversation:synthetic-thread",
    correlation_ref: "correlation:synthetic-correlation",
    provider_ref: "provider:synthetic-provider",
    trust_ref: "trust:synthetic-verified",
  };
}

function createFixture({
  agentID = "agent.synthetic",
  displayName = "Synthetic",
  filename = "synthetic.md",
  kind = "primary",
  workloadTier = "standard",
} = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-conversation-profile-"));
  const agentsDir = path.join(root, "agents");
  fs.mkdirSync(agentsDir);
  const source = `---\nname: synthetic\ndescription: Synthetic canonical agent\nmode: subagent\n---\n\n# Synthetic agent\n\nUse only the enforced tools.\n`;
  fs.writeFileSync(path.join(agentsDir, filename), source, {mode: 0o600});
  const agent = {
    agent_id: agentID,
    description: "Synthetic canonical agent",
    display_name: displayName,
    kind,
    source_digest: sourceDigest(source),
    source_ref: `agents:${filename}`,
    workload_tier: workloadTier,
  };
  const unsignedRoster = {
    agents: [
      agent,
      ...(kind === "framework_guide" ? [] : [{
        agent_id: "agent.aidevops-guide",
        description: "Synthetic guide",
        display_name: "AI DevOps",
        kind: "framework_guide",
        source_digest: "sha256:" + "0".repeat(64),
        source_ref: "agents:aidevops.md",
        workload_tier: "standard",
      }]),
    ],
    document_type: "agent_roster",
    roster_id: "agent-roster.aidevops",
    schema_version: 1,
  };
  const roster = {...unsignedRoster, roster_digest: canonicalDigest(unsignedRoster)};
  const overlay = createOverlayDocument({roster, agent, workloadTier, context: contextFixture()});
  const overlayPath = path.join(root, "overlay.json");
  fs.writeFileSync(overlayPath, `${canonicalJson(overlay)}\n`, {mode: 0o600});
  const conversation = loadTeamInterfaceConversation({
    AIDEVOPS_SESSION_ORIGIN: "conversation",
    AIDEVOPS_TEAM_INTERFACE_OVERLAY: overlayPath,
  }, agentsDir);
  return {agentsDir, conversation, overlay, overlayPath, root, source};
}

function widenedConfig() {
  return {
    agent: {
      Build: {mode: "primary", tools: {bash: true}},
      arbitrary: {mode: "primary", permission: "allow", tools: {future_tool: true}},
    },
    default_agent: "Build",
    formatter: {unsafe: {command: ["synthetic-formatter"]}},
    lsp: {unsafe: {command: ["synthetic-lsp"]}},
    mcp: {unsafe: {command: ["synthetic-mcp"], type: "local"}},
    permission: "allow",
    share: "auto",
    snapshot: true,
    subagent_depth: 9,
    tools: {"*": true, bash: true, future_tool: true},
  };
}

function assertRestrictedConfig(config, conversation) {
  const name = conversation.overlay.agent.display_name;
  const evidence = conversationConfigEvidence(name);
  assert.equal(config.default_agent, name);
  assert.deepEqual(config.tools, evidence.tools);
  assert.deepEqual(config.permission, evidence.permission);
  assert.deepEqual(config.mcp, {});
  assert.equal(config.formatter, false);
  assert.equal(config.lsp, false);
  assert.equal(config.share, "disabled");
  assert.equal(config.snapshot, false);
  assert.equal(config.subagent_depth, 0);
  assert.equal(config.tools.read, true);
  assert.equal(config.tools.grep, true);
  assert.equal(config.tools.glob, true);
  for (const denied of ["bash", "task", "write", "edit", "apply_patch", "skill", "webfetch", "question", "todowrite"]) {
    assert.equal(config.tools[denied], false, `${denied} remained enabled`);
  }
  assert.equal(config.tools["*"], false);
  assert.equal(config.permission["*"], "deny");
  assert.equal(config.permission.external_directory, "deny");
  assert.equal(config.permission.read["**/.ssh/**"], "deny");
  assert.equal(config.permission.read["**/auth.json"], "deny");
  assert.deepEqual(Object.keys(config.agent).sort(), [name, "build", "explore", "general", "plan"].sort());
  assert.equal(config.agent[name].mode, "primary");
  assert.equal(config.agent[name].prompt, conversation.sourceContent);
  assert.deepEqual(config.agent[name].tools, evidence.agent[name].tools);
  assert.deepEqual(config.agent[name].permission, evidence.agent[name].permission);
  for (const builtin of ["build", "plan", "general", "explore"]) {
    assert.deepEqual(config.agent[builtin], {disable: true});
  }
}

test("final conversation isolation removes every widened capability", () => {
  const fixture = createFixture();
  try {
    assert.equal(Object.isFrozen(fixture.conversation), true);
    assert.equal(Object.isFrozen(fixture.conversation.overlay.context), true);
    const config = widenedConfig();
    assert.equal(enforceTeamInterfaceConversationIsolation(config, fixture.conversation), 1);
    assertRestrictedConfig(config, fixture.conversation);
    assert.equal(Object.hasOwn(config.tools, "future_tool"), false);
    assert.equal(Object.hasOwn(config.agent, "arbitrary"), false);
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("config hook applies conversation isolation after MCP, grant, and managed-directory widening", async () => {
  const fixture = createFixture();
  try {
    const workspaceDir = path.join(fixture.root, "workspace");
    fs.mkdirSync(path.join(workspaceDir, "tmp"), {recursive: true});
    const config = widenedConfig();
    const hook = createConfigHook({
      agentsDir: fixture.agentsDir,
      conversation: fixture.conversation,
      pluginDir: path.join(repositoryRoot, ".agents/plugins/opencode-aidevops"),
      repositoryDir: fixture.root,
      workspaceDir,
    });
    await hook(config);
    assertRestrictedConfig(config, fixture.conversation);
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("normal sessions remain unchanged by the conversation-only guard", () => {
  const config = widenedConfig();
  const original = structuredClone(config);
  assert.equal(enforceTeamInterfaceConversationIsolation(config, null), 0);
  assert.deepEqual(config, original);
});

test("bounded context is appended as an immutable evidence block without raw content", () => {
  const fixture = createFixture();
  try {
    const block = conversationSystemBlock(fixture.conversation);
    assert.match(block, /^<aidevops-team-interface-context-v1>/);
    assert.match(block, /provider_ref=provider:synthetic-provider/);
    assert.match(block, /grants no authority/);
    assert.doesNotMatch(block, /Synthetic canonical agent|Use only the enforced tools/);
    const output = {system: ["base system"]};
    assert.equal(appendConversationSystemContext(output, fixture.conversation), 1);
    assert.equal(output.system[0], "base system");
    assert.equal(output.system[1], block);
    assert.throws(
      () => appendConversationSystemContext({}, fixture.conversation),
      /system transform output is unavailable/,
    );
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("all workload tiers resolve through current root-session provider policy", async () => {
  for (const tier of ["simple", "standard", "thinking"]) {
    const fixture = createFixture({workloadTier: tier});
    try {
      const output = {options: {}};
      const applied = await applyConversationRootVariant(
        {
          message: {agent: "Synthetic", sessionID: `root-${tier}`},
          model: {id: "gpt-5.6-sol"},
          provider: {id: "openai"},
        },
        output,
        fixture.conversation,
        {
          client: {session: {get: async () => ({data: {id: `root-${tier}`}})}},
          resolveVariant: resolveTierReasoning,
          tierReasoning,
        },
      );
      assert.equal(applied, 1, `${tier} did not resolve a provider variant`);
      assert.equal(output.options.reasoningEffort, tierReasoning[tier].openai);
    } finally {
      fs.rmSync(fixture.root, {recursive: true, force: true});
    }
  }
});

test("nested sessions, mismatched agents, and incompatible runtime metadata fail closed", async () => {
  const fixture = createFixture();
  const baseInput = {
    message: {agent: "Synthetic", sessionID: "session"},
    model: {id: "gpt-5.6-sol"},
    provider: {id: "openai"},
  };
  const options = {
    resolveVariant: resolveTierReasoning,
    tierReasoning,
  };
  try {
    await assert.rejects(
      applyConversationRootVariant(baseInput, {options: {}}, fixture.conversation, {
        ...options,
        client: {session: {get: async () => ({data: {id: "session", parentID: "parent"}})}},
      }),
      /cannot route nested sessions/,
    );
    await assert.rejects(
      applyConversationRootVariant(
        {...baseInput, message: {...baseInput.message, agent: "Different"}},
        {options: {}},
        fixture.conversation,
        {...options, client: {session: {get: async () => ({data: {id: "session"}})}}},
      ),
      /different agent profile/,
    );
    await assert.rejects(
      applyConversationRootVariant(baseInput, {options: {}}, fixture.conversation, {
        ...options,
        client: {},
      }),
      /metadata is unavailable/,
    );
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("unknown provider policy cannot serialize or invent a model variant", async () => {
  const fixture = createFixture();
  try {
    const output = {options: {}};
    const applied = await applyConversationRootVariant(
      {
        message: {agent: "Synthetic", sessionID: "root"},
        model: {id: "synthetic-model"},
        provider: {id: "unknown"},
      },
      output,
      fixture.conversation,
      {
        client: {session: {get: async () => ({data: {id: "root"}})}},
        resolveVariant: resolveTierReasoning,
        tierReasoning,
      },
    );
    assert.equal(applied, 0);
    assert.deepEqual(output.options, {});
    assert.equal(Object.hasOwn(fixture.conversation.overlay, "model"), false);
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("source drift, noncanonical overlays, wrong origins, and symlink overlays fail closed", () => {
  const fixture = createFixture();
  try {
    fs.appendFileSync(path.join(fixture.agentsDir, "synthetic.md"), "drift\n");
    assert.throws(
      () => loadTeamInterfaceConversation({
        AIDEVOPS_SESSION_ORIGIN: "conversation",
        AIDEVOPS_TEAM_INTERFACE_OVERLAY: fixture.overlayPath,
      }, fixture.agentsDir),
      /source digest no longer matches/,
    );
    assert.throws(
      () => loadTeamInterfaceConversation({
        AIDEVOPS_SESSION_ORIGIN: "interactive",
        AIDEVOPS_TEAM_INTERFACE_OVERLAY: fixture.overlayPath,
      }, fixture.agentsDir),
      /dedicated session origin/,
    );

    const prettyPath = path.join(fixture.root, "pretty.json");
    fs.writeFileSync(prettyPath, `${JSON.stringify(fixture.overlay, null, 2)}\n`, {mode: 0o600});
    assert.throws(
      () => loadTeamInterfaceConversation({
        AIDEVOPS_SESSION_ORIGIN: "conversation",
        AIDEVOPS_TEAM_INTERFACE_OVERLAY: prettyPath,
      }, fixture.agentsDir),
      /not canonical JSON/,
    );
    const symlinkPath = path.join(fixture.root, "overlay-link.json");
    fs.symlinkSync(fixture.overlayPath, symlinkPath);
    assert.throws(
      () => loadTeamInterfaceConversation({
        AIDEVOPS_SESSION_ORIGIN: "conversation",
        AIDEVOPS_TEAM_INTERFACE_OVERLAY: symlinkPath,
      }, fixture.agentsDir),
      /non-symlink file/,
    );
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("framework guide remains an explicit restricted profile instead of Build+", () => {
  const fixture = createFixture({
    agentID: "agent.aidevops-guide",
    displayName: "AI DevOps",
    filename: "aidevops.md",
    kind: "framework_guide",
  });
  try {
    const config = widenedConfig();
    enforceTeamInterfaceConversationIsolation(config, fixture.conversation);
    assert.equal(config.default_agent, "AI DevOps");
    assert.equal(Object.hasOwn(config.agent, "Build+"), false);
    assert.equal(config.agent["AI DevOps"].mode, "primary");
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});
