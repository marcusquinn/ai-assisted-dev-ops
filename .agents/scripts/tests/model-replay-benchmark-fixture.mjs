// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const testDirectory = dirname(fileURLToPath(import.meta.url));
export const scriptDirectory = resolve(testDirectory, "..");
const benchmark = join(scriptDirectory, "brief-tier-test-helper.sh");
const temporaryParent = process.env.AIDEVOPS_TEMP_DIR
  || join(homedir(), ".aidevops", ".agent-workspace", "tmp");

const FAKE_RUNTIME = `#!/bin/sh
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
case "$AIDEVOPS_MODEL_REPLAY_EXECUTION_POSTURE:$AIDEVOPS_WORKER_EGRESS_MODE" in
  enforced:required) ;;
  trusted-local:auto) [ -z "\${AIDEVOPS_WORKER_EGRESS_BACKEND:-}" ] || exit 24 ;;
  *) exit 15 ;;
esac
[ "$tier" = "simple" ] || exit 16
[ -z "\${OPENCODE_SERVER_PASSWORD:-}" ] || exit 17
[ -z "\${AIDEVOPS_HEADLESS_VARIANT:-}\${AIDEVOPS_HEADLESS_VARIANT_SIMPLE:-}" ] || exit 18
case "$AIDEVOPS_WORKTREE_BASE_DIR" in "$AIDEVOPS_TEST_SENSITIVE_TEMP_DIR"/aidevops-model-replay.*) ;; *) exit 19 ;; esac
case "$AIDEVOPS_HEADLESS_RUNTIME_DIR" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 20 ;; esac
case "$AIDEVOPS_HEADLESS_METRICS_FILE" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 21 ;; esac
case "$AIDEVOPS_RESOURCE_METRICS_FILE" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 22 ;; esac
case "$AIDEVOPS_OAUTH_POOL_FILE" in "$AIDEVOPS_WORKTREE_BASE_DIR"/*) ;; *) exit 23 ;; esac
if [ "\${AIDEVOPS_TEST_RUNTIME_FAILURE:-}" = "1" ]; then
  printf '%s\n' 'simulated pre-provider infrastructure failure' >&2
  exit 126
fi
export MR_WORK_DIR="$work_dir" MR_SESSION_KEY="$session_key" MR_MODEL="$model" MR_VARIANT="$variant" MR_TIER="$tier"
"$AIDEVOPS_TEST_NODE" -e '
const fs = require("node:fs");
if (process.env.AIDEVOPS_TEST_NO_CHANGE !== "1") {
  fs.writeFileSync(process.env.MR_WORK_DIR + "/value.txt", "fixed\\n");
  fs.writeFileSync(process.env.MR_WORK_DIR + "/created.txt", "x".repeat(3000) + "PATCH_END_MARKER\\n");
}
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
`;

export function execute(argv, { cwd, env } = {}) {
  return spawnSync(argv[0], argv.slice(1), {
    cwd,
    env: { ...process.env, ...env },
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function required(argv, options = {}) {
  const result = execute(argv, options);
  if (result.status !== 0) {
    throw new Error(`${argv.join(" ")} failed:\n${result.stderr || result.stdout}`);
  }
  return result.stdout;
}

export function git(repository, ...args) {
  return required(["git", ...args], { cwd: repository }).trim();
}

export function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

function invoke(environment, ...args) {
  return execute([benchmark, ...args], { env: environment });
}

export function invokeRequired(environment, ...args) {
  const result = invoke(environment, ...args);
  if (result.status !== 0) {
    throw new Error(`benchmark ${args.join(" ")} failed:\n${result.stderr || result.stdout}`);
  }
  return JSON.parse(result.stdout);
}

export function expectFailure(environment, pattern, ...args) {
  const result = invoke(environment, ...args);
  assert.notEqual(result.status, 0, `expected ${args.join(" ")} to fail`);
  assert.match(`${result.stderr}${result.stdout}`, pattern);
}

export function completedPredictions(experiment) {
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

function fixturePaths(sandbox) {
  return {
    sandbox,
    repository: join(sandbox, "repository"),
    inputs: join(sandbox, "inputs"),
    corpus: join(sandbox, "corpus"),
    catalog: join(sandbox, "repositories.json"),
    candidates: join(sandbox, "candidates.json"),
    promptGuard: join(sandbox, "prompt-guard.sh"),
    fakeRuntime: join(sandbox, "fake-headless-runtime.sh"),
    runtimeMarker: join(sandbox, "runtime-called"),
    runtimeMetrics: join(sandbox, "runtime-metrics.jsonl"),
    resourceMetrics: join(sandbox, "resource-metrics.jsonl"),
    runtimeState: join(sandbox, "shared-runtime-state"),
    sharedOauthPool: join(sandbox, "shared-oauth-pool.json"),
    sensitiveTemp: join(sandbox, "sensitive-temp"),
    testHome: join(sandbox, "home"),
    fakeOpenCode: join(sandbox, "fake-opencode.sh"),
    fakeEgressBackend: join(sandbox, "fake-egress-backend.sh"),
  };
}

function initializeRepository(paths) {
  mkdirSync(paths.repository, { recursive: true, mode: 0o700 });
  mkdirSync(paths.inputs, { recursive: true, mode: 0o700 });
  mkdirSync(paths.testHome, { recursive: true, mode: 0o700 });
  git(paths.repository, "init", "--quiet");
  git(paths.repository, "config", "user.name", "Model Replay Test");
  git(paths.repository, "config", "user.email", "model-replay-test@localhost");
  writeFileSync(join(paths.repository, "value.txt"), "broken\n");
  writeFileSync(join(paths.repository, "stable.txt"), "stable\n");
  writeFileSync(join(paths.repository, ".gitattributes"), "stable.txt export-ignore\n");
  git(paths.repository, "add", "-A");
  git(paths.repository, "commit", "--quiet", "-m", "broken base");
  const baseSHA = git(paths.repository, "rev-parse", "HEAD");
  writeFileSync(join(paths.repository, "value.txt"), "fixed\n");
  writeFileSync(join(paths.inputs, "gold.patch"), `${git(paths.repository, "diff", "--binary", baseSHA)}\n`);
  git(paths.repository, "checkout", "--", "value.txt");
  writeFileSync(join(paths.repository, "future-only.txt"), "must not be replay-visible\n");
  git(paths.repository, "add", "future-only.txt");
  git(paths.repository, "commit", "--quiet", "-m", "future history");
  return baseSHA;
}

function writeCaseInputs(paths) {
  writeFileSync(join(paths.inputs, "prompt.md"), "Change value.txt so its content is fixed.\n");
  writeFileSync(
    join(paths.inputs, "prescriptive.md"),
    "Edit value.txt, replacing broken with fixed, and preserve stable.txt.\n",
  );
  const fixedCheck = "const fs=require('node:fs');process.exit(fs.readFileSync('value.txt','utf8').trim()==='fixed'?0:1)";
  const stableCheck = "const fs=require('node:fs');process.exit(fs.readFileSync('stable.txt','utf8').trim()==='stable'?0:1)";
  const cleanEnvironmentCheck = "process.exit(process.env.AIDEVOPS_TEST_SECRET_SENTINEL?1:0)";
  const filesystemBoundaryCheck = `const fs=require('node:fs');try{fs.readFileSync(${JSON.stringify(join(paths.inputs, "gold.patch"))});process.exit(1)}catch(error){process.exit(['EACCES','EPERM'].includes(error.code)?0:2)}`;
  const mutationCheck = "require('node:fs').writeFileSync('verifier-marker','isolated');process.exit(0)";
  const noMutationLeakCheck = "process.exit(require('node:fs').existsSync('verifier-marker')?1:0)";
  writeJson(join(paths.inputs, "checks.json"), {
    fail_to_pass: [{
      name: "target-value",
      argv: [process.execPath, "--input-type=commonjs", "-e", fixedCheck],
      timeout_seconds: 10,
    }],
    pass_to_pass: [
      { name: "mutation-isolated", argv: [process.execPath, "--input-type=commonjs", "-e", mutationCheck], timeout_seconds: 10 },
      { name: "no-mutation-leak", argv: [process.execPath, "--input-type=commonjs", "-e", noMutationLeakCheck], timeout_seconds: 10 },
      { name: "stable-value", argv: [process.execPath, "--input-type=commonjs", "-e", stableCheck], timeout_seconds: 10 },
      { name: "sanitized-environment", argv: [process.execPath, "--input-type=commonjs", "-e", cleanEnvironmentCheck], timeout_seconds: 10 },
      { name: "filesystem-boundary", argv: [process.execPath, "--input-type=commonjs", "-e", filesystemBoundaryCheck], timeout_seconds: 10 },
    ],
  });
  return stableCheck;
}

function writeBenchmarkConfiguration(paths) {
  writeJson(paths.catalog, {
    schema_version: "aidevops-model-replay-repositories/v1",
    repositories: { "repo-fixture": { path: paths.repository, profile: "fixture" } },
  });
  writeJson(paths.candidates, {
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
}

function writeRuntimeFixtures(paths) {
  writeFileSync(
    paths.promptGuard,
    "#!/bin/sh\ncase \"$2\" in *prescriptive.md) exit 1 ;; esac\nexit 0\n",
    { mode: 0o700 },
  );
  chmodSync(paths.promptGuard, 0o700);
  writeFileSync(paths.fakeOpenCode, "#!/bin/sh\nprintf '%s\\n' 'fixture-opencode 1.0'\n", { mode: 0o700 });
  chmodSync(paths.fakeOpenCode, 0o700);
  writeFileSync(paths.fakeEgressBackend, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
  chmodSync(paths.fakeEgressBackend, 0o700);
  writeFileSync(paths.fakeRuntime, FAKE_RUNTIME, { mode: 0o700 });
  chmodSync(paths.fakeRuntime, 0o700);
}

function fixtureEnvironment(paths) {
  return {
    HOME: paths.testHome,
    AIDEVOPS_PROMPT_GUARD_HELPER: paths.promptGuard,
    AIDEVOPS_HEADLESS_RUNTIME_HELPER: paths.fakeRuntime,
    AIDEVOPS_HEADLESS_METRICS_FILE: paths.runtimeMetrics,
    AIDEVOPS_HEADLESS_RUNTIME_DIR: paths.runtimeState,
    AIDEVOPS_OAUTH_POOL_FILE: paths.sharedOauthPool,
    AIDEVOPS_RESOURCE_METRICS_FILE: paths.resourceMetrics,
    AIDEVOPS_SENSITIVE_TEMP_DIR: paths.sensitiveTemp,
    AIDEVOPS_TEST_SECRET_SENTINEL: "must-not-reach-verification",
    AIDEVOPS_TEST_SENSITIVE_TEMP_DIR: paths.sensitiveTemp,
    AIDEVOPS_TEST_PROVIDER_MARKER: paths.runtimeMarker,
    AIDEVOPS_TEST_NODE: process.execPath,
    AIDEVOPS_HEADLESS_VARIANT: "xhigh",
    AIDEVOPS_HEADLESS_VARIANT_SIMPLE: "high",
    AIDEVOPS_WORKER_EGRESS_BACKEND: paths.fakeEgressBackend,
    OPENCODE_BIN: paths.fakeOpenCode,
    OPENCODE_SERVER_PASSWORD: "test-only-password",
  };
}

export function createReplayFixture() {
  mkdirSync(temporaryParent, { recursive: true, mode: 0o700 });
  const paths = fixturePaths(mkdtempSync(join(temporaryParent, "model-replay-test-")));
  const baseSHA = initializeRepository(paths);
  const stableCheck = writeCaseInputs(paths);
  writeBenchmarkConfiguration(paths);
  writeRuntimeFixtures(paths);
  return { ...paths, baseSHA, stableCheck, environment: fixtureEnvironment(paths) };
}
