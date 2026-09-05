// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRelay } from "../frontier-harness-oauth-relay.mjs";
import observerPlugin from "../../plugins/frontier-harness/index.mjs";
import { summarize } from "../frontier-harness-report.mjs";

const observer = observerPlugin.server;

test("relay confines credentials, model, endpoint, usage and request budget", async () => {
  let calls = 0;
  const relay = await createRelay({ model: "fixture-model", account: { access: "fixture-not-a-token" }, maxRequests: 2,
    fetchImpl: async (url, init) => {
      calls++;
      assert.equal(url, "https://chatgpt.com/backend-api/codex/responses");
      assert.equal(init.redirect, "error");
      assert.equal(init.headers.authorization, "Bearer fixture-not-a-token");
      const body = JSON.parse(init.body);
      assert.equal(body.store, false);
      assert.equal(body.stream, true);
      return new Response('data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2,"input_tokens_details":{"cached_tokens":3}}}}\n\n');
    } });
  try {
    const url = `http://127.0.0.1:${relay.port}/v1/responses`;
    assert.equal((await fetch(url)).status, 401);
    const post = (model) => fetch(url, { method: "POST", headers: { authorization: `Bearer ${relay.key}` },
      body: JSON.stringify({ model, input: [], store: true }) });
    assert.equal((await post("wrong-model")).status, 400);
    assert.equal(calls, 0);
    const response = await post("fixture-model");
    assert.equal(response.status, 200);
    await response.text();
    assert.equal(calls, 1);
    assert.equal((await post("fixture-model")).status, 429);
    assert.deepEqual(relay.stats().upstream_usage, [{ input_tokens: 10, output_tokens: 2, cached_tokens: 3 }]);
  } finally { relay.close(); }
});

test("rate limits stop the relay rather than retrying or switching billing", async () => {
  let calls = 0;
  const relay = await createRelay({ model: "fixture", account: { access: "fixture-not-a-token" },
    fetchImpl: async () => { calls++; return new Response("private provider detail", { status: 429 }); } });
  try {
    const request = () => fetch(`http://127.0.0.1:${relay.port}/v1/responses`, {
      method: "POST", headers: { authorization: `Bearer ${relay.key}` },
      body: JSON.stringify({ model: "fixture", input: [] }),
    });
    const response = await request();
    assert.equal(response.status, 429);
    assert.equal(await response.text(), "");
    assert.equal((await request()).status, 429);
    assert.equal(calls, 1);
  } finally { relay.close(); }
});

test("observer deduplicates completed messages without recording content", async () => {
  const dir = mkdtempSync(join(tmpdir(), "frontier-observer-"));
  try {
    const events = join(dir, "events.jsonl");
    const hooks = await observer({}, { profile: "stock", events });
    const event = { event: { type: "message.updated", properties: { info: {
      id: "private-message", sessionID: "private-session", role: "assistant", text: "private content",
      time: { created: 10, completed: 20 }, tokens: { input: 12, output: 2, cache: { read: 4, write: 0 } },
    } } } };
    await hooks.event(event);
    await hooks.event(event);
    const text = readFileSync(events, "utf8");
    assert.equal(text.includes("private"), false);
    const records = text.trim().split("\n").map(JSON.parse);
    const report = summarize(records);
    assert.equal(report.completions, 1);
    assert.equal(report.peak_prompt_tokens_proxy, 16);
    assert.equal(report.compactions_requested, 0);
    assert.equal(report.reasoning_tokens, null);
    assert.equal(report.verifier_success, null);
    assert.throws(() => summarize([...records, records[1]]));
    await assert.rejects(observer({}, { profile: "stock", events }));
    await hooks.dispose();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
