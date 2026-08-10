// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import {
  PLUGIN_HEALTH_SCHEMA,
  pluginHealthProbeRequested,
  recordPluginHealthStage,
} from "../plugin-health.mjs";

test("plugin health stages are nonce-bound and atomically accumulated", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-plugin-health-"));
  const receipt = join(root, "receipt.json");
  const nonce = "probe-0123456789abcdef";
  writeFileSync(receipt, `${JSON.stringify({ nonce, stages: [], details: {} })}\n`, { mode: 0o600 });
  const env = {
    AIDEVOPS_TEMP_DIR: root,
    AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE: receipt,
    AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE: nonce,
  };

  assert.equal(pluginHealthProbeRequested({ ...env, AIDEVOPS_PLUGIN_HEALTH_PROBE_ONLY: "1" }), true);
  assert.equal(pluginHealthProbeRequested({ AIDEVOPS_PLUGIN_HEALTH_PROBE_ONLY: "1" }), false);
  assert.equal(recordPluginHealthStage("imported", {}, env), true);
  assert.equal(recordPluginHealthStage("config_applied", { gpt56_limits: { context: 300000 } }, env), true);
  const result = JSON.parse(readFileSync(receipt, "utf8"));
  assert.equal(result.schema, PLUGIN_HEALTH_SCHEMA);
  assert.deepEqual(result.stages, ["imported", "config_applied"]);
  assert.equal(result.details.config_applied.gpt56_limits.context, 300000);
  rmSync(root, { recursive: true, force: true });
});

test("plugin health rejects nonce mismatch, loose modes, and symlinks", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-plugin-health-deny-"));
  const receipt = join(root, "receipt.json");
  const linked = join(root, "linked.json");
  const nonce = "probe-fedcba9876543210";
  writeFileSync(receipt, `${JSON.stringify({ nonce, stages: [] })}\n`, { mode: 0o600 });
  const baseEnv = {
    AIDEVOPS_TEMP_DIR: root,
    AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE: receipt,
    AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE: nonce,
  };

  assert.equal(recordPluginHealthStage("imported", {}, { ...baseEnv, AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE: "probe-wrongwrongwrong1" }), false);
  chmodSync(receipt, 0o644);
  assert.equal(recordPluginHealthStage("imported", {}, baseEnv), false);
  chmodSync(receipt, 0o600);
  symlinkSync(receipt, linked);
  assert.equal(recordPluginHealthStage("imported", {}, { ...baseEnv, AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE: linked }), false);
  rmSync(root, { recursive: true, force: true });
});

test("probe-only plugin factory registers config and terminal-title health", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-plugin-health-factory-"));
  const receipt = join(root, "receipt.json");
  const nonce = "probe-factory-0123456789";
  const pluginUrl = new URL("../index.mjs", import.meta.url).href;
  writeFileSync(receipt, `${JSON.stringify({ nonce, stages: [], details: {} })}\n`, { mode: 0o600 });

  const child = spawnSync(
    process.execPath,
    [
      "--input-type=module",
      "--eval",
      `const plugin = await import(${JSON.stringify(pluginUrl)});
       const hooks = await plugin.AidevopsPlugin({directory: process.cwd(), client: {}});
       await hooks.config({});`,
    ],
    {
      cwd: process.cwd(),
      encoding: "utf8",
      env: {
        ...process.env,
        AIDEVOPS_TEMP_DIR: root,
        AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE: receipt,
        AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE: nonce,
        AIDEVOPS_PLUGIN_HEALTH_PROBE_ONLY: "1",
      },
    },
  );
  assert.equal(child.status, 0, child.stderr);
  const result = JSON.parse(readFileSync(receipt, "utf8"));
  assert.deepEqual(result.stages, ["imported", "factory_initialized", "config_applied"]);
  assert.equal(result.details.factory_initialized.terminal_title_status, true);
  assert.deepEqual(result.details.config_applied.gpt56_limits, {
    output: 128000,
    context: 300000,
    input: 260000,
  });
  rmSync(root, { recursive: true, force: true });
});
