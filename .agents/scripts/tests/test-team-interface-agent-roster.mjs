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

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const rosterScript = path.join(repositoryRoot, ".agents/scripts/team-interface-agent-roster.py");
const schemaDirectory = path.join(repositoryRoot, ".agents/schemas/team-interface");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function runRoster(agentsDirectory, extraArguments = []) {
  return spawnSync(
    "python3",
    [rosterScript, "--agents-dir", agentsDirectory, ...extraArguments],
    {encoding: "utf8"},
  );
}

function requireSuccess(result, label) {
  assert.equal(result.status, 0, `${label} failed:\n${result.stderr}`);
  return JSON.parse(result.stdout);
}

function writeAgent(directory, filename, {name, description, model, heading = "Agent"}) {
  const metadata = [
    "---",
    ...(name === undefined ? [] : [`name: ${name}`]),
    `description: ${description}`,
    "mode: subagent",
    ...(model === undefined ? [] : [`model: ${model}`]),
    "---",
    "",
    `# ${heading}`,
    "",
    "Fixture instructions.",
    "",
  ].join("\n");
  fs.writeFileSync(path.join(directory, filename), metadata);
}

function copy(value) {
  return structuredClone(value);
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

const coreSchema = readJson(path.join(schemaDirectory, "core-v1.schema.json"));
const rosterSchema = readJson(path.join(schemaDirectory, "agent-roster-v1.schema.json"));
const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: false});
ajv.addSchema(coreSchema);
const validate = ajv.compile(rosterSchema);

const liveFirst = runRoster(path.join(repositoryRoot, ".agents"));
const liveRoster = requireSuccess(liveFirst, "live roster generation");
const liveSecond = runRoster(path.join(repositoryRoot, ".agents"));
assert.equal(liveSecond.status, 0, liveSecond.stderr);
assert.equal(liveSecond.stdout, liveFirst.stdout, "unchanged live source must be byte-identical");
assert.equal(validate(liveRoster), true, JSON.stringify(validate.errors, null, 2));

const primaryAgents = liveRoster.agents.filter(({kind}) => kind === "primary");
const frameworkGuides = liveRoster.agents.filter(({kind}) => kind === "framework_guide");
assert.equal(primaryAgents.length, 13, "current source must expose 13 canonical primaries");
assert.equal(frameworkGuides.length, 1);
assert.equal(frameworkGuides[0].agent_id, "agent.aidevops-guide");
assert.equal(frameworkGuides[0].workload_tier, "standard");
assert.deepEqual(
  primaryAgents.filter(({workload_tier}) => workload_tier === "thinking").map(({agent_id}) => agent_id).sort(),
  ["agent.content", "agent.pr", "agent.vault"],
);
assert.equal(primaryAgents.filter(({workload_tier}) => workload_tier === "standard").length, 10);
assert.equal(new Set(liveRoster.agents.map(({agent_id}) => agent_id)).size, liveRoster.agents.length);
assert.ok(liveRoster.agents.every(({source_ref: sourceRef}) => sourceRef.startsWith("agents:")));
assert.ok(liveRoster.agents.every(({source_ref: sourceRef}) => !path.isAbsolute(sourceRef)));
assert.ok(liveRoster.agents.every(({source_digest: digest}) => /^sha256:[a-f0-9]{64}$/.test(digest)));
assert.deepEqual(
  Object.keys(liveRoster).sort(),
  ["agents", "document_type", "roster_digest", "roster_id", "schema_version"],
);

const unsignedLive = copy(liveRoster);
delete unsignedLive.roster_digest;
const expectedDigest = `sha256:${crypto.createHash("sha256").update(canonicalJson(unsignedLive)).digest("hex")}`;
assert.equal(liveRoster.roster_digest, expectedDigest, "roster digest does not cover canonical unsigned JSON");

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-roster-"));
try {
  writeAgent(fixtureRoot, "build-plus.md", {
    name: "build-plus",
    description: "Fixture build agent",
    model: "thinking",
    heading: "Build+",
  });
  writeAgent(fixtureRoot, "aidevops.md", {
    name: "aidevops",
    description: "Fixture framework guide",
    heading: "AI DevOps",
  });

  const initialResult = runRoster(fixtureRoot);
  const initial = requireSuccess(initialResult, "initial sandbox roster");
  assert.deepEqual(initial.agents.map(({agent_id}) => agent_id), ["agent.build-plus", "agent.aidevops-guide"]);

  writeAgent(fixtureRoot, "zeta.md", {
    name: "stable-zeta",
    description: "Fixture dynamically added agent",
    heading: "Zeta",
  });
  const added = requireSuccess(runRoster(fixtureRoot), "sandbox addition");
  assert.ok(added.agents.some(({agent_id}) => agent_id === "agent.stable-zeta"));

  fs.renameSync(path.join(fixtureRoot, "zeta.md"), path.join(fixtureRoot, "renamed.md"));
  const renamed = requireSuccess(runRoster(fixtureRoot), "sandbox rename");
  assert.ok(renamed.agents.some(({agent_id}) => agent_id === "agent.stable-zeta"));
  assert.ok(renamed.agents.some(({source_ref: sourceRef}) => sourceRef === "agents:renamed.md"));

  const beforeContentChange = renamed.agents.find(({agent_id}) => agent_id === "agent.stable-zeta");
  fs.appendFileSync(path.join(fixtureRoot, "renamed.md"), "Changed source bytes.\n");
  const changed = requireSuccess(runRoster(fixtureRoot), "sandbox content change");
  const afterContentChange = changed.agents.find(({agent_id}) => agent_id === "agent.stable-zeta");
  assert.notEqual(afterContentChange.source_digest, beforeContentChange.source_digest);
  assert.notEqual(changed.roster_digest, renamed.roster_digest);
  const beforeWithoutDigest = {...beforeContentChange};
  const afterWithoutDigest = {...afterContentChange};
  delete beforeWithoutDigest.source_digest;
  delete afterWithoutDigest.source_digest;
  assert.deepEqual(afterWithoutDigest, beforeWithoutDigest, "source bytes changed unrelated roster metadata");

  fs.unlinkSync(path.join(fixtureRoot, "renamed.md"));
  const removed = requireSuccess(runRoster(fixtureRoot), "sandbox removal");
  assert.equal(removed.agents.some(({agent_id}) => agent_id === "agent.stable-zeta"), false);

  const outputPath = path.join(fixtureRoot, "roster.json");
  const outputResult = runRoster(fixtureRoot, ["--output", outputPath]);
  assert.equal(outputResult.status, 0, outputResult.stderr);
  const previousOutput = fs.readFileSync(outputPath, "utf8");
  assert.ok(previousOutput.endsWith("\n"));

  writeAgent(fixtureRoot, "missing-name.md", {
    description: "Fixture missing an explicit name",
  });
  const missingName = runRoster(fixtureRoot, ["--output", outputPath]);
  assert.notEqual(missingName.status, 0);
  assert.match(missingName.stderr, /missing explicit frontmatter name/i);
  assert.equal(fs.readFileSync(outputPath, "utf8"), previousOutput, "failed generation replaced prior output");
  fs.unlinkSync(path.join(fixtureRoot, "missing-name.md"));

  writeAgent(fixtureRoot, "duplicate.md", {
    name: "build-plus",
    description: "Fixture duplicate stable identity",
  });
  const duplicate = runRoster(fixtureRoot);
  assert.notEqual(duplicate.status, 0);
  assert.match(duplicate.stderr, /duplicate agent ID/i);
  fs.unlinkSync(path.join(fixtureRoot, "duplicate.md"));

  writeAgent(fixtureRoot, "bad-tier.md", {
    name: "bad-tier",
    description: "Fixture concrete model value",
    model: "provider/model",
  });
  const badTier = runRoster(fixtureRoot);
  assert.notEqual(badTier.status, 0);
  assert.match(badTier.stderr, /non-canonical workload tier/i);
  fs.unlinkSync(path.join(fixtureRoot, "bad-tier.md"));

  const aliasResult = runRoster(fixtureRoot, ["--output", path.join(fixtureRoot, "build-plus.md")]);
  assert.notEqual(aliasResult.status, 0);
  assert.match(aliasResult.stderr, /aliases agent source/i);

  const unsupported = runRoster(fixtureRoot, ["--format", "yaml"]);
  assert.notEqual(unsupported.status, 0);

  writeAgent(fixtureRoot, "unsafe name.md", {
    name: "safe-name",
    description: "Fixture unsafe source reference",
  });
  const unsafeFilename = runRoster(fixtureRoot);
  assert.notEqual(unsafeFilename.status, 0);
  assert.match(unsafeFilename.stderr, /not relative and registered/i);
  fs.unlinkSync(path.join(fixtureRoot, "unsafe name.md"));

  const invalidAbsolute = copy(initial);
  invalidAbsolute.agents[0].source_ref = "agents:/private/source.md";
  assert.equal(validate(invalidAbsolute), false, "absolute source reference unexpectedly validated");

  const invalidProvider = copy(initial);
  invalidProvider.agents[0].provider_id = "provider/concrete";
  assert.equal(validate(invalidProvider), false, "provider-specific field unexpectedly validated");

  const invalidRosterIdentity = copy(initial);
  invalidRosterIdentity.roster_id = "agent-roster.other";
  assert.equal(validate(invalidRosterIdentity), false, "alternate roster identity unexpectedly validated");

  const invalidGuideIdentity = copy(initial);
  invalidGuideIdentity.agents.find(({kind}) => kind === "framework_guide").agent_id = "agent.other-guide";
  assert.equal(validate(invalidGuideIdentity), false, "alternate framework guide unexpectedly validated");

  const unknownField = copy(initial);
  unknownField.runtime_overlay = {};
  assert.equal(validate(unknownField), false, "unknown roster field unexpectedly validated");
} finally {
  fs.rmSync(fixtureRoot, {recursive: true, force: true});
}

console.log("PASS: canonical agent roster is deterministic, portable, and discovery-driven");
