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
  assertUniqueIds(records, property, label);
  const actual = records.map((record) => record[property]);
  const expected = [...actual].sort(compareCanonicalText);
  if (canonicalJson(actual) !== canonicalJson(expected)) {
    throw new TeamInterfaceError("adapter_inventory_order", `${label} is not in canonical ID order`);
  }
}

function requireInventoryRef(ref, ids, label) {
  if (ref !== undefined && !ids.has(ref)) {
    throw new TeamInterfaceError("adapter_inventory_reference", `${label} does not resolve`);
  }
}

function assertInventoryBinding(observation) {
  if (!observation.inventory) return;
  const {communities, agents, teams, runtimes} = observation.inventory;
  assertCanonicalIds(communities, "community_id", "adapter community inventory");
  assertCanonicalIds(agents, "agent_id", "adapter agent inventory");
  assertCanonicalIds(teams, "team_id", "adapter team inventory");
  assertCanonicalIds(runtimes, "runtime_id", "adapter runtime inventory");

  const communityIds = new Set(communities.map(({community_id: id}) => id));
  const agentIds = new Set(agents.map(({agent_id: id}) => id));
  const teamIds = new Set(teams.map(({team_id: id}) => id));
  const runtimeIds = new Set(runtimes.map(({runtime_id: id}) => id));
  for (const agent of agents) {
    requireInventoryRef(agent.community_ref, communityIds, "adapter agent community reference");
    requireInventoryRef(agent.runtime_ref, runtimeIds, "adapter agent runtime reference");
    requireInventoryRef(agent.team_ref, teamIds, "adapter agent team reference");
  }
  for (const team of teams) {
    const expected = [...team.member_refs].sort(compareCanonicalText);
    if (canonicalJson(team.member_refs) !== canonicalJson(expected)) {
      throw new TeamInterfaceError("adapter_inventory_order", "adapter team member references are not canonical");
    }
    for (const memberRef of team.member_refs) {
      requireInventoryRef(memberRef, agentIds, "adapter team member reference");
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
  assertInventoryBinding(observation);
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
