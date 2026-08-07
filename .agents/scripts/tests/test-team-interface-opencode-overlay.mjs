// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";
import Ajv2020 from "ajv/dist/2020.js";

import {
  canonicalJson,
  conversationConfigEvidence,
} from "../../plugins/opencode-aidevops/team-interface-context.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const overlayScript = path.join(repositoryRoot, ".agents/scripts/team-interface-opencode-overlay.mjs");
const rosterScript = path.join(repositoryRoot, ".agents/scripts/team-interface-agent-roster.py");
const schemaDirectory = path.join(repositoryRoot, ".agents/schemas/team-interface");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function taggedDigest(value) {
  return `sha256:${crypto.createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
}

function writeJson(filePath, value, mode = 0o600) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, {mode});
}

function runOverlay(argumentsList, options = {}) {
  return spawnSync("node", [overlayScript, ...argumentsList], {
    encoding: "utf8",
    input: options.input,
  });
}

function requireSuccess(result, label) {
  assert.equal(result.status, 0, `${label} failed:\n${result.stderr}`);
  return result.stdout;
}

function requireFailure(result, pattern, label) {
  assert.notEqual(result.status, 0, `${label} unexpectedly succeeded`);
  assert.match(result.stderr, pattern, `${label} emitted an unexpected error: ${result.stderr}`);
}

function generateArguments(rosterPath, contextPath, extra = []) {
  return [
    "generate",
    "--roster", rosterPath,
    "--agent-id", "agent.build-plus",
    "--context", contextPath,
    ...extra,
  ];
}

const coreSchema = readJson(path.join(schemaDirectory, "core-v1.schema.json"));
const overlaySchema = readJson(path.join(schemaDirectory, "opencode-launch-overlay-v1.schema.json"));
const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: false});
ajv.addSchema(coreSchema);
const validateOverlaySchema = ajv.compile(overlaySchema);

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-opencode-overlay-"));
try {
  const rosterPath = path.join(fixtureRoot, "roster.json");
  const contextPath = path.join(fixtureRoot, "context.json");
  const overlayPath = path.join(fixtureRoot, "overlay.json");
  const rosterResult = spawnSync(
    "python3",
    [rosterScript, "--agents-dir", path.join(repositoryRoot, ".agents"), "--output", rosterPath],
    {encoding: "utf8"},
  );
  assert.equal(rosterResult.status, 0, rosterResult.stderr);
  const roster = readJson(rosterPath);
  const context = {
    actor_ref: "actor:synthetic-owner",
    app_team_ref: "app-team:synthetic-team",
    community_ref: "community:synthetic-community",
    conversation_ref: "conversation:synthetic-thread",
    correlation_ref: "correlation:synthetic-correlation",
    provider_ref: "provider:synthetic-provider",
    trust_ref: "trust:synthetic-verified",
  };
  writeJson(contextPath, context);

  const firstText = requireSuccess(runOverlay(generateArguments(rosterPath, contextPath)), "first generation");
  const secondText = requireSuccess(runOverlay(generateArguments(rosterPath, contextPath)), "second generation");
  assert.equal(secondText, firstText, "identical input did not produce byte-identical output");
  assert.ok(firstText.startsWith('{"agent":'), "output is not canonical key-ordered JSON");
  assert.ok(firstText.endsWith("\n"));

  const overlay = JSON.parse(firstText);
  assert.equal(validateOverlaySchema(overlay), true, JSON.stringify(validateOverlaySchema.errors, null, 2));
  assert.equal(overlay.permission_profile, "conversation_read_only_v1");
  assert.equal(overlay.agent.agent_id, "agent.build-plus");
  assert.equal(overlay.agent.kind, "primary");
  assert.equal(overlay.workload_tier, "standard");
  assert.equal(overlay.context_digest, taggedDigest(context));
  assert.equal(overlay.config_digest, taggedDigest(conversationConfigEvidence(overlay.agent.display_name)));
  const unsignedOverlay = structuredClone(overlay);
  delete unsignedOverlay.overlay_digest;
  assert.equal(overlay.overlay_digest, taggedDigest(unsignedOverlay));
  assert.deepEqual(
    Object.keys(overlay).sort(),
    [
      "agent", "config_digest", "context", "context_digest", "document_type",
      "overlay_digest", "overlay_id", "permission_profile", "roster_digest",
      "roster_id", "schema_version", "workload_tier",
    ],
  );
  assert.doesNotMatch(firstText, /(?:gpt-|claude-|openai\/|anthropic\/)/i);
  assert.doesNotMatch(firstText, new RegExp(repositoryRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));

  const outputResult = runOverlay(generateArguments(rosterPath, contextPath, ["--output", overlayPath]));
  assert.equal(outputResult.status, 0, outputResult.stderr);
  assert.equal(fs.readFileSync(overlayPath, "utf8"), firstText);
  assert.equal(fs.statSync(overlayPath).mode & 0o077, 0, "overlay output is group/world accessible");
  const validateResult = runOverlay(["validate", "--overlay", overlayPath]);
  assert.equal(validateResult.status, 0, validateResult.stderr);
  assert.equal(validateResult.stdout.trim(), overlay.overlay_digest);

  const noncanonicalPath = path.join(fixtureRoot, "noncanonical.json");
  writeJson(noncanonicalPath, overlay);
  requireFailure(
    runOverlay(["validate", "--overlay", noncanonicalPath]),
    /not canonical JSON/i,
    "non-canonical overlay",
  );

  for (const forbiddenKey of ["message", "instructions", "secret", "path", "model", "provider", "shell", "env", "authority"]) {
    const invalidContextPath = path.join(fixtureRoot, `context-${forbiddenKey}.json`);
    writeJson(invalidContextPath, {...context, [forbiddenKey]: "synthetic-value"});
    requireFailure(
      runOverlay(generateArguments(rosterPath, invalidContextPath)),
      /closed-schema validation/i,
      `forbidden context key ${forbiddenKey}`,
    );
  }

  for (const [label, value] of [
    ["url", "provider:https://synthetic.invalid"],
    ["traversal", "provider:../synthetic"],
    ["absolute-path", "provider:/synthetic"],
    ["secret-shape", "provider:token=synthetic"],
    ["shell-shape", "provider:synthetic;command"],
  ]) {
    const invalidContextPath = path.join(fixtureRoot, `context-${label}.json`);
    writeJson(invalidContextPath, {...context, provider_ref: value});
    requireFailure(
      runOverlay(generateArguments(rosterPath, invalidContextPath)),
      /validation|reference/i,
      `unsafe reference ${label}`,
    );
  }

  const mismatchedRoster = structuredClone(roster);
  mismatchedRoster.agents[0].display_name = "Changed without digest update";
  const mismatchedRosterPath = path.join(fixtureRoot, "roster-mismatched.json");
  writeJson(mismatchedRosterPath, mismatchedRoster);
  requireFailure(
    runOverlay(generateArguments(mismatchedRosterPath, contextPath)),
    /roster digest/i,
    "mismatched roster digest",
  );

  const duplicateRoster = structuredClone(roster);
  const duplicateAgent = {...duplicateRoster.agents.find(({agent_id: agentID}) => agentID === "agent.build-plus")};
  duplicateAgent.display_name = "Synthetic duplicate";
  duplicateRoster.agents.push(duplicateAgent);
  const unsignedDuplicateRoster = structuredClone(duplicateRoster);
  delete unsignedDuplicateRoster.roster_digest;
  duplicateRoster.roster_digest = taggedDigest(unsignedDuplicateRoster);
  const duplicateRosterPath = path.join(fixtureRoot, "roster-duplicate.json");
  writeJson(duplicateRosterPath, duplicateRoster);
  requireFailure(
    runOverlay(generateArguments(duplicateRosterPath, contextPath)),
    /duplicate stable agent IDs/i,
    "duplicate roster agent",
  );

  requireFailure(
    runOverlay([
      "generate", "--roster", rosterPath, "--agent-id", "agent.unknown",
      "--context", contextPath,
    ]),
    /unknown or duplicated/i,
    "unknown roster agent",
  );

  for (const tier of ["simple", "standard", "thinking"]) {
    const tierText = requireSuccess(
      runOverlay(generateArguments(rosterPath, contextPath, ["--workload-tier", tier])),
      `${tier} workload generation`,
    );
    assert.equal(JSON.parse(tierText).workload_tier, tier);
    assert.doesNotMatch(tierText, /"model"|"provider_id"/i);
  }
  requireFailure(
    runOverlay(generateArguments(rosterPath, contextPath, ["--workload-tier", "provider/model"])),
    /workload tier/i,
    "concrete model workload",
  );

  const guideText = requireSuccess(
    runOverlay([
      "generate", "--roster", rosterPath, "--agent-id", "agent.aidevops-guide",
      "--context", contextPath,
    ]),
    "framework guide generation",
  );
  const guide = JSON.parse(guideText);
  assert.equal(guide.agent.kind, "framework_guide");
  assert.equal(guide.agent.display_name, "AI DevOps");
  assert.equal(guide.agent.source_ref, "agents:aidevops.md");
  assert.notEqual(guide.agent.agent_id, "agent.build-plus");

  const previousOverlay = fs.readFileSync(overlayPath, "utf8");
  const invalidOutputContext = path.join(fixtureRoot, "context-invalid-output.json");
  writeJson(invalidOutputContext, {...context, raw_message: "synthetic text"});
  requireFailure(
    runOverlay(generateArguments(rosterPath, invalidOutputContext, ["--output", overlayPath])),
    /closed-schema validation/i,
    "failed atomic replacement",
  );
  assert.equal(fs.readFileSync(overlayPath, "utf8"), previousOverlay, "failed generation replaced prior output");
  requireFailure(
    runOverlay(generateArguments(rosterPath, contextPath, ["--output", rosterPath])),
    /must not replace an input/i,
    "input/output alias",
  );

  const effectiveEvidence = conversationConfigEvidence(overlay.agent.display_name);
  const effectiveConfig = {
    ...effectiveEvidence,
    agent: {
      [overlay.agent.display_name]: {
        ...effectiveEvidence.agent[overlay.agent.display_name],
        prompt: "Synthetic canonical agent prompt",
      },
      build: {disable: true},
      plan: {disable: true},
      general: {disable: true},
      explore: {disable: true},
    },
  };
  const effectiveResult = runOverlay(
    ["verify-effective", "--overlay", overlayPath],
    {input: JSON.stringify(effectiveConfig)},
  );
  assert.equal(effectiveResult.status, 0, effectiveResult.stderr);
  assert.equal(effectiveResult.stdout.trim(), overlay.overlay_digest);

  const widenedConfig = structuredClone(effectiveConfig);
  widenedConfig.tools.future_tool = true;
  requireFailure(
    runOverlay(["verify-effective", "--overlay", overlayPath], {input: JSON.stringify(widenedConfig)}),
    /effective config tools/i,
    "widened effective tools",
  );
  const enabledAgentConfig = structuredClone(effectiveConfig);
  enabledAgentConfig.agent.unexpected = {mode: "primary"};
  requireFailure(
    runOverlay(["verify-effective", "--overlay", overlayPath], {input: JSON.stringify(enabledAgentConfig)}),
    /unselected agent/i,
    "enabled unselected agent",
  );

  const tamperedOverlay = structuredClone(overlay);
  tamperedOverlay.context.actor_ref = "actor:tampered";
  const unsignedTampered = structuredClone(tamperedOverlay);
  delete unsignedTampered.overlay_digest;
  tamperedOverlay.overlay_digest = taggedDigest(unsignedTampered);
  const tamperedPath = path.join(fixtureRoot, "overlay-tampered.json");
  fs.writeFileSync(tamperedPath, `${canonicalJson(tamperedOverlay)}\n`, {mode: 0o600});
  requireFailure(
    runOverlay(["validate", "--overlay", tamperedPath]),
    /context digest/i,
    "tampered context digest",
  );
} finally {
  fs.rmSync(fixtureRoot, {recursive: true, force: true});
}

console.log("team-interface OpenCode overlay tests passed");
