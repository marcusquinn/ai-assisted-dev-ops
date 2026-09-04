// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import {
  createMcpActivationTool,
  enforceManagedMcpArtifactPath,
} from "../mcp-activation-tool.mjs";
import { createMcpSessionRuntime, registerMcpServers } from "../mcp-registry.mjs";

const TEST_DIR = fileURLToPath(new URL(".", import.meta.url));
const AGENTS_DIR = join(TEST_DIR, "../../..");
const schemaNode = { describe() { return this; } };
const z = { enum() { return schemaNode; } };
const tool = (definition) => definition;

test("registers only the explicit MCP activation profiles", () => {
  const config = {};
  const count = registerOnDemandMcpAgents(config, AGENTS_DIR);

  assert.equal(count, 3);
  assert.deepEqual(Object.keys(config.agent), ["playwriter", "playwright", "quickfile"]);
  assert.equal(config.tools.aidevops_mcp, false);
  assert.equal(config.agent.playwriter.mode, "subagent");
  assert.equal(config.agent.playwriter.tools.aidevops_mcp, true);
  assert.equal(config.agent.playwriter.tools["playwriter_*"], true);
  assert.equal(config.agent.playwriter.permission.aidevops_mcp, "allow");
  assert.equal(config.agent.playwriter.permission["playwriter_*"], "allow");
  assert.match(config.agent.playwriter.prompt, /connect.*playwriter/);
  assert.match(config.agent.playwriter.prompt, /no browser tab is approved/i);
  assert.match(config.agent.playwriter.prompt, /before requesting authentication/i);
  assert.match(config.agent.playwriter.prompt, /enumerate.*context\.pages\(\)/i);
  assert.match(config.agent.playwriter.prompt, /never silently substitute.*playwright/i);
  assert.match(config.agent.playwriter.prompt, /never close\s+user-owned[\s\S]*browser windows/i);
  assert.match(config.agent.playwriter.prompt, /# Playwriter - Browser Extension MCP/);
  assert.equal(config.agent.playwright.mode, "subagent");
  assert.equal(config.agent.playwright.tools.aidevops_mcp, true);
  assert.equal(config.agent.playwright.tools["playwright_*"], true);
  assert.equal(config.agent.playwright.permission.aidevops_mcp, "allow");
  assert.equal(config.agent.playwright.permission["playwright_*"], "allow");
  assert.match(config.agent.playwright.prompt, /connect.*playwright/);
  assert.match(config.agent.playwright.prompt, /# Playwright MCP/);
  assert.equal(config.agent.quickfile.mode, "subagent");
  assert.equal(config.agent.quickfile.tools.aidevops_mcp, true);
  assert.equal(config.agent.quickfile.tools["quickfile_*"], true);
  assert.equal(config.agent.quickfile.permission.aidevops_mcp, "allow");
  assert.equal(config.agent.quickfile.permission["quickfile_*"], "allow");
  assert.match(config.agent.quickfile.prompt, /connect.*quickfile/);
  assert.match(config.agent.quickfile.prompt, /# QuickFile Agent/);
  assert.match(config.agent.quickfile.prompt, /business\/accounting\.md/);
  assert.doesNotMatch(config.agent.quickfile.prompt, /browser tab/i);
});

test("pins legacy Playwriter commands while preserving custom commands", () => {
  const legacyCommands = [
    ["npx", "playwriter@latest"],
    ["/opt/aidevops/bin/npx", "playwriter@latest"],
    ["npx", "-y", "playwriter@latest"],
    ["bun", "x", "playwriter@latest"],
  ];

  for (const command of legacyCommands) {
    const playwriter = {
      type: "local",
      command: [...command],
      enabled: true,
      environment: { PLAYWRITER_RELAY: "local" },
      timeout: 5_000,
      customMetadata: { owner: "user" },
    };
    const config = {
      mcp: { playwriter },
      tools: { "playwriter_*": true },
    };

    registerMcpServers(config);

    assert.strictEqual(config.mcp.playwriter, playwriter);
    assert.equal(playwriter.command.at(-1), "playwriter@0.5.0");
    assert.ok(!playwriter.command.includes("playwriter@latest"));
    assert.equal(playwriter.enabled, false);
    assert.deepEqual(playwriter.environment, { PLAYWRITER_RELAY: "local" });
    assert.equal(playwriter.timeout, 5_000);
    assert.deepEqual(playwriter.customMetadata, { owner: "user" });
    assert.equal(config.tools["playwriter_*"], false);
  }

  const customConfig = {
    mcp: {
      playwriter: {
        type: "local",
        command: ["playwriter", "serve", "--port", "19988"],
        enabled: true,
      },
    },
    tools: { "playwriter_*": true },
  };

  registerMcpServers(customConfig);

  assert.deepEqual(customConfig.mcp.playwriter.command, [
    "playwriter", "serve", "--port", "19988",
  ]);
  assert.equal(customConfig.mcp.playwriter.enabled, false);
  assert.equal(customConfig.tools["playwriter_*"], false);

  const customLatestConfig = {
    mcp: {
      playwriter: {
        type: "local",
        command: ["npx", "playwriter@latest", "serve", "--port", "19988"],
        enabled: true,
      },
    },
    tools: { "playwriter_*": true },
  };

  registerMcpServers(customLatestConfig);

  assert.deepEqual(customLatestConfig.mcp.playwriter.command, [
    "npx", "playwriter@latest", "serve", "--port", "19988",
  ]);
  assert.equal(customLatestConfig.mcp.playwriter.enabled, false);
  assert.equal(customLatestConfig.tools["playwriter_*"], false);

  const customLatestWithYesConfig = {
    mcp: {
      playwriter: {
        type: "local",
        command: ["npx", "-y", "playwriter@latest", "serve", "--port", "19988"],
        enabled: true,
      },
    },
    tools: { "playwriter_*": true },
  };

  registerMcpServers(customLatestWithYesConfig);

  assert.deepEqual(customLatestWithYesConfig.mcp.playwriter.command, [
    "npx", "-y", "playwriter@latest", "serve", "--port", "19988",
  ]);
  assert.equal(customLatestWithYesConfig.mcp.playwriter.enabled, false);
  assert.equal(customLatestWithYesConfig.tools["playwriter_*"], false);
});

test("opts framework-generated Playwriter commands into the authenticated relay launcher", () => {
  const previous = process.env.AIDEVOPS_PLAYWRITER_AUTHENTICATED_RELAY;
  process.env.AIDEVOPS_PLAYWRITER_AUTHENTICATED_RELAY = "1";
  try {
    const generated = { mcp: {}, tools: {} };
    registerMcpServers(generated);
    assert.match(generated.mcp.playwriter.command[0], /node$/);
    assert.match(generated.mcp.playwriter.command[1], /playwriter-authenticated-relay\.mjs$/);
    assert.equal(generated.mcp.playwriter.command.at(-1), "playwriter@0.5.0");
    assert.ok(!generated.mcp.playwriter.command.some((part) => part.includes("TOKEN")));

    const previousGenerated = {
      mcp: {
        playwriter: {
          type: "local",
          command: ["npx", "playwriter@0.5.0"],
          enabled: true,
        },
      },
      tools: {},
    };
    registerMcpServers(previousGenerated);
    assert.match(
      previousGenerated.mcp.playwriter.command[1],
      /playwriter-authenticated-relay\.mjs$/,
    );
    assert.equal(previousGenerated.mcp.playwriter.enabled, false);

    const custom = {
      mcp: {
        playwriter: {
          type: "local",
          command: ["playwriter", "serve", "--host", "127.0.0.1"],
          enabled: true,
        },
      },
      tools: {},
    };
    registerMcpServers(custom);
    assert.deepEqual(custom.mcp.playwriter.command, [
      "playwriter", "serve", "--host", "127.0.0.1",
    ]);
  } finally {
    if (previous === undefined) delete process.env.AIDEVOPS_PLAYWRITER_AUTHENTICATED_RELAY;
    else process.env.AIDEVOPS_PLAYWRITER_AUTHENTICATED_RELAY = previous;
  }
});

test("migrates browser MCPs to disconnected and globally denied", () => {
  const runtime = createMcpSessionRuntime("/managed/workspace", {
    tempRoot: "/managed/tmp",
    nonce: "migration",
    markerToken: "migration-token",
  });
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

  registerMcpServers(config, { runtime });

  assert.equal(config.mcp.playwriter.enabled, false);
  assert.ok(config.mcp.playwriter.command.includes("playwriter@0.5.0"));
  assert.ok(!config.mcp.playwriter.command.includes("playwriter@latest"));
  assert.equal(config.mcp.playwright.enabled, false);
  assert.equal(config.mcp.playwright.command[0], "/bin/bash");
  assert.ok(config.mcp.playwright.command.includes(runtime.workspaces.playwright.directory));
  assert.ok(config.mcp.playwright.command.includes(
    join(runtime.workspaces.playwright.directory, ".playwright-mcp"),
  ));
  assert.match(config.mcp.playwright.command[2], /--output-dir/);
  assert.ok(config.mcp.playwright.command.includes("@playwright/mcp@0.0.79"));
  assert.equal(config.tools["playwriter_*"], false);
  assert.equal(config.tools["playwright_*"], false);
});

test("disables an inherited Playwright MCP when no safe runtime is available", () => {
  const config = {
    mcp: {
      playwright: {
        type: "local",
        command: ["npx", "-y", "@playwright/mcp@latest"],
        enabled: true,
      },
    },
    tools: { "playwright_*": true },
  };

  registerMcpServers(config);

  assert.equal(config.mcp.playwright.enabled, false);
  assert.equal(config.tools["playwright_*"], false);
});

test("rejects repository-local and relative Playwright temp roots", (t) => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-mcp-temp-root-"));
  const repositoryDir = join(root, "repository");
  const workspaceDir = join(root, "managed-workspace");
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const repositoryLocal = createMcpSessionRuntime(workspaceDir, {
    tempRoot: join(repositoryDir, "tmp"),
    repositoryDir,
    nonce: "repo-local",
    markerToken: "repo-local-token",
  });
  const relativeTemp = createMcpSessionRuntime(workspaceDir, {
    tempRoot: "relative-temp",
    repositoryDir,
    nonce: "relative",
    markerToken: "relative-token",
  });

  assert.ok(repositoryLocal.workspaces.playwright.directory.startsWith(join(workspaceDir, "tmp")));
  assert.ok(relativeTemp.workspaces.playwright.directory.startsWith(join(workspaceDir, "tmp")));
});

test("confines Playwright outputs from a canonical-start context and cleans on disconnect", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-mcp-confinement-"));
  const canonical = join(root, "canonical");
  const binDir = join(root, "bin");
  mkdirSync(canonical);
  mkdirSync(binDir);
  const runtime = createMcpSessionRuntime(join(root, "workspace"), {
    tempRoot: join(root, "managed-tmp"),
    nonce: "session-one",
    markerToken: "owned-session-one",
  });
  const secondRuntime = createMcpSessionRuntime(join(root, "workspace"), {
    tempRoot: join(root, "managed-tmp"),
    nonce: "session-two",
    markerToken: "owned-session-two",
  });
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const npxStub = join(binDir, "npx");
  writeFileSync(npxStub, `#!/usr/bin/env bash
set -eu
output_dir=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output-dir" ]]; then
    output_dir="$2"
    shift 2
    continue
  fi
  shift
done
mkdir -p -- "$output_dir"
printf 'snapshot' >"$output_dir/page.yml"
printf 'console' >"$output_dir/console.log"
printf 'named screenshot' >"$output_dir/review-home-desktop.png"
`, { mode: 0o755 });

  const config = {};
  registerMcpServers(config, { runtime });
  assert.notEqual(
    runtime.workspaces.playwright.directory,
    secondRuntime.workspaces.playwright.directory,
  );

  const calls = [];
  const client = {
    async connect(args) {
      calls.push(["connect", args]);
      const command = config.mcp.playwright.command;
      const result = spawnSync(command[0], command.slice(1), {
        cwd: canonical,
        encoding: "utf8",
        env: { ...process.env, PATH: `${binDir}:${process.env.PATH || ""}` },
      });
      assert.equal(result.status, 0, result.stderr);
    },
    async disconnect(args) { calls.push(["disconnect", args]); },
  };
  const activation = createMcpActivationTool(tool, z, {
    client,
    directory: canonical,
    allowedNames: ["playwright"],
    managedWorkspaces: runtime.workspaces,
  });

  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /Connected MCP playwright/,
  );
  const managedDir = runtime.workspaces.playwright.directory;
  assert.deepEqual(readdirSync(canonical), []);
  assert.equal(readFileSync(join(managedDir, ".playwright-mcp", "page.yml"), "utf8"), "snapshot");
  assert.equal(readFileSync(join(managedDir, ".playwright-mcp", "console.log"), "utf8"), "console");
  assert.equal(
    readFileSync(join(managedDir, ".playwright-mcp", "review-home-desktop.png"), "utf8"),
    "named screenshot",
  );

  assert.match(
    await activation.execute({ action: "disconnect", name: "playwright" }),
    /Disconnected MCP playwright/,
  );
  assert.equal(existsSync(managedDir), false);
  assert.deepEqual(calls, [
    ["connect", { path: { name: "playwright" }, query: { directory: canonical } }],
    ["disconnect", { path: { name: "playwright" }, query: { directory: canonical } }],
  ]);
});

test("removes an owned Playwright workspace after a failed connection", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-mcp-connect-failure-"));
  const runtime = createMcpSessionRuntime(join(root, "workspace"), {
    tempRoot: join(root, "managed-tmp"),
    nonce: "failed-session",
    markerToken: "owned-failed-session",
  });
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const activation = createMcpActivationTool(tool, z, {
    client: { async connect() { return { error: { message: "unavailable" } }; } },
    allowedNames: ["playwright"],
    managedWorkspaces: runtime.workspaces,
  });

  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /unavailable/,
  );
  assert.equal(existsSync(runtime.workspaces.playwright.directory), false);
});

test("keeps an existing owned workspace when a repeated connection fails", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-mcp-reconnect-"));
  const runtime = createMcpSessionRuntime(join(root, "workspace"), {
    tempRoot: join(root, "managed-tmp"),
    nonce: "reconnect-session",
    markerToken: "owned-reconnect-session",
  });
  t.after(() => rmSync(root, { recursive: true, force: true }));
  let connectCalls = 0;
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect() {
        connectCalls++;
        if (connectCalls > 1) return { error: { message: "already connected" } };
      },
      async disconnect() {},
    },
    allowedNames: ["playwright"],
    managedWorkspaces: runtime.workspaces,
  });

  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /Connected MCP playwright/,
  );
  const artifact = join(runtime.workspaces.playwright.directory, "active-artifact.png");
  writeFileSync(artifact, "active");
  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /already connected/,
  );
  assert.equal(readFileSync(artifact, "utf8"), "active");
  await activation.execute({ action: "disconnect", name: "playwright" });
});

test("rejects a temp-root ancestor symlink into the repository", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-mcp-ancestor-symlink-"));
  const canonical = join(root, "canonical");
  const tempRootLink = join(root, "managed-link");
  mkdirSync(canonical);
  symlinkSync(canonical, tempRootLink);
  const runtime = createMcpSessionRuntime(join(root, "workspace"), {
    tempRoot: join(tempRootLink, "tmp"),
    repositoryDir: canonical,
    nonce: "ancestor-symlink",
    markerToken: "owned-ancestor-symlink",
  });
  t.after(() => rmSync(root, { recursive: true, force: true }));
  let connectCalls = 0;
  const activation = createMcpActivationTool(tool, z, {
    client: { async connect() { connectCalls++; } },
    allowedNames: ["playwright"],
    managedWorkspaces: runtime.workspaces,
  });

  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /resolves inside the repository/,
  );
  assert.equal(connectCalls, 0);
  assert.deepEqual(readdirSync(canonical), []);
});

test("refuses cleanup after an ancestor symlink swap", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-mcp-cleanup-symlink-"));
  const canonical = join(root, "canonical");
  const tempRoot = join(root, "managed-tmp");
  mkdirSync(canonical);
  const runtime = createMcpSessionRuntime(join(root, "workspace"), {
    tempRoot,
    repositoryDir: canonical,
    nonce: "cleanup-symlink",
    markerToken: "owned-cleanup-symlink",
  });
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const activation = createMcpActivationTool(tool, z, {
    client: { async connect() {}, async disconnect() {} },
    allowedNames: ["playwright"],
    managedWorkspaces: runtime.workspaces,
  });
  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /Connected MCP playwright/,
  );

  const mcpParent = join(tempRoot, "mcp");
  renameSync(mcpParent, join(tempRoot, "mcp-owned"));
  const redirectedWorkspace = join(canonical, "playwright", "session-cleanup-symlink");
  mkdirSync(redirectedWorkspace, { recursive: true });
  writeFileSync(
    join(redirectedWorkspace, ".aidevops-mcp-workspace"),
    runtime.workspaces.playwright.markerToken,
  );
  writeFileSync(join(redirectedWorkspace, "must-survive.txt"), "preserved");
  symlinkSync(canonical, mcpParent);

  assert.match(
    await activation.execute({ action: "disconnect", name: "playwright" }),
    /workspace escapes its temporary root|workspace resolves inside the repository/,
  );
  assert.equal(readFileSync(join(redirectedWorkspace, "must-survive.txt"), "utf8"), "preserved");
});

test("rejects a symlinked Playwright workspace without touching its target", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-mcp-symlink-"));
  const canonical = join(root, "canonical");
  const runtime = createMcpSessionRuntime(join(root, "workspace"), {
    tempRoot: join(root, "managed-tmp"),
    nonce: "symlink-session",
    markerToken: "owned-symlink-session",
  });
  mkdirSync(canonical);
  mkdirSync(join(root, "managed-tmp", "mcp", "playwright"), { recursive: true });
  symlinkSync(canonical, runtime.workspaces.playwright.directory);
  t.after(() => rmSync(root, { recursive: true, force: true }));
  let connectCalls = 0;
  const activation = createMcpActivationTool(tool, z, {
    client: { async connect() { connectCalls++; } },
    allowedNames: ["playwright"],
    managedWorkspaces: runtime.workspaces,
  });

  assert.match(
    await activation.execute({ action: "connect", name: "playwright" }),
    /workspace (escapes its temporary root|is not a regular directory)/,
  );
  assert.equal(connectCalls, 0);
  assert.deepEqual(readdirSync(canonical), []);
});

test("blocks Playwright screenshot paths that escape managed storage", () => {
  const managedWorkspaces = { playwright: { directory: "/managed/playwright" } };
  const valid = { args: { filename: "screenshots/review.png" } };
  enforceManagedMcpArtifactPath(
    { tool: "playwright_browser_take_screenshot" },
    valid,
    managedWorkspaces,
  );
  assert.equal(valid.args.filename, "screenshots/review.png");

  for (const filename of ["../review.png", "shots/../../review.png", "/tmp/review.png", "C:\\review.png"]) {
    assert.throws(
      () => enforceManagedMcpArtifactPath(
        { tool: "playwright_browser_take_screenshot" },
        { args: { filename } },
        managedWorkspaces,
      ),
      /must not be absolute or contain '\.\.' traversal/,
    );
  }

  assert.throws(
    () => enforceManagedMcpArtifactPath(
      { tool: "playwright_browser_console_messages" },
      { args: { filename: "../console.log" } },
      managedWorkspaces,
    ),
    /must not be absolute or contain '\.\.' traversal/,
  );
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

test("resets a failed MCP status once and then connects", async () => {
  const statuses = ["failed", "connected"];
  const calls = [];
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect(args) { calls.push(["connect", args]); },
      async disconnect(args) { calls.push(["disconnect", args]); },
      async status(args) {
        calls.push(["status", args]);
        return { data: { playwriter: { status: statuses.shift() } } };
      },
    },
    directory: "/workspace",
    allowedNames: ["playwriter"],
    pause: async () => {},
  });

  assert.match(
    await activation.execute({ action: "connect", name: "playwriter" }),
    /Connected MCP playwriter/,
  );
  assert.deepEqual(calls, [
    ["connect", { path: { name: "playwriter" }, query: { directory: "/workspace" } }],
    ["status", { query: { directory: "/workspace" } }],
    ["disconnect", { path: { name: "playwriter" }, query: { directory: "/workspace" } }],
    ["connect", { path: { name: "playwriter" }, query: { directory: "/workspace" } }],
    ["status", { query: { directory: "/workspace" } }],
  ]);
});

test("limits failed-status recovery to one reset", async () => {
  const calls = [];
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect() { calls.push("connect"); },
      async disconnect() { calls.push("disconnect"); },
      async status() {
        calls.push("status");
        const phase = calls.filter((call) => call === "status").length;
        return {
          data: {
            playwriter: {
              status: "failed",
              error: phase === 1 ? "relay launch failed" : "protocol handshake failed",
            },
          },
        };
      },
    },
    allowedNames: ["playwriter"],
    pause: async () => {},
  });

  assert.equal(
    await activation.execute({ action: "connect", name: "playwriter" }),
    "Error: MCP connect failed for playwriter: MCP entered failed status during initial activation; diagnostic unavailable; use the documented secure CLI diagnostic path; MCP entered failed status during post-reset activation; diagnostic unavailable; use the documented secure CLI diagnostic path after one bounded reset",
  );
  assert.deepEqual(calls, ["connect", "status", "disconnect", "connect", "status"]);
});

test("reports when failed-status reset is unavailable", async () => {
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect() {},
      async status() { return { data: { playwriter: { status: "error" } } }; },
    },
    allowedNames: ["playwriter"],
  });

  assert.equal(
    await activation.execute({ action: "connect", name: "playwriter" }),
    "Error: MCP connect failed for playwriter: MCP entered error status during initial activation; diagnostic unavailable; use the documented secure CLI diagnostic path; bounded reset unavailable because OpenCode does not expose MCP disconnect in this runtime.",
  );
});

test("reports failed-status reset errors without reconnecting", async () => {
  const calls = [];
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect() { calls.push("connect"); },
      async disconnect() {
        calls.push("disconnect");
        return { error: { message: "reset unavailable" } };
      },
      async status() {
        calls.push("status");
        return { data: { playwriter: { status: "failed" } } };
      },
    },
    allowedNames: ["playwriter"],
  });

  assert.equal(
    await activation.execute({ action: "connect", name: "playwriter" }),
    "Error: MCP connect failed for playwriter: MCP entered failed status during initial activation; diagnostic unavailable; use the documented secure CLI diagnostic path; bounded reset disconnect failed: reset unavailable",
  );
  assert.deepEqual(calls, ["connect", "status", "disconnect"]);
});

test("never renders free-form failed-status diagnostics", async () => {
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect() {},
      async status() {
        return {
          data: {
            playwriter: {
              status: "failed",
              error: `PLAYWRITER_TOKEN=private-value Authorization: Bearer private-bearer {"cookie":"private-cookie","url":"https://example.invalid/?token=private-query"} ${"x".repeat(400)}`,
              token: "must-not-be-serialized",
            },
          },
        };
      },
    },
    allowedNames: ["playwriter"],
  });

  const result = await activation.execute({ action: "connect", name: "playwriter" });
  assert.match(result, /diagnostic unavailable; use the documented secure CLI diagnostic path/);
  assert.doesNotMatch(
    result,
    /PLAYWRITER_TOKEN|private-value|private-bearer|private-cookie|private-query|must-not-be-serialized|example\.invalid/,
  );
  assert.match(result, /bounded reset unavailable/);
});

test("normalizes unknown status values before reporting a timeout", async () => {
  const activation = createMcpActivationTool(tool, z, {
    client: {
      async connect() {},
      async status() {
        return { data: { playwriter: { status: "PLAYWRITER_TOKEN=private-value" } } };
      },
    },
    allowedNames: ["playwriter"],
    connectTimeoutMs: 1,
    pollIntervalMs: 1,
    pause: async () => new Promise((resolve) => setTimeout(resolve, 2)),
  });

  const result = await activation.execute({ action: "connect", name: "playwriter" });
  assert.match(result, /last status: unknown/);
  assert.doesNotMatch(result, /PLAYWRITER_TOKEN|private-value/);
});

test("does not reset status API errors or timeouts", async () => {
  const apiErrorCalls = [];
  const apiErrorActivation = createMcpActivationTool(tool, z, {
    client: {
      async connect() { apiErrorCalls.push("connect"); },
      async disconnect() { apiErrorCalls.push("disconnect"); },
      async status() {
        apiErrorCalls.push("status");
        return { error: { message: "status unavailable" } };
      },
    },
    allowedNames: ["playwriter"],
  });
  assert.equal(
    await apiErrorActivation.execute({ action: "connect", name: "playwriter" }),
    "Error: MCP connect failed for playwriter: status unavailable",
  );
  assert.deepEqual(apiErrorCalls, ["connect", "status"]);

  const timeoutCalls = [];
  const timeoutActivation = createMcpActivationTool(tool, z, {
    client: {
      async connect() { timeoutCalls.push("connect"); },
      async disconnect() { timeoutCalls.push("disconnect"); },
      async status() {
        timeoutCalls.push("status");
        return { data: { playwriter: { status: "connecting" } } };
      },
    },
    allowedNames: ["playwriter"],
    connectTimeoutMs: 1,
    pollIntervalMs: 1,
    pause: async () => new Promise((resolve) => setTimeout(resolve, 2)),
  });
  assert.equal(
    await timeoutActivation.execute({ action: "connect", name: "playwriter" }),
    "Error: MCP connect failed for playwriter: MCP did not become ready (last status: connecting)",
  );
  assert.deepEqual(timeoutCalls, ["connect", "status"]);
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
