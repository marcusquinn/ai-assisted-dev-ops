// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  CASE_SCHEMA,
  CATALOG_SCHEMA,
  CORPUS_SCHEMA,
  POLICY_VERSION,
  TIERS,
  assertSafeID,
  harnessIdentity,
  pathInside,
  readJson,
  regularFileInside,
  sha256,
  sha256File,
  stableJson,
} from "./model-replay-common.mjs";
import { validateCaseDefinition } from "./model-replay-case-validation.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const PROMPT_GUARD = process.env.AIDEVOPS_PROMPT_GUARD_HELPER
  || join(SCRIPT_DIR, "prompt-guard-helper.sh");

function validateSuiteSizes(manifest) {
  const quickSize = Number(manifest.suites?.quick);
  const fullSize = Number(manifest.suites?.full);
  if (!Number.isInteger(quickSize) || quickSize < 1) {
    throw new Error("Corpus suites require a positive quick size");
  }
  if (!Number.isInteger(fullSize) || fullSize < quickSize) {
    throw new Error("Corpus suites require a full size at least as large as quick");
  }
}

function validateCorpusCases(manifest) {
  if (!Array.isArray(manifest.cases)) throw new Error("Corpus cases must be an array");
  const caseIDs = manifest.cases.map((entry) => assertSafeID(entry.case_id, "case_id"));
  if (new Set(caseIDs).size !== caseIDs.length) throw new Error("Corpus case IDs must be unique");
  const directories = manifest.cases.map((entry) => String(entry.directory || ""));
  if (directories.some((directory) => !directory)) {
    throw new Error("Corpus case directories must be present and unique");
  }
  if (new Set(directories).size !== directories.length) {
    throw new Error("Corpus case directories must be present and unique");
  }
  for (const entry of manifest.cases) {
    if (!manifest.profiles.includes(entry.profile) || !TIERS.includes(entry.expected_tier)) {
      throw new Error(`Corpus entry ${entry.case_id} has invalid profile or tier metadata`);
    }
  }
}

export function loadCorpus(corpusDir) {
  const requestedRoot = resolve(corpusDir);
  const root = existsSync(requestedRoot) ? realpathSync(requestedRoot) : requestedRoot;
  const manifestPath = join(root, "corpus.json");
  const manifest = readJson(manifestPath);
  if (manifest.schema_version !== CORPUS_SCHEMA) {
    throw new Error(`Unsupported corpus schema in ${manifestPath}`);
  }
  if (!Array.isArray(manifest.profiles) || manifest.profiles.length === 0) {
    throw new Error("Corpus must declare at least one profile");
  }
  manifest.profiles.forEach((profile) => {
    assertSafeID(profile, "profile");
  });
  if (new Set(manifest.profiles).size !== manifest.profiles.length) {
    throw new Error("Corpus profiles must be unique");
  }
  validateSuiteSizes(manifest);
  validateCorpusCases(manifest);
  return { root, manifest, manifestPath };
}

export function loadCase(corpusDir, caseID) {
  const corpus = loadCorpus(corpusDir);
  const entry = corpus.manifest.cases.find((candidate) => candidate.case_id === caseID);
  if (!entry) throw new Error(`Unknown case_id: ${caseID}`);
  const directory = pathInside(corpus.root, join(corpus.root, entry.directory));
  const definitionPath = regularFileInside(directory, "case.json", "case definition");
  const definition = readJson(definitionPath);
  validateCaseDefinition(definition, corpus.manifest.profiles);
  if (definition.case_id !== caseID) throw new Error(`Case ID mismatch for ${caseID}`);
  if (definition.profile !== entry.profile || definition.expected_tier !== entry.expected_tier) {
    throw new Error(`Corpus metadata does not match case definition for ${caseID}`);
  }
  return { ...corpus, entry, directory, definition, definitionPath };
}

export function loadCatalog(catalogPath) {
  const path = resolve(catalogPath);
  const catalog = readJson(path);
  if (catalog.schema_version !== CATALOG_SCHEMA || !catalog.repositories) {
    throw new Error(`Unsupported repository catalog schema in ${path}`);
  }
  for (const [key, record] of Object.entries(catalog.repositories)) {
    assertSafeID(key, "repository key");
    if (!record || !isAbsolute(record.path || "")) {
      throw new Error(`Repository catalog path for ${key} must be absolute`);
    }
  }
  return { path, catalog };
}

export function caseFiles(loadedCase) {
  const { directory, definition } = loadedCase;
  const prompt = regularFileInside(directory, definition.prompt_file, "prompt");
  const goldPatch = regularFileInside(directory, definition.gold_patch_file, "gold patch");
  let prescriptivePrompt = "";
  if (definition.modes.includes("prescriptive")) {
    prescriptivePrompt = regularFileInside(
      directory,
      definition.prescriptive_prompt_file,
      "prescriptive prompt",
    );
  }
  return { prompt, goldPatch, prescriptivePrompt };
}

export function computeCaseHash(loadedCase, baseTreeHash) {
  const files = caseFiles(loadedCase);
  const definition = loadedCase.definition;
  const identity = {
    schema_version: CASE_SCHEMA,
    policy_version: POLICY_VERSION,
    harness: harnessIdentity(),
    case_id: definition.case_id,
    profile: definition.profile,
    expected_tier: definition.expected_tier,
    repo_key: definition.repo_key,
    base_sha: definition.base_sha,
    base_tree_sha: baseTreeHash,
    modes: [...definition.modes].sort(),
    prompt_fidelity: definition.prompt_fidelity,
    provenance: definition.provenance,
    checks: definition.checks,
    prompt_sha256: sha256File(files.prompt),
    gold_patch_sha256: sha256File(files.goldPatch),
    prescriptive_prompt_sha256: files.prescriptivePrompt
      ? sha256File(files.prescriptivePrompt)
      : "",
    prompt_guard_sha256: promptGuardHash(),
  };
  return { caseHash: sha256(stableJson(identity)), identity, files };
}

function promptGuardHash() {
  return existsSync(PROMPT_GUARD) ? sha256File(PROMPT_GUARD) : "unavailable";
}

export function repositoryPathForCase(loadedCase, loadedCatalog) {
  const record = loadedCatalog.catalog.repositories[loadedCase.definition.repo_key];
  if (!record?.path) {
    throw new Error(`Repository catalog has no entry for ${loadedCase.definition.repo_key}`);
  }
  const repositoryPath = resolve(record.path);
  if (!existsSync(repositoryPath)) throw new Error("Repository catalog path does not exist");
  return repositoryPath;
}
