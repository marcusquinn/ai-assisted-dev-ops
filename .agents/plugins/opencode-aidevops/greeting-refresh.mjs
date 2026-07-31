// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  closeSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "fs";
import { basename, dirname, join } from "path";

import { emitCachedGreeting } from "./greeting-toast.mjs";

const LOCK_OWNER_BASENAME = "owner";
// Number of times to poll for a replacement lock or refreshed cache after the
// prior lock disappears.
const MAX_MISSING_LOCK_RETRIES = 4;

/**
 * Write raw update-check output to the greeting cache so non-Bash agents can
 * consult it without re-running the script. Failures are non-fatal.
 *
 * @param {string} cacheFile
 * @param {string} output
 */
export function cacheGreeting(cacheFile, output) {
  const tempFile = join(dirname(cacheFile), `.${basename(cacheFile)}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`);
  try {
    mkdirSync(dirname(cacheFile), { recursive: true });
    writeFileSync(tempFile, output + "\n", { encoding: "utf-8", mode: 0o600 });
    renameSync(tempFile, cacheFile);
  } catch (err) {
    rmSync(tempFile, { force: true });
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: cache write failed: ${err.message}`);
    }
  }
}

export function readGreetingCache(cacheFile) {
  let fd;
  try {
    fd = openSync(cacheFile, "r");
    const output = readFileSync(fd, "utf-8").trim();
    if (!output) return null;
    return { output, mtimeMs: fstatSync(fd).mtimeMs };
  } catch {
    return null;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

export function greetingCacheHasCurrentProvenance(cached, initializedAtMs) {
  return Boolean(cached && cached.mtimeMs >= initializedAtMs);
}

export function isGreetingCacheUsable(cached, nowMs, refreshTtlMs, initializedAtMs) {
  return greetingCacheHasCurrentProvenance(cached, initializedAtMs) &&
    nowMs - cached.mtimeMs <= refreshTtlMs;
}

function createOwnedLock(lockDir, lockToken) {
  try {
    mkdirSync(lockDir);
    writeFileSync(join(lockDir, LOCK_OWNER_BASENAME), lockToken, { encoding: "utf-8", mode: 0o600 });
    return lockToken;
  } catch (err) {
    if (err.code !== "EEXIST") {
      rmSync(lockDir, { recursive: true, force: true });
    }
    return null;
  }
}

export function acquireRefreshLock(lockDir, staleMs, nowMs) {
  const lockToken = `${process.pid}-${Math.random().toString(16).slice(2)}`;
  try {
    mkdirSync(dirname(lockDir), { recursive: true });
    const acquired = createOwnedLock(lockDir, lockToken);
    if (acquired) return acquired;
  } catch (err) {
    if (err.code !== "EEXIST") return null;
  }

  const staleDir = `${lockDir}.stale.${lockToken}`;
  try {
    if (nowMs - statSync(lockDir).mtimeMs <= staleMs) return null;
    // Rename atomically before reaping: only one contender can claim a stale
    // lock, and no contender can delete a replacement lock by path.
    renameSync(lockDir, staleDir);
    return createOwnedLock(lockDir, lockToken);
  } catch {
    // Another process either recovered or acquired the lock first.
    return null;
  } finally {
    rmSync(staleDir, { recursive: true, force: true });
  }
}

export function releaseRefreshLock(lockDir, lockToken) {
  try {
    const owner = readFileSync(join(lockDir, LOCK_OWNER_BASENAME), "utf-8");
    if (owner !== lockToken) return;
    rmSync(lockDir, { recursive: true, force: true });
  } catch (err) {
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: lock release failed: ${err.message}`);
    }
  }
}

export function observeSharedRefresh({ cacheFile, lockDir, lockStaleMs, client, now, minimumMtimeMs }) {
  const deadline = now() + lockStaleMs;
  let missingLockRetries = 0;
  const poll = () => {
    const cached = readGreetingCache(cacheFile);
    if (cached && cached.mtimeMs > minimumMtimeMs) {
      emitCachedGreeting(client, cached);
      return;
    }

    try {
      if (now() >= deadline || now() - statSync(lockDir).mtimeMs > lockStaleMs) return;
      missingLockRetries = 0;
    } catch {
      // The owner may publish the cache and remove its lock between our cache
      // read and lock stat. Re-check once so that handoff still emits it.
      const finalCached = readGreetingCache(cacheFile);
      if (finalCached && finalCached.mtimeMs > minimumMtimeMs) {
        emitCachedGreeting(client, finalCached);
        return;
      }
      // A stale-lock contender may have renamed the old lock but not created
      // its replacement yet. Allow a short handoff window without polling for
      // the full stale-lock lifetime when an owner exits without publishing.
      if (now() >= deadline) return;
      if (missingLockRetries >= MAX_MISSING_LOCK_RETRIES) return;
      missingLockRetries += 1;
    }

    const timer = setTimeout(poll, 25);
    timer.unref?.();
  };
  poll();
}
