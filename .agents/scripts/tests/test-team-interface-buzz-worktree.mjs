// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import test from "node:test";
import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const helper = path.resolve(testDirectory, "../team-interface-buzz-worktree.sh");

function run(command, args, options = {}) {
  return spawnSync(command, args, {encoding: "utf8", ...options});
}

function requireSuccess(result, label) {
  assert.equal(result.status, 0, `${label} failed:\n${result.stderr}`);
  return result.stdout.trim();
}

test("Buzz worktree resolver binds canonical projects per host-qualified agent", () => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "aidevops-buzz-worktree-")));
  const canonical = path.join(root, "project");
  const central = path.join(root, "worktrees");
  const manager = path.join(root, "worktree-manager.sh");
  fs.mkdirSync(canonical, {mode: 0o700});
  fs.mkdirSync(central, {mode: 0o700});
  requireSuccess(run("/usr/bin/git", ["-C", canonical, "init", "--quiet", "--initial-branch=main"]), "git init");
  fs.writeFileSync(path.join(canonical, "README.md"), "fixture\n");
  requireSuccess(run("/usr/bin/git", ["-C", canonical, "add", "README.md"]), "git add");
  requireSuccess(run("/usr/bin/git", [
    "-C", canonical,
    "-c", "user.name=Fixture",
    "-c", "user.email=fixture@example.invalid",
    "commit", "--quiet", "-m", "fixture",
  ]), "git commit");
  fs.writeFileSync(manager, `#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "add" ]]
[[ "$PWD" == "${canonical}" ]]
/usr/bin/git -C "${canonical}" worktree add -q -b "$2" "$3" main
`);
  fs.chmodSync(manager, 0o700);
  const environment = {
    ...process.env,
    AIDEVOPS_BUZZ_HOST_SLUG: "test-host",
    AIDEVOPS_BUZZ_WORKTREE_MANAGER: manager,
    AIDEVOPS_WORKTREE_BASE_DIR: central,
  };
  try {
    const resolved = requireSuccess(
      run(helper, ["resolve", canonical, "build-plus"], {env: environment}),
      "canonical project resolution",
    );
    assert.equal(resolved, path.join(central, "project-buzz-test-host-build-plus"));
    assert.equal(
      requireSuccess(run("/usr/bin/git", ["-C", resolved, "branch", "--show-current"]), "branch read"),
      "buzz/test-host/build-plus",
    );
    const reused = requireSuccess(
      run(helper, ["resolve", canonical, "build-plus"], {env: environment}),
      "existing worktree resolution",
    );
    assert.equal(reused, resolved);
    const linked = requireSuccess(
      run(helper, ["resolve", resolved, "build-plus"], {env: environment}),
      "explicit linked worktree resolution",
    );
    assert.equal(linked, resolved);

    const invalid = run(helper, ["resolve", canonical, "../escape"], {env: environment});
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, /agent slug is invalid/);

    const secondAgent = requireSuccess(
      run(helper, ["resolve", canonical, "aidevops"], {
        cwd: root,
        env: environment,
      }),
      "non-repository caller resolution",
    );
    assert.equal(secondAgent, path.join(central, "project-buzz-test-host-aidevops"));
  } finally {
    fs.rmSync(root, {recursive: true, force: true});
  }
});
