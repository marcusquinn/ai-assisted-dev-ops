// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRelay } from "../frontier-harness-oauth-relay.mjs";
import observerPlugin from "../../plugins/frontier-harness/index.mjs";
import { summarize, summarizeRun } from "../frontier-harness-report.mjs";

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

test("calibration stops measured infeasible input before summary, not feasible or unknown input", async () => {
  for (const scenario of [
    { context: 16384, input: 13000, stop: true, usable: 12288 },
    { context: 18432, input: 13000, stop: false, usable: 14336 },
    { context: 16384, input: 12288, stop: true, usable: 12288 },
    { context: 16384, input: null, stop: false, usable: 12288 },
    { context: 16384, input: 13000, version: "1.18.22", stop: false, usable: null },
    { context: 16384, input: 13000, reserved: 0, stop: false, usable: 14336 },
    { context: 16384, input: 13000, unavailable: true, stop: false, usable: 12288 },
  ]) {
    const dir = mkdtempSync(join(tmpdir(), "frontier-calibration-"));
    const events = join(dir, "events.jsonl");
    const info = { id: "fixture-response", sessionID: "fixture-session", role: "assistant",
      time: { created: 1, completed: 2 },
      tokens: { input: scenario.input, output: 2048, cache: { read: 0, write: 0 } } };
    const hooks = await observer({ client: { session: { messages: async () => {
      if (scenario.unavailable) throw new Error("fixture unavailable");
      return { data: [{ info }] };
    } } } }, { profile: "stock", events,
      experimental: true, runtimeVersion: scenario.version ?? "1.18.29" });
    try {
      await hooks.config({ compaction: { reserved: scenario.reserved } });
      const params = { sessionID: "fixture-session", model: { limit: {
        context: scenario.context, input: scenario.context - 2048, output: 2048,
      } } };
      await hooks["chat.params"](params, {});
      await hooks["experimental.chat.system.transform"](params, { system: ["private core"] });
      await hooks.event({ event: { type: "message.updated", properties: { info } } });
      const compact = () => hooks["experimental.session.compacting"](params, { context: [] });
      if (scenario.stop) await assert.rejects(compact(), /FrontierCalibrationInfeasible/);
      else await compact();
      // A shortfall in one trial/session never stops an unrelated session.
      await hooks["experimental.session.compacting"]({ sessionID: "other-session" }, { context: [] });
      const text = readFileSync(events, "utf8");
      assert.equal(text.includes("private core"), false);
      const report = summarize(text.trim().split("\n").map(JSON.parse));
      assert.equal(report.calibration.applied[0].capacity?.usable_input ?? null, scenario.usable);
      assert.equal(report.calibration.stopped.length, scenario.stop ? 1 : 0);
      assert.equal(report.summary_completions, 0);
      assert.equal(report.calibration.footprints[0].system_bytes, 12);
    } finally { await hooks.dispose(); rmSync(dir, { recursive: true, force: true }); }
  }
});

test("partial usage keeps known subtotals separate from unknown totals and summary overhead", () => {
  const rows = [
    { type: "observer.started" },
    { type: "completion", input_tokens: 10, output_tokens: 2 },
    { type: "completion", summary: true, input_tokens: null, output_tokens: 3 },
  ].map((row, i) => ({ schema: 1, profile: "stock", sequence: i + 1, ...row }));
  const report = summarize(rows);
  assert.equal(report.input_tokens, null);
  assert.deepEqual(report.usage_coverage.input_tokens, {
    measured_completions: 1, missing_completions: 1, completed_subtotal: 10,
  });
  assert.equal(report.summary_input_tokens, null);
  assert.equal(report.summary_output_tokens, 3);
  assert.deepEqual(report.calibration.initial, []);
});

test("delayed bus usage is recovered from the first completed response in the same session", async () => {
  const dir = mkdtempSync(join(tmpdir(), "frontier-delayed-"));
  const message = (sessionID, created, input) => ({ info: { sessionID, role: "assistant",
    time: { created, completed: created + 1 }, tokens: { input, cache: { read: 0, write: 0 } } } });
  const hooks = await observer({ client: { session: { messages: async ({ path }) => {
    assert.equal(path.id, "target");
    return { data: [message("target", 10, 1), message("other", 1, 1), message("target", 2, 13000)] };
  } } } }, { profile: "stock", events: join(dir, "events.jsonl"), experimental: true, runtimeVersion: "1.18.29" });
  try {
    await hooks["chat.params"]({ sessionID: "target", model: {
      limit: { context: 16384, input: 14336, output: 2048 },
    } }, {});
    await hooks.event({ event: { type: "message.updated", properties: {
      info: { ...message("target", 10, 1).info, id: "later-delivered-first" },
    } } });
    await assert.rejects(hooks["experimental.session.compacting"]({ sessionID: "target" }, { context: [] }),
      /FrontierCalibrationInfeasible/);
  } finally { await hooks.dispose(); rmSync(dir, { recursive: true, force: true }); }
});

test("run report joins verifier evidence, detects overridden output and preserves failed attempts", () => {
  const root = mkdtempSync(join(tmpdir(), "frontier-report-"));
  const trialDir = join(root, "jobs/pilot/trial");
  mkdirSync(join(trialDir, "agent"), { recursive: true });
  const json = (path, data) => writeFileSync(path, JSON.stringify(data));
  const manifest = { profile: "stock", experimental_context_limit: 18432, experimental_output_reserve: 2048,
    opencode_version: "1.18.29", status: "runner_finished", runner_exit_code: 0, completed_trials: 1, errored_trials: 0,
    relay: { requests: 2, stream_failures: 0, upstream_usage: [{ input_tokens: 13000, output_tokens: 2, cached_tokens: null }] } };
  const result = { verifier_result: { rewards: { reward: 1 } } };
  const rows = [{ type: "observer.started" }, { type: "config.applied" },
    { type: "request", session: "fixture", context_limit: 18432, input_limit: 16384, output_limit: 2048,
      capacity: { formula: "opencode-1.18.29-explicit-input-v1", usable_input: 14336, reserve: 2048 } },
    { type: "calibration.initial", status: "initial_input_fits", input_tokens_including_cache: 13000,
      capacity: { usable_input: 14336 } },
    { type: "completion", input_tokens: 13000, output_tokens: 2 },
    { type: "completion", summary: true, input_tokens: 13000, output_tokens: 3 }];
  const saveEvents = () => writeFileSync(join(trialDir, "agent/frontier-events.jsonl"), rows.map((row, i) =>
    JSON.stringify({ schema: 1, sequence: i + 1, profile: "stock", ...row })).join("\n"));
  try {
    json(join(root, "manifest.json"), manifest);
    json(join(trialDir, "result.json"), result);
    saveEvents();
    const report = summarizeRun(root);
    assert.equal(report.comparison_valid, true);
    assert.equal(report.telemetry.summary_output_tokens, 3);
    assert.equal(report.telemetry.calibration.applied[0].capacity.usable_input, 14336);
    assert.equal(report.upstream_usage_complete, false);
    assert.equal(report.upstream_responses_without_usage, 1);
    assert.equal(report.source_result_sha256.length, 64);
    manifest.interrupted = true;
    json(join(root, "manifest.json"), manifest);
    assert.equal(summarizeRun(root).comparison_valid, false);
    manifest.interrupted = false;
    manifest.opencode_version = "1.18.22";
    json(join(root, "manifest.json"), manifest);
    assert.equal(summarizeRun(root).comparison_valid, false);
    assert.equal(summarizeRun(root).calibration_status, "unknown");
    manifest.opencode_version = "1.18.29";
    json(join(root, "manifest.json"), manifest);
    rows[2].output_limit = 4096;
    saveEvents();
    assert.throws(() => summarizeRun(root), /model limits/);
    rows[2].output_limit = 2048;
    rows.push({ type: "calibration.stopped", reason: "initial_input_exceeds_usable" });
    saveEvents();
    assert.equal(summarizeRun(root).comparison_valid, false);
    assert.equal(summarizeRun(root).verifier_reward, 1, "never rewrite the verifier verdict");
    result.exception_info = { exception_type: "AgentTimeoutError" };
    json(join(trialDir, "result.json"), result);
    assert.equal(summarizeRun(root).task_passed, false);
    assert.equal(summarizeRun(root).trial_exception, "AgentTimeoutError");
  } finally { rmSync(root, { recursive: true, force: true }); }
});
