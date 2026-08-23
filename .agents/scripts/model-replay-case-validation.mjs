// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  CASE_SCHEMA,
  MODES,
  TIERS,
  assertSafeID,
  isFullCommitSHA,
} from "./model-replay-common.mjs";

function validateCheckName(check, label) {
  if (!check || typeof check.name !== "string" || !check.name.trim()) {
    throw new Error(`${label} check requires a name`);
  }
}

function validateCheckArguments(check, label) {
  if (!Array.isArray(check.argv) || check.argv.length === 0
    || check.argv.some((part) => typeof part !== "string" || !part)) {
    throw new Error(`${label} check ${check.name} requires non-empty argv strings`);
  }
}

function validateCheckTimeout(check, label) {
  const timeout = Number(check.timeout_seconds ?? 120);
  if (!Number.isInteger(timeout) || timeout < 1 || timeout > 3600) {
    throw new Error(`${label} check ${check.name} timeout must be 1..3600 seconds`);
  }
}

function validateCheck(check, label) {
  validateCheckName(check, label);
  validateCheckArguments(check, label);
  validateCheckTimeout(check, label);
}

function validateCaseIdentity(definition, profiles) {
  if (definition.schema_version !== CASE_SCHEMA) throw new Error("Unsupported case schema");
  assertSafeID(definition.case_id, "case_id");
  assertSafeID(definition.repo_key, "repo_key");
  if (!profiles.includes(definition.profile)) {
    throw new Error(`Case ${definition.case_id} uses undeclared profile ${definition.profile}`);
  }
  if (!TIERS.includes(definition.expected_tier)) {
    throw new Error(`Case ${definition.case_id} has invalid expected_tier`);
  }
  if (!isFullCommitSHA(definition.base_sha)) {
    throw new Error(`Case ${definition.case_id} requires an immutable full base SHA`);
  }
}

function validateCaseModes(definition) {
  if (!Array.isArray(definition.modes) || definition.modes.length === 0
    || definition.modes.some((mode) => !MODES.includes(mode))) {
    throw new Error(`Case ${definition.case_id} has invalid modes`);
  }
  if (new Set(definition.modes).size !== definition.modes.length) {
    throw new Error(`Case ${definition.case_id} modes must be unique`);
  }
}

function validateCaseProvenance(definition) {
  if (definition.prompt_fidelity !== "exact" && definition.prompt_fidelity !== "reconstructed") {
    throw new Error(`Case ${definition.case_id} has invalid prompt_fidelity`);
  }
  if (!["public", "private"].includes(definition.provenance?.visibility)) {
    throw new Error(`Case ${definition.case_id} requires public or private provenance visibility`);
  }
}

function validateCaseChecks(definition) {
  const failChecks = definition.checks?.fail_to_pass;
  const passChecks = definition.checks?.pass_to_pass;
  if (!Array.isArray(failChecks) || failChecks.length === 0) {
    throw new Error(`Case ${definition.case_id} requires fail_to_pass checks`);
  }
  if (!Array.isArray(passChecks) || passChecks.length === 0) {
    throw new Error(`Case ${definition.case_id} requires pass_to_pass checks`);
  }
  for (const check of failChecks) validateCheck(check, "fail_to_pass");
  for (const check of passChecks) validateCheck(check, "pass_to_pass");
  const checkNames = [...failChecks, ...passChecks].map((check) => check.name);
  if (new Set(checkNames).size !== checkNames.length) {
    throw new Error(`Case ${definition.case_id} check names must be unique`);
  }
}

export function validateCaseDefinition(definition, profiles = []) {
  validateCaseIdentity(definition, profiles);
  validateCaseModes(definition);
  validateCaseProvenance(definition);
  validateCaseChecks(definition);
  return definition;
}
