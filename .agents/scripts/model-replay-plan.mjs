// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import {
  MODES,
  assertSafeID,
  loadCase,
  loadCorpus,
  readJson,
  sha256,
  stableJson,
  verifyQualification,
  writeJson,
} from "./model-replay-core.mjs";
import { contaminationFor, loadCandidates } from "./model-replay-candidates.mjs";
import { PLAN_SCHEMA } from "./model-replay-contracts.mjs";
import {
  frameworkIdentity,
  resolveExperimentDirectory,
} from "./model-replay-framework.mjs";
import {
  effortsFor,
  repeatsFor,
  selectSuiteEntries,
} from "./model-replay-suite.mjs";

export function verifyPlannedCases(plan, corpusDir) {
  for (const selectedCase of plan.cases) {
    const verified = verifyQualification(corpusDir, selectedCase.case_id);
    if (verified.qualification.case_hash !== selectedCase.case_hash
      || verified.qualification.qualification_sha256 !== selectedCase.qualification_sha256) {
      throw new Error(`Case ${selectedCase.case_id} changed after plan creation`);
    }
  }
}

function cellID(caseHash, mode, candidate, effort, repeat) {
  return sha256(`${caseHash}\0${mode}\0${candidate.model}\0${effort}\0${repeat}`).slice(0, 20);
}

export function planDigest(plan) {
  const payload = { ...plan };
  delete payload.plan_sha256;
  return sha256(stableJson(payload));
}

export function loadVerifiedPlan(experimentDir) {
  const plan = readJson(join(experimentDir, "plan.json"));
  if (plan.schema_version !== PLAN_SCHEMA || planDigest(plan) !== plan.plan_sha256) {
    throw new Error("Experiment plan integrity check failed");
  }
  return plan;
}

export function loadExperimentCandidates(experimentDir, plan) {
  const candidates = loadCandidates(join(experimentDir, "candidate-config.json"));
  if (sha256(stableJson(candidates)) !== plan.candidate_config_sha256) {
    throw new Error("Candidate configuration changed after plan creation");
  }
  return candidates;
}

export function predictionTemplate(plan) {
  return plan.cells.map((cell) => ({
    cell_id: cell.cell_id,
    case_id: cell.case_id,
    model: cell.model,
    requested_effort: cell.requested_effort,
    predicted_tier: null,
    predicted_best_effort: null,
    success_probability: null,
    predicted_cost_usd: null,
    predicted_duration_seconds: null,
    predicted_failure_mode: null,
    confidence: null,
    rationale: null,
  }));
}

function plannedCase(corpusDir, entry, mode) {
  const verified = verifyQualification(corpusDir, entry.case_id);
  if (!verified.loadedCase.definition.modes.includes(mode)) {
    throw new Error(`Case ${entry.case_id} does not support ${mode} replay`);
  }
  return {
    case_id: entry.case_id,
    profile: verified.loadedCase.definition.profile,
    expected_tier: verified.loadedCase.definition.expected_tier,
    case_hash: verified.qualification.case_hash,
    qualification_sha256: verified.qualification.qualification_sha256,
    prompt_fidelity: verified.loadedCase.definition.prompt_fidelity,
    check_names: {
      fail_to_pass: verified.loadedCase.definition.checks.fail_to_pass.map((check) => check.name),
      pass_to_pass: verified.loadedCase.definition.checks.pass_to_pass.map((check) => check.name),
    },
  };
}

function candidateCells(selectedCase, candidate, stage, mode) {
  const cells = [];
  for (const effort of effortsFor(candidate, stage)) {
    for (let repeat = 1; repeat <= repeatsFor(candidate, stage); repeat += 1) {
      cells.push({
        cell_id: cellID(selectedCase.case_hash, mode, candidate, effort, repeat),
        case_id: selectedCase.case_id,
        case_hash: selectedCase.case_hash,
        profile: selectedCase.profile,
        expected_tier: selectedCase.expected_tier,
        model: candidate.model,
        candidate_tier: candidate.tier,
        requested_effort: effort,
        repeat,
        timeout_seconds: Number(candidate.timeout_seconds ?? 3600),
        runtime: candidate.runtime || "opencode",
      });
    }
  }
  return cells;
}

function caseCandidatePlan({ selectedCase, candidate, corpusDir, stage, mode, allowContaminated }) {
  const loadedCase = loadCase(corpusDir, selectedCase.case_id);
  const exposure = contaminationFor(loadedCase.definition, candidate);
  if (exposure !== "fresh" && !allowContaminated) {
    throw new Error(
      `Case ${selectedCase.case_id} is ${exposure} for ${candidate.model}; explicit override required`,
    );
  }
  const contamination = exposure === "fresh" ? [] : [{
    case_id: selectedCase.case_id,
    model: candidate.model,
    status: exposure,
  }];
  return {
    cells: candidateCells(selectedCase, candidate, stage, mode),
    contamination,
  };
}

function buildCells({ cases, candidateConfig, corpusDir, stage, mode, allowContaminated }) {
  const cells = [];
  const contamination = [];
  for (const selectedCase of cases) {
    for (const candidate of candidateConfig.candidates) {
      const combination = caseCandidatePlan({
        selectedCase,
        candidate,
        corpusDir,
        stage,
        mode,
        allowContaminated,
      });
      cells.push(...combination.cells);
      contamination.push(...combination.contamination);
    }
  }
  return { cells, contamination };
}

function validatePlanOptions({ experimentID, suite, stage, mode }) {
  assertSafeID(experimentID, "experiment_id");
  if (!["quick", "full"].includes(suite)) throw new Error("Suite must be quick or full");
  if (!["canary", "primary", "sweep", "confirm"].includes(stage)) {
    throw new Error("Stage must be canary, primary, sweep, or confirm");
  }
  if (!MODES.includes(mode)) throw new Error("Mode must be autonomous or prescriptive");
}

function persistPlan(experimentDir, plan, candidateConfig) {
  plan.plan_sha256 = planDigest(plan);
  mkdirSync(experimentDir, { recursive: true, mode: 0o700 });
  chmodSync(experimentDir, 0o700);
  writeJson(join(experimentDir, "plan.json"), plan);
  writeJson(join(experimentDir, "prediction-template.json"), predictionTemplate(plan));
  writeJson(join(experimentDir, "candidate-config.json"), candidateConfig);
}

export function createPlan({
  corpusDir,
  candidatePath,
  experimentDir,
  experimentID,
  suite = "quick",
  stage = "primary",
  mode = "autonomous",
  allowContaminated = false,
}) {
  experimentDir = resolveExperimentDirectory(experimentDir, true);
  validatePlanOptions({ experimentID, suite, stage, mode });
  if (existsSync(join(experimentDir, "plan.json"))) {
    throw new Error("Experiment plan already exists; use a new experiment directory");
  }
  const corpus = loadCorpus(corpusDir);
  const candidateConfig = loadCandidates(candidatePath);
  const entries = selectSuiteEntries(corpus, suite, stage);
  const cases = entries.map((entry) => plannedCase(corpusDir, entry, mode));
  const planned = buildCells({
    cases,
    candidateConfig,
    corpusDir,
    stage,
    mode,
    allowContaminated,
  });
  const plan = {
    schema_version: PLAN_SCHEMA,
    experiment_id: experimentID,
    created_at: new Date().toISOString(),
    corpus_schema: corpus.manifest.schema_version,
    corpus_name: corpus.manifest.name,
    suite,
    stage,
    mode,
    framework: frameworkIdentity(candidateConfig),
    candidate_config_sha256: sha256(stableJson(candidateConfig)),
    allowed_providers: candidateConfig.allowed_providers,
    cases,
    cells: planned.cells,
    integrity: {
      contamination_override: Boolean(allowContaminated),
      non_fresh_cells: planned.contamination,
    },
  };
  persistPlan(experimentDir, plan, candidateConfig);
  return plan;
}
