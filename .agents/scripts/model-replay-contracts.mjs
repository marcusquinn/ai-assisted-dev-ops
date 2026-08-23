// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { TIERS } from "./model-replay-core.mjs";

export const CANDIDATE_SCHEMA = "aidevops-model-replay-candidates/v1";
export const PLAN_SCHEMA = "aidevops-model-replay-plan/v1";
export const PREDICTION_SCHEMA = "aidevops-model-replay-predictions/v1";
export const RESULT_SCHEMA = "aidevops-model-replay-result/v1";
export const REPORT_SCHEMA = "aidevops-model-replay-report/v1";
export const DEFAULT_EXECUTION_POSTURE = "enforced";
export const EXECUTION_POSTURES = Object.freeze([DEFAULT_EXECUTION_POSTURE, "trusted-local"]);
export const TIER_RANK = Object.fromEntries(TIERS.map((tier, index) => [tier, index]));

export function modelReplayExecutionPosture(plan) {
  const posture = Object.hasOwn(plan, "execution_posture")
    ? plan.execution_posture
    : DEFAULT_EXECUTION_POSTURE;
  if (!EXECUTION_POSTURES.includes(posture)) {
    throw new Error(`Unsupported model replay execution posture: ${posture}`);
  }
  return posture;
}
