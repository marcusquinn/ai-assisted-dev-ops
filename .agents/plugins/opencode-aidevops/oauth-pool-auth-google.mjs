// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — Google Auth Hook
 *
 * @module oauth-pool-auth-google
 */

import {
  GOOGLE_CLIENT_ID, GOOGLE_OAUTH_AUTHORIZE_URL,
  GOOGLE_REDIRECT_URI, GOOGLE_OAUTH_SCOPES,
} from "./oauth-pool-constants.mjs";
import { getAccounts } from "./oauth-pool-storage.mjs";
import {
  generatePKCE, generateState, makeEmailPrompt,
} from "./oauth-pool-callback.mjs";
import { handleGoogleCallback } from "./oauth-pool-auth-handlers.mjs";

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
