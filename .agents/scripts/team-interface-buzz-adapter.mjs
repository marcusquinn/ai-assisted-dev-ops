// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {homedir} from "node:os";
import {join} from "node:path";
import {executeBoundedFile} from "./team-interface-buzz-command.mjs";
import {
  finalizeTeams,
  normalizeAgents,
  normalizeCommunities,
  normalizeTeamBases,
} from "./team-interface-buzz-inventory.mjs";
import {
  assertSafeApplicationDirectory,
  isAbortError,
  throwIfAborted,
} from "./team-interface-buzz-safe-read.mjs";
import {
  captureSource,
  readAgentStore,
  readAppVersion,
  readCommunities,
  readTeamStore,
} from "./team-interface-buzz-source.mjs";

const ADAPTER_VERSION = "1.0.0";
const KNOWN_PROVIDER_VERSION = "0.5.5";

const DECLARED_CAPABILITIES = [
  {
    capability_id: "capability.buzz.agents.read",
    resource_kinds: ["other"],
    operations: ["discover", "read"],
    availability: "unknown",
    owner_review_required: true,
  },
  {
    capability_id: "capability.buzz.communities.read",
    resource_kinds: ["community"],
    operations: ["discover", "read"],
    availability: "unknown",
    owner_review_required: true,
  },
  {
    capability_id: "capability.buzz.installation.read",
    resource_kinds: ["other"],
    operations: ["discover", "read"],
    availability: "unknown",
    owner_review_required: false,
  },
  {
    capability_id: "capability.buzz.runtimes.read",
    resource_kinds: ["other"],
    operations: ["discover", "read"],
    availability: "unknown",
    owner_review_required: true,
  },
  {
    capability_id: "capability.buzz.teams.read",
    resource_kinds: ["group"],
    operations: ["discover", "read"],
    availability: "unknown",
    owner_review_required: true,
  },
];

function capabilityAvailability(capabilityId, availability) {
  const source = DECLARED_CAPABILITIES.find(({capability_id: id}) => id === capabilityId);
  return {...structuredClone(source), availability};
}

function observationAvailability(installation, sources) {
  if (installation === "unavailable") return "unavailable";
  if (installation !== "available" || sources.some((state) => state !== "available")) return "degraded";
  return "available";
}

function compatibilityFor(platform, providerVersion) {
  if (platform !== "darwin") {
    return {state: "unsupported", reference: "compatibility:buzz-desktop-macos-only"};
  }
  if (providerVersion === KNOWN_PROVIDER_VERSION) {
    return {state: "compatible", reference: "compatibility:buzz-desktop-0.5.5"};
  }
  return {
    state: "unknown",
    reference: providerVersion === "not-detected"
      ? "compatibility:buzz-desktop-not-detected"
      : "compatibility:buzz-desktop-unverified",
  };
}

function emptyObservation(dependencies, installationAvailability, providerVersion) {
  const sourceAvailability = installationAvailability === "unavailable" ? "unavailable" : "degraded";
  return buildObservation(dependencies, {
    agents: {availability: sourceAvailability, records: [], runtimes: []},
    communities: {availability: sourceAvailability, records: []},
    installationAvailability,
    providerVersion,
    teams: {availability: sourceAvailability, normalizedRecords: []},
  });
}

function buildObservation(dependencies, state) {
  const sourceStates = [state.communities.availability, state.agents.availability, state.teams.availability];
  return {
    schema_version: 1,
    document_type: "adapter_observation",
    adapter_id: "adapter.buzz",
    provider_id: "buzz",
    adapter_version: ADAPTER_VERSION,
    provider_version: state.providerVersion,
    availability: observationAvailability(state.installationAvailability, sourceStates),
    capabilities: [
      capabilityAvailability("capability.buzz.agents.read", state.agents.availability),
      capabilityAvailability("capability.buzz.communities.read", state.communities.availability),
      capabilityAvailability("capability.buzz.installation.read", state.installationAvailability),
      capabilityAvailability("capability.buzz.runtimes.read", state.agents.availability),
      capabilityAvailability("capability.buzz.teams.read", state.teams.availability),
    ],
    compatibility: compatibilityFor(dependencies.platform, state.providerVersion),
    observed_at: dependencies.now(),
    evidence_refs: ["evidence:buzz-desktop-read-only-local-observation"],
    inventory: {
      communities: state.communities.records,
      agents: state.agents.records,
      teams: state.teams.normalizedRecords,
      runtimes: state.agents.runtimes,
    },
  };
}

async function observeBuzz(context, dependencies) {
  const signal = context.runtime.abort_signal;
  throwIfAborted(signal);
  if (dependencies.platform !== "darwin") return emptyObservation(dependencies, "unavailable", "not-detected");

  try {
    await assertSafeApplicationDirectory(dependencies.paths.appPath, dependencies.currentUid);
  } catch (error) {
    if (isAbortError(error, signal)) throw error;
    const availability = error?.code === "ENOENT" ? "unavailable" : "degraded";
    return emptyObservation(dependencies, availability, "not-detected");
  }

  const versionSource = await captureSource(() => readAppVersion(dependencies.paths, dependencies, signal), signal);
  const providerVersion = versionSource.availability === "available" ? versionSource.value : "unknown";
  const installationAvailability = versionSource.availability === "available" ? "available" : "degraded";
  const [communitySource, agentSource, teamSource] = await Promise.all([
    captureSource(() => readCommunities(dependencies.paths, dependencies, signal), signal),
    captureSource(() => readAgentStore(dependencies.paths, dependencies, signal), signal),
    captureSource(() => readTeamStore(dependencies.paths, dependencies, signal), signal),
  ]);
  const communities = normalizeCommunities(communitySource);
  const teamBases = normalizeTeamBases(teamSource);
  const agents = normalizeAgents(agentSource, communities, teamBases, dependencies.processExists);
  const teams = finalizeTeams(teamBases, agents);
  return buildObservation(dependencies, {
    agents,
    communities,
    installationAvailability,
    providerVersion,
    teams,
  });
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
  return Object.freeze({
    currentUid: dependencies.currentUid ?? (typeof process.getuid === "function" ? process.getuid() : null),
    executeFile: dependencies.executeFile || executeBoundedFile,
    now: dependencies.now || (() => new Date().toISOString()),
    paths: Object.freeze({
      appPath: dependencies.appPath || "/Applications/Buzz.app",
      appDataPath: dependencies.appDataPath || join(homeDirectory, "Library/Application Support/xyz.block.buzz.app"),
      webkitRoot: dependencies.webkitRoot || join(homeDirectory, "Library/WebKit/xyz.block.buzz.app/WebsiteData"),
    }),
    platform: dependencies.platform || process.platform,
    processExists: dependencies.processExists || defaultProcessExists,
    snapshotRoot: dependencies.snapshotRoot
      || process.env.AIDEVOPS_TEMP_DIR
      || join(homeDirectory, ".aidevops/.agent-workspace/tmp"),
  });
}

export function createBuzzAdapter(dependencies = {}) {
  const resolved = resolvedDependencies(dependencies);
  const read = (context) => observeBuzz(context, resolved);
  return {
    adapter_id: "adapter.buzz",
    provider_id: "buzz",
    adapter_version: ADAPTER_VERSION,
    capabilities: structuredClone(DECLARED_CAPABILITIES),
    detect: read,
    status: read,
  };
}

export const buzzAdapter = createBuzzAdapter();
