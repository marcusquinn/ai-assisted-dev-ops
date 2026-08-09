// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import {spawn, spawnSync} from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

import {
  canonicalJson,
  conversationBootstrapConfig,
  createOverlayDocument,
  loadCanonicalAgentRoster,
} from "../../plugins/opencode-aidevops/team-interface-context.mjs";
import {verifyConversationEffectiveConfig} from "../team-interface-opencode-effective-config.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
// The nosemgrep sites below use only this canonical source root or a process-owned mkdtemp tree.
const repositoryRoot = fs.realpathSync(path.resolve(testDirectory, "../../..")); // nosemgrep
const agentsDirectory = fs.realpathSync( // nosemgrep
  process.env.AIDEVOPS_TEST_AGENTS_DIR || path.join(repositoryRoot, ".agents"),
);
const pluginPath = fs.realpathSync(path.join( // nosemgrep
  agentsDirectory,
  "plugins",
  "opencode-aidevops",
  "index.mjs",
));
const pluginUrl = pathToFileURL(pluginPath).href;
const MAX_ACP_OUTPUT_BYTES = 64 * 1024;

async function assertHealthyAcpStartup({cwd, environment}) {
  const child = spawn("opencode", ["acp", "--cwd", cwd], {
    cwd,
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let outputBytes = 0;
  let stderr = "";
  let startupWindowElapsed = false;
  let failure;
  let forceKillTimer;
  let startupTimer;

  const recordOutput = (chunk, captureStderr = false) => {
    outputBytes += chunk.length;
    if (captureStderr) stderr += chunk.toString("utf8");
    if (outputBytes > MAX_ACP_OUTPUT_BYTES && !failure) {
      failure = new Error("installed OpenCode ACP startup exceeded its output limit");
      child.kill("SIGKILL");
    }
  };
  child.stdout.on("data", (chunk) => recordOutput(chunk));
  child.stderr.on("data", (chunk) => recordOutput(chunk, true));

  const result = await new Promise((resolveResult, rejectResult) => {
    child.once("error", rejectResult);
    child.once("exit", (code, signal) => {
      clearTimeout(startupTimer);
      clearTimeout(forceKillTimer);
      if (failure) {
        rejectResult(failure);
        return;
      }
      if (!startupWindowElapsed) {
        rejectResult(new Error(
          `installed OpenCode ACP exited before healthy startup (code=${code}, signal=${signal}): ${stderr.trim()}`,
        ));
        return;
      }
      resolveResult({code, signal});
    });
    startupTimer = setTimeout(() => {
      startupWindowElapsed = true;
      child.kill("SIGTERM");
      forceKillTimer = setTimeout(() => child.kill("SIGKILL"), 5000);
    }, 2000);
  });
  assert.ok(
    result.signal === "SIGTERM" || result.signal === "SIGKILL" || result.code === 0,
    `installed OpenCode ACP did not stop cleanly: ${JSON.stringify(result)}`,
  );
}

const versionResult = spawnSync("opencode", ["--version"], {
  encoding: "utf8",
  timeout: 10000,
});
if (versionResult.error?.code === "ENOENT") {
  process.stdout.write("team-interface installed OpenCode boundary canary skipped: opencode is unavailable\n");
  process.exit(0);
}
assert.equal(versionResult.status, 0, versionResult.stderr);

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-installed-opencode-"))); // nosemgrep
try {
  const projectRoot = path.join(root, "project");
  const persistentHome = path.join(root, "persistent-home");
  const runtimeRoot = path.join(root, "runtime");
  const configDirectory = path.join(runtimeRoot, "config", "opencode");
  const overlayPath = path.join(root, "overlay.json");
  for (const directory of [
    projectRoot,
    path.join(persistentHome, ".config", "opencode"),
    runtimeRoot,
    path.join(runtimeRoot, "cache"),
    path.join(runtimeRoot, "config"),
    configDirectory,
    path.join(runtimeRoot, "data"),
    path.join(runtimeRoot, "home"),
    path.join(runtimeRoot, "state"),
    path.join(runtimeRoot, "tmp"),
  ]) {
    fs.mkdirSync(directory, {recursive: true, mode: 0o700}); // nosemgrep
    fs.chmodSync(directory, 0o700); // nosemgrep
  }

  const persistentCanary = {
    command: {"persistent-canary": {template: "must-not-load"}},
    instructions: ["persistent-canary.md"],
    plugin: ["file:///persistent-canary.mjs"],
  };
  fs.writeFileSync( // nosemgrep
    path.join(persistentHome, ".config", "opencode", "opencode.json"),
    `${JSON.stringify(persistentCanary)}\n`,
    {mode: 0o600},
  );
  fs.writeFileSync(
    path.join(projectRoot, "opencode.json"),
    `${JSON.stringify(persistentCanary)}\n`,
    {mode: 0o600},
  );

  const roster = loadCanonicalAgentRoster(agentsDirectory);
  const agent = roster.agents.find(({agent_id: agentID}) => agentID === "agent.aidevops-guide");
  assert.ok(agent, "canonical AI DevOps framework guide is unavailable");
  const overlay = createOverlayDocument({
    roster,
    agent,
    workloadTier: "standard",
    context: {
      actor_ref: "actor:installed-canary",
      app_team_ref: "app-team:installed-canary",
      community_ref: "community:installed-canary",
      conversation_ref: "conversation:installed-canary",
      correlation_ref: "correlation:installed-canary",
      provider_ref: "provider:installed-canary",
      trust_ref: "trust:installed-canary",
    },
  });
  fs.writeFileSync(overlayPath, `${canonicalJson(overlay)}\n`, {mode: 0o600}); // nosemgrep

  const configFile = path.join(configDirectory, "opencode.json");
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
    LANG: process.env.LANG || "C",
    OPENCODE_CONFIG: configFile,
    OPENCODE_CONFIG_DIR: configDirectory,
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
    TEMP: path.join(runtimeRoot, "tmp"),
    TERM: "dumb",
    TMP: path.join(runtimeRoot, "tmp"),
    TMPDIR: path.join(runtimeRoot, "tmp"),
    XDG_CACHE_HOME: path.join(runtimeRoot, "cache"),
    XDG_CONFIG_HOME: path.join(runtimeRoot, "config"),
    XDG_DATA_HOME: path.join(runtimeRoot, "data"),
    XDG_STATE_HOME: path.join(runtimeRoot, "state"),
  };
  const debugResult = spawnSync(
    "opencode",
    ["debug", "config", "--log-level", "ERROR"],
    {
      cwd: projectRoot,
      encoding: "utf8",
      env: environment,
      maxBuffer: 8 * 1024 * 1024,
      timeout: 60000,
    },
  );
  assert.equal(debugResult.status, 0, debugResult.stderr);
  const effectiveConfig = JSON.parse(debugResult.stdout);
  assert.equal(
    effectiveConfig.default_agent,
    overlay.agent.display_name,
    JSON.stringify({
      actual: effectiveConfig.default_agent,
      agentKeys: Object.keys(effectiveConfig.agent || {}),
      expected: overlay.agent.display_name,
    }),
  );
  verifyConversationEffectiveConfig(effectiveConfig, overlay, {pluginUrl});
  assert.equal(JSON.stringify(effectiveConfig).includes("persistent-canary"), false);
  assert.equal(JSON.stringify(effectiveConfig).includes("must-not-load"), false);
  await assertHealthyAcpStartup({cwd: projectRoot, environment});
  process.stdout.write(
    `team-interface installed OpenCode ${versionResult.stdout.trim()} effective-config and ACP startup canary passed\n`,
  );
} finally {
  fs.rmSync(root, {recursive: true, force: true});
}
