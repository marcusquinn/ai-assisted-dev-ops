// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {constants, createReadStream} from "node:fs";
import {open} from "node:fs/promises";
import {
  captureSafePathIdentity,
  verifySafePathIdentity,
} from "./team-interface-buzz-path.mjs";

const MAX_CONFIG_BYTES = 128 * 1024;
const MAX_PID_BYTES = 32;
const MAX_ALLOWED_USERS = 1000;
const MAX_ROOM_MAPPINGS = 1000;

function matrixSourceError(code) {
  const error = new Error("Matrix source read failed");
  error.code = code;
  return error;
}

export function throwIfMatrixReadAborted(signal) {
  if (!signal?.aborted) return;
  const error = new Error("Matrix adapter read aborted");
  error.name = "AbortError";
  error.code = "ABORT_ERR";
  throw error;
}

export function isMatrixAbortError(error, signal) {
  return signal?.aborted || error?.name === "AbortError" || error?.code === "ABORT_ERR";
}

function assertOwnershipAndMode(stats, policy, currentUid) {
  const mode = stats.mode & 0o777;
  if (currentUid !== null && stats.uid !== currentUid) throw matrixSourceError("unsafe_source");
  if (policy === "private" ? (mode & 0o077) !== 0 : (mode & 0o022) !== 0) {
    throw matrixSourceError("unsafe_source");
  }
}

async function readOpenedFile(handle, filePath, maxBytes, signal) {
  const chunks = [];
  let bytesRead = 0;
  const stream = createReadStream(filePath, {
    autoClose: false,
    end: maxBytes,
    fd: handle.fd,
    signal,
    start: 0,
  });
  for await (const chunk of stream) {
    bytesRead += chunk.length;
    if (bytesRead > maxBytes) throw matrixSourceError("oversized_source");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, bytesRead).toString("utf8");
}

async function readSafeFile(filePath, options) {
  const {currentUid, maxBytes, openFile = open, policy, signal} = options;
  throwIfMatrixReadAborted(signal);
  const identity = await captureSafePathIdentity(filePath);
  const handle = await openFile(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  try {
    const stats = await handle.stat();
    if (!stats.isFile()) throw matrixSourceError("unsafe_source");
    if (stats.size > maxBytes) throw matrixSourceError("oversized_source");
    assertOwnershipAndMode(stats, policy, currentUid);
    const openedIdentity = await verifySafePathIdentity(identity);
    if (openedIdentity.dev !== stats.dev || openedIdentity.ino !== stats.ino) {
      throw matrixSourceError("unsafe_source");
    }
    const text = await readOpenedFile(handle, filePath, maxBytes, signal);
    throwIfMatrixReadAborted(signal);
    const currentIdentity = await verifySafePathIdentity(identity);
    if (currentIdentity.dev !== stats.dev || currentIdentity.ino !== stats.ino) {
      throw matrixSourceError("unsafe_source");
    }
    return text;
  } finally {
    await handle.close();
  }
}

function digest(value) {
  return createHash("sha256").update(String(value), "utf8").digest("hex");
}

function requireBoundedString(value, maxLength, allowEmpty = false) {
  if (typeof value !== "string" || value.length > maxLength || (!allowEmpty && value.length === 0)) {
    throw matrixSourceError("malformed_source");
  }
  return value;
}

function normalizedHomeserver(value) {
  const raw = requireBoundedString(value, 2048);
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw matrixSourceError("malformed_source");
  }
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password) {
    throw matrixSourceError("malformed_source");
  }
  parsed.hash = "";
  parsed.search = "";
  return parsed.toString().replace(/\/$/u, "");
}

function allowedUserCount(value) {
  const raw = requireBoundedString(value ?? "", 64 * 1024, true);
  if (raw.length === 0) return 0;
  const users = raw.split(",").map((entry) => entry.trim());
  if (users.length > MAX_ALLOWED_USERS || users.some((entry) => entry.length === 0 || entry.length > 1024)) {
    throw matrixSourceError("malformed_source");
  }
  return new Set(users).size;
}

function configuredRunners(config) {
  const defaultRunner = requireBoundedString(config.defaultRunner ?? "", 255, true);
  const mappings = config.roomMappings ?? {};
  if (!mappings || typeof mappings !== "object" || Array.isArray(mappings)) {
    throw matrixSourceError("malformed_source");
  }
  const entries = Object.entries(mappings);
  if (entries.length > MAX_ROOM_MAPPINGS) throw matrixSourceError("oversized_source");
  const runners = new Set(defaultRunner ? [defaultRunner] : []);
  for (const [roomId, runnerName] of entries) {
    requireBoundedString(roomId, 1024);
    runners.add(requireBoundedString(runnerName, 255));
  }
  return {defaultRunner, runners: [...runners].sort()};
}

function projectConfig(config) {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw matrixSourceError("malformed_source");
  }
  const homeserver = normalizedHomeserver(config.homeserverUrl);
  requireBoundedString(config.accessToken, 64 * 1024);
  const users = allowedUserCount(config.allowedUsers);
  const {defaultRunner, runners} = configuredRunners(config);
  const communityDigest = digest(`matrix-community\0${homeserver}`);
  return {
    bot_runtime: {
      runtime_id: `runtime.matrix.bot.${communityDigest}`,
      display_label: `Matrix bot runtime ${communityDigest.slice(0, 12)}`,
    },
    community: {
      community_id: `community.matrix.${communityDigest}`,
      display_label: `Matrix community ${communityDigest.slice(0, 12)}`,
      availability: "available",
    },
    policy_availability: users > 0 && defaultRunner ? "available" : "degraded",
    runtimes: runners.map((runner) => {
      const runnerDigest = digest(`matrix-runner\0${runner}`);
      return {
        runtime_id: `runtime.matrix.runner.${runnerDigest}`,
        display_label: `Configured runner ${runnerDigest.slice(0, 12)}`,
        availability: "unknown",
      };
    }),
  };
}

export async function readMatrixConfig(configPath, dependencies, signal) {
  const text = await readSafeFile(configPath, {
    currentUid: dependencies.currentUid,
    maxBytes: MAX_CONFIG_BYTES,
    openFile: dependencies.openFile,
    policy: "private",
    signal,
  });
  let config;
  try {
    config = JSON.parse(text);
  } catch {
    throw matrixSourceError("malformed_source");
  }
  return projectConfig(config);
}

export async function readMatrixProcess(pidPath, dependencies, signal) {
  const text = await readSafeFile(pidPath, {
    currentUid: dependencies.currentUid,
    maxBytes: MAX_PID_BYTES,
    openFile: dependencies.openFile,
    policy: "owned",
    signal,
  });
  const value = text.trim();
  if (!/^[1-9][0-9]{0,9}$/u.test(value)) throw matrixSourceError("malformed_source");
  const pid = Number(value);
  if (!Number.isSafeInteger(pid)) throw matrixSourceError("malformed_source");
  return dependencies.processExists(pid) ? "available" : "unavailable";
}

export async function captureMatrixSource(reader, signal, fallback = null) {
  try {
    return {availability: "available", value: await reader()};
  } catch (error) {
    if (isMatrixAbortError(error, signal)) throw error;
    const availability = ["ENOENT", "missing_source"].includes(error?.code) ? "unavailable" : "degraded";
    return {availability, value: fallback};
  }
}
