// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import { startOAuthCallbackServer } from "../oauth-pool-callback.mjs";

test("callback server preserves the public re-export and captures valid codes", async () => {
  const server = startOAuthCallbackServer("expected-state");

  try {
    assert.equal(await server.ready, true);
    const response = await fetch(
      "http://127.0.0.1:1455/auth/callback?code=test-code&state=expected-state",
    );

    assert.equal(response.status, 200);
    assert.match(await response.text(), /Authorization Successful/);
    assert.equal(await server.promise, "test-code");
  } finally {
    server.close();
  }
});

test("callback server rejects mismatched OAuth state", async () => {
  const server = startOAuthCallbackServer("expected-state");
  const rejection = assert.rejects(server.promise, /OAuth state mismatch/);

  try {
    assert.equal(await server.ready, true);
    const response = await fetch(
      "http://127.0.0.1:1455/auth/callback?code=test-code&state=wrong-state",
    );

    assert.equal(response.status, 400);
    await rejection;
  } finally {
    server.close();
  }
});

test("callback server escapes OAuth errors and rejects the pending code", async () => {
  const server = startOAuthCallbackServer("expected-state");
  const unsafeError = "<img src=x onerror=alert(1)>";
  const rejection = assert.rejects(server.promise, /OAuth error: <img src=x onerror=alert\(1\)>/);

  try {
    assert.equal(await server.ready, true);
    const description = encodeURIComponent('<script>"not allowed"</script>');
    const error = encodeURIComponent(unsafeError);
    const response = await fetch(
      `http://127.0.0.1:1455/auth/callback?error=${error}&error_description=${description}&state=expected-state`,
    );
    const body = await response.text();

    assert.equal(response.status, 200);
    assert.match(body, /&lt;img src=x onerror=alert\(1\)&gt;/);
    assert.match(body, /&lt;script&gt;&quot;not allowed&quot;&lt;\/script&gt;/);
    assert.equal(body.includes(unsafeError), false);
    assert.doesNotMatch(body, /<script>/);
    await rejection;

    const rebound = startOAuthCallbackServer("rebound-state");
    try {
      assert.equal(await rebound.ready, true);
    } finally {
      rebound.close();
    }
  } finally {
    server.close();
  }
});

test("closing the callback server releases the loopback port", async () => {
  const first = startOAuthCallbackServer("first-state");
  assert.equal(await first.ready, true);
  first.close();

  const second = startOAuthCallbackServer("second-state");
  try {
    assert.equal(await second.ready, true);
  } finally {
    second.close();
  }
});
