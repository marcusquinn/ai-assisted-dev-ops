// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const agentsDirectory = path.join(repositoryRoot, ".agents");
const runtimeHelper = path.join(agentsDirectory, "scripts/team-interface-buzz-runtime.py");
const runtimeWrapper = path.join(agentsDirectory, "bin/aidevops-buzz-acp");
const interactiveRuntimeWrapper = path.join(
  agentsDirectory,
  "bin/aidevops-buzz-acp-interactive",
);
const snapshotGenerator = path.join(
  agentsDirectory,
  "scripts/team-interface-buzz-team-snapshot.py",
);
const canonicalManifest = path.join(
  agentsDirectory,
  "configs/buzz-runtime-aidevops-conversation-v1.json",
);
const interactiveCanonicalManifest = path.join(
  agentsDirectory,
  "configs/buzz-runtime-aidevops-interactive-v1.json",
);
const opencodeNodeModules = path.join(os.homedir(), ".config/opencode/node_modules");

function runHelper(argumentsList, options = {}) {
  return spawnSync("python3", [runtimeHelper, ...argumentsList], {
    encoding: "utf8",
    ...options,
  });
}

function requireSuccess(result, label) {
  assert.equal(result.status, 0, `${label} failed:\n${result.stderr}`);
  return result;
}

const fixtureRoot = fs.realpathSync(
  fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-buzz-runtime-")),
);
try {
  const fixtureHome = path.join(fixtureRoot, "home");
  const projectRoot = path.join(fixtureRoot, "project");
  const appDataDirectory = path.join(fixtureRoot, "buzz-data");
  const reposPath = path.join(fixtureRoot, "repos.json");
  fs.mkdirSync(fixtureHome, {recursive: true, mode: 0o700});
  const fixtureConfigDirectory = path.join(fixtureHome, ".config/opencode");
  const fixtureCommandDirectory = path.join(fixtureConfigDirectory, "command");
  fs.mkdirSync(fixtureCommandDirectory, {recursive: true, mode: 0o700});
  fs.writeFileSync(
    path.join(fixtureConfigDirectory, "opencode.json"),
    `${JSON.stringify({
      agent: {"Build+": {prompt: "{file:~/.aidevops/agents/prompts/build.txt}"}},
      instructions: ["~/.aidevops/agents/AGENTS.md"],
      mcp: {
        privateFixture: {
          command: ["fixture-mcp"],
          environment: {FIXTURE_ACCESS_TOKEN: "synthetic-sensitive-value"},
          headers: {Authorization: "synthetic-sensitive-value"},
          type: "local",
        },
      },
      plugin: ["file:///mutable/opencode-aidevops/index.mjs"],
      provider: {
        fixture: {
          options: {
            apiKey: "synthetic-sensitive-value",
            auth: "synthetic-sensitive-value",
            baseURL: "https://example.invalid/v1",
            headers: {"X-Provider-Token": "synthetic-sensitive-value"},
            monkey: "retained-noncredential-field",
            refreshToken: "synthetic-sensitive-value",
            secretAccessKey: "synthetic-sensitive-value",
            signingKey: "synthetic-sensitive-value",
          },
        },
      },
    })}\n`,
    {mode: 0o600},
  );
  fs.writeFileSync(
    path.join(fixtureCommandDirectory, "fixture.md"),
    "Read {file:~/.aidevops/agents/AGENTS.md}.\n",
    {mode: 0o600},
  );
  const stableBinDirectory = path.join(fixtureHome, ".aidevops/bin");
  const stableRuntimeCommand = path.join(stableBinDirectory, "aidevops-buzz-acp");
  const stableInteractiveRuntimeCommand = path.join(
    stableBinDirectory,
    "aidevops-buzz-acp-interactive",
  );
  fs.mkdirSync(stableBinDirectory, {recursive: true, mode: 0o700});
  fs.symlinkSync(runtimeWrapper, stableRuntimeCommand);
  fs.symlinkSync(interactiveRuntimeWrapper, stableInteractiveRuntimeCommand);
  fs.mkdirSync(projectRoot, {mode: 0o700});
  requireSuccess(
    spawnSync("/usr/bin/git", ["-C", projectRoot, "init", "--quiet"], {encoding: "utf8"}),
    "fixture Git initialization",
  );
  fs.writeFileSync(reposPath, `${JSON.stringify({
    git_parent_dirs: [],
    initialized_repos: [{path: projectRoot, slug: "example/project"}],
  })}\n`);

  const deployedAgentsDirectory = path.join(fixtureRoot, "deployed-bundle/agents");
  const deployedFrameworkModules = path.join(deployedAgentsDirectory, "node_modules");
  const deployedOpenCodeConfig = path.join(fixtureRoot, "deployed-opencode-config");
  const deployedOpenCodeModules = path.join(deployedOpenCodeConfig, "node_modules");
  const frameworkPackages = [
    "ajv", "fast-deep-equal", "fast-uri", "json-schema-traverse", "require-from-string",
  ];
  for (const packageName of frameworkPackages) {
    const packageRoot = path.join(deployedFrameworkModules, packageName);
    fs.mkdirSync(packageRoot, {recursive: true, mode: 0o700});
    fs.writeFileSync(path.join(packageRoot, "package.json"), `${JSON.stringify({
      name: packageName,
      version: "1.0.0",
    })}\n`);
  }
  for (const [packageName, manifest] of Object.entries({
    "@opencode-ai/plugin": {
      dependencies: {"@opencode-ai/sdk": "1.2.21", zod: "4.1.8"},
      name: "@opencode-ai/plugin",
      version: "1.2.21",
    },
    "@opencode-ai/sdk": {name: "@opencode-ai/sdk", version: "1.2.21"},
    zod: {name: "zod", version: "4.1.8"},
  })) {
    const packageRoot = path.join(deployedOpenCodeModules, packageName);
    fs.mkdirSync(packageRoot, {recursive: true, mode: 0o700});
    fs.writeFileSync(path.join(packageRoot, "package.json"), `${JSON.stringify(manifest)}\n`);
  }
  const deployedResolution = requireSuccess(spawnSync("python3", [
    "-c",
    [
      "import json, sys",
      "from pathlib import Path",
      `sys.path.insert(0, ${JSON.stringify(path.join(agentsDirectory, "scripts"))})`,
      "import _team_interface_buzz_runtime_anchor as anchor",
      "anchor.AGENTS_DIR = Path(sys.argv[1])",
      "sources = anchor.pinned_node_package_sources(Path(sys.argv[2]))",
      "print(json.dumps({name: str(source) for name, source in sources.items()}, sort_keys=True))",
    ].join("; "),
    deployedAgentsDirectory,
    deployedOpenCodeConfig,
  ], {
    encoding: "utf8",
    env: Object.fromEntries(
      Object.entries(process.env).filter(([name]) => name !== "AIDEVOPS_BUZZ_OPENCODE_NODE_MODULES_DIR"),
    ),
  }), "deployed runtime dependency resolution");
  const deployedSources = JSON.parse(deployedResolution.stdout);
  for (const packageName of frameworkPackages) {
    assert.equal(
      deployedSources[packageName],
      path.join(deployedFrameworkModules, packageName),
      `deployed runtime did not resolve ${packageName} from agents/node_modules`,
    );
  }

  const deployedPluginDirectory = path.join(
    deployedAgentsDirectory,
    "plugins/opencode-aidevops",
  );
  const deployedInteractiveCommand = path.join(
    deployedAgentsDirectory,
    "bin/aidevops-buzz-acp-interactive",
  );
  fs.mkdirSync(deployedPluginDirectory, {recursive: true, mode: 0o700});
  fs.mkdirSync(path.dirname(deployedInteractiveCommand), {recursive: true, mode: 0o700});
  fs.writeFileSync(path.join(deployedPluginDirectory, "index.mjs"), "export default {};\n");
  fs.writeFileSync(deployedInteractiveCommand, "#!/usr/bin/env bash\nexit 0\n", {mode: 0o700});
  fs.symlinkSync(
    deployedOpenCodeModules,
    path.join(deployedPluginDirectory, "node_modules"),
  );
  const deployedMaterialization = requireSuccess(spawnSync("python3", [
    "-c",
    [
      "import sys",
      "from pathlib import Path",
      `sys.path.insert(0, ${JSON.stringify(path.join(agentsDirectory, "scripts"))})`,
      "import _team_interface_buzz_runtime_anchor as anchor",
      "anchor.AGENTS_DIR = Path(sys.argv[1])",
      "profile = {'command': 'aidevops-buzz-acp-interactive', 'id': 'aidevops-interactive-v1'}",
      "print(anchor.materialize_pinned_runtime(profile))",
    ].join("; "),
    deployedAgentsDirectory,
  ], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIDEVOPS_BUZZ_OPENCODE_NODE_MODULES_DIR: deployedOpenCodeModules,
      HOME: fixtureHome,
    },
  }), "deployed runtime materialization with generated dependency symlink");
  const deployedRuntimeAnchor = deployedMaterialization.stdout.trim();
  assert.equal(
    fs.existsSync(path.join(
      deployedRuntimeAnchor,
      "agents/plugins/opencode-aidevops/node_modules",
    )),
    false,
    "generated deployed dependency symlink was copied into the immutable anchor",
  );
  requireSuccess(
    runHelper(["verify-anchor", "--root", deployedRuntimeAnchor, "--runtime", "interactive"], {
      env: {...process.env, HOME: fixtureHome},
    }),
    "deployed runtime standalone anchor verification",
  );
  const injectedAnchorDependencyLink = path.join(
    deployedRuntimeAnchor,
    "agents/plugins/opencode-aidevops/node_modules",
  );
  fs.symlinkSync(deployedOpenCodeModules, injectedAnchorDependencyLink);
  const injectedAnchorVerification = runHelper([
    "verify-anchor", "--root", deployedRuntimeAnchor, "--runtime", "interactive",
  ], {env: {...process.env, HOME: fixtureHome}});
  assert.notEqual(injectedAnchorVerification.status, 0);
  assert.match(injectedAnchorVerification.stderr, /absolute symbolic link/);
  fs.rmSync(injectedAnchorDependencyLink);
  const unrelatedAbsoluteTarget = path.join(fixtureRoot, "unrelated-absolute-target");
  const unrelatedAbsoluteLink = path.join(deployedAgentsDirectory, "unrelated-absolute-link");
  fs.mkdirSync(unrelatedAbsoluteTarget, {mode: 0o700});
  fs.symlinkSync(unrelatedAbsoluteTarget, unrelatedAbsoluteLink);
  const unsafeDeployedMaterialization = spawnSync("python3", [
    "-c",
    [
      "import sys",
      "from pathlib import Path",
      `sys.path.insert(0, ${JSON.stringify(path.join(agentsDirectory, "scripts"))})`,
      "import _team_interface_buzz_runtime_anchor as anchor",
      "anchor.AGENTS_DIR = Path(sys.argv[1])",
      "profile = {'command': 'aidevops-buzz-acp-interactive', 'id': 'aidevops-interactive-v1'}",
      "anchor.materialize_pinned_runtime(profile)",
    ].join("; "),
    deployedAgentsDirectory,
  ], {
    encoding: "utf8",
    env: {
      ...process.env,
      AIDEVOPS_BUZZ_OPENCODE_NODE_MODULES_DIR: deployedOpenCodeModules,
      HOME: fixtureHome,
    },
  });
  assert.notEqual(unsafeDeployedMaterialization.status, 0);
  assert.match(unsafeDeployedMaterialization.stderr, /absolute symbolic link/);
  fs.rmSync(unrelatedAbsoluteLink);

  const sourceManifest = JSON.parse(fs.readFileSync(canonicalManifest, "utf8"));
  assert.deepEqual(Object.keys(sourceManifest).sort(), [
    "args", "command", "env", "id", "installHint", "installInstructionsUrl", "label",
  ]);
  assert.deepEqual(sourceManifest.env, {}, "canonical manifest must stay machine-neutral");
  assert.equal(sourceManifest.command, "aidevops-buzz-acp");
  assert.equal(sourceManifest.id, "aidevops-conversation-v1");
  assert.equal(sourceManifest.label, "Aidevops Restricted Conversation V1");
  assert.equal(sourceManifest.installInstructionsUrl, "https://aidevops.sh/docs");

  const interactiveSourceManifest = JSON.parse(
    fs.readFileSync(interactiveCanonicalManifest, "utf8"),
  );
  assert.equal(interactiveSourceManifest.command, "aidevops-buzz-acp-interactive");
  assert.equal(interactiveSourceManifest.id, "aidevops-interactive-v1");
  assert.equal(interactiveSourceManifest.label, "Aidevops Full Interactive V1");
  assert.deepEqual(interactiveSourceManifest.env, {});

  const materialized = requireSuccess(
    runHelper(["manifest", "--project-root", projectRoot, "--repos", reposPath], {
      env: {...process.env, HOME: fixtureHome},
    }),
    "runtime manifest materialization",
  );
  const materializedManifest = JSON.parse(materialized.stdout);
  assert.equal(materializedManifest.command, stableRuntimeCommand);
  assert.deepEqual(materializedManifest.env, {
    AIDEVOPS_BUZZ_PROJECT_ROOT: projectRoot,
    BUZZ_ACP_CWD: projectRoot,
  });
  assert.equal(materializedManifest.args.length, 0);
  assert.equal(materializedManifest.installInstructionsUrl, "https://aidevops.sh/docs");

  const interactiveMaterialized = requireSuccess(
    runHelper([
      "manifest",
      "--runtime",
      "interactive",
      "--project-root",
      projectRoot,
      "--repos",
      reposPath,
    ], {env: {...process.env, HOME: fixtureHome}}),
    "interactive runtime manifest materialization",
  );
  const interactiveMaterializedManifest = JSON.parse(interactiveMaterialized.stdout);
  assert.equal(interactiveMaterializedManifest.command, stableInteractiveRuntimeCommand);
  assert.equal(interactiveMaterializedManifest.id, "aidevops-interactive-v1");
  assert.deepEqual(interactiveMaterializedManifest.env, {
    AIDEVOPS_BUZZ_PROJECT_ROOT: projectRoot,
    BUZZ_ACP_CWD: projectRoot,
  });

  const installEnvironment = {
    ...process.env,
    AIDEVOPS_BUZZ_RUNNING_OVERRIDE: "false",
    AIDEVOPS_BUZZ_OPENCODE_NODE_MODULES_DIR: opencodeNodeModules,
    HOME: fixtureHome,
  };
  requireSuccess(
    runHelper([
      "install",
      "--project-root",
      projectRoot,
      "--repos",
      reposPath,
      "--app-data-dir",
      appDataDirectory,
    ], {env: installEnvironment}),
    "runtime installation",
  );
  const installedPath = path.join(
    appDataDirectory,
    "custom_harnesses/aidevops-conversation-v1.json",
  );
  assert.equal(fs.statSync(installedPath).mode & 0o777, 0o600);
  assert.deepEqual(JSON.parse(fs.readFileSync(installedPath, "utf8")), materializedManifest);

  requireSuccess(
    runHelper([
      "install",
      "--runtime",
      "interactive",
      "--project-root",
      projectRoot,
      "--repos",
      reposPath,
      "--app-data-dir",
      appDataDirectory,
    ], {env: installEnvironment}),
    "interactive runtime installation",
  );
  const installedInteractivePath = path.join(
    appDataDirectory,
    "custom_harnesses/aidevops-interactive-v1.json",
  );
  assert.equal(fs.statSync(installedInteractivePath).mode & 0o777, 0o600);
  const installedInteractiveManifest = JSON.parse(
    fs.readFileSync(installedInteractivePath, "utf8"),
  );
  assert.notEqual(installedInteractiveManifest.command, stableInteractiveRuntimeCommand);
  assert.match(installedInteractiveManifest.command, /\/\.aidevops\/buzz-runtimes\/aidevops-interactive-v1\//);
  assert.equal(fs.realpathSync(installedInteractiveManifest.command), installedInteractiveManifest.command);
  const runtimeAnchor = installedInteractiveManifest.env.AIDEVOPS_BUZZ_AGENTS_DIR.replace(/\/agents$/, "");
  assert.equal(installedInteractiveManifest.command, path.join(
    runtimeAnchor,
    "agents/bin/aidevops-buzz-acp-interactive",
  ));
  assert.deepEqual(installedInteractiveManifest.env, {
    AIDEVOPS_BUZZ_AGENTS_DIR: path.join(runtimeAnchor, "agents"),
    AIDEVOPS_BUZZ_PROJECT_ROOT: projectRoot,
    AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME: "1",
    BUZZ_ACP_CWD: projectRoot,
  });
  const anchorMarker = JSON.parse(fs.readFileSync(
    path.join(runtimeAnchor, "buzz-runtime-anchor-v1.json"),
    "utf8",
  ));
  assert.equal(anchorMarker.runtime_id, "aidevops-interactive-v1");
  assert.equal(anchorMarker.schema_version, 2);
  assert.match(anchorMarker.agents_digest, /^[a-f0-9]{64}$/);
  assert.match(anchorMarker.config_digest, /^[a-f0-9]{64}$/);
  assert.match(anchorMarker.content_digest, /^[a-f0-9]{64}$/);
  const pinnedConfig = JSON.parse(fs.readFileSync(
    path.join(runtimeAnchor, "opencode-config/opencode/opencode.json"),
    "utf8",
  ));
  assert.deepEqual(pinnedConfig.plugin, [
    `file://${path.join(runtimeAnchor, "agents/plugins/opencode-aidevops/index.mjs")}`,
  ]);
  assert.deepEqual(
    pinnedConfig.mcp.privateFixture,
    {command: ["fixture-mcp"], type: "local"},
    "pinned MCP definitions must omit persisted environment and headers",
  );
  assert.deepEqual(
    pinnedConfig.provider.fixture.options,
    {baseURL: "https://example.invalid/v1", monkey: "retained-noncredential-field"},
    "pinned provider definitions must omit persisted credential fields",
  );
  assert.doesNotMatch(
    JSON.stringify(pinnedConfig),
    /synthetic-sensitive-value/,
    "pinned OpenCode config retained a fixture credential value",
  );
  for (const packageName of [
    "@opencode-ai/plugin",
    "@opencode-ai/sdk",
    "ajv",
    "zod",
  ]) {
    assert.ok(
      fs.existsSync(path.join(runtimeAnchor, "node_modules", packageName, "package.json")),
      `pinned runtime omitted ${packageName}`,
    );
  }
  assert.equal(
    pinnedConfig.agent["Build+"].prompt,
    `{file:${path.join(runtimeAnchor, "agents/prompts/build.txt")}}`,
  );
  assert.equal(
    fs.readFileSync(path.join(runtimeAnchor, "opencode-config/opencode/command/fixture.md"), "utf8"),
    `Read {file:${path.join(runtimeAnchor, "agents/AGENTS.md")}}.\n`,
  );
  requireSuccess(
    runHelper(["verify-anchor", "--root", runtimeAnchor, "--runtime", "interactive"], {
      env: installEnvironment,
    }),
    "standalone runtime anchor verification",
  );

  const assertAnchorTamperRejected = (targetPath, mutate, label) => {
    const original = fs.readFileSync(targetPath);
    try {
      mutate(targetPath);
      const result = runHelper([
        "install",
        "--runtime",
        "interactive",
        "--project-root",
        projectRoot,
        "--repos",
        reposPath,
        "--app-data-dir",
        appDataDirectory,
      ], {env: installEnvironment});
      assert.notEqual(result.status, 0, `${label} tamper was accepted`);
      assert.match(result.stderr, /content drifted|content digest drifted/);
      const standalone = runHelper([
        "verify-anchor", "--root", runtimeAnchor, "--runtime", "interactive",
      ], {env: installEnvironment});
      assert.notEqual(standalone.status, 0, `${label} tamper passed standalone verification`);
      assert.match(standalone.stderr, /content drifted|content digest drifted/);
    } finally {
      fs.writeFileSync(targetPath, original);
    }
  };
  assertAnchorTamperRejected(
    path.join(runtimeAnchor, "agents/private-local-ai.md"),
    (targetPath) => fs.appendFileSync(targetPath, "\nfixture tamper\n"),
    "agent",
  );
  assertAnchorTamperRejected(
    path.join(runtimeAnchor, "node_modules/zod/package.json"),
    (targetPath) => fs.appendFileSync(targetPath, " "),
    "dependency",
  );
  assertAnchorTamperRejected(
    path.join(runtimeAnchor, "opencode-config/opencode/opencode.json"),
    (targetPath) => {
      const value = JSON.parse(fs.readFileSync(targetPath, "utf8"));
      value.provider.fixture.options.baseURL = "https://tampered.invalid/v1";
      fs.writeFileSync(targetPath, `${JSON.stringify(value)}\n`);
    },
    "config",
  );
  assertAnchorTamperRejected(
    path.join(runtimeAnchor, "opencode-config/opencode/command/fixture.md"),
    (targetPath) => fs.appendFileSync(targetPath, "fixture tamper\n"),
    "command",
  );

  const idempotent = runHelper([
    "install",
    "--project-root",
    projectRoot,
    "--repos",
    reposPath,
    "--app-data-dir",
    appDataDirectory,
  ], {env: installEnvironment});
  assert.equal(idempotent.status, 0, idempotent.stderr);

  fs.writeFileSync(installedPath, `${JSON.stringify({...materializedManifest, label: "Local edit"})}\n`, {
    mode: 0o600,
  });
  const collision = runHelper([
    "install",
    "--project-root",
    projectRoot,
    "--repos",
    reposPath,
    "--app-data-dir",
    appDataDirectory,
  ], {env: installEnvironment});
  assert.notEqual(collision.status, 0);
  assert.match(collision.stderr, /different content/);
  assert.equal(JSON.parse(fs.readFileSync(installedPath, "utf8")).label, "Local edit");

  requireSuccess(
    runHelper([
      "install",
      "--project-root",
      projectRoot,
      "--repos",
      reposPath,
      "--app-data-dir",
      appDataDirectory,
      "--replace",
    ], {env: installEnvironment}),
    "explicit runtime replacement",
  );
  assert.deepEqual(JSON.parse(fs.readFileSync(installedPath, "utf8")), materializedManifest);
  assert.equal(
    fs.readdirSync(path.join(fixtureHome, ".aidevops/buzz-backups")).length,
    1,
    "replacement must retain one private rollback copy",
  );

  const symlinkPayload = path.join(fixtureRoot, "symlink-payload.json");
  fs.writeFileSync(symlinkPayload, fs.readFileSync(installedPath), {mode: 0o600});
  fs.rmSync(installedPath);
  fs.symlinkSync(symlinkPayload, installedPath);
  const symlinkCollision = runHelper([
    "install",
    "--project-root",
    projectRoot,
    "--repos",
    reposPath,
    "--app-data-dir",
    appDataDirectory,
  ], {env: installEnvironment});
  assert.notEqual(symlinkCollision.status, 0);
  assert.match(symlinkCollision.stderr, /not a regular file/);
  assert.equal(fs.lstatSync(installedPath).isSymbolicLink(), true);
  fs.rmSync(installedPath);
  requireSuccess(
    runHelper([
      "install",
      "--project-root",
      projectRoot,
      "--repos",
      reposPath,
      "--app-data-dir",
      appDataDirectory,
    ], {env: installEnvironment}),
    "runtime restoration after symlink refusal",
  );

  const unsafeHome = path.join(fixtureRoot, "unsafe-home");
  const divertedBackups = path.join(fixtureRoot, "diverted-backups");
  fs.mkdirSync(path.join(unsafeHome, ".aidevops/bin"), {recursive: true, mode: 0o700});
  fs.symlinkSync(runtimeWrapper, path.join(unsafeHome, ".aidevops/bin/aidevops-buzz-acp"));
  fs.mkdirSync(divertedBackups, {mode: 0o700});
  fs.symlinkSync(divertedBackups, path.join(unsafeHome, ".aidevops/buzz-backups"));
  fs.writeFileSync(installedPath, `${JSON.stringify({...materializedManifest, label: "Unsafe backup"})}\n`, {
    mode: 0o600,
  });
  const unsafeBackup = runHelper([
    "install",
    "--project-root",
    projectRoot,
    "--repos",
    reposPath,
    "--app-data-dir",
    appDataDirectory,
    "--replace",
  ], {env: {...installEnvironment, HOME: unsafeHome}});
  assert.notEqual(unsafeBackup.status, 0);
  assert.match(unsafeBackup.stderr, /backup directory must not be a symbolic link/);
  assert.equal(JSON.parse(fs.readFileSync(installedPath, "utf8")).label, "Unsafe backup");
  requireSuccess(
    runHelper([
      "install",
      "--project-root",
      projectRoot,
      "--repos",
      reposPath,
      "--app-data-dir",
      appDataDirectory,
      "--replace",
    ], {env: installEnvironment}),
    "runtime restoration after unsafe backup refusal",
  );

  const unsafeAnchorHome = path.join(fixtureRoot, "unsafe-anchor-home");
  const divertedAnchors = path.join(fixtureRoot, "diverted-anchors");
  fs.mkdirSync(path.join(unsafeAnchorHome, ".aidevops/bin"), {recursive: true, mode: 0o700});
  fs.mkdirSync(path.join(unsafeAnchorHome, ".config"), {recursive: true, mode: 0o700});
  fs.cpSync(fixtureConfigDirectory, path.join(unsafeAnchorHome, ".config/opencode"), {
    recursive: true,
  });
  fs.symlinkSync(runtimeWrapper, path.join(unsafeAnchorHome, ".aidevops/bin/aidevops-buzz-acp"));
  fs.symlinkSync(
    interactiveRuntimeWrapper,
    path.join(unsafeAnchorHome, ".aidevops/bin/aidevops-buzz-acp-interactive"),
  );
  fs.mkdirSync(divertedAnchors, {mode: 0o700});
  fs.symlinkSync(divertedAnchors, path.join(unsafeAnchorHome, ".aidevops/buzz-runtimes"));
  const unsafeAnchor = runHelper([
    "install",
    "--runtime",
    "interactive",
    "--project-root",
    projectRoot,
    "--repos",
    reposPath,
    "--app-data-dir",
    path.join(fixtureRoot, "unsafe-anchor-app-data"),
  ], {env: {...installEnvironment, HOME: unsafeAnchorHome}});
  assert.notEqual(unsafeAnchor.status, 0);
  assert.match(unsafeAnchor.stderr, /anchor directory chain is unsafe/);
  assert.deepEqual(fs.readdirSync(divertedAnchors), [], "symlinked ancestor received runtime content");

  const prepareDirectory = path.join(fixtureRoot, "prepared");
  fs.mkdirSync(prepareDirectory, {mode: 0o700});
  const liveSnapshotResult = requireSuccess(
    spawnSync("python3", [snapshotGenerator, "generate", "--agents-dir", agentsDirectory], {
      encoding: "utf8",
      env: {...process.env, AIDEVOPS_BUZZ_HOST_SLUG: "test-host-01"},
    }),
    "canonical snapshot generation for runtime evidence",
  );
  const buildPrompt = JSON.parse(liveSnapshotResult.stdout).members.find(
    ({profile}) => profile.displayName === "build-plus-test-host-01",
  ).definition.systemPrompt;
  const buzzEnvironment = {
    ...process.env,
    AIDEVOPS_BUZZ_HOST_SLUG: "test-host-01",
    BUZZ_ACP_ALLOWED_RESPOND_TO: "owner-only",
    BUZZ_ACP_AGENT_OWNER: "fixture-owner",
    BUZZ_ACP_CWD: projectRoot,
    BUZZ_ACP_DISPLAY_NAME: "build-plus-test-host-01",
    BUZZ_ACP_MODEL: "inherited/default-model-must-not-cross-boundary",
    BUZZ_ACP_RESPOND_TO: "owner-only",
    BUZZ_ACP_SYSTEM_PROMPT: buildPrompt,
    BUZZ_MANAGED_AGENT: "xyz.block.buzz.app",
    BUZZ_MANAGED_AGENT_START_NONCE: "0123456789abcdef0123456789abcdef",
    BUZZ_RELAY_URL: "wss://relay.invalid",
  };
  requireSuccess(
    runHelper([
      "prepare",
      "--agents-dir",
      agentsDirectory,
      "--output-dir",
      prepareDirectory,
    ], {env: buzzEnvironment}),
    "restricted launch preparation",
  );
  assert.equal(fs.readFileSync(path.join(prepareDirectory, "agent-id.txt"), "utf8").trim(), "agent.build-plus");
  const contextText = fs.readFileSync(path.join(prepareDirectory, "context.json"), "utf8");
  const context = JSON.parse(contextText);
  assert.equal(context.provider_ref, "provider:buzz");
  assert.equal(context.trust_ref, "trust:buzz-owner-only");
  assert.doesNotMatch(contextText, /fixture-owner|relay\.invalid|0123456789abcdef/);
  assert.equal(fs.readFileSync(path.join(prepareDirectory, "host-slug.txt"), "utf8").trim(), "test-host-01");
  for (const filename of ["agent-id.txt", "context.json", "host-slug.txt", "roster.json"]) {
    assert.equal(fs.statSync(path.join(prepareDirectory, filename)).mode & 0o777, 0o600);
  }

  const rejectedPrepare = runHelper([
    "prepare",
    "--agents-dir",
    agentsDirectory,
    "--output-dir",
    prepareDirectory,
  ], {env: {...buzzEnvironment, BUZZ_ACP_RESPOND_TO: "anyone"}});
  assert.notEqual(rejectedPrepare.status, 0);
  assert.match(rejectedPrepare.stderr, /owner-only/);

  const mismatchedPrompt = runHelper([
    "prepare",
    "--agents-dir",
    agentsDirectory,
    "--output-dir",
    prepareDirectory,
  ], {env: {...buzzEnvironment, BUZZ_ACP_SYSTEM_PROMPT: `${buildPrompt}\nDrifted`}});
  assert.notEqual(mismatchedPrompt.status, 0);
  assert.match(mismatchedPrompt.stderr, /source pointer or digest/);

  const mismatchedHost = runHelper([
    "prepare",
    "--agents-dir",
    agentsDirectory,
    "--output-dir",
    prepareDirectory,
  ], {env: {...buzzEnvironment, BUZZ_ACP_DISPLAY_NAME: "build-plus-other-host"}});
  assert.notEqual(mismatchedHost.status, 0);
  assert.match(mismatchedHost.stderr, /does not select exactly one/);

  const wrapperTemp = path.join(fixtureRoot, "wrapper-temp");
  const launcherLog = path.join(fixtureRoot, "launcher.log");
  const capturedOverlay = path.join(fixtureRoot, "captured-overlay.json");
  const mockLauncher = path.join(fixtureRoot, "mock-launcher.sh");
  fs.mkdirSync(wrapperTemp, {mode: 0o700});
  fs.writeFileSync(mockLauncher, `#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "conversation" && "$2" == "--overlay" && "$4" == "--dir" ]]
[[ -z "\${BUZZ_ACP_CWD+x}" ]]
[[ -z "\${BUZZ_ACP_MODEL+x}" ]]
cp "$3" "$MOCK_CAPTURED_OVERLAY"
printf '%s\\n' "$*" >"$MOCK_LAUNCHER_LOG"
`);
  fs.chmodSync(mockLauncher, 0o700);
  const wrapped = spawnSync(runtimeWrapper, [], {
    encoding: "utf8",
    env: {
      ...buzzEnvironment,
      AIDEVOPS_BUZZ_AGENTS_DIR: agentsDirectory,
      AIDEVOPS_BUZZ_CLI: mockLauncher,
      AIDEVOPS_BUZZ_LAUNCHER: mockLauncher,
      AIDEVOPS_BUZZ_PROJECT_ROOT: projectRoot,
      AIDEVOPS_BUZZ_TEMP_DIR: wrapperTemp,
      HOME: fixtureHome,
      MOCK_CAPTURED_OVERLAY: capturedOverlay,
      MOCK_LAUNCHER_LOG: launcherLog,
    },
  });
  assert.equal(wrapped.status, 0, wrapped.stderr);
  assert.equal(wrapped.stdout, "", "wrapper must reserve stdout for ACP only");
  const overlay = JSON.parse(fs.readFileSync(capturedOverlay, "utf8"));
  assert.equal(overlay.agent.agent_id, "agent.build-plus");
  assert.equal(overlay.permission_profile, "conversation_read_only_v1");
  assert.match(fs.readFileSync(launcherLog, "utf8"), /conversation --overlay .* --dir/);
  assert.deepEqual(fs.readdirSync(wrapperTemp), [], "wrapper leaked private launch material");

  const missingCwdEnvironment = {...buzzEnvironment};
  delete missingCwdEnvironment.BUZZ_ACP_CWD;
  const legacyCwdWrapper = spawnSync(runtimeWrapper, [], {
    encoding: "utf8",
    env: {
      ...missingCwdEnvironment,
      AIDEVOPS_BUZZ_AGENTS_DIR: agentsDirectory,
      AIDEVOPS_BUZZ_CLI: mockLauncher,
      AIDEVOPS_BUZZ_LAUNCHER: mockLauncher,
      AIDEVOPS_BUZZ_PROJECT_ROOT: projectRoot,
      AIDEVOPS_BUZZ_TEMP_DIR: wrapperTemp,
      HOME: fixtureHome,
      MOCK_CAPTURED_OVERLAY: capturedOverlay,
      MOCK_LAUNCHER_LOG: launcherLog,
    },
  });
  assert.equal(legacyCwdWrapper.status, 0, legacyCwdWrapper.stderr);

  const mismatchedCwdWrapper = spawnSync(runtimeWrapper, [], {
    encoding: "utf8",
    env: {
      ...buzzEnvironment,
      AIDEVOPS_BUZZ_AGENTS_DIR: agentsDirectory,
      AIDEVOPS_BUZZ_CLI: mockLauncher,
      AIDEVOPS_BUZZ_LAUNCHER: mockLauncher,
      AIDEVOPS_BUZZ_PROJECT_ROOT: projectRoot,
      AIDEVOPS_BUZZ_TEMP_DIR: wrapperTemp,
      BUZZ_ACP_CWD: fixtureRoot,
      HOME: fixtureHome,
    },
  });
  assert.notEqual(mismatchedCwdWrapper.status, 0);
  assert.match(mismatchedCwdWrapper.stderr, /working directory does not match/);

  const rejectedWrapper = spawnSync(runtimeWrapper, [], {
    encoding: "utf8",
    env: {
      ...buzzEnvironment,
      AIDEVOPS_BUZZ_AGENTS_DIR: agentsDirectory,
      AIDEVOPS_BUZZ_CLI: mockLauncher,
      AIDEVOPS_BUZZ_LAUNCHER: mockLauncher,
      AIDEVOPS_BUZZ_PROJECT_ROOT: projectRoot,
      AIDEVOPS_BUZZ_TEMP_DIR: wrapperTemp,
      BUZZ_ACP_RESPOND_TO: "anyone",
      HOME: fixtureHome,
    },
  });
  assert.notEqual(rejectedWrapper.status, 0);
  assert.match(rejectedWrapper.stderr, /owner-only/);

  const interactiveLauncher = path.join(fixtureRoot, "mock-interactive-launcher.sh");
  const interactiveWorktree = path.join(fixtureRoot, "mock-worktree.sh");
  const interactiveOverlay = path.join(fixtureRoot, "interactive-overlay.json");
  const interactiveLauncherLog = path.join(fixtureRoot, "interactive-launcher.log");
  fs.writeFileSync(interactiveWorktree, `#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "resolve" && "$2" == "${projectRoot}" && "$3" == "build-plus" ]]
printf '%s\\n' "${projectRoot}"
`);
  fs.chmodSync(interactiveWorktree, 0o700);
  fs.writeFileSync(interactiveLauncher, `#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "remote-interactive" && "$2" == "--overlay" && "$4" == "--dir" && "$6" == "--session-id" ]]
[[ -z "\${BUZZ_PRIVATE_KEY+x}" ]]
[[ -z "\${BUZZ_RELAY_URL+x}" ]]
[[ -z "\${BUZZ_ACP_SYSTEM_PROMPT+x}" ]]
[[ -z "\${AIDEVOPS_BUZZ_PROJECT_ROOT+x}" ]]
[[ -z "\${NOSTR_PRIVATE_KEY+x}" ]]
cp "$3" "$MOCK_INTERACTIVE_OVERLAY"
printf '%s\\n' "$*" >"$MOCK_INTERACTIVE_LAUNCHER_LOG"
`);
  fs.chmodSync(interactiveLauncher, 0o700);
  const interactiveWrapped = spawnSync(interactiveRuntimeWrapper, [], {
    encoding: "utf8",
    env: {
      ...buzzEnvironment,
      AIDEVOPS_BUZZ_AGENTS_DIR: agentsDirectory,
      AIDEVOPS_BUZZ_CLI: interactiveLauncher,
      AIDEVOPS_BUZZ_LAUNCHER: interactiveLauncher,
      AIDEVOPS_BUZZ_PROJECT_ROOT: projectRoot,
      AIDEVOPS_BUZZ_TEMP_DIR: wrapperTemp,
      AIDEVOPS_BUZZ_WORKTREE_HELPER: interactiveWorktree,
      BUZZ_PRIVATE_KEY: "fixture-private-key",
      HOME: fixtureHome,
      MOCK_INTERACTIVE_LAUNCHER_LOG: interactiveLauncherLog,
      MOCK_INTERACTIVE_OVERLAY: interactiveOverlay,
      NOSTR_PRIVATE_KEY: "fixture-nostr-private-key",
    },
  });
  assert.equal(interactiveWrapped.status, 0, interactiveWrapped.stderr);
  assert.equal(interactiveWrapped.stdout, "", "interactive wrapper must reserve stdout for ACP only");
  const fullOverlay = JSON.parse(fs.readFileSync(interactiveOverlay, "utf8"));
  assert.equal(fullOverlay.agent.agent_id, "agent.build-plus");
  assert.equal(fullOverlay.permission_profile, "remote_interactive_v1");
  assert.match(
    fs.readFileSync(interactiveLauncherLog, "utf8"),
    /remote-interactive --overlay .* --dir .* --session-id test-host-01-build-plus/,
  );
  assert.deepEqual(fs.readdirSync(wrapperTemp), [], "interactive wrapper leaked private launch material");
} finally {
  fs.rmSync(fixtureRoot, {recursive: true, force: true});
}

console.log("PASS: aidevops Buzz runtime manifests and restricted launch overlays fail closed");
