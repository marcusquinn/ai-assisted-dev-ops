// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { registerResearchOnlyAgent } from "../config-hook.mjs";

test("research-only profile overrides permissive config and fails closed", () => {
  const agentsDir = mkdtempSync(join(tmpdir(), "aidevops-research-only-"));
  const sourceDir = join(agentsDir, "tools", "ai-assistants");
  mkdirSync(sourceDir, { recursive: true });
  writeFileSync(join(sourceDir, "research-only.md"), `---
name: research-only
description: Canonical research profile
mode: subagent
tools:
  "*": false
  read: true
  bash: false
permission:
  "*": deny
  read:
    "*": allow
    "*.env": deny
  bash: deny
---

Canonical research prompt.
`);

  try {
    const config = {
      tools: { "playwriter_*": true },
      agent: {
        "research-only": {
          tools: { bash: true, task: true },
          permission: "allow",
        },
      },
    };

    assert.equal(registerResearchOnlyAgent(config, agentsDir), 1);
    const profile = config.agent["research-only"];

    assert.equal(profile.description, "Canonical research profile");
    assert.equal(profile.mode, "subagent");
    assert.equal(profile.prompt, "Canonical research prompt.");
    assert.deepEqual(profile.tools, {
      "*": false,
      read: true,
      bash: false,
    });
    assert.equal(profile.permission["*"], "deny");
    assert.equal(profile.permission.bash, "deny");
    assert.equal(profile.permission.read["*"], "allow");
    assert.equal(profile.permission.read["*.env"], "deny");
    assert.equal(profile.name, undefined);
    assert.equal(config.tools["playwriter_*"], true);
  } finally {
    rmSync(agentsDir, { recursive: true, force: true });
  }
});

test("research-only profile fails closed when canonical frontmatter is invalid", () => {
  const agentsDir = mkdtempSync(join(tmpdir(), "aidevops-research-only-"));
  const sourceDir = join(agentsDir, "tools", "ai-assistants");
  mkdirSync(sourceDir, { recursive: true });
  writeFileSync(join(sourceDir, "research-only.md"), "---\ndescription: Broken\n tools:\n---\nUnsafe prompt.\n");

  try {
    const config = { agent: {} };
    assert.equal(registerResearchOnlyAgent(config, agentsDir), 1);
    assert.deepEqual(config.agent["research-only"].tools, { "*": false });
    assert.equal(config.agent["research-only"].permission, "deny");
    assert.equal(config.agent["research-only"].disable, true);
  } finally {
    rmSync(agentsDir, { recursive: true, force: true });
  }
});

test("native ai-research child receives an inference-only tool ceiling", () => {
  const agentsDir = mkdtempSync(join(tmpdir(), "aidevops-research-only-"));
  const sourceDir = join(agentsDir, "tools", "ai-assistants");
  mkdirSync(sourceDir, { recursive: true });
  writeFileSync(join(sourceDir, "research-only.md"), `---
name: research-only
description: Canonical research profile
mode: subagent
tools:
  "*": false
  read: true
  webfetch: true
permission:
  "*": deny
  read: allow
  webfetch: allow
---

Canonical research prompt.
`);

  try {
    const config = { agent: {} };
    assert.equal(registerResearchOnlyAgent(
      config,
      agentsDir,
      { AIDEVOPS_AI_RESEARCH_TOOL_CEILING: "1" },
    ), 1);
    const profile = config.agent["research-only"];

    assert.deepEqual(profile.tools, { "*": false });
    assert.equal(profile.permission, "deny");
    assert.equal(profile.prompt, "Canonical research prompt.");
  } finally {
    rmSync(agentsDir, { recursive: true, force: true });
  }
});
