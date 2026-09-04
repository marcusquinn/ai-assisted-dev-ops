// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createTools } from "../tools.mjs";

const testDir = dirname(fileURLToPath(import.meta.url));
const scriptsDir = resolve(testDir, "../../../scripts");

function git(cwd, args) {
  return execFileSync("/usr/bin/git", args, {
    cwd,
    encoding: "utf-8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

test("pre-edit tool validates the explicitly targeted Git worktree", async () => {
  const root = mkdtempSync(join(tmpdir(), "t27909-pre-edit-tool-"));
  const repo = join(root, "repo");
  const linked = join(root, "linked");
  const otherLinked = join(root, "other-linked");
  const nonGit = join(root, "not-git");
  const injectionMarker = join(root, "injected");

  try {
    mkdirSync(repo);
    mkdirSync(nonGit);
    git(repo, ["init", "--initial-branch=main"]);
    git(repo, ["config", "user.email", "test@example.invalid"]);
    git(repo, ["config", "user.name", "Test"]);
    git(repo, ["config", "commit.gpgsign", "false"]);
    writeFileSync(join(repo, "README.md"), "fixture\n");
    git(repo, ["add", "README.md"]);
    git(repo, ["commit", "--no-gpg-sign", "-m", "init"]);
    git(repo, ["worktree", "add", "-b", "bugfix/fixture", linked]);
    git(repo, ["worktree", "add", "-b", "bugfix/other-fixture", otherLinked]);

    const preEditTool = createTools(scriptsDir, () => "").aidevops_pre_edit_check;
    const canonicalResult = await preEditTool.execute({ workdir: repo });
    assert.match(canonicalResult, /Pre-edit check exit [12]:/);
    assert.match(canonicalResult, /create a worktree/i);

    const linkedResult = await preEditTool.execute({
      workdir: linked,
      task: `fix fixture '; touch ${injectionMarker}`,
    });
    assert.match(linkedResult, /Pre-edit check PASSED \(exit 0\)/);
    assert.equal(existsSync(injectionMarker), false, "task text must remain one argv value");

    const otherLinkedResult = await preEditTool.execute({
      workdir: linked,
      targetPaths: [join(otherLinked, "README.md")],
    });
    assert.match(otherLinkedResult, /Pre-edit check PASSED \(exit 0\)/);
    assert.match(otherLinkedResult, /bugfix\/other-fixture/);
    assert.doesNotMatch(otherLinkedResult, /bugfix\/fixture[^-]/);

    const multipleWorktreesResult = await preEditTool.execute({
      workdir: linked,
      targetPaths: [join(linked, "README.md"), join(otherLinked, "README.md")],
    });
    assert.match(multipleWorktreesResult, /explicit repository targets span multiple worktrees/);
    assert.doesNotMatch(multipleWorktreesResult, /Pre-edit check PASSED/);

    const invalidResult = await preEditTool.execute({ workdir: nonGit, task: "fix fixture" });
    assert.match(invalidResult, /target workdir must resolve to an existing Git worktree/);

    const worktreesBefore = git(repo, ["worktree", "list", "--porcelain"]);
    const externalResult = await preEditTool.execute({
      workdir: repo,
      task: "update personal configuration",
      targetPaths: [join(nonGit, "custom.sh"), join(root, "LaunchAgents", "fixture.plist")],
    });
    assert.match(externalResult, /Git isolation not applicable/);
    assert.match(externalResult, /does not authorize file writes/);
    assert.equal(git(repo, ["worktree", "list", "--porcelain"]), worktreesBefore);

    const repositoryResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: [join(repo, "nested", "..", "README.md")],
    });
    assert.match(repositoryResult, /Pre-edit check exit [12]:/);
    assert.doesNotMatch(repositoryResult, /Git isolation not applicable/);

    const mixedResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: [join(nonGit, "custom.sh"), join(repo, "README.md")],
    });
    assert.match(mixedResult, /Pre-edit check exit [12]:/);
    assert.doesNotMatch(mixedResult, /Git isolation not applicable/);

    const linkedToCanonicalResult = await preEditTool.execute({
      workdir: linked,
      targetPaths: [join(repo, "README.md")],
    });
    assert.match(linkedToCanonicalResult, /failed closed/);
    assert.doesNotMatch(linkedToCanonicalResult, /Pre-edit check PASSED/);

    const symlinkEscape = join(repo, "external-link");
    symlinkSync(nonGit, symlinkEscape);
    const symlinkResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: [join(symlinkEscape, "custom.sh")],
    });
    assert.match(symlinkResult, /failed closed/);
    assert.doesNotMatch(symlinkResult, /Git isolation not applicable/);

    const traversalResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: ["../not-git/custom.sh"],
    });
    assert.match(traversalResult, /parent traversal.*ambiguous/);
    assert.doesNotMatch(traversalResult, /Git isolation not applicable/);

    const repositoryLink = join(nonGit, "repository-link");
    symlinkSync(repo, repositoryLink);
    const repositorySymlinkResult = await preEditTool.execute({
      workdir: repo,
      targetPaths: [join(repositoryLink, "README.md")],
    });
    assert.match(repositorySymlinkResult, /Pre-edit check exit [12]:/);
    assert.doesNotMatch(repositorySymlinkResult, /Git isolation not applicable/);

    const malformedResult = await preEditTool.execute({ workdir: repo, targetPaths: [""] });
    assert.match(malformedResult, /failed closed/);
    const malformedArrayResult = await preEditTool.execute({ workdir: repo, targetPaths: {} });
    assert.match(malformedArrayResult, /targetPaths must be an array/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("slow loop-mode creation is reported exactly once beyond the former timeout", { timeout: 30000 }, async () => {
  const root = mkdtempSync(join(tmpdir(), "t28080-pre-edit-slow-"));
  const repo = join(root, "repo");
  const linked = join(root, "slow-linked");
  const fixtureScripts = join(root, "scripts");

  try {
    mkdirSync(repo);
    mkdirSync(fixtureScripts);
    git(repo, ["init", "--initial-branch=main"]);
    git(repo, ["config", "user.email", "test@example.invalid"]);
    git(repo, ["config", "user.name", "Test"]);
    git(repo, ["config", "commit.gpgsign", "false"]);
    writeFileSync(join(repo, "README.md"), "fixture\n");
    git(repo, ["add", "README.md"]);
    git(repo, ["commit", "--no-gpg-sign", "-m", "init"]);
    writeFileSync(join(fixtureScripts, "pre-edit-check.sh"), `#!/usr/bin/env bash
set -eu
[[ "\${OPENCODE_SESSION_ID:-}" == "ses_pre_edit_fixture" ]] || exit 9
[[ "\${OPENCODE_PID:-}" =~ ^[0-9]+$ ]] || exit 10
linked=${JSON.stringify(linked)}
if ! /usr/bin/git -C "$PWD" show-ref --verify --quiet refs/heads/bugfix/slow-fixture; then
  sleep 10.1
  /usr/bin/git -C "$PWD" worktree add -q -b bugfix/slow-fixture "$linked"
fi
printf 'LOOP_DECISION=worktree_created\\nWORKTREE_PATH=%s\\nNEXT_STEP: cd to the worktree path and continue implementation there.\\n' "$linked"
`);

    const preEditTool = createTools(fixtureScripts, () => "").aidevops_pre_edit_check;
    const context = { sessionID: "ses_pre_edit_fixture" };
    const firstResult = await preEditTool.execute({ workdir: repo, task: "fix slow fixture" }, context);
    const secondResult = await preEditTool.execute({ workdir: repo, task: "fix slow fixture" }, context);

    assert.match(firstResult, /Pre-edit check PASSED \(exit 0\)/);
    assert.match(firstResult, new RegExp(`WORKTREE_PATH=${linked.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
    assert.match(secondResult, /Pre-edit check PASSED \(exit 0\)/);
    const worktreeList = git(repo, ["worktree", "list", "--porcelain"]);
    assert.equal(worktreeList.split("branch refs/heads/bugfix/slow-fixture").length - 1, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("timeout is explicit and terminates the complete fixture process tree", async () => {
  const root = mkdtempSync(join(tmpdir(), "t28080-pre-edit-timeout-"));
  const repo = join(root, "repo");
  const fixtureScripts = join(root, "scripts");
  const lateMarker = join(root, "late-side-effect");

  try {
    mkdirSync(repo);
    mkdirSync(fixtureScripts);
    git(repo, ["init", "--initial-branch=main"]);
    writeFileSync(join(fixtureScripts, "pre-edit-check.sh"), `#!/usr/bin/env bash
sleep 0.2
touch ${JSON.stringify(lateMarker)}
`);
    const preEditTool = createTools(fixtureScripts, () => "", { preEditTimeoutMs: 25 }).aidevops_pre_edit_check;
    const result = await preEditTool.execute({ workdir: repo, task: "fix timeout fixture" });

    assert.match(result, /Pre-edit check TIMED OUT after 25ms/);
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 300));
    assert.equal(existsSync(lateMarker), false, "timed-out descendants must not complete side effects");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
