// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {deepFreezeDefinition, validateAdapterDefinition} from "./team-interface-adapter-validation.mjs";
import {buzzAdapter} from "./team-interface-buzz-adapter.mjs";
import {compareCanonicalText} from "./team-interface-common.mjs";
import {matrixAdapter} from "./team-interface-matrix-adapter.mjs";

const BUILTIN_ADAPTERS = Object.freeze([buzzAdapter, matrixAdapter]);

export {validateAdapterDefinition} from "./team-interface-adapter-validation.mjs";

export function createAdapterRegistry(adapters = BUILTIN_ADAPTERS) {
  if (!Array.isArray(adapters)) throw new TypeError("adapter registry input must be an array");
  const entries = new Map();
  for (const adapter of adapters) {
    validateAdapterDefinition(adapter);
    if (entries.has(adapter.adapter_id)) throw new TypeError(`duplicate adapter ID ${adapter.adapter_id}`);
    entries.set(adapter.adapter_id, deepFreezeDefinition(adapter));
  }
  return Object.freeze({
    get(adapterId) {
      return entries.get(adapterId);
    },
    has(adapterId) {
      return entries.has(adapterId);
    },
    ids() {
      return [...entries.keys()].sort();
    },
    values() {
      return [...entries.values()].sort((left, right) => compareCanonicalText(left.adapter_id, right.adapter_id));
    },
  });
}

export function selectConfiguredAdapters(config, registry = builtInAdapterRegistry) {
  const selectedIds = new Set();
  const selected = [];
  for (const selection of config.adapters) {
    if (selectedIds.has(selection.adapter_id)) {
      throw new TypeError(`duplicate configured adapter ID ${selection.adapter_id}`);
    }
    const adapter = registry.get(selection.adapter_id);
    if (!adapter) throw new TypeError(`unknown configured adapter ID ${selection.adapter_id}`);
    selectedIds.add(selection.adapter_id);
    selected.push(Object.freeze({adapter, settings_ref: selection.settings_ref}));
  }
  return selected.sort((left, right) => compareCanonicalText(left.adapter.adapter_id, right.adapter.adapter_id));
}

export function adapterMetadata(adapter) {
  return {
    adapter_id: adapter.adapter_id,
    adapter_version: adapter.adapter_version,
    capabilities: structuredClone(adapter.capabilities),
    provider_id: adapter.provider_id,
  };
}

export const builtInAdapterRegistry = createAdapterRegistry();
