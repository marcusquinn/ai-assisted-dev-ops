// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { HiggsfieldTokenManager } from "../higgsfield-mcp-oauth.mjs";
import {
  HiggsfieldMcpProxy,
  parseServerSentEvents,
  sanitizeToolSchemas,
} from "../higgsfield-mcp-proxy.mjs";

const FIXED_NOW = 2_000_000_000_000;

function fixture(t, tokens = {}) {
  const tempParent = process.env.AIDEVOPS_TEMP_DIR || tmpdir();
  mkdirSync(tempParent, { recursive: true });
  const directory = mkdtempSync(join(tempParent, "higgsfield-mcp-proxy-"));
  const statePath = join(directory, "state.json");
  const state = {
    client_id: "fixture-client",
    tokens: {
      access_token: "fixture-access-old",
      refresh_token: "fixture-refresh-old",
      expires_at: FIXED_NOW - 1_000,
      ...tokens,
    },
  };
  writeFileSync(statePath, `${JSON.stringify(state)}\n`, { mode: 0o600 });
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return { state, statePath };
}

function jsonResponse(payload, status = 200, headers = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

test("refreshes an expired token and persists restrictive atomic state", async (t) => {
  const { statePath } = fixture(t);
  let refreshCalls = 0;
  const manager = new HiggsfieldTokenManager({
    statePath,
    now: () => FIXED_NOW,
    fetchImpl: async (_url, options) => {
      refreshCalls += 1;
      assert.equal(options.body.get("grant_type"), "refresh_token");
      assert.equal(options.body.get("client_id"), "fixture-client");
      return jsonResponse({
        access_token: "fixture-access-new",
        refresh_token: "fixture-refresh-new",
        expires_in: 86_399,
      });
    },
  });

  assert.equal(await manager.accessToken(), "fixture-access-new");
  assert.equal(refreshCalls, 1);
  const stored = JSON.parse(readFileSync(statePath, "utf8"));
  assert.equal(stored.tokens.access_token, "fixture-access-new");
  assert.equal(stored.tokens.refresh_token, "fixture-refresh-new");
  assert.equal(stored.tokens.expires_at, FIXED_NOW + 86_399_000);
  assert.equal(statSync(statePath).mode & 0o777, 0o600);
});

test("retains the previous refresh token when rotation omits a replacement", async (t) => {
  const { statePath } = fixture(t);
  const manager = new HiggsfieldTokenManager({
    statePath,
    now: () => FIXED_NOW,
    fetchImpl: async () => jsonResponse({ access_token: "fixture-access-new", expires_in: 3_600 }),
  });

  await manager.accessToken();
  const stored = JSON.parse(readFileSync(statePath, "utf8"));
  assert.equal(stored.tokens.refresh_token, "fixture-refresh-old");
});

test("serializes independent managers into one token request", async (t) => {
  const { statePath } = fixture(t);
  let refreshCalls = 0;
  let releaseRefresh;
  let signalRefreshStarted;
  const refreshGate = new Promise((resolvePromise) => { releaseRefresh = resolvePromise; });
  const refreshStarted = new Promise((resolvePromise) => { signalRefreshStarted = resolvePromise; });
  const fetchImpl = async () => {
    refreshCalls += 1;
    signalRefreshStarted();
    await refreshGate;
    return jsonResponse({ access_token: "fixture-access-new", expires_in: 3_600 });
  };
  const managerOptions = { statePath, now: () => FIXED_NOW, fetchImpl };
  const firstManager = new HiggsfieldTokenManager(managerOptions);
  const secondManager = new HiggsfieldTokenManager(managerOptions);

  const first = firstManager.accessToken();
  await refreshStarted;
  const second = secondManager.accessToken();
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 75));
  releaseRefresh();
  assert.deepEqual(await Promise.all([first, second]), ["fixture-access-new", "fixture-access-new"]);
  assert.equal(refreshCalls, 1);
});

test("preserves the previous state when atomic persistence fails", async (t) => {
  const { state, statePath } = fixture(t);
  const manager = new HiggsfieldTokenManager({
    statePath,
    now: () => FIXED_NOW,
    fetchImpl: async () => jsonResponse({ access_token: "fixture-access-new", expires_in: 3_600 }),
    writeStateImpl: async () => { throw new Error("fixture write failure"); },
  });

  await assert.rejects(manager.accessToken(), /fixture write failure/);
  assert.deepEqual(JSON.parse(readFileSync(statePath, "utf8")), state);
});

test("refreshes and retries an authentication rejection only once", async (t) => {
  const { statePath } = fixture(t, { expires_at: FIXED_NOW + 60_000_000 });
  let refreshCalls = 0;
  let upstreamCalls = 0;
  const manager = new HiggsfieldTokenManager({
    statePath,
    now: () => FIXED_NOW,
    fetchImpl: async () => {
      refreshCalls += 1;
      return jsonResponse({ access_token: "fixture-access-new", expires_in: 3_600 });
    },
  });
  const proxy = new HiggsfieldMcpProxy({
    tokenManager: manager,
    mcpUrl: "https://fixture.invalid/mcp",
    fetchImpl: async () => {
      upstreamCalls += 1;
      return jsonResponse({ error: "unauthorized" }, 401);
    },
  });

  await assert.rejects(
    proxy.forward({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
    /Higgsfield authorization must be renewed in a browser/,
  );
  assert.equal(refreshCalls, 1);
  assert.equal(upstreamCalls, 2);
});

test("recovers the reported tool-level expired-session response", async (t) => {
  const { statePath } = fixture(t, { expires_at: FIXED_NOW + 60_000_000 });
  let upstreamCalls = 0;
  const manager = new HiggsfieldTokenManager({
    statePath,
    now: () => FIXED_NOW,
    fetchImpl: async () => jsonResponse({ access_token: "fixture-access-new", expires_in: 3_600 }),
  });
  const proxy = new HiggsfieldMcpProxy({
    tokenManager: manager,
    mcpUrl: "https://fixture.invalid/mcp",
    fetchImpl: async (_url, options) => {
      upstreamCalls += 1;
      if (upstreamCalls === 1) {
        assert.equal(options.headers.authorization, "Bearer fixture-access-old");
        return jsonResponse({
          jsonrpc: "2.0",
          id: 1,
          result: {
            isError: true,
            content: [{
              type: "text",
              text: "Your Higgsfield session has expired or is no longer valid. Please re-authorize the Higgsfield connector.",
            }],
          },
        });
      }
      assert.equal(options.headers.authorization, "Bearer fixture-access-new");
      return jsonResponse({ jsonrpc: "2.0", id: 1, result: { content: [{ type: "text", text: "ok" }] } });
    },
  });

  const messages = await proxy.forward({ jsonrpc: "2.0", id: 1, method: "tools/call" });
  assert.equal(messages[0].result.content[0].text, "ok");
  assert.equal(upstreamCalls, 2);
});

test("runs the refresh and MCP retry through real local HTTP boundaries", async (t) => {
  const { statePath } = fixture(t);
  let tokenRequests = 0;
  let mcpRequests = 0;
  const server = createServer(async (request, response) => {
    if (request.url === "/oauth/token") {
      tokenRequests += 1;
      let body = "";
      for await (const chunk of request) body += chunk;
      const params = new URLSearchParams(body);
      assert.equal(params.get("refresh_token"), "fixture-refresh-old");
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ access_token: "fixture-access-new", expires_in: 3_600 }));
      return;
    }
    if (request.url === "/mcp") {
      mcpRequests += 1;
      assert.equal(request.headers.authorization, "Bearer fixture-access-new");
      assert.equal(request.headers.accept, "application/json, text/event-stream");
      response.writeHead(200, {
        "content-type": "application/json",
        "mcp-session-id": "fixture-session",
      });
      response.end(JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        result: { protocolVersion: "2025-11-25", capabilities: {}, serverInfo: { name: "fixture", version: "1" } },
      }));
      return;
    }
    response.writeHead(404);
    response.end();
  });
  await new Promise((resolvePromise) => server.listen(0, "127.0.0.1", resolvePromise));
  t.after(() => server.close());
  const address = server.address();
  const origin = `http://127.0.0.1:${address.port}`;
  const manager = new HiggsfieldTokenManager({
    statePath,
    now: () => FIXED_NOW,
    tokenEndpoint: `${origin}/oauth/token`,
  });
  const proxy = new HiggsfieldMcpProxy({ tokenManager: manager, mcpUrl: `${origin}/mcp` });

  const messages = await proxy.forward({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "fixture", version: "1" } },
  });
  assert.equal(messages[0].result.protocolVersion, "2025-11-25");
  assert.equal(proxy.sessionId, "fixture-session");
  assert.equal(proxy.protocolVersion, "2025-11-25");
  assert.equal(tokenRequests, 1);
  assert.equal(mcpRequests, 1);
});

test("invalid_grant fails closed and does not enter a refresh loop", async (t) => {
  const { statePath } = fixture(t);
  let refreshCalls = 0;
  const manager = new HiggsfieldTokenManager({
    statePath,
    now: () => FIXED_NOW,
    fetchImpl: async () => {
      refreshCalls += 1;
      return jsonResponse({ error: "invalid_grant" }, 400);
    },
  });

  await assert.rejects(manager.accessToken(), /Higgsfield authorization must be renewed in a browser/);
  await assert.rejects(manager.accessToken(), /Higgsfield authorization must be renewed in a browser/);
  assert.equal(refreshCalls, 1);
  assert.equal(JSON.parse(readFileSync(statePath, "utf8")).tokens.refresh_token, null);
});

test("missing refresh credentials fail closed without a network request", async (t) => {
  const { statePath } = fixture(t, { refresh_token: null });
  let refreshCalls = 0;
  const manager = new HiggsfieldTokenManager({
    statePath,
    now: () => FIXED_NOW,
    fetchImpl: async () => { refreshCalls += 1; },
  });

  await assert.rejects(manager.accessToken(), /Higgsfield authorization must be renewed in a browser/);
  assert.equal(refreshCalls, 0);
});

test("preserves the proxy schema sanitizer and parses SSE JSON-RPC", () => {
  const message = {
    result: {
      tools: [{
        name: "fixture",
        inputSchema: {
          type: "object",
          properties: { values: { type: "array" } },
        },
      }],
    },
  };
  sanitizeToolSchemas(message);
  assert.equal(message.result.tools[0].inputSchema.additionalProperties, false);
  assert.deepEqual(message.result.tools[0].inputSchema.properties.values.items, { type: "string" });
  assert.deepEqual(
    parseServerSentEvents('event: message\ndata: {"jsonrpc":"2.0","id":1,\ndata: "result":{}}\n\n'),
    [{ jsonrpc: "2.0", id: 1, result: {} }],
  );
});
