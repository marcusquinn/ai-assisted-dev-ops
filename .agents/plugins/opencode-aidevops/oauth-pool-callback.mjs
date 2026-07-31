/**
 * OAuth Pool — Callback Server & Auth Helpers (t2128)
 *
 * PKCE generation, local OAuth callback HTTP server, email resolution
 * from JWT claims and API endpoints, and shared auth-hook helper functions.
 *
 * Extracted from oauth-pool-auth.mjs for complexity reduction.
 *
 * @module oauth-pool-callback
 */

import { createHash, randomBytes } from "crypto";
import {
  getAccounts, upsertAccount, savePendingToken,
} from "./oauth-pool-storage.mjs";
import { startOAuthCallbackServer } from "./oauth-pool-callback-server.mjs";

export { startOAuthCallbackServer };

// ---------------------------------------------------------------------------
// PKCE helpers
// ---------------------------------------------------------------------------

export function generatePKCE() {
  const verifier = randomBytes(32)
    .toString("base64url")
    .replace(/[^a-zA-Z0-9\-._~]/g, "")
    .slice(0, 128);
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

/**
 * Generate a cryptographically random OAuth state nonce.
 * Use this as the `state` parameter in every authorize URL instead of
 * reusing the PKCE verifier, which must remain secret.
 * @returns {string}
 */
export function generateState() {
  return randomBytes(32).toString("base64url");
}

// ---------------------------------------------------------------------------
// Email resolution helpers
// ---------------------------------------------------------------------------

export function resolveEmailFromJWTClaims(token, claimKeys = ["email", "sub"]) {
  try {
    const parts = token.split(".");
    if (parts.length < 2) return null;
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf-8"));
    for (const key of claimKeys) {
      const val = key.includes(".")
        ? key.split(".").reduce((o, k) => o?.[k], payload)
        : payload[key];
      if (val) return val;
    }
    return null;
  } catch { return null; }
}

export async function resolveEmailFromEndpoint(accessToken, endpoint, extraHeaders = {}, emailFields = ["email", "sub"]) {
  try {
    const resp = await fetch(endpoint, {
      headers: { "Authorization": `Bearer ${accessToken}`, ...extraHeaders },
      redirect: "follow",
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    for (const field of emailFields) {
      const value = field.includes(".")
        ? field.split(".").reduce((o, k) => o?.[k], data)
        : data[field];
      if (value) return value;
    }
    return null;
  } catch { return null; }
}

export function extractOpenAIAccountId(accessToken) {
  try {
    const parts = accessToken.split(".");
    if (parts.length < 2) return "";
    const p = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf-8"));
    return p.chatgpt_account_id || p["https://api.openai.com/auth"]?.chatgpt_account_id || p.organizations?.[0]?.id || "";
  } catch { return ""; }
}

// ---------------------------------------------------------------------------
// Email prompt builder
// ---------------------------------------------------------------------------

export function makeEmailPrompt(provider, placeholder = "you@example.com") {
  return {
    type: "text", key: "email",
    get message() {
      const accounts = getAccounts(provider);
      if (accounts.length === 0) return "Account email (required to match tokens to accounts)";
      return `Existing accounts:\n${accounts.map((a, i) => `  ${i + 1}. ${a.email}`).join("\n")}\nEnter email (existing to re-auth, or new to add)`;
    },
    placeholder,
    validate: (v) => (!v || !v.includes("@")) ? "Please enter a valid email address" : undefined,
  };
}

// ---------------------------------------------------------------------------
// Shared save-and-inject helper
// ---------------------------------------------------------------------------

export async function saveAccountAndInject(opts) {
  const { provider, client, email, tokenData, extras = {}, envKey, authId, injectFn, successExtras = {} } = opts;
  const now = new Date().toISOString();
  const saved = upsertAccount(provider, {
    email, ...tokenData, ...extras, added: now, lastUsed: now, status: "active", cooldownUntil: null,
  });
  if (!saved) {
    savePendingToken(provider, { ...tokenData, ...extras, added: now });
    if (envKey && tokenData.access) process.env[envKey] = tokenData.access;
    if (authId) {
      try { await client.auth.set({ path: { id: authId }, body: { type: "oauth", ...tokenData, ...extras } }); }
      catch { /* best-effort */ }
    }
    return { type: "success", ...tokenData, ...successExtras };
  }
  const total = getAccounts(provider).length;
  console.error(`[aidevops] OAuth pool: added ${email} (${total} account${total === 1 ? "" : "s"} total)`);
  const INSTR = {
    anthropic: 'Switch to "Anthropic" provider for models.',
    openai: 'Switch to "OpenAI" provider for models.',
    cursor: 'Switch to "Cursor" provider for models.',
    google: "Token injected as GOOGLE_OAUTH_ACCESS_TOKEN.",
  };
  console.error(`[aidevops] OAuth pool: Account added successfully. ${INSTR[provider] || ""}`);
  await injectFn(client);
  return { type: "success", ...tokenData, ...successExtras };
}

// ---------------------------------------------------------------------------
// Callback server helpers
// ---------------------------------------------------------------------------

export async function initCallbackServerSafe(expectedState) {
  try {
    const server = startOAuthCallbackServer(expectedState);
    const ready = await server.ready.catch(() => false);
    if (!ready) {
      console.error("[aidevops] OAuth pool: callback server failed -- manual code paste required");
      return { server: null, ready: false, code: null };
    }
    const state = { server, ready: true, code: null };
    server.promise.then((c) => { state.code = c; }).catch(() => { state.server = null; });
    return state;
  } catch {
    console.error("[aidevops] OAuth pool: callback server failed -- manual code paste required");
    return { server: null, ready: false, code: null };
  }
}

export async function acquireAuthCode(manualCode, cs) {
  const trimmed = manualCode?.trim() || "";
  if (trimmed.length >= 5) {
    if (cs.server) cs.server.close();
    return trimmed;
  }
  if (cs.code) {
    console.error("[aidevops] OAuth pool: using auto-captured code");
    if (cs.server) cs.server.close();
    return cs.code;
  }
  if (cs.ready && cs.server) {
    try {
      const code = await Promise.race([
        cs.server.promise,
        new Promise((_, r) => setTimeout(() => r(new Error("timeout")), 30_000)),
      ]);
      console.error("[aidevops] OAuth pool: received code from callback server");
      cs.server.close();
      return code;
    } catch {
      console.error("[aidevops] OAuth pool: no code received");
      cs.server.close();
      return null;
    }
  }
  if (cs.server) cs.server.close();
  return null;
}
