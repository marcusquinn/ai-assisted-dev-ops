// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  POLICY_VERSION,
  QUALIFICATION_SCHEMA,
  isFullCommitSHA,
  readJson,
  sha256,
  stableJson,
} from "./model-replay-common.mjs";
import { computeCaseHash, loadCase } from "./model-replay-corpus.mjs";
import { execute } from "./model-replay-process.mjs";
import { allFailedCleanly, allPassed } from "./model-replay-workspace.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PROMPT_GUARD = process.env.AIDEVOPS_PROMPT_GUARD_HELPER
  || join(SCRIPT_DIR, "prompt-guard-helper.sh");

function assertPromptGuardResult(result, allowWarnings) {
  if (result.status === 1) {
    throw new Error(`Prompt guard blocked archived prompt: ${result.stderr || result.stdout}`);
  }
  if (result.status === 2 && !allowWarnings) {
    throw new Error(
      "Prompt guard warned about the archived prompt; review it and use --allow-prompt-warnings explicitly",
    );
  }
  if (![0, 2].includes(result.status)) {
    throw new Error(`Prompt guard failed: ${result.stderr || result.stdout || result.error}`);
  }
}

export function scanPrompt(promptPath, allowWarnings) {
  if (!existsSync(PROMPT_GUARD)) {
    throw new Error("Prompt guard is unavailable; archived prompts cannot be qualified safely");
  }
  const result = execute([PROMPT_GUARD, "check-file", promptPath], { timeoutMs: 30000 });
  assertPromptGuardResult(result, allowWarnings);
  return {
    status: result.status === 2 ? "warning" : "clean",
    findings: result.status === 2 ? result.stderr || result.stdout : "",
  };
}

export function qualificationReason(baseFail, basePass, goldFail, goldPass, patchResult) {
  const failures = [
    [patchResult.status !== 0, "gold_patch_does_not_apply"],
    [!allFailedCleanly(baseFail), "fail_to_pass_did_not_fail_on_base"],
    [!allPassed(basePass), "pass_to_pass_failed_on_base"],
    [!allPassed(goldFail), "fail_to_pass_failed_after_gold_patch"],
    [!allPassed(goldPass), "pass_to_pass_failed_after_gold_patch"],
  ];
  return failures.find(([failed]) => failed)?.[1] || "";
}

function checkResultIdentity({ name, status, signal, timed_out }) {
  return { name, status, signal, timed_out };
}

export function qualificationRunSignature(run) {
  return stableJson({
    base_fail_to_pass: run.base_fail_to_pass.map(checkResultIdentity),
    base_pass_to_pass: run.base_pass_to_pass.map(checkResultIdentity),
    gold_patch_status: run.gold_patch_status,
    gold_fail_to_pass: run.gold_fail_to_pass.map(checkResultIdentity),
    gold_pass_to_pass: run.gold_pass_to_pass.map(checkResultIdentity),
  });
}

export function qualificationDigest(qualification) {
  const payload = { ...qualification };
  delete payload.qualification_sha256;
  return sha256(stableJson(payload));
}

function repetitionEnvelopeIsValid(qualification) {
  const repetitions = Number(qualification.repetitions);
  if (!Number.isInteger(repetitions)) return false;
  if (repetitions < 2 || repetitions > 5) return false;
  if (!Array.isArray(qualification.runs)) return false;
  return qualification.runs.length === repetitions;
}

function qualificationRunIsValid(run, index) {
  const reason = qualificationReason(
    run.base_fail_to_pass,
    run.base_pass_to_pass,
    run.gold_fail_to_pass,
    run.gold_pass_to_pass,
    { status: run.gold_patch_status },
  );
  if (run.repetition !== index + 1) return false;
  if (run.qualified !== true) return false;
  if (run.reason !== "") return false;
  return !reason;
}

function qualificationRunsAreValid(qualification) {
  if (!repetitionEnvelopeIsValid(qualification)) return false;
  const signatures = new Set();
  for (let index = 0; index < qualification.runs.length; index += 1) {
    const run = qualification.runs[index];
    if (!qualificationRunIsValid(run, index)) return false;
    signatures.add(qualificationRunSignature(run));
  }
  return signatures.size === 1;
}

function promptGuardStatusIsValid(record) {
  return ["clean", "warning"].includes(record?.status);
}

function qualificationMetadataIsValid(qualification, loadedCase, caseID) {
  const prescriptiveRequired = loadedCase.definition.modes.includes("prescriptive");
  const prescriptiveGuardValid = prescriptiveRequired
    ? promptGuardStatusIsValid(qualification.prompt_guard?.prescriptive)
    : true;
  const checks = [
    qualification.schema_version === QUALIFICATION_SCHEMA,
    qualification.policy_version === POLICY_VERSION,
    qualification.status === "qualified",
    qualification.reason === "",
    qualification.case_id === caseID,
    isFullCommitSHA(qualification.base_tree_sha),
    qualificationDigest(qualification) === qualification.qualification_sha256,
    qualificationRunsAreValid(qualification),
    promptGuardStatusIsValid(qualification.prompt_guard?.autonomous),
    prescriptiveGuardValid,
  ];
  return checks.every(Boolean);
}

export function verifyQualification(corpusDir, caseID) {
  const loadedCase = loadCase(corpusDir, caseID);
  const qualificationPath = join(loadedCase.directory, "qualification.json");
  if (!existsSync(qualificationPath)) throw new Error(`Case ${caseID} is not qualified`);
  const qualification = readJson(qualificationPath);
  if (!qualificationMetadataIsValid(qualification, loadedCase, caseID)) {
    throw new Error(`Case ${caseID} has no current successful qualification`);
  }
  const current = computeCaseHash(loadedCase, qualification.base_tree_sha);
  if (current.caseHash !== qualification.case_hash) {
    throw new Error(`Case ${caseID} changed after qualification`);
  }
  return { loadedCase, qualification, fingerprint: current };
}
