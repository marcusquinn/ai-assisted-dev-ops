#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {resolve} from "node:path";
import {pathToFileURL} from "node:url";
import {canonicalJson, TeamInterfaceError} from "./team-interface-common.mjs";
import {diagnostic} from "./team-interface-diagnostics.mjs";
import {runDetect, runDoctor, runPlan, runProviders, runStatus} from "./team-interface-runtime-commands.mjs";

export {
  canonicalDigest,
  canonicalJson,
  compareCanonicalText,
  expandRuntimePath,
  TeamInterfaceError,
} from "./team-interface-common.mjs";
export {diagnostic} from "./team-interface-diagnostics.mjs";
export {loadRuntimeConfig, loadRuntimeDocuments} from "./team-interface-config.mjs";
export {acquireStateLock, releaseStateLock} from "./team-interface-lock.mjs";
export {assertInputPolicy, assertInputRegistry, generatePlan} from "./team-interface-planner.mjs";
export {runDetect, runDoctor, runPlan, runProviders, runStatus} from "./team-interface-runtime-commands.mjs";
export {readRuntimeState, runtimeStatePaths, writeRuntimeState} from "./team-interface-state.mjs";
export {createRuntimeValidators} from "./team-interface-validators.mjs";

function parseCliArguments(argumentsList) {
  const options = {};
  const seen = new Set();
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (!["--config", "--request", "--state-dir"].includes(argument)) {
      throw new TeamInterfaceError("unsupported_argument", `unsupported argument ${argument}`);
    }
    if (seen.has(argument)) throw new TeamInterfaceError("duplicate_argument", `duplicate argument ${argument}`);
    const value = argumentsList[index + 1];
    if (!value) throw new TeamInterfaceError("missing_argument", `${argument} requires a value`);
    if (argument === "--config") options.configPath = value;
    if (argument === "--request") options.requestPath = value;
    if (argument === "--state-dir") options.stateRoot = value;
    seen.add(argument);
    index += 1;
  }
  return options;
}

export async function main(argumentsList = process.argv.slice(2)) {
  const [command, ...rest] = argumentsList;
  const supported = new Set(["providers", "detect", "status", "doctor", "plan"]);
  if (!supported.has(command)) throw new TeamInterfaceError("unsupported_command", `unsupported command ${command || "<empty>"}`);
  const options = parseCliArguments(rest);
  if (command === "providers") return runProviders(options);
  if (command === "detect") return runDetect(options);
  if (command === "status") return runStatus(options);
  if (command === "doctor") return runDoctor(options);
  return runPlan(options);
}

function isDirectExecution() {
  if (!process.argv[1]) return false;
  return import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
}

if (isDirectExecution()) {
  try {
    const result = await main();
    process.stdout.write(`${canonicalJson(result)}\n`);
    if (result?.ok === false) process.exitCode = 1;
  } catch (error) {
    process.stderr.write(`${canonicalJson({error: diagnostic(error)})}\n`);
    process.exitCode = 1;
  }
}
