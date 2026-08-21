// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { define as defineOpenCodeV2Plugin } from "@opencode-ai/plugin/v2/promise";

import { loadV1ToolHelper } from "../tools.mjs";
import v2Plugin, {
  defineAidevopsV2Adapter,
  OPENCODE_V2_MIGRATION_MESSAGE,
} from "../v2.mjs";

test("package exposes explicit V1 and V2 plugin entrypoints", () => {
  const packageDocument = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  assert.equal(packageDocument.exports["./v1"], "./index.mjs");
  assert.equal(packageDocument.exports["./v2"], "./v2.mjs");
  assert.equal(v2Plugin.id, "aidevops");
  assert.equal(typeof v2Plugin.setup, "function");
  assert.equal(defineOpenCodeV2Plugin(v2Plugin), v2Plugin);
});

test("V2 descriptor seam accepts a future domain-hook adapter", async () => {
  const context = { app: { version: "2.0.0" } };
  let observed;
  const cleanup = () => {};
  const plugin = defineAidevopsV2Adapter(async (input) => {
    observed = input;
    return cleanup;
  });

  assert.equal(await plugin.setup(context), cleanup);
  assert.equal(observed, context);
  assert.throws(() => defineAidevopsV2Adapter(), /setup must be a function/);
  await assert.rejects(v2Plugin.setup(context), new RegExp(OPENCODE_V2_MIGRATION_MESSAGE));
});

test("V1 tool schemas resolve across stable and V2 package layouts", async () => {
  const helper = (definition) => definition;
  helper.schema = {};
  const attempts = [];
  const selected = await loadV1ToolHelper({
    importer: async (specifier) => {
      attempts.push(specifier);
      if (specifier.endsWith("/v1")) return { tool: helper };
      throw new Error("root import must not be reached");
    },
  });
  assert.equal(selected, helper);
  assert.deepEqual(attempts, ["@opencode-ai/plugin/v1"]);

  const fallback = await loadV1ToolHelper({
    importer: async (specifier) => {
      if (specifier.endsWith("/v1")) throw new Error("legacy package has no v1 export");
      return { tool: helper };
    },
  });
  assert.equal(fallback, helper);

  await assert.rejects(
    loadV1ToolHelper({
      importer: async () => ({ Plugin: {} }),
      requirePinnedRuntime: true,
    }),
    /cannot resolve @opencode-ai\/plugin V1 schemas/,
  );
});
