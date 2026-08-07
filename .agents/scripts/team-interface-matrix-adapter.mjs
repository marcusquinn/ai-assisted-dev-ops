// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {homedir} from "node:os";
import {join} from "node:path";
import {compareCanonicalText} from "./team-interface-common.mjs";
import {
  captureMatrixSource,
  readMatrixConfig,
  readMatrixProcess,
  throwIfMatrixReadAborted,
} from "./team-interface-matrix-source.mjs";

const ADAPTER_VERSION = "1.0.0";

const DECLARED_CAPABILITIES = [
  {
    capability_id: "capability.matrix.communities.read",
    resource_kinds: ["community"],
    operations: ["discover", "read"],
    availability: "unknown",
    owner_review_required: true,
  },
  {
    capability_id: "capability.matrix.events.receive",
    resource_kinds: ["conversation"],
    operations: ["receive"],
    availability: "unknown",
    owner_review_required: true,
  },
  {
    capability_id: "capability.matrix.installation.read",
    resource_kinds: ["other"],
    operations: ["discover", "read"],
    availability: "unknown",
    owner_review_required: false,
  },
  {
    capability_id: "capability.matrix.runtimes.read",
    resource_kinds: ["other"],
    operations: ["discover", "read"],
    availability: "unknown",
    owner_review_required: true,
  },
];

function capabilityAvailability(capabilityId, availability) {
  const source = DECLARED_CAPABILITIES.find(({capability_id: id}) => id === capabilityId);
  return {...structuredClone(source), availability};
}

function eventAvailability(configSource, processSource) {
  if (configSource.availability === "unavailable") return "unavailable";
  if (configSource.availability !== "available" || processSource.availability !== "available") return "degraded";
  if (processSource.value === "unavailable") return "unavailable";
  if (processSource.value !== "available" || configSource.value.policy_availability !== "available") return "degraded";
  return "available";
}

function observationAvailability(configSource, processSource) {
  if (configSource.availability === "unavailable") return "unavailable";
  if (configSource.availability !== "available") return "degraded";
  if (configSource.value.policy_availability !== "available") return "degraded";
  if (processSource.availability !== "available" || processSource.value !== "available") return "degraded";
  return "available";
}

function inventoryFor(configSource, processSource) {
  if (!configSource.value) return {agents: [], communities: [], runtimes: [], teams: []};
  const processAvailability = processSource.availability === "available"
    ? processSource.value
    : processSource.availability;
  return {
    agents: [],
    communities: [configSource.value.community],
    runtimes: [
      {...configSource.value.bot_runtime, availability: processAvailability},
      ...configSource.value.runtimes,
    ].sort((left, right) => compareCanonicalText(left.runtime_id, right.runtime_id)),
    teams: [],
  };
}

function buildObservation(dependencies, configSource, processSource) {
  const configAvailability = configSource.availability;
  const events = eventAvailability(configSource, processSource);
  return {
    schema_version: 1,
    document_type: "adapter_observation",
    adapter_id: "adapter.matrix",
    provider_id: "matrix",
    adapter_version: ADAPTER_VERSION,
    provider_version: "unprobed",
    availability: observationAvailability(configSource, processSource),
    capabilities: [
      capabilityAvailability("capability.matrix.communities.read", configAvailability),
      capabilityAvailability("capability.matrix.events.receive", events),
      capabilityAvailability("capability.matrix.installation.read", configAvailability),
      capabilityAvailability("capability.matrix.runtimes.read", configAvailability),
    ],
    compatibility: {state: "unknown", reference: "compatibility:matrix-client-unprobed"},
    observed_at: dependencies.now(),
    evidence_refs: ["evidence:matrix-read-only-local-observation"],
    inventory: inventoryFor(configSource, processSource),
  };
}

async function observeMatrix(context, dependencies) {
  const signal = context.runtime.abort_signal;
  throwIfMatrixReadAborted(signal);
  const [configSource, processSource] = await Promise.all([
    captureMatrixSource(
      () => dependencies.readConfig(dependencies.paths.configPath, dependencies, signal),
      signal,
    ),
    captureMatrixSource(
      () => dependencies.readProcess(dependencies.paths.pidPath, dependencies, signal),
      signal,
      "unavailable",
    ),
  ]);
  return buildObservation(dependencies, configSource, processSource);
}

function defaultProcessExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function resolvedDependencies(dependencies) {
  const homeDirectory = dependencies.homeDirectory || homedir();
  const configRoot = dependencies.configRoot || process.env.XDG_CONFIG_HOME || join(homeDirectory, ".config");
  return Object.freeze({
    currentUid: dependencies.currentUid ?? (typeof process.getuid === "function" ? process.getuid() : null),
    now: dependencies.now || (() => new Date().toISOString()),
    openFile: dependencies.openFile,
    paths: Object.freeze({
      configPath: dependencies.configPath || join(configRoot, "aidevops/matrix-bot.json"),
      pidPath: dependencies.pidPath || join(homeDirectory, ".aidevops/.agent-workspace/matrix-bot/bot.pid"),
    }),
    processExists: dependencies.processExists || defaultProcessExists,
    readConfig: dependencies.readConfig || readMatrixConfig,
    readProcess: dependencies.readProcess || readMatrixProcess,
  });
}

export function createMatrixAdapter(dependencies = {}) {
  const resolved = resolvedDependencies(dependencies);
  const read = (context) => observeMatrix(context, resolved);
  return {
    adapter_id: "adapter.matrix",
    provider_id: "matrix",
    adapter_version: ADAPTER_VERSION,
    capabilities: structuredClone(DECLARED_CAPABILITIES),
    detect: read,
    status: read,
  };
}

export const matrixAdapter = createMatrixAdapter();
