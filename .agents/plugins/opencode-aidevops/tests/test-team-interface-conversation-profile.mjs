// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import {spawnSync} from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

import {createConfigHook, enforceTeamInterfaceConversationIsolation} from "../config-hook.mjs";
import {loadTierReasoningPolicies, resolveTierReasoning} from "../subagent-effort.mjs";
import {
  appendConversationSystemContext,
  applyConversationRootVariant,
  canonicalDigest,
  canonicalJson,
  conversationBootstrapConfig,
  conversationConfigEvidence,
  conversationSystemBlock,
  createOverlayDocument,
  loadCanonicalAgentRoster,
  loadTeamInterfaceConversation,
} from "../team-interface-context.mjs";
import {enforceConversationPathAccess} from "../team-interface-path-guard.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../../..");
const pluginEntryPath = path.join(repositoryRoot, ".agents/plugins/opencode-aidevops/index.mjs");
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
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-conversation-profile-")));
  const agentsDir = path.join(root, "agents");
  const projectRoot = path.join(root, "project");
  fs.mkdirSync(agentsDir);
  fs.mkdirSync(projectRoot);
  const fixturePluginDirectory = path.join(agentsDir, "plugins", "opencode-aidevops");
  fs.mkdirSync(fixturePluginDirectory, {recursive: true});
  fs.symlinkSync(pluginEntryPath, path.join(fixturePluginDirectory, "index.mjs"));
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
  const companion = kind === "framework_guide"
    ? {
        agent_id: "agent.synthetic-primary",
        description: "Synthetic primary",
        display_name: "Synthetic Primary",
        kind: "primary",
        source_digest: "sha256:" + "1".repeat(64),
        source_ref: "agents:synthetic-primary.md",
        workload_tier: "standard",
      }
    : {
        agent_id: "agent.aidevops-guide",
        description: "Synthetic guide",
        display_name: "AI DevOps",
        kind: "framework_guide",
        source_digest: "sha256:" + "0".repeat(64),
        source_ref: "agents:aidevops.md",
        workload_tier: "standard",
      };
  const unsignedRoster = {
    agents: [agent, companion],
    document_type: "agent_roster",
    roster_id: "agent-roster.aidevops",
    schema_version: 1,
  };
  const roster = {...unsignedRoster, roster_digest: canonicalDigest(unsignedRoster)};
  const overlay = createOverlayDocument({roster, agent, workloadTier, context: contextFixture()});
  const overlayPath = path.join(root, "overlay.json");
  fs.writeFileSync(overlayPath, `${canonicalJson(overlay)}\n`, {mode: 0o600});
  const runtimeRoot = path.join(root, "runtime");
  const runtimeDirectories = [
    runtimeRoot,
    path.join(runtimeRoot, "cache"),
    path.join(runtimeRoot, "config"),
    path.join(runtimeRoot, "config", "opencode"),
    path.join(runtimeRoot, "data"),
    path.join(runtimeRoot, "home"),
    path.join(runtimeRoot, "state"),
    path.join(runtimeRoot, "tmp"),
  ];
  for (const directory of runtimeDirectories) {
    fs.mkdirSync(directory, {recursive: true, mode: 0o700});
    fs.chmodSync(directory, 0o700);
  }
  const pluginUrl = pathToFileURL(fs.realpathSync(pluginEntryPath)).href;
  const configFile = path.join(runtimeRoot, "config", "opencode", "opencode.json");
  fs.writeFileSync(
    configFile,
    `${canonicalJson(conversationBootstrapConfig(pluginUrl))}\n`,
    {mode: 0o600},
  );
  const env = {
    AIDEVOPS_CONVERSATION_PROJECT_ROOT: projectRoot,
    AIDEVOPS_CONVERSATION_RUNTIME_ROOT: runtimeRoot,
    AIDEVOPS_OPENCODE_ISOLATED_DB: "1",
    AIDEVOPS_SESSION_ORIGIN: "conversation",
    AIDEVOPS_TEAM_INTERFACE_OVERLAY: overlayPath,
    AIDEVOPS_TEMP_DIR: path.join(runtimeRoot, "tmp"),
    HOME: path.join(runtimeRoot, "home"),
    OPENCODE_CONFIG: configFile,
    OPENCODE_CONFIG_DIR: path.join(runtimeRoot, "config", "opencode"),
    OPENCODE_DISABLE_AUTOCOMPACT: "1",
    OPENCODE_DISABLE_AUTOUPDATE: "1",
    OPENCODE_DISABLE_CLAUDE_CODE: "1",
    OPENCODE_DISABLE_CLAUDE_CODE_PROMPT: "1",
    OPENCODE_DISABLE_CLAUDE_CODE_SKILLS: "1",
    OPENCODE_DISABLE_DEFAULT_PLUGINS: "1",
    OPENCODE_DISABLE_EXTERNAL_SKILLS: "1",
    OPENCODE_DISABLE_LSP_DOWNLOAD: "1",
    OPENCODE_DISABLE_MODELS_FETCH: "1",
    OPENCODE_DISABLE_PROJECT_CONFIG: "1",
    OPENCODE_DISABLE_SHARE: "1",
    XDG_CACHE_HOME: path.join(runtimeRoot, "cache"),
    XDG_CONFIG_HOME: path.join(runtimeRoot, "config"),
    XDG_DATA_HOME: path.join(runtimeRoot, "data"),
    XDG_STATE_HOME: path.join(runtimeRoot, "state"),
  };
  const loadOptions = {canonicalRoster: roster, pluginEntryPath, repositoryDir: projectRoot};
  const conversation = loadTeamInterfaceConversation(env, agentsDir, loadOptions);
  return {
    agentsDir,
    configFile,
    conversation,
    env,
    loadOptions,
    overlay,
    overlayPath,
    projectRoot,
    root,
    source,
  };
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
  assert.deepEqual(config.plugin, [conversation.pluginUrl]);
  assert.deepEqual(config.instructions, []);
  assert.deepEqual(config.command, {});
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
        ...fixture.env,
        AIDEVOPS_TEAM_INTERFACE_OVERLAY: fixture.overlayPath,
      }, fixture.agentsDir, fixture.loadOptions),
      /source digest no longer matches/,
    );
    assert.throws(
      () => loadTeamInterfaceConversation({
        ...fixture.env,
        AIDEVOPS_SESSION_ORIGIN: "interactive",
      }, fixture.agentsDir, fixture.loadOptions),
      /dedicated session origin/,
    );

    const prettyPath = path.join(fixture.root, "pretty.json");
    fs.writeFileSync(prettyPath, `${JSON.stringify(fixture.overlay, null, 2)}\n`, {mode: 0o600});
    assert.throws(
      () => loadTeamInterfaceConversation({
        ...fixture.env,
        AIDEVOPS_TEAM_INTERFACE_OVERLAY: prettyPath,
      }, fixture.agentsDir, fixture.loadOptions),
      /not canonical JSON/,
    );
    const symlinkPath = path.join(fixture.root, "overlay-link.json");
    fs.symlinkSync(fixture.overlayPath, symlinkPath);
    assert.throws(
      () => loadTeamInterfaceConversation({
        ...fixture.env,
        AIDEVOPS_TEAM_INTERFACE_OVERLAY: symlinkPath,
      }, fixture.agentsDir, fixture.loadOptions),
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

test("conversation origin without an overlay fails closed before config registration", () => {
  const fixture = createFixture();
  try {
    const env = {...fixture.env};
    delete env.AIDEVOPS_TEAM_INTERFACE_OVERLAY;
    assert.throws(
      () => loadTeamInterfaceConversation(env, fixture.agentsDir, fixture.loadOptions),
      /requires a canonical launch overlay/,
    );
    assert.equal(loadTeamInterfaceConversation({}, fixture.agentsDir), null);
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("canonical roster digest and selected identity are revalidated at consumption", () => {
  const fixture = createFixture();
  const writeOverlay = (name, mutate) => {
    const document = structuredClone(fixture.overlay);
    mutate(document);
    const unsigned = structuredClone(document);
    delete unsigned.overlay_digest;
    document.overlay_digest = canonicalDigest(unsigned);
    const overlayPath = path.join(fixture.root, `${name}.json`);
    fs.writeFileSync(overlayPath, `${canonicalJson(document)}\n`, {mode: 0o600});
    return overlayPath;
  };
  try {
    const unknownPath = writeOverlay("unknown-agent", (document) => {
      document.agent.agent_id = "agent.forged";
    });
    assert.throws(
      () => loadTeamInterfaceConversation(
        {...fixture.env, AIDEVOPS_TEAM_INTERFACE_OVERLAY: unknownPath},
        fixture.agentsDir,
        fixture.loadOptions,
      ),
      /not uniquely present/,
    );

    const stalePath = writeOverlay("stale-roster", (document) => {
      document.roster_digest = `sha256:${"0".repeat(64)}`;
    });
    assert.throws(
      () => loadTeamInterfaceConversation(
        {...fixture.env, AIDEVOPS_TEAM_INTERFACE_OVERLAY: stalePath},
        fixture.agentsDir,
        fixture.loadOptions,
      ),
      /current canonical roster/,
    );

    const mismatchPath = writeOverlay("identity-mismatch", (document) => {
      document.agent.display_name = "Forged Synthetic";
      document.config_digest = canonicalDigest(conversationConfigEvidence("Forged Synthetic"));
    });
    assert.throws(
      () => loadTeamInterfaceConversation(
        {...fixture.env, AIDEVOPS_TEAM_INTERFACE_OVERLAY: mismatchPath},
        fixture.agentsDir,
        fixture.loadOptions,
      ),
      /does not match its canonical roster entry/,
    );
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("runtime boundary rejects missing isolation, path drift, and persistent config canaries", () => {
  const fixture = createFixture();
  try {
    const missingIsolation = {...fixture.env};
    delete missingIsolation.OPENCODE_DISABLE_PROJECT_CONFIG;
    assert.throws(
      () => loadTeamInterfaceConversation(missingIsolation, fixture.agentsDir, fixture.loadOptions),
      /OPENCODE_DISABLE_PROJECT_CONFIG does not match/,
    );
    assert.throws(
      () => loadTeamInterfaceConversation(
        {...fixture.env, HOME: fixture.root},
        fixture.agentsDir,
        fixture.loadOptions,
      ),
      /HOME escapes the private conversation runtime/,
    );
    assert.throws(
      () => loadTeamInterfaceConversation(
        fixture.env,
        fixture.agentsDir,
        {...fixture.loadOptions, repositoryDir: fixture.root},
      ),
      /runtime cwd does not match the validated project root/,
    );

    const unsafeConfig = conversationBootstrapConfig(fixture.conversation.pluginUrl);
    unsafeConfig.instructions = ["persistent-canary.md"];
    fs.writeFileSync(fixture.configFile, `${canonicalJson(unsafeConfig)}\n`, {mode: 0o600});
    assert.throws(
      () => loadTeamInterfaceConversation(fixture.env, fixture.agentsDir, fixture.loadOptions),
      /untrusted plugins, instructions, or commands/,
    );

    fs.writeFileSync(
      fixture.configFile,
      `${canonicalJson(conversationBootstrapConfig(fixture.conversation.pluginUrl))}\n`,
      {mode: 0o600},
    );
    fs.mkdirSync(path.join(path.dirname(fixture.configFile), "command"));
    assert.throws(
      () => loadTeamInterfaceConversation(fixture.env, fixture.agentsDir, fixture.loadOptions),
      /unsupported entries/,
    );
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("conversation read, grep, and glob stay within root and reject credential paths", () => {
  const fixture = createFixture();
  const normalFile = path.join(fixture.projectRoot, "notes.txt");
  const credentialFile = path.join(fixture.projectRoot, ".env");
  const outsideRoot = path.join(fixture.root, "outside");
  const escapeLink = path.join(fixture.projectRoot, "escape");
  fs.writeFileSync(normalFile, "safe fixture\n");
  fs.mkdirSync(outsideRoot);
  fs.writeFileSync(path.join(outsideRoot, "outside.txt"), "outside fixture\n");
  try {
    assert.equal(
      enforceConversationPathAccess("read", {filePath: normalFile}, fixture.conversation),
      1,
    );
    assert.equal(
      enforceConversationPathAccess("grep", {path: normalFile, pattern: "fixture"}, fixture.conversation),
      1,
    );
    assert.equal(
      enforceConversationPathAccess("glob", {path: fixture.projectRoot, pattern: "*.txt"}, fixture.conversation),
      1,
    );

    fs.writeFileSync(credentialFile, "fixture-only\n");
    for (const tool of ["read", "grep", "glob"]) {
      const args = tool === "read"
        ? {filePath: credentialFile}
        : {path: fixture.projectRoot, pattern: "*"};
      assert.throws(
        () => enforceConversationPathAccess(tool, args, fixture.conversation),
        /credential-like paths/,
      );
    }
    fs.rmSync(credentialFile);

    fs.symlinkSync(outsideRoot, escapeLink, "dir");
    for (const tool of ["read", "grep", "glob"]) {
      const args = tool === "read"
        ? {filePath: path.join(escapeLink, "outside.txt")}
        : {path: escapeLink, pattern: "*"};
      assert.throws(
        () => enforceConversationPathAccess(tool, args, fixture.conversation),
        /symbolic-link traversal/,
      );
    }
  } finally {
    fs.rmSync(fixture.root, {recursive: true, force: true});
  }
});

test("conversation plugin exposes only the minimal restricted hook surface", () => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-conversation-plugin-")));
  const agentsDir = path.join(repositoryRoot, ".agents");
  const projectRoot = path.join(root, "project");
  fs.mkdirSync(projectRoot);
  fs.writeFileSync(path.join(projectRoot, ".env"), "fixture-only\n", {mode: 0o600});
  const roster = loadCanonicalAgentRoster(agentsDir);
  const agent = roster.agents.find(({agent_id: agentID}) => agentID === "agent.build-plus");
  assert.ok(agent, "canonical Build+ agent is unavailable");
  const overlay = createOverlayDocument({
    roster,
    agent,
    workloadTier: "standard",
    context: contextFixture(),
  });
  const overlayPath = path.join(root, "overlay.json");
  const runtimeRoot = path.join(root, "runtime");
  const runtimeDirectories = [
    runtimeRoot,
    path.join(runtimeRoot, "cache"),
    path.join(runtimeRoot, "config"),
    path.join(runtimeRoot, "config", "opencode"),
    path.join(runtimeRoot, "data"),
    path.join(runtimeRoot, "home"),
    path.join(runtimeRoot, "state"),
    path.join(runtimeRoot, "tmp"),
  ];
  for (const directory of runtimeDirectories) {
    fs.mkdirSync(directory, {recursive: true, mode: 0o700});
    fs.chmodSync(directory, 0o700);
  }
  fs.writeFileSync(overlayPath, `${canonicalJson(overlay)}\n`, {mode: 0o600});
  const pluginUrl = pathToFileURL(fs.realpathSync(pluginEntryPath)).href;
  const configFile = path.join(runtimeRoot, "config", "opencode", "opencode.json");
  fs.writeFileSync(
    configFile,
    `${canonicalJson(conversationBootstrapConfig(pluginUrl))}\n`,
    {mode: 0o600},
  );
  const environment = {
    AIDEVOPS_CONVERSATION_PROJECT_ROOT: projectRoot,
    AIDEVOPS_CONVERSATION_RUNTIME_ROOT: runtimeRoot,
    AIDEVOPS_OPENCODE_ISOLATED_DB: "1",
    AIDEVOPS_SESSION_ORIGIN: "conversation",
    AIDEVOPS_TEAM_INTERFACE_OVERLAY: overlayPath,
    AIDEVOPS_TEMP_DIR: path.join(runtimeRoot, "tmp"),
    HOME: path.join(runtimeRoot, "home"),
    OPENCODE_CONFIG: configFile,
    OPENCODE_CONFIG_DIR: path.join(runtimeRoot, "config", "opencode"),
    OPENCODE_DISABLE_AUTOCOMPACT: "1",
    OPENCODE_DISABLE_AUTOUPDATE: "1",
    OPENCODE_DISABLE_CLAUDE_CODE: "1",
    OPENCODE_DISABLE_CLAUDE_CODE_PROMPT: "1",
    OPENCODE_DISABLE_CLAUDE_CODE_SKILLS: "1",
    OPENCODE_DISABLE_DEFAULT_PLUGINS: "1",
    OPENCODE_DISABLE_EXTERNAL_SKILLS: "1",
    OPENCODE_DISABLE_LSP_DOWNLOAD: "1",
    OPENCODE_DISABLE_MODELS_FETCH: "1",
    OPENCODE_DISABLE_PROJECT_CONFIG: "1",
    OPENCODE_DISABLE_SHARE: "1",
    PATH: process.env.PATH || "/usr/bin:/bin",
    XDG_CACHE_HOME: path.join(runtimeRoot, "cache"),
    XDG_CONFIG_HOME: path.join(runtimeRoot, "config"),
    XDG_DATA_HOME: path.join(runtimeRoot, "data"),
    XDG_STATE_HOME: path.join(runtimeRoot, "state"),
  };
  const childScript = [
    "const pluginModule = await import(process.argv[2]);",
    "const hooks = await pluginModule.AidevopsPlugin({directory: process.argv[1], client: {}});",
    "const config = {};",
    "await hooks.config(config);",
    "let denial = '';",
    "try {",
    "  await hooks['tool.execute.before']({tool: 'read'}, {args: {filePath: process.argv[1] + '/.env'}});",
    "} catch (error) {",
    "  denial = String(error.message || error);",
    "}",
    "process.stdout.write(JSON.stringify({config, denial, keys: Object.keys(hooks).sort()}));",
  ].join("\n");
  try {
    const result = spawnSync(
      process.execPath,
      ["--input-type=module", "-e", childScript, projectRoot, pluginUrl],
      {cwd: projectRoot, encoding: "utf8", env: environment, timeout: 30000},
    );
    assert.equal(result.status, 0, result.stderr);
    const evidence = JSON.parse(result.stdout);
    assert.deepEqual(evidence.keys, [
      "chat.message",
      "chat.params",
      "config",
      "experimental.chat.system.transform",
      "tool.execute.before",
    ]);
    assert.deepEqual(evidence.config.plugin, [pluginUrl]);
    assert.deepEqual(evidence.config.instructions, []);
    assert.deepEqual(evidence.config.command, {});
    assert.match(evidence.denial, /credential-like paths are denied/);
  } finally {
    fs.rmSync(root, {recursive: true, force: true});
  }
});
