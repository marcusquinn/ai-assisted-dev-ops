// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import {
  POLICY_VERSION,
  QUALIFICATION_SCHEMA,
  writeJson,
  writePrivateFile,
} from "./model-replay-common.mjs";
import {
  caseFiles,
  computeCaseHash,
  loadCase,
  loadCatalog,
} from "./model-replay-corpus.mjs";
import {
  assertNoSymlinks,
  execute,
  workspaceExecutionEnvironment,
} from "./model-replay-process.mjs";
import {
  qualificationDigest,
  qualificationReason,
  qualificationRunSignature,
  scanPrompt,
} from "./model-replay-qualification-validation.mjs";
import {
  createSyntheticWorkspace,
  removeSyntheticWorkspace,
  runCheckSet,
} from "./model-replay-workspace.mjs";

function qualificationPromptGuard(files, allowPromptWarnings) {
  return {
    autonomous: scanPrompt(files.prompt, allowPromptWarnings),
    prescriptive: files.prescriptivePrompt
      ? scanPrompt(files.prescriptivePrompt, allowPromptWarnings)
      : null,
  };
}

function checksAfterPatch(checks, workspace, patchApplied) {
  if (!patchApplied) return [];
  return runCheckSet(checks, workspace);
}

function qualificationAttempt({ loadedCase, loadedCatalog, basePath, goldPath, workRoot, files, repetition }) {
  const base = createSyntheticWorkspace(loadedCase, loadedCatalog, basePath, workRoot);
  const gold = createSyntheticWorkspace(loadedCase, loadedCatalog, goldPath, workRoot);
  const baseFail = runCheckSet(loadedCase.definition.checks.fail_to_pass, base.workspace);
  const basePass = runCheckSet(loadedCase.definition.checks.pass_to_pass, base.workspace);
  const patchResult = execute(
    ["git", "apply", "--binary", "--whitespace=nowarn", files.goldPatch],
    {
      cwd: gold.workspace,
      env: workspaceExecutionEnvironment(gold.workspace),
      timeoutMs: 120000,
    },
  );
  const patchApplied = patchResult.status === 0;
  if (patchApplied) assertNoSymlinks(gold.workspace);
  const goldFail = checksAfterPatch(
    loadedCase.definition.checks.fail_to_pass,
    gold.workspace,
    patchApplied,
  );
  const goldPass = checksAfterPatch(
    loadedCase.definition.checks.pass_to_pass,
    gold.workspace,
    patchApplied,
  );
  const reason = qualificationReason(baseFail, basePass, goldFail, goldPass, patchResult);
  return {
    baseTreeHash: base.baseTreeHash,
    reason,
    record: {
      repetition,
      base_fail_to_pass: baseFail,
      base_pass_to_pass: basePass,
      gold_patch_status: patchResult.status,
      gold_fail_to_pass: goldFail,
      gold_pass_to_pass: goldPass,
      qualified: !reason,
      reason,
    },
  };
}

function qualificationRepetitions(value) {
  const repeatCount = Number(value);
  if (!Number.isInteger(repeatCount) || repeatCount < 2 || repeatCount > 5) {
    throw new Error("Qualification repetitions must be 2..5");
  }
  return repeatCount;
}

function runQualificationRepetitions({
  loadedCase,
  loadedCatalog,
  caseID,
  workRoot,
  files,
  repeatCount,
  retainWorkspaces,
}) {
  const runs = [];
  let baseTreeHash = "";
  let rejectionReason = "";
  for (let index = 0; index < repeatCount; index += 1) {
    const basePath = join(workRoot, `${caseID}-q${index + 1}-base`);
    const goldPath = join(workRoot, `${caseID}-q${index + 1}-gold`);
    try {
      const attempt = qualificationAttempt({
        loadedCase,
        loadedCatalog,
        basePath,
        goldPath,
        workRoot,
        files,
        repetition: index + 1,
      });
      baseTreeHash = attempt.baseTreeHash;
      if (attempt.reason && !rejectionReason) rejectionReason = attempt.reason;
      runs.push(attempt.record);
    } finally {
      if (!retainWorkspaces) {
        removeSyntheticWorkspace(workRoot, basePath);
        removeSyntheticWorkspace(workRoot, goldPath);
      }
    }
  }
  const outcomeSignatures = new Set(runs.map(qualificationRunSignature));
  if (outcomeSignatures.size > 1 && !rejectionReason) {
    rejectionReason = "non_deterministic_verifier";
  }
  return { baseTreeHash, rejectionReason, runs };
}

export function qualifyCase({
  corpusDir,
  caseID,
  catalogPath,
  workRoot,
  repetitions = 3,
  allowReconstructedPrompt = false,
  allowPromptWarnings = false,
  retainWorkspaces = false,
}) {
  const loadedCase = loadCase(corpusDir, caseID);
  const loadedCatalog = loadCatalog(catalogPath);
  if (loadedCase.definition.prompt_fidelity !== "exact" && !allowReconstructedPrompt) {
    throw new Error(`Case ${caseID} has reconstructed prompt fidelity; explicit override required`);
  }
  const files = caseFiles(loadedCase);
  const promptGuard = qualificationPromptGuard(files, allowPromptWarnings);
  const repeatCount = qualificationRepetitions(repetitions);
  mkdirSync(workRoot, { recursive: true, mode: 0o700 });
  const { baseTreeHash, rejectionReason, runs } = runQualificationRepetitions({
    loadedCase,
    loadedCatalog,
    caseID,
    workRoot,
    files,
    repeatCount,
    retainWorkspaces,
  });
  const fingerprint = computeCaseHash(loadedCase, baseTreeHash);
  const qualification = {
    schema_version: QUALIFICATION_SCHEMA,
    policy_version: POLICY_VERSION,
    case_id: caseID,
    case_hash: fingerprint.caseHash,
    base_tree_sha: baseTreeHash,
    status: rejectionReason ? "rejected" : "qualified",
    reason: rejectionReason,
    prompt_guard: promptGuard,
    repetitions: repeatCount,
    qualified_at: new Date().toISOString(),
    runs,
  };
  qualification.qualification_sha256 = qualificationDigest(qualification);
  writeJson(join(loadedCase.directory, "qualification.json"), qualification);
  return qualification;
}

export function copyCaseInput(source, destination) {
  const resolvedSource = resolve(source);
  if (!existsSync(resolvedSource) || !lstatSync(resolvedSource).isFile()) {
    throw new Error(`Case input is not a regular file: ${resolvedSource}`);
  }
  return writePrivateFile(destination, readFileSync(resolvedSource), 0o600);
}
