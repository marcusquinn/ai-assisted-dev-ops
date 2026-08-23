// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { chmodSync, existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  TIERS,
  readJson,
  sha256,
  stableJson,
  writeJson,
} from "./model-replay-core.mjs";
import { PREDICTION_SCHEMA } from "./model-replay-contracts.mjs";
import { resolveExperimentDirectory } from "./model-replay-framework.mjs";
import { loadVerifiedPlan } from "./model-replay-plan.mjs";

function predictionIdentityMatches(record, cell) {
  if (!record) return false;
  const fields = ["cell_id", "case_id", "model", "requested_effort"];
  return fields.every((field) => record[field] === cell[field]);
}

function validateProbability(record, field) {
  const value = record[field];
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error(`Prediction ${field} must be between 0 and 1`);
  }
}

function validateNonNegative(record, field) {
  const value = record[field];
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`Prediction ${field} must be non-negative`);
  }
}

function validatePrediction(record, cell) {
  if (!predictionIdentityMatches(record, cell)) {
    throw new Error(`Prediction identity mismatch for cell ${cell.cell_id}`);
  }
  if (!TIERS.includes(record.predicted_tier)) throw new Error("Prediction tier is invalid");
  if (typeof record.predicted_best_effort !== "string" || !record.predicted_best_effort) {
    throw new Error("Prediction best effort is required");
  }
  ["success_probability", "confidence"].forEach((field) => {
    validateProbability(record, field);
  });
  ["predicted_cost_usd", "predicted_duration_seconds"]
    .forEach((field) => {
      validateNonNegative(record, field);
    });
  if (typeof record.predicted_failure_mode !== "string") {
    throw new Error("Prediction failure mode and rationale are required");
  }
  if (typeof record.rationale !== "string" || !record.rationale.trim()) {
    throw new Error("Prediction failure mode and rationale are required");
  }
}

function resultsExist(experimentDir) {
  const path = join(experimentDir, "results.jsonl");
  return existsSync(path) && readFileSync(path, "utf8").trim().length > 0;
}

export function sealPredictions({ experimentDir, inputPath }) {
  experimentDir = resolveExperimentDirectory(experimentDir);
  const plan = loadVerifiedPlan(experimentDir);
  if (resultsExist(experimentDir)) throw new Error("Cannot seal predictions after results exist");
  if (existsSync(join(experimentDir, "sealed-predictions.json"))) {
    throw new Error("Predictions are already sealed for this experiment");
  }
  const predictions = readJson(resolve(inputPath));
  if (!Array.isArray(predictions) || predictions.length !== plan.cells.length) {
    throw new Error("Predictions must contain exactly one record per plan cell");
  }
  const byCell = new Map(predictions.map((record) => [record.cell_id, record]));
  if (byCell.size !== plan.cells.length) throw new Error("Prediction cell IDs must be unique");
  for (const cell of plan.cells) validatePrediction(byCell.get(cell.cell_id), cell);
  const payload = {
    schema_version: PREDICTION_SCHEMA,
    experiment_id: plan.experiment_id,
    plan_sha256: plan.plan_sha256,
    sealed_at: new Date().toISOString(),
    predictions: plan.cells.map((cell) => byCell.get(cell.cell_id)),
  };
  payload.seal_sha256 = sha256(stableJson(payload));
  const output = join(experimentDir, "sealed-predictions.json");
  writeJson(output, payload, 0o400);
  chmodSync(output, 0o400);
  return payload;
}

export function loadSealedPredictions(experimentDir, plan) {
  const path = join(experimentDir, "sealed-predictions.json");
  const sealed = readJson(path);
  if (sealed.schema_version !== PREDICTION_SCHEMA || sealed.plan_sha256 !== plan.plan_sha256) {
    throw new Error("Prediction ledger does not match the experiment plan");
  }
  const expected = sealed.seal_sha256;
  const payload = { ...sealed };
  delete payload.seal_sha256;
  if (sha256(stableJson(payload)) !== expected) throw new Error("Prediction seal is invalid");
  return sealed;
}
