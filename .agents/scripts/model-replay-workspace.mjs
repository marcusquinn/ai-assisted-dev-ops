// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { randomUUID } from "node:crypto";
import {
  cpSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { join, relative, resolve, sep } from "node:path";
import { pathInside } from "./model-replay-common.mjs";
import { repositoryPathForCase } from "./model-replay-corpus.mjs";
import {
  assertVerifierSandboxAvailable,
  assertNoSymlinks,
  createCommandEnvironment,
  deleteWorkspaceEnvironment,
  execute,
  executeRequired,
  registerWorkspaceEnvironment,
  verifierSandboxCommand,
  workspaceEnvironmentRecord,
  workspaceExecutionEnvironment,
} from "./model-replay-process.mjs";

export function removeSyntheticWorkspace(ownerRoot, workspace) {
  const path = pathInside(ownerRoot, workspace);
  const control = pathInside(ownerRoot, `${workspace}.control`);
  const environment = pathInside(ownerRoot, `${workspace}.environment`);
  deleteWorkspaceEnvironment(path);
  rmSync(path, { recursive: true, force: true });
  rmSync(control, { recursive: true, force: true });
  rmSync(environment, { recursive: true, force: true });
  return 0;
}

function assertBaseCommit(loadedCase, repositoryPath, commandEnvironment) {
  const object = `${loadedCase.definition.base_sha}^{commit}`;
  const resolvedBase = executeRequired(
    ["git", "-C", repositoryPath, "rev-parse", "--verify", object],
    { env: commandEnvironment },
  );
  if (resolvedBase !== loadedCase.definition.base_sha) {
    throw new Error(`Repository did not resolve the exact base SHA for ${loadedCase.definition.case_id}`);
  }
}

function materializeBaseTree({ loadedCase, repositoryPath, control, sourceIndex, environment }) {
  const baseSHA = loadedCase.definition.base_sha;
  const baseTreeHash = executeRequired(
    ["git", "-C", repositoryPath, "rev-parse", `${baseSHA}^{tree}`],
    { env: environment },
  );
  const treeEntries = executeRequired([
    "git", "-C", repositoryPath, "ls-tree", "-r", "--full-tree",
    "--format=%(objectmode) %(path)", baseSHA,
  ], { env: environment, compact: false });
  const unsafeTreeEntry = treeEntries.split("\n").find((line) => (
    line.startsWith("120000 ") || line.startsWith("160000 ")
  ));
  if (unsafeTreeEntry) {
    throw new Error(`Base tree contains a forbidden symlink or gitlink: ${unsafeTreeEntry}`);
  }
  try {
    const indexEnvironment = { ...environment, GIT_INDEX_FILE: sourceIndex };
    executeRequired(["git", "-C", repositoryPath, "read-tree", baseSHA], {
      env: indexEnvironment,
    });
    executeRequired([
      "git", "-C", repositoryPath, "checkout-index", "--all", "--force",
      `--prefix=${control}${sep}`,
    ], { env: indexEnvironment });
  } finally {
    rmSync(sourceIndex, { force: true });
  }
  return baseTreeHash;
}

function initializeSyntheticRepository(control, environmentRoot, commandEnvironment, baseTreeHash, caseID) {
  assertNoSymlinks(control);
  executeRequired(["git", "init", "--quiet", `--template=${join(environmentRoot, "git-template")}`], {
    cwd: control,
    env: commandEnvironment,
  });
  for (const [key, value] of [
    ["user.name", "aidevops-model-replay"],
    ["user.email", "model-replay@localhost"],
    ["core.hooksPath", "/dev/null"],
  ]) {
    executeRequired(["git", "config", key, value], { cwd: control, env: commandEnvironment });
  }
  executeRequired(["git", "add", "-A"], { cwd: control, env: commandEnvironment });
  const materializedTreeHash = executeRequired(["git", "write-tree"], {
    cwd: control,
    env: commandEnvironment,
  });
  if (materializedTreeHash !== baseTreeHash) {
    throw new Error(`Synthetic base tree mismatch for case ${caseID}`);
  }
  executeRequired(["git", "commit", "--quiet", "--allow-empty", "-m", "benchmark base"], {
    cwd: control,
    env: commandEnvironment,
  });
  executeRequired(["git", "branch", "-M", "main"], { cwd: control, env: commandEnvironment });
}

function syntheticGitMetadata(target, ownerRoot) {
  const gitFile = join(target, ".git");
  const metadata = lstatSync(gitFile);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.nlink !== 1) {
    throw new Error(`Synthetic workspace has invalid Git metadata: ${target}`);
  }
  const gitFileContent = readFileSync(gitFile, "utf8");
  const gitDirectoryMatch = /^gitdir: (.+)\n?$/u.exec(gitFileContent);
  if (!gitDirectoryMatch) throw new Error(`Synthetic workspace Git link is invalid: ${target}`);
  const gitDirectoryReference = gitDirectoryMatch[1];
  const gitDirectory = realpathSync(resolve(target, gitDirectoryReference));
  pathInside(ownerRoot, gitDirectory);
  return { gitDirectory, gitDirectoryReference, gitFileContent };
}

export function createSyntheticWorkspace(loadedCase, loadedCatalog, workspace, ownerRoot) {
  const repositoryPath = repositoryPathForCase(loadedCase, loadedCatalog);
  const target = pathInside(ownerRoot, workspace);
  const control = pathInside(ownerRoot, `${target}.control`);
  const environmentRoot = pathInside(ownerRoot, `${target}.environment`);
  const sourceIndex = pathInside(ownerRoot, `${target}.source-index`);
  removeSyntheticWorkspace(ownerRoot, target);
  rmSync(sourceIndex, { force: true });
  mkdirSync(control, { recursive: true, mode: 0o700 });
  mkdirSync(environmentRoot, { recursive: true, mode: 0o700 });
  const commandEnvironment = createCommandEnvironment(environmentRoot);
  assertBaseCommit(loadedCase, repositoryPath, commandEnvironment);
  const baseTreeHash = materializeBaseTree({
    loadedCase,
    repositoryPath,
    control,
    sourceIndex,
    environment: commandEnvironment,
  });
  initializeSyntheticRepository(
    control,
    environmentRoot,
    commandEnvironment,
    baseTreeHash,
    loadedCase.definition.case_id,
  );
  executeRequired([
    "git", "worktree", "add", "--quiet", "-b", "replay-benchmark", target, "HEAD",
  ], { cwd: control, env: commandEnvironment });
  assertNoSymlinks(target);
  const gitMetadata = syntheticGitMetadata(target, ownerRoot);
  registerWorkspaceEnvironment(target, {
    environmentRoot,
    environment: commandEnvironment,
    ...gitMetadata,
    ownerRoot: realpathSync(ownerRoot),
  });
  const syntheticCommit = executeRequired(["git", "rev-parse", "HEAD"], {
    cwd: target,
    env: commandEnvironment,
  });
  return { workspace: target, baseTreeHash, syntheticCommit };
}

function runCheck(check, cwd) {
  assertNoSymlinks(cwd);
  workspaceExecutionEnvironment(cwd);
  const source = realpathSync(cwd);
  const record = workspaceEnvironmentRecord(source);
  const verificationWorkspace = pathInside(
    record.ownerRoot,
    `${source}.verification-${randomUUID()}`,
  );
  const verificationEnvironment = pathInside(
    record.ownerRoot,
    `${verificationWorkspace}.environment`,
  );
  cpSync(source, verificationWorkspace, {
    recursive: true,
    filter: (path) => {
      const child = relative(source, path);
      return child !== ".git" && !child.startsWith(`.git${sep}`);
    },
  });
  mkdirSync(verificationEnvironment, { recursive: true, mode: 0o700 });
  const environment = createCommandEnvironment(verificationEnvironment);
  let result;
  try {
    result = execute(
      verifierSandboxCommand(check.argv, verificationWorkspace, verificationEnvironment),
      {
        cwd: verificationWorkspace,
        env: environment,
        timeoutMs: Number(check.timeout_seconds ?? 120) * 1000,
      },
    );
    assertNoSymlinks(verificationWorkspace);
  } finally {
    rmSync(verificationWorkspace, { recursive: true, force: true });
    rmSync(verificationEnvironment, { recursive: true, force: true });
  }
  return {
    name: check.name,
    status: result.status,
    signal: result.signal,
    timed_out: result.timedOut,
    duration_ms: result.durationMs,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

export function runCheckSet(checks, cwd) {
  assertVerifierSandboxAvailable();
  return checks.map((check) => runCheck(check, cwd));
}

export function allPassed(results) {
  return results.every((result) => result.status === 0 && !result.timed_out);
}

function failedCleanly(result) {
  if (!Number.isInteger(result.status)) return false;
  if (result.status === 0) return false;
  if (result.signal) return false;
  if (result.timed_out) return false;
  return !result.error;
}

export function allFailedCleanly(results) {
  return results.every(failedCleanly);
}

export function gradeWorkspace(loadedCase, workspace) {
  assertNoSymlinks(workspace);
  const failResults = runCheckSet(loadedCase.definition.checks.fail_to_pass, workspace);
  const passResults = runCheckSet(loadedCase.definition.checks.pass_to_pass, workspace);
  const failToPassPassed = allPassed(failResults);
  const passToPassPassed = allPassed(passResults);
  return {
    fail_to_pass: failResults,
    pass_to_pass: passResults,
    fail_to_pass_passed: failToPassPassed,
    pass_to_pass_passed: passToPassPassed,
    functional_passed: failToPassPassed && passToPassPassed,
  };
}
