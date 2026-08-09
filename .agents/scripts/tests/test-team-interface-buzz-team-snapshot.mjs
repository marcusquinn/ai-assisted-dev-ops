// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const snapshotScript = path.join(repositoryRoot, ".agents/scripts/team-interface-buzz-team-snapshot.py");
const agentsDirectory = path.join(repositoryRoot, ".agents");

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function runSnapshot(argumentsList = []) {
  return spawnSync("python3", [snapshotScript, "--agents-dir", agentsDirectory, ...argumentsList], {encoding: "utf8"});
}

const first = runSnapshot();
assert.equal(first.status, 0, first.stderr);
const second = runSnapshot();
assert.equal(second.status, 0, second.stderr);
assert.equal(second.stdout, first.stdout, "unchanged canonical sources must produce byte-identical snapshots");

const snapshot = JSON.parse(first.stdout);
assert.equal(snapshot.document_type, "buzz_team_import_snapshot");
assert.equal(snapshot.import_mode, "owner_reviewed_create_only");
assert.equal(snapshot.team_id, "team.aidevops");
assert.equal(snapshot.members.length, 15);
assert.equal(new Set(snapshot.members.map(({agent_id: agentID}) => agentID)).size, 15);

const privateMembers = snapshot.members.filter(({agent_id: agentID}) => agentID === "agent.private-local-ai");
assert.equal(privateMembers.length, 1);
const [privateMember] = privateMembers;
assert.deepEqual(
  {
    agent_kind: privateMember.agent_kind,
    investigator_profile: privateMember.investigator_profile,
    max_parallelism: privateMember.max_parallelism,
    model: privateMember.model,
    portable_memory: privateMember.portable_memory,
    provider: privateMember.provider,
    response_policy: privateMember.response_policy,
  },
  {
    agent_kind: "Buzz Agent",
    investigator_profile: "private_ai_investigator_v1",
    max_parallelism: 1,
    model: "auto",
    portable_memory: false,
    provider: "relay-mesh",
    response_policy: "owner_only",
  },
);

const interactiveMembers = snapshot.members.filter(({agent_id: agentID}) => agentID !== "agent.private-local-ai");
assert.equal(interactiveMembers.length, 14);
for (const member of interactiveMembers) {
  assert.equal(member.runtime, "aidevops-interactive-v1");
  assert.equal(Object.hasOwn(member, "provider"), false);
  assert.equal(Object.hasOwn(member, "model"), false);
}
for (const member of snapshot.members) {
  assert.match(member.source_digest, /^sha256:[a-f0-9]{64}$/);
  assert.match(member.runtime_anchor, /^sha256:[a-f0-9]{64}$/);
  assert.match(member.source_ref, /^agents:[A-Za-z0-9][A-Za-z0-9._-]*\.md$/);
}

const unsigned = structuredClone(snapshot);
delete unsigned.snapshot_digest;
const expectedDigest = `sha256:${crypto.createHash("sha256").update(canonicalJson(unsigned)).digest("hex")}`;
assert.equal(snapshot.snapshot_digest, expectedDigest);
assert.equal(JSON.stringify(snapshot).match(/token|secret|credential|nsec/iu), null);

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-buzz-snapshot-"));
try {
  const outputPath = path.join(temporary, "snapshot.json");
  const written = runSnapshot(["--output", outputPath]);
  assert.equal(written.status, 0, written.stderr);
  assert.equal(fs.readFileSync(outputPath, "utf8"), first.stdout);
} finally {
  fs.rmSync(temporary, {force: true, recursive: true});
}

console.log("PASS: immutable owner-reviewed Buzz team snapshot is complete and private-local-ai is isolated");
