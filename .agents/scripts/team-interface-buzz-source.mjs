// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {readdir} from "node:fs/promises";
import {join} from "node:path";
import {compareCanonicalText} from "./team-interface-common.mjs";
import {
  captureSafePathIdentity,
  verifySafePathIdentity,
} from "./team-interface-buzz-path.mjs";
import {
  buzzReadError,
  isAbortError,
  readBoundedFile,
  throwIfAborted,
  withSafeFile,
} from "./team-interface-buzz-safe-read.mjs";
import {withSqliteSnapshot} from "./team-interface-buzz-snapshot.mjs";

const MAX_APP_METADATA_BYTES = 1024 * 1024;
const MAX_AGENT_STORE_BYTES = 10 * 1024 * 1024;
const MAX_TEAM_STORE_BYTES = 2 * 1024 * 1024;
const MAX_SQLITE_BYTES = 256 * 1024 * 1024;
const MAX_SQLITE_OUTPUT_BYTES = 2 * 1024 * 1024;
const MAX_RECORDS = 1000;
const MAX_DATABASES = 32;
const MAX_DIRECTORY_ENTRIES = 5000;
const MAX_DIRECTORY_DEPTH = 8;
const COMMUNITIES_KEY = "buzz-communities";
const SNAPSHOT_DATABASE_NAME = "localstorage.sqlite3";
const SOURCE_DESCRIPTOR_PATH = "/dev/fd/3";

async function readJsonArray(filePath, maxBytes, policy, currentUid, signal) {
  const bytes = await readBoundedFile(filePath, maxBytes, policy, currentUid, signal);
  let value;
  try {
    value = JSON.parse(bytes.toString("utf8"));
  } catch {
    throw buzzReadError("malformed_source");
  }
  if (!Array.isArray(value) || value.length > MAX_RECORDS) throw buzzReadError("malformed_source");
  return value;
}

export async function readAppVersion(paths, dependencies, signal) {
  const plistPath = join(paths.appPath, "Contents/Info.plist");
  return withSafeFile(
    plistPath,
    {currentUid: dependencies.currentUid, maxBytes: MAX_APP_METADATA_BYTES, policy: "system", signal},
    async (sourceFd) => {
      const {stdout} = await dependencies.executeFile(
        "/usr/bin/plutil",
        ["-extract", "CFBundleShortVersionString", "raw", "--", SOURCE_DESCRIPTOR_PATH],
        {encoding: "utf8", maxBuffer: MAX_APP_METADATA_BYTES, signal, sourceFd},
      );
      const version = String(stdout).trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,99}$/.test(version)) throw buzzReadError("malformed_source");
      return version;
    },
  );
}

function accountForStorageEntry(entry, directory, depth, state) {
  state.entryCount += 1;
  if (state.entryCount > MAX_DIRECTORY_ENTRIES) throw buzzReadError("oversized_source");
  const entryPath = join(directory, entry.name);
  if (entry.isSymbolicLink()) throw buzzReadError("unsafe_source");
  if (entry.isDirectory()) {
    if (depth >= MAX_DIRECTORY_DEPTH) throw buzzReadError("oversized_source");
    state.pending.push({depth: depth + 1, directory: entryPath});
    return;
  }
  if (entry.isFile() && entry.name === "localstorage.sqlite3") {
    state.databases.push(entryPath);
    if (state.databases.length > MAX_DATABASES) throw buzzReadError("oversized_source");
  }
}

async function collectLocalStorageDatabases(rootPath, signal) {
  const rootIdentity = await captureSafePathIdentity(rootPath);
  if (!rootIdentity.target.isDirectory()) throw buzzReadError("unsafe_source");
  const state = {databases: [], entryCount: 0, pending: [{depth: 0, directory: rootPath}]};
  while (state.pending.length > 0) {
    throwIfAborted(signal);
    const {depth, directory} = state.pending.shift();
    await verifySafePathIdentity(rootIdentity);
    const directoryIdentity = await captureSafePathIdentity(directory);
    if (!directoryIdentity.target.isDirectory()) throw buzzReadError("unsafe_source");
    const entries = await readdir(directory, {withFileTypes: true});
    await verifySafePathIdentity(directoryIdentity);
    await verifySafePathIdentity(rootIdentity);
    entries.sort((left, right) => compareCanonicalText(left.name, right.name));
    for (const entry of entries) accountForStorageEntry(entry, directory, depth, state);
  }
  await verifySafePathIdentity(rootIdentity);
  if (state.databases.length === 0) throw buzzReadError("missing_source");
  return {databases: state.databases.sort(compareCanonicalText), rootIdentity};
}

function decodeWebkitValue(hexValue) {
  const encoded = hexValue.trim();
  if (encoded.length === 0) return null;
  if (encoded.length % 2 !== 0 || !/^[0-9A-Fa-f]+$/.test(encoded)) throw buzzReadError("malformed_source");
  const bytes = Buffer.from(encoded, "hex");
  const utf16Shape = bytes.length % 2 === 0
    && Array.from({length: bytes.length / 2}, (_, index) => bytes[index * 2 + 1]).some((byte) => byte === 0);
  return (utf16Shape ? bytes.toString("utf16le") : bytes.toString("utf8")).replace(/\0+$/u, "");
}

export async function readCommunities(paths, dependencies, signal) {
  const {databases, rootIdentity} = await collectLocalStorageDatabases(paths.webkitRoot, signal);
  const payloads = [];
  const query = `SELECT hex(value) FROM ItemTable WHERE key = '${COMMUNITIES_KEY}' LIMIT 1;`;
  for (const databasePath of databases) {
    await verifySafePathIdentity(rootIdentity);
    const decoded = await withSqliteSnapshot(
      databasePath,
      {
        currentUid: dependencies.currentUid,
        maxBytes: MAX_SQLITE_BYTES,
        policy: "owned",
        signal,
        snapshotRoot: dependencies.snapshotRoot,
      },
      async (_snapshotPath, snapshotDirectory) => {
        const {stdout} = await dependencies.executeFile(
          "/usr/bin/sqlite3",
          ["-readonly", "-batch", "-noheader", SNAPSHOT_DATABASE_NAME, query],
          {cwd: snapshotDirectory, encoding: "utf8", maxBuffer: MAX_SQLITE_OUTPUT_BYTES, signal},
        );
        return decodeWebkitValue(String(stdout));
      },
    );
    await verifySafePathIdentity(rootIdentity);
    if (decoded !== null) payloads.push(decoded);
  }
  if (payloads.length === 0) return [];
  if (payloads.length > 1) throw buzzReadError("ambiguous_source");
  let communities;
  try {
    communities = JSON.parse(payloads[0]);
  } catch {
    throw buzzReadError("malformed_source");
  }
  if (!Array.isArray(communities) || communities.length > MAX_RECORDS) {
    throw buzzReadError("malformed_source");
  }
  return communities;
}

export function readAgentStore(paths, dependencies, signal) {
  return readJsonArray(
    join(paths.appDataPath, "agents/managed-agents.json"),
    MAX_AGENT_STORE_BYTES,
    "private",
    dependencies.currentUid,
    signal,
  );
}

export function readTeamStore(paths, dependencies, signal) {
  return readJsonArray(
    join(paths.appDataPath, "agents/teams.json"),
    MAX_TEAM_STORE_BYTES,
    "owned",
    dependencies.currentUid,
    signal,
  );
}

export async function captureSource(reader, signal) {
  try {
    return {availability: "available", value: await reader()};
  } catch (error) {
    if (isAbortError(error, signal)) throw error;
    const availability = ["ENOENT", "missing_source"].includes(error?.code) ? "unavailable" : "degraded";
    return {availability, value: []};
  }
}
