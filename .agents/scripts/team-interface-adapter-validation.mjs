// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const READ_ONLY_OPERATIONS = new Set(["discover", "read", "receive"]);
const RESOURCE_KINDS = new Set(["community", "channel", "conversation", "thread", "direct_message", "group", "other"]);
const AVAILABILITY_STATES = new Set(["available", "degraded", "unavailable", "unknown"]);
const ADAPTER_PROPERTIES = new Set(["adapter_id", "provider_id", "adapter_version", "capabilities", "detect", "status"]);
const CAPABILITY_PROPERTIES = new Set([
  "capability_id",
  "resource_kinds",
  "operations",
  "availability",
  "owner_review_required",
]);
const MUTATION_METHODS = new Set(["apply", "create", "delete", "invite", "moderate", "publish", "send", "update", "write"]);

function isAsciiAlphaNumeric(character) {
  const code = character.charCodeAt(0);
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function isStableId(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 255 || !isAsciiAlphaNumeric(value[0])) return false;
  for (const character of value.slice(1)) {
    if (!isAsciiAlphaNumeric(character) && !"._:/-".includes(character)) return false;
  }
  return true;
}

function requireStableId(value, label) {
  if (!isStableId(value)) {
    throw new TypeError(`${label} is not a valid stable ID`);
  }
  return value;
}

function requireVersion(value, label) {
  if (typeof value !== "string" || value.length < 1 || value.length > 100) {
    throw new TypeError(`${label} must contain 1-100 characters`);
  }
}

function assertCapabilityProperties(capability, adapterId) {
  for (const property of Object.keys(capability)) {
    if (!CAPABILITY_PROPERTIES.has(property)) {
      throw new TypeError(`adapter ${adapterId} capability contains unknown property ${property}`);
    }
  }
}

function validateResourceKinds(capability, adapterId) {
  const kinds = capability.resource_kinds;
  if (!Array.isArray(kinds) || kinds.length === 0) {
    throw new TypeError(`adapter ${adapterId} capability resource kinds are required`);
  }
  if (new Set(kinds).size !== kinds.length) {
    throw new TypeError(`adapter ${adapterId} capability contains duplicate resource kinds`);
  }
  for (const kind of kinds) {
    if (!RESOURCE_KINDS.has(kind)) throw new TypeError(`adapter ${adapterId} capability has unknown resource kind ${kind}`);
  }
}

function validateOperations(capability, adapterId) {
  const operations = capability.operations;
  if (!Array.isArray(operations) || operations.length === 0) {
    throw new TypeError(`adapter ${adapterId} capability operations are required`);
  }
  if (new Set(operations).size !== operations.length) {
    throw new TypeError(`adapter ${adapterId} capability contains duplicate operations`);
  }
  for (const operation of operations) {
    if (!READ_ONLY_OPERATIONS.has(operation)) {
      throw new TypeError(`adapter ${adapterId} declares mutation-capable operation ${operation}`);
    }
  }
}

function validateCapability(capability, adapterId) {
  if (!capability || typeof capability !== "object" || Array.isArray(capability)) {
    throw new TypeError(`adapter ${adapterId} has an invalid capability`);
  }
  requireStableId(capability.capability_id, `adapter ${adapterId} capability ID`);
  assertCapabilityProperties(capability, adapterId);
  validateResourceKinds(capability, adapterId);
  validateOperations(capability, adapterId);
  if (!AVAILABILITY_STATES.has(capability.availability)) {
    throw new TypeError(`adapter ${adapterId} capability availability is invalid`);
  }
  if (typeof capability.owner_review_required !== "boolean") {
    throw new TypeError(`adapter ${adapterId} capability review policy is invalid`);
  }
}

function assertAdapterProperties(adapter, adapterId) {
  for (const property of Object.keys(adapter)) {
    if (!ADAPTER_PROPERTIES.has(property)) {
      const description = MUTATION_METHODS.has(property) ? "forbidden mutation method" : "unknown property";
      throw new TypeError(`adapter ${adapterId} exposes ${description} ${property}`);
    }
  }
}

function validateCapabilities(adapter, adapterId) {
  if (!Array.isArray(adapter.capabilities) || adapter.capabilities.length === 0 || adapter.capabilities.length > 100) {
    throw new TypeError(`adapter ${adapterId} must declare 1-100 capabilities`);
  }
  for (const capability of adapter.capabilities) validateCapability(capability, adapterId);
  const ids = adapter.capabilities.map(({capability_id: capabilityId}) => capabilityId);
  if (new Set(ids).size !== ids.length) throw new TypeError(`adapter ${adapterId} contains duplicate capability IDs`);
}

function validateMethods(adapter, adapterId) {
  for (const method of ["detect", "status"]) {
    if (typeof adapter[method] !== "function") throw new TypeError(`adapter ${adapterId} is missing ${method}()`);
  }
}

export function validateAdapterDefinition(adapter) {
  if (!adapter || typeof adapter !== "object" || Array.isArray(adapter)) {
    throw new TypeError("adapter definition must be an object");
  }
  const adapterId = requireStableId(adapter.adapter_id, "adapter ID");
  assertAdapterProperties(adapter, adapterId);
  requireStableId(adapter.provider_id, `adapter ${adapterId} provider ID`);
  requireVersion(adapter.adapter_version, `adapter ${adapterId} version`);
  validateCapabilities(adapter, adapterId);
  validateMethods(adapter, adapterId);
  return adapter;
}

export function deepFreezeDefinition(value) {
  if (!value || typeof value !== "object") return value;
  for (const child of Object.values(value)) deepFreezeDefinition(child);
  return Object.isFrozen(value) ? value : Object.freeze(value);
}
