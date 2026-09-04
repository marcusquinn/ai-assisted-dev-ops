/**
 * OAuth Multi-Account Pool (t1543, t1548, t1549)
 *
 * Enables multiple OAuth accounts per provider with automatic credential
 * rotation on rate limits (429). Stores credentials in a separate pool file
 * (~/.aidevops/oauth-pool.json) to avoid conflicts with OpenCode's auth.json.
 *
 * Architecture:
 *   - constants: shared OAuth endpoints, client IDs, paths (oauth-pool-constants.mjs)
 *   - token-endpoint: CLI detection, curl wrapper, cooldown gate (oauth-pool-token-endpoint.mjs)
 *   - storage: pool file CRUD (oauth-pool-storage.mjs)
 *   - refresh: token refresh, cursor credentials (oauth-pool-refresh.mjs)
 *   - callback: PKCE, OAuth server, email resolution (oauth-pool-callback.mjs)
 *   - auth: provider auth hooks (oauth-pool-auth.mjs)
 *   - display: formatting, action handlers (oauth-pool-display.mjs)
 *   - tool: MCP tool definition (oauth-pool-tool.mjs)
 *   - shell: oauth-pool-helper.sh (no OpenCode SDK needed)
 *
 * This file is the public facade — all external imports resolve through here.
 *
 * Supported providers:
 *   - anthropic: Claude Pro/Max accounts (claude.ai OAuth)
 *   - openai: ChatGPT Plus/Pro accounts (auth.openai.com OAuth)
 *   - cursor: Cursor Pro accounts (cursor-agent CLI + local proxy sidecar)
 *   - google: Google AI Pro/Ultra/Workspace (ADC bearer token)
 *
 * References:
 *   - Built-in auth plugin: opencode-anthropic-auth@0.0.13
 *   - OpenCode PR #11832 (upstream multi-account proposal)
 *   - Plugin API: @opencode-ai/plugin AuthHook type
 *   - OpenAI OAuth: CLIENT_ID=app_EMoamEEZ73f0CkXaXp7hrann, ISSUER=https://auth.openai.com
 *   - Cursor: opencode-cursor-auth@1.0.16 (POSO-PocketSolutions/opencode-cursor-auth)
 */

import {
  CURSOR_PROXY_HOST, CURSOR_PROXY_DEFAULT_PORT, CURSOR_PROXY_BASE_URL,
} from "./oauth-pool-constants.mjs";
import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { getAccounts, patchAccount } from "./oauth-pool-storage.mjs";
import { ensureValidToken, normalizeExpiredCooldowns } from "./oauth-pool-refresh.mjs";

// ---------------------------------------------------------------------------
// Re-exports — public API (backward-compatible surface)
// ---------------------------------------------------------------------------

// Constants
export { GOOGLE_HEALTH_CHECK_URL } from "./oauth-pool-constants.mjs";

// Token endpoint
export {
  ANTHROPIC_USER_AGENT, OPENCODE_USER_AGENT, getAnthropicUserAgent,
  DETECTED_STAINLESS_PACKAGE_VERSION,
  fetchTokenEndpoint, fetchOpenAITokenEndpoint, fetchGoogleTokenEndpoint,
  getEndpointCooldownValue, resetEndpointCooldown,
} from "./oauth-pool-token-endpoint.mjs";

// Storage
export {
  getAccounts, upsertAccount, savePendingToken, getPendingToken,
  assignPendingToken, removeAccount, patchAccount,
  withPoolLock, loadPool, savePool, getPoolFilePath,
} from "./oauth-pool-storage.mjs";

// Refresh & Cursor helpers
export {
  decodeCursorJWT, readCursorAuthJsonCredentials, readCursorStateDbCredentials,
  isCursorAgentAvailable, ensureValidToken, normalizeExpiredCooldowns,
  authFailureBackoffMs, markAuthRefreshFailure,
} from "./oauth-pool-refresh.mjs";

// Auth hooks & provider registration
export {
  createPoolAuthHook, createOpenAIPoolAuthHook,
  createCursorPoolAuthHook, createGooglePoolAuthHook,
  registerPoolProvider,
} from "./oauth-pool-auth.mjs";

// Tool
export { createPoolTool } from "./oauth-pool-tool.mjs";

// ---------------------------------------------------------------------------
// Account selection (rotation)
// ---------------------------------------------------------------------------

/**
 * Compare two accounts for rotation preference.
 * Primary: priority descending (higher priority first; missing/0 = default).
 * Secondary: lastUsed ascending (least recently used first, i.e. LRU).
 */
function compareAccountPriority(a, b) {
  const pa = a.priority || 0;
  const pb = b.priority || 0;
  if (pa !== pb) return pb - pa;
  return new Date(a.lastUsed || 0).getTime() - new Date(b.lastUsed || 0).getTime();
}

function openCodeAuthPath() {
  const dataHome = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  return join(dataHome, "opencode", "auth.json");
}

export function readCurrentOpenAIAuth() {
  const authPath = openCodeAuthPath();
  if (!existsSync(authPath)) return null;
  try {
    return JSON.parse(readFileSync(authPath, "utf-8")).openai || null;
  } catch {
    return null;
  }
}

function matchesOpenAIAuth(account, auth) {
  if (!auth) return false;
  const same = (left, right) => Boolean(left && right && left === right);
  if (same(auth.accountId, account.accountId)) return true;
  if (same(auth.access, account.access)) return true;
  return same(auth.refresh, account.refresh);
}

function isAvailableAccount(account, now = Date.now()) {
  return ["active", "idle"].includes(account.status) && (!account.cooldownUntil || account.cooldownUntil <= now);
}

/**
 * Generic pool account selection (shared by all inject functions).
 * Finds the best available account with a valid token.
 */
async function selectPoolAccount(provider, skipEmail) {
  const accounts = getAccounts(provider);
  if (accounts.length === 0) return null;
  normalizeExpiredCooldowns(provider, accounts);
  const now = Date.now();
  const sorted = [...accounts]
    .filter((a) => isAvailableAccount(a, now) && a.email !== skipEmail)
    .sort(compareAccountPriority);
  for (const c of sorted) {
    if (await ensureValidToken(provider, c)) return c;
    console.error(`[aidevops] OAuth pool: skipping invalid ${provider} token for ${c.email}`);
  }
  const fb = accounts.find((a) => isAvailableAccount(a, now) && a.email !== skipEmail);
  if (fb && await ensureValidToken(provider, fb)) return fb;
  return null;
}

export async function selectOpenAIStartupAccount(skipEmail) {
  const accounts = getAccounts("openai");
  if (accounts.length === 0) return null;
  normalizeExpiredCooldowns("openai", accounts);
  const currentAuth = readCurrentOpenAIAuth();
  const current = accounts.find((a) => a.email !== skipEmail && matchesOpenAIAuth(a, currentAuth));
  // Startup should preserve a manually rotated, still-valid OpenAI auth entry.
  // Only fall through to pool priority/LRU selection when that current account
  // is unavailable or cannot be refreshed.
  if (current && isAvailableAccount(current) && await ensureValidToken("openai", current)) return current;
  return selectPoolAccount("openai", skipEmail);
}

/**
 * Select a valid OpenAI account for a discrete request. An explicit email is
 * pinned: unavailable or invalid accounts fail instead of falling back.
 */
export async function selectOpenAIRequestAccount(email) {
  const requestedEmail = String(email || "").trim();
  if (!requestedEmail) return selectOpenAIStartupAccount();
  const accounts = getAccounts("openai");
  normalizeExpiredCooldowns("openai", accounts);
  const account = accounts.find((candidate) => candidate.email === requestedEmail);
  if (!account || !isAvailableAccount(account)) return null;
  return await ensureValidToken("openai", account) ? account : null;
}

// ---------------------------------------------------------------------------
// Token injection — inject selected account into provider auth
// ---------------------------------------------------------------------------

export async function injectPoolToken(client, skipEmail) {
  const account = await selectPoolAccount("anthropic", skipEmail);
  if (!account) return false;
  process.env.ANTHROPIC_API_KEY = account.access;
  try {
    await client.auth.set({
      path: { id: "anthropic" },
      body: { type: "oauth", refresh: account.refresh, access: account.access, expires: account.expires },
    });
  } catch { /* best-effort */ }
  patchAccount("anthropic", account.email, { lastUsed: new Date().toISOString(), status: "active" });
  console.error(`[aidevops] OAuth pool: injected token for ${account.email} into built-in anthropic provider`);
  return true;
}

export async function applyOpenAIPoolAccount(client, account) {
  process.env.OPENAI_API_KEY = account.access;
  process.env.AIDEVOPS_OPENAI_API_KEY_SOURCE = "oauth-pool";
  try {
    await client.auth.set({
      path: { id: "openai" },
      body: { type: "oauth", refresh: account.refresh, access: account.access, expires: account.expires, accountId: account.accountId || "" },
    });
  } catch { /* best-effort */ }
  patchAccount("openai", account.email, { lastUsed: new Date().toISOString(), status: "active" });
  console.error(`[aidevops] OAuth pool: injected token for ${account.email} into built-in openai provider`);
  return account;
}

export async function rotateOpenAIPoolToken(client, skipEmail) {
  const account = await selectPoolAccount("openai", skipEmail);
  if (!account) return false;
  return applyOpenAIPoolAccount(client, account);
}

export async function injectOpenAIPoolToken(client, skipEmail) {
  const account = await selectOpenAIStartupAccount(skipEmail);
  if (!account) return false;
  await applyOpenAIPoolAccount(client, account);
  return true;
}

// ---------------------------------------------------------------------------
// Cursor gRPC proxy lifecycle (t1549, t1551)
// ---------------------------------------------------------------------------

const cursorProxy = {
  port: null,
  baseURL: CURSOR_PROXY_BASE_URL,
};

export async function ensureCursorProxy(client) {
  if (cursorProxy.port) return cursorProxy.baseURL;

  try {
    const { startCursorProxy, getCursorProxyPort } = await import("./cursor-proxy.mjs");
    const existingPort = getCursorProxyPort();
    if (existingPort) {
      cursorProxy.port = existingPort;
      cursorProxy.baseURL = `http://${CURSOR_PROXY_HOST}:${existingPort}/v1`;
      return cursorProxy.baseURL;
    }
    const result = await startCursorProxy(client);
    if (result && result.port) {
      cursorProxy.port = result.port;
      cursorProxy.baseURL = `http://${CURSOR_PROXY_HOST}:${result.port}/v1`;
      console.error(`[aidevops] OAuth pool: cursor gRPC proxy running on port ${result.port}`);
      return cursorProxy.baseURL;
    }
    throw new Error("gRPC proxy returned no port");
  } catch (err) {
    console.error(`[aidevops] OAuth pool: cursor gRPC proxy failed: ${err.message}`);
    throw err;
  }
}

export function stopCursorProxy() {
  if (cursorProxy.port) {
    try {
      import("./cursor-proxy.mjs").then(({ stopCursorGrpcProxy }) => {
        stopCursorGrpcProxy();
      }).catch(() => {});
    } catch { /* ignore */ }
    cursorProxy.port = null;
    cursorProxy.baseURL = CURSOR_PROXY_BASE_URL;
    console.error("[aidevops] OAuth pool: cursor proxy stopped");
  }
}

export async function injectCursorPoolToken(client, skipEmail) {
  const account = await selectPoolAccount("cursor", skipEmail);
  if (!account) return false;

  try {
    await ensureCursorProxy(client);
  } catch (err) {
    console.error(`[aidevops] OAuth pool: cursor proxy failed to start: ${err.message}`);
  }

  try {
    await client.auth.set({
      path: { id: "cursor" },
      body: { type: "api", key: "cursor-pool" },
    });
    patchAccount("cursor", account.email, { lastUsed: new Date().toISOString(), status: "active" });
    console.error(`[aidevops] OAuth pool: injected Cursor token for ${account.email}`);
    return true;
  } catch (err) {
    console.error(`[aidevops] OAuth pool: failed to inject Cursor token: ${err.message}`);
    return false;
  }
}

export async function injectGooglePoolToken(client, skipEmail) {
  const account = await selectPoolAccount("google", skipEmail);
  if (!account) return false;
  process.env.GOOGLE_OAUTH_ACCESS_TOKEN = account.access;
  patchAccount("google", account.email, { lastUsed: new Date().toISOString(), status: "active" });
  console.error(`[aidevops] OAuth pool: injected Google token for ${account.email} as GOOGLE_OAUTH_ACCESS_TOKEN`);
  return true;
}

// ---------------------------------------------------------------------------
// Inject function resolver (used by tool rotation)
// ---------------------------------------------------------------------------

const INJECT_FN_MAP = {
  cursor: injectCursorPoolToken,
  openai: injectOpenAIPoolToken,
  google: injectGooglePoolToken,
};

export function resolveInjectFn(provider) {
  return INJECT_FN_MAP[provider] || injectPoolToken;
}

// ---------------------------------------------------------------------------
// Auth hook initialization
// ---------------------------------------------------------------------------

export async function initPoolAuth(client) {
  await injectPoolToken(client);
  await injectOpenAIPoolToken(client);
  await injectCursorPoolToken(client);
  // Google: isolated — failure does not affect other providers
  try { await injectGooglePoolToken(client); } catch (err) {
    console.error(`[aidevops] OAuth pool: Google token injection failed (isolated): ${err.message}`);
  }
}
