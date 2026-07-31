// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth pool provider registration.
 *
 * Kept separate from the provider authorization flows so configuration repair
 * does not contribute to the auth hook module's file complexity.
 *
 * @module oauth-pool-auth-provider
 */

import { CURSOR_PROXY_BASE_URL } from "./oauth-pool-constants.mjs";

const PROVIDER_DEFINITIONS = [
  { id: "anthropic-pool", name: "Anthropic Pool (Account Management)", npm: "@ai-sdk/anthropic", api: "https://api.anthropic.com/v1", mn: "[Account Setup Only] Use Anthropic provider for models" },
  { id: "openai-pool", name: "OpenAI Pool (Account Management)", npm: "@ai-sdk/openai", api: "https://api.openai.com/v1", mn: "[Account Setup Only] Use OpenAI provider for models" },
  { id: "cursor-pool", name: "Cursor Pool (Account Management)", npm: "@ai-sdk/openai-compatible", api: CURSOR_PROXY_BASE_URL, mn: "[Account Setup Only] Use Cursor provider for models" },
  { id: "google-pool", name: "Google Pool (Account Management)", npm: "@ai-sdk/google", api: "https://generativelanguage.googleapis.com/v1beta", mn: "[Account Setup Only] Token injected as GOOGLE_OAUTH_ACCESS_TOKEN" },
];

function providerModels(name) {
  return {
    "pool-account-management": {
      name, attachment: false, tool_call: false, temperature: false,
      modalities: { input: ["text"], output: ["text"] },
      cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
      limit: { context: 1000, output: 100 }, family: "pool",
    },
  };
}

export function registerPoolProvider(config) {
  if (!config.provider) config.provider = {};
  let registered = 0;
  for (const def of PROVIDER_DEFINITIONS) {
    const models = providerModels(def.mn);
    if (!config.provider[def.id]) {
      config.provider[def.id] = { name: def.name, npm: def.npm, api: def.api, models };
      registered++;
    } else {
      const existing = config.provider[def.id];
      if (existing.name !== def.name || existing.npm !== def.npm || existing.api !== def.api || JSON.stringify(existing.models) !== JSON.stringify(models)) {
        Object.assign(existing, { name: def.name, npm: def.npm, api: def.api, models });
        registered++;
      }
    }
  }
  return registered;
}
