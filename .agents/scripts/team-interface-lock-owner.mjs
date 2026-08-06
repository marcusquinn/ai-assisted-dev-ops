// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {execFileSync} from "node:child_process";
import {randomUUID} from "node:crypto";
import {readFileSync} from "node:fs";
import {hostname} from "node:os";

function processStartFingerprint(pid) {
  try {
    return execFileSync("ps", ["-p", String(pid), "-o", "lstart="], {
      encoding: "utf8",
      timeout: 1000,
    }).trim();
  } catch {
    return "";
  }
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    if (error?.code === "EPERM") return true;
    throw error;
  }
}

function validLockOwner(owner) {
  return [
    Boolean(owner),
    typeof owner?.host === "string",
    Number.isSafeInteger(owner?.pid),
    owner?.pid > 0,
    typeof owner?.process_started_at === "string",
    typeof owner?.token === "string",
    typeof owner?.created_at === "string",
  ].every(Boolean);
}

export function readLockOwner(lockPath) {
  try {
    const owner = JSON.parse(readFileSync(lockPath, "utf8"));
    return validLockOwner(owner) ? owner : null;
  } catch {
    return null;
  }
}

export function lockOwnerIsActive(owner) {
  if (owner.host !== hostname()) return true;
  if (!processIsAlive(owner.pid)) return false;
  const currentFingerprint = processStartFingerprint(owner.pid);
  if (!currentFingerprint || !owner.process_started_at) return true;
  return currentFingerprint === owner.process_started_at;
}

export function lockStillMatchesAbandonedOwner(stats, currentOwner, expectedOwner, staleMs) {
  let matches = false;
  if (stats && currentOwner) {
    matches = stats.isFile();
    if (stats.isSymbolicLink()) matches = false;
    if (Date.now() - stats.mtimeMs < staleMs) matches = false;
    if (currentOwner.token !== expectedOwner.token) matches = false;
    if (currentOwner.host !== hostname()) matches = false;
    if (lockOwnerIsActive(currentOwner)) matches = false;
  }
  return matches;
}

export function stateLockOwner() {
  return Object.freeze({
    created_at: new Date().toISOString(),
    host: hostname(),
    pid: process.pid,
    process_started_at: processStartFingerprint(process.pid),
    token: randomUUID(),
  });
}
