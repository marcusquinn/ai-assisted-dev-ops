// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

const DEFAULT_LOCK_STALE_MS = 60_000;

function processIsLive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

async function createLock(lockPath) {
  const lock = await open(lockPath, "wx", 0o600);
  try {
    await lock.writeFile(`${process.pid}\n`);
    return lock;
  } catch (error) {
    await lock.close();
    await rm(lockPath, { force: true });
    throw error;
  }
}

async function staleLockCanBeReclaimed(lockPath, clock, lockStaleMs) {
  try {
    const existing = await lstat(lockPath);
    const owned = existing.isFile()
      && !existing.isSymbolicLink()
      && existing.uid === process.getuid()
      && (existing.mode & 0o077) === 0;
    if (!owned || clock() - existing.mtimeMs < lockStaleMs) return false;
    const ownerPid = Number.parseInt(await readFile(lockPath, "utf8"), 10);
    return !processIsLive(ownerPid);
  } catch {
    return false;
  }
}

async function acquireLock(lockPath, clock, lockStaleMs) {
  try {
    return await createLock(lockPath);
  } catch (error) {
    if (error?.code !== "EEXIST") return null;
  }

  if (!await staleLockCanBeReclaimed(lockPath, clock, lockStaleMs)) return null;
  try {
    await rm(lockPath);
    return await createLock(lockPath);
  } catch {
    return null;
  }
}

async function readAttemptedAt(markerPath) {
  try {
    const previous = JSON.parse(await readFile(markerPath, "utf8"));
    return Number(previous?.attempted_at || 0);
  } catch {
    return 0;
  }
}

async function writeMarker(markerPath, fingerprint, clock) {
  const attemptedAt = clock();
  const temporaryPath = `${markerPath}.${process.pid}.${attemptedAt}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify({ fingerprint, attempted_at: attemptedAt })}\n`, {
    mode: 0o600,
    flag: "wx",
  });
  await rename(temporaryPath, markerPath);
  await chmod(markerPath, 0o600);
}

function recoveryFingerprint(sessionID, state) {
  return createHash("sha256")
    .update(`${sessionID}:${state.busySince}:${state.lastActivityAt}`)
    .digest("hex")
    .slice(0, 16);
}

class PersistentRecoveryLedger {
  constructor(root, clock, lockStaleMs = DEFAULT_LOCK_STALE_MS) {
    this.root = root;
    this.clock = clock;
    this.lockStaleMs = lockStaleMs;
  }

  pathFor(sessionID) {
    const name = createHash("sha256").update(sessionID).digest("hex").slice(0, 24);
    return join(this.root, `${name}.json`);
  }

  async claim(sessionID, fingerprint, cooldownMs) {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    await chmod(this.root, 0o700);
    const markerPath = this.pathFor(sessionID);
    const lockPath = `${markerPath}.lock`;
    const lock = await acquireLock(lockPath, this.clock, this.lockStaleMs);
    if (!lock) return false;

    try {
      const attemptedAt = await readAttemptedAt(markerPath);
      if (attemptedAt > 0 && this.clock() - attemptedAt < cooldownMs) return false;
      await writeMarker(markerPath, fingerprint, this.clock);
      return true;
    } finally {
      await lock.close();
      await rm(lockPath, { force: true });
    }
  }
}

export { PersistentRecoveryLedger, recoveryFingerprint };
