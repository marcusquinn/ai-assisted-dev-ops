// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {compareCanonicalText} from "./team-interface-common.mjs";

const RUNTIME_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;

function buzzReadError(code) {
  const error = new Error("Buzz source read failed");
  error.code = code;
  return error;
}

function stableInventoryId(prefix, externalIdentity) {
  const digest = createHash("sha256").update(`${prefix}\0${externalIdentity}`).digest("hex");
  return `${prefix}.buzz.${digest}`;
}

function requireIdentity(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 1024) {
    throw buzzReadError("malformed_source");
  }
  return value;
}

function displayLabel(value, fallback) {
  const normalized = typeof value === "string"
    ? value.replace(/[\u0000-\u001f\u007f]/gu, " ").replace(/\s+/gu, " ").trim()
    : "";
  return (normalized || fallback).slice(0, 255);
}

function normalizeRelayUrl(value) {
  const parsed = new URL(requireIdentity(value));
  if (!["ws:", "wss:"].includes(parsed.protocol)) throw buzzReadError("malformed_source");
  parsed.username = "";
  parsed.password = "";
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString().replace(/\/$/u, "");
}

function normalizeCommunityRecord(raw, ids, relayIds) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw buzzReadError("malformed_source");
  const communityId = stableInventoryId("community", requireIdentity(raw.id));
  const relayUrl = normalizeRelayUrl(raw.relayUrl);
  if (ids.has(communityId) || relayIds.has(relayUrl)) throw buzzReadError("malformed_source");
  ids.add(communityId);
  relayIds.set(relayUrl, communityId);
  return {
    community_id: communityId,
    display_label: displayLabel(raw.name, "Buzz community"),
    availability: "available",
  };
}

export function normalizeCommunities(source) {
  if (source.availability !== "available") return {...source, records: [], relayIds: new Map()};
  try {
    const relayIds = new Map();
    const ids = new Set();
    const records = source.value.map((raw) => normalizeCommunityRecord(raw, ids, relayIds));
    records.sort((left, right) => compareCanonicalText(left.community_id, right.community_id));
    return {...source, records, relayIds};
  } catch {
    return {availability: "degraded", value: [], records: [], relayIds: new Map()};
  }
}

function normalizeTeamBase(raw, teamIds) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || !Array.isArray(raw.persona_ids)) {
    throw buzzReadError("malformed_source");
  }
  const externalId = requireIdentity(raw.id);
  const teamId = stableInventoryId("team", externalId);
  if (teamIds.has(externalId)) throw buzzReadError("malformed_source");
  teamIds.set(externalId, teamId);
  return {
    raw,
    value: {
      team_id: teamId,
      display_label: displayLabel(raw.name, "Buzz team"),
      built_in: raw.is_builtin === true,
      availability: "available",
      member_agent_ids: [],
    },
  };
}

export function normalizeTeamBases(source) {
  if (source.availability !== "available") return {...source, records: [], teamIds: new Map()};
  try {
    const teamIds = new Map();
    const records = source.value.map((raw) => normalizeTeamBase(raw, teamIds));
    return {...source, records, teamIds};
  } catch {
    return {availability: "degraded", value: [], records: [], teamIds: new Map()};
  }
}

function processAvailability(raw, processExists) {
  requireIdentity(raw.pubkey || raw.slug || raw.persona_id);
  if (!raw.pubkey) return raw.is_active === false ? "unavailable" : "available";
  if (!Number.isSafeInteger(raw.runtime_pid) || raw.runtime_pid <= 0) return "unavailable";
  return processExists(raw.runtime_pid) ? "available" : "unavailable";
}

function attachCommunity(record, raw, communities, state) {
  if (!raw.relay_url) return;
  const communityId = communities.relayIds.get(normalizeRelayUrl(raw.relay_url));
  if (communityId) {
    record.community_id = communityId;
    return;
  }
  state.relationshipDegraded = true;
}

function attachRuntime(record, raw, state) {
  if (raw.runtime === undefined || raw.runtime === null) return;
  const externalId = requireIdentity(raw.runtime);
  if (!RUNTIME_ID_PATTERN.test(externalId)) throw buzzReadError("malformed_source");
  let runtimeId = state.runtimeIds.get(externalId);
  if (!runtimeId) {
    runtimeId = stableInventoryId("runtime", externalId);
    state.runtimeIds.set(externalId, runtimeId);
  }
  record.runtime_id = runtimeId;
}

function attachTeam(record, raw, teamBases, state) {
  if (raw.team_id === undefined || raw.team_id === null) return;
  const teamId = teamBases.teamIds.get(requireIdentity(raw.team_id));
  if (teamId) {
    record.team_id = teamId;
    return;
  }
  state.relationshipDegraded = true;
}

function registerDefinition(raw, kind, agentId, definitionIds) {
  if (kind !== "definition") return;
  const keys = [...new Set(
    [raw.slug, raw.persona_id].filter((value) => typeof value === "string" && value.length > 0),
  )];
  for (const key of keys) {
    if (definitionIds.has(key)) throw buzzReadError("malformed_source");
    definitionIds.set(key, agentId);
  }
}

function normalizeAgentRecord(raw, communities, teamBases, processExists, state) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw buzzReadError("malformed_source");
  const kind = raw.pubkey ? "managed_instance" : "definition";
  const externalIdentity = requireIdentity(raw.pubkey || raw.slug || raw.persona_id);
  const agentId = stableInventoryId("agent", `${kind}:${externalIdentity}`);
  if (state.agentIds.has(agentId)) throw buzzReadError("malformed_source");
  state.agentIds.add(agentId);
  const record = {
    agent_id: agentId,
    display_label: displayLabel(raw.display_name || raw.name, "Buzz agent"),
    kind,
    built_in: raw.is_builtin === true,
    availability: processAvailability(raw, processExists),
  };
  attachCommunity(record, raw, communities, state);
  attachRuntime(record, raw, state);
  attachTeam(record, raw, teamBases, state);
  registerDefinition(raw, kind, agentId, state.definitionIds);
  return record;
}

function buildRuntimeRecords(runtimeIds) {
  return [...runtimeIds.entries()].map(([externalId, runtimeId]) => ({
    runtime_id: runtimeId,
    display_label: displayLabel(externalId, "Buzz runtime"),
    availability: "unknown",
  })).sort((left, right) => compareCanonicalText(left.runtime_id, right.runtime_id));
}

export function normalizeAgents(source, communities, teamBases, processExists) {
  if (source.availability !== "available") {
    return {...source, records: [], runtimes: [], definitionIds: new Map()};
  }
  try {
    const state = {
      agentIds: new Set(),
      definitionIds: new Map(),
      relationshipDegraded: false,
      runtimeIds: new Map(),
    };
    const records = source.value.map((raw) => (
      normalizeAgentRecord(raw, communities, teamBases, processExists, state)
    ));
    records.sort((left, right) => compareCanonicalText(left.agent_id, right.agent_id));
    return {
      availability: state.relationshipDegraded ? "degraded" : source.availability,
      value: source.value,
      records,
      runtimes: buildRuntimeRecords(state.runtimeIds),
      definitionIds: state.definitionIds,
    };
  } catch {
    return {availability: "degraded", value: [], records: [], runtimes: [], definitionIds: new Map()};
  }
}

function resolveTeamMembers(personaIds, definitionIds) {
  const memberIds = [];
  let degraded = false;
  for (const personaId of personaIds) {
    const agentId = definitionIds.get(requireIdentity(personaId));
    if (agentId) memberIds.push(agentId);
    else degraded = true;
  }
  const uniqueMembers = [...new Set(memberIds)].sort(compareCanonicalText);
  return {degraded: degraded || uniqueMembers.length !== memberIds.length, uniqueMembers};
}

export function finalizeTeams(teamBases, agents) {
  if (teamBases.availability !== "available") return {...teamBases, normalizedRecords: []};
  try {
    let degraded = false;
    const normalizedRecords = teamBases.records.map(({raw, value}) => {
      const resolution = resolveTeamMembers(raw.persona_ids, agents.definitionIds);
      if (resolution.degraded) degraded = true;
      return {...value, member_agent_ids: resolution.uniqueMembers};
    }).sort((left, right) => compareCanonicalText(left.team_id, right.team_id));
    if (degraded) {
      for (const record of normalizedRecords) record.availability = "degraded";
    }
    return {...teamBases, availability: degraded ? "degraded" : teamBases.availability, normalizedRecords};
  } catch {
    return {...teamBases, availability: "degraded", normalizedRecords: []};
  }
}
