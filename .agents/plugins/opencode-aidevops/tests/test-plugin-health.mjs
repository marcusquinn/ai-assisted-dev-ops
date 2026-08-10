// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { PLUGIN_HEALTH_SCHEMA, recordPluginHealthStage } from "../plugin-health.mjs";

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
