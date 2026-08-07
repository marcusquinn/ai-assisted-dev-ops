// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {lstatSync, readdirSync, realpathSync} from "node:fs";
import {isAbsolute, join, relative, resolve, sep} from "node:path";
import {pathToFileURL} from "node:url";

import {
  canonicalJson,
  conversationBootstrapConfig,
  ConversationOverlayError,
} from "./team-interface-overlay-contract.mjs";
import {
  readBoundedRegularFile,
  requireExactObjectKeys,
} from "./team-interface-roster-binding.mjs";

const MAX_RUNTIME_CONFIG_BYTES = 256 * 1024;
const MAX_RUNTIME_PACKAGE_BYTES = 4 * 1024 * 1024;
const RUNTIME_CONFIG_ENTRIES = new Set([
  ".gitignore",
  "bun.lock",
  "node_modules",
  "opencode.json",
  "package-lock.json",
  "package.json",
]);
const RUNTIME_CONFIG_GITIGNORE = "node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore";

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
  const unsafeDirectory = [
    !metadata.isDirectory(),
    metadata.isSymbolicLink(),
    (metadata.mode & 0o077) !== 0,
  ].some(Boolean);
  if (unsafeDirectory) {
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

function validateRuntimePluginPackage(configDirectory, packageDocument) {
  requireExactObjectKeys(packageDocument, ["dependencies"], "OpenCode runtime package metadata");
  requireExactObjectKeys(
    packageDocument.dependencies,
    ["@opencode-ai/plugin"],
    "OpenCode runtime package dependencies",
  );
  const pluginVersion = packageDocument.dependencies["@opencode-ai/plugin"];
  const invalidVersion = [
    typeof pluginVersion !== "string",
    !/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/u.test(pluginVersion || ""),
  ].some(Boolean);
  if (invalidVersion) {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode runtime plugin dependency is invalid");
  }

  const nodeModules = join(configDirectory, "node_modules");
  const nodeModulesMetadata = lstatSync(nodeModules);
  const unsafeNodeModules = [
    !nodeModulesMetadata.isDirectory(),
    nodeModulesMetadata.isSymbolicLink(),
    realpathSync(nodeModules) !== resolve(nodeModules),
  ].some(Boolean);
  if (unsafeNodeModules) {
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
}

function validateRuntimePackageLocks(configDirectory, entries, dependencies) {
  if (entries.includes("package-lock.json")) {
    const lockDocument = readRuntimeJson(
      join(configDirectory, "package-lock.json"),
      MAX_RUNTIME_PACKAGE_BYTES,
      "OpenCode runtime package lock",
    );
    if (canonicalJson(lockDocument.packages?.[""]?.dependencies) !== canonicalJson(dependencies)) {
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
  validateRuntimePluginPackage(configDirectory, packageDocument);
  validateRuntimePackageLocks(configDirectory, entries, packageDocument.dependencies);
}

function validatePrivateRuntimeDirectories(env, runtimeRoot) {
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
}

function validateConversationEnvironment(env, runtimeRoot) {
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
  return {configDirectory, configFile};
}

function validatePinnedPlugin(agentsDir, pluginEntryPath, configFile) {
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
  return pluginUrl;
}

function validateProjectBinding(env, repositoryDir) {
  if (!repositoryDir || !env?.AIDEVOPS_CONVERSATION_PROJECT_ROOT) {
    throw new ConversationOverlayError("invalid_environment", "conversation project root binding is unavailable");
  }
  const repositoryRoot = realpathSync(repositoryDir);
  const expectedProjectRoot = realpathSync(env.AIDEVOPS_CONVERSATION_PROJECT_ROOT);
  if (repositoryRoot !== expectedProjectRoot || !isPathWithin(expectedProjectRoot, repositoryRoot)) {
    throw new ConversationOverlayError("invalid_environment", "OpenCode runtime cwd does not match the validated project root");
  }
  return repositoryRoot;
}

export function validateConversationRuntimeBoundary(env, agentsDir, {pluginEntryPath, repositoryDir}) {
  const runtimeRoot = requirePrivateDirectory(
    env?.AIDEVOPS_CONVERSATION_RUNTIME_ROOT,
    "conversation runtime root",
  );
  validatePrivateRuntimeDirectories(env, runtimeRoot);
  const {configDirectory, configFile} = validateConversationEnvironment(env, runtimeRoot);
  const pluginUrl = validatePinnedPlugin(agentsDir, pluginEntryPath, configFile);
  validateRuntimeManagedConfig(configDirectory);
  const projectRoot = validateProjectBinding(env, repositoryDir);
  return {pluginUrl, projectRoot, runtimeRoot};
}
