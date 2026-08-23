// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  existsSync,
  lstatSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import {
  DEFAULT_EXECUTION_POSTURE,
  modelReplayExecutionPosture,
  RESULT_SCHEMA,
} from "./model-replay-contracts.mjs";
import {
  pathInside,
  sha256,
  sha256File,
  stableJson,
} from "./model-replay-core.mjs";

export function resultRecords(experimentDir) {
  const path = join(experimentDir, "results.jsonl");
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

export function resultDigest(result) {
  const payload = { ...result };
  delete payload.result_sha256;
  return sha256(stableJson(payload));
}

function checkResultPassed(result) {
  if (typeof result.name !== "string" || !result.name) return false;
  if (result.status !== 0) return false;
  if (result.signal) return false;
  return result.timed_out === false;
}

function checkSetPassed(results) {
  if (!Array.isArray(results) || results.length === 0) return false;
  return results.every(checkResultPassed);
}

function checkNamesMatch(results, expectedNames) {
  if (!Array.isArray(results) || !Array.isArray(expectedNames)) return false;
  if (results.length !== expectedNames.length) return false;
  return results.every((result, index) => result?.name === expectedNames[index]);
}

function artifactMetadataIsValid(path, expectedHash) {
  if (!existsSync(path)) return false;
  const metadata = lstatSync(path);
  if (!metadata.isFile()) return false;
  if (metadata.isSymbolicLink()) return false;
  if (metadata.nlink !== 1) return false;
  return sha256File(path) === expectedHash;
}

function validateResultArtifacts(result, cell, experimentDir) {
  const expected = {
    prompt: `artifacts/${cell.cell_id}.prompt.md`,
    log: `artifacts/${cell.cell_id}.runtime.log`,
    patch: `artifacts/${cell.cell_id}.patch`,
    metrics: `artifacts/${cell.cell_id}.metrics.json`,
  };
  for (const [name, relativePath] of Object.entries(expected)) {
    const record = result.artifacts?.[name];
    if (!record || record.path !== relativePath || !/^[0-9a-f]{64}$/.test(record.sha256 || "")) {
      throw new Error(`Result ${name} artifact identity is invalid for cell ${cell.cell_id}`);
    }
    const path = pathInside(experimentDir, join(experimentDir, relativePath));
    if (!artifactMetadataIsValid(path, record.sha256)) {
      throw new Error(`Result ${name} artifact integrity failed for cell ${cell.cell_id}`);
    }
  }
}

function resultContainmentMatches(result, plan) {
  const expectedPosture = modelReplayExecutionPosture(plan);
  if (Object.hasOwn(plan, "execution_posture")) {
    if (typeof result.execution_posture !== "string"
      || typeof result.process_tree_egress_enforced !== "boolean") return false;
  }
  const resultPosture = Object.hasOwn(result, "execution_posture")
    ? result.execution_posture
    : DEFAULT_EXECUTION_POSTURE;
  const processTreeEgressEnforced = Object.hasOwn(result, "process_tree_egress_enforced")
    ? result.process_tree_egress_enforced
    : true;
  return resultPosture === expectedPosture
    && processTreeEgressEnforced === (expectedPosture === "enforced");
}

function resultIdentityMatches(result, cell, plan, sealed) {
  const expected = {
    schema_version: RESULT_SCHEMA,
    experiment_id: plan.experiment_id,
    cell_id: cell.cell_id,
    case_id: cell.case_id,
    case_hash: cell.case_hash,
    profile: cell.profile,
    expected_tier: cell.expected_tier,
    candidate_tier: cell.candidate_tier,
    model: cell.model,
    runtime: cell.runtime,
    runtime_version: plan.framework.runtime_versions[cell.runtime],
    requested_effort: cell.requested_effort,
    repeat: cell.repeat,
    mode: plan.mode,
    prediction_seal_sha256: sealed.seal_sha256,
  };
  return Object.entries(expected).every(([field, value]) => result[field] === value)
    && resultContainmentMatches(result, plan);
}

function verificationState(result, plannedCase) {
  const failToPass = checkSetPassed(result.verification?.fail_to_pass);
  const passToPass = checkSetPassed(result.verification?.pass_to_pass);
  const failNamesMatch = checkNamesMatch(
    result.verification?.fail_to_pass,
    plannedCase?.check_names?.fail_to_pass,
  );
  const passNamesMatch = checkNamesMatch(
    result.verification?.pass_to_pass,
    plannedCase?.check_names?.pass_to_pass,
  );
  return {
    failToPass,
    passToPass,
    functional: failToPass && passToPass,
    namesMatch: failNamesMatch && passNamesMatch,
  };
}

function verificationInvariantsHold(result, verification) {
  const checks = [
    result.verification?.fail_to_pass_passed === verification.failToPass,
    result.verification?.pass_to_pass_passed === verification.passToPass,
    result.verification?.functional_passed === verification.functional,
    result.functional_passed === verification.functional,
  ];
  return checks.every(Boolean);
}

function passingEvidenceIsValid(result, verification, modelMatched, tierMatched, effortSupported) {
  const checks = [
    verification.functional,
    result.terminal_completed === true,
    modelMatched,
    tierMatched,
    effortSupported,
    result.provider_request_observed === true,
    result.request_count >= 1,
    result.resource_metric_observed === true,
    result.failure_class === "",
    result.runtime_result === "success",
  ];
  return checks.every(Boolean);
}

function validateOptionalMeasurements(result, cell) {
  for (const [field, value] of [
    ["tokens_total", result.tokens_total],
    ["cost_usd", result.cost_usd],
    ["duration_seconds", result.duration_seconds],
  ]) {
    if (value !== null && (!Number.isFinite(value) || value < 0)) {
      throw new Error(`Result ${field} is invalid for cell ${cell.cell_id}`);
    }
  }
}

function runtimeEvidenceIsValid(result) {
  if (!result.resources) return false;
  const checks = [
    typeof result.terminal_completed === "boolean",
    typeof result.failure_class === "string",
    typeof result.provider_request_observed === "boolean",
    typeof result.resource_metric_observed === "boolean",
    typeof result.routing_tier === "string",
    typeof result.tier_matched === "boolean",
    Number.isInteger(result.request_count),
    result.request_count >= 0,
    typeof result.runtime_result === "string",
    Number.isFinite(result.resources.cpu_seconds),
    result.resources.cpu_seconds >= 0,
    Number.isFinite(result.resources.peak_rss_kb),
    result.resources.peak_rss_kb >= 0,
    Number.isInteger(result.resources.peak_process_count),
    result.resources.peak_process_count >= 0,
  ];
  return checks.every(Boolean);
}

function validateResultVerification(result, cell, plannedCase) {
  const verification = verificationState(result, plannedCase);
  if (!verification.namesMatch) {
    throw new Error(`Result check identities do not match the plan for cell ${cell.cell_id}`);
  }
  if (!verificationInvariantsHold(result, verification)) {
    throw new Error(`Result verification invariants failed for cell ${cell.cell_id}`);
  }
  return verification;
}

function resultRoutingState(result) {
  const modelMatched = result.concrete_model === result.model;
  const tierMatched = result.routing_tier === result.candidate_tier;
  const effortSupported = result.effective_effort !== "unknown"
    && result.effective_effort === result.requested_effort;
  return { modelMatched, tierMatched, effortSupported };
}

function validateResultRouting(result, cell) {
  const routing = resultRoutingState(result);
  const checks = [
    result.model_matched === routing.modelMatched,
    result.tier_matched === routing.tierMatched,
    result.effort_supported === routing.effortSupported,
  ];
  if (!checks.every(Boolean)) {
    throw new Error(`Result routing evidence is inconsistent for cell ${cell.cell_id}`);
  }
  return routing;
}

function validatePassingResult(result, cell, verification, routing) {
  if (result.outcome !== "pass") return;
  if (!passingEvidenceIsValid(
    result,
    verification,
    routing.modelMatched,
    routing.tierMatched,
    routing.effortSupported,
  )) {
    throw new Error(`Passing result lacks required evidence for cell ${cell.cell_id}`);
  }
}

function validateResultIntegrity(result, cell, experimentDir) {
  validateOptionalMeasurements(result, cell);
  if (!runtimeEvidenceIsValid(result)) {
    throw new Error(`Result runtime evidence is invalid for cell ${cell.cell_id}`);
  }
  if (!Number.isFinite(Date.parse(result.recorded_at || ""))) {
    throw new Error(`Result integrity check failed for cell ${cell.cell_id}`);
  }
  if (resultDigest(result) !== result.result_sha256) {
    throw new Error(`Result integrity check failed for cell ${cell.cell_id}`);
  }
  validateResultArtifacts(result, cell, experimentDir);
}

export function validateResult(result, cell, plan, sealed, experimentDir) {
  if (!resultIdentityMatches(result, cell, plan, sealed)) {
    throw new Error(`Result identity mismatch for cell ${cell.cell_id}`);
  }
  if (!["pass", "fail", "error", "timeout"].includes(result.outcome)) {
    throw new Error(`Invalid result outcome for cell ${cell.cell_id}`);
  }
  const plannedCase = plan.cases.find((record) => record.case_id === cell.case_id);
  const verification = validateResultVerification(result, cell, plannedCase);
  const routing = validateResultRouting(result, cell);
  validatePassingResult(result, cell, verification, routing);
  validateResultIntegrity(result, cell, experimentDir);
}

export function validatedResultRecords(experimentDir, plan, sealed) {
  const results = resultRecords(experimentDir);
  const cells = new Map(plan.cells.map((cell) => [cell.cell_id, cell]));
  const seen = new Set();
  for (const result of results) {
    const cell = cells.get(result.cell_id);
    if (!cell) throw new Error(`Result references unknown cell ${result.cell_id}`);
    if (seen.has(result.cell_id)) throw new Error(`Duplicate result for cell ${result.cell_id}`);
    validateResult(result, cell, plan, sealed, experimentDir);
    seen.add(result.cell_id);
  }
  return results;
}

export function acquireRunLock(experimentDir) {
  const path = join(experimentDir, "run.lock");
  try {
    writeFileSync(path, `${process.pid}\n`, { flag: "wx", mode: 0o600 });
  } catch (error) {
    if (error?.code === "EEXIST") {
      throw new Error("Experiment already has an active or stale run.lock");
    }
    throw error;
  }
  return () => rmSync(path, { force: true });
}
