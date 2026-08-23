// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const testDirectory = dirname(fileURLToPath(import.meta.url));
const scriptDirectory = resolve(testDirectory, "..");
const benchmark = join(scriptDirectory, "brief-tier-test-helper.sh");
const temporaryParent = process.env.AIDEVOPS_TEMP_DIR
  || join(homedir(), ".aidevops", ".agent-workspace", "tmp");

function execute(argv, { cwd, env } = {}) {
  const result = spawnSync(argv[0], argv.slice(1), {
    cwd,
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return result;
}

function required(argv, options = {}) {
  const result = execute(argv, options);
  if (result.status !== 0) {
    throw new Error(`${argv.join(" ")} failed:\n${result.stderr || result.stdout}`);
  }
  return result.stdout;
}

function git(repository, ...args) {
  return required(["git", ...args], { cwd: repository }).trim();
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

function invoke(environment, ...args) {
  return execute([benchmark, ...args], { env: environment });
}

function invokeRequired(environment, ...args) {
  const result = invoke(environment, ...args);
  if (result.status !== 0) {
    throw new Error(`benchmark ${args.join(" ")} failed:\n${result.stderr || result.stdout}`);
  }
  return JSON.parse(result.stdout);
}

function expectFailure(environment, pattern, ...args) {
  const result = invoke(environment, ...args);
  assert.notEqual(result.status, 0, `expected ${args.join(" ")} to fail`);
  assert.match(`${result.stderr}${result.stdout}`, pattern);
}

function completedPredictions(experiment) {
  const template = JSON.parse(readFileSync(join(experiment, "prediction-template.json"), "utf8"));
  return template.map((prediction) => ({
    ...prediction,
    predicted_tier: "simple",
    predicted_best_effort: "high",
    success_probability: 0.8,
    predicted_cost_usd: 0.01,
    predicted_duration_seconds: 2,
    predicted_failure_mode: "target_not_solved",
    confidence: 0.7,
    rationale: "The fixture is a bounded one-file correction.",
  }));
}

mkdirSync(temporaryParent, { recursive: true, mode: 0o700 });
const sandbox = mkdtempSync(join(temporaryParent, "model-replay-test-"));

try {
  const repository = join(sandbox, "repository");
  const inputs = join(sandbox, "inputs");
  const corpus = join(sandbox, "corpus");
  const catalog = join(sandbox, "repositories.json");
  const candidates = join(sandbox, "candidates.json");
  const promptGuard = join(sandbox, "prompt-guard.sh");
  const fakeRuntime = join(sandbox, "fake-headless-runtime.sh");
  const fakeOpenCode = join(sandbox, "fake-opencode.sh");
  const runtimeMarker = join(sandbox, "runtime-called");
  const runtimeMetrics = join(sandbox, "runtime-metrics.jsonl");
  const resourceMetrics = join(sandbox, "resource-metrics.jsonl");
  const runtimeState = join(sandbox, "shared-runtime-state");
  const sharedOauthPool = join(sandbox, "shared-oauth-pool.json");
  const sensitiveTemp = join(sandbox, "sensitive-temp");
  const testHome = join(sandbox, "home");
  mkdirSync(repository, { recursive: true, mode: 0o700 });
  mkdirSync(inputs, { recursive: true, mode: 0o700 });
  mkdirSync(testHome, { recursive: true, mode: 0o700 });

  git(repository, "init", "--quiet");
  git(repository, "config", "user.name", "Model Replay Test");
  git(repository, "config", "user.email", "model-replay-test@localhost");
  writeFileSync(join(repository, "value.txt"), "broken\n");
  writeFileSync(join(repository, "stable.txt"), "stable\n");
  writeFileSync(join(repository, ".gitattributes"), "stable.txt export-ignore\n");
  git(repository, "add", "-A");
  git(repository, "commit", "--quiet", "-m", "broken base");
  const baseSHA = git(repository, "rev-parse", "HEAD");

  writeFileSync(join(repository, "value.txt"), "fixed\n");
  const goldPatch = git(repository, "diff", "--binary", baseSHA);
  writeFileSync(join(inputs, "gold.patch"), `${goldPatch}\n`);
  git(repository, "checkout", "--", "value.txt");
  writeFileSync(join(repository, "future-only.txt"), "must not be replay-visible\n");
  git(repository, "add", "future-only.txt");
  git(repository, "commit", "--quiet", "-m", "future history");

  writeFileSync(join(inputs, "prompt.md"), "Change value.txt so its content is fixed.\n");
  writeFileSync(
    join(inputs, "prescriptive.md"),
    "Edit value.txt, replacing broken with fixed, and preserve stable.txt.\n",
  );
  const fixedCheck = "const fs=require('node:fs');process.exit(fs.readFileSync('value.txt','utf8').trim()==='fixed'?0:1)";
  const stableCheck = "const fs=require('node:fs');process.exit(fs.readFileSync('stable.txt','utf8').trim()==='stable'?0:1)";
  const cleanEnvironmentCheck = "process.exit(process.env.AIDEVOPS_TEST_SECRET_SENTINEL?1:0)";
  const filesystemBoundaryCheck = `const fs=require('node:fs');try{fs.readFileSync(${JSON.stringify(join(inputs, "gold.patch"))});process.exit(1)}catch(error){process.exit(['EACCES','EPERM'].includes(error.code)?0:2)}`;
  const mutationCheck = "require('node:fs').writeFileSync('verifier-marker','isolated');process.exit(0)";
  const noMutationLeakCheck = "process.exit(require('node:fs').existsSync('verifier-marker')?1:0)";
  writeJson(join(inputs, "checks.json"), {
    fail_to_pass: [{
      name: "target-value",
      argv: [process.execPath, "--input-type=commonjs", "-e", fixedCheck],
      timeout_seconds: 10,
    }],
    pass_to_pass: [
      {
        name: "mutation-isolated",
        argv: [process.execPath, "--input-type=commonjs", "-e", mutationCheck],
        timeout_seconds: 10,
      },
      {
        name: "no-mutation-leak",
        argv: [process.execPath, "--input-type=commonjs", "-e", noMutationLeakCheck],
        timeout_seconds: 10,
      },
      {
        name: "stable-value",
        argv: [process.execPath, "--input-type=commonjs", "-e", stableCheck],
        timeout_seconds: 10,
      },
      {
        name: "sanitized-environment",
        argv: [process.execPath, "--input-type=commonjs", "-e", cleanEnvironmentCheck],
        timeout_seconds: 10,
      },
      {
        name: "filesystem-boundary",
        argv: [process.execPath, "--input-type=commonjs", "-e", filesystemBoundaryCheck],
        timeout_seconds: 10,
      },
    ],
  });
  writeJson(catalog, {
    schema_version: "aidevops-model-replay-repositories/v1",
    repositories: { "repo-fixture": { path: repository, profile: "fixture" } },
  });
  writeJson(candidates, {
    schema_version: "aidevops-model-replay-candidates/v1",
    allowed_providers: ["openai"],
    candidates: [{
      model: "openai/replay-fixture",
      tier: "simple",
      efforts: ["high"],
      primary_effort: "high",
      runtime: "opencode",
      timeout_seconds: 60,
    }],
  });
  writeFileSync(
    promptGuard,
    "#!/bin/sh\ncase \"$2\" in *prescriptive.md) exit 1 ;; esac\nexit 0\n",
    { mode: 0o700 },
  );
  chmodSync(promptGuard, 0o700);
  writeFileSync(fakeOpenCode, "#!/bin/sh\nprintf '%s\\n' 'fixture-opencode 1.0'\n", { mode: 0o700 });
  chmodSync(fakeOpenCode, 0o700);
  writeFileSync(fakeRuntime, `#!/bin/sh
work_dir=""
session_key=""
model=""
variant="default"
tier=""
role=""
agent=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) work_dir="$2"; shift 2 ;;
    --session-key) session_key="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --variant) variant="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    --agent) agent="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST" = "openai" ] || exit 9
[ "$role" = "model-replay" ] || exit 10
[ "$agent" = "model-replay" ] || exit 11
[ -f "$OPENCODE_CONFIG" ] || exit 12
case "$work_dir" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 13 ;; esac
[ "$AIDEVOPS_HEADLESS_SANDBOX_TIMEOUT" = "60" ] || exit 14
[ "$AIDEVOPS_WORKER_EGRESS_MODE" = "required" ] || exit 15
[ "$tier" = "simple" ] || exit 16
[ -z "\${OPENCODE_SERVER_PASSWORD:-}" ] || exit 17
[ -z "\${AIDEVOPS_HEADLESS_VARIANT:-}\${AIDEVOPS_HEADLESS_VARIANT_SIMPLE:-}" ] || exit 18
case "$AIDEVOPS_WORKTREE_BASE_DIR" in "$AIDEVOPS_TEST_SENSITIVE_TEMP_DIR"/aidevops-model-replay.*) ;; *) exit 19 ;; esac
case "$AIDEVOPS_HEADLESS_RUNTIME_DIR" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 20 ;; esac
case "$AIDEVOPS_HEADLESS_METRICS_FILE" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 21 ;; esac
case "$AIDEVOPS_RESOURCE_METRICS_FILE" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 22 ;; esac
case "$AIDEVOPS_OAUTH_POOL_FILE" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 23 ;; esac
export MR_WORK_DIR="$work_dir" MR_SESSION_KEY="$session_key" MR_MODEL="$model" MR_VARIANT="$variant" MR_TIER="$tier"
"$AIDEVOPS_TEST_NODE" -e '
const fs = require("node:fs");
fs.writeFileSync(process.env.MR_WORK_DIR + "/value.txt", "fixed\\n");
fs.writeFileSync(process.env.MR_WORK_DIR + "/created.txt", "x".repeat(3000) + "PATCH_END_MARKER\\n");
const now = Math.floor(Date.now() / 1000);
const mixedEvidence = process.env.AIDEVOPS_TEST_MIXED_EVIDENCE === "1";
const observedModel = mixedEvidence ? process.env.MR_MODEL + ",openai/replay-other" : process.env.MR_MODEL;
const observedVariant = mixedEvidence ? process.env.MR_VARIANT + ",xhigh" : process.env.MR_VARIANT;
fs.appendFileSync(process.env.AIDEVOPS_HEADLESS_METRICS_FILE, JSON.stringify({ts: now, role: "model-replay", session_key: process.env.MR_SESSION_KEY, model: process.env.MR_MODEL, provider: "openai", result: "success", exit_code: 0, duration_ms: 1250, routing_tier: process.env.MR_TIER, variant: process.env.MR_VARIANT, observed_model: observedModel, observed_variant: observedVariant, observed_request_count: mixedEvidence ? 2 : 1, observed_usage_count: 1, observed_tokens_total: 15, observed_cost_count: 0}) + "\\n");
fs.appendFileSync(process.env.AIDEVOPS_HEADLESS_METRICS_FILE, JSON.stringify({ts: now + 3600, role: "model-replay", session_key: process.env.MR_SESSION_KEY, model: "blocked/stale", provider: "blocked", result: "success", exit_code: 0, duration_ms: 1, variant: process.env.MR_VARIANT}) + "\\n");
fs.appendFileSync(process.env.AIDEVOPS_RESOURCE_METRICS_FILE, JSON.stringify({ts: now, role: "model-replay", session_key: process.env.MR_SESSION_KEY, cpu_seconds: 0.25, peak_rss_kb: 1024, peak_process_count: 2, sample_count: 1}) + "\\n");
fs.writeFileSync(process.env.AIDEVOPS_TEST_PROVIDER_MARKER, "called\\n");
const part = {type: "step-finish", providerID: "openai", modelID: "replay-fixture", variant: process.env.MR_VARIANT, tokens: {input: 10, output: 5}};
if (process.env.AIDEVOPS_TEST_OMIT_COST !== "1") part.cost = 0;
process.stdout.write(JSON.stringify({type: "step_finish", part}) + "\\n");
'
printf '%s\n' TASK_COMPLETE
exit 0
`, { mode: 0o700 });
  chmodSync(fakeRuntime, 0o700);

  const environment = {
    HOME: testHome,
    AIDEVOPS_PROMPT_GUARD_HELPER: promptGuard,
    AIDEVOPS_HEADLESS_RUNTIME_HELPER: fakeRuntime,
    AIDEVOPS_HEADLESS_METRICS_FILE: runtimeMetrics,
    AIDEVOPS_HEADLESS_RUNTIME_DIR: runtimeState,
    AIDEVOPS_OAUTH_POOL_FILE: sharedOauthPool,
    AIDEVOPS_RESOURCE_METRICS_FILE: resourceMetrics,
    AIDEVOPS_SENSITIVE_TEMP_DIR: sensitiveTemp,
    AIDEVOPS_TEST_SECRET_SENTINEL: "must-not-reach-verification",
    AIDEVOPS_TEST_SENSITIVE_TEMP_DIR: sensitiveTemp,
    AIDEVOPS_TEST_PROVIDER_MARKER: runtimeMarker,
    AIDEVOPS_TEST_NODE: process.execPath,
    AIDEVOPS_HEADLESS_VARIANT: "xhigh",
    AIDEVOPS_HEADLESS_VARIANT_SIMPLE: "high",
    OPENCODE_BIN: fakeOpenCode,
    OPENCODE_SERVER_PASSWORD: "test-only-password",
  };

  expectFailure(
    environment,
    /placeholder 'extract' workflow was replaced/u,
    "extract", "--repo", "owner/repository",
  );
  for (const [operation, replacement] of [
    ["validate", "qualify"],
    ["qualify", "qualify"],
    ["dry-run", "plan, seal, then run --dry-run"],
    ["run", "plan, seal, then run"],
    ["report", "report"],
  ]) {
    expectFailure(
      environment,
      new RegExp(`Legacy 'replay ${operation}'.*Use ${replacement}`, "u"),
      "replay", operation, "--legacy-option", "ignored",
    );
  }
  invokeRequired(
    environment,
    "init", "--corpus", corpus, "--profiles", "fixture", "--quick-size", "1",
    "--full-size", "1",
  );
  invokeRequired(
    environment,
    "add-case", "--corpus", corpus, "--case-id", "case-one", "--repo-key", "repo-fixture",
    "--profile", "fixture", "--tier", "simple", "--base-sha", baseSHA,
    "--prompt-file", join(inputs, "prompt.md"), "--gold-patch", join(inputs, "gold.patch"),
    "--checks-file", join(inputs, "checks.json"), "--prescriptive-file",
    join(inputs, "prescriptive.md"), "--visibility", "private", "--quick", "--discriminator",
  );

  expectFailure(
    { ...environment, AIDEVOPS_PROMPT_GUARD_HELPER: join(sandbox, "missing-prompt-guard") },
    /Prompt guard is unavailable/u,
    "qualify", "--corpus", corpus, "--catalog", catalog, "--repetitions", "2",
  );
  expectFailure(
    environment,
    /Prompt guard blocked archived prompt/u,
    "qualify", "--corpus", corpus, "--catalog", catalog, "--repetitions", "2",
  );
  writeFileSync(promptGuard, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
  chmodSync(promptGuard, 0o700);
  const qualification = invokeRequired(
    environment,
    "qualify", "--corpus", corpus, "--catalog", catalog, "--repetitions", "2",
  );
  assert.equal(qualification[0].status, "qualified");
  assert.equal(qualification[0].runs.length, 2);
  assert.match(qualification[0].qualification_sha256, /^[a-f0-9]{64}$/u);
  const qualificationPath = join(corpus, "cases", "case-one", "qualification.json");
  const originalQualification = readFileSync(qualificationPath, "utf8");
  const tamperedQualification = JSON.parse(originalQualification);
  tamperedQualification.qualified_at = "2020-01-01T00:00:00.000Z";
  writeJson(qualificationPath, tamperedQualification);
  expectFailure(
    environment,
    /no current successful qualification/u,
    "plan", "--corpus", corpus, "--candidates", candidates,
    "--experiment", join(sandbox, "tampered-qualification-experiment"),
    "--experiment-id", "tampered-qualification", "--suite", "quick",
  );
  writeFileSync(qualificationPath, originalQualification, { mode: 0o600 });
  expectFailure(
    environment,
    /Qualification repetitions must be 2\.\.5/u,
    "qualify", "--corpus", corpus, "--catalog", catalog, "--repetitions", "1",
  );

  const core = await import(pathToFileURL(join(scriptDirectory, "model-replay-core.mjs")).href);
  const framework = await import(
    pathToFileURL(join(scriptDirectory, "model-replay-framework.mjs")).href
  );
  const deploymentRoot = join(sandbox, "deployment");
  const bundleID = "fixture-bundle";
  const deployedRoot = join(deploymentRoot, "runtime-bundles", bundleID);
  const deployedScripts = join(deployedRoot, "agents", "scripts");
  const deployedCommit = "a".repeat(40);
  mkdirSync(deployedScripts, { recursive: true, mode: 0o700 });
  writeFileSync(join(deploymentRoot, ".deployed-sha"), `${deployedCommit}\n`, { mode: 0o600 });
  writeFileSync(
    join(deployedRoot, "agents", ".bundle-manifest"),
    `schema=1\nstatus=validated\nbundle_id=${bundleID}\ngit_sha=${deployedCommit}\n`,
    { mode: 0o600 },
  );
  assert.equal(framework.frameworkCommit({
    repoRoot: deployedRoot,
    scriptDirectory: deployedScripts,
  }), deployedCommit);
  writeFileSync(join(deploymentRoot, ".deployed-sha"), `${"b".repeat(40)}\n`, { mode: 0o600 });
  assert.equal(framework.frameworkCommit({
    repoRoot: deployedRoot,
    scriptDirectory: deployedScripts,
  }), "unavailable");
  writeFileSync(join(deploymentRoot, ".deployed-sha"), `${deployedCommit}\n`, { mode: 0o600 });
  writeFileSync(
    join(deployedRoot, "agents", ".bundle-manifest"),
    `schema=1\nstatus=validated\nbundle_id=${bundleID}\ngit_sha=${deployedCommit}\ngit_sha=${deployedCommit}\n`,
    { mode: 0o600 },
  );
  assert.equal(framework.frameworkCommit({
    repoRoot: deployedRoot,
    scriptDirectory: deployedScripts,
  }), "unavailable");
  const usage = await import(pathToFileURL(join(scriptDirectory, "model-replay-usage.mjs")).href);
  const opencodeUsage = usage.combinedUsage({}, [
    JSON.stringify({
      type: "step_finish",
      part: {
        type: "step-finish",
        tokens: { total: 17, input: 4, output: 5, cache: { read: 8, write: 0 } },
        cost: 0,
      },
    }),
    JSON.stringify({
      type: "step_finish",
      part: {
        type: "step-finish",
        tokens: { input: 2, output: 3, reasoning: 4, cache: { read: 5, write: 6 } },
        cost: 0.01,
      },
    }),
  ].join("\n"));
  assert.equal(opencodeUsage.request_count, 2);
  assert.equal(opencodeUsage.tokens_total, 37);
  assert.equal(opencodeUsage.cost_usd, 0.01);
  const syntheticRoot = join(sandbox, "synthetic");
  mkdirSync(syntheticRoot, { recursive: true, mode: 0o700 });
  const syntheticWorkspace = join(syntheticRoot, "workspace");
  const synthetic = core.createSyntheticWorkspace(
    core.loadCase(corpus, "case-one"),
    core.loadCatalog(catalog),
    syntheticWorkspace,
    syntheticRoot,
  );
  assert.equal(existsSync(join(synthetic.workspace, "future-only.txt")), false);
  assert.equal(git(synthetic.workspace, "rev-list", "--count", "HEAD"), "1");
  assert.equal(git(synthetic.workspace, "remote"), "");
  writeFileSync(join(synthetic.workspace, ".git"), `gitdir: ${join(repository, ".git")}\n`);
  assert.throws(
    () => core.workspaceExecutionEnvironment(synthetic.workspace),
    /Synthetic workspace Git metadata changed/u,
  );
  rmSync(syntheticRoot, { recursive: true, force: true });

  const badCandidates = join(sandbox, "bad-candidates.json");
  writeJson(badCandidates, {
    schema_version: "aidevops-model-replay-candidates/v1",
    allowed_providers: ["openai"],
    candidates: [{
      model: "blocked/replay-fixture",
      tier: "simple",
      efforts: ["high"],
      primary_effort: "high",
    }],
  });
  expectFailure(
    environment,
    /not in the explicit allowlist/u,
    "plan", "--corpus", corpus, "--candidates", badCandidates,
    "--experiment", join(sandbox, "bad-provider-experiment"),
    "--experiment-id", "bad-provider", "--suite", "quick",
  );
  const anthropicCandidates = join(sandbox, "anthropic-candidates.json");
  writeJson(anthropicCandidates, {
    schema_version: "aidevops-model-replay-candidates/v1",
    allowed_providers: ["anthropic"],
    candidates: [{
      model: "anthropic/claude-fixture",
      tier: "simple",
      efforts: ["high"],
      primary_effort: "high",
    }],
  });
  expectFailure(
    environment,
    /Anthropic-family/u,
    "plan", "--corpus", corpus, "--candidates", anthropicCandidates,
    "--experiment", join(sandbox, "anthropic-experiment"),
    "--experiment-id", "anthropic-provider", "--suite", "quick",
  );
  const claudeRuntimeCandidates = join(sandbox, "claude-runtime-candidates.json");
  writeJson(claudeRuntimeCandidates, {
    schema_version: "aidevops-model-replay-candidates/v1",
    allowed_providers: ["openai"],
    candidates: [{
      model: "openai/replay-fixture",
      tier: "simple",
      efforts: ["high"],
      primary_effort: "high",
      runtime: "claude",
    }],
  });
  expectFailure(
    environment,
    /runtime must be opencode for isolated replay/u,
    "plan", "--corpus", corpus, "--candidates", claudeRuntimeCandidates,
    "--experiment", join(sandbox, "claude-runtime-experiment"),
    "--experiment-id", "claude-runtime", "--suite", "quick",
  );

  const experiment = join(sandbox, "experiment-autonomous");
  const plan = invokeRequired(
    environment,
    "plan", "--corpus", corpus, "--candidates", candidates,
    "--experiment", experiment, "--experiment-id", "fixture-autonomous",
    "--suite", "quick", "--stage", "primary", "--mode", "autonomous",
  );
  assert.equal(plan.cells.length, 1);
  const predictionInput = join(sandbox, "predictions-autonomous.json");
  writeJson(predictionInput, completedPredictions(experiment));
  invokeRequired(environment, "seal", "--experiment", experiment, "--input", predictionInput);
  expectFailure(
    environment,
    /already sealed/u,
    "seal", "--experiment", experiment, "--input", predictionInput,
  );

  const originalRuntime = readFileSync(fakeRuntime, "utf8");
  writeFileSync(fakeRuntime, `${originalRuntime}\n# changed after planning\n`, { mode: 0o700 });
  expectFailure(
    environment,
    /runtime contract changed after plan creation/u,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog, "--dry-run",
  );
  writeFileSync(fakeRuntime, originalRuntime, { mode: 0o700 });
  chmodSync(fakeRuntime, 0o700);

  const dryRun = invokeRequired(
    environment,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog, "--dry-run",
  );
  assert.equal(dryRun.provider_calls_made, 0);
  assert.equal(existsSync(runtimeMarker), false);
  assert.equal(existsSync(join(experiment, "report.json")), true);
  invokeRequired(environment, "report", "--experiment", experiment);
  const firstReport = readFileSync(join(experiment, "report.json"), "utf8");
  invokeRequired(environment, "report", "--experiment", experiment);
  assert.equal(readFileSync(join(experiment, "report.json"), "utf8"), firstReport);

  invokeRequired(
    environment,
    "qualify", "--corpus", corpus, "--catalog", catalog, "--repetitions", "2",
  );
  expectFailure(
    environment,
    /changed after plan creation/u,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog, "--dry-run",
  );
  writeFileSync(qualificationPath, originalQualification, { mode: 0o600 });

  const planPath = join(experiment, "plan.json");
  const originalPlan = readFileSync(planPath, "utf8");
  const tamperedPlan = JSON.parse(originalPlan);
  tamperedPlan.mode = "prescriptive";
  writeJson(planPath, tamperedPlan);
  expectFailure(environment, /plan integrity check failed/u, "report", "--experiment", experiment);
  writeFileSync(planPath, originalPlan, { mode: 0o600 });

  const sealedPath = join(experiment, "sealed-predictions.json");
  const originalSeal = readFileSync(sealedPath, "utf8");
  const tamperedSeal = JSON.parse(originalSeal);
  tamperedSeal.predictions[0].rationale = "tampered";
  chmodSync(sealedPath, 0o600);
  writeJson(sealedPath, tamperedSeal);
  expectFailure(environment, /Prediction seal is invalid/u, "report", "--experiment", experiment);
  writeFileSync(sealedPath, originalSeal, { mode: 0o400 });
  chmodSync(sealedPath, 0o400);

  const promptPath = join(corpus, "cases", "case-one", "prompt.md");
  const originalPrompt = readFileSync(promptPath, "utf8");
  writeFileSync(promptPath, `${originalPrompt}Changed after qualification.\n`);
  expectFailure(
    environment,
    /changed after qualification/u,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog, "--dry-run",
  );
  expectFailure(
    environment,
    /changed after qualification/u,
    "plan", "--corpus", corpus, "--candidates", candidates,
    "--experiment", join(sandbox, "stale-experiment"), "--experiment-id", "stale-case",
    "--suite", "quick", "--mode", "autonomous",
  );
  writeFileSync(promptPath, originalPrompt, { mode: 0o600 });
  rmSync(promptPath);
  symlinkSync(join(inputs, "prompt.md"), promptPath);
  expectFailure(
    environment,
    /not a regular file|Unsafe symlink/u,
    "plan", "--corpus", corpus, "--candidates", candidates,
    "--experiment", join(sandbox, "symlink-experiment"), "--experiment-id", "symlink-case",
    "--suite", "quick", "--mode", "autonomous",
  );
  rmSync(promptPath);
  writeFileSync(promptPath, originalPrompt, { mode: 0o600 });

  const prescriptiveExperiment = join(sandbox, "experiment-prescriptive");
  const prescriptivePlan = invokeRequired(
    environment,
    "plan", "--corpus", corpus, "--candidates", candidates,
    "--experiment", prescriptiveExperiment, "--experiment-id", "fixture-prescriptive",
    "--suite", "quick", "--stage", "primary", "--mode", "prescriptive",
  );
  assert.notEqual(prescriptivePlan.cells[0].cell_id, plan.cells[0].cell_id);
  const prescriptivePredictions = join(sandbox, "predictions-prescriptive.json");
  writeJson(prescriptivePredictions, completedPredictions(prescriptiveExperiment));
  invokeRequired(
    environment,
    "seal", "--experiment", prescriptiveExperiment, "--input", prescriptivePredictions,
  );

  const runLock = join(experiment, "run.lock");
  writeFileSync(runLock, "fixture\n", { mode: 0o600 });
  expectFailure(
    environment,
    /active or stale run\.lock/u,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog,
  );
  rmSync(runLock);

  const futureSHA = git(repository, "rev-parse", "HEAD");
  git(repository, "replace", baseSHA, futureSHA);
  expectFailure(
    environment,
    /source tree changed after qualification/u,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog,
  );
  git(repository, "replace", "-d", baseSHA);

  const run = invokeRequired(
    environment,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog,
  );
  assert.equal(run.results.length, 1);
  assert.equal(run.results[0].outcome, "pass");
  assert.equal(run.results[0].concrete_model, "openai/replay-fixture");
  assert.equal(run.results[0].routing_tier, "simple");
  assert.equal(run.results[0].tier_matched, true);
  assert.equal(run.results[0].effective_effort, "high");
  assert.equal(run.results[0].effort_supported, true);
  assert.equal(run.results[0].provider_request_observed, true);
  assert.equal(run.results[0].resource_metric_observed, true);
  assert.equal(run.results[0].request_count, 1);
  assert.equal(run.results[0].cost_usd, 0);
  assert.equal(run.results[0].duration_seconds, 1.25);
  assert.equal(run.results[0].resources.peak_rss_kb, 1024);
  assert.match(run.results[0].result_sha256, /^[a-f0-9]{64}$/u);
  assert.equal(existsSync(runtimeMarker), true);
  assert.equal(existsSync(runtimeMetrics), false);
  assert.equal(existsSync(resourceMetrics), false);
  assert.equal(existsSync(runtimeState), false);
  assert.equal(existsSync(sharedOauthPool), false);
  assert.deepEqual(readdirSync(sensitiveTemp), []);
  const patch = readFileSync(join(experiment, "artifacts", `${plan.cells[0].cell_id}.patch`), "utf8");
  assert.equal(patch.includes("created.txt"), true);
  assert.equal(patch.includes("PATCH_END_MARKER"), true);
  assert.equal(patch.length > 3000, true);
  assert.match(run.results[0].artifacts.patch.sha256, /^[a-f0-9]{64}$/u);

  const finalReport = invokeRequired(environment, "report", "--experiment", experiment);
  assert.equal(finalReport.integrity.completed_cells, 1);
  assert.equal(finalReport.integrity.unknown_cost_cells, 0);
  assert.equal(finalReport.configurations[0].completed_pass_rate, 1);

  const patchPath = join(experiment, "artifacts", `${plan.cells[0].cell_id}.patch`);
  writeFileSync(patchPath, `${patch}tampered\n`, { mode: 0o600 });
  expectFailure(environment, /patch artifact integrity failed/u, "report", "--experiment", experiment);
  writeFileSync(patchPath, patch, { mode: 0o600 });

  const resultsPath = join(experiment, "results.jsonl");
  const originalResults = readFileSync(resultsPath, "utf8");
  const resultModule = await import(
    pathToFileURL(join(scriptDirectory, "model-replay-results.mjs")).href
  );
  const wrongTierResult = structuredClone(run.results[0]);
  wrongTierResult.routing_tier = "standard";
  wrongTierResult.tier_matched = false;
  wrongTierResult.result_sha256 = resultModule.resultDigest(wrongTierResult);
  writeFileSync(resultsPath, `${JSON.stringify(wrongTierResult)}\n`, { mode: 0o600 });
  expectFailure(
    environment,
    /Passing result lacks required evidence/u,
    "report", "--experiment", experiment,
  );
  writeFileSync(resultsPath, originalResults, { mode: 0o600 });
  const forgedResult = structuredClone(run.results[0]);
  forgedResult.functional_passed = false;
  forgedResult.verification.functional_passed = false;
  writeFileSync(resultsPath, `${JSON.stringify(forgedResult)}\n`, { mode: 0o600 });
  expectFailure(
    environment,
    /verification invariants failed/u,
    "report", "--experiment", experiment,
  );
  expectFailure(
    environment,
    /verification invariants failed/u,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog,
  );
  writeFileSync(resultsPath, originalResults, { mode: 0o600 });

  const prescriptiveResults = join(prescriptiveExperiment, "results.jsonl");
  writeFileSync(prescriptiveResults, originalResults, { mode: 0o600 });
  expectFailure(
    environment,
    /unknown cell/u,
    "report", "--experiment", prescriptiveExperiment,
  );
  rmSync(prescriptiveResults);

  const unverifiedRun = invokeRequired(
    {
      ...environment,
      AIDEVOPS_TEST_MIXED_EVIDENCE: "1",
      AIDEVOPS_TEST_OMIT_COST: "1",
    },
    "run", "--experiment", prescriptiveExperiment,
    "--corpus", corpus, "--catalog", catalog,
  );
  assert.equal(unverifiedRun.results[0].outcome, "error");
  assert.equal(unverifiedRun.results[0].concrete_model, "unknown");
  assert.equal(unverifiedRun.results[0].model_matched, false);
  assert.equal(unverifiedRun.results[0].effective_effort, "unknown");
  assert.equal(unverifiedRun.results[0].effort_supported, false);
  assert.equal(unverifiedRun.results[0].cost_usd, null);
  const unverifiedReport = invokeRequired(
    environment,
    "report", "--experiment", prescriptiveExperiment,
  );
  assert.equal(unverifiedReport.integrity.unknown_cost_cells, 1);
  assert.equal(unverifiedReport.configurations[0].cost_usd, null);
  assert.equal(unverifiedReport.configurations[0].cost_per_verified_success, null);

  const nondeterministicCorpus = join(sandbox, "nondeterministic-corpus");
  const nondeterministicChecks = join(inputs, "nondeterministic-checks.json");
  const nondeterministicScript = "const fs=require('node:fs');const value=fs.readFileSync('value.txt','utf8').trim();if(value==='fixed')process.exit(0);process.exit(process.cwd().includes('-q1-')?1:2)";
  writeJson(nondeterministicChecks, {
    fail_to_pass: [{
      name: "alternating-target",
      argv: [process.execPath, "--input-type=commonjs", "-e", nondeterministicScript],
      timeout_seconds: 10,
    }],
    pass_to_pass: [{
      name: "stable-value",
      argv: [process.execPath, "--input-type=commonjs", "-e", stableCheck],
      timeout_seconds: 10,
    }],
  });
  invokeRequired(
    environment,
    "init", "--corpus", nondeterministicCorpus, "--profiles", "fixture",
    "--quick-size", "1", "--full-size", "1",
  );
  invokeRequired(
    environment,
    "add-case", "--corpus", nondeterministicCorpus, "--case-id", "case-nondeterministic",
    "--repo-key", "repo-fixture", "--profile", "fixture", "--tier", "simple",
    "--base-sha", baseSHA, "--prompt-file", join(inputs, "prompt.md"),
    "--gold-patch", join(inputs, "gold.patch"), "--checks-file", nondeterministicChecks,
    "--visibility", "private", "--quick",
  );
  expectFailure(
    environment,
    /non_deterministic_verifier/u,
    "qualify", "--corpus", nondeterministicCorpus, "--catalog", catalog,
    "--repetitions", "2",
  );

  console.log("Model replay benchmark tests passed");
} finally {
  rmSync(sandbox, { recursive: true, force: true });
}
