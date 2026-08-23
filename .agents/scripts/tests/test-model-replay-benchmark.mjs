// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  completedPredictions,
  createReplayFixture,
  expectFailure,
  git,
  invokeRequired,
  scriptDirectory,
  writeJson,
} from "./model-replay-benchmark-fixture.mjs";

const fixture = createReplayFixture();
const { sandbox } = fixture;

try {
  const {
    repository,
    inputs,
    corpus,
    catalog,
    candidates,
    promptGuard,
    fakeRuntime,
    runtimeMarker,
    runtimeMetrics,
    resourceMetrics,
    runtimeState,
    sharedOauthPool,
    sensitiveTemp,
    baseSHA,
    stableCheck,
    environment,
  } = fixture;

  expectFailure(
    environment,
    /placeholder 'extract' workflow was replaced/u,
    "extract", "--repo", "owner/repository",
  );
  for (const [operation, expected] of [
    ["validate", /Legacy 'replay validate'.*Use qualify/u],
    ["qualify", /Legacy 'replay qualify'.*Use qualify/u],
    ["dry-run", /Legacy 'replay dry-run'.*Use plan, seal, then run --dry-run/u],
    ["run", /Legacy 'replay run'.*Use plan, seal, then run/u],
    ["report", /Legacy 'replay report'.*Use report/u],
  ]) {
    expectFailure(
      environment,
      expected,
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
  const deployedManifest = join(deployedRoot, "agents", ".bundle-manifest");
  const deployedCommit = "a".repeat(40);
  mkdirSync(deployedScripts, { recursive: true, mode: 0o700 });
  writeFileSync(join(deploymentRoot, ".deployed-sha"), `${deployedCommit}\n`, { mode: 0o600 });
  assert.equal(framework.frameworkCommit({
    repoRoot: deployedRoot,
    scriptDirectory: deployedScripts,
  }), "unavailable");
  writeFileSync(
    deployedManifest,
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
    deployedManifest,
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
  const noChangeExperiment = join(sandbox, "experiment-no-change");
  const noChangePlan = invokeRequired(
    environment,
    "plan", "--corpus", corpus, "--candidates", candidates,
    "--experiment", noChangeExperiment, "--experiment-id", "fixture-no-change",
    "--suite", "quick", "--stage", "primary", "--mode", "autonomous",
  );
  const noChangePredictions = join(sandbox, "predictions-no-change.json");
  writeJson(noChangePredictions, completedPredictions(noChangeExperiment));
  invokeRequired(
    environment,
    "seal", "--experiment", noChangeExperiment, "--input", noChangePredictions,
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

  for (const invalidBackend of ["", "relative/backend"]) {
    expectFailure(
      { ...environment, AIDEVOPS_WORKER_EGRESS_BACKEND: invalidBackend },
      /requires AIDEVOPS_WORKER_EGRESS_BACKEND to be an executable absolute file/u,
      "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog,
    );
  }
  assert.equal(existsSync(runtimeMarker), false);

  expectFailure(
    { ...environment, AIDEVOPS_TEST_RUNTIME_FAILURE: "1" },
    /infrastructure failed before a verified provider request.*evidence: artifacts\//u,
    "run", "--experiment", experiment, "--corpus", corpus, "--catalog", catalog,
  );
  const infrastructureArtifact = readdirSync(join(experiment, "artifacts"))
    .find((name) => name.includes(".infrastructure-") && name.endsWith(".json"));
  assert.ok(infrastructureArtifact);
  const infrastructureAttempt = JSON.parse(readFileSync(
    join(experiment, "artifacts", infrastructureArtifact),
    "utf8",
  ));
  assert.equal(infrastructureAttempt.runtime_status, 126);
  assert.equal(infrastructureAttempt.provider_request_observed, false);
  assert.equal(existsSync(join(experiment, infrastructureAttempt.log.path)), true);
  assert.equal(existsSync(runtimeMarker), false);

  const noChangeRun = invokeRequired(
    { ...environment, AIDEVOPS_TEST_NO_CHANGE: "1" },
    "run", "--experiment", noChangeExperiment, "--corpus", corpus, "--catalog", catalog,
  );
  assert.equal(noChangeRun.results[0].outcome, "fail");
  assert.equal(noChangeRun.results[0].provider_request_observed, true);
  assert.equal(noChangeRun.results[0].verification.functional_passed, false);
  assert.equal(
    readFileSync(
      join(noChangeExperiment, "artifacts", `${noChangePlan.cells[0].cell_id}.patch`),
      "utf8",
    ),
    "",
  );

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
