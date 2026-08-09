// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import {spawn, spawnSync} from "node:child_process";
import {once} from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = fs.realpathSync(path.resolve(testDirectory, "../../..")); // nosemgrep
const agentsDirectory = path.join(repositoryRoot, ".agents");
const runtimeHelper = path.join(agentsDirectory, "scripts/team-interface-buzz-runtime.py");
const privateTempParent = process.env.AIDEVOPS_TEMP_DIR
  || path.join(os.homedir(), ".aidevops/.agent-workspace/tmp");

function requireSuccess(result, label) {
  assert.equal(result.status, 0, `${label} failed:\n${result.stderr || result.error || "unknown error"}`);
  return result;
}

function git(cwd, argumentsList, label) {
  return requireSuccess(spawnSync("/usr/bin/git", ["-C", cwd, ...argumentsList], {
    encoding: "utf8",
  }), label);
}

async function exchangeAcpStartup({command, cwd, environment, initialize, sessionNew, sessionPrompt}) {
  const child = spawn(command, [], {
    cwd,
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "";
  let stdoutBuffer = "";
  const responses = [];
  const responseWaiters = new Map();
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(-(8 * 1024 * 1024));
  });
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk;
    while (stdoutBuffer.includes("\n")) {
      const newline = stdoutBuffer.indexOf("\n");
      const line = stdoutBuffer.slice(0, newline);
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      responses.push(message);
      responseWaiters.get(message.id)?.(message);
      responseWaiters.delete(message.id);
    }
  });
  const exited = once(child, "exit");
  const waitForResponse = (id) => new Promise((resolveResponse, rejectResponse) => {
    const existing = responses.find((message) => message.id === id);
    if (existing) {
      resolveResponse(existing);
      return;
    }
    const timer = setTimeout(() => {
      responseWaiters.delete(id);
      rejectResponse(new Error(`ACP response ${id} timed out: ${stderr}`));
    }, 60000);
    responseWaiters.set(id, (message) => {
      clearTimeout(timer);
      resolveResponse(message);
    });
  });
  child.stdin.write(`${JSON.stringify(initialize)}\n`);
  const initializeResponse = await waitForResponse(initialize.id);
  child.stdin.write(`${JSON.stringify(sessionNew)}\n`);
  const sessionResponse = await waitForResponse(sessionNew.id);
  const sessionId = sessionResponse?.result?.sessionId;
  assert.ok(sessionId, `ACP session/new omitted sessionId: ${JSON.stringify(sessionResponse)}`);
  const boundPrompt = structuredClone(sessionPrompt);
  boundPrompt.params.sessionId = sessionId;
  child.stdin.write(`${JSON.stringify(boundPrompt)}\n`);
  const promptResponse = await waitForResponse(boundPrompt.id);
  child.stdin.end();
  const killTimer = setTimeout(() => child.kill("SIGTERM"), 5000);
  await exited;
  clearTimeout(killTimer);
  return {initializeResponse, promptResponse, responses, sessionResponse, stderr};
}

const version = spawnSync("opencode", ["--version"], {encoding: "utf8", timeout: 10000});
if (version.error?.code === "ENOENT") {
  process.stdout.write("Buzz installed startup canary skipped: opencode is unavailable\n");
  process.exit(0);
}
requireSuccess(version, "installed OpenCode version check");
assert.ok(fs.existsSync(path.join(os.homedir(), ".config/opencode/opencode.json")),
  "normal OpenCode config is required for the pinned runtime canary");

fs.mkdirSync(privateTempParent, {recursive: true, mode: 0o700}); // nosemgrep
const fixtureRoot = fs.realpathSync( // nosemgrep
  fs.mkdtempSync(path.join(privateTempParent, "buzz-installed-startup-")),
);
try {
  const appDataDirectory = path.join(fixtureRoot, "buzz-data");
  const callerDirectory = path.join(fixtureRoot, "non-git-caller");
  const canonicalRepository = path.join(fixtureRoot, "canonical-project");
  const fixtureHome = path.join(fixtureRoot, "home");
  const privateRuntimeTemp = path.join(fixtureRoot, "private-runtime-tmp");
  const workDirectory = path.join(fixtureRoot, "work");
  const worktreeBase = path.join(fixtureRoot, "worktrees");
  const reposPath = path.join(fixtureRoot, "repos.json");
  for (const directory of [
    appDataDirectory,
    callerDirectory,
    canonicalRepository,
    path.join(fixtureHome, ".config/aidevops"),
    privateRuntimeTemp,
    workDirectory,
    worktreeBase,
  ]) {
    fs.mkdirSync(directory, {recursive: true, mode: 0o700}); // nosemgrep
  }
  git(canonicalRepository, ["init", "--quiet", "--initial-branch=main"], "canonical repository initialization");
  fs.writeFileSync(path.join(canonicalRepository, "README.md"), "# Buzz startup canary\n", {mode: 0o600}); // nosemgrep
  git(canonicalRepository, ["add", "README.md"], "canonical repository staging");
  git(canonicalRepository, [
    "-c", "user.name=Aidevops Canary",
    "-c", "user.email=canary@example.invalid",
    "commit", "--quiet", "-m", "test: initialize Buzz startup canary",
  ], "canonical repository commit");
  fs.writeFileSync(reposPath, `${JSON.stringify({ // nosemgrep
    git_parent_dirs: [],
    initialized_repos: [{path: canonicalRepository, slug: "fixture/buzz-startup"}],
  })}\n`, {mode: 0o600});
  fs.copyFileSync(reposPath, path.join(fixtureHome, ".config/aidevops/repos.json")); // nosemgrep

  requireSuccess(spawnSync("python3", [
    runtimeHelper,
    "install",
    "--runtime", "interactive",
    "--project-root", canonicalRepository,
    "--repos", reposPath,
    "--app-data-dir", appDataDirectory,
  ], {
    encoding: "utf8",
    env: {...process.env, AIDEVOPS_BUZZ_RUNNING_OVERRIDE: "false"},
    timeout: 120000,
  }), "pinned Buzz runtime installation");

  const manifestPath = path.join(
    appDataDirectory,
    "custom_harnesses/aidevops-interactive-v1.json",
  );
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")); // nosemgrep
  assert.equal(fs.realpathSync(manifest.command), manifest.command); // nosemgrep
  assert.equal(manifest.env.AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME, "1");
  const pinnedAgents = fs.realpathSync(manifest.env.AIDEVOPS_BUZZ_AGENTS_DIR); // nosemgrep
  assert.ok(manifest.command.startsWith(`${pinnedAgents}${path.sep}`));

  const hostSlug = `canary-${process.pid}`;
  const snapshot = requireSuccess(spawnSync("python3", [
    path.join(pinnedAgents, "scripts/team-interface-buzz-team-snapshot.py"),
    "generate",
    "--agents-dir", pinnedAgents,
  ], {
    encoding: "utf8",
    env: {...process.env, AIDEVOPS_BUZZ_HOST_SLUG: hostSlug},
    timeout: 60000,
  }), "pinned Buzz team snapshot generation");
  const buildMember = JSON.parse(snapshot.stdout).members.find(
    ({profile}) => profile.displayName === `build-plus-${hostSlug}`,
  );
  assert.ok(buildMember, "pinned Buzz snapshot must include Build+");

  const initialize = {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: 1,
      clientCapabilities: {
        fs: {readTextFile: true, writeTextFile: true},
        terminal: true,
      },
    },
  };
  const sessionNew = {
    jsonrpc: "2.0",
    id: 2,
    method: "session/new",
    params: {cwd: callerDirectory, mcpServers: []},
  };
  const sessionPrompt = {
    jsonrpc: "2.0",
    id: 3,
    method: "session/prompt",
    params: {
      sessionId: "replaced-after-session-new",
      prompt: [{type: "text", text: "Reply with the word canary."}],
    },
  };
  const startupEnvironment = {
    ...process.env,
    ...manifest.env,
    AIDEVOPS_BUZZ_CLI: "/usr/bin/true",
    AIDEVOPS_BUZZ_HOST_SLUG: hostSlug,
    AIDEVOPS_BUZZ_TEMP_DIR: privateRuntimeTemp,
    AIDEVOPS_WORK_DIR: workDirectory,
    AIDEVOPS_WORKTREE_BASE_DIR: worktreeBase,
    BUZZ_ACP_AGENT_OWNER: "installed-canary-owner",
    BUZZ_ACP_ALLOWED_RESPOND_TO: "owner-only",
    BUZZ_ACP_DISPLAY_NAME: buildMember.profile.displayName,
    BUZZ_ACP_RESPOND_TO: "owner-only",
    BUZZ_ACP_SYSTEM_PROMPT: buildMember.definition.systemPrompt,
    BUZZ_MANAGED_AGENT: "xyz.block.buzz.app:installed-startup-canary",
    BUZZ_MANAGED_AGENT_START_NONCE: "0123456789abcdef0123456789abcdef",
    BUZZ_RELAY_URL: "wss://relay.invalid",
    HOME: fixtureHome,
  };
  const startup = await exchangeAcpStartup({
    command: manifest.command,
    cwd: callerDirectory,
    environment: startupEnvironment,
    initialize,
    sessionNew,
    sessionPrompt,
  });
  assert.ok(startup.initializeResponse?.result && !startup.initializeResponse.error,
    `ACP initialize failed: ${JSON.stringify(startup.initializeResponse)}`);
  assert.ok(startup.sessionResponse?.result && !startup.sessionResponse.error,
    `ACP session/new failed: ${JSON.stringify(startup.sessionResponse)}`);
  const promptEvidence = `${JSON.stringify(startup.promptResponse)}\n${startup.stderr}`;
  assert.doesNotMatch(
    promptEvidence,
    /SessionTools\.resolve|ToolRegistry|g\.type|_zod|cannot resolve @opencode-ai\/plugin schemas/i,
    `ACP session/prompt encountered an invalid plugin tool schema: ${promptEvidence}`,
  );
  assert.ok(startup.promptResponse?.result && !startup.promptResponse.error,
    `ACP session/prompt failed: ${promptEvidence}`);

  const expectedWorktree = path.join(
    worktreeBase,
    `canonical-project-buzz-${hostSlug}-build-plus`,
  );
  assert.equal(fs.realpathSync(expectedWorktree), expectedWorktree); // nosemgrep
  assert.equal(
    git(expectedWorktree, ["branch", "--show-current"], "Buzz worktree branch verification").stdout.trim(),
    `buzz/${hostSlug}/build-plus`,
  );
  process.stdout.write(
    `Buzz pinned ${version.stdout.trim()} wrapper startup canary passed from a non-Git cwd\n`,
  );
} finally {
  fs.rmSync(fixtureRoot, {recursive: true, force: true, maxRetries: 10, retryDelay: 100}); // nosemgrep
}
