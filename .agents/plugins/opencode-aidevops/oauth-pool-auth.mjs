/**
 * OAuth Pool — Auth Hooks & Handlers (t2128 refactor)
 *
 * Re-exports the browser OAuth provider hooks and contains the lightweight
 * Cursor API auth hook. Token exchange handlers live in
 * oauth-pool-auth-handlers.mjs, and provider registration is re-exported from
 * oauth-pool-auth-provider.mjs.
 *
 * Depends on: oauth-pool-storage, oauth-pool-callback, and
 * oauth-pool-auth-handlers.
 *
 * @module oauth-pool-auth
 */

import { getAccounts } from "./oauth-pool-storage.mjs";
import { makeEmailPrompt } from "./oauth-pool-callback.mjs";
import { handleCursorAuthorize } from "./oauth-pool-auth-handlers.mjs";

// ---------------------------------------------------------------------------
// Auth hooks (thin wrappers)
// ---------------------------------------------------------------------------

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

export { createPoolAuthHook } from "./oauth-pool-auth-anthropic.mjs";
export { createOpenAIPoolAuthHook } from "./oauth-pool-auth-openai.mjs";
export { createGooglePoolAuthHook } from "./oauth-pool-auth-google.mjs";
export { registerPoolProvider } from "./oauth-pool-auth-provider.mjs";
