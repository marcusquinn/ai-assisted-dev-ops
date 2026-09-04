// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import {
  chmod,
  lstat,
  mkdir,
  open,
  rename,
  unlink,
} from "node:fs/promises";
import { dirname, isAbsolute } from "node:path";

export const HIGGSFIELD_REAUTHORIZATION_MESSAGE =
  "Higgsfield authorization must be renewed in a browser; remove and re-add the connector, then retry";

const DEFAULT_LOCK_TIMEOUT_MS = 5_000;
const STALE_LOCK_MS = 30_000;

export function oauthError(message) {
  return new Error(`Higgsfield MCP OAuth: ${message}`);
}

export function terminalAuthorizationError() {
  return oauthError(HIGGSFIELD_REAUTHORIZATION_MESSAGE);
}

function assertRegularFile(stats, message) {
  if (!stats.isFile() || stats.isSymbolicLink()) throw oauthError(message);
}

async function openStateFile(statePath) {
  try {
    return await open(statePath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  } catch (error) {
    if (error?.code === "ENOENT") throw terminalAuthorizationError();
    if (error?.code === "ELOOP") throw oauthError("OAuth state path must be a regular file");
    throw oauthError("could not inspect the OAuth state file");
  }
}

async function parseStateFile(handle) {
  try {
    return JSON.parse(await handle.readFile("utf8"));
  } catch {
    throw oauthError("OAuth state file is not valid JSON");
  }
}

export async function readHiggsfieldState(statePath) {
  if (!isAbsolute(statePath)) throw oauthError("state path must be absolute");
  const handle = await openStateFile(statePath);
  try {
    assertRegularFile(await handle.stat(), "OAuth state path must be a regular file");
    return await parseStateFile(handle);
  } finally {
    await handle.close();
  }
}

async function assertReplaceableStatePath(statePath) {
  try {
    assertRegularFile(
      await lstat(statePath),
      "refusing to replace a non-regular OAuth state file",
    );
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

async function writeTemporaryState(temporaryPath, state) {
  const handle = await open(temporaryPath, "wx", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(state, null, 2)}\n`, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function ensureStateDirectory(statePath) {
  const parent = dirname(statePath);
  await mkdir(parent, { recursive: true, mode: 0o700 });
  await chmod(parent, 0o700);
}

export async function writeHiggsfieldStateAtomic(statePath, state) {
  if (!isAbsolute(statePath)) throw oauthError("state path must be absolute");
  await ensureStateDirectory(statePath);
  await assertReplaceableStatePath(statePath);

  const temporaryPath = `${statePath}.tmp.${process.pid}.${randomUUID()}`;
  try {
    await writeTemporaryState(temporaryPath, state);
    await chmod(temporaryPath, 0o600);
    await rename(temporaryPath, statePath);
    await chmod(statePath, 0o600);
  } catch (error) {
    await unlink(temporaryPath).catch(() => {});
    throw oauthError(`could not persist refreshed OAuth state (${error?.code || "write failed"})`);
  }
}

function processIsGone(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return false;
  } catch (error) {
    return error?.code === "ESRCH";
  }
}

async function readLockText(lockPath) {
  const handle = await open(lockPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  try {
    return await handle.readFile("utf8");
  } finally {
    await handle.close();
  }
}

function lockOwnerIsLive(rawOwner) {
  try {
    return !processIsGone(JSON.parse(rawOwner).pid);
  } catch {
    return false;
  }
}

async function staleLockSnapshot(lockPath, now) {
  let stats;
  try {
    stats = await lstat(lockPath);
  } catch (error) {
    if (error?.code === "ENOENT") return { missing: true };
    throw oauthError("could not inspect the refresh lock");
  }
  assertRegularFile(stats, "refresh lock path is not a regular file");
  if (now() - stats.mtimeMs <= STALE_LOCK_MS) return null;
  try {
    const rawOwner = await readLockText(lockPath);
    return lockOwnerIsLive(rawOwner) ? null : { rawOwner };
  } catch (error) {
    if (error?.code === "ENOENT") return { missing: true };
    throw oauthError("could not read the refresh lock owner");
  }
}

async function removeStaleLock(lockPath, snapshot) {
  if (snapshot.missing) return;
  try {
    const currentOwner = await readLockText(lockPath);
    if (currentOwner === snapshot.rawOwner) await unlink(lockPath);
  } catch (error) {
    if (error?.code !== "ENOENT") throw oauthError("could not remove the stale refresh lock");
  }
}

async function tryCreateLock(lockPath, ownerToken) {
  let handle;
  try {
    handle = await open(lockPath, "wx", 0o600);
    await handle.writeFile(JSON.stringify({
      schema: "aidevops.oauth-lock/v1",
      pid: process.pid,
      token: ownerToken,
      createdAt: Date.now(),
    }), "utf8");
    return true;
  } catch (error) {
    if (error?.code === "EEXIST") return false;
    await unlink(lockPath).catch(() => {});
    throw oauthError("could not acquire the refresh lock");
  } finally {
    if (handle) await handle.close();
  }
}

async function waitForExistingLock(lockPath, deadline, now, sleep) {
  const snapshot = await staleLockSnapshot(lockPath, now);
  if (snapshot) {
    await removeStaleLock(lockPath, snapshot);
    return;
  }
  if (now() >= deadline) throw oauthError("timed out waiting for another token refresh");
  await sleep(50);
}

async function acquireRefreshLock(lockPath, ownerToken, deadline, now, sleep) {
  while (!await tryCreateLock(lockPath, ownerToken)) {
    await waitForExistingLock(lockPath, deadline, now, sleep);
  }
}

async function releaseRefreshLock(lockPath, ownerToken) {
  try {
    const owner = JSON.parse(await readLockText(lockPath));
    if (owner.pid === process.pid && owner.token === ownerToken) await unlink(lockPath);
  } catch {
    // A missing or replaced lock is not ours to remove.
  }
}

export async function withRefreshLock(statePath, action, {
  now = Date.now,
  sleep = (milliseconds) => new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds)),
  timeoutMs = DEFAULT_LOCK_TIMEOUT_MS,
} = {}) {
  const lockPath = `${statePath}.refresh.lock`;
  const ownerToken = randomUUID();
  await ensureStateDirectory(statePath);
  await acquireRefreshLock(lockPath, ownerToken, now() + timeoutMs, now, sleep);
  try {
    return await action();
  } finally {
    await releaseRefreshLock(lockPath, ownerToken);
  }
}
