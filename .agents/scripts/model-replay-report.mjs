// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { chmodSync } from "node:fs";
import { join } from "node:path";
import {
  sha256File,
  writeJson,
  writePrivateFile,
} from "./model-replay-core.mjs";
import {
  budgetRecommendation,
  configurationStats,
  pairwiseSeparation,
} from "./model-replay-analysis.mjs";
import { predictionCalibration } from "./model-replay-calibration.mjs";
import { REPORT_SCHEMA } from "./model-replay-contracts.mjs";
import { resolveExperimentDirectory } from "./model-replay-framework.mjs";
import {
  loadExperimentCandidates,
  loadVerifiedPlan,
} from "./model-replay-plan.mjs";
import { loadSealedPredictions } from "./model-replay-predictions.mjs";
import { validatedResultRecords } from "./model-replay-results.mjs";

function configurationRows(report) {
  return report.configurations.map((row) => {
    const completed = `${row.completed_passes}/${row.attempts} (${(row.completed_pass_rate * 100).toFixed(1)}%)`;
    const functional = `${row.functional_passes}/${row.attempts} (${(row.functional_pass_rate * 100).toFixed(1)}%)`;
    const cost = row.cost_per_verified_success === null
      ? "n/a" : `$${row.cost_per_verified_success.toFixed(4)}`;
    const time = row.seconds_per_verified_success === null
      ? "n/a" : row.seconds_per_verified_success.toFixed(1);
    return `| ${row.configuration} | ${completed} | ${functional} | ${cost} | ${time} |`;
  });
}

function pairwiseRows(report) {
  return report.pairwise_separation.map((row) => (
    `| ${row.left} | ${row.right} | ${row.shared_cells} | ${row.left_wins} | ${row.right_wins} | ${row.both_pass} | ${row.both_fail} |`
  ));
}

function calibrationRows(report) {
  return report.prediction_calibration.cases.map((row) => (
    `| ${row.case_id} | ${row.profile} | ${row.predicted_tier} | ${row.observed_lowest_successful_tier} | ${row.direction} |`
  ));
}

function markdownReport(report) {
  const lines = [
    "# Model Replay Benchmark Report",
    "",
    `- Experiment: \`${report.experiment_id}\``,
    `- Suite/stage: ${report.suite} / ${report.stage}`,
    `- Replay mode: ${report.mode}`,
    `- Completed cells: ${report.integrity.completed_cells}/${report.integrity.planned_cells}`,
    "",
    "## Integrity",
    "",
    `- Missing cells: ${report.integrity.missing_cells}`,
    `- Non-fresh cells admitted by override: ${report.integrity.non_fresh_cells}`,
    `- Unknown effective effort: ${report.integrity.unknown_effect_cells}`,
    `- Unverified model identity: ${report.integrity.unverified_model_cells}`,
    `- Unknown cost: ${report.integrity.unknown_cost_cells}`,
    "",
    "## Configuration results",
    "",
    "| Configuration | Completed pass | Functional pass | Cost/success | Seconds/success |",
    "|---|---:|---:|---:|---:|",
    ...configurationRows(report),
    "",
    "## Pairwise separation",
    "",
    "| Left | Right | Shared | Left wins | Right wins | Both pass | Both fail |",
    "|---|---|---:|---:|---:|---:|---:|",
    ...pairwiseRows(report),
    "",
    "## Budget recommendation",
    "",
    `- Next action: ${report.budget_recommendation.action}`,
    `- Reason: ${report.budget_recommendation.reason}`,
    `- Dominant configuration: ${report.budget_recommendation.dominant_configuration || "none"}`,
    "",
    "## Prediction calibration",
    "",
    `- Brier score: ${report.prediction_calibration.brier_score === null ? "n/a" : report.prediction_calibration.brier_score.toFixed(4)}`,
    `- Cost MAE: ${report.prediction_calibration.cost_mae_usd === null ? "n/a" : `$${report.prediction_calibration.cost_mae_usd.toFixed(4)}`}`,
    `- Duration MAE: ${report.prediction_calibration.duration_mae_seconds === null ? "n/a" : report.prediction_calibration.duration_mae_seconds.toFixed(1)}`,
    `- Tier comparison: ${report.prediction_calibration.matched} matched, ${report.prediction_calibration.under_routed} under-routed, ${report.prediction_calibration.over_routed} over-routed.`,
    "",
    "| Case | Profile | Predicted tier | Observed lowest successful tier | Comparison |",
    "|---|---|---|---|---|",
    ...calibrationRows(report),
    "",
    "Deterministic verification is the correctness source; patch similarity and LLM judgment are excluded.",
    "",
  ];
  return lines.join("\n");
}

export function createReport({ experimentDir }) {
  experimentDir = resolveExperimentDirectory(experimentDir);
  const plan = loadVerifiedPlan(experimentDir);
  const sealed = loadSealedPredictions(experimentDir, plan);
  loadExperimentCandidates(experimentDir, plan);
  const results = validatedResultRecords(experimentDir, plan, sealed);
  const configurations = configurationStats(results);
  const pairwise = pairwiseSeparation(results);
  const report = {
    schema_version: REPORT_SCHEMA,
    experiment_id: plan.experiment_id,
    generated_at: results.map((result) => result.recorded_at).filter(Boolean).sort().at(-1)
      || sealed.sealed_at,
    suite: plan.suite,
    stage: plan.stage,
    mode: plan.mode,
    plan_sha256: plan.plan_sha256,
    prediction_seal_sha256: sealed.seal_sha256,
    integrity: {
      planned_cells: plan.cells.length,
      completed_cells: results.length,
      missing_cells: plan.cells.length - results.length,
      non_fresh_cells: plan.integrity.non_fresh_cells.length,
      contamination_override: plan.integrity.contamination_override,
      unknown_effect_cells: results.filter((result) => result.effective_effort === "unknown").length,
      unverified_model_cells: results.filter((result) => result.model_matched !== true).length,
      unknown_cost_cells: results.filter((result) => !Number.isFinite(result.cost_usd)).length,
    },
    configurations,
    pairwise_separation: pairwise,
    budget_recommendation: budgetRecommendation(plan, configurations, pairwise, results.length),
    prediction_calibration: predictionCalibration(plan, sealed, results),
  };
  writeJson(join(experimentDir, "report.json"), report);
  const markdown = markdownReport(report);
  const markdownPath = join(experimentDir, "report.md");
  writePrivateFile(markdownPath, markdown, 0o600);
  chmodSync(markdownPath, 0o600);
  return report;
}

export function reportHash(experimentDir) {
  return sha256File(join(experimentDir, "report.json"));
}
