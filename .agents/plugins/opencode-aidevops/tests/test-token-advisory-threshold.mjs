// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for the OpenCode token cost advisory threshold.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-token-advisory-threshold.mjs

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createSessionStartGreetingGate, createTtsrHooks } from "../ttsr.mjs";

function createHooks(options = {}) {
  const logs = [];
  const tempPrefix = `${Date.now()}-${process.pid}-${randomUUID()}-aidevops-token-advisory-test`;
  const hooks = createTtsrHooks({
    agentsDir: join(tmpdir(), `${tempPrefix}-agents`),
    scriptsDir: join(tmpdir(), `${tempPrefix}-scripts`),
    readIfExists: options.readIfExists || (() => ""),
    qualityLog: (level, message) => logs.push({ level, message }),
    run: () => "",
    intentField: "agent__intent",
    isHeadless: options.isHeadless || (() => false),
    shouldInjectGreeting: options.shouldInjectGreeting,
    readGreetingCache: options.readGreetingCache,
    now: options.now,
    refreshTtlMs: options.refreshTtlMs,
    initializedAtMs: options.initializedAtMs,
  });
  return { hooks, logs };
}

function outputForTokens(total, sessionID = "token-advisory-test-session") {
  return {
    messages: [{
      info: {
        id: `assistant-${total}`,
        role: "assistant",
        sessionID,
        tokens: { input: total, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
      },
      parts: [{ type: "text", text: "assistant response" }],
    }],
  };
}

function advisoryMessages(output) {
  return output.messages.filter((msg) => msg.info?.id?.startsWith("token-advisory-"));
}

describe("token cost advisory threshold", () => {
  test("appends session greeting after durable system guidance", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("VERSION") ? "3.14.23\n" : "",
      readGreetingCache: () => ({
        output: "aidevops v3.14.23 running in OpenCode v1.14.33 | aidevops/main",
        mtimeMs: 9_500,
      }),
      now: () => 10_000,
      refreshTtlMs: 1_000,
      initializedAtMs: 9_000,
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.equal(output.system[0], "base system prompt");
    assert.match(output.system.at(-1), /Session-start greeting order/);
    assert.match(output.system.at(-1), /authoritative greeting instruction/);
    assert.match(output.system.at(-1), /do not read the greeting cache or VERSION/);
    assert.match(output.system.at(-1), /this exact aidevops greeting/);
    assert.match(output.system.at(-1), /We're running aidevops v3\.14\.23 in OpenCode v1\.14\.33\./);
    assert.equal(output.system.filter((entry) => entry.includes("Session-start greeting order")).length, 1);
  });

  test("falls back to aidevops version when greeting cache is missing", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("VERSION") ? "3.14.23\n" : "",
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.match(output.system.at(-1), /We're running aidevops v3\.14\.23\./);
  });

  test("trims fallback aidevops version whitespace", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("VERSION") ? "3.14.23\r\n" : "",
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.match(output.system.at(-1), /We're running aidevops v3\.14\.23\./);
    assert.doesNotMatch(output.system.at(-1), /v3\.14\.23\r/);
  });

  test("keeps startup advisory messages out of chat instructions", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("session-greeting-opencode.txt")
        ? [
            "aidevops v3.14.23 running in OpenCode v1.14.33 | aidevops/main",
            "Security: all protections active",
            "[SECURITY ADVISORY] Rotate test credentials",
            "[WARN] Pulse stalled for 12 minutes",
          ].join("\n")
        : "",
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.match(output.system.at(-1), /Do not include startup status or advisory messages in chat/);
    assert.doesNotMatch(output.system.at(-1), /cache lines/);
    assert.doesNotMatch(output.system.at(-1), /\[SECURITY ADVISORY\] Rotate test credentials/);
    assert.doesNotMatch(output.system.at(-1), /\[WARN\] Pulse stalled for 12 minutes/);
    assert.doesNotMatch(output.system.at(-1), /Security: all protections active/);
  });

  test("avoids duplicate greeting after salutation-only launch input", async () => {
    const { hooks } = createHooks({
      readIfExists: (path) => path.endsWith("session-greeting-opencode.txt")
        ? [
            "aidevops v3.14.23 running in OpenCode v1.14.33 | aidevops/main",
            "Security: all protections active",
          ].join("\n")
        : "",
    });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.match(output.system.at(-1), /do not add any additional salutations, greetings, introductory questions, or equivalent help prompts/);
    assert.doesNotMatch(output.system.at(-1), /How can I help you\?/);
  });

  test("does not inject session greeting order in headless sessions", async () => {
    const { hooks } = createHooks({ isHeadless: () => true });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "openai" } }, output);

    assert.equal(output.system[0], "base system prompt");
  });

  test("injects the greeting only on the first request of an interactive root session", async () => {
    const client = { session: { get: async () => ({ data: { id: "root-session" } }) } };
    const shouldInjectGreeting = createSessionStartGreetingGate(client);
    const { hooks } = createHooks({ shouldInjectGreeting });
    const first = { system: ["base system prompt"] };
    const later = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ sessionID: "root-session", model: { providerID: "openai" } }, first);
    await hooks.systemTransformHook({ sessionID: "root-session", model: { providerID: "openai" } }, later);

    assert.match(first.system.at(-1), /Session-start greeting order/);
    assert.deepEqual(first.system.slice(0, -1), later.system);
    assert.equal(later.system[0], "base system prompt");
  });

  test("does not inject the greeting into subagent sessions", async () => {
    const client = { session: { get: async () => ({ data: { id: "child-session", parentID: "root-session" } }) } };
    const shouldInjectGreeting = createSessionStartGreetingGate(client);
    const { hooks } = createHooks({ shouldInjectGreeting });
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ sessionID: "child-session", model: { providerID: "openai" } }, output);

    assert.equal(output.system[0], "base system prompt");
  });

  test("keeps Anthropic identity prefix separate from greeting order", async () => {
    const { hooks } = createHooks();
    const output = { system: ["base system prompt"] };

    await hooks.systemTransformHook({ model: { providerID: "anthropic" } }, output);

    assert.match(output.system[0], /Session-start greeting order/);
    assert.equal(output.system[1], "You are Claude Code, Anthropic's official CLI for Claude.");
    assert.match(output.system[2], /^You are Claude Code, Anthropic's official CLI for Claude\.\n\nbase system prompt/);
  });

  test("does not inject advisory below 300k tokens", async () => {
    const { hooks } = createHooks();
    const output = outputForTokens(299_999);

    await hooks.messagesTransformHook({}, output);

    assert.equal(advisoryMessages(output).length, 0);
  });

  test("injects first advisory at 300k tokens", async () => {
    const { hooks, logs } = createHooks();
    const output = outputForTokens(300_000);

    await hooks.messagesTransformHook({}, output);

    const advisories = advisoryMessages(output);
    assert.equal(advisories.length, 1);
    assert.match(advisories[0].parts[0].text, /approximately 300k tokens/);
    assert.deepEqual(logs, [{ level: "INFO", message: "Token advisory: session token-advisory-test-session at ~300k tokens" }]);
  });

  test("does not inject advisory in headless sessions", async () => {
    const { hooks } = createHooks({ isHeadless: () => true });
    const output = outputForTokens(300_000);

    await hooks.messagesTransformHook({}, output);

    assert.equal(advisoryMessages(output).length, 0);
  });

  test("does not inject advisory for GPT-5.5 family models", async () => {
    const { hooks } = createHooks();
    const output = outputForTokens(300_000);

    await hooks.messagesTransformHook({ model: { modelID: "gpt-5.5-fast" } }, output);

    assert.equal(advisoryMessages(output).length, 0);
  });

  test("does not inject advisory for models newer than GPT-5.5", async () => {
    const { hooks } = createHooks();
    const output = outputForTokens(300_000);

    await hooks.messagesTransformHook({ model: { modelID: "gpt-6" } }, output);

    assert.equal(advisoryMessages(output).length, 0);
  });

  test("does not repeat at the same threshold for a session", async () => {
    const { hooks } = createHooks();
    const first = outputForTokens(300_000);
    const second = outputForTokens(325_000);

    await hooks.messagesTransformHook({}, first);
    await hooks.messagesTransformHook({}, second);

    assert.equal(advisoryMessages(first).length, 1);
    assert.equal(advisoryMessages(second).length, 0);
  });

  test("fires again at the next 50k interval", async () => {
    const { hooks } = createHooks();
    const first = outputForTokens(300_000);
    const second = outputForTokens(350_000);

    await hooks.messagesTransformHook({}, first);
    await hooks.messagesTransformHook({}, second);

    const advisories = advisoryMessages(second);
    assert.equal(advisories.length, 1);
    assert.match(advisories[0].parts[0].text, /approximately 350k tokens/);
  });
});
