#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  commandAddCase,
  commandInit,
  commandQualify,
} from "./model-replay-cli-corpus.mjs";
import {
  parseArgs,
  rejectUnknownOptions,
  required,
  usage,
} from "./model-replay-cli-options.mjs";
import {
  createPlan,
  createReport,
  runExperiment,
  sealPredictions,
} from "./model-replay-experiment.mjs";

function commandPlan(options) {
  return createPlan({
    corpusDir: resolve(required(options, "corpus")),
    candidatePath: resolve(required(options, "candidates")),
    experimentDir: resolve(required(options, "experiment")),
    experimentID: required(options, "experiment_id"),
    suite: options.suite || "quick",
    stage: options.stage || "primary",
    mode: options.mode || "autonomous",
    allowContaminated: Boolean(options.allow_contaminated),
  });
}

function commandSeal(options) {
  return sealPredictions({
    experimentDir: resolve(required(options, "experiment")),
    inputPath: resolve(required(options, "input")),
  });
}

function commandRun(options) {
  return runExperiment({
    experimentDir: resolve(required(options, "experiment")),
    corpusDir: resolve(required(options, "corpus")),
    catalogPath: resolve(required(options, "catalog")),
    dryRun: Boolean(options.dry_run),
  });
}

function commandReport(options) {
  return createReport({ experimentDir: resolve(required(options, "experiment")) });
}

const HELP_COMMANDS = new Set(["help", "--help", "-h"]);
const LEGACY_COMMANDS = new Set(["extract", "enrich", "test", "score"]);
const LEGACY_REPLAY_MIGRATIONS = {
  validate: "qualify",
  qualify: "qualify",
  "dry-run": "plan, seal, then run --dry-run",
  run: "plan, seal, then run",
  report: "report",
};

function legacyError(command) {
  throw new Error(
    `The placeholder '${command}' workflow was replaced. Use init/add-case/qualify/plan/seal/run/report; see --help.`,
  );
}

function legacyReplayError(operation) {
  const replacement = LEGACY_REPLAY_MIGRATIONS[operation];
  if (!replacement) {
    throw new Error(
      "The legacy 'replay' namespace was removed. Use qualify/plan/seal/run/report; see --help.",
    );
  }
  throw new Error(
    `Legacy 'replay ${operation}' was removed. Use ${replacement}; see --help.`,
  );
}

function executeCommand(command, options) {
  let result;
  switch (command) {
    case "init": result = commandInit(options); break;
    case "add-case": result = commandAddCase(options); break;
    case "qualify": result = commandQualify(options); break;
    case "plan": result = commandPlan(options); break;
    case "seal": result = commandSeal(options); break;
    case "run": result = commandRun(options); break;
    case "report": result = commandReport(options); break;
    default: throw new Error(`Unknown command: ${command}`);
  }
  return result;
}

export function runCLI(argv = process.argv.slice(2)) {
  const command = argv[0] || "help";
  if (command === "replay") return legacyReplayError(argv[1] || "");
  const options = parseArgs(argv.slice(1));
  if (HELP_COMMANDS.has(command)) {
    rejectUnknownOptions("help", options);
    return usage();
  }
  if (LEGACY_COMMANDS.has(command)) return legacyError(command);
  rejectUnknownOptions(command, options);
  return executeCommand(command, options);
}

function printResult(result) {
  if (typeof result === "string") process.stdout.write(result);
  else process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  try {
    printResult(runCLI());
  } catch (error) {
    process.stderr.write(`Error: ${error.message}\n`);
    if (error.details) process.stderr.write(`${JSON.stringify(error.details, null, 2)}\n`);
    process.exitCode = 1;
  }
}
