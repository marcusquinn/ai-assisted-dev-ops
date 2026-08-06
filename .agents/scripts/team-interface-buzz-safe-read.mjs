// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {constants, createReadStream} from "node:fs";
import {open} from "node:fs/promises";
import {
  captureSafePathIdentity,
  verifySafePathIdentity,
} from "./team-interface-buzz-path.mjs";

export function buzzReadError(code) {
  const error = new Error("Buzz source read failed");
  error.code = code;
  return error;
}

export function throwIfAborted(signal) {
  if (signal?.aborted) {
    const error = new Error("Buzz adapter read aborted");
    error.name = "AbortError";
    error.code = "ABORT_ERR";
    throw error;
  }
}

export function isAbortError(error, signal) {
  return signal?.aborted || error?.name === "AbortError" || error?.code === "ABORT_ERR";
}

function assertOwnershipAndMode(stats, policy, currentUid) {
  const mode = stats.mode & 0o777;
  if (policy === "system") {
    if (currentUid !== null && ![0, currentUid].includes(stats.uid)) throw buzzReadError("unsafe_source");
  } else if (currentUid !== null && stats.uid !== currentUid) {
    throw buzzReadError("unsafe_source");
  }
  if (policy === "private" ? (mode & 0o077) !== 0 : (mode & 0o022) !== 0) {
    throw buzzReadError("unsafe_source");
  }
}

async function openSafeFile(filePath, maxBytes, policy, currentUid, openFile) {
  const identity = await captureSafePathIdentity(filePath);
  const handle = await openFile(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  try {
    const stats = await handle.stat();
    if (!stats.isFile()) throw buzzReadError("unsafe_source");
    if (stats.size > maxBytes) throw buzzReadError("oversized_source");
    assertOwnershipAndMode(stats, policy, currentUid);
    const current = await verifySafePathIdentity(identity);
    if (current.dev !== stats.dev || current.ino !== stats.ino) {
      throw buzzReadError("unsafe_source");
    }
    return {handle, identity, stats};
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function verifyOpenedIdentity(identity, stats) {
  const current = await verifySafePathIdentity(identity);
  if (current.dev !== stats.dev || current.ino !== stats.ino) {
    throw buzzReadError("unsafe_source");
  }
}

export async function withSafeFile(filePath, options, reader) {
  const {currentUid, maxBytes, openFile = open, policy, signal} = options;
  throwIfAborted(signal);
  const {handle, identity, stats} = await openSafeFile(filePath, maxBytes, policy, currentUid, openFile);
  try {
    const value = await reader(handle.fd, handle, stats);
    throwIfAborted(signal);
    await verifyOpenedIdentity(identity, stats);
    return value;
  } finally {
    await handle.close();
  }
}

export function readBoundedFile(filePath, maxBytes, policy, currentUid, signal) {
  return withSafeFile(filePath, {currentUid, maxBytes, policy, signal}, async (sourceFd) => {
    const chunks = [];
    let bytesRead = 0;
    const stream = createReadStream(filePath, {
      autoClose: false,
      end: maxBytes,
      fd: sourceFd,
      signal,
      start: 0,
    });
    for await (const chunk of stream) {
      bytesRead += chunk.length;
      if (bytesRead > maxBytes) throw buzzReadError("oversized_source");
      chunks.push(chunk);
    }
    return Buffer.concat(chunks, bytesRead);
  });
}

export async function assertSafeDirectory(directoryPath) {
  const {target: stats} = await captureSafePathIdentity(directoryPath);
  if (!stats.isDirectory()) throw buzzReadError("unsafe_source");
  return stats;
}

export async function assertSafeApplicationDirectory(appPath, currentUid) {
  const stats = await assertSafeDirectory(appPath);
  assertOwnershipAndMode(stats, "system", currentUid);
}
