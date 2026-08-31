import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

function loadModule() {
  return import(`../openai-provider-auth.mjs?test=${Date.now()}-${Math.random()}`);
}

function runProviderScript(prefix, script) {
  const home = mkdtempSync(join(tmpdir(), prefix));
  execFileSync(process.execPath, ["--input-type=module", "--eval", script], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, HOME: home, XDG_DATA_HOME: join(home, ".local", "share") },
    stdio: "pipe",
  });
}

test("detects OpenAI provider requests only", async () => {
  const { isOpenAIProviderRequest, isOpenAITokenRefreshRequest } = await loadModule();
  assert.equal(isOpenAIProviderRequest("https://api.openai.com/v1/chat/completions"), true);
  assert.equal(isOpenAIProviderRequest("https://api.openai.com/dashboard"), false);
  assert.equal(isOpenAIProviderRequest("https://example.com/v1/chat/completions"), false);
  assert.equal(isOpenAITokenRefreshRequest("https://auth.openai.com/oauth/token"), true);
  assert.equal(isOpenAITokenRefreshRequest("https://api.openai.com/v1/responses"), false);
});

test("detects OpenAI usage-limit responses", async () => {
  const { isOpenAIUsageLimitResponse } = await loadModule();
  const quota = new Response(JSON.stringify({ error: { code: "insufficient_quota", message: "Usage limit reached" } }), {
    status: 403,
    headers: { "content-type": "application/json" },
  });
  assert.equal(await isOpenAIUsageLimitResponse(quota), true);
  assert.equal(await isOpenAIUsageLimitResponse(new Response("ok", { status: 200 })), false);
});

test("injects optional intent into OpenAI provider tool-schema variants", async () => {
  const { transformOpenAIRequestBody } = await loadModule();
  const source = JSON.stringify({
    tools: [
      {
        type: "function",
        name: "read_file",
        parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
      },
      {
        type: "function",
        function: {
          name: "run_command",
          parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] },
        },
      },
      { type: "web_search_preview" },
    ],
  });

  const transformed = JSON.parse(transformOpenAIRequestBody(source));
  assert.equal(transformed.tools[0].parameters.properties.agent__intent.type, "string");
  assert.deepEqual(transformed.tools[0].parameters.required, ["path"]);
  assert.equal(transformed.tools[1].function.parameters.properties.agent__intent.type, "string");
  assert.deepEqual(transformed.tools[1].function.parameters.required, ["command"]);
  assert.deepEqual(transformed.tools[2], { type: "web_search_preview" });
  assert.equal(transformOpenAIRequestBody("not-json"), "not-json");
});

test("installed fetch guard rotates on response failures and pre-request cooldowns", async () => {
  const script = String.raw`
    import assert from "node:assert/strict";
    import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
    import { join } from "node:path";

    const home = process.env.HOME;
    const aidevopsDir = join(home, ".aidevops");
    mkdirSync(aidevopsDir, { recursive: true });
    const poolPath = join(aidevopsDir, "oauth-pool.json");

    async function withInstalledGuard(pool, fetchImpl, request) {
      writeFileSync(poolPath, JSON.stringify(pool));
      const calls = [];
      globalThis.fetch = async (input, init) => fetchImpl(input, init, calls);
      const authWrites = [];
      const { installOpenAIProviderFetchRotation } = await import("./openai-provider-auth.mjs?case=" + Math.random());
      installOpenAIProviderFetchRotation({
        auth: { set: async (entry) => authWrites.push(entry) },
      });
      const response = await fetch(request.input ?? request.url, request.init);
      return { response, calls, authWrites, pool: JSON.parse(readFileSync(poolPath, "utf-8")) };
    }

    const responseRotation = await withInstalledGuard({
      openai: [
        { email: "limited@example.com", access: "limited-token", refresh: "limited-refresh", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z" },
        { email: "healthy@example.com", access: "healthy-token", refresh: "healthy-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_healthy" },
      ],
    }, async (input, init, calls) => {
      calls.push({
        authorization: new Headers(init?.headers).get("authorization"),
        body: JSON.parse(String(init?.body || "{}")),
      });
      if (calls.length === 1) {
        return new Response(JSON.stringify({ error: { code: "insufficient_quota", message: "usage limit" } }), {
          status: 403,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response("ok", { status: 200 });
    }, {
      url: "https://api.openai.com/v1/chat/completions",
      init: {
        method: "POST",
        headers: { authorization: "Bearer limited-token" },
        body: JSON.stringify({ tools: [{
          type: "function",
          function: {
            name: "read_file",
            parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
          },
        }] }),
      },
    });

    assert.equal(responseRotation.response.status, 200);
    assert.deepEqual(responseRotation.calls.map((call) => call.authorization), ["Bearer limited-token", "Bearer healthy-token"]);
    for (const call of responseRotation.calls) {
      const parameters = call.body.tools[0].function.parameters;
      assert.equal(parameters.properties.agent__intent.type, "string");
      assert.deepEqual(parameters.required, ["path"]);
    }
    assert.equal(responseRotation.pool.openai[0].status, "rate-limited");
    assert.equal(responseRotation.pool.openai[1].status, "active");
    assert.equal(responseRotation.authWrites[0].path.id, "openai");
    assert.equal(responseRotation.authWrites[0].body.accountId, "acct_healthy");

    const requestSource = JSON.stringify({ tools: [{
      type: "function",
      name: "read_file",
      parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] },
    }] });
    const requestInput = new Request("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { authorization: "Bearer healthy-token" },
      body: requestSource,
    });
    const requestTransform = await withInstalledGuard({
      openai: [{ email: "healthy@example.com", access: "healthy-token", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0 }],
    }, async (input, init, calls) => {
      calls.push(await new Request(input, init).text());
      return new Response("ok", { status: 200 });
    }, { input: requestInput });
    assert.equal(JSON.parse(requestTransform.calls[0]).tools[0].parameters.properties.agent__intent.type, "string");

    const transformedInheritedInit = Object.create({
      body: requestSource,
      method: "PUT",
      headers: { authorization: "Bearer inherited-token", "x-request-source": "inherited" },
    });
    const inheritedTransform = await withInstalledGuard({
      openai: [{ email: "inherited@example.com", access: "inherited-token", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0 }],
    }, async (input, init, calls) => {
      const normalized = new Request(input, init);
      calls.push({
        method: normalized.method,
        authorization: normalized.headers.get("authorization"),
        source: normalized.headers.get("x-request-source"),
        body: await normalized.text(),
      });
      return new Response("ok", { status: 200 });
    }, { input: requestInput, init: transformedInheritedInit });
    assert.equal(inheritedTransform.calls[0].method, "PUT");
    assert.equal(inheritedTransform.calls[0].authorization, "Bearer inherited-token");
    assert.equal(inheritedTransform.calls[0].source, "inherited");
    assert.equal(JSON.parse(inheritedTransform.calls[0].body).tools[0].parameters.properties.agent__intent.type, "string");

    const inheritedInit = Object.create({ body: "inherited-override" });
    const overrideCases = [
      { init: { body: "" }, expected: "" },
      { init: { body: new URLSearchParams({ payload: "replacement" }) }, expected: "payload=replacement" },
      { init: inheritedInit, expected: "inherited-override" },
    ];
    for (const overrideCase of overrideCases) {
      const overrideInput = new Request("https://api.openai.com/v1/responses", {
        method: "POST",
        headers: { authorization: "Bearer healthy-token" },
        body: requestSource,
      });
      const overrideResult = await withInstalledGuard({
        openai: [{ email: "healthy@example.com", access: "healthy-token", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0 }],
      }, async (input, init, calls) => {
        calls.push(await new Request(input, init).text());
        return new Response("ok", { status: 200 });
      }, { input: overrideInput, init: overrideCase.init });
      assert.equal(overrideResult.calls[0], overrideCase.expected);
    }

    const tokenRefreshRecovery = await withInstalledGuard({
      openai: [
        { email: "expired@example.com", access: "expired-token", refresh: "expired-refresh", expires: 1, status: "active", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z" },
        { email: "fallback@example.com", access: "fallback-token", refresh: "fallback-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_fallback" },
      ],
    }, async (input, init, calls) => {
      calls.push({ url: String(input), body: String(init?.body || "") });
      return new Response(JSON.stringify({ error: "invalid_grant" }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    }, {
      url: "https://auth.openai.com/oauth/token",
      init: {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: "expired-refresh", client_id: "app_test" }).toString(),
      },
    });

    const recoveredTokenPayload = await tokenRefreshRecovery.response.json();
    assert.equal(tokenRefreshRecovery.response.status, 200);
    assert.equal(recoveredTokenPayload.access_token, "fallback-token");
    assert.equal(recoveredTokenPayload.refresh_token, "fallback-refresh");
    assert.equal(tokenRefreshRecovery.pool.openai[0].status, "auth-error");
    assert.equal(tokenRefreshRecovery.pool.openai[1].status, "active");
    assert.equal(tokenRefreshRecovery.authWrites[0].path.id, "openai");
    assert.equal(tokenRefreshRecovery.authWrites[0].body.access, "fallback-token");
    assert.equal(tokenRefreshRecovery.authWrites[0].body.accountId, "acct_fallback");

    const cooldownPreflight = await withInstalledGuard({
      openai: [
        { email: "cooldown@example.com", access: "cooldown-token", refresh: "cooldown-refresh", expires: Date.now() + 3600_000, status: "rate-limited", cooldownUntil: Date.now() + 4 * 86400_000, lastUsed: "2026-01-02T00:00:00Z" },
        { email: "fresh@example.com", access: "fresh-token", refresh: "fresh-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z" },
      ],
    }, async (input, init, calls) => {
      calls.push(new Headers(init?.headers).get("authorization"));
      return new Response("ok", { status: 200 });
    }, {
      url: "https://api.openai.com/v1/responses",
      init: { method: "POST", headers: { authorization: "Bearer cooldown-token" }, body: "{}" },
    });

    assert.equal(cooldownPreflight.response.status, 200);
    assert.deepEqual(cooldownPreflight.calls, ["Bearer fresh-token"]);

    const genericServerFailure = await withInstalledGuard({
      openai: [
        { email: "active@example.com", access: "active-token", refresh: "active-refresh", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z" },
      ],
    }, async (input, init, calls) => {
      calls.push(new Headers(init?.headers).get("authorization"));
      return new Response(JSON.stringify({ error: { code: "server_is_overloaded" } }), {
        status: 503,
        headers: { "content-type": "application/json" },
      });
    }, {
      url: "https://api.openai.com/v1/responses",
      init: { method: "POST", headers: { authorization: "Bearer active-token" }, body: "{}" },
    });

    assert.equal(genericServerFailure.response.status, 503);
    assert.deepEqual(genericServerFailure.calls, ["Bearer active-token"]);
    assert.equal(genericServerFailure.authWrites.length, 0);

  `;
  runProviderScript("aidevops-openai-rotation-", script);
});

test("OpenAI startup injection honors current auth availability", async () => {
  const script = String.raw`
    import assert from "node:assert/strict";
    import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
    import { join } from "node:path";

    const home = process.env.HOME;
    const aidevopsDir = join(home, ".aidevops");
    const opencodeDir = join(home, ".local", "share", "opencode");
    mkdirSync(aidevopsDir, { recursive: true });
    mkdirSync(opencodeDir, { recursive: true });
    const poolPath = join(aidevopsDir, "oauth-pool.json");
    const authPath = join(opencodeDir, "auth.json");

    async function injectWithPool(pool, auth, skipEmail) {
      writeFileSync(poolPath, JSON.stringify(pool));
      writeFileSync(authPath, JSON.stringify({ openai: auth }));
      const authWrites = [];
      const { injectOpenAIPoolToken } = await import("./oauth-pool.mjs?case=" + Math.random());
      const ok = await injectOpenAIPoolToken({ auth: { set: async (entry) => authWrites.push(entry) } }, skipEmail);
      return { ok, authWrites, pool: JSON.parse(readFileSync(poolPath, "utf-8")) };
    }

    const preserved = await injectWithPool({ openai: [
      { email: "old@example.com", access: "old-token", refresh: "old-refresh", expires: Date.now() + 3600_000, status: "active", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_old" },
      { email: "current@example.com", access: "current-token", refresh: "current-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z", accountId: "acct_current" },
    ] }, { type: "oauth", access: "current-token", refresh: "current-refresh", expires: Date.now() + 3600_000, accountId: "acct_current" });

    assert.equal(preserved.ok, true);
    assert.equal(preserved.authWrites[0].body.accountId, "acct_current");
    assert.equal(preserved.pool.openai[1].status, "active");

    const rotated = await injectWithPool({ openai: [
      { email: "cooldown@example.com", access: "cooldown-token", refresh: "cooldown-refresh", expires: Date.now() + 3600_000, status: "rate-limited", cooldownUntil: Date.now() + 86400_000, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_cooldown" },
      { email: "fresh@example.com", access: "fresh-token", refresh: "fresh-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z", accountId: "acct_fresh" },
    ] }, { type: "oauth", access: "cooldown-token", refresh: "cooldown-refresh", expires: Date.now() + 3600_000, accountId: "acct_cooldown" });

    assert.equal(rotated.ok, true);
    assert.equal(rotated.authWrites[0].body.accountId, "acct_fresh");

    const authErrorRotated = await injectWithPool({ openai: [
      { email: "auth-error@example.com", access: "auth-error-token", refresh: "auth-error-refresh", expires: Date.now() + 3600_000, status: "auth-error", cooldownUntil: Date.now() + 86400_000, lastUsed: "2026-01-03T00:00:00Z", accountId: "acct_auth_error" },
      { email: "fallback@example.com", access: "fallback-token", refresh: "fallback-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_fallback" },
    ] }, { type: "oauth", access: "auth-error-token", refresh: "auth-error-refresh", expires: Date.now() + 3600_000, accountId: "acct_auth_error" });

    assert.equal(authErrorRotated.ok, true);
    assert.equal(authErrorRotated.authWrites[0].body.accountId, "acct_fallback");

    const skippedAccountAvoided = await injectWithPool({ openai: [
      { email: "current@example.com", access: "current-token", refresh: "current-refresh", expires: Date.now() + 3600_000, status: "rate-limited", cooldownUntil: Date.now() + 86400_000, lastUsed: "2026-01-03T00:00:00Z", accountId: "acct_current" },
      { email: "skip@example.com", access: "skip-token", refresh: "skip-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-01T00:00:00Z", accountId: "acct_skip" },
      { email: "fallback@example.com", access: "fallback-token", refresh: "fallback-refresh", expires: Date.now() + 3600_000, status: "idle", cooldownUntil: 0, lastUsed: "2026-01-02T00:00:00Z", accountId: "acct_fallback" },
    ] }, { type: "oauth", access: "current-token", refresh: "current-refresh", expires: Date.now() + 3600_000, accountId: "acct_current" }, "skip@example.com");

    assert.equal(skippedAccountAvoided.ok, true);
    assert.equal(skippedAccountAvoided.authWrites[0].body.accountId, "acct_fallback");
  `;
  runProviderScript("aidevops-openai-startup-", script);
});
