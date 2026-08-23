// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { TIERS } from "./model-replay-core.mjs";
import { TIER_RANK } from "./model-replay-contracts.mjs";

function mean(values) {
  return values.length ? values.reduce((sum, value) => sum + value, 0) / values.length : 0;
}

function observedCaseTiers(results) {
  const byCase = new Map();
  for (const result of results) {
    if (!byCase.has(result.case_id)) byCase.set(result.case_id, []);
    byCase.get(result.case_id).push(result);
  }
  const observed = new Map();
  for (const [caseID, records] of byCase) {
    const successful = records.filter((record) => record.outcome === "pass")
      .sort((left, right) => TIER_RANK[left.candidate_tier] - TIER_RANK[right.candidate_tier]
        || Number(left.cost_usd || 0) - Number(right.cost_usd || 0));
    observed.set(caseID, successful[0]?.candidate_tier || "unresolved");
  }
  return observed;
}

function comparedPredictions(sealed, results) {
  const predictions = new Map(sealed.predictions.map((record) => [record.cell_id, record]));
  return results.map((result) => ({
    result,
    prediction: predictions.get(result.cell_id),
  })).filter((record) => record.prediction);
}

function calibrationMetrics(compared) {
  const brier = mean(compared.map(({ result, prediction }) => {
    const observed = result.outcome === "pass" ? 1 : 0;
    return (prediction.success_probability - observed) ** 2;
  }));
  const knownCosts = compared.filter(({ result }) => Number.isFinite(result.cost_usd));
  const costMae = mean(knownCosts.map(({ result, prediction }) => (
    Math.abs(prediction.predicted_cost_usd - result.cost_usd)
  )));
  const durationMae = mean(compared.map(({ result, prediction }) => (
    Math.abs(prediction.predicted_duration_seconds - Number(result.duration_seconds || 0))
  )));
  const failed = compared.filter(({ result }) => result.outcome !== "pass");
  const failureMatches = failed.filter(({ result, prediction }) => (
    prediction.predicted_failure_mode === result.failure_class
  )).length;
  const effortMatches = compared.filter(({ result, prediction }) => (
    prediction.predicted_best_effort === result.effective_effort
  )).length;
  return { brier, knownCosts, costMae, durationMae, failed, failureMatches, effortMatches };
}

function tierDirection(predictedTier, observedTier) {
  if (observedTier === "unresolved") return "unresolved";
  if (!TIERS.includes(predictedTier)) return "unresolved";
  const delta = TIER_RANK[predictedTier] - TIER_RANK[observedTier];
  if (delta < 0) return "under-routed";
  if (delta > 0) return "over-routed";
  return "matched";
}

function caseTierComparison(selectedCase, sealed, observedTiers) {
  const predictedTiers = [...new Set(sealed.predictions
    .filter((record) => record.case_id === selectedCase.case_id)
    .map((record) => record.predicted_tier))];
  const observedTier = observedTiers.get(selectedCase.case_id) || "unresolved";
  const predictedTier = predictedTiers.length === 1 ? predictedTiers[0] : "ambiguous";
  return {
    case_id: selectedCase.case_id,
    profile: selectedCase.profile,
    predicted_tier: predictedTier,
    observed_lowest_successful_tier: observedTier,
    direction: tierDirection(predictedTier, observedTier),
  };
}

export function predictionCalibration(plan, sealed, results) {
  const compared = comparedPredictions(sealed, results);
  const metrics = calibrationMetrics(compared);
  const observedTiers = observedCaseTiers(results);
  const cases = plan.cases.map((selectedCase) => (
    caseTierComparison(selectedCase, sealed, observedTiers)
  ));
  return {
    observations: compared.length,
    brier_score: compared.length ? metrics.brier : null,
    cost_mae_usd: metrics.knownCosts.length ? metrics.costMae : null,
    duration_mae_seconds: compared.length ? metrics.durationMae : null,
    failure_mode_accuracy: metrics.failed.length
      ? metrics.failureMatches / metrics.failed.length : null,
    effective_effort_accuracy: compared.length ? metrics.effortMatches / compared.length : null,
    under_routed: cases.filter((record) => record.direction === "under-routed").length,
    over_routed: cases.filter((record) => record.direction === "over-routed").length,
    matched: cases.filter((record) => record.direction === "matched").length,
    cases,
  };
}
