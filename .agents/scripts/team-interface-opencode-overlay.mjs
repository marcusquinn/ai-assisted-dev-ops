#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  closeSync,
  constants,
  existsSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {randomBytes} from "node:crypto";
import Ajv2020 from "ajv/dist/2020.js";

import {
  canonicalDigest,
  canonicalJson,
  bindOverlayToCanonicalRoster,
  conversationBootstrapConfig,
  createOverlayDocument,
  loadCanonicalAgentRoster,
  parseCanonicalOverlayText,
} from "../plugins/opencode-aidevops/team-interface-context.mjs";
import {readBoundedJson, TeamInterfaceError} from "./team-interface-common.mjs";
import {verifyConversationEffectiveConfig} from "./team-interface-opencode-effective-config.mjs";
import {
  ProjectRootValidationError,
  validateRegisteredProjectRoot,
} from "./team-interface-opencode-project-root.mjs";

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const SCHEMA_DIRECTORY = resolve(SCRIPT_DIRECTORY, "../schemas/team-interface");
const CANONICAL_AGENTS_DIRECTORY = resolve(SCRIPT_DIRECTORY, "..");
const MAX_ROSTER_BYTES = 1024 * 1024;
const MAX_CONTEXT_BYTES = 16 * 1024;
const MAX_OVERLAY_BYTES = 64 * 1024;
const MAX_EFFECTIVE_CONFIG_BYTES = 4 * 1024 * 1024;

class OverlayGeneratorError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "OverlayGeneratorError";
    this.code = code;
  }
}

function readSchema(filename) {
  return JSON.parse(readFileSync(join(SCHEMA_DIRECTORY, filename), "utf8"));
}

function validators() {
  const core = readSchema("core-v1.schema.json");
  const roster = readSchema("agent-roster-v1.schema.json");
  const overlay = readSchema("opencode-launch-overlay-v1.schema.json");
  const ajv = new Ajv2020({allErrors: true, strict: false, validateFormats: false});
  ajv.addSchema(core);
  ajv.addSchema(roster);
  ajv.addSchema(overlay);
  return {
    context: ajv.compile({$ref: `${overlay.$id}#/$defs/interface_context`}),
    overlay: ajv.getSchema(overlay.$id),
    roster: ajv.getSchema(roster.$id),
  };
}

function validationError(validate, label) {
  const details = (validate.errors || [])
    .map((error) => `${error.instancePath || "<root>"} ${error.keyword}`)
    .join(", ");
  return new OverlayGeneratorError("invalid_document", `${label} failed closed-schema validation: ${details}`);
}

function requireValid(validate, value, label) {
  if (!validate(value)) throw validationError(validate, label);
  return value;
}

function validateRosterDigest(roster) {
  const unsigned = structuredClone(roster);
  delete unsigned.roster_digest;
  if (roster.roster_digest !== canonicalDigest(unsigned)) {
    throw new OverlayGeneratorError("digest_mismatch", "agent roster digest does not match its canonical content");
  }
  const ids = roster.agents.map(({agent_id: agentID}) => agentID);
  if (new Set(ids).size !== ids.length) {
    throw new OverlayGeneratorError("duplicate_agent", "agent roster contains duplicate stable agent IDs");
  }
}

function selectAgent(roster, agentID) {
  const matches = roster.agents.filter((agent) => agent.agent_id === agentID);
  if (matches.length !== 1) {
    throw new OverlayGeneratorError("unknown_agent", "selected stable agent ID is unknown or duplicated");
  }
  return matches[0];
}

function parseOptions(argumentsList, allowed) {
  const options = {};
  for (let index = 0; index < argumentsList.length; index += 1) {
    const name = argumentsList[index];
    if (!name.startsWith("--") || !allowed.has(name)) {
      throw new OverlayGeneratorError("invalid_arguments", `unsupported argument: ${name}`);
    }
    if (Object.hasOwn(options, name)) {
      throw new OverlayGeneratorError("invalid_arguments", `duplicate argument: ${name}`);
    }
    const value = argumentsList[index + 1];
    if (!value || value.startsWith("--")) {
      throw new OverlayGeneratorError("invalid_arguments", `${name} requires a value`);
    }
    options[name] = value;
    index += 1;
  }
  return options;
}

function requireOption(options, name) {
  const value = options[name];
  if (!value) throw new OverlayGeneratorError("invalid_arguments", `${name} is required`);
  return value;
}

function readOverlayText(filePath) {
  const resolvedPath = resolve(filePath);
  let stats;
  try {
    stats = lstatSync(resolvedPath);
  } catch {
    throw new OverlayGeneratorError("missing_document", "OpenCode launch overlay is unavailable");
  }
  if (!stats.isFile() || stats.isSymbolicLink()) {
    throw new OverlayGeneratorError("unsafe_path", "OpenCode launch overlay must be a regular non-symlink file");
  }
  if (stats.size > MAX_OVERLAY_BYTES) {
    throw new OverlayGeneratorError("document_too_large", "OpenCode launch overlay exceeds its size limit");
  }
  return readFileSync(resolvedPath, "utf8");
}

function readBoundOverlay(overlayPath, agentsDirectory) {
  const document = parseCanonicalOverlayText(readOverlayText(overlayPath));
  requireValid(validators().overlay, document, "OpenCode launch overlay");
  bindOverlayToCanonicalRoster(document, loadCanonicalAgentRoster(agentsDirectory));
  return document;
}

function validateOutputPath(outputPath, inputPaths) {
  const resolvedOutput = resolve(outputPath);
  if (inputPaths.map((inputPath) => resolve(inputPath)).includes(resolvedOutput)) {
    throw new OverlayGeneratorError("unsafe_path", "output must not replace an input document");
  }
  const parent = dirname(resolvedOutput);
  if (!existsSync(parent) || !statSync(parent).isDirectory()) {
    throw new OverlayGeneratorError("unsafe_path", "output parent directory is unavailable");
  }
  if (existsSync(resolvedOutput) && lstatSync(resolvedOutput).isSymbolicLink()) {
    throw new OverlayGeneratorError("unsafe_path", "output must not replace a symbolic link");
  }
  return resolvedOutput;
}

function atomicWrite(outputPath, contents) {
  const temporary = `${outputPath}.tmp-${process.pid}-${randomBytes(6).toString("hex")}`;
  let descriptor;
  try {
    descriptor = openSync(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
    writeFileSync(descriptor, contents, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporary, outputPath);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    rmSync(temporary, {force: true});
  }
}

function generate(argumentsList) {
  const allowed = new Set([
    "--agent-id",
    "--context",
    "--output",
    "--permission-profile",
    "--roster",
    "--workload-tier",
  ]);
  const options = parseOptions(argumentsList, allowed);
  const rosterPath = requireOption(options, "--roster");
  const contextPath = requireOption(options, "--context");
  const agentID = requireOption(options, "--agent-id");
  const runtimeValidators = validators();
  const roster = requireValid(
    runtimeValidators.roster,
    readBoundedJson(resolve(rosterPath), MAX_ROSTER_BYTES, "agent roster"),
    "agent roster",
  );
  validateRosterDigest(roster);
  const agent = selectAgent(roster, agentID);
  const context = requireValid(
    runtimeValidators.context,
    readBoundedJson(resolve(contextPath), MAX_CONTEXT_BYTES, "interface context"),
    "interface context",
  );
  const workloadTier = options["--workload-tier"] || agent.workload_tier;
  if (!["simple", "standard", "thinking"].includes(workloadTier)) {
    throw new OverlayGeneratorError("invalid_arguments", "workload tier must be simple, standard, or thinking");
  }
  const document = createOverlayDocument({
    roster,
    agent,
    workloadTier,
    context,
    permissionProfile: options["--permission-profile"],
  });
  requireValid(runtimeValidators.overlay, document, "OpenCode launch overlay");
  const contents = `${canonicalJson(document)}\n`;
  if (options["--output"]) {
    const outputPath = validateOutputPath(options["--output"], [rosterPath, contextPath]);
    atomicWrite(outputPath, contents);
  } else {
    process.stdout.write(contents);
  }
  return 0;
}

function validate(argumentsList) {
  const options = parseOptions(
    argumentsList,
    new Set(["--agents-dir", "--overlay", "--permission-profile"]),
  );
  const overlayPath = requireOption(options, "--overlay");
  const agentsDirectory = resolve(options["--agents-dir"] || CANONICAL_AGENTS_DIRECTORY);
  const document = readBoundOverlay(overlayPath, agentsDirectory);
  if (options["--permission-profile"]
    && document.permission_profile !== options["--permission-profile"]) {
    throw new OverlayGeneratorError("invalid_document", "OpenCode launch overlay uses the wrong permission profile");
  }
  process.stdout.write(`${document.overlay_digest}\n`);
  return 0;
}

function prepareConfig(argumentsList) {
  const options = parseOptions(argumentsList, new Set(["--agents-dir", "--output", "--overlay"]));
  const overlayPath = requireOption(options, "--overlay");
  const outputPath = requireOption(options, "--output");
  const agentsDirectory = resolve(options["--agents-dir"] || CANONICAL_AGENTS_DIRECTORY);
  readBoundOverlay(overlayPath, agentsDirectory);
  const pluginEntry = realpathSync(join(
    agentsDirectory,
    "plugins",
    "opencode-aidevops",
    "index.mjs",
  ));
  const pluginMetadata = lstatSync(pluginEntry);
  if (!pluginMetadata.isFile() || pluginMetadata.isSymbolicLink()) {
    throw new OverlayGeneratorError("unsafe_path", "canonical conversation plugin entry is unavailable");
  }
  const config = conversationBootstrapConfig(pathToFileURL(pluginEntry).href);
  const resolvedOutput = validateOutputPath(outputPath, [overlayPath]);
  atomicWrite(resolvedOutput, `${canonicalJson(config)}\n`);
  return 0;
}

function validateProjectRoot(argumentsList) {
  const options = parseOptions(argumentsList, new Set(["--dir", "--repos"]));
  const requestedDirectory = requireOption(options, "--dir");
  const reposPath = requireOption(options, "--repos");
  const candidate = validateRegisteredProjectRoot({requestedDirectory, reposPath});
  process.stdout.write(`${candidate}\n`);
  return 0;
}

function verifyEffectiveConfig(argumentsList) {
  const options = parseOptions(argumentsList, new Set(["--overlay"]));
  const overlayPath = requireOption(options, "--overlay");
  const document = readBoundOverlay(overlayPath, CANONICAL_AGENTS_DIRECTORY);
  const input = readFileSync(0, "utf8");
  if (Buffer.byteLength(input, "utf8") > MAX_EFFECTIVE_CONFIG_BYTES) {
    throw new OverlayGeneratorError("document_too_large", "effective OpenCode config exceeds its size limit");
  }
  let config;
  try {
    config = JSON.parse(input);
  } catch {
    throw new OverlayGeneratorError("runtime_incompatible", "effective OpenCode config is not complete JSON");
  }

  const pluginUrl = pathToFileURL(realpathSync(join(
    CANONICAL_AGENTS_DIRECTORY,
    "plugins",
    "opencode-aidevops",
    "index.mjs",
  ))).href;
  verifyConversationEffectiveConfig(config, document, {pluginUrl});
  process.stdout.write(`${document.overlay_digest}\n`);
  return 0;
}

function usage() {
  process.stdout.write([
    "Usage:",
    "  team-interface-opencode-overlay.mjs generate --roster FILE --agent-id ID --context FILE [--workload-tier TIER] [--permission-profile PROFILE] [--output FILE]",
    "  team-interface-opencode-overlay.mjs validate --overlay FILE [--agents-dir DIR]",
    "  team-interface-opencode-overlay.mjs prepare-config --overlay FILE --output FILE [--agents-dir DIR]",
    "  team-interface-opencode-overlay.mjs validate-project-root --dir PATH --repos FILE",
    "  opencode debug config | team-interface-opencode-overlay.mjs verify-effective --overlay FILE",
    "",
  ].join("\n"));
  return 0;
}

const COMMAND_HANDLERS = Object.freeze({
  "--help": usage,
  "-h": usage,
  generate,
  help: usage,
  "prepare-config": prepareConfig,
  validate,
  "validate-project-root": validateProjectRoot,
  "verify-effective": verifyEffectiveConfig,
});

export function main(argv = process.argv.slice(2)) {
  const [command = "help", ...argumentsList] = argv;
  const handler = Object.hasOwn(COMMAND_HANDLERS, command)
    ? COMMAND_HANDLERS[command]
    : undefined;
  if (!handler) throw new OverlayGeneratorError("invalid_arguments", `unsupported command: ${command}`);
  return handler(argumentsList);
}

if (process.argv[1]
  && realpathSync(resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    process.exitCode = main();
  } catch (error) {
    const known = error instanceof OverlayGeneratorError
      || error instanceof ProjectRootValidationError
      || error instanceof TeamInterfaceError
      || error?.name === "ConversationOverlayError";
    const message = known ? error.message : "unexpected validation failure";
    process.stderr.write(`team-interface-opencode-overlay: ${message}\n`);
    process.exitCode = 1;
  }
}
