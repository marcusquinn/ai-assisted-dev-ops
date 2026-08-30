// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  bindActiveScriptsDir,
  checkCanonicalGitSafetyGate,
  checkCanonicalWriteSafetyGate,
  checkCommandSafetyGate,
  isDirectFileMutationTool,
} from "../quality-hooks-git-safety.mjs";
import { createQualityHooks } from "../quality-hooks.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const scriptsDir = join(here, "..", "..", "..", "scripts");
const realGit = "/usr/bin/git";

function setupRepo({ managed = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "aidevops-git-gate-"));
  const repo = join(root, "repo");
  const linked = join(root, "linked");
  mkdirSync(repo);
  execFileSync(realGit, ["init", "-q", "-b", "main"], { cwd: repo });
  execFileSync(realGit, ["config", "user.name", "Test"], { cwd: repo });
  execFileSync(realGit, ["config", "user.email", "test@example.invalid"], { cwd: repo });
  execFileSync(realGit, ["config", "commit.gpgsign", "false"], { cwd: repo });
  if (managed) {
    writeFileSync(join(repo, ".aidevops.json"), "{}\n");
  }
  writeFileSync(join(repo, "README.md"), "seed\n");
  execFileSync(realGit, ["add", "README.md"], { cwd: repo });
  execFileSync(realGit, ["commit", "-q", "-m", "seed"], { cwd: repo });
  execFileSync(realGit, ["worktree", "add", "-q", "-b", "feature/test", linked], { cwd: repo });
  return { root, repo, linked };
}

test("classifies built-in and namespaced direct file mutation tools", () => {
  for (const tool of ["Write", "write_file", "edit", "edit_file", "write", "functions.apply_patch", "namespace/Edit", "tools::apply-patch"]) {
    assert.equal(isDirectFileMutationTool(tool), true, tool);
  }
  for (const tool of ["Bash", "read", "functions.read", "glob"]) {
    assert.equal(isDirectFileMutationTool(tool), false, tool);
  }
});

test("classifies every apply-patch target instead of trusting linked cwd", () => {
  const { root, repo, linked } = setupRepo();
  try {
    const linkedPatch = "*** Begin Patch\n*** Add File: linked-only.md\n+safe\n*** End Patch\n";
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, linked, linkedPatch),
    );
    const absoluteLinkedPatch = `*** Begin Patch\n*** Add File: ${join(linked, "absolute-linked.md")}\n+safe\n*** End Patch\n`;
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, absoluteLinkedPatch),
      "an absolute linked-worktree target must not inherit the canonical workspace classification",
    );
    const canonicalPatch = `*** Begin Patch\n*** Update File: ${join(repo, "README.md")}\n@@\n-seed\n+unsafe\n*** End Patch\n`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, linked, canonicalPatch),
      /canonical write policy.*read-only session mirrors/,
    );
    const traversalPatch = `*** Begin Patch\n*** Update File: ${join(linked, "..", "repo", "README.md")}\n@@\n-seed\n+unsafe\n*** End Patch\n`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, traversalPatch),
      /canonical write policy.*read-only session mirrors/,
    );
    symlinkSync(repo, join(linked, "canonical-link"));
    const symlinkPatch = `*** Begin Patch\n*** Update File: ${join(linked, "canonical-link", "README.md")}\n@@\n-seed\n+unsafe\n*** End Patch\n`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, symlinkPatch),
      /canonical write policy.*read-only session mirrors/,
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, linked, ""),
      /targets could not be classified/,
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, linked, { invalid: true }),
      /targets could not be classified/,
    );

    const outsideTarget = join(root, "aidevops-issue-body.md");
    const outsidePatch = `*** Begin Patch\n*** Add File: ${outsideTarget}\n+safe\n*** End Patch\n`;
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, outsidePatch),
    );
    const mixedPatch = `*** Begin Patch\n*** Add File: ${outsideTarget}\n+safe\n*** Update File: ${join(repo, "README.md")}\n@@\n-seed\n+unsafe\n*** End Patch\n`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo, mixedPatch),
      /canonical write policy.*read-only session mirrors/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("uses the plugin repository directory when mutation tools omit workdir", async () => {
  const { root, repo, linked } = setupRepo();
  try {
    const hooks = createQualityHooks({ scriptsDir, logsDir: root, repositoryDir: repo });
    const linkedPatch = `*** Begin Patch\n*** Add File: ${join(linked, "plugin-context.md")}\n+safe\n*** End Patch\n`;
    await assert.doesNotReject(
      () => hooks.toolExecuteBefore(
        { tool: "functions.apply_patch" },
        { args: { patchText: linkedPatch } },
      ),
      "the plugin project directory must establish same-repository linked-worktree identity",
    );

    const canonicalPatch = "*** Begin Patch\n*** Update File: README.md\n@@\n-seed\n+unsafe\n*** End Patch\n";
    await assert.rejects(
      () => hooks.toolExecuteBefore(
        { tool: "functions.apply_patch" },
        { args: { patchText: canonicalPatch } },
      ),
      /canonical write policy.*read-only session mirrors/,
      "relative mutation targets must resolve from the plugin project directory",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed when canonical policy returns a non-object payload", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-canonical-policy-"));
  const isolatedScripts = join(root, "scripts");
  mkdirSync(isolatedScripts);
  try {
    writeFileSync(
      join(isolatedScripts, "canonical-write-policy-helper.py"),
      "print('null')\n",
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("README.md", isolatedScripts),
      /malformed output/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("blocks every canonical direct write and preserves linked-worktree writes", () => {
  const { root, repo, linked } = setupRepo();
  try {
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(repo, "README.md"), scriptsDir, repo),
      /canonical write policy.*read-only session mirrors/,
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, repo),
      /canonical write policy/,
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(repo, "new-file.md"), scriptsDir, linked),
      /canonical write policy/,
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(linked, "README.md"), scriptsDir, linked),
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(linked, "README.md"), scriptsDir, repo),
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("new-file.md", scriptsDir, linked),
    );
    const bodyDir = join(root, ".aidevops", ".agent-workspace", "tmp");
    mkdirSync(bodyDir, { recursive: true });
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(bodyDir, "issue-body.md"), scriptsDir, repo),
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(linked, "from-canonical.md"), scriptsDir, repo),
    );

    const canonicalAlias = join(root, "canonical-alias");
    symlinkSync(repo, canonicalAlias, "dir");
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(canonicalAlias, "README.md"), scriptsDir, repo),
      /canonical write policy.*read-only session mirrors/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("allows cross-repository linked writes only inside the trusted Git workspace", () => {
  const { root, repo, linked } = setupRepo();
  const outsideRoot = mkdtempSync(`${root}-sibling-`);
  const previousWorkspace = process.env.AIDEVOPS_GIT_WORKSPACE_ROOT;
  const foreignRepo = join(root, "foreign-repo");
  const foreignLinked = join(root, "foreign-linked");
  const outsideRepo = join(outsideRoot, "outside-repo");
  const outsideLinked = join(outsideRoot, "outside-linked");
  const escapedOutsideFile = `${outsideRoot}-escaped.txt`;

  function createLinkedRepo(repoPath, linkedPath, branch) {
    mkdirSync(repoPath);
    execFileSync(realGit, ["init", "-q", "-b", "main"], { cwd: repoPath });
    execFileSync(realGit, ["config", "user.name", "Test"], { cwd: repoPath });
    execFileSync(realGit, ["config", "user.email", "test@example.invalid"], { cwd: repoPath });
    execFileSync(realGit, ["config", "commit.gpgsign", "false"], { cwd: repoPath });
    writeFileSync(join(repoPath, "README.md"), `${branch}\n`);
    execFileSync(realGit, ["add", "README.md"], { cwd: repoPath });
    execFileSync(realGit, ["commit", "-q", "-m", `${branch} seed`], { cwd: repoPath });
    execFileSync(realGit, ["worktree", "add", "-q", "-b", `feature/${branch}`, linkedPath], { cwd: repoPath });
  }

  try {
    createLinkedRepo(foreignRepo, foreignLinked, "foreign");
    createLinkedRepo(outsideRepo, outsideLinked, "outside");
    process.env.AIDEVOPS_GIT_WORKSPACE_ROOT = root;

    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(foreignLinked, "README.md"), scriptsDir, linked),
      "linked worktrees from sibling repositories inside the trusted workspace should be writable",
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(join(foreignLinked, "README.md"), scriptsDir, repo),
      "canonical context must not block a structurally safe foreign linked-worktree target",
    );
    const workspaceRootPatch = `*** Begin Patch\n*** Update File: ${join(foreignLinked, "README.md")}\n@@\n-foreign\n+updated\n*** End Patch\n`;
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, root, workspaceRootPatch),
      "a non-repository session root inside the trusted workspace must allow an absolute linked-worktree patch",
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate("", scriptsDir, outsideRoot, workspaceRootPatch),
      /limited to the trusted Git workspace/,
      "a non-repository session root outside the trusted workspace must remain blocked",
    );
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(outsideLinked, "README.md"), scriptsDir, linked),
      /limited to the trusted Git workspace/,
    );

    const escapedAlias = join(root, "outside-alias");
    symlinkSync(outsideLinked, escapedAlias, "dir");
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(escapedAlias, "README.md"), scriptsDir, linked),
      /limited to the trusted Git workspace/,
    );

    const outsideFile = join(outsideRoot, "outside.txt");
    const outsideFileAlias = join(linked, "outside-files");
    writeFileSync(outsideFile, "outside\n");
    writeFileSync(escapedOutsideFile, "escaped\n");
    symlinkSync(outsideRoot, outsideFileAlias, "dir");
    assert.throws(
      () => checkCanonicalWriteSafetyGate(join(outsideFileAlias, "outside.txt"), scriptsDir, linked),
      /symlinked write target escapes/,
    );
    const traversedExisting = `${outsideFileAlias}${sep}..${sep}${basename(escapedOutsideFile)}`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate(traversedExisting, scriptsDir, linked),
      /symlinked write target escapes/,
    );
    const traversedMissing = `${outsideFileAlias}${sep}..${sep}${basename(outsideRoot)}-missing.txt`;
    assert.throws(
      () => checkCanonicalWriteSafetyGate(traversedMissing, scriptsDir, linked),
      /symlinked write target escapes/,
    );
    assert.doesNotThrow(
      () => checkCanonicalWriteSafetyGate(outsideFile, scriptsDir, linked),
      "an explicit sanctioned outside-Git path should retain its existing allowance",
    );
  } finally {
    if (previousWorkspace === undefined) {
      delete process.env.AIDEVOPS_GIT_WORKSPACE_ROOT;
    } else {
      process.env.AIDEVOPS_GIT_WORKSPACE_ROOT = previousWorkspace;
    }
    rmSync(root, { recursive: true, force: true });
    rmSync(outsideRoot, { recursive: true, force: true });
    rmSync(escapedOutsideFile, { force: true });
  }
});

test("blocks canonical branch mutation before execution", () => {
  const { root, repo } = setupRepo();
  try {
    assert.throws(
      () => checkCommandSafetyGate("git branch -m main safety/example", scriptsDir, repo),
      /canonical worktree mutation/,
    );
    assert.equal(execFileSync(realGit, ["symbolic-ref", "--short", "HEAD"], { cwd: repo, encoding: "utf8" }).trim(), "main");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("allows read-only canonical commands, linked-worktree mutation, and unmanaged repositories", () => {
  const { root, repo, linked } = setupRepo();
  const { root: unmanagedRoot, repo: unmanagedRepo } = setupRepo({ managed: false });
  try {
    assert.doesNotThrow(() => checkCommandSafetyGate("git status --short", scriptsDir, repo));
    assert.doesNotThrow(() => checkCommandSafetyGate("git switch -c feature/child", scriptsDir, linked));
    assert.doesNotThrow(() => checkCommandSafetyGate("git branch -m main external/example", scriptsDir, unmanagedRepo));
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(unmanagedRoot, { recursive: true, force: true });
  }
});

test("allows the repository full-loop commit-and-pr wrapper only from a linked worktree", () => {
  const { root, repo, linked } = setupRepo();
  const wrapperCommand = "PR_NUMBER=$(full-loop-helper.sh commit-and-pr --issue 123 --testing 'git tests pass')";
  const activeScriptsDir = join(root, "active", "agents", "scripts");
  try {
    mkdirSync(join(repo, ".agents", "scripts"), { recursive: true });
    writeFileSync(join(repo, ".agents", "scripts", "full-loop-helper.sh"), "#!/bin/sh\n");
    assert.throws(
      () => checkCanonicalGitSafetyGate(wrapperCommand, scriptsDir, repo),
      /canonical worktree mutation/,
    );

    mkdirSync(join(linked, ".agents", "scripts"), { recursive: true });
    writeFileSync(join(linked, ".agents", "scripts", "full-loop-helper.sh"), "#!/bin/sh\n");
    mkdirSync(dirname(activeScriptsDir), { recursive: true });
    symlinkSync(scriptsDir, activeScriptsDir, "dir");
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(wrapperCommand, scriptsDir, linked));
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
      "./.agents/scripts/full-loop-helper.sh commit-and-pr --issue 123 --testing 'git tests pass'",
      scriptsDir,
      linked,
    ));
    const repositoryWrapper = join(linked, ".agents", "scripts", "full-loop-helper.sh");
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
      `${repositoryWrapper} commit-and-pr --issue 123`,
      scriptsDir,
      linked,
    ));
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        `${join(repo, ".agents", "scripts", "full-loop-helper.sh")} commit-and-pr --issue 123`,
        scriptsDir,
        repo,
      ),
      /canonical worktree mutation/,
    );
    const activeWrapper = join(activeScriptsDir, "full-loop-helper.sh");
    const activeScriptsDirBinding = bindActiveScriptsDir(activeScriptsDir, scriptsDir);
    assert.equal(checkCanonicalGitSafetyGate(
      `PR_NUMBER=$(${activeWrapper} commit-and-pr --issue 123 --message 'fix: example')`,
      scriptsDir,
      linked,
      { activeScriptsDir },
    ), `PR_NUMBER=$(${activeWrapper} commit-and-pr --issue 123 --message 'fix: example')`);
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        `${activeWrapper} commit-and-pr --issue 123`,
        scriptsDir,
        repo,
        { activeScriptsDir },
      ),
      /canonical worktree mutation/,
    );
    assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
      `${join(scriptsDir, "full-loop-helper.sh")} commit-and-pr --issue 123 --testing 'git tests pass'`,
      scriptsDir,
      linked,
    ));
    const homeRelativeScripts = scriptsDir.startsWith(`${process.env.HOME}/`)
      ? `~/${scriptsDir.slice(process.env.HOME.length + 1)}`
      : null;
    if (homeRelativeScripts) {
      assert.doesNotThrow(() => checkCanonicalGitSafetyGate(
        `${homeRelativeScripts}/full-loop-helper.sh commit-and-pr --issue 123`,
        scriptsDir,
        linked,
      ));
    }

    const rotatedScriptsDir = join(root, "rotated", "agents", "scripts");
    mkdirSync(rotatedScriptsDir, { recursive: true });
    writeFileSync(join(rotatedScriptsDir, "full-loop-helper.sh"), "#!/bin/sh\n");
    rmSync(activeScriptsDir);
    symlinkSync(rotatedScriptsDir, activeScriptsDir, "dir");
    const rotatedCommand = `PR_NUMBER=$(${activeWrapper} commit-and-pr --issue 123 --message 'fix: example')`;
    assert.equal(
      checkCanonicalGitSafetyGate(rotatedCommand, scriptsDir, linked, {
        activeScriptsDir,
        activeScriptsDirBinding,
      }),
      `PR_NUMBER=$('${join(scriptsDir, "full-loop-helper.sh")}' commit-and-pr --issue 123 --message 'fix: example')`,
    );
    assert.throws(
      () => checkCanonicalGitSafetyGate(rotatedCommand, scriptsDir, repo, {
        activeScriptsDir,
        activeScriptsDirBinding,
      }),
      /canonical worktree mutation/,
    );
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        `${join(rotatedScriptsDir, "full-loop-helper.sh")} commit-and-pr --issue 123`,
        scriptsDir,
        linked,
        { activeScriptsDir },
      ),
      /unclassified nested Git invocation/,
    );
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        `${activeWrapper} commit-and-pr --issue 123 && ${join(rotatedScriptsDir, "full-loop-helper.sh")} commit-and-pr --issue 123`,
        scriptsDir,
        linked,
        { activeScriptsDir, activeScriptsDirBinding },
      ),
      /unclassified nested Git invocation/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("does not trust similarly named full-loop wrappers", () => {
  const { root, linked } = setupRepo();
  try {
    assert.throws(
      () => checkCanonicalGitSafetyGate("./tmp/full-loop-helper.sh commit-and-pr --testing 'git tests pass'", scriptsDir, linked),
      /unclassified nested Git invocation/,
    );
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        "$HOME/.aidevops/agents/scripts/full-loop-helper.sh commit-and-pr --issue 123",
        scriptsDir,
        linked,
      ),
      /unclassified nested Git invocation/,
    );
    const unrelatedScripts = join(root, "unrelated", "scripts");
    mkdirSync(unrelatedScripts, { recursive: true });
    writeFileSync(join(unrelatedScripts, "full-loop-helper.sh"), "#!/bin/sh\n");
    assert.throws(
      () => checkCanonicalGitSafetyGate(
        `${join(unrelatedScripts, "full-loop-helper.sh")} commit-and-pr --issue 123`,
        scriptsDir,
        linked,
        { activeScriptsDir: unrelatedScripts },
      ),
      /unclassified nested Git invocation/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed when policy engine is missing", () => {
  assert.throws(
    () => checkCommandSafetyGate("printf safe", "/missing/aidevops/scripts", process.cwd()),
    /policy helper is missing/,
  );
});

test("blocks generic destructive commands through shared policy", () => {
  assert.throws(
    () => checkCommandSafetyGate("rm -rf ./build-output", scriptsDir, process.cwd()),
    /forbid, filesystem\.rm-recursive-force/,
  );
});

test("blocks direct pull request merge outside lifecycle helpers", () => {
  const cwd = process.cwd();
  for (const command of [
    "gh pr merge 123 --repo owner/repo --squash",
    "/usr/local/bin/gh pr merge 123 --repo owner/repo --admin --squash",
    "gh --repo owner/repo pr merge 123 --squash",
    "gh pr --repo owner/repo merge 123 --squash",
    "env GH_PAGER=cat gh pr merge 123 --repo owner/repo --auto --squash",
    "gh pr view 123 --repo owner/repo && gh pr merge 123 --repo owner/repo --squash",
  ]) {
    assert.throws(
      () => checkCommandSafetyGate(command, scriptsDir, cwd),
      /github\.pr-merge-direct.*full-loop-helper\.sh merge/,
    );
  }
  for (const command of [
    "gh pr merge 123 --repo owner/repo --disable-auto",
    "gh pr merge 123 --repo owner/repo --disable-auto=true",
  ]) {
    assert.throws(
      () => checkCommandSafetyGate(command, scriptsDir, cwd),
      /github\.pr-disable-auto-direct.*Do not substitute full-loop-helper\.sh merge/,
    );
  }
  assert.doesNotThrow(() => checkCommandSafetyGate(
    "full-loop-helper.sh merge 123 owner/repo --squash",
    scriptsDir,
    cwd,
  ));
  assert.doesNotThrow(() => checkCommandSafetyGate("gh pr checks 123 --repo owner/repo", scriptsDir, cwd));
  assert.doesNotThrow(() => checkCommandSafetyGate("gh pr merge --help", scriptsDir, cwd));
  assert.doesNotThrow(() => checkCommandSafetyGate("gh pr merge 123 --help", scriptsDir, cwd));
  assert.doesNotThrow(() => checkCommandSafetyGate(
    "printf '%s' 'gh pr merge 123 --repo owner/repo --squash'",
    scriptsDir,
    cwd,
  ));
});

test("refreshes approval state before privileged approval commands", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-approval-policy-"));
  const approvalHelper = join(root, "approval-helper.sh");
  const command = "sudo aidevops approve issue 30700 owner/repo";
  try {
    writeFileSync(
      approvalHelper,
      "#!/usr/bin/env bash\nprintf 'NO_APPROVAL\\n'\nexit 1\n",
    );
    chmodSync(approvalHelper, 0o755);
    assert.doesNotThrow(() => checkCommandSafetyGate(
      command,
      scriptsDir,
      process.cwd(),
      { approvalHelper },
    ));

    writeFileSync(
      approvalHelper,
      "#!/usr/bin/env bash\nprintf 'VERIFIED\\n'\nexit 0\n",
    );
    assert.throws(
      () => checkCommandSafetyGate(
        command,
        scriptsDir,
        process.cwd(),
        { approvalHelper },
      ),
      /approval\.already-verified.*skip sudo and continue/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("blocks current runtime termination while allowing a detached sandbox group", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-process-termination-"));
  const fixture = join(root, "processes.json");
  writeFileSync(fixture, JSON.stringify({
    processes: [
      { pid: 1, ppid: 0, pgid: 1, start: "init-a", comm: "launchd", args: "launchd" },
      { pid: 100, ppid: 1, pgid: 100, start: "terminal-a", comm: "terminal", args: "terminal" },
      { pid: 200, ppid: 100, pgid: 100, start: "runtime-a", comm: "opencode", args: "opencode serve" },
      { pid: 400, ppid: 200, pgid: 400, start: "child-a", comm: "sandbox-worker", args: "sandbox-worker task" },
    ],
  }));
  const options = {
    runtimePid: 200,
    runtimeProcessIdentity: "runtime-a",
    processTableFixture: fixture,
  };
  try {
    assert.throws(
      () => checkCommandSafetyGate("kill -TERM -- -100", scriptsDir, process.cwd(), options),
      /process\.runtime-self-preservation.*process group/,
    );
    assert.throws(
      () => checkCommandSafetyGate("bash -lc 'kill 200'", scriptsDir, process.cwd(), options),
      /process\.runtime-self-preservation.*runtime host/,
    );
    assert.doesNotThrow(
      () => checkCommandSafetyGate("kill -TERM -- -400", scriptsDir, process.cwd(), options),
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("blocks account mutations unless inherited authorization matches exactly", () => {
  const cwd = process.cwd();
  const helper = join(scriptsDir, "command-policy-helper.py");
  const command = "gh repo fork owner/source --clone=false";
  const previousAuthorization = process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION;
  const previousWorkspaceRoot = process.env.AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT;
  try {
    process.env.AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT = "";
    const authorization = execFileSync(
      "python3",
      [helper, "authorization-digest", "--cwd", cwd, "--command", command],
      { encoding: "utf8" },
    ).trim();
    delete process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION;
    assert.throws(
      () => checkCommandSafetyGate(command, scriptsDir, cwd),
      /github\.account-mutation/,
    );
    assert.throws(
      () => checkCommandSafetyGate(
        "bash -lc 'gh repo fork owner/source --clone=false'",
        scriptsDir,
        cwd,
      ),
      /github\.account-mutation/,
    );
    assert.doesNotThrow(() => checkCommandSafetyGate("gh repo view owner/source", scriptsDir, cwd));

    process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION = authorization;
    assert.doesNotThrow(() => checkCommandSafetyGate(command, scriptsDir, cwd));
    assert.throws(
      () => checkCommandSafetyGate(
        "sudo -n gh repo fork owner/source --clone=false",
        scriptsDir,
        cwd,
      ),
      /github\.account-mutation/,
    );
    assert.throws(
      () => checkCommandSafetyGate("gh repo fork owner/different --clone=false", scriptsDir, cwd),
      /github\.account-mutation/,
    );
    assert.throws(
      () => checkCommandSafetyGate("gh repo create owner/new-repo --public", scriptsDir, cwd),
      /github\.account-mutation/,
    );
  } finally {
    if (previousAuthorization === undefined) {
      delete process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION;
    } else {
      process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION = previousAuthorization;
    }
    if (previousWorkspaceRoot === undefined) {
      delete process.env.AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT;
    } else {
      process.env.AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT = previousWorkspaceRoot;
    }
  }
});

test("scopes remote-only account mutation authorization to the projects workspace", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-account-workspace-"));
  const workspace = join(root, "projects");
  const repoA = join(workspace, "repo-a");
  const repoB = join(workspace, "repo-b");
  const outside = join(root, "outside");
  const escape = join(workspace, "escape");
  const helper = join(scriptsDir, "command-policy-helper.py");
  const command = "gh repo fork owner/source --clone=false";
  const previousAuthorization = process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION;
  const previousWorkspaceRoot = process.env.AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT;
  mkdirSync(repoA, { recursive: true });
  mkdirSync(repoB, { recursive: true });
  mkdirSync(outside, { recursive: true });
  symlinkSync(outside, escape);
  try {
    process.env.AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT = workspace;
    const authorization = execFileSync(
      "python3",
      [helper, "authorization-digest", "--cwd", repoA, "--command", command],
      { encoding: "utf8" },
    ).trim();
    process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION = authorization;
    assert.doesNotThrow(() => checkCommandSafetyGate(command, scriptsDir, repoB));
    assert.throws(
      () => checkCommandSafetyGate(command, scriptsDir, outside),
      /github\.account-mutation/,
    );
    assert.throws(
      () => checkCommandSafetyGate(command, scriptsDir, escape),
      /github\.account-mutation/,
    );

    const localCommand = "gh repo fork owner/source";
    process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION = execFileSync(
      "python3",
      [helper, "authorization-digest", "--cwd", repoA, "--command", localCommand],
      { encoding: "utf8" },
    ).trim();
    assert.doesNotThrow(() => checkCommandSafetyGate(localCommand, scriptsDir, repoA));
    assert.throws(
      () => checkCommandSafetyGate(localCommand, scriptsDir, repoB),
      /github\.account-mutation/,
    );
  } finally {
    if (previousAuthorization === undefined) {
      delete process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION;
    } else {
      process.env.AIDEVOPS_ACCOUNT_MUTATION_AUTHORIZATION = previousAuthorization;
    }
    if (previousWorkspaceRoot === undefined) {
      delete process.env.AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT;
    } else {
      process.env.AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT = previousWorkspaceRoot;
    }
    rmSync(root, { recursive: true, force: true });
  }
});

test("rejects ambiguous shell syntax before execution", () => {
  assert.throws(
    () => checkCommandSafetyGate("printf one\nprintf two", scriptsDir, process.cwd()),
    /command\.parse-error.*multiline/,
  );
  assert.throws(
    () => checkCommandSafetyGate("curl https:\/\/\$\(printf example\.com\)", scriptsDir, process.cwd()),
    /command\.parse-error.*dynamic shell expansion/,
  );
});

test("authorizes documented canonical recovery commands without dynamic expansion", () => {
  assert.doesNotThrow(() => checkCommandSafetyGate(
    "canonical-recovery-helper.sh fast-forward-current --repo /path/to/canonical-checkout --branch develop --issue 123 --confirm FAST_FORWARD_CANONICAL_BRANCH",
    scriptsDir,
    process.cwd(),
  ));
  assert.doesNotThrow(() => checkCommandSafetyGate(
    "canonical-recovery-helper.sh sync-mirror --repo /path/to/canonical-checkout --issue 123 --confirm SYNCHRONIZE_CANONICAL_MIRROR",
    scriptsDir,
    process.cwd(),
  ));
  assert.throws(
    () => checkCommandSafetyGate(
      "${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/canonical-recovery-helper.sh sync-mirror --repo /path/to/canonical-checkout --issue 123 --confirm SYNCHRONIZE_CANONICAL_MIRROR",
      scriptsDir,
      process.cwd(),
    ),
    /command\.parse-error.*dynamic shell expansion/,
  );
});

test("enforces network policy in OpenCode worker tool adapter", () => {
  assert.throws(
    () => checkCommandSafetyGate(
      "curl --url HTTPS://requestbin.com/collect",
      scriptsDir,
      process.cwd(),
      { worker: true, workerId: "node-test" },
    ),
    /network\.worker-policy/,
  );
  assert.doesNotThrow(() => checkCommandSafetyGate(
    "printf '%s' 'curl https://requestbin.com/collect'",
    scriptsDir,
    process.cwd(),
    { worker: true, workerId: "node-test" },
  ));
});

test("fails closed when required policy is malformed", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-command-policy-"));
  const isolatedScripts = join(root, "scripts");
  const isolatedConfigs = join(root, "configs");
  mkdirSync(isolatedScripts);
  mkdirSync(isolatedConfigs);
  try {
    copyFileSync(join(scriptsDir, "command-policy-helper.py"), join(isolatedScripts, "command-policy-helper.py"));
    for (const moduleName of readdirSync(scriptsDir).filter((name) => /^command_policy_.*\.py$/.test(name))) {
      copyFileSync(join(scriptsDir, moduleName), join(isolatedScripts, moduleName));
    }
    copyFileSync(join(scriptsDir, "canonical-git-command-guard.py"), join(isolatedScripts, "canonical-git-command-guard.py"));
    writeFileSync(join(isolatedConfigs, "command-policy.json"), "{not-json\n");
    assert.throws(
      () => checkCommandSafetyGate("printf safe", isolatedScripts, process.cwd()),
      /policy\.invalid.*malformed/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("fails closed when command policy exits nonzero with an allow payload", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-command-policy-exit-"));
  const isolatedScripts = join(root, "scripts");
  mkdirSync(isolatedScripts);
  try {
    writeFileSync(
      join(isolatedScripts, "command-policy-helper.py"),
      "import sys\nprint('{\"decision\":\"allow\"}')\nsys.exit(1)\n",
    );
    assert.throws(
      () => checkCommandSafetyGate("printf safe", isolatedScripts, process.cwd()),
      /shared command policy \(allow/,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
