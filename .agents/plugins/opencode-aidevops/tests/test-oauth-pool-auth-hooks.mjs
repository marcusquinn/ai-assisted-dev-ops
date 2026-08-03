// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  createPoolAuthHook, createOpenAIPoolAuthHook,
  createCursorPoolAuthHook, createGooglePoolAuthHook,
} from "../oauth-pool-auth.mjs";

test("pool auth hooks preserve provider and method metadata", () => {
  const hooks = [
    [createPoolAuthHook({}), "anthropic-pool", "oauth"],
    [createOpenAIPoolAuthHook({}), "openai-pool", "oauth"],
    [createCursorPoolAuthHook({}), "cursor-pool", "api"],
    [createGooglePoolAuthHook({}), "google-pool", "oauth"],
  ];

  for (const [hook, provider, type] of hooks) {
    assert.equal(hook.provider, provider);
    assert.equal(hook.methods.length, 1);
    assert.equal(hook.methods[0].type, type);
    assert.equal(hook.methods[0].prompts[0].key, "email");
    assert.equal(typeof hook.methods[0].authorize, "function");
  }
});

test("Anthropic authorization keeps PKCE and state callback wiring", async () => {
  const method = createPoolAuthHook({}).methods[0];
  const authorization = await method.authorize({ email: "account@example.test" });
  const url = new URL(authorization.url);

  assert.equal(url.searchParams.get("code"), "true");
  assert.equal(url.searchParams.get("response_type"), "code");
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  assert.ok(url.searchParams.get("code_challenge"));
  assert.ok(url.searchParams.get("state"));
  assert.match(authorization.instructions, /account@example\.test/);
  assert.equal(authorization.method, "code");
  assert.equal(typeof authorization.callback, "function");
});

test("Google authorization keeps offline consent and callback wiring", async () => {
  const method = createGooglePoolAuthHook({}).methods[0];
  const authorization = await method.authorize({ email: "account@example.test" });
  const url = new URL(authorization.url);

  assert.equal(url.searchParams.get("response_type"), "code");
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  assert.equal(url.searchParams.get("access_type"), "offline");
  assert.equal(url.searchParams.get("prompt"), "consent");
  assert.ok(url.searchParams.get("code_challenge"));
  assert.ok(url.searchParams.get("state"));
  assert.equal(authorization.method, "code");
  assert.equal(typeof authorization.callback, "function");
});
