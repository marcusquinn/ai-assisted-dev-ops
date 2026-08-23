// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { rmSync } from "node:fs";
import { join } from "node:path";
import {
  appendJsonLine,
  createSyntheticWorkspace,
  loadCatalog,
  removeSyntheticWorkspace,
  verifyQualification,
  writeJson,
} from "./model-replay-core.mjs";
import { executeCell } from "./model-replay-cell.mjs";
import { validateRuntimeContract, resolveExperimentDirectory } from "./model-replay-framework.mjs";
import {
  loadExperimentCandidates,
  loadVerifiedPlan,
  verifyPlannedCases,
} from "./model-replay-plan.mjs";
import { loadSealedPredictions } from "./model-replay-predictions.mjs";
import { createReport, reportHash } from "./model-replay-report.mjs";
import { acquireRunLock, validatedResultRecords } from "./model-replay-results.mjs";
import {
  assertModelReplayEgressConfigured,
  createRuntimeWorkRoot,
} from "./model-replay-runtime.mjs";

function pendingCells(plan, results) {
  const completed = new Set(results.map((record) => record.cell_id));
  return plan.cells.filter((cell) => !completed.has(cell.cell_id));
}

function verifyDryRunSources(plan, corpusDir, catalog) {
  const sourceRoot = createRuntimeWorkRoot({ cell_id: "dry-run-source-check" });
  try {
    for (const plannedCase of plan.cases) {
      const workspace = join(sourceRoot, `source-${plannedCase.case_id}`);
      try {
        const verified = verifyQualification(corpusDir, plannedCase.case_id);
        const synthetic = createSyntheticWorkspace(
          verified.loadedCase,
          catalog,
          workspace,
          sourceRoot,
        );
        if (synthetic.baseTreeHash !== verified.qualification.base_tree_sha) {
          throw new Error(`Dry-run source tree changed for case ${plannedCase.case_id}`);
        }
      } finally {
        removeSyntheticWorkspace(sourceRoot, workspace);
      }
    }
  } finally {
    rmSync(sourceRoot, { recursive: true, force: true });
  }
}

function createDryRunRecord({ experimentDir, plan, sealed, pending }) {
  createReport({ experimentDir });
  return {
    schema_version: "aidevops-model-replay-dry-run/v1",
    experiment_id: plan.experiment_id,
    plan_sha256: plan.plan_sha256,
    prediction_seal_sha256: sealed.seal_sha256,
    pending_cells: pending.map((cell) => ({
      cell_id: cell.cell_id,
      case_id: cell.case_id,
      model: cell.model,
      requested_effort: cell.requested_effort,
      mode: plan.mode,
    })),
    provider_calls_made: 0,
    created_at: sealed.sealed_at,
    report_sha256: reportHash(experimentDir),
  };
}

function executePendingCells({ cells, plan, sealed, corpusDir, catalog, experimentDir, candidates }) {
  const results = [];
  for (const cell of cells) {
    const result = executeCell({
      cell,
      plan,
      sealed,
      corpusDir,
      catalog,
      experimentDir,
      candidates,
    });
    appendJsonLine(join(experimentDir, "results.jsonl"), result);
    results.push(result);
  }
  return results;
}

export function runExperiment({ experimentDir, corpusDir, catalogPath, dryRun = false }) {
  experimentDir = resolveExperimentDirectory(experimentDir);
  const plan = loadVerifiedPlan(experimentDir);
  const sealed = loadSealedPredictions(experimentDir, plan);
  const candidates = loadExperimentCandidates(experimentDir, plan);
  validateRuntimeContract(plan, candidates);
  verifyPlannedCases(plan, corpusDir);
  const releaseLock = acquireRunLock(experimentDir);
  try {
    const existingResults = validatedResultRecords(experimentDir, plan, sealed);
    const initialPending = pendingCells(plan, existingResults);
    const catalog = loadCatalog(catalogPath);
    if (dryRun) {
      verifyDryRunSources(plan, corpusDir, catalog);
      const record = createDryRunRecord({
        experimentDir,
        plan,
        sealed,
        pending: initialPending,
      });
      writeJson(join(experimentDir, "dry-run.json"), record);
      return record;
    }
    const lockedResults = validatedResultRecords(experimentDir, plan, sealed);
    const executableCells = pendingCells(plan, lockedResults);
    if (executableCells.length > 0) assertModelReplayEgressConfigured();
    const results = executePendingCells({
      cells: executableCells,
      plan,
      sealed,
      corpusDir,
      catalog,
      experimentDir,
      candidates,
    });
    return { experiment_id: plan.experiment_id, results };
  } finally {
    releaseLock();
  }
}
