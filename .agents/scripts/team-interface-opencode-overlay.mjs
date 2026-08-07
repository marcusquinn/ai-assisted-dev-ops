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
import {homedir} from "node:os";
import {dirname, isAbsolute, join, parse, relative, resolve, sep} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {randomBytes} from "node:crypto";
import {execFileSync} from "node:child_process";
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

const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const SCHEMA_DIRECTORY = resolve(SCRIPT_DIRECTORY, "../schemas/team-interface");
const CANONICAL_AGENTS_DIRECTORY = resolve(SCRIPT_DIRECTORY, "..");
const GIT_BINARY = "/usr/bin/git";
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
  const allowed = new Set(["--agent-id", "--context", "--output", "--roster", "--workload-tier"]);
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
  const document = createOverlayDocument({roster, agent, workloadTier, context});
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
  const options = parseOptions(argumentsList, new Set(["--agents-dir", "--overlay"]));
  const overlayPath = requireOption(options, "--overlay");
  const agentsDirectory = resolve(options["--agents-dir"] || CANONICAL_AGENTS_DIRECTORY);
  const document = readBoundOverlay(overlayPath, agentsDirectory);
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

function hasSymlinkComponent(filePath) {
  const absolutePath = resolve(filePath);
  const root = parse(absolutePath).root;
  let current = root;
  for (const part of absolutePath.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, part);
    if (lstatSync(current).isSymbolicLink()) return true;
  }
  return false;
}

function isPathWithin(base, candidate) {
  const remainder = relative(base, candidate);
  return remainder === ""
    || (!isAbsolute(remainder) && remainder !== ".." && !remainder.startsWith(`..${sep}`));
}

function gitProjectMetadata(projectRoot) {
  try {
    const topLevel = realpathSync(execFileSync(
      GIT_BINARY,
      ["-C", projectRoot, "rev-parse", "--show-toplevel"],
      {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10000},
    ).trim());
    if (topLevel !== projectRoot) return null;
    const commonDirectory = realpathSync(execFileSync(
      GIT_BINARY,
      ["-C", projectRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"],
      {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10000},
    ).trim());
    return {commonDirectory, topLevel};
  } catch {
    return null;
  }
}

function expandedRegisteredPath(value, homeDirectory) {
  if (typeof value !== "string" || !value) return "";
  const expanded = value === "~"
    ? homeDirectory
    : value.startsWith("~/") ? join(homeDirectory, value.slice(2)) : value;
  if (!isAbsolute(expanded) || !existsSync(expanded)) return "";
  try {
    return realpathSync(expanded);
  } catch {
    return "";
  }
}

function rejectSensitiveProjectRoot(candidate, homeDirectory) {
  const sensitiveRoots = [
    join(homeDirectory, ".aws"),
    join(homeDirectory, ".azure"),
    join(homeDirectory, ".config"),
    join(homeDirectory, ".docker"),
    join(homeDirectory, ".gnupg"),
    join(homeDirectory, ".kube"),
    join(homeDirectory, ".local", "share", "opencode"),
    join(homeDirectory, ".ssh"),
  ].map((sensitiveRoot) => resolve(sensitiveRoot));
  if (
    candidate === parse(candidate).root
    || candidate === homeDirectory
    || isPathWithin(candidate, homeDirectory)
    || sensitiveRoots.some((sensitiveRoot) => isPathWithin(sensitiveRoot, candidate))
  ) {
    throw new OverlayGeneratorError("unsafe_path", "restricted conversation cwd is not a bounded project root");
  }
}

function validateProjectRoot(argumentsList) {
  const options = parseOptions(argumentsList, new Set(["--dir", "--repos"]));
  const requestedDirectory = requireOption(options, "--dir");
  const reposPath = requireOption(options, "--repos");
  if (!isAbsolute(requestedDirectory) || hasSymlinkComponent(requestedDirectory)) {
    throw new OverlayGeneratorError("unsafe_path", "restricted conversation cwd must be an absolute non-symlink project root");
  }
  const candidate = realpathSync(requestedDirectory);
  if (!statSync(candidate).isDirectory()) {
    throw new OverlayGeneratorError("unsafe_path", "restricted conversation cwd is not a directory");
  }
  const homeDirectory = realpathSync(homedir());
  rejectSensitiveProjectRoot(candidate, homeDirectory);

  const repos = readBoundedJson(resolve(reposPath), MAX_ROSTER_BYTES, "registered repositories");
  if (!Array.isArray(repos?.initialized_repos)) {
    throw new OverlayGeneratorError("invalid_document", "registered repository metadata is invalid");
  }
  const registeredRoots = repos.initialized_repos
    .map((entry) => expandedRegisteredPath(entry?.path, homeDirectory))
    .filter(Boolean);
  if (registeredRoots.includes(candidate)) {
    process.stdout.write(`${candidate}\n`);
    return 0;
  }

  const candidateGit = gitProjectMetadata(candidate);
  if (candidateGit) {
    const linkedToRegisteredRoot = registeredRoots.some((registeredRoot) => {
      const registeredGit = gitProjectMetadata(registeredRoot);
      return registeredGit?.commonDirectory === candidateGit.commonDirectory;
    });
    if (linkedToRegisteredRoot) {
      process.stdout.write(`${candidate}\n`);
      return 0;
    }
  }
  throw new OverlayGeneratorError("unsafe_path", "restricted conversation cwd is not a registered canonical project or linked worktree root");
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
    "  team-interface-opencode-overlay.mjs generate --roster FILE --agent-id ID --context FILE [--workload-tier TIER] [--output FILE]",
    "  team-interface-opencode-overlay.mjs validate --overlay FILE [--agents-dir DIR]",
    "  team-interface-opencode-overlay.mjs prepare-config --overlay FILE --output FILE [--agents-dir DIR]",
    "  team-interface-opencode-overlay.mjs validate-project-root --dir PATH --repos FILE",
    "  opencode debug config | team-interface-opencode-overlay.mjs verify-effective --overlay FILE",
    "",
  ].join("\n"));
  return 0;
}

export function main(argv = process.argv.slice(2)) {
  const [command = "help", ...argumentsList] = argv;
  if (["help", "--help", "-h"].includes(command)) return usage();
  if (command === "generate") return generate(argumentsList);
  if (command === "validate") return validate(argumentsList);
  if (command === "prepare-config") return prepareConfig(argumentsList);
  if (command === "validate-project-root") return validateProjectRoot(argumentsList);
  if (command === "verify-effective") return verifyEffectiveConfig(argumentsList);
  throw new OverlayGeneratorError("invalid_arguments", `unsupported command: ${command}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main();
  } catch (error) {
    const known = error instanceof OverlayGeneratorError
      || error instanceof TeamInterfaceError
      || error?.name === "ConversationOverlayError";
    const message = known ? error.message : "unexpected validation failure";
    process.stderr.write(`team-interface-opencode-overlay: ${message}\n`);
    process.exitCode = 1;
  }
}
