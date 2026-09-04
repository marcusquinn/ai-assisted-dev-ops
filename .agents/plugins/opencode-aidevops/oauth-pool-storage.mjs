/**
 * OAuth Pool — Pool File Storage (t2128)
 *
 * CRUD operations for the pool credential file (~/.aidevops/oauth-pool.json).
 * Handles atomic writes, advisory locking, and account management.
 *
 * @module oauth-pool-storage
 */

import {
  readFileSync, writeFileSync, existsSync, mkdirSync, rmdirSync, unlinkSync,
  renameSync, chmodSync, statSync,
} from "fs";
import { randomUUID } from "crypto";
import { dirname } from "path";
import { POOL_FILE, POOL_LOCK_FILE } from "./oauth-pool-constants.mjs";

// ---------------------------------------------------------------------------
// Pool file I/O
// ---------------------------------------------------------------------------

/**
 * @typedef {Object} PoolAccount
 * @property {string} email
 * @property {string} refresh
 * @property {string} access
 * @property {number} expires
 * @property {string} added
 * @property {string} lastUsed
 * @property {"active"|"idle"|"rate-limited"|"auth-error"} status
 * @property {number|null} cooldownUntil
 * @property {string} [accountId]
 * @property {number} [priority]
 * @property {number} [authRefreshFailures]
 * @property {number} [authRefreshLastFailureAt]
 */

/**
 * Load the pool file. Returns empty pool if file doesn't exist.
 * @returns {Object}
 */
export function loadPool() {
  try {
    if (existsSync(POOL_FILE)) {
      const raw = readFileSync(POOL_FILE, "utf-8");
      return JSON.parse(raw);
    }
  } catch {
    // Corrupted file -- start fresh
  }
  return {};
}

/**
 * Save the pool file with 0600 permissions using an atomic write
 * (temp file + renameSync) so a mid-write crash cannot corrupt the pool.
 * @param {Object} data
 */
export function savePool(data) {
  const dir = dirname(POOL_FILE);
  let tmp = "";
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
    tmp = `${POOL_FILE}.tmp.${process.pid}.${randomUUID()}`;
    writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, POOL_FILE);
  } catch (err) {
    if (tmp) {
      try { unlinkSync(tmp); } catch { /* absent or already renamed */ }
    }
    console.error(`[aidevops] OAuth pool: failed to save pool file: ${err.message}`);
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Pool lock helpers (used only by withPoolLock)
// ---------------------------------------------------------------------------

const LOCK_DIR = POOL_LOCK_FILE + ".d";
const OWNER_FILE = LOCK_DIR + "/owner";
const LOCK_WAIT_MS = 30000;
const OWNERLESS_LOCK_GRACE_MS = 30000;
let activeAsyncLockToken = "";
let asyncLockTail = Promise.resolve();

function ensurePoolDirectory() {
  const dir = dirname(POOL_FILE);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
}

function processIsLive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err?.code === "EPERM";
  }
}

/** Return a stable snapshot only when the current lock can be reclaimed. */
function staleLockSnapshot() {
  try {
    const raw = readFileSync(OWNER_FILE, "utf-8");
    const owner = JSON.parse(raw);
    return processIsLive(owner.pid) ? null : raw;
  } catch {
    try {
      return Date.now() - statSync(LOCK_DIR).mtimeMs >= OWNERLESS_LOCK_GRACE_MS ? "" : null;
    } catch {
      return null;
    }
  }
}

/** Remove only the unchanged stale lock observed by staleLockSnapshot. */
function removeStaleLock(snapshot) {
  try {
    const current = readFileSync(OWNER_FILE, "utf-8");
    if (current !== snapshot) return;
  } catch {
    if (snapshot !== "") return;
  }
  try { unlinkSync(OWNER_FILE); } catch { /* race */ }
  try { rmdirSync(LOCK_DIR); } catch { /* race */ }
}

function tryAcquireLock() {
  const token = randomUUID();
  try {
    mkdirSync(LOCK_DIR, { mode: 0o700 });
  } catch (err) {
    if (err?.code === "EEXIST") return "";
    throw err;
  }
  try {
    chmodSync(LOCK_DIR, 0o700);
    writeFileSync(
      OWNER_FILE,
      JSON.stringify({ schema: "aidevops.oauth-lock/v1", pid: process.pid, token, createdAt: Date.now() }),
      { flag: "wx", mode: 0o600 },
    );
    chmodSync(OWNER_FILE, 0o600);
    return token;
  } catch (err) {
    try { unlinkSync(OWNER_FILE); } catch { /* absent */ }
    try { rmdirSync(LOCK_DIR); } catch { /* retained for diagnosis */ }
    throw err;
  }
}

/** Release the lock only when its unguessable owner token still matches. */
function releaseLock(token) {
  try {
    const owner = JSON.parse(readFileSync(OWNER_FILE, "utf-8"));
    if (owner.pid !== process.pid || owner.token !== token) return;
    try { unlinkSync(OWNER_FILE); } catch { /* ignore */ }
    try { rmdirSync(LOCK_DIR); } catch { /* ignore */ }
  } catch { /* lock dir already gone — that's fine */ }
}

function waitForLockSync() {
  const deadline = Date.now() + LOCK_WAIT_MS;
  const sleepBuf = new Int32Array(new SharedArrayBuffer(4));
  while (Date.now() < deadline) {
    const token = tryAcquireLock();
    if (token) return token;
    const snapshot = staleLockSnapshot();
    if (snapshot !== null) {
      removeStaleLock(snapshot);
      continue;
    }
    Atomics.wait(sleepBuf, 0, 0, 50);
  }
  throw new Error("[aidevops] OAuth pool: timed out waiting for pool lock");
}

async function waitForLockAsync() {
  const deadline = Date.now() + LOCK_WAIT_MS;
  while (Date.now() < deadline) {
    const token = tryAcquireLock();
    if (token) return token;
    const snapshot = staleLockSnapshot();
    if (snapshot !== null) {
      removeStaleLock(snapshot);
      continue;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("[aidevops] OAuth pool: timed out waiting for pool lock");
}

/**
 * Execute a read-modify-write operation on the pool file with cross-process
 * advisory locking via atomic directory creation (mkdirSync is POSIX-atomic).
 *
 * An owner file records { pid, ts } on acquisition; stale locks from crashed
 * processes are reclaimed automatically. Times out after 5 s.
 *
 * @template T
 * @param {() => T} fn
 * @returns {T}
 */
export function withPoolLock(fn) {
  ensurePoolDirectory();
  if (activeAsyncLockToken) return fn();
  const token = waitForLockSync();
  try { return fn(); }
  finally { releaseLock(token); }
}

/**
 * Execute an async refresh transaction under the same cross-process lock.
 * Synchronous same-process mutations remain re-entrant and complete before the
 * awaiting refresh continuation resumes on the JavaScript event loop.
 *
 * @template T
 * @param {() => Promise<T>} fn
 * @returns {Promise<T>}
 */
export async function withPoolLockAsync(fn) {
  ensurePoolDirectory();
  const previous = asyncLockTail;
  let advanceQueue = () => {};
  asyncLockTail = new Promise((resolve) => { advanceQueue = resolve; });
  await previous;

  let token = "";
  try {
    token = await waitForLockAsync();
    activeAsyncLockToken = token;
    return await fn();
  } finally {
    activeAsyncLockToken = "";
    if (token) releaseLock(token);
    advanceQueue();
  }
}

// ---------------------------------------------------------------------------
// Account accessors
// ---------------------------------------------------------------------------

/**
 * Get accounts for a provider.
 * @param {string} provider
 * @returns {PoolAccount[]}
 */
export function getAccounts(provider) {
  const pool = loadPool();
  return pool[provider] || [];
}

/**
 * Add or update an account in the pool.
 * If an account with the same email exists, it is updated (not duplicated).
 * @param {string} provider
 * @param {PoolAccount} account
 * @returns {boolean}
 */
export function upsertAccount(provider, account) {
  return withPoolLock(() => {
    const pool = loadPool();
    if (!pool[provider]) pool[provider] = [];

    // Refuse "unknown" email when named accounts exist
    if (account.email === "unknown") {
      const namedAccounts = pool[provider].filter((a) => a.email !== "unknown");
      if (namedAccounts.length > 0) {
        const emails = namedAccounts.map((a) => a.email).join(", ");
        console.error(
          [
            "[aidevops] OAuth pool: REFUSED to save account with unknown email.",
            `${namedAccounts.length} named account(s) exist: ${emails}.`,
            'Re-auth via "Add Account to Pool" and enter the email when prompted,',
            "or use /model-accounts-pool to manage accounts.",
          ].join(" "),
        );
        return false;
      }
    }

    const idx = pool[provider].findIndex((a) => a.email === account.email);
    if (idx >= 0) {
      pool[provider][idx] = account;
    } else {
      pool[provider].push(account);
    }
    savePool(pool);
    return true;
  });
}

/**
 * Save a token to the pending area when email couldn't be resolved.
 * @param {string} provider
 * @param {object} tokenData
 */
export function savePendingToken(provider, tokenData) {
  withPoolLock(() => {
    const pool = loadPool();
    const pendingKey = `_pending_${provider}`;
    pool[pendingKey] = tokenData;
    savePool(pool);
    const existing = (pool[provider] || []).map((a) => a.email).join(", ");
    console.error(
      [
        `[aidevops] OAuth pool: token saved to pending for ${provider}.`,
        `Existing accounts: ${existing}.`,
        "Use /model-accounts-pool to assign this token to an account.",
      ].join(" "),
    );
  });
}

/**
 * Get a pending token for a provider, if one exists.
 * @param {string} provider
 * @returns {object|null}
 */
export function getPendingToken(provider) {
  const pool = loadPool();
  return pool[`_pending_${provider}`] || null;
}

/**
 * Assign a pending token to an existing account by email.
 * @param {string} provider
 * @param {string} email
 * @returns {boolean}
 */
export function assignPendingToken(provider, email) {
  return withPoolLock(() => {
    const pool = loadPool();
    const pendingKey = `_pending_${provider}`;
    const pending = pool[pendingKey];
    if (!pending) return false;

    if (!pool[provider]) pool[provider] = [];
    const idx = pool[provider].findIndex((a) => a.email === email);
    if (idx < 0) return false;

    const updates = {
      refresh: pending.refresh,
      access: pending.access,
      expires: pending.expires,
      lastUsed: new Date().toISOString(),
      status: "active",
      cooldownUntil: null,
    };
    if (pending.accountId) {
      updates.accountId = pending.accountId;
    }
    Object.assign(pool[provider][idx], updates);

    delete pool[pendingKey];
    savePool(pool);
    console.error(`[aidevops] OAuth pool: assigned pending token to ${email}`);
    return true;
  });
}

/**
 * Remove an account from the pool by email.
 * @param {string} provider
 * @param {string} email
 * @returns {boolean}
 */
export function removeAccount(provider, email) {
  return withPoolLock(() => {
    const pool = loadPool();
    if (!pool[provider]) return false;
    const before = pool[provider].length;
    pool[provider] = pool[provider].filter((a) => a.email !== email);
    if (pool[provider].length === before) return false;
    savePool(pool);
    return true;
  });
}

/**
 * Update an account's status and cooldown in the pool.
 * @param {string} provider
 * @param {string} email
 * @param {Partial<PoolAccount>} patch
 */
export function patchAccount(provider, email, patch) {
  withPoolLock(() => {
    const pool = loadPool();
    if (!pool[provider]) return;
    const account = pool[provider].find((a) => a.email === email);
    if (!account) return;
    Object.assign(account, patch);
    savePool(pool);
  });
}

/** Get the pool file path. */
export function getPoolFilePath() { return POOL_FILE; }
