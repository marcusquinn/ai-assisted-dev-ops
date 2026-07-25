// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createTools } from "../tools.mjs";

function git(cwd, args) {
  return execFileSync("/usr/bin/git", args, {
    cwd,
    encoding: "utf-8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function createRepository(root, name) {
  const repo = join(root, name);
  mkdirSync(repo);
  git(repo, ["init", "--initial-branch=main"]);
  git(repo, ["config", "user.email", "test@example.invalid"]);
  git(repo, ["config", "user.name", "Test"]);
  git(repo, ["config", "commit.gpgsign", "false"]);
  writeFileSync(join(repo, "README.md"), "fixture\n");
  git(repo, ["add", "README.md"]);
  git(repo, ["commit", "--no-gpg-sign", "-m", "init"]);
  return repo;
}

test("hook status inspects only known markers for the assigned linked worktree", async () => {
  const root = mkdtempSync(join(tmpdir(), "t28615-hook-status-"));
  const repo = createRepository(root, "repo");
  const linked = join(root, "linked");
  const otherRepo = createRepository(root, "other");

  try {
    git(repo, ["worktree", "add", "-b", "bugfix/fixture", linked]);
    const hooksDir = join(repo, ".git", "hooks");
    writeFileSync(join(hooksDir, "pre-commit"), [
      "#!/usr/bin/env bash",
      "# aidevops-pre-commit-hook",
      "# aidevops-markdoc-validate-hook",
      "private fixture content must never be returned",
      "",
    ].join("\n"));
    writeFileSync(join(hooksDir, "pre-push"), [
      "#!/usr/bin/env bash",
      "# aidevops-gh-wrapper-guard",
      "# aidevops-pre-push-quality-hook",
      "",
    ].join("\n"));

    const hookTool = createTools(root, () => "", { workerWorktree: linked }).aidevops_hook_status;
    const result = await hookTool.execute({ workdir: linked });
    const status = JSON.parse(result);

    assert.equal(status.schema, "aidevops-hook-status/v1");
    assert.equal(status.sharedGitDirectory, true);
    assert.equal(status.hooksDirectory, "directory");
    assert.deepEqual(status.hooks["pre-commit"], {
      status: "regular-file",
      markers: { quality: true, markdoc: true },
    });
    assert.deepEqual(status.hooks["pre-push"], {
      status: "regular-file",
      markers: { ghWrapper: true, quality: true },
    });
    assert.doesNotMatch(result, /private fixture content/);
    assert.equal(result.includes(root), false, "status must not expose absolute fixture paths");

    const denied = await hookTool.execute({ workdir: otherRepo });
    assert.match(denied, /inspect only their assigned worktree/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("hook status rejects symlinked hook files without reading their targets", async () => {
  const root = mkdtempSync(join(tmpdir(), "t28615-hook-symlink-"));
  const repo = createRepository(root, "repo");
  const target = join(root, "outside-hook");

  try {
    writeFileSync(target, "# aidevops-pre-commit-hook\nprivate target content\n");
    symlinkSync(target, join(repo, ".git", "hooks", "pre-commit"));
    const hookTool = createTools(root, () => "").aidevops_hook_status;
    const result = await hookTool.execute({ workdir: repo });
    const status = JSON.parse(result);

    assert.equal(status.hooks["pre-commit"].status, "unsafe-symlink");
    assert.deepEqual(status.hooks["pre-commit"].markers, { quality: false, markdoc: false });
    assert.doesNotMatch(result, /private target content/);
    assert.equal(result.includes(root), false, "status must not expose symlink or repository paths");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
