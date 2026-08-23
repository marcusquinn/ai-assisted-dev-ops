// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

function configurationKey(result) {
  return `${result.model}@${result.requested_effort}`;
}

export function configurationStats(results) {
  const groups = new Map();
  for (const result of results) {
    const key = configurationKey(result);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(result);
  }
  return [...groups.entries()].map(([configuration, records]) => {
    const passes = records.filter((record) => record.outcome === "pass").length;
    const functional = records.filter((record) => record.functional_passed).length;
    const knownCosts = records.filter((record) => Number.isFinite(record.cost_usd));
    const totalCost = knownCosts.reduce((sum, record) => sum + record.cost_usd, 0);
    const totalTime = records.reduce((sum, record) => sum + Number(record.duration_seconds || 0), 0);
    const allCostsKnown = knownCosts.length === records.length;
    return {
      configuration,
      attempts: records.length,
      completed_passes: passes,
      completed_pass_rate: records.length ? passes / records.length : 0,
      functional_passes: functional,
      functional_pass_rate: records.length ? functional / records.length : 0,
      cost_usd: allCostsKnown ? totalCost : null,
      cost_per_verified_success: passes && allCostsKnown ? totalCost / passes : null,
      duration_seconds: totalTime,
      seconds_per_verified_success: passes ? totalTime / passes : null,
      unknown_effect_cells: records.filter((record) => record.effective_effort === "unknown").length,
      unknown_cost_cells: records.length - knownCosts.length,
    };
  }).sort((left, right) => right.completed_pass_rate - left.completed_pass_rate
    || (left.cost_per_verified_success ?? Infinity) - (right.cost_per_verified_success ?? Infinity));
}

function groupedResults(results) {
  const groups = new Map();
  for (const result of results) {
    const configuration = configurationKey(result);
    if (!groups.has(configuration)) groups.set(configuration, new Map());
    groups.get(configuration).set(`${result.case_id}:${result.repeat}`, result);
  }
  return groups;
}

function comparisonCounts(shared, leftResults, rightResults) {
  const counts = { leftWins: 0, rightWins: 0, bothPass: 0, bothFail: 0 };
  for (const key of shared) {
    const leftPassed = leftResults.get(key).outcome === "pass";
    const rightPassed = rightResults.get(key).outcome === "pass";
    if (leftPassed && !rightPassed) counts.leftWins += 1;
    else if (!leftPassed && rightPassed) counts.rightWins += 1;
    else if (leftPassed) counts.bothPass += 1;
    else counts.bothFail += 1;
  }
  return counts;
}

function compareConfigurations(left, right, groups) {
  const leftResults = groups.get(left);
  const rightResults = groups.get(right);
  const shared = [...leftResults.keys()].filter((key) => rightResults.has(key));
  const counts = comparisonCounts(shared, leftResults, rightResults);
  return {
    left,
    right,
    shared_cells: shared.length,
    left_wins: counts.leftWins,
    right_wins: counts.rightWins,
    both_pass: counts.bothPass,
    both_fail: counts.bothFail,
    separated_cells: counts.leftWins + counts.rightWins,
  };
}

export function pairwiseSeparation(results) {
  const groups = groupedResults(results);
  const configurations = [...groups.keys()].sort();
  const rows = [];
  for (let leftIndex = 0; leftIndex < configurations.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < configurations.length; rightIndex += 1) {
      rows.push(compareConfigurations(
        configurations[leftIndex],
        configurations[rightIndex],
        groups,
      ));
    }
  }
  return rows;
}

function comparisonFor(configuration, comparison) {
  if (comparison.left === configuration) {
    return { wins: comparison.left_wins, losses: comparison.right_wins };
  }
  if (comparison.right === configuration) {
    return { wins: comparison.right_wins, losses: comparison.left_wins };
  }
  return null;
}

function dominatesPairwise(configuration, pairwise) {
  let hasWin = false;
  for (const comparison of pairwise) {
    const outcome = comparisonFor(configuration, comparison);
    if (!outcome) continue;
    if (outcome.losses > 0) return false;
    if (outcome.wins > 0) hasWin = true;
  }
  return hasWin;
}

function dominantConfiguration(configurations, pairwise) {
  const candidates = configurations.filter((configuration) => (
    configuration.completed_pass_rate === 1
  ));
  const dominant = candidates.filter((candidate) => (
    dominatesPairwise(candidate.configuration, pairwise)
  ));
  return dominant.length === 1 ? dominant[0].configuration : "";
}

function recommendation(action, reason, dominantConfiguration = "") {
  return { action, reason, dominant_configuration: dominantConfiguration };
}

function canaryRecommendation(configurations, dominant) {
  const viable = configurations.some((configuration) => configuration.completed_passes > 0);
  return viable
    ? recommendation("primary", "canary_viable", dominant)
    : recommendation("stop", "no_configuration_passed_canary");
}

function primaryRecommendation(dominant) {
  return dominant
    ? recommendation("confirm", "dominance_skips_effort_sweep", dominant)
    : recommendation("sweep", "no_unique_dominant_configuration");
}

function sweepRecommendation(configurations, dominant) {
  const viable = configurations.some((configuration) => configuration.completed_passes > 0);
  return viable
    ? recommendation("confirm", "confirm_route_changing_result", dominant)
    : recommendation("stop", "no_configuration_passed_sweep");
}

function confirmationRecommendation(plan, dominant) {
  if (plan.suite !== "quick") {
    return recommendation("complete", "full_corpus_complete", dominant);
  }
  return dominant
    ? recommendation("full", "quick_result_confirmed", dominant)
    : recommendation("stop", "confirmation_did_not_separate_routes");
}

export function budgetRecommendation(plan, configurations, pairwise, completedCells) {
  if (plan.integrity.non_fresh_cells.length > 0) {
    return recommendation("quarantine", "non_fresh_cells_excluded");
  }
  if (completedCells !== plan.cells.length) {
    return recommendation("complete-stage", "planned_cells_missing");
  }
  const dominant = dominantConfiguration(configurations, pairwise);
  const recommendations = [
    ["canary", canaryRecommendation(configurations, dominant)],
    ["primary", primaryRecommendation(dominant)],
    ["sweep", sweepRecommendation(configurations, dominant)],
    ["confirm", confirmationRecommendation(plan, dominant)],
  ];
  const selected = recommendations.find(([stage]) => stage === plan.stage);
  if (!selected) throw new Error(`Unsupported experiment stage: ${plan.stage}`);
  return selected[1];
}
