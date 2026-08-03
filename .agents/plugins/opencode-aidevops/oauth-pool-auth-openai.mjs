// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — OpenAI Auth Hook
 *
 * @module oauth-pool-auth-openai
 */

import {
  OPENAI_CLIENT_ID, OPENAI_OAUTH_AUTHORIZE_URL,
  OPENAI_REDIRECT_URI, OPENAI_OAUTH_SCOPES,
} from "./oauth-pool-constants.mjs";
import { getAccounts } from "./oauth-pool-storage.mjs";
import {
  generatePKCE, generateState, makeEmailPrompt, initCallbackServerSafe,
} from "./oauth-pool-callback.mjs";
import { handleOpenAICallback } from "./oauth-pool-auth-handlers.mjs";

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
