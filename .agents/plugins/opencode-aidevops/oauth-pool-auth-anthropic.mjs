// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — Anthropic Auth Hook
 *
 * @module oauth-pool-auth-anthropic
 */

import {
  ANTHROPIC_CLIENT_ID, ANTHROPIC_OAUTH_AUTHORIZE_URL,
  ANTHROPIC_REDIRECT_URI, ANTHROPIC_OAUTH_SCOPES,
} from "./oauth-pool-constants.mjs";
import { getAccounts } from "./oauth-pool-storage.mjs";
import {
  generatePKCE, generateState, makeEmailPrompt,
} from "./oauth-pool-callback.mjs";
import { handleAnthropicCallback } from "./oauth-pool-auth-handlers.mjs";

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
