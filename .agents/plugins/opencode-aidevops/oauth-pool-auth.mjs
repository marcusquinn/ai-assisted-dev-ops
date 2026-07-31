/**
 * OAuth Pool — Auth Hooks & Handlers (t2128 refactor)
 *
 * Contains: provider auth hooks (anthropic, openai, cursor, google)
 * and token exchange handlers. Provider registration is re-exported
 * from oauth-pool-auth-provider.mjs.
 *
 * Depends on: oauth-pool-constants, oauth-pool-token-endpoint,
 * oauth-pool-storage, oauth-pool-refresh, oauth-pool-callback,
 * and oauth-pool.mjs (for inject functions).
 *
 * @module oauth-pool-auth
 */

import { execSync } from "child_process";

import {
  ANTHROPIC_CLIENT_ID, ANTHROPIC_OAUTH_AUTHORIZE_URL,
  ANTHROPIC_REDIRECT_URI, ANTHROPIC_OAUTH_SCOPES,
  OPENAI_CLIENT_ID, OPENAI_OAUTH_AUTHORIZE_URL,
  OPENAI_REDIRECT_URI, OPENAI_OAUTH_SCOPES,
  GOOGLE_CLIENT_ID, GOOGLE_OAUTH_AUTHORIZE_URL,
  GOOGLE_REDIRECT_URI, GOOGLE_OAUTH_SCOPES,
} from "./oauth-pool-constants.mjs";

import {
  ANTHROPIC_USER_AGENT, OPENCODE_USER_AGENT,
  fetchTokenEndpoint, fetchOpenAITokenEndpoint, fetchGoogleTokenEndpoint,
} from "./oauth-pool-token-endpoint.mjs";

import { getAccounts } from "./oauth-pool-storage.mjs";

import {
  decodeCursorJWT, readCursorAuthJsonCredentials,
  readCursorStateDbCredentials, isCursorAgentAvailable,
} from "./oauth-pool-refresh.mjs";

import {
  generatePKCE, generateState, makeEmailPrompt, saveAccountAndInject,
  resolveEmailFromJWTClaims, resolveEmailFromEndpoint,
  extractOpenAIAccountId, acquireAuthCode, initCallbackServerSafe,
} from "./oauth-pool-callback.mjs";

import {
  injectPoolToken, injectOpenAIPoolToken,
  injectCursorPoolToken, injectGooglePoolToken,
} from "./oauth-pool.mjs";

import { OPENAI_ISSUER } from "./oauth-pool-constants.mjs";

// ---------------------------------------------------------------------------
// Anthropic email resolution
// ---------------------------------------------------------------------------

async function resolveAnthropicEmail(accessToken) {
  for (const endpoint of [
    "https://console.anthropic.com/api/auth/user",
    "https://api.anthropic.com/api/auth/user",
  ]) {
    const email = await resolveEmailFromEndpoint(
      accessToken, endpoint,
      { "User-Agent": ANTHROPIC_USER_AGENT },
      ["email", "email_address", "user.email", "account.email"],
    );
    if (email) {
      console.error(`[aidevops] OAuth pool: resolved email ${email} from ${endpoint}`);
      return email;
    }
  }
  console.error("[aidevops] OAuth pool: could not resolve email from profile API");
  return null;
}

// ---------------------------------------------------------------------------
// Provider callback handlers
// ---------------------------------------------------------------------------

async function handleAnthropicCallback(code, pkce, expectedState, email, client) {
  const hashIdx = code.indexOf("#");
  const authCode = hashIdx >= 0 ? code.substring(0, hashIdx) : code;
  const returnedState = hashIdx >= 0 ? code.substring(hashIdx + 1) : undefined;
  // Validate state when present. In manual code-paste flows the user may paste
  // only the authorization code without the state fragment, so we accept absent
  // state rather than failing valid flows. When state IS returned it must match.
  if (returnedState !== undefined && returnedState !== expectedState) {
    console.error("[aidevops] OAuth pool: Anthropic state mismatch — possible CSRF");
    return { type: "failed" };
  }
  const result = await fetchTokenEndpoint(
    JSON.stringify({
      code: authCode, state: returnedState, grant_type: "authorization_code",
      client_id: ANTHROPIC_CLIENT_ID, redirect_uri: ANTHROPIC_REDIRECT_URI,
      code_verifier: pkce.verifier,
    }),
    "token exchange",
  );
  if (!result.ok) return { type: "failed" };
  const json = await result.json();
  let resolvedEmail = email;
  if (resolvedEmail === "unknown" && json.access_token) {
    resolvedEmail = (await resolveAnthropicEmail(json.access_token)) || "unknown";
  }
  return saveAccountAndInject({
    provider: "anthropic", client, email: resolvedEmail,
    tokenData: { refresh: json.refresh_token, access: json.access_token, expires: Date.now() + json.expires_in * 1000 },
    envKey: "ANTHROPIC_API_KEY", authId: "anthropic", injectFn: injectPoolToken,
  });
}

async function handleOpenAICallback(code, pkce, email, callbackState, client) {
  const authCode = await acquireAuthCode(code, callbackState);
  if (!authCode) return { type: "failed" };
  const cleanCode = authCode.split(/[&#?]/)[0];
  const params = new URLSearchParams({
    grant_type: "authorization_code", code: cleanCode,
    redirect_uri: OPENAI_REDIRECT_URI, client_id: OPENAI_CLIENT_ID,
    code_verifier: pkce.verifier,
  });
  const result = await fetchOpenAITokenEndpoint(params, "token exchange");
  if (!result.ok) return { type: "failed" };
  const json = await result.json();
  let resolvedEmail = email;
  let accountId = "";
  if (json.access_token) {
    accountId = extractOpenAIAccountId(json.access_token);
    if (resolvedEmail === "unknown") resolvedEmail = resolveEmailFromJWTClaims(json.access_token) || "unknown";
    if (resolvedEmail === "unknown") {
      resolvedEmail = (await resolveEmailFromEndpoint(
        json.access_token, `${OPENAI_ISSUER}/userinfo`, { "User-Agent": OPENCODE_USER_AGENT },
      )) || "unknown";
      if (resolvedEmail !== "unknown") console.error(`[aidevops] OAuth pool: resolved OpenAI email ${resolvedEmail}`);
    }
  }
  return saveAccountAndInject({
    provider: "openai", client, email: resolvedEmail,
    tokenData: { refresh: json.refresh_token || "", access: json.access_token, expires: Date.now() + (json.expires_in || 3600) * 1000 },
    extras: { accountId }, envKey: "OPENAI_API_KEY", authId: "openai", injectFn: injectOpenAIPoolToken,
  });
}

async function handleCursorAuthorize(email, client) {
  let creds = readCursorAuthJsonCredentials(email);
  if (creds) console.error("[aidevops] OAuth pool: found Cursor credentials in auth.json");
  if (!creds) {
    creds = readCursorStateDbCredentials(email);
    if (creds) console.error("[aidevops] OAuth pool: found Cursor credentials in state DB");
  }
  if (!creds) {
    if (!isCursorAgentAvailable()) {
      console.error("[aidevops] OAuth pool: cursor-agent not found");
      return { type: "failed" };
    }
    console.error("[aidevops] OAuth pool: running cursor-agent login...");
    try {
      execSync("cursor-agent login", { encoding: "utf-8", timeout: 120_000, stdio: ["inherit", "pipe", "pipe"] });
      creds = readCursorAuthJsonCredentials(email);
    } catch (err) {
      console.error(`[aidevops] OAuth pool: cursor-agent login failed: ${err.message}`);
      return { type: "failed" };
    }
  }
  if (!creds) {
    console.error("[aidevops] OAuth pool: no Cursor access token obtained");
    return { type: "failed" };
  }
  const resolvedEmail = (email === "unknown" && creds.email) ? creds.email : email;
  const tokenInfo = decodeCursorJWT(creds.access);
  return saveAccountAndInject({
    provider: "cursor", client, email: resolvedEmail,
    tokenData: { refresh: creds.refresh || "", access: creds.access, expires: tokenInfo.expiresAt || (Date.now() + 3600_000) },
    injectFn: injectCursorPoolToken, successExtras: { key: "cursor-pool" },
  });
}

// NOTE: expectedState cannot be validated in this flow. GOOGLE_REDIRECT_URI is
// the OOB (urn:ietf:wg:oauth:2.0:oob) redirect, which causes Google to display
// the authorization code directly in the browser page rather than performing an
// HTTP redirect. Because there is no redirect, the state nonce is never returned
// to our process. We still include state in the authorize URL to prevent
// redirect-level CSRF; the absence of callback-side validation is an inherent
// limitation of the OOB grant type, not a fixable bug in this code.
// eslint-disable-next-line no-unused-vars
async function handleGoogleCallback(code, pkce, expectedState, email, client) {
  const authCode = code?.trim();
  if (!authCode || authCode.length < 5) return { type: "failed" };
  const result = await fetchGoogleTokenEndpoint(
    JSON.stringify({
      code: authCode, grant_type: "authorization_code",
      client_id: GOOGLE_CLIENT_ID, redirect_uri: GOOGLE_REDIRECT_URI,
      code_verifier: pkce.verifier,
    }),
    "Google token exchange",
  );
  if (!result.ok) return { type: "failed" };
  const json = await result.json();
  let resolvedEmail = email;
  if (json.id_token && resolvedEmail === "unknown") {
    resolvedEmail = resolveEmailFromJWTClaims(json.id_token) || "unknown";
    if (resolvedEmail !== "unknown") console.error(`[aidevops] OAuth pool: resolved Google email ${resolvedEmail} from ID token`);
  }
  if (resolvedEmail === "unknown" && json.access_token) {
    resolvedEmail = (await resolveEmailFromEndpoint(json.access_token, "https://www.googleapis.com/oauth2/v3/userinfo")) || "unknown";
    if (resolvedEmail !== "unknown") console.error(`[aidevops] OAuth pool: resolved Google email ${resolvedEmail}`);
  }
  return saveAccountAndInject({
    provider: "google", client, email: resolvedEmail,
    tokenData: { refresh: json.refresh_token || "", access: json.access_token, expires: Date.now() + (json.expires_in || 3600) * 1000 },
    envKey: "GOOGLE_OAUTH_ACCESS_TOKEN", injectFn: injectGooglePoolToken,
  });
}

// ---------------------------------------------------------------------------
// Auth hooks (thin wrappers)
// ---------------------------------------------------------------------------

export function createPoolAuthHook(client) {
  return {
    provider: "anthropic-pool",
    methods: [{
      get label() {
        const a = getAccounts("anthropic");
        return a.length === 0
          ? "Add Account to Pool (Claude Pro/Max)"
          : `Add Account to Pool (${a.length} account${a.length === 1 ? "" : "s"})`;
      },
      type: "oauth",
      prompts: [makeEmailPrompt("anthropic")],
      authorize: async (inputs) => {
        const email = inputs?.email || "unknown";
        const pkce = generatePKCE();
        const state = generateState(); // separate nonce — pkce.verifier stays secret
        const url = new URL(ANTHROPIC_OAUTH_AUTHORIZE_URL);
        url.searchParams.set("code", "true");
        url.searchParams.set("client_id", ANTHROPIC_CLIENT_ID);
        url.searchParams.set("response_type", "code");
        url.searchParams.set("redirect_uri", ANTHROPIC_REDIRECT_URI);
        url.searchParams.set("scope", ANTHROPIC_OAUTH_SCOPES);
        url.searchParams.set("code_challenge", pkce.challenge);
        url.searchParams.set("code_challenge_method", "S256");
        url.searchParams.set("state", state);
        return {
          url: url.toString(),
          instructions: `Adding account: ${email}\nPaste the authorization code here: `,
          method: "code",
          callback: (code) => handleAnthropicCallback(code, pkce, state, email, client),
        };
      },
    }],
  };
}

export function createOpenAIPoolAuthHook(client) {
  return {
    provider: "openai-pool",
    methods: [{
      get label() {
        const a = getAccounts("openai");
        return a.length === 0
          ? "Add Account to Pool (ChatGPT Plus/Pro)"
          : `Add Account to Pool (${a.length} account${a.length === 1 ? "" : "s"})`;
      },
      type: "oauth",
      prompts: [makeEmailPrompt("openai")],
      authorize: async (inputs) => {
        const email = inputs?.email || "unknown";
        const pkce = generatePKCE();
        const state = generateState(); // separate nonce — pkce.verifier stays secret
        const cs = await initCallbackServerSafe(state);
        const url = new URL(OPENAI_OAUTH_AUTHORIZE_URL);
        url.searchParams.set("client_id", OPENAI_CLIENT_ID);
        url.searchParams.set("response_type", "code");
        url.searchParams.set("redirect_uri", OPENAI_REDIRECT_URI);
        url.searchParams.set("scope", OPENAI_OAUTH_SCOPES);
        url.searchParams.set("code_challenge", pkce.challenge);
        url.searchParams.set("code_challenge_method", "S256");
        url.searchParams.set("state", state);
        return {
          url: url.toString(),
          instructions: [
            `Adding OpenAI account: ${email}`,
            "1. A browser window will open to auth.openai.com",
            "2. Sign in with your ChatGPT Plus/Pro account",
            cs.ready ? "3. The code will be captured automatically" : "3. Copy the authorization code from the browser URL",
            cs.ready ? "4. Press Enter here to complete (or paste manually): " : "4. Paste the authorization code here: ",
          ].join("\n"),
          method: "code",
          callback: (code) => handleOpenAICallback(code, pkce, email, cs, client),
        };
      },
    }],
  };
}

export function createCursorPoolAuthHook(client) {
  return {
    provider: "cursor-pool",
    methods: [{
      get label() {
        const a = getAccounts("cursor");
        return a.length === 0
          ? "Add Account to Pool (Cursor Pro)"
          : `Add Account to Pool (${a.length} account${a.length === 1 ? "" : "s"})`;
      },
      type: "api",
      prompts: [makeEmailPrompt("cursor")],
      authorize: (inputs) => handleCursorAuthorize(inputs?.email || "unknown", client),
    }],
  };
}

export function createGooglePoolAuthHook(client) {
  return {
    provider: "google-pool",
    methods: [{
      get label() {
        const a = getAccounts("google");
        return a.length === 0
          ? "Add Account to Pool (Google AI Pro/Ultra/Workspace)"
          : `Add Account to Pool (${a.length} account${a.length === 1 ? "" : "s"})`;
      },
      type: "oauth",
      prompts: [makeEmailPrompt("google", "you@gmail.com")],
      authorize: async (inputs) => {
        const email = inputs?.email || "unknown";
        const pkce = generatePKCE();
        const state = generateState(); // separate nonce — pkce.verifier stays secret
        const url = new URL(GOOGLE_OAUTH_AUTHORIZE_URL);
        url.searchParams.set("client_id", GOOGLE_CLIENT_ID);
        url.searchParams.set("response_type", "code");
        url.searchParams.set("redirect_uri", GOOGLE_REDIRECT_URI);
        url.searchParams.set("scope", GOOGLE_OAUTH_SCOPES);
        url.searchParams.set("code_challenge", pkce.challenge);
        url.searchParams.set("code_challenge_method", "S256");
        url.searchParams.set("access_type", "offline");
        url.searchParams.set("prompt", "consent");
        url.searchParams.set("state", state);
        return {
          url: url.toString(),
          instructions: [
            `Adding Google AI account: ${email}`,
            "1. A browser window will open to accounts.google.com",
            "2. Sign in with your Google AI Pro/Ultra or Workspace account",
            "3. Copy the authorization code shown in the browser",
            "4. Paste the authorization code here: ",
          ].join("\n"),
          method: "code",
          callback: (code) => handleGoogleCallback(code, pkce, state, email, client),
        };
      },
    }],
  };
}

export { registerPoolProvider } from "./oauth-pool-auth-provider.mjs";
