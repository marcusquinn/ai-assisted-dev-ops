// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import { registerPoolProvider } from "../oauth-pool-auth.mjs";

test("registerPoolProvider remains available through the auth module", () => {
  const config = {};

  assert.equal(registerPoolProvider(config), 4);
  assert.deepEqual(Object.keys(config.provider).sort(), [
    "anthropic-pool",
    "cursor-pool",
    "google-pool",
    "openai-pool",
  ]);
  assert.equal(config.provider["openai-pool"].npm, "@ai-sdk/openai");
  assert.equal(config.provider["cursor-pool"].api, "http://127.0.0.1:32123/v1");
  assert.equal(registerPoolProvider(config), 0);
});

test("registerPoolProvider repairs stale definitions without dropping extras", () => {
  const config = {
    provider: {
      "anthropic-pool": {
        name: "stale",
        npm: "stale",
        api: "stale",
        models: {},
        options: { custom: true },
      },
    },
  };

  assert.equal(registerPoolProvider(config), 4);
  assert.equal(config.provider["anthropic-pool"].name, "Anthropic Pool (Account Management)");
  assert.deepEqual(config.provider["anthropic-pool"].options, { custom: true });
});
