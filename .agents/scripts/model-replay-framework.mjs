// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  execute,
  harnessIdentity,
  isFullCommitSHA,
  sha256,
  sha256File,
  stableJson,
} from "./model-replay-core.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "../..");
const MODEL_REPLAY_AGENT = resolve(SCRIPT_DIR, "../workflows/model-replay.md");

function detectedRuntimeVersion(runtime) {
  const executable = runtime === "claude"
    ? process.env.CLAUDE_BIN || "claude"
    : process.env.OPENCODE_BIN || "opencode";
  const result = execute([executable, "--version"], { timeoutMs: 10000 });
  return result.status === 0 ? result.stdout.trim().split("\n", 1)[0] : "unavailable";
}

function runtimeContractFileNames() {
  const helperNames = [
    "brief-tier-test-helper.sh",
    "command-policy-helper.py",
    "headless-private-output-filter.py",
    "headless-runtime-provider-classifier.py",
    "network-tier-helper.sh",
    "resource-metrics-helper.sh",
    "sandbox-exec-helper.sh",
    "sensitive-temp-helper.sh",
  ];
  const runtimeNames = readdirSync(SCRIPT_DIR)
    .filter((name) => name.startsWith("headless-runtime-") && name.endsWith(".sh"));
  const modelReplayNames = readdirSync(SCRIPT_DIR)
    .filter((name) => name.startsWith("model-replay-") && name.endsWith(".mjs"));
  return [...new Set([...helperNames, ...runtimeNames, ...modelReplayNames])].sort();
}

function runtimeContractDigest() {
  const files = runtimeContractFileNames()
    .map((name) => ({ name, path: join(SCRIPT_DIR, name) }));
  files.push({ name: "workflows/model-replay.md", path: MODEL_REPLAY_AGENT });
  const missing = files.find(({ path }) => {
    if (!existsSync(path)) return true;
    const metadata = lstatSync(path);
    return !metadata.isFile() || metadata.isSymbolicLink();
  });
  if (missing) return "unavailable";
  return sha256(stableJson(Object.fromEntries(
    files.map(({ name, path }) => [name, sha256File(path)]),
  )));
}

function regularFileContents(path) {
  if (!existsSync(path)) return null;
  const metadata = lstatSync(path);
  if (!metadata.isFile() || metadata.isSymbolicLink()) return null;
  return readFileSync(path, "utf8");
}

function uniqueManifestValue(contents, key) {
  const prefix = `${key}=`;
  const values = contents.split("\n")
    .filter((line) => line.startsWith(prefix))
    .map((line) => line.slice(prefix.length));
  return values.length === 1 ? values[0] : "";
}

function deploymentPaths(repoRoot, scriptDirectory) {
  const bundleRoot = resolve(scriptDirectory, "../..");
  const bundlesRoot = dirname(bundleRoot);
  if (basename(bundlesRoot) === "runtime-bundles") {
    return {
      bundleID: basename(bundleRoot),
      stampPath: join(dirname(bundlesRoot), ".deployed-sha"),
    };
  }
  return { bundleID: "", stampPath: join(repoRoot, ".deployed-sha") };
}

function commitFromMissingManifest(bundleID, stamp) {
  if (bundleID) return "unavailable";
  return isFullCommitSHA(stamp) ? stamp : "unavailable";
}

function manifestIsValid(manifest, bundleID, manifestCommit) {
  const checks = [
    uniqueManifestValue(manifest, "schema") === "1",
    uniqueManifestValue(manifest, "status") === "validated",
    !bundleID || uniqueManifestValue(manifest, "bundle_id") === bundleID,
    isFullCommitSHA(manifestCommit),
  ];
  return checks.every(Boolean);
}

function installedFrameworkCommit(repoRoot, scriptDirectory) {
  const manifestPath = join(scriptDirectory, "../.bundle-manifest");
  const { bundleID, stampPath } = deploymentPaths(repoRoot, scriptDirectory);
  const stampContents = regularFileContents(stampPath);
  const stamp = stampContents === null ? "" : stampContents.trim();
  if (!existsSync(manifestPath)) return commitFromMissingManifest(bundleID, stamp);
  const manifest = regularFileContents(manifestPath);
  if (manifest === null) return "unavailable";
  const manifestCommit = uniqueManifestValue(manifest, "git_sha");
  if (!manifestIsValid(manifest, bundleID, manifestCommit)
    || !isFullCommitSHA(stamp) || stamp !== manifestCommit) {
    return "unavailable";
  }
  return manifestCommit;
}

export function frameworkCommit({ repoRoot = REPO_ROOT, scriptDirectory = SCRIPT_DIR } = {}) {
  const gitEnvironment = { ...process.env };
  for (const name of Object.keys(gitEnvironment)) {
    if (name.startsWith("GIT_")) delete gitEnvironment[name];
  }
  gitEnvironment.GIT_CONFIG_GLOBAL = "/dev/null";
  gitEnvironment.GIT_CONFIG_NOSYSTEM = "1";
  gitEnvironment.GIT_TERMINAL_PROMPT = "0";
  const git = execute(["git", "rev-parse", "HEAD"], {
    cwd: repoRoot,
    env: gitEnvironment,
    timeoutMs: 10000,
  });
  const gitCommit = git.status === 0 ? git.stdout.trim() : "";
  if (isFullCommitSHA(gitCommit)) return gitCommit;
  return installedFrameworkCommit(repoRoot, scriptDirectory);
}

export function frameworkIdentity(candidateConfig) {
  const helper = process.env.AIDEVOPS_HEADLESS_RUNTIME_HELPER
    || join(SCRIPT_DIR, "headless-runtime-helper.sh");
  const runtimes = [...new Set(
    candidateConfig.candidates.map((candidate) => candidate.runtime || "opencode"),
  )];
  return {
    ...harnessIdentity(),
    commit: frameworkCommit(),
    headless_helper_sha256: existsSync(helper) ? sha256File(helper) : "unavailable",
    model_replay_agent_sha256: existsSync(MODEL_REPLAY_AGENT)
      ? sha256File(MODEL_REPLAY_AGENT) : "unavailable",
    runtime_contract_sha256: runtimeContractDigest(),
    runtime_versions: Object.fromEntries(
      runtimes.map((runtime) => [runtime, detectedRuntimeVersion(runtime)]),
    ),
  };
}

export function resolveExperimentDirectory(experimentDir, create = false) {
  const requested = resolve(experimentDir);
  if (create) mkdirSync(requested, { recursive: true, mode: 0o700 });
  if (!existsSync(requested)) {
    throw new Error(`Experiment directory must be a real local directory: ${requested}`);
  }
  const metadata = lstatSync(requested);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new Error(`Experiment directory must be a real local directory: ${requested}`);
  }
  const canonical = realpathSync(requested);
  chmodSync(canonical, 0o700);
  return canonical;
}

function frameworkIdentityIsAvailable(current) {
  const checks = [
    isFullCommitSHA(current.commit),
    current.headless_helper_sha256 !== "unavailable",
    current.model_replay_agent_sha256 !== "unavailable",
    current.runtime_contract_sha256 !== "unavailable",
    !Object.values(current.runtime_versions).includes("unavailable"),
  ];
  return checks.every(Boolean);
}

export function validateRuntimeContract(plan, candidateConfig) {
  const current = frameworkIdentity(candidateConfig);
  if (stableJson(current) !== stableJson(plan.framework)) {
    throw new Error("Framework or runtime contract changed after plan creation");
  }
  if (!frameworkIdentityIsAvailable(current)) {
    throw new Error("Framework or runtime identity is unavailable");
  }
}
