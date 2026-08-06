// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {
  builtInAdapterRegistry,
  validateAdapterDefinition,
} from "../team-interface-adapters.mjs";
import {invokeAdapterRead} from "../team-interface-adapter-runtime.mjs";
import {createBuzzAdapter} from "../team-interface-buzz-adapter.mjs";
import {executeBoundedFile} from "../team-interface-buzz-command.mjs";
import {withSafeFile} from "../team-interface-buzz-safe-read.mjs";
import {withSqliteSnapshot} from "../team-interface-buzz-snapshot.mjs";
import {createRuntimeValidators} from "../team-interface-validators.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");
const currentUid = typeof process.getuid === "function" ? process.getuid() : null;
const observedAt = "2026-08-06T05:30:00.000Z";
const communities = [
  {
    id: "community-primary",
    name: "Primary Community",
    relayUrl: "wss://relay.example.test",
    token: "COMMUNITY_TOKEN_CANARY",
    pubkey: "COMMUNITY_PUBKEY_CANARY",
    reposDir: "/private/source/COMMUNITY_REPO_ROOT_CANARY",
    nsec: "COMMUNITY_NSEC_CANARY",
  },
  {
    id: "community-secondary",
    name: "Secondary Community",
    relayUrl: "wss://second.example.test/",
    token: "SECOND_COMMUNITY_TOKEN_CANARY",
  },
];

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function ensureDirectory(directoryPath, mode = 0o700) {
  fs.mkdirSync(directoryPath, {mode, recursive: true});
}

function writeFile(filePath, content, mode) {
  fs.writeFileSync(filePath, content, {mode});
  fs.chmodSync(filePath, mode);
}

function writeJson(filePath, value, mode) {
  writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, mode);
}

function makeLayout(root, includeStores = true) {
  const appPath = path.join(root, "Applications/Buzz.app");
  const appDataPath = path.join(root, "Library/Application Support/xyz.block.buzz.app");
  const webkitRoot = path.join(root, "Library/WebKit/xyz.block.buzz.app/WebsiteData");
  const appContents = path.join(appPath, "Contents");
  ensureDirectory(appContents);
  writeFile(path.join(appContents, "Info.plist"), "synthetic plist fixture\n", 0o644);
  if (includeStores) {
    const agentsDirectory = path.join(appDataPath, "agents");
    const databaseDirectory = path.join(webkitRoot, "LocalStorage");
    ensureDirectory(agentsDirectory);
    ensureDirectory(databaseDirectory);
    writeJson(
      path.join(agentsDirectory, "managed-agents.json"),
      readJson(path.join(fixtureDirectory, "buzz-managed-agents.json")),
      0o600,
    );
    writeJson(
      path.join(agentsDirectory, "teams.json"),
      readJson(path.join(fixtureDirectory, "buzz-teams.json")),
      0o644,
    );
    writeFile(path.join(databaseDirectory, "localstorage.sqlite3"), "synthetic sqlite fixture\n", 0o600);
  }
  return {appPath, appDataPath, webkitRoot};
}

function makeExecutor(calls, options = {}) {
  const version = options.version || "0.5.5";
  const sqliteOutput = options.sqliteOutput
    ?? Buffer.from(JSON.stringify(communities), options.utf16 === false ? "utf8" : "utf16le").toString("hex");
  return async (command, argumentsList, executionOptions) => {
    calls.push({argumentsList: [...argumentsList], command});
    assert.equal(executionOptions.signal instanceof AbortSignal, true, "child reads must receive the runtime abort signal");
    if (command === "/usr/bin/plutil") {
      assert.equal(argumentsList.at(-1), "/dev/fd/3");
      assert.equal(Number.isSafeInteger(executionOptions.sourceFd), true);
      return {stderr: "", stdout: `${version}\n`};
    }
    if (command === "/usr/bin/sqlite3") {
      assert.deepEqual(argumentsList.slice(0, 3), ["-readonly", "-batch", "-noheader"]);
      assert.equal(executionOptions.sourceFd, undefined);
      assert.equal(argumentsList[3], "localstorage.sqlite3");
      assert.match(executionOptions.cwd, /buzz-sqlite-/u);
      const snapshotPath = path.join(executionOptions.cwd, argumentsList[3]);
      for (const [suffix, expected] of Object.entries(options.expectedSqliteSidecars || {})) {
        assert.deepEqual(fs.readFileSync(`${snapshotPath}${suffix}`), expected);
      }
      assert.match(argumentsList.at(-1), /WHERE key = 'buzz-communities'/u);
      return {stderr: "", stdout: `${sqliteOutput}\n`};
    }
    throw new Error(`unexpected executable: ${command}`);
  };
}

function adapterContext(signal) {
  return Object.freeze({
    documents: Object.freeze({}),
    runtime: Object.freeze({abort_signal: signal, read_only: true, schema_version: 1}),
    settings_ref: "settings:buzz-fixture",
  });
}

function makeAdapter(paths, executeFile, overrides = {}) {
  const snapshotRoot = snapshotRootFor(paths);
  ensureDirectory(snapshotRoot);
  return createBuzzAdapter({
    ...paths,
    currentUid,
    executeFile,
    now: () => observedAt,
    platform: "darwin",
    processExists: (pid) => pid === 4242,
    snapshotRoot,
    ...overrides,
  });
}

function snapshotRootFor(paths) {
  return path.join(path.dirname(path.dirname(paths.appPath)), "snapshots");
}

function capability(observation, capabilityId) {
  return observation.capabilities.find(({capability_id: id}) => id === capabilityId);
}

function assertCanonicalInventory(inventory) {
  for (const [collection, property] of [
    [inventory.communities, "community_id"],
    [inventory.agents, "agent_id"],
    [inventory.teams, "team_id"],
    [inventory.runtimes, "runtime_id"],
  ]) {
    const ids = collection.map((record) => record[property]);
    assert.deepEqual(ids, [...ids].sort(), `${property} inventory is not canonical`);
    assert.equal(new Set(ids).size, ids.length, `${property} inventory contains duplicates`);
  }
  for (const team of inventory.teams) {
    assert.deepEqual(team.member_agent_ids, [...team.member_agent_ids].sort());
  }
}

function snapshotSources(paths) {
  return snapshotFiles([
    path.join(paths.appPath, "Contents/Info.plist"),
    path.join(paths.appDataPath, "agents/managed-agents.json"),
    path.join(paths.appDataPath, "agents/teams.json"),
    path.join(paths.webkitRoot, "LocalStorage/localstorage.sqlite3"),
  ]);
}

function snapshotFiles(filePaths) {
  return filePaths.map((filePath) => ({
    bytes: fs.readFileSync(filePath),
    filePath,
    mode: fs.statSync(filePath).mode & 0o777,
    modified: fs.statSync(filePath).mtimeMs,
  }));
}

async function observeDuringSwapAndRestore(paths, databasePath) {
  const original = fs.readFileSync(databasePath);
  const mode = fs.statSync(databasePath).mode & 0o777;
  const backupPath = `${databasePath}.transient-original`;
  const substituted = [{id: "substituted", name: "Substituted Community"}];
  const baseExecutor = makeExecutor([]);
  const replacingExecutor = async (command, argumentsList, executionOptions) => {
    if (command !== "/usr/bin/sqlite3") return baseExecutor(command, argumentsList, executionOptions);
    fs.renameSync(databasePath, backupPath);
    writeFile(databasePath, "substituted sqlite fixture\n", mode);
    try {
      const selectedPath = path.join(executionOptions.cwd, argumentsList[3]);
      const selected = fs.readFileSync(selectedPath, "utf8").includes("substituted")
        ? substituted
        : communities;
      const stdout = Buffer.from(JSON.stringify(selected), "utf16le").toString("hex");
      return {stderr: "", stdout: `${stdout}\n`};
    } finally {
      fs.unlinkSync(databasePath);
      fs.renameSync(backupPath, databasePath);
    }
  };
  const observation = await makeAdapter(paths, replacingExecutor).detect(
    adapterContext(new AbortController().signal),
  );
  assert.deepEqual(fs.readFileSync(databasePath), original);
  return observation;
}

async function startWalWriter(databasePath, records) {
  const writer = spawn("/usr/bin/sqlite3", ["-batch", databasePath], {stdio: ["pipe", "pipe", "pipe"]});
  const payloadHex = Buffer.from(JSON.stringify(records), "utf16le").toString("hex");
  let stderr = "";
  writer.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  const ready = new Promise((resolve, reject) => {
    let stdout = "";
    const timer = setTimeout(() => reject(new Error(`SQLite WAL fixture timed out: ${stderr}`)), 5000);
    writer.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (!stdout.includes("BUZZ_WAL_READY")) return;
      clearTimeout(timer);
      resolve();
    });
    writer.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    writer.once("close", (code) => {
      clearTimeout(timer);
      if (!stdout.includes("BUZZ_WAL_READY")) reject(new Error(`SQLite WAL fixture exited ${code}: ${stderr}`));
    });
  });
  writer.stdin.write([
    "PRAGMA journal_mode=WAL;",
    "PRAGMA wal_autocheckpoint=0;",
    "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);",
    `INSERT INTO ItemTable(key, value) VALUES('buzz-communities', X'${payloadHex}');`,
    ".print BUZZ_WAL_READY",
    "",
  ].join("\n"));
  await ready;
  return writer;
}

async function stopWalWriter(writer) {
  const closed = new Promise((resolve) => writer.once("close", resolve));
  writer.stdin.end(".quit\n");
  await closed;
}

function assertSourcesUnchanged(snapshots) {
  for (const snapshot of snapshots) {
    assert.deepEqual(fs.readFileSync(snapshot.filePath), snapshot.bytes, `${snapshot.filePath} content changed`);
    assert.equal(fs.statSync(snapshot.filePath).mode & 0o777, snapshot.mode, `${snapshot.filePath} mode changed`);
    assert.equal(fs.statSync(snapshot.filePath).mtimeMs, snapshot.modified, `${snapshot.filePath} mtime changed`);
  }
}

async function observeDuringFileReplacement(paths, filePath, command) {
  const original = fs.readFileSync(filePath);
  const mode = fs.statSync(filePath).mode & 0o777;
  const backupPath = `${filePath}.race-original`;
  const baseExecutor = makeExecutor([]);
  let replaced = false;
  const replacingExecutor = async (...argumentsList) => {
    if (!replaced && argumentsList[0] === command) {
      fs.renameSync(filePath, backupPath);
      writeFile(filePath, original, mode);
      replaced = true;
    }
    return baseExecutor(...argumentsList);
  };
  try {
    return await makeAdapter(paths, replacingExecutor).detect(adapterContext(new AbortController().signal));
  } finally {
    if (replaced) {
      fs.unlinkSync(filePath);
      fs.renameSync(backupPath, filePath);
    }
  }
}

const temporaryParent = process.env.AIDEVOPS_TEMP_DIR
  || path.join(os.homedir(), ".aidevops/.agent-workspace/tmp");
ensureDirectory(temporaryParent);
const sandbox = fs.mkdtempSync(path.join(temporaryParent, "team-interface-buzz-"));
const validators = createRuntimeValidators();

try {
  const paths = makeLayout(path.join(sandbox, "valid"));
  const sourceSnapshots = snapshotSources(paths);
  const calls = [];
  const adapter = makeAdapter(paths, makeExecutor(calls));
  validateAdapterDefinition(adapter);
  assert.deepEqual(Object.keys(adapter).sort(), [
    "adapter_id",
    "adapter_version",
    "capabilities",
    "detect",
    "provider_id",
    "status",
  ]);
  assert.deepEqual(builtInAdapterRegistry.ids(), ["adapter.buzz"]);
  assert.equal(builtInAdapterRegistry.get("adapter.buzz").provider_id, "buzz");

  const detectedController = new AbortController();
  const detected = await adapter.detect(adapterContext(detectedController.signal));
  assert.equal(validators.adapterObservation(detected), true, JSON.stringify(validators.adapterObservation.errors));
  assert.equal(detected.adapter_id, "adapter.buzz");
  assert.equal(detected.provider_id, "buzz");
  assert.equal(detected.provider_version, "0.5.5");
  assert.equal(detected.availability, "available");
  assert.equal(detected.compatibility.state, "compatible");
  assert.equal(detected.inventory.communities.length, 2);
  assert.equal(detected.inventory.agents.length, 3);
  assert.equal(detected.inventory.teams.length, 2);
  assert.equal(detected.inventory.runtimes.length, 2);
  assertCanonicalInventory(detected.inventory);

  const communityIds = new Set(detected.inventory.communities.map(({community_id: id}) => id));
  const runtimeIds = new Set(detected.inventory.runtimes.map(({runtime_id: id}) => id));
  const teamIds = new Set(detected.inventory.teams.map(({team_id: id}) => id));
  const agentIds = new Set(detected.inventory.agents.map(({agent_id: id}) => id));
  for (const agent of detected.inventory.agents) {
    if (agent.community_id) assert.equal(communityIds.has(agent.community_id), true);
    if (agent.runtime_id) assert.equal(runtimeIds.has(agent.runtime_id), true);
    if (agent.team_id) assert.equal(teamIds.has(agent.team_id), true);
  }
  for (const team of detected.inventory.teams) {
    for (const memberId of team.member_agent_ids) assert.equal(agentIds.has(memberId), true);
  }
  assert.equal(detected.inventory.agents.find(({display_label: label}) => label === "Fizz Worker").availability, "available");
  assert.equal(detected.inventory.agents.find(({display_label: label}) => label === "Honey Worker").availability, "unavailable");
  assert.deepEqual(new Set(detected.inventory.runtimes.map(({display_label: label}) => label)), new Set(["goose", "opencode"]));

  const forbiddenValues = [
    "SECRET_NSEC_CANARY",
    "AUTH_TAG_CANARY",
    "ENV_VALUE_CANARY",
    "PROMPT_CANARY",
    "MODEL_CANARY",
    "PROVIDER_CANARY",
    "COMMAND_CANARY",
    "ARG_CANARY",
    "ERROR_CANARY",
    "PATH_CANARY",
    "REPO_ROOT_CANARY",
    "INSTRUCTION_CANARY",
    "COMMUNITY_TOKEN_CANARY",
    "COMMUNITY_PUBKEY_CANARY",
    "COMMUNITY_REPO_ROOT_CANARY",
    "settings:buzz-fixture",
  ];
  const serialized = JSON.stringify(detected);
  for (const forbidden of forbiddenValues) assert.equal(serialized.includes(forbidden), false, `${forbidden} escaped projection`);

  const statusController = new AbortController();
  const status = await adapter.status(adapterContext(statusController.signal));
  assert.deepEqual(status, detected, "detect and status must project equivalent read-only observations");
  const invoked = await invokeAdapterRead(
    "detect",
    {adapter, settings_ref: "settings:buzz-fixture"},
    {},
    validators,
    {timeoutMs: 1000},
  );
  assert.deepEqual(invoked, detected, "runtime invocation must accept the normalized inventory");
  assertSourcesUnchanged(sourceSnapshots);
  assert.deepEqual(fs.readdirSync(snapshotRootFor(paths)), [], "private SQLite snapshots must be removed");
  assert.equal(calls.length, 6, "each observation should perform one plist read and one SQLite read");
  assert.equal(calls.every(({command}) => ["/usr/bin/plutil", "/usr/bin/sqlite3"].includes(command)), true);
  assert.equal(calls.some(({command}) => /Buzz|buzz-acp|npm|cargo|auth/iu.test(command)), false);

  const unknownVersion = await makeAdapter(paths, makeExecutor([], {version: "0.6.0"})).detect(
    adapterContext(new AbortController().signal),
  );
  assert.equal(unknownVersion.provider_version, "0.6.0");
  assert.equal(unknownVersion.compatibility.state, "unknown");

  let unsupportedCalls = 0;
  const unsupported = await createBuzzAdapter({
    ...paths,
    currentUid,
    executeFile: async () => {
      unsupportedCalls += 1;
      throw new Error("unsupported platform executed a child");
    },
    now: () => observedAt,
    platform: "linux",
  }).detect(adapterContext(new AbortController().signal));
  assert.equal(unsupported.availability, "unavailable");
  assert.equal(unsupported.compatibility.state, "unsupported");
  assert.deepEqual(unsupported.inventory, {agents: [], communities: [], runtimes: [], teams: []});
  assert.equal(unsupportedCalls, 0);

  let missingCalls = 0;
  const missing = await createBuzzAdapter({
    appPath: path.join(sandbox, "missing/Buzz.app"),
    appDataPath: path.join(sandbox, "missing/app-data"),
    currentUid,
    executeFile: async () => {
      missingCalls += 1;
      throw new Error("missing installation executed a child");
    },
    now: () => observedAt,
    platform: "darwin",
    webkitRoot: path.join(sandbox, "missing/webkit"),
  }).detect(adapterContext(new AbortController().signal));
  assert.equal(missing.availability, "unavailable");
  assert.equal(missing.compatibility.state, "unknown");
  assert.equal(missingCalls, 0);

  const appOnlyPaths = makeLayout(path.join(sandbox, "app-only"), false);
  const appOnly = await makeAdapter(appOnlyPaths, makeExecutor([])).detect(adapterContext(new AbortController().signal));
  assert.equal(appOnly.availability, "degraded");
  assert.equal(capability(appOnly, "capability.buzz.agents.read").availability, "unavailable");
  assert.equal(capability(appOnly, "capability.buzz.communities.read").availability, "unavailable");
  assert.equal(capability(appOnly, "capability.buzz.teams.read").availability, "unavailable");

  const managedAgentsPath = path.join(paths.appDataPath, "agents/managed-agents.json");
  const teamsPath = path.join(paths.appDataPath, "agents/teams.json");
  const plistPath = path.join(paths.appPath, "Contents/Info.plist");
  const databasePath = path.join(paths.webkitRoot, "LocalStorage/localstorage.sqlite3");
  const originalAgents = fs.readFileSync(managedAgentsPath);
  const originalTeams = fs.readFileSync(teamsPath);

  const descriptorController = new AbortController();
  const descriptorRead = await withSafeFile(
    managedAgentsPath,
    {
      currentUid,
      maxBytes: 10 * 1024 * 1024,
      policy: "private",
      signal: descriptorController.signal,
    },
    (sourceFd) => executeBoundedFile(
      "/bin/cat",
      ["/dev/fd/3"],
      {encoding: "utf8", maxBuffer: 10 * 1024 * 1024, signal: descriptorController.signal, sourceFd},
    ),
  );
  assert.deepEqual(Buffer.from(descriptorRead.stdout), originalAgents);

  const componentRaceRoot = path.join(sandbox, "component-race");
  const componentRaceDirectory = path.join(componentRaceRoot, "trusted");
  const componentRaceAlternate = path.join(componentRaceRoot, "alternate");
  const componentRaceBackup = path.join(componentRaceRoot, "trusted-original");
  const componentRacePath = path.join(componentRaceDirectory, "source.json");
  ensureDirectory(componentRaceDirectory);
  ensureDirectory(componentRaceAlternate);
  writeFile(componentRacePath, "trusted\n", 0o600);
  writeFile(path.join(componentRaceAlternate, "source.json"), "substituted\n", 0o600);
  let componentReaderCalled = false;
  let componentSwapped = false;
  try {
    await assert.rejects(
      withSafeFile(
        componentRacePath,
        {
          currentUid,
          maxBytes: 1024,
          openFile: async (filePath, flags) => {
            fs.renameSync(componentRaceDirectory, componentRaceBackup);
            fs.symlinkSync(componentRaceAlternate, componentRaceDirectory, "dir");
            componentSwapped = true;
            return fs.promises.open(filePath, flags);
          },
          policy: "private",
          signal: new AbortController().signal,
        },
        () => {
          componentReaderCalled = true;
          return "substituted";
        },
      ),
      (error) => error?.code === "unsafe_source",
    );
  } finally {
    if (componentSwapped) {
      fs.unlinkSync(componentRaceDirectory);
      fs.renameSync(componentRaceBackup, componentRaceDirectory);
    }
  }
  assert.equal(componentReaderCalled, false, "parent replacement must fail before exposing the descriptor");

  const snapshotRaceRoot = path.join(sandbox, "snapshot-root-race");
  const snapshotRaceAlternate = path.join(sandbox, "snapshot-root-alternate");
  const snapshotRaceBackup = path.join(sandbox, "snapshot-root-original");
  ensureDirectory(snapshotRaceRoot);
  ensureDirectory(snapshotRaceAlternate);
  let snapshotRaceOutput;
  let snapshotRaceOutputWasEmpty = false;
  let snapshotReaderCalled = false;
  let snapshotRootSwapped = false;
  try {
    await assert.rejects(
      withSqliteSnapshot(
        databasePath,
        {
          currentUid,
          makeTemporaryDirectory: async (prefix) => {
            fs.renameSync(snapshotRaceRoot, snapshotRaceBackup);
            fs.symlinkSync(snapshotRaceAlternate, snapshotRaceRoot, "dir");
            snapshotRootSwapped = true;
            snapshotRaceOutput = await fs.promises.mkdtemp(prefix);
            return snapshotRaceOutput;
          },
          maxBytes: 1024 * 1024,
          policy: "owned",
          signal: new AbortController().signal,
          snapshotRoot: snapshotRaceRoot,
        },
        () => {
          snapshotReaderCalled = true;
          return "substituted";
        },
      ),
      (error) => error?.code === "unsafe_source",
    );
  } finally {
    if (snapshotRootSwapped) {
      snapshotRaceOutputWasEmpty = fs.readdirSync(snapshotRaceOutput).length === 0;
      fs.rmdirSync(snapshotRaceOutput);
      fs.unlinkSync(snapshotRaceRoot);
      fs.renameSync(snapshotRaceBackup, snapshotRaceRoot);
    }
  }
  assert.equal(snapshotReaderCalled, false, "snapshot-root replacement must fail before copying provider data");
  assert.equal(snapshotRaceOutputWasEmpty, true, "unsafe cleanup paths must contain no provider snapshot");
  assert.deepEqual(fs.readdirSync(snapshotRaceAlternate), [], "failed snapshot-root races must clean empty output");

  const replacedPlist = await observeDuringFileReplacement(paths, plistPath, "/usr/bin/plutil");
  assert.equal(capability(replacedPlist, "capability.buzz.installation.read").availability, "degraded");
  assert.equal(replacedPlist.provider_version, "unknown");

  const replacedDatabase = await observeDuringFileReplacement(paths, databasePath, "/usr/bin/sqlite3");
  assert.equal(capability(replacedDatabase, "capability.buzz.communities.read").availability, "degraded");
  assert.deepEqual(replacedDatabase.inventory.communities, []);

  const transientReplacement = await observeDuringSwapAndRestore(paths, databasePath);
  assert.equal(capability(transientReplacement, "capability.buzz.communities.read").availability, "available");
  assert.equal(transientReplacement.inventory.communities.length, communities.length);
  assert.equal(
    transientReplacement.inventory.communities.some(({display_label: label}) => label === "Substituted Community"),
    false,
  );

  const walBytes = Buffer.from("synthetic WAL fixture\n");
  const shmBytes = Buffer.from("synthetic SHM fixture\n");
  writeFile(`${databasePath}-wal`, walBytes, 0o600);
  writeFile(`${databasePath}-shm`, shmBytes, 0o600);
  const sidecarObservation = await makeAdapter(
    paths,
    makeExecutor([], {expectedSqliteSidecars: {"-shm": shmBytes, "-wal": walBytes}}),
  ).detect(adapterContext(new AbortController().signal));
  assert.equal(capability(sidecarObservation, "capability.buzz.communities.read").availability, "available");
  fs.unlinkSync(`${databasePath}-wal`);
  fs.unlinkSync(`${databasePath}-shm`);

  if (fs.existsSync("/usr/bin/sqlite3")) {
    const walPaths = makeLayout(path.join(sandbox, "wal-backed"));
    const walDatabase = path.join(walPaths.webkitRoot, "LocalStorage/localstorage.sqlite3");
    fs.unlinkSync(walDatabase);
    const writer = await startWalWriter(walDatabase, communities);
    try {
      const walSourcePaths = [walDatabase, `${walDatabase}-wal`, `${walDatabase}-shm`];
      assert.equal(walSourcePaths.every((filePath) => fs.existsSync(filePath)), true);
      const walSnapshots = snapshotFiles(walSourcePaths);
      const plistExecutor = makeExecutor([]);
      const realSqliteExecutor = (command, argumentsList, executionOptions) => command === "/usr/bin/plutil"
        ? plistExecutor(command, argumentsList, executionOptions)
        : executeBoundedFile(command, argumentsList, executionOptions);
      const walObservation = await makeAdapter(walPaths, realSqliteExecutor).detect(
        adapterContext(new AbortController().signal),
      );
      assert.equal(capability(walObservation, "capability.buzz.communities.read").availability, "available");
      assert.equal(walObservation.inventory.communities.length, communities.length);
      assertSourcesUnchanged(walSnapshots);
      assert.deepEqual(fs.readdirSync(snapshotRootFor(walPaths)), []);
    } finally {
      await stopWalWriter(writer);
    }
  }

  writeFile(managedAgentsPath, "{malformed", 0o600);
  const malformed = await makeAdapter(paths, makeExecutor([])).detect(adapterContext(new AbortController().signal));
  assert.equal(capability(malformed, "capability.buzz.agents.read").availability, "degraded");
  assert.deepEqual(malformed.inventory.agents, []);
  writeFile(managedAgentsPath, originalAgents, 0o600);

  writeFile(teamsPath, Buffer.alloc((2 * 1024 * 1024) + 1, 32), 0o644);
  const oversized = await makeAdapter(paths, makeExecutor([])).detect(adapterContext(new AbortController().signal));
  assert.equal(capability(oversized, "capability.buzz.teams.read").availability, "degraded");
  assert.deepEqual(oversized.inventory.teams, []);
  writeFile(teamsPath, originalTeams, 0o644);

  const symlinkTarget = `${managedAgentsPath}.target`;
  fs.renameSync(managedAgentsPath, symlinkTarget);
  fs.symlinkSync(symlinkTarget, managedAgentsPath);
  const symlinked = await makeAdapter(paths, makeExecutor([])).detect(adapterContext(new AbortController().signal));
  assert.equal(capability(symlinked, "capability.buzz.agents.read").availability, "degraded");
  assert.deepEqual(symlinked.inventory.agents, []);
  fs.unlinkSync(managedAgentsPath);
  fs.renameSync(symlinkTarget, managedAgentsPath);

  fs.chmodSync(managedAgentsPath, 0o644);
  const insecure = await makeAdapter(paths, makeExecutor([])).detect(adapterContext(new AbortController().signal));
  assert.equal(capability(insecure, "capability.buzz.agents.read").availability, "degraded");
  assert.deepEqual(insecure.inventory.agents, []);
  fs.chmodSync(managedAgentsPath, 0o600);

  const malformedSqlite = await makeAdapter(paths, makeExecutor([], {sqliteOutput: "not-hex"})).detect(
    adapterContext(new AbortController().signal),
  );
  assert.equal(capability(malformedSqlite, "capability.buzz.communities.read").availability, "degraded");
  assert.deepEqual(malformedSqlite.inventory.communities, []);

  const abortedController = new AbortController();
  abortedController.abort();
  await assert.rejects(adapter.detect(adapterContext(abortedController.signal)), /aborted/iu);

  let timeoutSignalAborted = false;
  const hangingAdapter = makeAdapter(paths, async (_command, _argumentsList, executionOptions) => new Promise((_, reject) => {
    executionOptions.signal.addEventListener("abort", () => {
      timeoutSignalAborted = true;
      const error = new Error("synthetic child aborted");
      error.name = "AbortError";
      error.code = "ABORT_ERR";
      reject(error);
    }, {once: true});
  }));
  await assert.rejects(
    invokeAdapterRead(
      "detect",
      {adapter: hangingAdapter, settings_ref: "settings:buzz-fixture"},
      {},
      validators,
      {timeoutMs: 20},
    ),
    (error) => error?.code === "adapter_timeout",
  );
  assert.equal(timeoutSignalAborted, true, "runtime timeout must abort the adapter child read");

  console.log("team-interface Buzz adapter tests passed");
} finally {
  fs.rmSync(sandbox, {force: true, recursive: true});
}
