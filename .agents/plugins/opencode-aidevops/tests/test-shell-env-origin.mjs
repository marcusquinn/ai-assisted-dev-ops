// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for t3538: interactive OpenCode shells must stamp
// AIDEVOPS_SESSION_ORIGIN=interactive even when a stale worker-origin value is
// inherited by the shell environment. Without this, gh_create_issue labels
// maintainer-created issues as origin:worker.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  createSessionModelStore,
  createShellEnvHook,
  sessionModelIdentity,
} from "../shell-env.mjs";

function makeHook() {
  return createShellEnvHook({
    agentsDir: "/tmp/aidevops-agents",
    scriptsDir: "/tmp/aidevops-scripts",
    workspaceDir: "/tmp/aidevops-workspace",
  });
}

function withTempAgentsDir(fn) {
  const root = mkdtempSync(join(tmpdir(), "aidevops-shell-env-"));
  const dir = join(root, "agents");
  mkdirSync(dir);
  try {
    return fn(dir);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function makeHookForAgentsDir(agentsDir) {
  return createShellEnvHook({
    agentsDir,
    scriptsDir: "/tmp/aidevops-scripts",
    workspaceDir: "/tmp/aidevops-workspace",
  });
}

function makeHookForAgentsDirAndVersion(agentsDir, version) {
  return createShellEnvHook({
    agentsDir,
    scriptsDir: "/tmp/aidevops-scripts",
    workspaceDir: "/tmp/aidevops-workspace",
    version,
  });
}

async function withCleanHeadlessProcessEnv(fn) {
  const keys = ["FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS", "OPENCODE_HEADLESS", "GITHUB_ACTIONS"];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  try {
    for (const key of keys) delete process.env[key];
    await fn();
  } finally {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
}

test("interactive OpenCode shell overrides stale worker origin", async () => {
  await withCleanHeadlessProcessEnv(async () => {
    const hook = makeHook();
    const output = {
      env: {
        PATH: "/usr/bin:/bin",
        AIDEVOPS_SESSION_ORIGIN: "worker",
        AIDEVOPS_WORKER_ID: "worker:stale",
        AIDEVOPS_PARENT_WORKER_ID: "worker:stale-parent",
        AIDEVOPS_ROOT_WORKER_ID: "worker:stale-root",
        AIDEVOPS_CORRELATION_ID: "correlation:stale",
        AIDEVOPS_CAUSATION_ID: "event:stale",
        AIDEVOPS_PARENT_EVENT_ID: "event:stale",
        AIDEVOPS_ROOT_EVENT_ID: "event:stale-root",
      },
    };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_SESSION_ORIGIN, "interactive");
    for (const key of Object.keys(output.env).filter((key) => /WORKER_ID|EVENT_ID|CORRELATION_ID|CAUSATION_ID/.test(key))) {
      assert.fail(`interactive shell retained stale lineage key ${key}`);
    }
  });
});

test("shell env moves the Git guard scripts directory to PATH first", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-shell-path-"));
  const scriptsDir = join(root, "scripts");
  const binDir = join(root, "bin");
  mkdirSync(scriptsDir);
  mkdirSync(binDir);
  try {
    const hook = createShellEnvHook({ agentsDir: root, scriptsDir, workspaceDir: root });
    const output = { env: { PATH: `/usr/bin:${binDir}:${scriptsDir}:/bin` } };
    await hook({ sessionID: "path-test" }, output);
    assert.equal(output.env.PATH, `${scriptsDir}:${binDir}:/usr/bin:/bin`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("headless OpenCode shell stamps worker origin", async () => {
  const hook = makeHook();
  const output = {
    env: {
      PATH: "/usr/bin:/bin",
      OPENCODE_HEADLESS: "true",
      AIDEVOPS_SESSION_ORIGIN: "interactive",
    },
  };

  await hook({ sessionID: "worker-session" }, output);

  assert.equal(output.env.AIDEVOPS_SESSION_ORIGIN, "worker");
});

test("shell env replaces stale OpenCode identity after a plugin update", async () => {
  const hook = makeHook();
  const output = {
    env: {
      PATH: "/usr/bin:/bin",
      OPENCODE_SESSION_ID: "stale-opencode-session",
      AIDEVOPS_OPENCODE_SESSION_ID: "stale-opencode-session",
    },
  };

  await hook({ sessionID: "current-opencode-session" }, output);

  assert.equal(output.env.OPENCODE_SESSION_ID, "current-opencode-session");
  assert.equal(output.env.AIDEVOPS_OPENCODE_SESSION_ID, "current-opencode-session");
});

test("shell env preserves framework identity and publishes its OpenCode mapping", async () => {
  const hook = makeHook();
  const output = {
    env: {
      PATH: "/usr/bin:/bin",
      AIDEVOPS_SESSION_ID: "framework-session",
    },
  };

  await hook({ sessionID: "opencode-session" }, output);

  assert.equal(output.env.AIDEVOPS_SESSION_ID, "framework-session");
  assert.equal(output.env.AIDEVOPS_OPENCODE_SESSION_ID, "opencode-session");
});

test("shell env derives the signature model without replacing an explicit value", async () => {
  const hook = makeHook();
  const derived = { env: { PATH: "/usr/bin:/bin" } };
  await hook({ model: { providerID: "openai", modelID: "gpt-5.6-sol" } }, derived);
  assert.equal(derived.env.AIDEVOPS_SIG_MODEL, "openai/gpt-5.6-sol");

  const explicit = { env: { PATH: "/usr/bin:/bin", AIDEVOPS_SIG_MODEL: "configured/model" } };
  await hook({ model: { providerID: "openai", modelID: "other-model" } }, explicit);
  assert.equal(explicit.env.AIDEVOPS_SIG_MODEL, "configured/model");
});

test("shell env records the effective model against only its session", async () => {
  const store = createSessionModelStore();
  const hook = createShellEnvHook({
    agentsDir: "/tmp/aidevops-agents",
    scriptsDir: "/tmp/aidevops-scripts",
    workspaceDir: "/tmp/aidevops-workspace",
    onSessionIdentity: (sessionId, modelId) => store.remember(sessionId, modelId),
  });

  await hook(
    { sessionID: "session-a", model: { providerID: "openai", modelID: "model-a" } },
    { env: { PATH: "/usr/bin:/bin" } },
  );
  await hook(
    { sessionID: "session-b", model: { providerID: "anthropic", modelID: "model-b" } },
    { env: { PATH: "/usr/bin:/bin" } },
  );

  assert.equal(store.resolve("session-a"), "openai/model-a");
  assert.equal(store.resolve("session-b"), "anthropic/model-b");
  assert.equal(store.resolve("session-missing"), "");
});

test("session model store evicts old entries at its bound", () => {
  const store = createSessionModelStore(2);
  store.remember("session-a", "model-a");
  store.remember("session-b", "model-b");
  store.remember("session-c", "model-c");
  assert.equal(store.resolve("session-a"), "");
  assert.equal(store.resolve("session-b"), "model-b");
  assert.equal(store.resolve("session-c"), "model-c");
});

test("chat params identity seeds the session model before tool execution", () => {
  assert.deepEqual(
    sessionModelIdentity({
      message: { sessionID: "chat-session" },
      provider: { id: "openai" },
      model: { id: "gpt-5.6-sol" },
    }),
    { sessionId: "chat-session", modelId: "openai/gpt-5.6-sol" },
  );
});

test("shell env forwards OTEL values without replacing shell-specific values", async () => {
  const keys = ["OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_SERVICE_NAME"];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  try {
    process.env.OTEL_EXPORTER_OTLP_ENDPOINT = "test-endpoint";
    process.env.OTEL_SERVICE_NAME = "parent-service";
    const output = { env: { PATH: "/usr/bin:/bin", OTEL_SERVICE_NAME: "shell-service" } };

    await makeHook()({ sessionID: "otel-session" }, output);

    assert.equal(output.env.OTEL_EXPORTER_OTLP_ENDPOINT, "test-endpoint");
    assert.equal(output.env.OTEL_SERVICE_NAME, "shell-service");
  } finally {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
});

test("headless shell preserves explicit worker lineage", async () => {
  const keys = [
    "AIDEVOPS_WORKER_ID",
    "AIDEVOPS_PARENT_WORKER_ID",
    "AIDEVOPS_ROOT_WORKER_ID",
    "AIDEVOPS_CORRELATION_ID",
    "AIDEVOPS_CAUSATION_ID",
    "AIDEVOPS_PARENT_EVENT_ID",
    "AIDEVOPS_ROOT_EVENT_ID",
  ];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  try {
    process.env.AIDEVOPS_WORKER_ID = "worker:child";
    process.env.AIDEVOPS_PARENT_WORKER_ID = "worker:parent";
    process.env.AIDEVOPS_ROOT_WORKER_ID = "worker:root";
    process.env.AIDEVOPS_CORRELATION_ID = "correlation:root";
    process.env.AIDEVOPS_CAUSATION_ID = "event:dispatch";
    process.env.AIDEVOPS_PARENT_EVENT_ID = "event:dispatch";
    process.env.AIDEVOPS_ROOT_EVENT_ID = "event:root";
    const output = { env: { PATH: "/usr/bin:/bin", OPENCODE_HEADLESS: "true" } };
    await makeHook()({ sessionID: "worker-session" }, output);
    assert.equal(output.env.AIDEVOPS_WORKER_ID, "worker:child");
    assert.equal(output.env.AIDEVOPS_PARENT_WORKER_ID, "worker:parent");
    assert.equal(output.env.AIDEVOPS_ROOT_WORKER_ID, "worker:root");
    assert.equal(output.env.AIDEVOPS_CORRELATION_ID, "correlation:root");
    assert.equal(output.env.AIDEVOPS_CAUSATION_ID, "event:dispatch");
    assert.equal(output.env.AIDEVOPS_PARENT_EVENT_ID, "event:dispatch");
    assert.equal(output.env.AIDEVOPS_ROOT_EVENT_ID, "event:root");
  } finally {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
});

test("shell env version prefers deployed agents VERSION over legacy version", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.20.102\n");
    writeFileSync(join(agentsDir, "..", "version"), "2.44.2\n");

    const hook = makeHookForAgentsDir(agentsDir);
    const output = { env: { PATH: "/usr/bin:/bin" } };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_VERSION, "3.20.102");
  });
});

test("shell env version follows active deployment instead of pinned runtime bundle", async () => {
  await withTempAgentsDir(async (activeAgentsDir) => {
    const runtimeAgentsDir = join(activeAgentsDir, "..", "runtime-agents");
    mkdirSync(runtimeAgentsDir);
    writeFileSync(join(activeAgentsDir, "VERSION"), "3.20.103\n");
    writeFileSync(join(runtimeAgentsDir, "VERSION"), "3.20.102\n");

    const hook = createShellEnvHook({
      activeAgentsDir,
      agentsDir: runtimeAgentsDir,
      scriptsDir: join(runtimeAgentsDir, "scripts"),
      workspaceDir: "/tmp/aidevops-workspace",
    });
    const output = { env: { PATH: "/usr/bin:/bin", AIDEVOPS_VERSION: "3.20.101" } };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_ACTIVE_AGENTS_DIR, activeAgentsDir);
    assert.equal(output.env.AIDEVOPS_AGENTS_DIR, runtimeAgentsDir);
    assert.equal(output.env.AIDEVOPS_VERSION, "3.20.103");
  });
});

test("shell env version uses precomputed dependency before filesystem fallbacks", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.20.102\n");

    const hook = makeHookForAgentsDirAndVersion(agentsDir, "3.21.0\n");
    const output = { env: { PATH: "/usr/bin:/bin" } };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_VERSION, "3.21.0");
  });
});

test("shell env hook tolerates missing dependency object", async () => {
  await withCleanHeadlessProcessEnv(async () => {
    const hook = createShellEnvHook();
    const output = { env: { PATH: "/usr/bin:/bin" } };

    await hook({ sessionID: "interactive-session" }, output);

    assert.equal(output.env.AIDEVOPS_SESSION_ORIGIN, "interactive");
  });
});

test("shell env hook without agentsDir does not read VERSION from process cwd", async () => {
  await withCleanHeadlessProcessEnv(async () => {
    const root = mkdtempSync(join(tmpdir(), "aidevops-shell-env-cwd-"));
    const previousCwd = process.cwd();
    try {
      writeFileSync(join(root, "VERSION"), "9.9.9-cwd\n");
      process.chdir(root);

      const hook = createShellEnvHook();
      const output = { env: { PATH: "/usr/bin:/bin" } };

      await hook({ sessionID: "interactive-session" }, output);

      assert.equal(output.env.AIDEVOPS_VERSION, undefined);
    } finally {
      process.chdir(previousCwd);
      rmSync(root, { recursive: true, force: true });
    }
  });
});

test("shell env hook with blank agentsDir does not read VERSION from process cwd", async () => {
  await withCleanHeadlessProcessEnv(async () => {
    const root = mkdtempSync(join(tmpdir(), "aidevops-shell-env-blank-cwd-"));
    const previousCwd = process.cwd();
    try {
      writeFileSync(join(root, "VERSION"), "9.9.9-cwd\n");
      process.chdir(root);

      const hook = makeHookForAgentsDir("   ");
      const output = { env: { PATH: "/usr/bin:/bin" } };

      await hook({ sessionID: "interactive-session" }, output);

      assert.equal(output.env.AIDEVOPS_VERSION, undefined);
    } finally {
      process.chdir(previousCwd);
      rmSync(root, { recursive: true, force: true });
    }
  });
});
