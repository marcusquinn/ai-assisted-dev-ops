// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for GH#25895: intent metadata is schema-injected so it
// can reach the plugin, but must be consumed before executable tool args reach
// OpenCode's host-side validation/execution paths.

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  consumeIntent,
  consumeIntentRecord,
  deriveFallbackIntent,
  extractAndStoreIntent,
  prepareIntent,
} from "../intent-tracing.mjs";

describe("extractAndStoreIntent", () => {
  test("stores and strips agent__intent while preserving Bash workdir", () => {
    const callID = "call-gh-25895-bash";
    const args = {
      command: "git status --short",
      workdir: "/tmp/aidevops-workspace",
      agent__intent: " Inspecting repository state before editing ",
    };

    const intent = extractAndStoreIntent(callID, args);

    assert.equal(intent, "Inspecting repository state before editing");
    assert.equal(consumeIntent(callID), "Inspecting repository state before editing");
    assert.equal(args.workdir, "/tmp/aidevops-workspace");
    assert.ok(!Object.prototype.hasOwnProperty.call(args, "agent__intent"));
  });

  test("strips agent__intent from Read filePath args before execution", () => {
    const callID = "call-gh-25895-read";
    const args = {
      filePath: "/tmp/aidevops-workspace/README.md",
      agent__intent: "Reading a file to understand context",
    };

    extractAndStoreIntent(callID, args);

    assert.equal(consumeIntent(callID), "Reading a file to understand context");
    assert.deepEqual(args, { filePath: "/tmp/aidevops-workspace/README.md" });
  });

  test("strips malformed intent metadata without storing it", () => {
    const callID = "call-gh-25895-custom";
    const args = {
      target: "custom-tool",
      agent__intent: 42,
    };

    const intent = extractAndStoreIntent(callID, args);

    assert.equal(intent, undefined);
    assert.equal(consumeIntent(callID), undefined);
    assert.deepEqual(args, { target: "custom-tool" });
  });

  test("replaces non-configurable args so intent cannot reach execution", () => {
    const callID = "call-gh-25992-nonconfigurable";
    const args = { target: "custom-tool" };
    Object.defineProperty(args, "agent__intent", {
      value: "Recording intent from immutable host args",
      configurable: false,
      enumerable: true,
    });

    const prepared = prepareIntent(callID, args, "custom-tool");

    assert.equal(prepared.intent, "Recording intent from immutable host args");
    assert.equal(consumeIntent(callID), "Recording intent from immutable host args");
    assert.equal(args.agent__intent, "Recording intent from immutable host args");
    assert.deepEqual(prepared.args, { target: "custom-tool" });
    assert.ok(!Object.prototype.hasOwnProperty.call(prepared.args, "agent__intent"));
  });

  test("records explicit provenance without changing the intent text", () => {
    const callID = "call-gh-31025-explicit";
    const args = { agent__intent: "Reading explicit context" };

    extractAndStoreIntent(callID, args, "read");

    assert.deepEqual(consumeIntentRecord(callID), {
      intent: "Reading explicit context",
      source: "explicit",
    });
  });

  test("derives fallback only from normalized tool identity", () => {
    const callID = "call-gh-31025-fallback";
    const args = {
      command: "secret-command-canary",
      filePath: "/private/path-canary",
      prompt: "private-prompt-canary",
    };

    const intent = extractAndStoreIntent(callID, args, "Bash");
    const record = consumeIntentRecord(callID);

    assert.equal(intent, "Running the requested operation");
    assert.deepEqual(record, { intent, source: "fallback" });
    assert.doesNotMatch(intent, /secret-command|private|canary/i);
    assert.deepEqual(args, {
      command: "secret-command-canary",
      filePath: "/private/path-canary",
      prompt: "private-prompt-canary",
    });
  });

  test("strips blank metadata and uses fallback provenance", () => {
    const callID = "call-gh-31025-blank";
    const args = { agent__intent: "   ", filePath: "/private/canary" };

    extractAndStoreIntent(callID, args, "READ");

    assert.deepEqual(consumeIntentRecord(callID), {
      intent: "Reading requested context",
      source: "fallback",
    });
    assert.deepEqual(args, { filePath: "/private/canary" });
  });

  test("uses a generic fallback for bounded unknown tool identities", () => {
    assert.equal(deriveFallbackIntent("custom.vendor/tool"), "Using the requested tool");
    assert.equal(deriveFallbackIntent(""), undefined);
  });

  test("ignores inherited intent and records fallback provenance", () => {
    const callID = "call-gh-31025-prototype";
    const args = Object.create({ agent__intent: "Inherited private canary" });
    args.target = "safe-value";

    const prepared = prepareIntent(callID, args, "read");

    assert.equal(prepared.args, args);
    assert.deepEqual(consumeIntentRecord(callID), {
      intent: "Reading requested context",
      source: "fallback",
    });
  });
});
