// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  gpt56ContextCapEnabled,
  registerAstraContextLimits,
  registerGpt56ContextLimits,
} from "../config-hook.mjs";

const originalSettingsFile = process.env.AIDEVOPS_SETTINGS_FILE;
const tempDirs = [];

afterEach(() => {
  if (originalSettingsFile === undefined) {
    delete process.env.AIDEVOPS_SETTINGS_FILE;
  } else {
    process.env.AIDEVOPS_SETTINGS_FILE = originalSettingsFile;
  }
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function settingsFile(value) {
  const dir = mkdtempSync(join(tmpdir(), "aidevops-gpt56-"));
  tempDirs.push(dir);
  const file = join(dir, "settings.json");
  if (value !== undefined) writeFileSync(file, JSON.stringify(value));
  process.env.AIDEVOPS_SETTINGS_FILE = file;
  return file;
}

test("GPT-5.6 cap defaults on and applies a 240K compaction threshold without losing model fields", () => {
  settingsFile(undefined);
  const config = {
    provider: { openai: { models: { "gpt-5.6-sol": { name: "Sol" } } } },
  };
  assert.equal(gpt56ContextCapEnabled(), true);
  assert.equal(registerGpt56ContextLimits(config), 4);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].name, "Sol");
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.context, 300000);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.input, 260000);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.output, 128000);
  assert.equal(config.provider.openai.models["gpt-5.6-terra"].limit.context, 300000);
  assert.equal(config.provider.openai.models["gpt-5.6-terra"].limit.input, 260000);
  assert.equal(config.provider.openai.models["gpt-5.6-terra"].limit.output, 128000);
  assert.equal(config.provider.openai.models["gpt-5.6-sol"].limit.input - 20000, 240000);
});

test("GPT-5.6 cap preserves an explicit output limit but owns context and input budgets", () => {
  settingsFile(undefined);
  const config = {
    provider: { openai: { models: { "gpt-5.6-sol": { limit: { context: 400000, input: 380000, output: 64000 } } } } },
  };
  registerGpt56ContextLimits(config);
  assert.deepEqual(config.provider.openai.models["gpt-5.6-sol"].limit, {
    output: 64000,
    context: 300000,
    input: 260000,
  });
});

test("GPT-5.6 cap opt-out leaves OpenAI model metadata untouched", () => {
  settingsFile({ runtime: { opencode: { gpt56_context_cap: false } } });
  const config = { provider: { openai: { models: {} } } };
  assert.equal(gpt56ContextCapEnabled(), false);
  assert.equal(registerGpt56ContextLimits(config), 0);
  assert.deepEqual(config.provider.openai.models, {});
});

test("malformed settings fail open to the cost-aware default", () => {
  const file = settingsFile({});
  writeFileSync(file, "not-json");
  assert.equal(gpt56ContextCapEnabled(), true);
});

test("Astra compacts at 400K with the default and an explicit reserve", () => {
  settingsFile(undefined);
  for (const reserve of [undefined, 0, 35000]) {
    const config = { compaction: reserve === undefined ? {} : { reserved: reserve } };
    assert.equal(registerAstraContextLimits(config), 1);
    const limits = config.provider.openai.models["gpt-6-astra"].limit;
    assert.equal(limits.input - (reserve ?? 20000), 400000);
    assert.equal(limits.context, limits.input + limits.output);
    assert.equal(limits.output, 128000);
    assert.equal(config.compaction.reserved, reserve);
  }
});

test("Astra retains model fields and explicit output limits, independently of GPT-5.6", () => {
  settingsFile({ runtime: { opencode: { gpt56_context_cap: false } } });
  const config = { provider: { openai: { models: {
    "gpt-6-astra": { name: "Astra", limit: { context: 1000000, output: 4000 } },
    "gpt-5.6-sol": { name: "untouched" },
  } } } };
  registerAstraContextLimits(config);
  assert.equal(config.provider.openai.models["gpt-6-astra"].name, "Astra");
  assert.equal(config.provider.openai.models["gpt-6-astra"].limit.input - 4000, 400000);
  assert.deepEqual(config.provider.openai.models["gpt-5.6-sol"], { name: "untouched" });
});

test("Astra opt-out leaves metadata untouched", () => {
  settingsFile({ runtime: { opencode: { astra_context_cap: false } } });
  const config = {};
  assert.equal(registerAstraContextLimits(config), 0);
  assert.deepEqual(config, {});
});
