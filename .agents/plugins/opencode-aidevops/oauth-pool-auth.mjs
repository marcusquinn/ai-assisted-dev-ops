/**
 * OAuth Pool — Auth Hooks & Handlers (t2128 refactor)
 *
 * Contains provider auth hooks (anthropic, openai, cursor, google).
 * Token exchange handlers live in oauth-pool-auth-handlers.mjs, and provider
 * registration is re-exported from oauth-pool-auth-provider.mjs.
 *
 * Depends on: oauth-pool-constants, oauth-pool-storage, oauth-pool-callback,
 * and oauth-pool-auth-handlers.
 *
 * @module oauth-pool-auth
 */

import {
  ANTHROPIC_CLIENT_ID, ANTHROPIC_OAUTH_AUTHORIZE_URL,
  ANTHROPIC_REDIRECT_URI, ANTHROPIC_OAUTH_SCOPES,
  OPENAI_CLIENT_ID, OPENAI_OAUTH_AUTHORIZE_URL,
  OPENAI_REDIRECT_URI, OPENAI_OAUTH_SCOPES,
  GOOGLE_CLIENT_ID, GOOGLE_OAUTH_AUTHORIZE_URL,
  GOOGLE_REDIRECT_URI, GOOGLE_OAUTH_SCOPES,
} from "./oauth-pool-constants.mjs";

import { getAccounts } from "./oauth-pool-storage.mjs";

import {
  generatePKCE, generateState, makeEmailPrompt, initCallbackServerSafe,
} from "./oauth-pool-callback.mjs";

import {
  handleAnthropicCallback, handleOpenAICallback,
  handleCursorAuthorize, handleGoogleCallback,
} from "./oauth-pool-auth-handlers.mjs";

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
