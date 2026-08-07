// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {execFileSync} from "node:child_process";
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readdirSync,
  readFileSync,
  realpathSync,
} from "node:fs";
import {isAbsolute, join, relative, resolve, sep} from "node:path";
import {pathToFileURL} from "node:url";
import {
  canonicalDigest,
  canonicalJson,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  CONVERSATION_PERMISSION_PROFILE,
  conversationBootstrapConfig,
  conversationConfigEvidence,
  conversationPermissions,
  conversationTools,
  ConversationOverlayError,
  createOverlayDocument,
  parseCanonicalOverlayText,
  sourceFilenameFromReference,
  validateInterfaceContext,
  validateOverlayDocument,
} from "./team-interface-overlay-contract.mjs";

export {
  canonicalDigest,
  canonicalJson,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  CONVERSATION_PERMISSION_PROFILE,
  conversationBootstrapConfig,
  conversationConfigEvidence,
  conversationPermissions,
  conversationTools,
  ConversationOverlayError,
  createOverlayDocument,
  parseCanonicalOverlayText,
  validateInterfaceContext,
  validateOverlayDocument,
};

const BUILTIN_AGENT_NAMES = ["build", "plan", "general", "explore"];
const MAX_OVERLAY_BYTES = 64 * 1024;
const MAX_AGENT_SOURCE_BYTES = 1024 * 1024;
const MAX_ROSTER_BYTES = 1024 * 1024;
const MAX_RUNTIME_CONFIG_BYTES = 256 * 1024;
const MAX_RUNTIME_PACKAGE_BYTES = 4 * 1024 * 1024;
const PYTHON_BINARY = "/usr/bin/python3";
const RUNTIME_CONFIG_ENTRIES = new Set([
  ".gitignore",
  "bun.lock",
  "node_modules",
  "opencode.json",
  "package-lock.json",
  "package.json",
]);
const RUNTIME_CONFIG_GITIGNORE = "node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore";
const ROSTER_KEYS = ["agents", "document_type", "roster_digest", "roster_id", "schema_version"];
const ROSTER_AGENT_KEYS = [
  "agent_id",
  "description",
  "display_name",
  "kind",
  "source_digest",
  "source_ref",
  "workload_tier",
];
const SELECTED_AGENT_KEYS = ["agent_id", "display_name", "kind", "source_digest", "source_ref"];

function readBoundedRegularFile(filePath, maximumBytes, label) {
  const absolutePath = resolve(filePath);
  let before;
  try {
    before = lstatSync(absolutePath);
  } catch {
    throw new ConversationOverlayError("missing_document", `${label} is unavailable`);
  }
  if (!before.isFile() || before.isSymbolicLink()) {
    throw new ConversationOverlayError("unsafe_path", `${label} must be a regular non-symlink file`);
  }
  if (before.size > maximumBytes) {
    throw new ConversationOverlayError("document_too_large", `${label} exceeds its size limit`);
  }

  let descriptor;
  try {
    descriptor = openSync(absolutePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    const opened = fstatSync(descriptor);
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino) {
      throw new ConversationOverlayError("unsafe_path", `${label} changed while it was opened`);
    }
    const bytes = readFileSync(descriptor);
    if (bytes.length > maximumBytes) {
      throw new ConversationOverlayError("document_too_large", `${label} exceeds its size limit`);
    }
    const after = lstatSync(absolutePath);
    if (!after.isFile() || after.isSymbolicLink() || after.dev !== opened.dev || after.ino !== opened.ino) {
      throw new ConversationOverlayError("unsafe_path", `${label} changed while it was read`);
    }
    return {absolutePath, bytes, contents: bytes.toString("utf8")};
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

export function readCanonicalOverlayFile(filePath) {
  if (!isAbsolute(filePath || "")) {
    throw new ConversationOverlayError("unsafe_path", "OpenCode launch overlay path must be absolute");
  }
  const {absolutePath, contents} = readBoundedRegularFile(filePath, MAX_OVERLAY_BYTES, "OpenCode launch overlay");
  return {absolutePath, document: parseCanonicalOverlayText(contents)};
}

function requireExactObjectKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ConversationOverlayError("invalid_document", `${label} must be an object`);
  }
  if (canonicalJson(Object.keys(value).sort()) !== canonicalJson([...expected].sort())) {
    throw new ConversationOverlayError("invalid_document", `${label} contains missing or unsupported fields`);
  }
}

function validateCanonicalRoster(roster) {
  requireExactObjectKeys(roster, ROSTER_KEYS, "canonical agent roster");
  if (
    roster.schema_version !== 1
    || roster.document_type !== "agent_roster"
    || roster.roster_id !== "agent-roster.aidevops"
    || !Array.isArray(roster.agents)
    || roster.agents.length < 2
  ) {
    throw new ConversationOverlayError("invalid_roster", "canonical agent roster structure is invalid");
  }
  const unsigned = structuredClone(roster);
  delete unsigned.roster_digest;
  if (roster.roster_digest !== canonicalDigest(unsigned)) {
    throw new ConversationOverlayError("digest_mismatch", "canonical agent roster digest is invalid");
  }
  const ids = new Set();
  let guideCount = 0;
  for (const agent of roster.agents) {
    requireExactObjectKeys(agent, ROSTER_AGENT_KEYS, "canonical roster agent");
    if (ids.has(agent.agent_id)) {
      throw new ConversationOverlayError("invalid_roster", "canonical agent roster contains duplicate IDs");
    }
    ids.add(agent.agent_id);
    if (agent.kind === "framework_guide") guideCount += 1;
  }
  if (guideCount !== 1) {
    throw new ConversationOverlayError("invalid_roster", "canonical agent roster must contain one framework guide");
  }
  return roster;
}

export function loadCanonicalAgentRoster(agentsDir) {
  const rosterScript = join(resolve(agentsDir), "scripts", "team-interface-agent-roster.py");
  let scriptMetadata;
  try {
    scriptMetadata = lstatSync(rosterScript);
  } catch {
    throw new ConversationOverlayError("missing_document", "canonical agent roster generator is unavailable");
  }
  if (!scriptMetadata.isFile() || scriptMetadata.isSymbolicLink()) {
    throw new ConversationOverlayError("unsafe_path", "canonical agent roster generator is not a regular file");
  }

  let output;
  try {
    output = execFileSync(
      PYTHON_BINARY,
      ["-I", "-B", rosterScript, "--agents-dir", resolve(agentsDir)],
      {
        encoding: "utf8",
        env: {PATH: "/usr/bin:/bin", PYTHONNOUSERSITE: "1"},
        maxBuffer: MAX_ROSTER_BYTES,
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 15000,
      },
    );
  } catch {
    throw new ConversationOverlayError("invalid_roster", "canonical agent roster generation failed");
  }

  let roster;
  try {
    roster = JSON.parse(output);
  } catch {
    throw new ConversationOverlayError("invalid_roster", "canonical agent roster output is invalid JSON");
  }
  return validateCanonicalRoster(roster);
}

export function bindOverlayToCanonicalRoster(document, canonicalRoster) {
  const roster = validateCanonicalRoster(canonicalRoster);
  if (document.roster_digest !== roster.roster_digest) {
    throw new ConversationOverlayError("roster_mismatch", "OpenCode launch overlay does not bind to the current canonical roster");
  }
  const matches = roster.agents.filter(({agent_id: agentID}) => agentID === document.agent.agent_id);
  if (matches.length !== 1) {
    throw new ConversationOverlayError("unknown_agent", "selected overlay agent is not uniquely present in the canonical roster");
  }
  const selected = Object.fromEntries(
    SELECTED_AGENT_KEYS.map((key) => [key, matches[0][key]]),
  );
  if (canonicalJson(selected) !== canonicalJson(document.agent)) {
    throw new ConversationOverlayError("agent_mismatch", "selected overlay agent does not match its canonical roster entry");
  }
  return matches[0];
}

function readVerifiedAgentSource(agentsDir, agent) {
  const sourcePath = join(resolve(agentsDir), sourceFilenameFromReference(agent.source_ref));
  const {bytes, contents} = readBoundedRegularFile(sourcePath, MAX_AGENT_SOURCE_BYTES, "selected agent source");
  const sourceDigest = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
  if (sourceDigest !== agent.source_digest) {
    throw new ConversationOverlayError("digest_mismatch", "selected agent source digest no longer matches the overlay");
  }
  return contents;
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  for (const child of Object.values(value)) deepFreeze(child);
  return Object.freeze(value);
}

function isPathWithin(base, candidate) {
  const remainder = relative(base, candidate);
  return remainder === ""
    || (!isAbsolute(remainder) && remainder !== ".." && !remainder.startsWith(`..${sep}`));
}

function requirePrivateDirectory(directoryPath, label) {
  if (!isAbsolute(directoryPath || "")) {
    throw new ConversationOverlayError("invalid_environment", `${label} must be absolute`);
  }
  let metadata;
  try {
    metadata = lstatSync(directoryPath);
  } catch {
    throw new ConversationOverlayError("invalid_environment", `${label} is unavailable`);
  }
  if (!metadata.isDirectory() || metadata.isSymbolicLink() || (metadata.mode & 0o077) !== 0) {
    throw new ConversationOverlayError("unsafe_path", `${label} must be a private non-symlink directory`);
  }
  const canonicalPath = realpathSync(directoryPath);
  if (canonicalPath !== resolve(directoryPath)) {
    throw new ConversationOverlayError("unsafe_path", `${label} must not traverse symbolic links`);
  }
  return canonicalPath;
}

function requireEnvironmentValue(env, name, expected) {
  if (env?.[name] !== expected) {
    throw new ConversationOverlayError("invalid_environment", `${name} does not match the restricted conversation runtime`);
  }
}

function readRuntimeJson(filePath, maximumBytes, label) {
  const {contents} = readBoundedRegularFile(filePath, maximumBytes, label);
  try {
    return JSON.parse(contents);
  } catch {
    throw new ConversationOverlayError("invalid_environment", `${label} is invalid JSON`);
  }
}

function validateRuntimeManagedConfig(configDirectory) {
  const entries = readdirSync(configDirectory).sort();
  if (entries.some((entry) => !RUNTIME_CONFIG_ENTRIES.has(entry))) {
    throw new ConversationOverlayError("unsafe_effective_config", "conversation config directory contains unsupported entries");
  }
  const generatedEntries = entries.filter((entry) => entry !== "opencode.json");
  if (generatedEntries.length === 0) return;
  for (const required of [".gitignore", "node_modules", "package.json"]) {
    if (!entries.includes(required)) {
      throw new ConversationOverlayError("runtime_incompatible", "OpenCode runtime package metadata is incomplete");
    }
  }

  const gitignore = readBoundedRegularFile(
    join(configDirectory, ".gitignore"),
    MAX_RUNTIME_CONFIG_BYTES,
    "OpenCode runtime gitignore",
  ).contents.trimEnd();
  if (gitignore !== RUNTIME_CONFIG_GITIGNORE) {
    throw new ConversationOverlayError("unsafe_effective_config", "OpenCode runtime gitignore contains unsupported entries");
  }
  const packageDocument = readRuntimeJson(
    join(configDirectory, "package.json"),
    MAX_RUNTIME_CONFIG_BYTES,
    "OpenCode runtime package metadata",
  );
  requireExactObjectKeys(packageDocument, ["dependencies"], "OpenCode runtime package metadata");
  requireExactObjectKeys(
    packageDocument.dependencies,
    ["@opencode-ai/plugin"],
    "OpenCode runtime package dependencies",
  );
  const pluginVersion = packageDocument.dependencies["@opencode-ai/plugin"];
  if (typeof pluginVersion !== "string" || !/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u.test(pluginVersion)) {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode runtime plugin dependency is invalid");
  }

  const nodeModules = join(configDirectory, "node_modules");
  const nodeModulesMetadata = lstatSync(nodeModules);
  if (
    !nodeModulesMetadata.isDirectory()
    || nodeModulesMetadata.isSymbolicLink()
    || realpathSync(nodeModules) !== resolve(nodeModules)
  ) {
    throw new ConversationOverlayError("unsafe_path", "OpenCode runtime dependencies are not a local directory");
  }
  const installedPlugin = readRuntimeJson(
    join(nodeModules, "@opencode-ai", "plugin", "package.json"),
    MAX_RUNTIME_CONFIG_BYTES,
    "installed OpenCode plugin metadata",
  );
  if (installedPlugin.version !== pluginVersion) {
    throw new ConversationOverlayError("runtime_incompatible", "installed OpenCode plugin version does not match runtime metadata");
  }

  if (entries.includes("package-lock.json")) {
    const lockDocument = readRuntimeJson(
      join(configDirectory, "package-lock.json"),
      MAX_RUNTIME_PACKAGE_BYTES,
      "OpenCode runtime package lock",
    );
    if (canonicalJson(lockDocument.packages?.[""]?.dependencies) !== canonicalJson(packageDocument.dependencies)) {
      throw new ConversationOverlayError("unsafe_effective_config", "OpenCode runtime package lock contains unsupported root dependencies");
    }
  }
  if (entries.includes("bun.lock")) {
    readBoundedRegularFile(
      join(configDirectory, "bun.lock"),
      MAX_RUNTIME_PACKAGE_BYTES,
      "OpenCode runtime Bun lock",
    );
  }
}

function validateConversationRuntimeBoundary(env, agentsDir, {pluginEntryPath, repositoryDir}) {
  const runtimeRoot = requirePrivateDirectory(
    env?.AIDEVOPS_CONVERSATION_RUNTIME_ROOT,
    "conversation runtime root",
  );
  const expectedDirectories = {
    AIDEVOPS_TEMP_DIR: join(runtimeRoot, "tmp"),
    HOME: join(runtimeRoot, "home"),
    XDG_CACHE_HOME: join(runtimeRoot, "cache"),
    XDG_CONFIG_HOME: join(runtimeRoot, "config"),
    XDG_STATE_HOME: join(runtimeRoot, "state"),
  };
  for (const [name, expectedPath] of Object.entries(expectedDirectories)) {
    const canonicalPath = requirePrivateDirectory(env?.[name], name);
    if (canonicalPath !== expectedPath) {
      throw new ConversationOverlayError("invalid_environment", `${name} escapes the private conversation runtime`);
    }
  }
  const dataRoot = requirePrivateDirectory(env?.XDG_DATA_HOME, "XDG_DATA_HOME");
  if (dataRoot !== join(runtimeRoot, "data")) {
    throw new ConversationOverlayError("invalid_environment", "XDG_DATA_HOME escapes the private conversation runtime");
  }

  const configDirectory = join(runtimeRoot, "config", "opencode");
  const configFile = join(configDirectory, "opencode.json");
  requirePrivateDirectory(configDirectory, "conversation config directory");
  requireEnvironmentValue(env, "OPENCODE_CONFIG_DIR", configDirectory);
  requireEnvironmentValue(env, "OPENCODE_CONFIG", configFile);
  for (const name of [
    "OPENCODE_DISABLE_AUTOCOMPACT",
    "OPENCODE_DISABLE_AUTOUPDATE",
    "OPENCODE_DISABLE_CLAUDE_CODE",
    "OPENCODE_DISABLE_CLAUDE_CODE_PROMPT",
    "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS",
    "OPENCODE_DISABLE_DEFAULT_PLUGINS",
    "OPENCODE_DISABLE_EXTERNAL_SKILLS",
    "OPENCODE_DISABLE_LSP_DOWNLOAD",
    "OPENCODE_DISABLE_MODELS_FETCH",
    "OPENCODE_DISABLE_PROJECT_CONFIG",
    "OPENCODE_DISABLE_SHARE",
  ]) {
    requireEnvironmentValue(env, name, "1");
  }
  requireEnvironmentValue(env, "AIDEVOPS_OPENCODE_ISOLATED_DB", "1");
  for (const name of [
    "AIDEVOPS_SIG_MODEL",
    "BUZZ_ACP_MODEL",
    "OPENCODE_CONFIG_CONTENT",
    "OPENCODE_MODEL",
    "OPENCODE_PURE",
    "OPENCODE_SERVER_PASSWORD",
    "OPENCODE_SERVER_USERNAME",
  ]) {
    if (env?.[name]) {
      throw new ConversationOverlayError("invalid_environment", `${name} is forbidden in restricted conversation mode`);
    }
  }

  if (!pluginEntryPath) {
    throw new ConversationOverlayError("runtime_incompatible", "conversation plugin entry is unavailable");
  }
  const expectedPluginPath = realpathSync(
    join(resolve(agentsDir), "plugins", "opencode-aidevops", "index.mjs"),
  );
  const loadedPluginPath = realpathSync(pluginEntryPath);
  if (loadedPluginPath !== expectedPluginPath) {
    throw new ConversationOverlayError("invalid_environment", "conversation plugin is not pinned to the canonical agent bundle");
  }
  const pluginUrl = pathToFileURL(loadedPluginPath).href;
  const {contents} = readBoundedRegularFile(
    configFile,
    MAX_RUNTIME_CONFIG_BYTES,
    "conversation runtime config",
  );
  const expectedConfigText = `${canonicalJson(conversationBootstrapConfig(pluginUrl))}\n`;
  if (contents !== expectedConfigText) {
    throw new ConversationOverlayError("unsafe_effective_config", "conversation runtime config contains untrusted plugins, instructions, or commands");
  }
  validateRuntimeManagedConfig(configDirectory);

  if (!repositoryDir || !env?.AIDEVOPS_CONVERSATION_PROJECT_ROOT) {
    throw new ConversationOverlayError("invalid_environment", "conversation project root binding is unavailable");
  }
  const repositoryRoot = realpathSync(repositoryDir);
  const expectedProjectRoot = realpathSync(env.AIDEVOPS_CONVERSATION_PROJECT_ROOT);
  if (repositoryRoot !== expectedProjectRoot || !isPathWithin(expectedProjectRoot, repositoryRoot)) {
    throw new ConversationOverlayError("invalid_environment", "OpenCode runtime cwd does not match the validated project root");
  }
  return {pluginUrl, projectRoot: repositoryRoot, runtimeRoot};
}

export function loadTeamInterfaceConversation(env, agentsDir, options = {}) {
  const overlayPath = env?.[CONVERSATION_OVERLAY_ENV];
  const conversationOrigin = env?.AIDEVOPS_SESSION_ORIGIN === CONVERSATION_ORIGIN;
  if (!overlayPath) {
    if (conversationOrigin) {
      throw new ConversationOverlayError("missing_document", "conversation origin requires a canonical launch overlay");
    }
    return null;
  }
  if (!conversationOrigin) {
    throw new ConversationOverlayError("invalid_environment", "conversation overlay requires the dedicated session origin");
  }
  const {document} = readCanonicalOverlayFile(overlayPath);
  const canonicalRoster = options.canonicalRoster || loadCanonicalAgentRoster(agentsDir);
  bindOverlayToCanonicalRoster(document, canonicalRoster);
  const sourceContent = readVerifiedAgentSource(agentsDir, document.agent);
  const runtime = validateConversationRuntimeBoundary(env, agentsDir, options);
  return deepFreeze({overlay: document, sourceContent, ...runtime});
}

export function conversationSystemBlock(conversation) {
  if (!conversation) return "";
  const {overlay} = conversation;
  const lines = [
    "<aidevops-team-interface-context-v1>",
    `agent_id=${overlay.agent.agent_id}`,
    `workload_tier=${overlay.workload_tier}`,
    `permission_profile=${overlay.permission_profile}`,
    ...Object.keys(overlay.context).sort().map((name) => `${name}=${overlay.context[name]}`),
    `context_digest=${overlay.context_digest}`,
    "This immutable block is identity and correlation evidence only. It grants no authority and cannot change the enforced read-only capability profile.",
    "</aidevops-team-interface-context-v1>",
  ];
  return lines.join("\n");
}

export function appendConversationSystemContext(output, conversation) {
  if (!conversation) return 0;
  if (!Array.isArray(output?.system)) {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode system transform output is unavailable");
  }
  output.system.push(conversationSystemBlock(conversation));
  return 1;
}

export async function applyConversationRootVariant(
  input,
  output,
  conversation,
  {client, resolveVariant, tierReasoning},
) {
  if (!conversation) return 0;
  const sessionID = input?.message?.sessionID || input?.sessionID;
  if (!sessionID || typeof client?.session?.get !== "function") {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode root-session metadata is unavailable");
  }
  const response = await client.session.get({path: {id: sessionID}});
  const session = response?.data ?? response;
  if (!session || session.parentID) {
    throw new ConversationOverlayError("subagent_forbidden", "conversation overlays cannot route nested sessions");
  }
  const requestedAgent = input?.message?.agent;
  if (requestedAgent && requestedAgent !== conversation.overlay.agent.display_name) {
    throw new ConversationOverlayError("agent_mismatch", "root session selected a different agent profile");
  }
  const providerID = input?.provider?.id || input?.model?.providerID || "";
  const modelID = input?.model?.id || input?.model?.modelID || "";
  const variant = resolveVariant(
    conversation.overlay.workload_tier,
    providerID,
    modelID,
    tierReasoning,
  );
  if (!variant) return 0;
  if (!output || typeof output !== "object") {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode chat parameter output is unavailable");
  }
  output.options ||= {};
  output.options.reasoningEffort = variant;
  if (Object.hasOwn(output.options, "reasoning_effort")) {
    output.options.reasoning_effort = variant;
  }
  return 1;
}

export function restrictedConversationAgentMap(conversation) {
  const {overlay, sourceContent} = conversation;
  const selectedName = overlay.agent.display_name;
  const agents = {
    [selectedName]: {
      description: `Restricted conversation profile for ${overlay.agent.agent_id}`,
      mode: "primary",
      permission: conversationPermissions(),
      prompt: sourceContent,
      tools: conversationTools(),
    },
  };
  for (const name of BUILTIN_AGENT_NAMES) {
    if (name !== selectedName) agents[name] = {disable: true};
  }
  return agents;
}
