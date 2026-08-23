// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const BOOLEAN_OPTIONS = new Set([
  "quick",
  "discriminator",
  "allow_contaminated",
  "allow_reconstructed",
  "allow_prompt_warnings",
  "retain_workspaces",
  "dry_run",
]);

const COMMAND_OPTIONS = {
  init: ["corpus", "name", "profiles", "quick_size", "full_size"],
  "add-case": [
    "corpus", "case_id", "repo_key", "profile", "tier", "base_sha", "prompt_file",
    "gold_patch", "checks_file", "prescriptive_file", "quick", "discriminator", "visibility",
    "prompt_fidelity", "source_type", "merged_at",
  ],
  qualify: [
    "corpus", "catalog", "case", "repetitions", "work_dir", "allow_reconstructed",
    "allow_prompt_warnings", "retain_workspaces",
  ],
  plan: [
    "corpus", "candidates", "experiment", "experiment_id", "suite", "stage", "mode",
    "execution_posture", "allow_contaminated",
  ],
  seal: ["experiment", "input"],
  run: ["experiment", "corpus", "catalog", "dry_run"],
  report: ["experiment"],
};

export function usage() {
  return `Historical model replay benchmark

Usage:
  brief-tier-test-helper.sh init --corpus DIR [--name NAME] [--profiles CSV] \\
    [--quick-size N] [--full-size N]
  brief-tier-test-helper.sh add-case --corpus DIR --case-id ID --repo-key KEY \\
    --profile PROFILE --tier TIER --base-sha SHA --prompt-file FILE \\
    --gold-patch FILE --checks-file FILE [--prescriptive-file FILE] [--quick] \\
    [--discriminator] [--visibility public|private] \\
    [--prompt-fidelity exact|reconstructed] [--source-type TYPE] [--merged-at ISO_DATE]
  brief-tier-test-helper.sh qualify --corpus DIR --catalog FILE [--case ID] \\
    [--repetitions N] [--allow-reconstructed] [--allow-prompt-warnings]
  brief-tier-test-helper.sh plan --corpus DIR --candidates FILE --experiment DIR \\
    --experiment-id ID [--suite quick|full] [--stage canary|primary|sweep|confirm] \\
    [--mode autonomous|prescriptive] [--execution-posture enforced|trusted-local] \\
    [--allow-contaminated]
  brief-tier-test-helper.sh seal --experiment DIR --input FILE
  brief-tier-test-helper.sh run --experiment DIR --corpus DIR --catalog FILE [--dry-run]
  brief-tier-test-helper.sh report --experiment DIR

Corpus defaults: three profiles, nine quick cases, eighteen full cases.
Raw corpora, repository catalogs, experiment logs, and reports are local-only.
`;
}

export function parseArgs(argv) {
  const options = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (!value.startsWith("--")) {
      options._.push(value);
      continue;
    }
    const key = value.slice(2).replace(/-/gu, "_");
    if (Object.hasOwn(options, key)) throw new Error(`Duplicate option: ${value}`);
    if (BOOLEAN_OPTIONS.has(key)) {
      options[key] = true;
      continue;
    }
    const next = argv[index + 1];
    if (next === undefined || next.startsWith("--")) throw new Error(`Missing value for ${value}`);
    options[key] = next;
    index += 1;
  }
  return options;
}

export function rejectUnknownOptions(command, options) {
  if (options._.length > 0) {
    throw new Error(`Unexpected positional arguments: ${options._.join(" ")}`);
  }
  const allowed = new Set(COMMAND_OPTIONS[command] || []);
  const unknown = Object.keys(options).filter((key) => key !== "_" && !allowed.has(key));
  if (unknown.length > 0) {
    throw new Error(`Unknown option for ${command}: --${unknown[0].replace(/_/gu, "-")}`);
  }
}

export function required(options, key) {
  const value = options[key];
  if (!value) throw new Error(`--${key.replace(/_/gu, "-")} is required`);
  return value;
}

export function integerOption(value, fallback, label) {
  const parsed = Number(value ?? fallback);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${label} must be a positive integer`);
  }
  return parsed;
}
