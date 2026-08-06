// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {assertUniqueIds, canonicalJson, deepFreeze, TeamInterfaceError} from "./team-interface-common.mjs";
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

function assertObservationBinding(observation, adapter) {
  for (const property of ["adapter_id", "provider_id", "adapter_version"]) {
    if (observation[property] !== adapter[property]) {
      throw new TeamInterfaceError("adapter_identity_mismatch", `adapter observation changed ${property}`);
    }
  }
  assertCapabilityBinding(observation, adapter);
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
