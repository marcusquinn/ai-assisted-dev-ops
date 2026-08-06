// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {execFile as execFileCallback} from "node:child_process";
import {constants} from "node:fs";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {promisify} from "node:util";
import {compareCanonicalText} from "./team-interface-common.mjs";

const execFile = promisify(execFileCallback);
const ADAPTER_VERSION = "1.0.0";
const SUPPORTED_PROVIDER_VERSION = "0.5.5";
const MAX_SOURCE_BYTES = 4 * 1024 * 1024;
const MAX_RECORDS = 1000;
const MAX_STORAGE_ENTRIES = 512;
const COMMUNITIES_KEY = "buzz-communities";
const COMMUNITY_QUERY = `SELECT hex(value) FROM ItemTable WHERE key = '${COMMUNITIES_KEY}' LIMIT 1;`;

const CAPABILITIES = Object.freeze([
  Object.freeze({
    capability_id: "capability.buzz.installation.read",
    resource_kinds: Object.freeze(["other"]),
    operations: Object.freeze(["discover", "read"]),
    availability: "unknown",
    owner_review_required: false,
  }),
  Object.freeze({
    capability_id: "capability.buzz.communities.read",
    resource_kinds: Object.freeze(["community"]),
    operations: Object.freeze(["discover", "read"]),
    availability: "unknown",
    owner_review_required: false,
  }),
  Object.freeze({
    capability_id: "capability.buzz.agents.read",
    resource_kinds: Object.freeze(["other"]),
    operations: Object.freeze(["discover", "read"]),
    availability: "unknown",
    owner_review_required: false,
  }),
  Object.freeze({
    capability_id: "capability.buzz.teams.read",
    resource_kinds: Object.freeze(["group"]),
    operations: Object.freeze(["discover", "read"]),
    availability: "unknown",
    owner_review_required: false,
  }),
  Object.freeze({
    capability_id: "capability.buzz.runtimes.read",
    resource_kinds: Object.freeze(["other"]),
    operations: Object.freeze(["discover", "read"]),
    availability: "unknown",
    owner_review_required: false,
  }),
]);

function abortIfRequested(signal) {
  if (signal?.aborted) throw new DOMException("The operation was aborted", "AbortError");
}

function stableId(category, externalIdentity) {
  const digest = createHash("sha256").update(externalIdentity).digest("hex").slice(0, 24);
  return `${category}.buzz.${digest}`;
}

function requireString(value, label, maxLength = 255) {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength || /[\u0000-\u001f]/u.test(value)) {
    throw new TypeError(`${label} is invalid`);
  }
  return value;
}

function optionalString(value, label, maxLength = 1024) {
  if (value === undefined || value === null || value === "") return undefined;
  return requireString(value, label, maxLength);
}

async function existingStats(filePath) {
  try {
    return await fs.lstat(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function assertNoSymlinkComponents(filePath) {
  const absolute = path.resolve(filePath);
  const parsed = path.parse(absolute);
  let current = parsed.root;
  for (const component of absolute.slice(parsed.root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stats = await existingStats(current);
    if (!stats) break;
    if (stats.isSymbolicLink()) throw new Error("unsafe source path");
  }
}

function assertTrustedStats(stats, {privateFile}) {
  if (!stats.isFile()) throw new Error("source is not a regular file");
  const currentUid = typeof process.getuid === "function" ? process.getuid() : stats.uid;
  if (privateFile) {
    if (stats.uid !== currentUid || (stats.mode & 0o077) !== 0) throw new Error("private source is insecure");
  } else if (![0, currentUid].includes(stats.uid) || (stats.mode & 0o022) !== 0) {
    throw new Error("public source is insecure");
  }
}

async function readTrustedFile(filePath, {label, maxBytes = MAX_SOURCE_BYTES, privateFile = true, signal}) {
  abortIfRequested(signal);
  await assertNoSymlinkComponents(filePath);
  let handle;
  try {
    handle = await fs.open(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  try {
    const opened = await handle.stat();
    assertTrustedStats(opened, {privateFile});
    if (opened.size > maxBytes) throw new Error(`${label} exceeds its size limit`);
    const bytes = await handle.readFile({signal});
    if (bytes.length > maxBytes) throw new Error(`${label} exceeds its size limit`);
    const current = await existingStats(filePath);
    if (!current || current.isSymbolicLink() || current.dev !== opened.dev || current.ino !== opened.ino) {
      throw new Error(`${label} changed while it was read`);
    }
    abortIfRequested(signal);
    return bytes;
  } finally {
    await handle.close();
  }
}

async function readTrustedJson(filePath, options) {
  const bytes = await readTrustedFile(filePath, options);
  if (bytes === null) return null;
  try {
    return JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new Error(`${options.label} is malformed`);
  }
}

function defaultPaths(homeDirectory) {
  const applicationData = path.join(homeDirectory, "Library/Application Support/xyz.block.buzz.app");
  return Object.freeze({
    app: "/Applications/Buzz.app",
    infoPlist: "/Applications/Buzz.app/Contents/Info.plist",
    agents: path.join(applicationData, "agents/managed-agents.json"),
    teams: path.join(applicationData, "agents/teams.json"),
    webkit: path.join(homeDirectory, "Library/WebKit/xyz.block.buzz.app/WebsiteData"),
  });
}

async function defaultReadVersion(paths, signal) {
  const bytes = await readTrustedFile(paths.infoPlist, {
    label: "Buzz application metadata",
    maxBytes: 1024 * 1024,
    privateFile: false,
    signal,
  });
  if (bytes === null) return null;
  const text = bytes.toString("utf8");
  const xmlMatch = text.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]{1,100})<\/string>/u);
  if (xmlMatch) return requireString(xmlMatch[1], "Buzz version", 100);
  const {stdout} = await execFile("/usr/bin/plutil", [
    "-extract", "CFBundleShortVersionString", "raw", "-o", "-", paths.infoPlist,
  ], {encoding: "utf8", maxBuffer: 4096, signal});
  return requireString(stdout.trim(), "Buzz version", 100);
}

function decodeWebKitValue(hexValue) {
  if (typeof hexValue !== "string" || hexValue.length > MAX_SOURCE_BYTES * 2 || !/^[0-9a-f]*$/iu.test(hexValue)) {
    throw new Error("community store value is malformed");
  }
  const bytes = Buffer.from(hexValue, "hex");
  if (bytes.length % 2 === 0 && bytes.some((byte, index) => index % 2 === 1 && byte === 0)) {
    return bytes.toString("utf16le").replace(/\0+$/u, "");
  }
  return bytes.toString("utf8");
}

async function collectStorageDatabases(root, signal) {
  abortIfRequested(signal);
  const rootStats = await existingStats(root);
  if (!rootStats) return [];
  if (!rootStats.isDirectory() || rootStats.isSymbolicLink()) throw new Error("community storage root is unsafe");
  const databases = [];
  let visited = 0;
  async function visit(directory, depth) {
    abortIfRequested(signal);
    if (depth > 8) throw new Error("community storage traversal is too deep");
    const entries = await fs.readdir(directory, {withFileTypes: true});
    entries.sort((left, right) => compareCanonicalText(left.name, right.name));
    for (const entry of entries) {
      visited += 1;
      if (visited > MAX_STORAGE_ENTRIES) throw new Error("community storage traversal is too large");
      const entryPath = path.join(directory, entry.name);
      const stats = await fs.lstat(entryPath);
      if (stats.isSymbolicLink()) throw new Error("community storage contains a symbolic link");
      if (stats.isDirectory()) await visit(entryPath, depth + 1);
      else if (stats.isFile() && entry.name === "localstorage.sqlite3") databases.push(entryPath);
    }
  }
  await visit(root, 0);
  return databases.sort(compareCanonicalText);
}

async function defaultReadCommunities(paths, signal) {
  const databases = await collectStorageDatabases(paths.webkit, signal);
  if (databases.length === 0) return null;
  for (const database of databases) {
    await readTrustedFile(database, {
      label: "Buzz community store",
      maxBytes: 64 * 1024 * 1024,
      privateFile: true,
      signal,
    });
    const {stdout} = await execFile("sqlite3", ["-readonly", "-batch", "-noheader", database, COMMUNITY_QUERY], {
      encoding: "utf8",
      maxBuffer: MAX_SOURCE_BYTES * 2 + 1,
      signal,
    });
    const encoded = stdout.trim();
    if (!encoded) continue;
    let records;
    try {
      records = JSON.parse(decodeWebKitValue(encoded));
    } catch {
      throw new Error("Buzz community store is malformed");
    }
    return records;
  }
  return [];
}

function requireRecordArray(value, label) {
  if (!Array.isArray(value) || value.length > MAX_RECORDS) throw new TypeError(`${label} is invalid`);
  for (const record of value) {
    if (!record || typeof record !== "object" || Array.isArray(record)) throw new TypeError(`${label} is invalid`);
  }
  return value;
}

function normalizeCommunities(records) {
  const relayToCommunity = new Map();
  const communityIds = new Set();
  const communities = requireRecordArray(records, "Buzz communities").map((record) => {
    const externalId = requireString(record.id, "Buzz community identity", 1024);
    const relayUrl = requireString(record.relayUrl, "Buzz community relay", 2048);
    const communityId = stableId("community", externalId);
    const normalizedRelay = relayUrl.replace(/\/$/u, "");
    if (communityIds.has(communityId) || relayToCommunity.has(normalizedRelay)) {
      throw new TypeError("Buzz community identity is duplicated");
    }
    communityIds.add(communityId);
    relayToCommunity.set(normalizedRelay, communityId);
    return {
      community_id: communityId,
      display_label: requireString(record.name, "Buzz community label"),
      availability: "available",
    };
  }).sort((left, right) => compareCanonicalText(left.community_id, right.community_id));
  return {communities, relayToCommunity};
}

function normalizeTeamIdentities(records) {
  const teamIds = new Map();
  const source = requireRecordArray(records, "Buzz teams");
  for (const record of source) {
    const externalId = requireString(record.id, "Buzz team identity", 1024);
    if (teamIds.has(externalId)) throw new TypeError("Buzz team identity is duplicated");
    teamIds.set(externalId, stableId("team", externalId));
  }
  return {source, teamIds};
}

function processAvailable(pid, isProcessAlive) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    return Boolean(isProcessAlive(pid));
  } catch {
    return false;
  }
}

function normalizeAgents(records, {isProcessAlive, relayToCommunity, teamIds, teamsKnown}) {
  const source = requireRecordArray(records, "Buzz managed agents");
  const runtimeSources = new Map();
  const deployedByTeam = new Map();
  const agentIds = new Set();
  const agents = source.map((record) => {
    const pubkey = optionalString(record.pubkey, "Buzz agent public identity", 1024);
    const definitionId = optionalString(record.slug, "Buzz agent definition identity", 1024)
      || optionalString(record.persona_id, "Buzz agent definition identity", 1024);
    const externalId = pubkey || definitionId;
    if (!externalId) throw new TypeError("Buzz agent identity is missing");
    const agentKind = pubkey ? "instance" : "definition";
    const agentId = stableId(`agent.${agentKind}`, externalId);
    if (agentIds.has(agentId)) throw new TypeError("Buzz agent identity is duplicated");
    agentIds.add(agentId);
    const agent = {
      agent_id: agentId,
      display_label: requireString(record.display_name || record.name, "Buzz agent label"),
      agent_kind: agentKind,
      is_builtin: record.is_builtin === true,
      availability: agentKind === "definition"
        ? (record.is_active === false ? "unavailable" : "available")
        : (processAvailable(record.runtime_pid, isProcessAlive) ? "available" : "unavailable"),
    };
    const relayUrl = optionalString(record.relay_url, "Buzz agent relay", 2048)?.replace(/\/$/u, "");
    if (relayUrl && relayToCommunity.has(relayUrl)) agent.community_ref = relayToCommunity.get(relayUrl);
    const runtime = optionalString(record.runtime, "Buzz runtime identity", 1024);
    if (runtime) {
      const runtimeRef = stableId("runtime", runtime);
      agent.runtime_ref = runtimeRef;
      const current = runtimeSources.get(runtimeRef) || {externalId: runtime, available: false};
      current.available ||= agent.availability === "available";
      runtimeSources.set(runtimeRef, current);
    }
    const sourceTeam = optionalString(record.team_id, "Buzz team relationship", 1024);
    if (sourceTeam && teamsKnown && !teamIds.has(sourceTeam)) {
      throw new TypeError("Buzz agent team relationship does not resolve");
    }
    if (sourceTeam && teamIds.has(sourceTeam)) {
      agent.team_ref = teamIds.get(sourceTeam);
      if (agentKind === "instance") {
        const members = deployedByTeam.get(agent.team_ref) || [];
        members.push(agentId);
        deployedByTeam.set(agent.team_ref, members);
      }
    }
    return agent;
  }).sort((left, right) => compareCanonicalText(left.agent_id, right.agent_id));
  return {agents, deployedByTeam, runtimeSources};
}

function normalizeTeams(source, teamIds, deployedByTeam, availability = "available") {
  return source.map((record) => {
    const teamId = teamIds.get(record.id);
    return {
      team_id: teamId,
      display_label: requireString(record.name, "Buzz team label"),
      is_builtin: record.is_builtin === true,
      member_refs: [...(deployedByTeam.get(teamId) || [])].sort(compareCanonicalText),
      availability,
    };
  }).sort((left, right) => compareCanonicalText(left.team_id, right.team_id));
}

function normalizeRuntimes(runtimeSources) {
  return [...runtimeSources.entries()].map(([runtimeId, source]) => ({
    runtime_id: runtimeId,
    display_label: requireString(source.externalId, "Buzz runtime label"),
    runtime_kind: "unknown",
    availability: source.available ? "available" : "unavailable",
  })).sort((left, right) => compareCanonicalText(left.runtime_id, right.runtime_id));
}

function capabilityObservation(capability, availability) {
  return {
    capability_id: capability.capability_id,
    resource_kinds: [...capability.resource_kinds],
    operations: [...capability.operations],
    availability,
    owner_review_required: capability.owner_review_required,
  };
}

async function sourceResult(reader) {
  try {
    const value = await reader();
    return value === null ? {availability: "unavailable", value: null} : {availability: "available", value};
  } catch (error) {
    if (error?.name === "AbortError") throw error;
    return {availability: "degraded", value: null};
  }
}

function overallAvailability(states) {
  if (states.every((state) => state === "available")) return "available";
  if (states.every((state) => state === "unavailable")) return "unavailable";
  return "degraded";
}

function unavailableObservation(now, providerVersion = "unknown") {
  return {
    schema_version: 1,
    document_type: "adapter_observation",
    adapter_id: "adapter.buzz",
    provider_id: "buzz",
    adapter_version: ADAPTER_VERSION,
    provider_version: providerVersion,
    availability: "unavailable",
    capabilities: CAPABILITIES.map((capability) => capabilityObservation(capability, "unavailable")),
    compatibility: {state: "unsupported", reference: "compatibility:buzz-macos-only"},
    observed_at: now,
    evidence_refs: ["evidence:buzz-read-only-adapter"],
    inventory: {communities: [], agents: [], teams: [], runtimes: []},
  };
}

export function createBuzzAdapter(dependencies = {}) {
  const homeDirectory = dependencies.homeDirectory || os.homedir();
  const paths = Object.freeze({...defaultPaths(homeDirectory), ...(dependencies.paths || {})});
  const platform = dependencies.platform || process.platform;
  const now = dependencies.now || (() => new Date().toISOString());
  const readVersion = dependencies.readVersion || defaultReadVersion;
  const readCommunities = dependencies.readCommunities || defaultReadCommunities;
  const readAgents = dependencies.readAgents || ((signal) => readTrustedJson(paths.agents, {
    label: "Buzz managed-agent store", privateFile: true, signal,
  }));
  const readTeams = dependencies.readTeams || ((signal) => readTrustedJson(paths.teams, {
    label: "Buzz team store", privateFile: true, signal,
  }));
  const isProcessAlive = dependencies.isProcessAlive || ((pid) => {
    process.kill(pid, 0);
    return true;
  });

  async function observe(context) {
    const signal = context.runtime.abort_signal;
    abortIfRequested(signal);
    const observedAt = now();
    if (platform !== "darwin") return unavailableObservation(observedAt);
    const appStats = await existingStats(paths.app);
    if (!appStats) return unavailableObservation(observedAt);
    if (!appStats.isDirectory() || appStats.isSymbolicLink()) return unavailableObservation(observedAt);

    const versionResult = await sourceResult(() => readVersion(paths, signal));
    const providerVersion = versionResult.value || "unknown";
    const [communityResult, agentResult, teamResult] = await Promise.all([
      sourceResult(() => readCommunities(paths, signal)),
      sourceResult(() => readAgents(signal)),
      sourceResult(() => readTeams(signal)),
    ]);
    abortIfRequested(signal);

    let communityState = communityResult.availability;
    let agentState = agentResult.availability;
    let teamState = teamResult.availability;
    let runtimeState = agentState;
    let communities = [];
    let agents = [];
    let teams = [];
    let runtimes = [];
    let relayToCommunity = new Map();
    let teamIds = new Map();
    let teamSource = [];
    let deployedByTeam = new Map();
    if (communityState === "available") {
      try {
        ({communities, relayToCommunity} = normalizeCommunities(communityResult.value));
      } catch {
        communityState = "degraded";
      }
    }
    if (teamState === "available") {
      try {
        ({source: teamSource, teamIds} = normalizeTeamIdentities(teamResult.value));
      } catch {
        teamState = "degraded";
      }
    }
    if (agentState === "available") {
      try {
        const normalized = normalizeAgents(agentResult.value, {
          isProcessAlive,
          relayToCommunity,
          teamIds,
          teamsKnown: teamState === "available",
        });
        agents = normalized.agents;
        deployedByTeam = normalized.deployedByTeam;
        runtimes = normalizeRuntimes(normalized.runtimeSources);
      } catch {
        agentState = "degraded";
        runtimeState = "degraded";
        agents = [];
        runtimes = [];
      }
    }
    if (teamState === "available") {
      const relationshipAvailability = agentState === "available" ? "available" : "degraded";
      teams = normalizeTeams(teamSource, teamIds, deployedByTeam, relationshipAvailability);
      if (relationshipAvailability === "degraded") teamState = "degraded";
    }

    const installationState = versionResult.availability === "available" ? "available" : "degraded";
    const states = [installationState, communityState, agentState, teamState, runtimeState];
    const compatibilityState = providerVersion === SUPPORTED_PROVIDER_VERSION ? "compatible" : "unknown";
    return {
      schema_version: 1,
      document_type: "adapter_observation",
      adapter_id: "adapter.buzz",
      provider_id: "buzz",
      adapter_version: ADAPTER_VERSION,
      provider_version: providerVersion,
      availability: overallAvailability(states),
      capabilities: CAPABILITIES.map((capability, index) => capabilityObservation(capability, states[index])),
      compatibility: {
        state: compatibilityState,
        reference: providerVersion === SUPPORTED_PROVIDER_VERSION
          ? "compatibility:buzz-0.5.5"
          : "compatibility:buzz-version-unknown",
      },
      observed_at: observedAt,
      evidence_refs: ["evidence:buzz-read-only-adapter"],
      inventory: {communities, agents, teams, runtimes},
    };
  }

  return {
    adapter_id: "adapter.buzz",
    provider_id: "buzz",
    adapter_version: ADAPTER_VERSION,
    capabilities: CAPABILITIES.map((capability) => ({
      ...capability,
      operations: [...capability.operations],
      resource_kinds: [...capability.resource_kinds],
    })),
    detect: observe,
    status: observe,
  };
}

export const buzzAdapter = createBuzzAdapter();
