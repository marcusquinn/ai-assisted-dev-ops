// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for the OpenCode aidevops_memory tool args schema.
// OpenCode exposes tools without an `args` schema as no-argument functions,
// preventing the model from passing action/content/query fields.

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createTools } from "../tools.mjs";

const SCRIPTS_DIR = "/tmp/aidevops-test-scripts";

function withMemoryHelper(fn) {
  const dir = mkdtempSync(join(tmpdir(), "aidevops-memory-tool-"));
  writeFileSync(join(dir, "memory-helper.sh"), "#!/usr/bin/env bash\n", { mode: 0o755 });
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe("aidevops_memory tool schema", () => {
  test("exposes a non-empty Zod args schema", () => {
    const tools = createTools(SCRIPTS_DIR, () => "");
    const schema = tools.aidevops_memory.args;

    assert.ok(schema, "memory tool must expose args");
    assert.ok(schema.action?._zod, "action must be a Zod schema");
    assert.ok(schema.query?._zod, "query must be a Zod schema");
    assert.ok(schema.limit?._zod, "limit must be a Zod schema");
    assert.ok(schema.content?._zod, "content must be a Zod schema");
    assert.ok(schema.confidence?._zod, "confidence must be a Zod schema");
    assert.match(tools.aidevops_memory.description, /mem_\.\.\..*exact lookup/);
  });
});

describe("aidevops_memory execution", () => {
  test("empty payload returns actionable validation without invoking helper", async () => {
    const calls = [];
    const result = await withMemoryHelper(async (scriptsDir) => {
      const tools = createTools(scriptsDir, (cmd) => {
        calls.push(cmd);
        return "unexpected";
      });

      return tools.aidevops_memory.execute({});
    });

    assert.equal(calls.length, 0);
    assert.match(result, /requires a complete payload/);
    assert.match(result, /do not use empty calls as placeholders/);
  });

  test("store action invokes memory-helper.sh store", async () => {
    const calls = [];
    const result = await withMemoryHelper(async (scriptsDir) => {
      const tools = createTools(scriptsDir, (cmd) => {
        calls.push(cmd);
        return "stored";
      });

      return tools.aidevops_memory.execute({
        action: "store",
        content: "Remember this",
        confidence: "high",
      });
    });

    assert.equal(result, "stored");
    assert.equal(calls.length, 1);
    assert.match(calls[0], /memory-helper\.sh" store 'Remember this' --confidence 'high'$/);
  });

  test("recall action invokes memory-helper.sh recall", async () => {
    const calls = [];
    const result = await withMemoryHelper(async (scriptsDir) => {
      const tools = createTools(scriptsDir, (cmd) => {
        calls.push(cmd);
        return "recalled";
      });

      return tools.aidevops_memory.execute({
        action: "recall",
        query: "schema",
        limit: 5,
      });
    });

    assert.equal(result, "recalled");
    assert.equal(calls.length, 1);
    assert.match(calls[0], /memory-helper\.sh" recall --query 'schema' --limit '5'$/);
  });

  test("exact memory ID recall is forwarded once without fallback", async () => {
    const calls = [];
    const result = await withMemoryHelper(async (scriptsDir) => {
      const tools = createTools(scriptsDir, (cmd) => {
        calls.push(cmd);
        return "";
      });

      return tools.aidevops_memory.execute({
        action: "recall",
        query: "mem_missing_fixture",
        limit: 5,
      });
    });

    assert.equal(result, "No memories found for this query.");
    assert.equal(calls.length, 1);
    assert.match(calls[0], /memory-helper\.sh" recall --query 'mem_missing_fixture' --limit '5'$/);
  });

  test("recall action defaults blank limit values", async () => {
    for (const limitValue of [null, "", "   "]) {
      const calls = [];
      const result = await withMemoryHelper(async (scriptsDir) => {
        const tools = createTools(scriptsDir, (cmd) => {
          calls.push(cmd);
          return "recalled";
        });

        return tools.aidevops_memory.execute({
          action: "recall",
          query: "schema",
          limit: limitValue,
        });
      });

      assert.equal(result, "recalled");
      assert.equal(calls.length, 1);
      assert.match(calls[0], /memory-helper\.sh" recall --query 'schema' --limit '5'$/);
    }
  });

  test("recall action without a query returns a validation error", async () => {
    const calls = [];
    const result = await withMemoryHelper(async (scriptsDir) => {
      const tools = createTools(scriptsDir, (cmd) => {
        calls.push(cmd);
        return "unexpected";
      });

      return tools.aidevops_memory.execute({ action: "recall", limit: 5 });
    });

    assert.equal(calls.length, 0);
    assert.match(result, /query is required for memory recall/);
  });

  test("empty store content returns a validation error", async () => {
    const result = await withMemoryHelper(async (scriptsDir) => {
      const tools = createTools(scriptsDir, () => "stored");
      return tools.aidevops_memory.execute({ action: "store", content: "   " });
    });

    assert.match(result, /content is required to store a memory/);
    assert.match(result, /do not store placeholders/);
  });
});
