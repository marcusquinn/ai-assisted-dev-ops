/**
 * OAuth Pool — Token Refresh & Cursor Credentials (t2128)
 *
 * Token refresh logic for all providers (Anthropic, OpenAI, Cursor, Google),
 * Cursor JWT decoding, Cursor credential reading helpers, expired cooldown
 * normalization, and ensureValidToken.
 *
 * @module oauth-pool-refresh
 */

import { readFileSync, existsSync } from "fs";
import { execSync, execFileSync } from "child_process";
import { platform } from "os";
import {
  ANTHROPIC_CLIENT_ID, OPENAI_CLIENT_ID, GOOGLE_CLIENT_ID,
  AUTH_FAILURE_INITIAL_COOLDOWN_MS, AUTH_FAILURE_MAX_COOLDOWN_MS,
  getCursorAgentAuthPath, getCursorStateDbPath,
} from "./oauth-pool-constants.mjs";
import {
  fetchTokenEndpoint, fetchOpenAITokenEndpoint, fetchGoogleTokenEndpoint,
} from "./oauth-pool-token-endpoint.mjs";
import {
  patchAccount, withPoolLock, withPoolLockAsync, loadPool, savePool,
} from "./oauth-pool-storage.mjs";

// ---------------------------------------------------------------------------
// Cursor JWT decoding
// ---------------------------------------------------------------------------

/**
 * Decode a Cursor JWT to extract email and expiry. No signature verification.
 * @param {string} token
 * @returns {{ email: string|undefined, expiresAt: number|undefined }}
 */
export function decodeCursorJWT(token) {
  try {
    const parts = token.split(".");
    if (parts.length < 2) return {};
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf-8"));
    return {
      email: payload.email || undefined,
      expiresAt: typeof payload.exp === "number" ? payload.exp * 1000 : undefined,
    };
  } catch {
    return {};
  }
}

/**
 * Read a value from Cursor's state.vscdb SQLite database.
 * @param {string} dbPath
 * @param {string} key
 * @returns {string|null}
 */
function readCursorStateDbValue(dbPath, key) {
  if (!/^[\w./:@-]+$/.test(key)) return null;
  try {
    const result = execFileSync(
      "sqlite3",
      [dbPath, `SELECT value FROM ItemTable WHERE key = '${key}'`],
      { encoding: "utf-8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    return result || null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Cursor credential helpers (shared by refresh + auth hook)
// ---------------------------------------------------------------------------

function isCursorTokenForAccount(tokenEmail, accountEmail) {
  return !tokenEmail || tokenEmail === accountEmail || accountEmail === "unknown";
}

export function readCursorAuthJsonCredentials(accountEmail) {
  const authPath = getCursorAgentAuthPath();
  if (!existsSync(authPath)) return null;
  try {
    const data = JSON.parse(readFileSync(authPath, "utf-8"));
    if (!data.accessToken) return null;
    const ti = decodeCursorJWT(data.accessToken);
    if (!isCursorTokenForAccount(ti.email, accountEmail)) return null;
    return {
      access: data.accessToken,
      refresh: data.refreshToken,
      expires: ti.expiresAt || (Date.now() + 3600_000),
      email: ti.email,
    };
  } catch { return null; }
}

export function readCursorStateDbCredentials(accountEmail) {
  const dbPath = getCursorStateDbPath();
  if (!existsSync(dbPath)) return null;
  const at = readCursorStateDbValue(dbPath, "cursorAuth/accessToken");
  if (!at) return null;
  const ti = decodeCursorJWT(at);
  if (!isCursorTokenForAccount(ti.email, accountEmail)) return null;
  return {
    access: at,
    refresh: readCursorStateDbValue(dbPath, "cursorAuth/refreshToken"),
    expires: ti.expiresAt || (Date.now() + 3600_000),
    email: ti.email || readCursorStateDbValue(dbPath, "cursorAuth/cachedEmail"),
  };
}

export function isCursorAgentAvailable() {
  try {
    execFileSync("cursor-agent", ["--version"], {
      timeout: 3000, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"],
    });
    return true;
  } catch { return false; }
}

// ---------------------------------------------------------------------------
// Token refresh — generic + provider-specific
// ---------------------------------------------------------------------------

/** Generic OAuth token refresh — shared by Anthropic, OpenAI, and Google. */
async function refreshProviderToken(account, fetchFn, label) {
  try {
    const response = await fetchFn(account);
    if (!response.ok) return null;
    const json = await response.json();
    return {
      access: json.access_token,
      refresh: json.refresh_token || account.refresh,
      expires: Date.now() + (json.expires_in || 3600) * 1000,
    };
  } catch (err) {
    console.error(`[aidevops] OAuth pool: ${label} token refresh error for ${account.email}: ${err.message}`);
    return null;
  }
}

async function refreshAccessToken(account) {
  return refreshProviderToken(account, (a) => fetchTokenEndpoint(
    JSON.stringify({ grant_type: "refresh_token", refresh_token: a.refresh, client_id: ANTHROPIC_CLIENT_ID }),
    `refresh for ${a.email}`,
  ), "Anthropic");
}

async function refreshOpenAIAccessToken(account) {
  return refreshProviderToken(account, (a) => fetchOpenAITokenEndpoint(
    new URLSearchParams({ grant_type: "refresh_token", refresh_token: a.refresh, client_id: OPENAI_CLIENT_ID }),
    `refresh for ${a.email}`,
  ), "OpenAI");
}

async function refreshCursorAccessToken(account) {
  try {
    const creds = readCursorAuthJsonCredentials(account.email) || readCursorStateDbCredentials(account.email);
    if (creds) {
      return { access: creds.access, refresh: creds.refresh || account.refresh, expires: creds.expires };
    }
    // Keychain fallback (macOS)
    if (platform() === "darwin") {
      try {
        const at = execSync(
          'security find-generic-password -s "cursor-access-token" -a "cursor-user" -w 2>/dev/null',
          { encoding: "utf-8", timeout: 5000 },
        ).trim();
        if (at && at.length > 10) {
          let rt = account.refresh;
          try {
            rt = execSync(
              'security find-generic-password -s "cursor-refresh-token" -a "cursor-user" -w 2>/dev/null',
              { encoding: "utf-8", timeout: 5000 },
            ).trim();
          } catch { /* not found */ }
          const ti = decodeCursorJWT(at);
          return { access: at, refresh: rt || account.refresh, expires: ti.expiresAt || (Date.now() + 3600_000) };
        }
      } catch { /* not found */ }
    }
    console.error(`[aidevops] OAuth pool: Cursor token refresh failed for ${account.email}`);
    return null;
  } catch (err) {
    console.error(`[aidevops] OAuth pool: Cursor token refresh error for ${account.email}: ${err.message}`);
    return null;
  }
}

async function refreshGoogleAccessToken(account) {
  return refreshProviderToken(account, (a) => fetchGoogleTokenEndpoint(
    JSON.stringify({ grant_type: "refresh_token", refresh_token: a.refresh, client_id: GOOGLE_CLIENT_ID }),
    `Google refresh for ${a.email}`,
  ), "Google");
}

export function authFailureBackoffMs(failures) {
  const count = Math.max(1, Number(failures) || 1);
  return Math.min(AUTH_FAILURE_MAX_COOLDOWN_MS, AUTH_FAILURE_INITIAL_COOLDOWN_MS * (2 ** (count - 1)));
}

function markAuthFailure(provider, account, reason) {
  const now = Date.now();
  const failures = (Number(account.authRefreshFailures) || 0) + 1;
  const cooldownMs = authFailureBackoffMs(failures);
  const failureState = {
    status: "auth-error",
    cooldownUntil: now + cooldownMs,
    authRefreshFailures: failures,
    authRefreshLastFailureAt: now,
  };
  patchAccount(provider, account.email, failureState);
  Object.assign(account, failureState);
  logAuthFailure(provider, account.email, reason, failures, cooldownMs);
  return cooldownMs;
}

function logAuthFailure(provider, email, reason, failures, cooldownMs) {
  console.error(
    `[aidevops] OAuth pool: ${provider} ${reason} for ${email}; ` +
    `retry in ${Math.ceil(cooldownMs / 1000)}s (failure ${failures})`,
  );
}

export function markAuthRefreshFailure(provider, account) {
  return markAuthFailure(provider, account, "token refresh failed");
}

export function markRejectedTokenFailure(provider, account) {
  return markAuthFailure(provider, account, "refreshed token was rejected");
}

// ---------------------------------------------------------------------------
// ensureValidToken
// ---------------------------------------------------------------------------

const REFRESH_FN = {
  cursor: refreshCursorAccessToken,
  openai: refreshOpenAIAccessToken,
  google: refreshGoogleAccessToken,
};

function tokenState(account) {
  return {
    access: account?.access || "",
    refresh: account?.refresh || "",
    expires: Number(account?.expires) || 0,
  };
}

function sameTokenState(account, expected) {
  const current = tokenState(account);
  return current.access === expected.access &&
    current.refresh === expected.refresh &&
    current.expires === expected.expires;
}

function findStoredAccount(pool, provider, email) {
  return (pool[provider] || []).find((candidate) => candidate.email === email) || null;
}

function syncCallerAccount(account, stored) {
  if (stored) Object.assign(account, stored);
  return stored?.access || null;
}

async function refreshAndStoreToken(provider, account, force = false) {
  const requestedState = tokenState(account);
  return withPoolLockAsync(async () => {
    let pool = loadPool();
    let stored = findStoredAccount(pool, provider, account.email);
    if (!stored) return null;

    if ((force && !sameTokenState(stored, requestedState)) ||
        (!force && stored.access && stored.expires > Date.now())) {
      return syncCallerAccount(account, stored);
    }

    const refreshState = tokenState(stored);
    const tokens = await (REFRESH_FN[provider] || refreshAccessToken)(stored);

    // Same-process synchronous writers are re-entrant while this async lock is
    // held. Re-read and compare before publishing so a re-auth cannot be
    // overwritten by an older in-flight refresh response.
    pool = loadPool();
    stored = findStoredAccount(pool, provider, account.email);
    if (!stored || !sameTokenState(stored, refreshState)) {
      return syncCallerAccount(account, stored);
    }

    if (!tokens) {
      const now = Date.now();
      const failures = (Number(stored.authRefreshFailures) || 0) + 1;
      const cooldownMs = authFailureBackoffMs(failures);
      Object.assign(stored, {
        status: "auth-error",
        cooldownUntil: now + cooldownMs,
        authRefreshFailures: failures,
        authRefreshLastFailureAt: now,
      });
      savePool(pool);
      syncCallerAccount(account, stored);
      logAuthFailure(provider, stored.email, "token refresh failed", failures, cooldownMs);
      return null;
    }

    Object.assign(stored, {
      access: tokens.access,
      refresh: tokens.refresh || stored.refresh,
      expires: tokens.expires,
      status: "active",
      cooldownUntil: null,
      authRefreshFailures: 0,
      authRefreshLastFailureAt: null,
    });
    savePool(pool);
    return syncCallerAccount(account, stored);
  });
}

/** Force-refresh an OpenAI account even when its local expiry is in the future. */
export async function forceRefreshOpenAIToken(account) {
  return refreshAndStoreToken("openai", account, true);
}

/**
 * Ensure an account has a valid (non-expired) access token.
 * Routes to the correct refresh function based on provider.
 *
 * @param {string} provider
 * @param {import("./oauth-pool-storage.mjs").PoolAccount} account
 * @returns {Promise<string|null>} access token or null on failure
 */
export async function ensureValidToken(provider, account) {
  if (account.access && account.expires > Date.now()) {
    return account.access;
  }
  return refreshAndStoreToken(provider, account);
}

// ---------------------------------------------------------------------------
// Expired cooldown normalization
// ---------------------------------------------------------------------------

/** Check if an account has an expired cooldown. */
function hasExpiredCooldown(a, now) {
  return a.cooldownUntil && a.cooldownUntil <= now &&
    (a.status === "rate-limited" || a.status === "auth-error");
}

/**
 * Auto-clear expired cooldowns for a provider's accounts.
 *
 * @param {string} provider
 * @param {import("./oauth-pool-storage.mjs").PoolAccount[]} accounts
 * @returns {number} count of accounts normalized
 */
export function normalizeExpiredCooldowns(provider, accounts) {
  const now = Date.now();
  let normalized = 0;
  for (const a of accounts) {
    if (hasExpiredCooldown(a, now)) {
      a.status = "idle";
      a.cooldownUntil = null;
      normalized++;
    }
  }
  if (normalized > 0) {
    withPoolLock(() => {
      const pool = loadPool();
      let changed = false;
      for (const a of pool[provider] || []) {
        if (hasExpiredCooldown(a, Date.now())) {
          a.status = "idle";
          a.cooldownUntil = null;
          changed = true;
        }
      }
      if (changed) savePool(pool);
    });
    console.error(`[aidevops] OAuth pool: auto-cleared ${normalized} expired cooldown(s) for ${provider}`);
  }
  return normalized;
}
