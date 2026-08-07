// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {invokeAdapterRead} from "../team-interface-adapter-runtime.mjs";
import {
  builtInAdapterRegistry,
  validateAdapterDefinition,
} from "../team-interface-adapters.mjs";
import {createMatrixAdapter} from "../team-interface-matrix-adapter.mjs";
import {createRuntimeValidators} from "../team-interface-validators.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");
const temporaryParent = process.env.AIDEVOPS_TEMP_DIR
  || path.join(os.homedir(), ".aidevops/.agent-workspace/tmp");
const currentUid = typeof process.getuid === "function" ? process.getuid() : null;
const observedAt = "2026-08-07T00:30:00.000Z";

function ensureDirectory(directoryPath) {
  fs.mkdirSync(directoryPath, {mode: 0o700, recursive: true});
}

function writeFile(filePath, content, mode) {
  fs.writeFileSync(filePath, content, {mode});
  fs.chmodSync(filePath, mode);
}

function readFixture() {
  return JSON.parse(fs.readFileSync(path.join(fixtureDirectory, "matrix-config.json"), "utf8"));
}

function writeConfig(filePath, value, mode = 0o600) {
  writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, mode);
}

function adapterContext(signal) {
  return Object.freeze({
    documents: Object.freeze({}),
    runtime: Object.freeze({abort_signal: signal, read_only: true, schema_version: 1}),
    settings_ref: "settings:matrix-fixture",
  });
}

function capability(observation, capabilityId) {
  return observation.capabilities.find(({capability_id: id}) => id === capabilityId);
}

function makeAdapter(configPath, pidPath, overrides = {}) {
  return createMatrixAdapter({
    configPath,
    currentUid,
    now: () => observedAt,
    pidPath,
    processExists: (pid) => pid === 4242,
    ...overrides,
  });
}

ensureDirectory(temporaryParent);
const sandbox = fs.mkdtempSync(path.join(temporaryParent, "team-interface-matrix-"));
const configDirectory = path.join(sandbox, "config");
const dataDirectory = path.join(sandbox, "data");
const configPath = path.join(configDirectory, "matrix-bot.json");
const pidPath = path.join(dataDirectory, "bot.pid");
const validators = createRuntimeValidators();

try {
  ensureDirectory(configDirectory);
  ensureDirectory(dataDirectory);
  writeConfig(configPath, readFixture());
  writeFile(pidPath, "4242\n", 0o600);
  const configBefore = fs.readFileSync(configPath);
  const pidBefore = fs.readFileSync(pidPath);
  const adapter = makeAdapter(configPath, pidPath);

  validateAdapterDefinition(adapter);
  assert.deepEqual(Object.keys(adapter).sort(), [
    "adapter_id",
    "adapter_version",
    "capabilities",
    "detect",
    "provider_id",
    "status",
  ]);
  assert.deepEqual(builtInAdapterRegistry.ids(), ["adapter.buzz", "adapter.matrix"]);
  assert.equal(builtInAdapterRegistry.get("adapter.matrix").provider_id, "matrix");

  const detected = await adapter.detect(adapterContext(new AbortController().signal));
  assert.equal(validators.adapterObservation(detected), true, JSON.stringify(validators.adapterObservation.errors));
  assert.equal(detected.adapter_id, "adapter.matrix");
  assert.equal(detected.provider_id, "matrix");
  assert.equal(detected.provider_version, "unprobed");
  assert.equal(detected.availability, "available");
  assert.equal(detected.compatibility.state, "unknown");
  assert.equal(capability(detected, "capability.matrix.events.receive").availability, "available");
  assert.equal(detected.inventory.communities.length, 1);
  assert.equal(detected.inventory.agents.length, 0);
  assert.equal(detected.inventory.teams.length, 0);
  assert.equal(detected.inventory.runtimes.length, 3);
  assert.deepEqual(
    detected.inventory.runtimes.map(({runtime_id: id}) => id),
    [...detected.inventory.runtimes.map(({runtime_id: id}) => id)].sort(),
  );

  const serialized = JSON.stringify(detected);
  for (const forbidden of [
    "matrix-fixture.example.invalid",
    "MATRIX_ACCESS_TOKEN_CANARY",
    "@owner:fixture.invalid",
    "!room-alpha:fixture.invalid",
    "runner-alpha-canary",
    "runner-beta-canary",
    "MATRIX_PATH_CANARY",
    "MATRIX_ERROR_CANARY",
    configPath,
    pidPath,
    "settings:matrix-fixture",
  ]) assert.equal(serialized.includes(forbidden), false, `${forbidden} escaped Matrix projection`);

  const status = await adapter.status(adapterContext(new AbortController().signal));
  assert.deepEqual(status, detected);
  const invoked = await invokeAdapterRead(
    "detect",
    {adapter, settings_ref: "settings:matrix-fixture"},
    {},
    validators,
    {timeoutMs: 1000},
  );
  assert.deepEqual(invoked, detected);
  assert.deepEqual(fs.readFileSync(configPath), configBefore);
  assert.deepEqual(fs.readFileSync(pidPath), pidBefore);

  const openPolicy = readFixture();
  openPolicy.allowedUsers = "";
  writeConfig(configPath, openPolicy);
  const degraded = await adapter.detect(adapterContext(new AbortController().signal));
  assert.equal(degraded.availability, "degraded");
  assert.equal(capability(degraded, "capability.matrix.events.receive").availability, "degraded");
  writeConfig(configPath, readFixture());

  const stopped = await makeAdapter(configPath, pidPath, {processExists: () => false}).detect(
    adapterContext(new AbortController().signal),
  );
  assert.equal(stopped.availability, "degraded");
  assert.equal(capability(stopped, "capability.matrix.events.receive").availability, "unavailable");
  assert.equal(stopped.inventory.runtimes.some(({availability}) => availability === "unavailable"), true);

  fs.chmodSync(configPath, 0o644);
  const insecure = await adapter.detect(adapterContext(new AbortController().signal));
  assert.equal(insecure.availability, "degraded");
  assert.deepEqual(insecure.inventory.communities, []);
  fs.chmodSync(configPath, 0o600);

  writeFile(configPath, "{malformed", 0o600);
  const malformed = await adapter.detect(adapterContext(new AbortController().signal));
  assert.equal(malformed.availability, "degraded");
  assert.deepEqual(malformed.inventory.runtimes, []);
  writeConfig(configPath, readFixture());

  const missing = await makeAdapter(path.join(sandbox, "missing.json"), pidPath).detect(
    adapterContext(new AbortController().signal),
  );
  assert.equal(missing.availability, "unavailable");
  assert.deepEqual(missing.inventory, {agents: [], communities: [], runtimes: [], teams: []});

  const targetPath = `${configPath}.target`;
  fs.renameSync(configPath, targetPath);
  fs.symlinkSync(targetPath, configPath);
  const symlinked = await adapter.detect(adapterContext(new AbortController().signal));
  assert.equal(symlinked.availability, "degraded");
  assert.deepEqual(symlinked.inventory.communities, []);
  fs.unlinkSync(configPath);
  fs.renameSync(targetPath, configPath);

  const aborted = new AbortController();
  aborted.abort();
  await assert.rejects(adapter.detect(adapterContext(aborted.signal)), /aborted/iu);

  let timeoutSignalAborted = false;
  const hanging = makeAdapter(configPath, pidPath, {
    readConfig: async (_configPath, _dependencies, signal) => new Promise((resolve, reject) => {
      signal.addEventListener("abort", () => {
        timeoutSignalAborted = true;
        const error = new Error("synthetic Matrix read aborted");
        error.name = "AbortError";
        error.code = "ABORT_ERR";
        reject(error);
      }, {once: true});
    }),
  });
  await assert.rejects(
    invokeAdapterRead(
      "detect",
      {adapter: hanging, settings_ref: "settings:matrix-fixture"},
      {},
      validators,
      {timeoutMs: 20},
    ),
    (error) => error?.code === "adapter_timeout",
  );
  assert.equal(timeoutSignalAborted, true);

  console.log("team-interface Matrix adapter tests passed");
} finally {
  fs.rmSync(sandbox, {force: true, recursive: true});
}
