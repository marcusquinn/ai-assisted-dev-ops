// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";
import {
  canonicalDigest,
  createRuntimeValidators,
  generatePlan,
  loadRuntimeConfig,
  readRuntimeState,
  runDetect,
  runDoctor,
  runProviders,
  runStatus,
  runtimeStatePaths,
  writeRuntimeState,
} from "../team-interface-core.mjs";
import {
  builtInAdapterRegistry,
  createAdapterRegistry,
  selectConfiguredAdapters,
} from "../team-interface-adapters.mjs";
import {assertNoSecretValueProperties} from "./lib/team-interface-reconciliation-fixtures.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const fixtureDirectory = path.join(testDirectory, "fixtures/team-interface");
const helperScript = path.join(repositoryRoot, ".agents/scripts/team-interface-helper.sh");
const runtimeSchemaPath = path.join(repositoryRoot, ".agents/schemas/team-interface/runtime-v1.schema.json");

function readJson(filePath) {
  return JSON.parse(readText(filePath));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, {mode: 0o600});
}

function readText(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function fileStats(filePath) {
  return fs.statSync(filePath);
}

function ensureDirectory(directoryPath, options) {
  fs.mkdirSync(directoryPath, options);
}

function temporaryDirectory(prefix) {
  return fs.mkdtempSync(prefix);
}

function setFileTimes(filePath, time) {
  fs.utimesSync(filePath, time, time);
}

function pathExists(filePath) {
  return fs.existsSync(filePath);
}

function removePath(filePath, options) {
  fs.rmSync(filePath, options);
}

function copy(value) {
  return structuredClone(value);
}

function validationErrors(validate) {
  return JSON.stringify(validate.errors || [], null, 2);
}

function requireValid(validate, document, label) {
  assert.equal(validate(document), true, `${label} failed:\n${validationErrors(validate)}`);
}

function requireInvalid(validate, document, label) {
  assert.equal(validate(document), false, `${label} unexpectedly validated`);
}

function unsignedPlan(plan) {
  const unsigned = copy(plan);
  delete unsigned.plan_hash;
  return unsigned;
}

function readMode(filePath) {
  return fileStats(filePath).mode & 0o777;
}

function makeObservation(source, adapterId, providerId, capabilityId, providerVersion) {
  const observation = copy(source);
  observation.adapter_id = adapterId;
  observation.provider_id = providerId;
  observation.provider_version = providerVersion;
  observation.capabilities[0].capability_id = capabilityId;
  observation.evidence_refs = [`evidence:${adapterId}`];
  return observation;
}

function makeAdapter(observation, handlers = {}) {
  return {
    adapter_id: observation.adapter_id,
    adapter_version: observation.adapter_version,
    capabilities: copy(observation.capabilities),
    provider_id: observation.provider_id,
    async detect(context) {
      if (handlers.detect) return handlers.detect(context);
      return copy(observation);
    },
    async status(context) {
      if (handlers.status) return handlers.status(context);
      return copy(observation);
    },
  };
}

function runHelper(command, argumentsList = []) {
  return spawnSync(helperScript, [command, ...argumentsList], {
    cwd: repositoryRoot,
    encoding: "utf8",
    env: {...process.env},
  });
}

const validFixture = readJson(path.join(fixtureDirectory, "runtime-valid.json"));
const invalidFixture = readJson(path.join(fixtureDirectory, "runtime-invalid.json"));
const coreFixture = readJson(path.join(fixtureDirectory, "core-valid.json"));
const providerRegistry = coreFixture.documents.find(({document_type: type}) => type === "registry");
const runtimeSchema = readJson(runtimeSchemaPath);
const validators = createRuntimeValidators();

assert.deepEqual(builtInAdapterRegistry.ids(), ["adapter.buzz", "adapter.matrix"]);

function plannerOptions(policy = validFixture.ownership_policy) {
  return {policy, registry: providerRegistry, validators};
}

assert.equal(runtimeSchema.$schema, "https://json-schema.org/draft/2020-12/schema");
assert.equal(runtimeSchema.$id, "urn:aidevops:team-interface:runtime:v1");
assertNoSecretValueProperties(runtimeSchema);
for (const [label, document] of Object.entries({
  adapter_observation: validFixture.adapter_observation,
  plan_request: validFixture.plan_request,
  runtime_config: validFixture.runtime_config,
  runtime_state: validFixture.runtime_state,
})) requireValid(validators.runtime, document, label);
requireValid(validators.ownershipPolicy, validFixture.ownership_policy, "ownership policy");
for (const invalidCase of invalidFixture.cases) {
  requireInvalid(validators.runtime, invalidCase.document, invalidCase.label);
}
for (const [label, document] of Object.entries({
  invalid_observation_time: {
    ...copy(validFixture.adapter_observation),
    observed_at: "2026-02-30T20:00:00Z",
  },
  invalid_plan_time: {
    ...copy(validFixture.plan_request),
    created_at: "not-a-date",
  },
  invalid_state_time: {
    ...copy(validFixture.runtime_state),
    updated_at: "2026-13-01T20:00:00Z",
  },
})) requireInvalid(validators.runtime, document, label);

const missingObservedCapabilities = copy(validFixture.adapter_observation);
missingObservedCapabilities.capabilities = [];
requireInvalid(validators.adapterObservation, missingObservedCapabilities, "missing observed capabilities");

const inventoryObservation = copy(validFixture.adapter_observation);
inventoryObservation.inventory = {
  communities: [
    {community_id: "community.fixture", display_label: "Fixture community", availability: "available"},
  ],
  agents: [
    {
      agent_id: "agent.fixture.alpha",
      display_label: "Fixture definition",
      kind: "definition",
      built_in: true,
      availability: "available",
      community_id: "community.fixture",
      runtime_id: "runtime.fixture",
      team_id: "team.fixture",
    },
    {
      agent_id: "agent.fixture.zeta",
      display_label: "Fixture instance",
      kind: "managed_instance",
      built_in: false,
      availability: "unavailable",
      community_id: "community.fixture",
      runtime_id: "runtime.fixture",
      team_id: "team.fixture",
    },
  ],
  teams: [{
    team_id: "team.fixture",
    display_label: "Fixture team",
    built_in: false,
    availability: "available",
    member_agent_ids: ["agent.fixture.alpha", "agent.fixture.zeta"],
  }],
  runtimes: [{runtime_id: "runtime.fixture", display_label: "Fixture runtime", availability: "unknown"}],
};
requireValid(validators.adapterObservation, inventoryObservation, "provider-neutral inventory observation");
const incompleteInventory = copy(inventoryObservation);
delete incompleteInventory.inventory.runtimes;
requireInvalid(validators.adapterObservation, incompleteInventory, "incomplete provider-neutral inventory");
const openInventoryRecord = copy(inventoryObservation);
openInventoryRecord.inventory.agents[0].private_value = "not allowed";
requireInvalid(validators.adapterObservation, openInventoryRecord, "open provider-neutral inventory record");

const inlineTokenConfig = copy(validFixture.runtime_config);
inlineTokenConfig.adapters = [{adapter_id: "adapter.mock", settings_ref: "token:inline-secret"}];
requireInvalid(validators.runtimeConfig, inlineTokenConfig, "inline token-shaped adapter setting");

const firstPlan = generatePlan(validFixture.plan_request, plannerOptions());
const replayPlan = generatePlan(copy(validFixture.plan_request), plannerOptions());
assert.deepEqual(replayPlan, firstPlan, "identical plan requests must replay byte-for-byte");
assert.equal(firstPlan.outcome, "update");
assert.equal(firstPlan.field_decisions[0].decision, "apply_desired");
assert.equal(firstPlan.plan_hash, canonicalDigest(unsignedPlan(firstPlan)));
requireValid(validators.plan, firstPlan, "generated plan");

const orderedRequest = copy(validFixture.plan_request);
const orderedPolicy = copy(validFixture.ownership_policy);
orderedRequest.reconciliation_input.fields.push({
  actual: {
    data: {kind: "literal", value: "user label"},
    digest: "sha256:5555555555555555555555555555555555555555555555555555555555555555",
    present: true,
  },
  actual_observed_at: "2026-08-05T20:00:00Z",
  desired: {
    data: {kind: "literal", value: "desired label"},
    digest: "sha256:3333333333333333333333333333333333333333333333333333333333333333",
    present: true,
  },
  field_path: "/display_label",
  last_applied: {
    data: {kind: "literal", value: "old label"},
    digest: "sha256:4444444444444444444444444444444444444444444444444444444444444444",
    present: true,
  },
  ownership: "user_owned",
  sensitive: false,
});
orderedPolicy.field_rules.push({field_path: "/display_label", ownership: "user_owned", sensitive: false});
orderedRequest.capabilities.evidence_refs.push("capability:runtime-secondary");
orderedRequest.audit.evidence_refs.push("evidence:runtime-secondary");
const reorderedRequest = copy(orderedRequest);
reorderedRequest.reconciliation_input.fields.reverse();
reorderedRequest.capabilities.evidence_refs.reverse();
reorderedRequest.audit.evidence_refs.reverse();
assert.deepEqual(
  generatePlan(reorderedRequest, plannerOptions(orderedPolicy)),
  generatePlan(orderedRequest, plannerOptions(orderedPolicy)),
  "set-like input ordering must not change plan output",
);

const unicodeRequest = copy(validFixture.plan_request);
const unicodePolicy = copy(validFixture.ownership_policy);
for (const fieldPath of ["/ä", "/z"]) {
  unicodeRequest.reconciliation_input.fields.push({
    ...copy(unicodeRequest.reconciliation_input.fields[0]),
    field_path: fieldPath,
  });
  unicodePolicy.field_rules.push({...copy(unicodePolicy.field_rules[0]), field_path: fieldPath});
}
assert.deepEqual(
  generatePlan(unicodeRequest, plannerOptions(unicodePolicy)).field_decisions.map(({field_path: fieldPath}) => fieldPath),
  ["/enabled", "/z", "/ä"],
  "plan ordering must use locale-independent code-unit comparison",
);

const changedRequest = copy(validFixture.plan_request);
changedRequest.desired_version = "fixture-2";
const changedPlan = generatePlan(changedRequest, plannerOptions());
assert.notEqual(changedPlan.plan_hash, firstPlan.plan_hash, "changed plan input must change the plan hash");
assert.notEqual(changedPlan.operation_id, firstPlan.operation_id, "changed plan input must change stable IDs");

const fallbackRequest = copy(validFixture.plan_request);
fallbackRequest.capabilities.supported_apply = false;
fallbackRequest.capabilities.compatibility = "degraded";
const fallbackPlan = generatePlan(fallbackRequest, plannerOptions());
assert.equal(fallbackPlan.outcome, "owner_reviewed_draft");
assert.equal(Object.hasOwn(fallbackPlan, "management_binding"), false);

const securityRequest = copy(validFixture.plan_request);
const securityPolicy = copy(validFixture.ownership_policy);
securityRequest.reconciliation_input.fields[0].ownership = "security_required";
securityRequest.reconciliation_input.fields[0].actual.digest = "sha256:6666666666666666666666666666666666666666666666666666666666666666";
securityPolicy.field_rules[0].ownership = "security_required";
const securityPlan = generatePlan(securityRequest, plannerOptions(securityPolicy));
assert.equal(securityPlan.field_decisions[0].decision, "disable_execution");
assert.equal(securityPlan.outcome, "disable");

for (const ownership of ["managed", "security_required"]) {
  const missingLastAppliedRequest = copy(validFixture.plan_request);
  const missingLastAppliedPolicy = copy(validFixture.ownership_policy);
  missingLastAppliedRequest.reconciliation_input.fields[0].last_applied = {present: false};
  missingLastAppliedRequest.reconciliation_input.fields[0].ownership = ownership;
  missingLastAppliedPolicy.field_rules[0].ownership = ownership;
  assert.throws(
    () => generatePlan(missingLastAppliedRequest, plannerOptions(missingLastAppliedPolicy)),
    /last-applied snapshot/i,
  );
}

const shortCapabilityRequest = copy(validFixture.plan_request);
shortCapabilityRequest.capabilities.expires_at = shortCapabilityRequest.created_at;
assert.throws(
  () => generatePlan(shortCapabilityRequest, plannerOptions()),
  /capability evidence does not cover the plan lifetime/i,
);

const omittedSecurityPolicy = copy(validFixture.ownership_policy);
omittedSecurityPolicy.field_rules.push({field_path: "/security_mode", ownership: "security_required", sensitive: false});
assert.throws(
  () => generatePlan(validFixture.plan_request, plannerOptions(omittedSecurityPolicy)),
  /omits a configured ownership field/i,
);

const mismatchedResourceRequest = copy(validFixture.plan_request);
mismatchedResourceRequest.reconciliation_input.resource.provider_external_id = "conversation/unregistered";
assert.throws(
  () => generatePlan(mismatchedResourceRequest, plannerOptions()),
  /does not match registered provider_external_id/i,
);

let observedProviderVersion = "fixture-1";
let mutationCalls = 0;
const adapterCalls = [];
const mockAdapter = makeAdapter(validFixture.adapter_observation, {
  detect(context) {
    adapterCalls.push("detect");
    assert.equal(Object.isFrozen(context), true);
    assert.equal(Object.isFrozen(context.documents), true);
    assert.equal(context.runtime.read_only, true);
    assert.equal(context.runtime.abort_signal instanceof AbortSignal, true);
    assert.equal(context.runtime.abort_signal.aborted, false);
    return {...copy(validFixture.adapter_observation), provider_version: observedProviderVersion};
  },
  status(context) {
    adapterCalls.push("status");
    assert.equal(Object.isFrozen(context), true);
    return {...copy(validFixture.adapter_observation), provider_version: observedProviderVersion};
  },
});
const mockRegistry = createAdapterRegistry([mockAdapter]);
assert.equal(Object.isFrozen(mockAdapter), true);
assert.equal(Object.isFrozen(mockAdapter.capabilities), true);
assert.equal(Object.isFrozen(mockAdapter.capabilities[0]), true);
assert.equal(Object.isFrozen(mockAdapter.capabilities[0].operations), true);
assert.equal(Object.isFrozen(mockAdapter.capabilities[0].resource_kinds), true);
const preFrozenAdapter = makeAdapter(validFixture.adapter_observation);
Object.freeze(preFrozenAdapter);
createAdapterRegistry([preFrozenAdapter]);
assert.equal(Object.isFrozen(preFrozenAdapter.capabilities), true, "pre-frozen adapters must freeze nested capabilities");
assert.equal(Object.isFrozen(preFrozenAdapter.capabilities[0]), true, "pre-frozen adapters must freeze capability entries");
const selectedConfig = copy(validFixture.runtime_config);
selectedConfig.adapters = [{adapter_id: "adapter.mock", settings_ref: "settings:mock"}];
assert.equal(selectConfiguredAdapters(selectedConfig, mockRegistry)[0].adapter, mockAdapter);
assert.throws(
  () => selectConfiguredAdapters(
    {...selectedConfig, adapters: [{adapter_id: "adapter.unknown", settings_ref: "settings:unknown"}]},
    mockRegistry,
  ),
  /unknown configured adapter/i,
);
assert.throws(() => createAdapterRegistry([mockAdapter, mockAdapter]), /duplicate adapter/i);
assert.throws(
  () => createAdapterRegistry([{...makeAdapter(validFixture.adapter_observation), unknown_property: true}]),
  /unknown property/i,
);
assert.throws(
  () => createAdapterRegistry([{
    ...makeAdapter(validFixture.adapter_observation),
    capabilities: [{...copy(validFixture.adapter_observation.capabilities[0]), unknown_property: true}],
  }]),
  /capability contains unknown property/i,
);
assert.throws(
  () => createAdapterRegistry([{
    ...makeAdapter(validFixture.adapter_observation),
    capabilities: [
      copy(validFixture.adapter_observation.capabilities[0]),
      copy(validFixture.adapter_observation.capabilities[0]),
    ],
  }]),
  /duplicate capability IDs/i,
);
for (const capabilityOverride of [
  {availability: "sometimes"},
  {operations: ["read", "read"]},
  {owner_review_required: "false"},
  {resource_kinds: ["channel", "channel"]},
  {resource_kinds: ["filesystem"]},
]) {
  assert.throws(
    () => createAdapterRegistry([{
      ...makeAdapter(validFixture.adapter_observation),
      capabilities: [{...copy(validFixture.adapter_observation.capabilities[0]), ...capabilityOverride}],
    }]),
    /capability/i,
  );
}
assert.throws(
  () => createAdapterRegistry([{
    ...mockAdapter,
    create() {
      mutationCalls += 1;
    },
  }]),
  /forbidden mutation method/i,
);
assert.equal(mutationCalls, 0, "provider mutation traps must never be called");

const temporaryParent = process.env.AIDEVOPS_TEMP_DIR
  || path.join(os.homedir(), ".aidevops/.agent-workspace/tmp");
ensureDirectory(temporaryParent, {mode: 0o700, recursive: true});
const sandbox = temporaryDirectory(path.join(temporaryParent, "team-interface-runtime-"));

try {
  const casRoot = path.join(sandbox, "cas-state");
  const casPaths = runtimeStatePaths(casRoot);
  const stateOne = copy(validFixture.runtime_state);
  writeRuntimeState(stateOne, {expectedGeneration: 0, paths: casPaths, validators});
  assert.equal(readMode(casPaths.directory), 0o700);
  assert.equal(readMode(casPaths.statePath), 0o600);
  assert.equal(readRuntimeState({paths: casPaths, validators}).generation, 1);
  assert.throws(
    () => writeRuntimeState(stateOne, {expectedGeneration: 0, paths: casPaths, validators}),
    /generation changed/i,
  );

  writeJson(casPaths.lockPath, {
    created_at: "2020-01-01T00:00:00Z",
    host: os.hostname(),
    pid: process.pid,
    process_started_at: "",
    token: "live-owner",
  });
  setFileTimes(casPaths.lockPath, new Date(0));
  const stateTwo = {...copy(stateOne), generation: 2, updated_at: "2026-08-05T20:00:02Z"};
  assert.throws(
    () => writeRuntimeState(stateTwo, {
      expectedGeneration: 1,
      lockStaleMs: 1,
      lockTimeoutMs: 10,
      paths: casPaths,
      validators,
    }),
    /lock timed out/i,
  );
  assert.equal(pathExists(casPaths.lockPath), true, "live stale lock must not be deleted");
  removePath(casPaths.lockPath);

  writeJson(casPaths.lockPath, {
    created_at: "2020-01-01T00:00:00Z",
    host: os.hostname(),
    pid: 2147483647,
    process_started_at: "dead-owner",
    token: "abandoned-owner",
  });
  setFileTimes(casPaths.lockPath, new Date(0));
  ensureDirectory(`${casPaths.lockPath}.reclaim`, {mode: 0o700});
  assert.throws(
    () => writeRuntimeState(stateTwo, {
      expectedGeneration: 1,
      lockStaleMs: 1,
      lockTimeoutMs: 10,
      paths: casPaths,
      validators,
    }),
    /lock timed out/i,
  );
  assert.equal(pathExists(casPaths.lockPath), true, "serialized reclaimer must preserve the observed lock");
  removePath(`${casPaths.lockPath}.reclaim`, {recursive: true});
  writeRuntimeState(stateTwo, {
    expectedGeneration: 1,
    lockStaleMs: 1,
    lockTimeoutMs: 250,
    paths: casPaths,
    validators,
  });
  assert.equal(readRuntimeState({paths: casPaths, validators}).generation, 2);
  assert.equal(pathExists(casPaths.lockPath), false, "abandoned lock must be reclaimed and released");

  const configDirectory = path.join(sandbox, "config");
  const runtimeStateRoot = path.join(sandbox, "runtime-state");
  ensureDirectory(configDirectory, {mode: 0o700});
  const appTeamFixture = readJson(path.join(fixtureDirectory, "app-team-valid-modes.json"));
  const registryPath = path.join(configDirectory, "registry-v1.json");
  const policyPath = path.join(configDirectory, "ownership-policy-v1.json");
  const appTeamPath = path.join(configDirectory, "app-team-v1.json");
  writeJson(registryPath, providerRegistry);
  writeJson(policyPath, validFixture.ownership_policy);
  writeJson(appTeamPath, appTeamFixture);

  const enabledConfig = copy(selectedConfig);
  enabledConfig.enabled = true;
  enabledConfig.documents = {
    app_team_path: "app-team-v1.json",
    policy_path: "ownership-policy-v1.json",
    registry_path: "registry-v1.json",
  };
  const configPath = path.join(configDirectory, "runtime-config.json");
  writeJson(configPath, enabledConfig);
  const configSymlink = path.join(configDirectory, "runtime-config-link.json");
  fs.symlinkSync(configPath, configSymlink);
  assert.throws(
    () => loadRuntimeConfig({configPath: configSymlink, validators}),
    /symbolic links|symbolic link/i,
  );
  const providers = runProviders({configPath, registry: mockRegistry, validators});
  assert.deepEqual(providers.selected, [{adapter_id: "adapter.mock", provider_id: "provider.mock"}]);
  assert.equal(Object.hasOwn(providers.selected[0], "settings_ref"), false, "provider output must not expose settings references");

  for (const [label, mutateObservation, expectedCode, expectedMessage] of [
    [
      "duplicate inventory identity",
      (observation) => {
        observation.inventory.runtimes.push({
          ...copy(observation.inventory.runtimes[0]),
          display_label: "Duplicate runtime",
        });
      },
      "duplicate_identity",
      "adapter observation contains duplicate identities",
    ],
    [
      "noncanonical inventory order",
      (observation) => {
        observation.inventory.agents.reverse();
      },
      "noncanonical_inventory",
      "adapter observation inventory order is not canonical",
    ],
    [
      "dangling inventory relationship",
      (observation) => {
        observation.inventory.agents[0].community_id = "community.missing";
      },
      "dangling_inventory_reference",
      "adapter observation contains dangling inventory references",
    ],
    [
      "dangling team member",
      (observation) => {
        observation.inventory.teams[0].member_agent_ids[0] = "agent.fixture.missing";
      },
      "dangling_inventory_reference",
      "adapter observation contains dangling inventory references",
    ],
    [
      "noncanonical team member order",
      (observation) => {
        observation.inventory.teams[0].member_agent_ids.reverse();
      },
      "noncanonical_inventory",
      "adapter observation inventory order is not canonical",
    ],
  ]) {
    const invalidInventoryAdapter = makeAdapter(inventoryObservation, {
      detect() {
        const observation = copy(inventoryObservation);
        mutateObservation(observation);
        return observation;
      },
    });
    const invalidResult = await runDetect({
      configPath,
      registry: createAdapterRegistry([invalidInventoryAdapter]),
      stateRoot: runtimeStateRoot,
      validators,
    });
    assert.equal(invalidResult.errors.length, 1, label);
    assert.equal(invalidResult.errors[0].code, expectedCode, label);
    assert.equal(invalidResult.errors[0].message, expectedMessage, label);
    assert.equal(pathExists(runtimeStatePaths(runtimeStateRoot).statePath), false, `${label} changed state`);
  }

  for (const [label, mutateObservation, expectedCode, expectedMessage] of [
    [
      "duplicate capability identity",
      (observation) => {
        observation.capabilities.push({...copy(observation.capabilities[0]), availability: "degraded"});
      },
      "duplicate_identity",
      "adapter observation contains duplicate identities",
    ],
    [
      "undeclared capability identity",
      (observation) => {
        observation.capabilities[0].capability_id = "capability.undeclared.read";
      },
      "adapter_capability_mismatch",
      "adapter observation capability mismatch",
    ],
  ]) {
    const invalidObservationAdapter = makeAdapter(validFixture.adapter_observation, {
      detect() {
        const observation = copy(validFixture.adapter_observation);
        mutateObservation(observation);
        return observation;
      },
    });
    const invalidResult = await runDetect({
      configPath,
      registry: createAdapterRegistry([invalidObservationAdapter]),
      stateRoot: runtimeStateRoot,
      validators,
    });
    assert.equal(invalidResult.errors.length, 1, label);
    assert.equal(invalidResult.errors[0].code, expectedCode, label);
    assert.equal(invalidResult.errors[0].message, expectedMessage, label);
    assert.equal(pathExists(runtimeStatePaths(runtimeStateRoot).statePath), false, `${label} changed state`);
  }

  let timeoutSignalAborted = false;
  const hangingAdapter = makeAdapter(validFixture.adapter_observation, {
    detect(context) {
      return new Promise((_, reject) => {
        context.runtime.abort_signal.addEventListener("abort", () => {
          timeoutSignalAborted = true;
          reject(new Error("adapter read aborted"));
        }, {once: true});
      });
    },
  });
  const timeoutConfig = copy(enabledConfig);
  timeoutConfig.options.adapter_timeout_ms = 20;
  writeJson(configPath, timeoutConfig);
  const timeoutStartedAt = Date.now();
  const timedOut = await runDetect({
    configPath,
    registry: createAdapterRegistry([hangingAdapter]),
    stateRoot: path.join(sandbox, "timeout-state"),
    validators,
  });
  assert.equal(timedOut.errors[0].code, "adapter_timeout");
  assert.equal(timedOut.errors[0].message, "adapter read timed out");
  assert.equal(timeoutSignalAborted, true, "adapter timeout must signal cancellation");
  assert.equal(Date.now() - timeoutStartedAt < 1000, true, "adapter timeout must bound a hung read");
  assert.equal(timedOut.state_changed, false);
  writeJson(configPath, enabledConfig);

  const detected = await runDetect({
    configPath,
    now: () => "2026-08-05T20:00:01Z",
    registry: mockRegistry,
    stateRoot: runtimeStateRoot,
    validators,
  });
  assert.equal(detected.generation, 1);
  assert.equal(detected.state_changed, true);
  assert.deepEqual(adapterCalls, ["detect"]);
  const runtimePaths = runtimeStatePaths(runtimeStateRoot);
  const firstStateBytes = readText(runtimePaths.statePath);

  const unchanged = await runDetect({
    configPath,
    now: () => "2026-08-05T20:00:02Z",
    registry: mockRegistry,
    stateRoot: runtimeStateRoot,
    validators,
  });
  assert.equal(unchanged.generation, 1);
  assert.equal(unchanged.state_changed, false);
  assert.equal(readText(runtimePaths.statePath), firstStateBytes);

  const statusBefore = fileStats(runtimePaths.statePath).mtimeMs;
  const status = await runStatus({configPath, registry: mockRegistry, stateRoot: runtimeStateRoot, validators});
  assert.equal(status.state_changed, false);
  assert.equal(status.live.length, 1);
  assert.equal(fileStats(runtimePaths.statePath).mtimeMs, statusBefore);
  const callsBeforeDoctor = adapterCalls.length;
  const doctor = runDoctor({configPath, registry: mockRegistry, stateRoot: runtimeStateRoot, validators});
  assert.equal(doctor.ok, true);
  assert.equal(adapterCalls.length, callsBeforeDoctor, "doctor must not call provider adapters");

  const validStateBeforeRejections = readText(runtimePaths.statePath);
  const unknownConfig = copy(enabledConfig);
  unknownConfig.adapters = [{adapter_id: "adapter.unknown", settings_ref: "settings:unknown"}];
  writeJson(configPath, unknownConfig);
  await assert.rejects(
    runDetect({configPath, registry: mockRegistry, stateRoot: runtimeStateRoot, validators}),
    /unknown configured adapter/i,
  );
  assert.equal(readText(runtimePaths.statePath), validStateBeforeRejections);

  for (const invalidCase of invalidFixture.cases.slice(0, 2)) {
    writeJson(configPath, invalidCase.document);
    await assert.rejects(
      runDetect({configPath, registry: mockRegistry, stateRoot: runtimeStateRoot, validators}),
      /failed validation/i,
    );
    assert.equal(readText(runtimePaths.statePath), validStateBeforeRejections);
  }

  writeJson(configPath, enabledConfig);
  writeJson(policyPath, {document_type: "ownership_policy", schema_version: 1});
  await assert.rejects(
    runDetect({configPath, registry: mockRegistry, stateRoot: runtimeStateRoot, validators}),
    /ownership policy failed validation/i,
  );
  assert.equal(readText(runtimePaths.statePath), validStateBeforeRejections);
  writeJson(policyPath, validFixture.ownership_policy);

  const failedObservation = makeObservation(
    validFixture.adapter_observation,
    "adapter.fail",
    "provider.fail",
    "capability.fail.read",
    "failure-prior",
  );
  const failedAdapter = makeAdapter(failedObservation, {
    detect() {
      const failure = new Error(`${os.homedir()}/private/provider token=fixture-sensitive\n${"x".repeat(800)}\u0007`);
      failure.code = `unsafe\n${"z".repeat(150)}`;
      throw failure;
    },
    status() {
      throw new Error("provider status unavailable");
    },
  });
  const partialRegistry = createAdapterRegistry([mockAdapter, failedAdapter]);
  const prior = readRuntimeState({paths: runtimePaths, validators});
  writeRuntimeState({
    ...copy(prior),
    generation: 2,
    observations: [...prior.observations, failedObservation].sort(
      (left, right) => left.adapter_id.localeCompare(right.adapter_id),
    ),
    updated_at: "2026-08-05T20:00:03Z",
  }, {expectedGeneration: 1, paths: runtimePaths, validators});
  const partialConfig = copy(enabledConfig);
  partialConfig.adapters.push({adapter_id: "adapter.fail", settings_ref: "settings:fail"});
  writeJson(configPath, partialConfig);
  observedProviderVersion = "fixture-2";
  const partial = await runDetect({
    configPath,
    now: () => "2026-08-05T20:00:04Z",
    registry: partialRegistry,
    stateRoot: runtimeStateRoot,
    validators,
  });
  assert.equal(partial.generation, 3);
  assert.equal(partial.errors.length, 1);
  assert.equal(partial.observations.find(({adapter_id: id}) => id === "adapter.fail").provider_version, "failure-prior");
  assert.equal(partial.errors[0].message, "adapter read failed");
  assert.equal(partial.errors[0].message.includes(os.homedir()), false);
  assert.doesNotMatch(partial.errors[0].message, /fixture-sensitive/);
  assert.equal(partial.errors[0].code, "adapter_read_failed");
  assert.equal(mutationCalls, 0);

  const partialStateBytes = readText(runtimePaths.statePath);
  const partialStatus = await runStatus({
    configPath,
    registry: partialRegistry,
    stateRoot: runtimeStateRoot,
    validators,
  });
  assert.equal(partialStatus.errors.length, 1);
  assert.equal(readText(runtimePaths.statePath), partialStateBytes);

  const upgradedFailedAdapter = {
    ...makeAdapter(failedObservation, {
      detect() {
        throw new Error("upgraded adapter unavailable");
      },
      status() {
        throw new Error("upgraded adapter unavailable");
      },
    }),
    adapter_version: "2.0.0",
  };
  const upgraded = await runDetect({
    configPath,
    now: () => "2026-08-05T20:00:05Z",
    registry: createAdapterRegistry([mockAdapter, upgradedFailedAdapter]),
    stateRoot: runtimeStateRoot,
    validators,
  });
  assert.equal(upgraded.generation, 4);
  assert.equal(upgraded.state_changed, true);
  assert.equal(upgraded.observations.some(({adapter_id: adapterId}) => adapterId === "adapter.fail"), false);

  const emptyConfig = copy(enabledConfig);
  emptyConfig.adapters = [];
  writeJson(configPath, emptyConfig);
  const cleared = await runDetect({
    configPath,
    now: () => "2026-08-05T20:00:06Z",
    registry: partialRegistry,
    stateRoot: runtimeStateRoot,
    validators,
  });
  assert.equal(cleared.state_changed, true);
  assert.deepEqual(cleared.observations, []);
  assert.deepEqual(readRuntimeState({paths: runtimePaths, validators}).observations, []);
  const emptyStatus = await runStatus({
    configPath,
    registry: partialRegistry,
    stateRoot: runtimeStateRoot,
    validators,
  });
  assert.deepEqual(emptyStatus.persisted, []);

  const cliConfig = copy(enabledConfig);
  cliConfig.adapters = [];
  const cliConfigPath = path.join(configDirectory, "cli-config.json");
  const requestPath = path.join(configDirectory, "plan-request.json");
  const cliStateRoot = path.join(sandbox, "cli-state");
  writeJson(cliConfigPath, cliConfig);
  writeJson(requestPath, validFixture.plan_request);
  const cliCommands = ["providers", "detect", "status", "doctor"];
  for (const command of cliCommands) {
    const result = runHelper(command, ["--config", cliConfigPath, "--state-dir", cliStateRoot]);
    assert.equal(result.status, 0, `${command} failed: ${result.stderr}`);
    assert.equal(JSON.parse(result.stdout).command, command);
  }
  assert.equal(pathExists(runtimeStatePaths(cliStateRoot).statePath), false, "empty detection must not create state");
  const cliPlan = runHelper("plan", ["--config", cliConfigPath, "--request", requestPath]);
  assert.equal(cliPlan.status, 0, cliPlan.stderr);
  assert.deepEqual(JSON.parse(cliPlan.stdout), firstPlan);

  for (const command of invalidFixture.unsupported_commands) {
    const stateBefore = pathExists(runtimeStatePaths(cliStateRoot).statePath);
    const result = runHelper(command, ["--config", cliConfigPath]);
    assert.notEqual(result.status, 0, `${command} unexpectedly succeeded`);
    assert.match(result.stderr, /unsupported read-only team-interface command/i);
    assert.equal(pathExists(runtimeStatePaths(cliStateRoot).statePath), stateBefore);
  }
  const duplicateArgument = runHelper("providers", ["--config", cliConfigPath, "--config", cliConfigPath]);
  assert.notEqual(duplicateArgument.status, 0);
  assert.match(duplicateArgument.stderr, /duplicate argument/i);

  const missingConfig = path.join(sandbox, "missing-config.json");
  const missingResult = runHelper("providers", ["--config", missingConfig]);
  assert.equal(missingResult.status, 0, missingResult.stderr);
  assert.equal(JSON.parse(missingResult.stdout).config_status, "missing");
} finally {
  removePath(sandbox, {force: true, recursive: true});
}

console.log("team-interface runtime tests passed");
