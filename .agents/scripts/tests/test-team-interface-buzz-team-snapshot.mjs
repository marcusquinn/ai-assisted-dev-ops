// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "../../..");
const generator = path.join(repositoryRoot, ".agents/scripts/team-interface-buzz-team-snapshot.py");
const helper = path.join(repositoryRoot, ".agents/scripts/buzz-team-provision-helper.sh");

function runGenerator(argumentsList, options = {}) {
  return spawnSync("python3", [generator, ...argumentsList], {
    encoding: "utf8",
    env: {...process.env, AIDEVOPS_BUZZ_HOST_SLUG: "test-host-01"},
    ...options,
  });
}

function requireSuccess(result, label) {
  assert.equal(result.status, 0, `${label} failed:\n${result.stderr}`);
  return result.stdout ? JSON.parse(result.stdout) : undefined;
}

function decodeAvatar(member) {
  const prefix = "data:image/svg+xml;base64,";
  assert.match(member.profile.avatarDataUrl, /^data:image\/svg\+xml;base64,/);
  assert.ok(Buffer.byteLength(member.profile.avatarDataUrl, "ascii") < 64 * 1024);
  return Buffer.from(member.profile.avatarDataUrl.slice(prefix.length), "base64").toString("utf8");
}

function writeAgent(directory, filename, {name, description, model, heading}) {
  fs.writeFileSync(path.join(directory, filename), [
    "---",
    `name: ${name}`,
    `description: ${description}`,
    "mode: subagent",
    ...(model ? [`model: ${model}`] : []),
    "---",
    "",
    `# ${heading}`,
    "",
    "Fixture instructions must not be copied into the portable snapshot.",
    "",
  ].join("\n"));
}

const liveFirst = runGenerator(["generate", "--agents-dir", path.join(repositoryRoot, ".agents")]);
const liveSnapshot = requireSuccess(liveFirst, "live Buzz team snapshot generation");
const liveSecond = runGenerator(["generate", "--agents-dir", path.join(repositoryRoot, ".agents")]);
assert.equal(liveSecond.status, 0, liveSecond.stderr);
assert.equal(liveSecond.stdout, liveFirst.stdout, "unchanged canonical roster must produce identical bytes");
assert.equal(liveSnapshot.format, "buzz-team-snapshot");
assert.equal(liveSnapshot.version, 1);
assert.equal(liveSnapshot.team.name, "AI DevOps");
assert.match(liveSnapshot.team.instructions, /full interactive aidevops runtime/);
assert.match(liveSnapshot.team.instructions, /Buzz access policy controls ingress/);
assert.deepEqual(
  liveSnapshot.members.map(({profile}) => profile.displayName),
  [
    "aidevops-test-host-01", "automate-test-host-01", "build-plus-test-host-01",
    "business-test-host-01", "content-test-host-01", "health-test-host-01",
    "legal-test-host-01", "marketing-sales-test-host-01", "pr-test-host-01",
    "private-local-ai-test-host-01", "product-test-host-01", "reports-test-host-01",
    "research-test-host-01", "seo-test-host-01", "vault-test-host-01",
  ],
);
for (const member of liveSnapshot.members) {
  assert.equal(member.format, "buzz-agent-snapshot");
  assert.equal(member.version, 1);
  assert.equal(member.definition.respondTo, "owner-only");
  assert.equal(member.definition.parallelism, 1);
  assert.equal(member.definition.sourceIsBuiltin, false);
  assert.equal(member.memory.level, "none");
  if (member.profile.displayName === "private-local-ai-test-host-01") {
    assert.equal(member.profile.about, "Private investigator using local AI");
    assert.equal(member.definition.runtime, "buzz-agent");
    assert.equal(member.definition.model, "auto");
    assert.equal(member.definition.provider, "relay-mesh");
    assert.match(member.definition.systemPrompt, /Buzz shared compute/);
    assert.match(
      member.definition.systemPrompt,
      /Do not describe Buzz shared compute as local, private, or on-device unless/i,
    );
  } else {
    assert.equal(member.definition.runtime, "aidevops-interactive-v1");
    assert.equal("model" in member.definition, false);
    assert.equal("provider" in member.definition, false);
  }
  assert.match(member.profile.displayName, /^[a-z0-9]+(?:-[a-z0-9]+)*-test-host-01$/);
  assert.equal(member.definition.name, member.profile.displayName);
  assert.match(member.definition.systemPrompt, /Aidevops canonical source: agents:[A-Za-z0-9._-]+\.md/);
  assert.match(member.definition.systemPrompt, /Expected source digest: sha256:[a-f0-9]{64}/);
  assert.doesNotMatch(member.definition.systemPrompt, /Fixture instructions/);
  const avatar = decodeAvatar(member);
  assert.match(avatar, /<svg[^>]+width="1024"[^>]+height="1024"/);
  assert.doesNotMatch(avatar, /\{\{/);
}
assert.equal(
  liveSnapshot.members.filter(({definition}) => definition.runtime === "buzz-agent").length,
  1,
  "exactly one canonical member must use the Buzz shared-compute runtime",
);
assert.equal(
  liveSnapshot.members.filter(
    ({definition}) => definition.runtime === "aidevops-interactive-v1",
  ).length,
  14,
  "the existing fourteen members must retain the full interactive aidevops runtime",
);
assert.equal(
  new Set(liveSnapshot.members.map(({profile}) => profile.avatarDataUrl)).size,
  liveSnapshot.members.length,
  "each canonical agent must receive a distinct reviewed hue",
);
assert.match(
  decodeAvatar(liveSnapshot.members.find(({profile}) => profile.displayName === "aidevops-test-host-01")),
  /#66d9f2/,
  "the framework guide must preserve the canonical aidevops cyan",
);
assert.doesNotMatch(liveFirst.stdout, /private_key|auth_tag|relay_url|agent_command|provider_binary_path/i);

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-buzz-team-"));
try {
  const agentsDirectory = path.join(fixtureRoot, "agents");
  fs.mkdirSync(agentsDirectory, {mode: 0o700});
  writeAgent(agentsDirectory, "build-plus.md", {
    name: "build-plus",
    description: "Fixture build specialist",
    heading: "Build+",
  });
  writeAgent(agentsDirectory, "automate.md", {
    name: "automate",
    description: "Fixture automation specialist",
    model: "thinking",
    heading: "Automate",
  });
  writeAgent(agentsDirectory, "aidevops.md", {
    name: "aidevops",
    description: "Fixture framework guide",
    heading: "AI DevOps",
  });

  const missingPrivate = runGenerator(["generate", "--agents-dir", agentsDirectory]);
  assert.notEqual(missingPrivate.status, 0);
  assert.match(missingPrivate.stderr, /exactly one Private AI member/);
  writeAgent(agentsDirectory, "private-local-ai.md", {
    name: "private-local-ai",
    description: "Fixture private investigator",
    heading: "Private AI",
  });

  const fixtureFirst = requireSuccess(
    runGenerator(["generate", "--agents-dir", agentsDirectory]),
    "fixture generation",
  );
  assert.deepEqual(
    fixtureFirst.members.map(({profile}) => profile.displayName),
    [
      "aidevops-test-host-01",
      "automate-test-host-01",
      "build-plus-test-host-01",
      "private-local-ai-test-host-01",
    ],
  );
  assert.deepEqual(
    fixtureFirst.members.find(
      ({profile}) => profile.displayName === "private-local-ai-test-host-01",
    ).definition,
    {
      model: "auto",
      name: "private-local-ai-test-host-01",
      parallelism: 1,
      provider: "relay-mesh",
      respondTo: "owner-only",
      runtime: "buzz-agent",
      sourceIsBuiltin: false,
      systemPrompt: fixtureFirst.members.find(
        ({profile}) => profile.displayName === "private-local-ai-test-host-01",
      ).definition.systemPrompt,
    },
  );
  assert.equal(
    new Set(fixtureFirst.members.map(({profile}) => profile.avatarDataUrl)).size,
    fixtureFirst.members.length,
  );
  assert.match(
    fixtureFirst.members.find(
      ({profile}) => profile.displayName === "automate-test-host-01",
    ).definition.systemPrompt,
    /Portable workload tier: thinking/,
  );
  assert.doesNotMatch(JSON.stringify(fixtureFirst), /Fixture instructions must not be copied/);

  const beforeChange = JSON.stringify(fixtureFirst);
  const automateAvatarBeforeChange = fixtureFirst.members.find(
    ({definition}) => definition.systemPrompt.includes("agents:automate.md"),
  ).profile.avatarDataUrl;
  fs.appendFileSync(path.join(agentsDirectory, "automate.md"), "Changed canonical bytes.\n");
  const changed = requireSuccess(
    runGenerator(["generate", "--agents-dir", agentsDirectory]),
    "changed fixture generation",
  );
  assert.notEqual(JSON.stringify(changed), beforeChange, "source digest change did not reach snapshot");
  assert.equal(
    changed.members.find(
      ({definition}) => definition.systemPrompt.includes("agents:automate.md"),
    ).profile.avatarDataUrl,
    automateAvatarBeforeChange,
    "avatar bytes must remain keyed to stable agent identity rather than source content",
  );

  const outputPath = path.join(fixtureRoot, "aidevops.team.json");
  const outputResult = runGenerator([
    "generate", "--agents-dir", agentsDirectory, "--output", outputPath,
  ]);
  assert.equal(outputResult.status, 0, outputResult.stderr);
  assert.equal(fs.statSync(outputPath).mode & 0o777, 0o600);
  assert.deepEqual(JSON.parse(fs.readFileSync(outputPath, "utf8")), changed);

  const symlinkPath = path.join(fixtureRoot, "snapshot-link.json");
  fs.symlinkSync(outputPath, symlinkPath);
  const symlinkResult = runGenerator([
    "generate", "--agents-dir", agentsDirectory, "--output", symlinkPath,
  ]);
  assert.notEqual(symlinkResult.status, 0);
  assert.match(symlinkResult.stderr, /symbolic link/i);

  const mockBuzz = path.join(fixtureRoot, "buzz-mock.sh");
  const brokerLog = path.join(fixtureRoot, "broker.log");
  const brokerSnapshot = path.join(fixtureRoot, "broker-snapshot.json");
  fs.writeFileSync(mockBuzz, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$MOCK_BUZZ_LOG"
if [[ "$1 $2" == "desktop status" ]]; then
  [[ "\${MOCK_BUZZ_FAIL_STATUS:-}" != "1" ]] || exit 7
  printf '{"apiVersion":1,"available":true}\\n'
  exit 0
fi
[[ "$1 $2 $3" == "desktop agents import-team-draft" ]] || exit 8
mode=$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$4")
[[ "$mode" == "600" ]] || exit 9
cp "$4" "$MOCK_BUZZ_SNAPSHOT"
printf '{"queued":true}\\n'
`);
  fs.chmodSync(mockBuzz, 0o700);
  const managedTemp = path.join(fixtureRoot, "managed-temp");
  fs.mkdirSync(managedTemp, {mode: 0o700});
  const submit = spawnSync(
    helper,
    ["submit", "--agents-dir", agentsDirectory],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        AIDEVOPS_BUZZ_CLI: mockBuzz,
        AIDEVOPS_BUZZ_HOST_SLUG: "test-host-01",
        AIDEVOPS_TEMP_DIR: managedTemp,
        MOCK_BUZZ_LOG: brokerLog,
        MOCK_BUZZ_SNAPSHOT: brokerSnapshot,
      },
    },
  );
  assert.equal(submit.status, 0, submit.stderr);
  assert.deepEqual(fs.readFileSync(brokerLog, "utf8").trim().split("\n").map((line) => line.split(" ").slice(0, 3).join(" ")), [
    "desktop status",
    "desktop agents import-team-draft",
  ]);
  assert.deepEqual(JSON.parse(fs.readFileSync(brokerSnapshot, "utf8")), changed);
  assert.deepEqual(fs.readdirSync(managedTemp), [], "submission leaked its private temporary snapshot");

  fs.writeFileSync(brokerLog, "");
  const failedStatus = spawnSync(
    helper,
    ["submit", "--agents-dir", agentsDirectory],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        AIDEVOPS_BUZZ_CLI: mockBuzz,
        AIDEVOPS_BUZZ_HOST_SLUG: "test-host-01",
        AIDEVOPS_TEMP_DIR: managedTemp,
        MOCK_BUZZ_FAIL_STATUS: "1",
        MOCK_BUZZ_LOG: brokerLog,
        MOCK_BUZZ_SNAPSHOT: brokerSnapshot,
      },
    },
  );
  assert.notEqual(failedStatus.status, 0);
  assert.equal(fs.readFileSync(brokerLog, "utf8").trim(), "desktop status");
} finally {
  fs.rmSync(fixtureRoot, {recursive: true, force: true});
}

console.log("PASS: Buzz team snapshot generation and owner-reviewed submission are deterministic and bounded");
