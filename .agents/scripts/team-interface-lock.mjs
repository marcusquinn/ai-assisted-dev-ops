// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {randomUUID} from "node:crypto";
import {chmodSync, closeSync, fsyncSync, lstatSync, mkdirSync, openSync, renameSync, rmSync, writeFileSync} from "node:fs";
import {assertNoSymlinkComponents, canonicalJson, existingPathStats, TeamInterfaceError} from "./team-interface-common.mjs";
import {lockOwnerIsActive, lockStillMatchesAbandonedOwner, readLockOwner, stateLockOwner} from "./team-interface-lock-owner.mjs";

export function ensurePrivateStateDirectory(directory) {
  assertNoSymlinkComponents(directory);
  mkdirSync(directory, {mode: 0o700, recursive: true});
  assertNoSymlinkComponents(directory);
  const stats = lstatSync(directory);
  if (!stats.isDirectory()) throw new TeamInterfaceError("unsafe_state", "team-interface state root is not a directory");
  chmodSync(directory, 0o700);
  return Object.freeze({device: stats.dev, inode: stats.ino});
}

export function assertDirectoryIdentity(directory, identity) {
  assertNoSymlinkComponents(directory);
  const stats = lstatSync(directory);
  if (!stats.isDirectory() || stats.dev !== identity.device || stats.ino !== identity.inode) {
    throw new TeamInterfaceError("unsafe_state", "team-interface state directory identity changed");
  }
}

function reclaimAbandonedLock(lockPath, expectedOwner, staleMs) {
  const reclaimPath = `${lockPath}.reclaim`;
  const quarantinePath = `${lockPath}.stale-${process.pid}-${randomUUID()}`;
  try {
    mkdirSync(reclaimPath, {mode: 0o700});
  } catch (error) {
    if (error?.code === "EEXIST") return false;
    throw error;
  }
  try {
    const stats = existingPathStats(lockPath);
    const currentOwner = readLockOwner(lockPath);
    if (!lockStillMatchesAbandonedOwner(stats, currentOwner, expectedOwner, staleMs)) return false;
    renameSync(lockPath, quarantinePath);
    rmSync(quarantinePath, {force: true});
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  } finally {
    rmSync(reclaimPath, {force: true, recursive: true});
  }
}

function inspectExistingLock(lockPath, staleMs) {
  const stats = existingPathStats(lockPath);
  if (!stats) return "retry";
  if (!stats.isFile() || stats.isSymbolicLink()) {
    throw new TeamInterfaceError("unsafe_lock", "team-interface state lock is unsafe");
  }
  if (Date.now() - stats.mtimeMs < staleMs) return "wait";
  const owner = readLockOwner(lockPath);
  if (!owner || lockOwnerIsActive(owner)) return "wait";
  return reclaimAbandonedLock(lockPath, owner, staleMs) ? "retry" : "wait";
}

function publishLock(lockPath, owner) {
  if (existingPathStats(`${lockPath}.reclaim`)) return false;
  let descriptor;
  try {
    descriptor = openSync(lockPath, "wx", 0o600);
    writeFileSync(descriptor, `${canonicalJson(owner)}\n`, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    return true;
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    if (error?.code === "EEXIST") return false;
    throw error;
  }
}

function waitForStateLock(paths, directoryIdentity, owner, staleMs, deadline) {
  while (true) {
    assertDirectoryIdentity(paths.directory, directoryIdentity);
    if (publishLock(paths.lockPath, owner)) return Object.freeze({directoryIdentity, owner, paths});
    if (inspectExistingLock(paths.lockPath, staleMs) === "retry") continue;
    if (Date.now() >= deadline) throw new TeamInterfaceError("lock_timeout", "team-interface state lock timed out");
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
  }
}

export function acquireStateLock(paths, options = {}) {
  const timeoutMs = options.timeoutMs ?? 4000;
  const staleMs = options.staleMs ?? 60000;
  const directoryIdentity = options.directoryIdentity || ensurePrivateStateDirectory(paths.directory);
  return waitForStateLock(paths, directoryIdentity, stateLockOwner(), staleMs, Date.now() + timeoutMs);
}

export function releaseStateLock(lock) {
  const owner = readLockOwner(lock.paths.lockPath);
  if (!owner || owner.token !== lock.owner.token) return false;
  rmSync(lock.paths.lockPath, {force: true});
  return true;
}
