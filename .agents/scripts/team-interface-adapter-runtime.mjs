// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  assertUniqueIds,
  canonicalJson,
  compareCanonicalText,
  deepFreeze,
  TeamInterfaceError,
} from "./team-interface-common.mjs";
import {requireValid} from "./team-interface-validators.mjs";

function adapterContext(documents, selection, abortSignal) {
  return Object.freeze({
    documents: deepFreeze(structuredClone(documents)),
    runtime: Object.freeze({abort_signal: abortSignal, read_only: true, schema_version: 1}),
    settings_ref: selection.settings_ref,
  });
}

function assertCapabilityBinding(observation, adapter) {
  assertUniqueIds(observation.capabilities, "capability_id", "adapter observation");
  const declared = new Map(adapter.capabilities.map((capability) => [capability.capability_id, capability]));
  if (observation.capabilities.length !== declared.size) {
    throw new TeamInterfaceError("adapter_capability_mismatch", "adapter omitted a declared capability");
  }
  for (const capability of observation.capabilities) {
    const source = declared.get(capability.capability_id);
    if (!source) throw new TeamInterfaceError("adapter_capability_mismatch", "adapter returned an undeclared capability");
    for (const property of ["operations", "resource_kinds"]) {
      const actual = [...capability[property]].sort();
      const expected = [...source[property]].sort();
      if (canonicalJson(actual) !== canonicalJson(expected)) {
        throw new TeamInterfaceError("adapter_capability_mismatch", `adapter changed capability ${property}`);
      }
    }
    if (capability.owner_review_required !== source.owner_review_required) {
      throw new TeamInterfaceError("adapter_capability_mismatch", "adapter changed capability review policy");
    }
  }
}

function assertCanonicalIds(records, property, label) {
  const actual = records.map((record) => record[property]);
  const expected = [...actual].sort(compareCanonicalText);
  if (canonicalJson(actual) !== canonicalJson(expected)) {
    throw new TeamInterfaceError("noncanonical_inventory", `${label} must use canonical identity order`);
  }
}

function requireInventoryReference(reference, ids, label) {
  if (reference !== undefined && !ids.has(reference)) {
    throw new TeamInterfaceError("dangling_inventory_reference", `${label} does not resolve`);
  }
}

function assertInventorySemantics(observation) {
  if (!observation.inventory) return;
  const {agents, communities, runtimes, teams} = observation.inventory;
  const collections = [
    [communities, "community_id", "adapter community inventory"],
    [agents, "agent_id", "adapter agent inventory"],
    [teams, "team_id", "adapter team inventory"],
    [runtimes, "runtime_id", "adapter runtime inventory"],
  ];
  for (const [records, property, label] of collections) {
    assertUniqueIds(records, property, label);
    assertCanonicalIds(records, property, label);
  }

  const communityIds = new Set(communities.map(({community_id: id}) => id));
  const agentIds = new Set(agents.map(({agent_id: id}) => id));
  const runtimeIds = new Set(runtimes.map(({runtime_id: id}) => id));
  const teamIds = new Set(teams.map(({team_id: id}) => id));
  for (const agent of agents) {
    requireInventoryReference(agent.community_id, communityIds, "agent community reference");
    requireInventoryReference(agent.runtime_id, runtimeIds, "agent runtime reference");
    requireInventoryReference(agent.team_id, teamIds, "agent team reference");
  }
  for (const team of teams) {
    const expectedMembers = [...team.member_agent_ids].sort(compareCanonicalText);
    if (canonicalJson(team.member_agent_ids) !== canonicalJson(expectedMembers)) {
      throw new TeamInterfaceError("noncanonical_inventory", "team members must use canonical identity order");
    }
    for (const agentId of team.member_agent_ids) {
      requireInventoryReference(agentId, agentIds, "team member reference");
    }
  }
}

function assertObservationBinding(observation, adapter) {
  for (const property of ["adapter_id", "provider_id", "adapter_version"]) {
    if (observation[property] !== adapter[property]) {
      throw new TeamInterfaceError("adapter_identity_mismatch", `adapter observation changed ${property}`);
    }
  }
  assertCapabilityBinding(observation, adapter);
  assertInventorySemantics(observation);
}

export function observationMatchesAdapterDefinition(observation, adapter) {
  try {
    assertObservationBinding(observation, adapter);
    return true;
  } catch {
    return false;
  }
}

async function boundedAdapterRead(method, selection, context, timeoutMs, controller) {
  let timeout;
  const read = Promise.resolve().then(() => selection.adapter[method](context));
  const deadline = new Promise((_, reject) => {
    timeout = setTimeout(() => {
      controller.abort();
      reject(new TeamInterfaceError("adapter_timeout", `${selection.adapter.adapter_id} ${method} timed out`));
    }, timeoutMs);
  });
  try {
    return await Promise.race([read, deadline]);
  } finally {
    clearTimeout(timeout);
    controller.abort();
  }
}

export async function invokeAdapterRead(method, selection, documents, validators, options = {}) {
  if (!["detect", "status"].includes(method)) {
    throw new TeamInterfaceError("unsupported_adapter_read", "adapter read method is unsupported");
  }
  const controller = new AbortController();
  const context = adapterContext(documents, selection, controller.signal);
  const timeoutMs = options.timeoutMs ?? 5000;
  const observation = await boundedAdapterRead(method, selection, context, timeoutMs, controller);
  requireValid(validators.adapterObservation, observation, `${selection.adapter.adapter_id} ${method} observation`);
  assertObservationBinding(observation, selection.adapter);
  return structuredClone(observation);
}
