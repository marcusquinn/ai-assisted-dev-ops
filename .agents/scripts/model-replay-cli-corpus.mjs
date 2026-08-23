// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import {
  CASE_SCHEMA,
  CATALOG_SCHEMA,
  CORPUS_SCHEMA,
  TIERS,
  assertSafeID,
  copyCaseInput,
  isFullCommitSHA,
  loadCorpus,
  qualifyCase,
  readJson,
  validateCaseDefinition,
  writeJson,
} from "./model-replay-core.mjs";
import { integerOption, required } from "./model-replay-cli-options.mjs";

export function commandInit(options) {
  const corpusDir = resolve(required(options, "corpus"));
  if (existsSync(join(corpusDir, "corpus.json"))) throw new Error("Corpus already exists");
  const profiles = String(options.profiles || "aidevops,wordpress-plugin,nextjs")
    .split(",").map((value) => value.trim()).filter(Boolean);
  profiles.forEach((profile) => {
    assertSafeID(profile, "profile");
  });
  if (new Set(profiles).size !== profiles.length) throw new Error("Profiles must be unique");
  const quickSize = integerOption(options.quick_size, 9, "quick size");
  const fullSize = integerOption(options.full_size, 18, "full size");
  if (fullSize < quickSize) throw new Error("Full suite size must be at least quick suite size");
  const manifest = {
    schema_version: CORPUS_SCHEMA,
    name: options.name || "historical-model-replay",
    created_at: new Date().toISOString(),
    profiles,
    suites: {
      quick: quickSize,
      full: fullSize,
    },
    cases: [],
  };
  mkdirSync(corpusDir, { recursive: true, mode: 0o700 });
  writeJson(join(corpusDir, "corpus.json"), manifest);
  const catalogTemplate = {
    schema_version: CATALOG_SCHEMA,
    repositories: Object.fromEntries(profiles.map((profile, index) => [
      `repo-${index + 1}`,
      { path: `/absolute/local/path/for-${profile}`, profile },
    ])),
  };
  writeJson(join(corpusDir, "repositories.example.json"), catalogTemplate);
  return manifest;
}

function caseDefinition(options, { caseID, repoKey, profile, tier, baseSHA, checks }) {
  const modes = ["autonomous"];
  if (options.prescriptive_file) modes.push("prescriptive");
  return {
    schema_version: CASE_SCHEMA,
    case_id: caseID,
    repo_key: repoKey,
    profile,
    expected_tier: tier,
    base_sha: baseSHA,
    modes,
    prompt_file: "prompt.md",
    prescriptive_prompt_file: options.prescriptive_file ? "prescriptive.md" : "",
    gold_patch_file: "gold.patch",
    prompt_fidelity: options.prompt_fidelity || "exact",
    provenance: {
      source_type: options.source_type || "merged-pr",
      visibility: options.visibility || "public",
      merged_at: options.merged_at || "",
    },
    checks,
  };
}

function addCaseFiles(options, caseDir) {
  copyCaseInput(required(options, "prompt_file"), join(caseDir, "prompt.md"));
  copyCaseInput(required(options, "gold_patch"), join(caseDir, "gold.patch"));
  if (options.prescriptive_file) {
    copyCaseInput(options.prescriptive_file, join(caseDir, "prescriptive.md"));
  }
}

export function commandAddCase(options) {
  const corpusDir = resolve(required(options, "corpus"));
  const corpus = loadCorpus(corpusDir);
  const caseID = assertSafeID(required(options, "case_id"), "case_id");
  const repoKey = assertSafeID(required(options, "repo_key"), "repo_key");
  const profile = required(options, "profile");
  const tier = required(options, "tier");
  if (!corpus.manifest.profiles.includes(profile)) throw new Error(`Unknown profile ${profile}`);
  if (!TIERS.includes(tier)) throw new Error(`Invalid tier ${tier}`);
  if (corpus.manifest.cases.some((entry) => entry.case_id === caseID)) {
    throw new Error(`Case already exists: ${caseID}`);
  }
  const baseSHA = required(options, "base_sha");
  if (!isFullCommitSHA(baseSHA)) {
    throw new Error("base SHA must be an exact full immutable hash");
  }
  const checks = readJson(resolve(required(options, "checks_file")));
  const definition = caseDefinition(options, {
    caseID,
    repoKey,
    profile,
    tier,
    baseSHA,
    checks,
  });
  validateCaseDefinition(definition, corpus.manifest.profiles);
  const caseDir = join(corpus.root, "cases", caseID);
  mkdirSync(caseDir, { recursive: true, mode: 0o700 });
  addCaseFiles(options, caseDir);
  writeJson(join(caseDir, "case.json"), definition);
  corpus.manifest.cases.push({
    case_id: caseID,
    directory: `cases/${caseID}`,
    profile,
    expected_tier: tier,
    quick: Boolean(options.quick),
    discriminator: Boolean(options.discriminator),
    active: true,
  });
  writeJson(corpus.manifestPath, corpus.manifest);
  return definition;
}

function qualifyEntry(entry, options, corpusDir, catalogPath, workRoot) {
  return qualifyCase({
    corpusDir,
    caseID: entry.case_id,
    catalogPath,
    workRoot,
    repetitions: integerOption(options.repetitions, 3, "repetitions"),
    allowReconstructedPrompt: Boolean(options.allow_reconstructed),
    allowPromptWarnings: Boolean(options.allow_prompt_warnings),
    retainWorkspaces: Boolean(options.retain_workspaces),
  });
}

export function commandQualify(options) {
  const corpusDir = resolve(required(options, "corpus"));
  const catalogPath = resolve(required(options, "catalog"));
  const corpus = loadCorpus(corpusDir);
  const selected = options.case
    ? corpus.manifest.cases.filter((entry) => entry.case_id === options.case)
    : corpus.manifest.cases;
  if (selected.length === 0) throw new Error("No matching cases to qualify");
  const workRoot = resolve(options.work_dir || join(corpusDir, ".qualification-work"));
  const results = [];
  for (const entry of selected) {
    try {
      results.push(qualifyEntry(entry, options, corpusDir, catalogPath, workRoot));
    } catch (error) {
      results.push({ case_id: entry.case_id, status: "rejected", reason: error.message });
    }
  }
  if (results.some((result) => result.status !== "qualified")) {
    const error = new Error("One or more replay cases failed qualification");
    error.details = results;
    throw error;
  }
  return results;
}
