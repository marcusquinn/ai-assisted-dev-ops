// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Phase 4: Shell Environment
// Extracted from index.mjs (t1914) — shell env variable injection.
// ---------------------------------------------------------------------------

import { existsSync, readFileSync } from "fs";
import { join } from "path";

/**
 * Read a file if it exists, or return empty string.
 * @param {string} filepath
 * @returns {string}
 */
function readIfExists(filepath) {
  try {
    if (existsSync(filepath)) {
      return readFileSync(filepath, "utf-8").trim();
    }
  } catch {
    // ignore
  }
  return "";
}

/**
 * Return true when the agents directory is usable for deterministic framework
 * file lookups.
 * @param {string} value
 * @returns {boolean}
 */
function hasAgentsDir(value) {
  return typeof value === "string" && value.trim() !== "";
}

/**
 * Extract the current OpenCode session ID from hook input variants.
 * @param {object} input
 * @returns {string}
 */
function getSessionId(input) {
  const candidates = [
    input?.session?.id,
    input?.message?.sessionID,
    input?.sessionID,
    input?.session_id,
    input?.id,
  ];
  return candidates.find((value) => value) || "";
}

function isBareModelId(model) {
  if (typeof model !== "string") {
    return false;
  }
  return !model.includes("/");
}

function modelStringOrEmpty(model) {
  if (typeof model !== "string") {
    return "";
  }
  return model;
}

function getModelValue(input) {
  const candidates = [
    input?.model?.modelID,
    input?.model?.id,
    input?.modelID,
    input?.model,
  ];
  return candidates.find((value) => value) || "";
}

/**
 * Extract the current model ID from hook input variants.
 * @param {object} input
 * @returns {string}
 */
function getModelId(input) {
  const provider = input?.model?.providerID || input?.provider?.id || "";
  const model = getModelValue(input);

  if (!provider) {
    return modelStringOrEmpty(model);
  }
  if (isBareModelId(model)) {
    return `${provider}/${model}`;
  }
  return modelStringOrEmpty(model);
}

/**
 * Extract normalized session/model identity from shell.env or chat.params input.
 * @param {object} input
 * @returns {{ sessionId: string, modelId: string }}
 */
export function sessionModelIdentity(input) {
  return { sessionId: getSessionId(input), modelId: getModelId(input) };
}

/**
 * Create bounded session-scoped model state for hooks that do not receive model
 * metadata directly. Entries are keyed by OpenCode session ID so concurrent
 * sessions cannot inherit one another's signature attribution.
 * @param {number} maxEntries
 * @returns {{ remember: Function, resolve: Function }}
 */
export function createSessionModelStore(maxEntries = 128) {
  const models = new Map();
  const limit = Math.max(1, Number(maxEntries) || 128);
  return {
    remember(sessionId, modelId) {
      if (!sessionId || !modelId) return;
      models.delete(sessionId);
      models.set(sessionId, modelId);
      while (models.size > limit) models.delete(models.keys().next().value);
    },
    resolve(sessionId) {
      return sessionId ? models.get(sessionId) || "" : "";
    },
  };
}

/**
 * Env vars that mark a shell as headless worker context. Shell commands run by
 * an interactive OpenCode TUI may inherit stale worker-origin env from a parent
 * process; the plugin must stamp the intended session origin explicitly so
 * issue/PR creation helpers do not mislabel maintainer-directed work.
 */
const HEADLESS_ENV_VARS = [
  "FULL_LOOP_HEADLESS",
  "AIDEVOPS_HEADLESS",
  "OPENCODE_HEADLESS",
  "GITHUB_ACTIONS",
];

const WORKER_LINEAGE_ENV_VARS = [
  "AIDEVOPS_WORKER_ID",
  "AIDEVOPS_PARENT_WORKER_ID",
  "AIDEVOPS_ROOT_WORKER_ID",
  "AIDEVOPS_CORRELATION_ID",
  "AIDEVOPS_CAUSATION_ID",
  "AIDEVOPS_PARENT_EVENT_ID",
  "AIDEVOPS_ROOT_EVENT_ID",
];

const OTEL_ENV_VARS = [
  "OTEL_EXPORTER_OTLP_ENDPOINT",
  "OTEL_EXPORTER_OTLP_HEADERS",
  "OTEL_EXPORTER_OTLP_PROTOCOL",
  "OTEL_SERVICE_NAME",
  "OTEL_RESOURCE_ATTRIBUTES",
];

/**
 * @param {string | undefined} value
 * @returns {boolean}
 */
function isTruthyEnv(value) {
  return !!value && value !== "0" && value !== "false";
}

/**
 * Determine the origin label intent for shell subprocesses.
 * @param {object} env
 * @returns {"worker" | "interactive"}
 */
function shellSessionOrigin(env) {
  const headless = HEADLESS_ENV_VARS.some((key) =>
    isTruthyEnv(env?.[key] || process.env[key]),
  );
  return headless ? "worker" : "interactive";
}

function prependFrameworkPaths(env, scriptsDir, agentsDir) {
  const binDir = agentsDir ? join(agentsDir, "bin") : "";
  const preferredPaths = [scriptsDir, binDir].filter((path) => path && existsSync(path));
  if (preferredPaths.length === 0) return;
  const currentPath = env.PATH || process.env.PATH || "";
  const pathParts = currentPath
    .split(":")
    .filter((part) => part && !preferredPaths.includes(part));
  env.PATH = [...preferredPaths, ...pathParts].join(":");
}

function projectWorkerLineage(env) {
  const sessionOrigin = shellSessionOrigin(env);
  env.AIDEVOPS_SESSION_ORIGIN = sessionOrigin;
  for (const key of WORKER_LINEAGE_ENV_VARS) {
    if (sessionOrigin !== "worker") {
      delete env[key];
    } else if (!env[key] && process.env[key]) {
      env[key] = process.env[key];
    }
  }
}

function resolveVersion({ activeAgentsDir, agentsDir, precomputedVersion }) {
  if (precomputedVersion) return precomputedVersion;
  const activeVersion = hasAgentsDir(activeAgentsDir)
    ? readIfExists(join(activeAgentsDir, "VERSION"))
    : "";
  if (activeVersion || !hasAgentsDir(agentsDir)) return activeVersion;
  return readIfExists(join(agentsDir, "VERSION")) ||
    readIfExists(join(agentsDir, "..", "VERSION")) ||
    readIfExists(join(agentsDir, "..", "version"));
}

function projectFrameworkEnvironment(env, config) {
  env.AIDEVOPS_AGENTS_DIR = config.agentsDir;
  if (hasAgentsDir(config.activeAgentsDir)) {
    env.AIDEVOPS_ACTIVE_AGENTS_DIR = config.activeAgentsDir;
  }
  env.AIDEVOPS_WORKSPACE_DIR = config.workspaceDir;
  projectWorkerLineage(env);

  const version = resolveVersion(config);
  if (version) env.AIDEVOPS_VERSION = version;
}

function projectSessionIdentity(input, env, onSessionIdentity) {
  const { sessionId, modelId } = sessionModelIdentity(input);
  if (sessionId) {
    env.OPENCODE_SESSION_ID = sessionId;
    env.AIDEVOPS_OPENCODE_SESSION_ID = sessionId;
  }

  if (modelId && !env.AIDEVOPS_SIG_MODEL) env.AIDEVOPS_SIG_MODEL = modelId;
  if (sessionId && env.AIDEVOPS_SIG_MODEL) {
    onSessionIdentity(sessionId, env.AIDEVOPS_SIG_MODEL);
  }
}

function projectOtelEnvironment(env) {
  for (const key of OTEL_ENV_VARS) {
    const value = process.env[key];
    if (value && !env[key]) env[key] = value;
  }
}

function normalizeDependencies(deps) {
  const {
    activeAgentsDir = "",
    agentsDir = "",
    scriptsDir = "",
    workspaceDir = "",
    version,
    onSessionIdentity,
  } = deps || {};
  return {
    activeAgentsDir,
    agentsDir,
    scriptsDir,
    workspaceDir,
    precomputedVersion: typeof version === "string" ? version.trim() : "",
    onSessionIdentity: typeof onSessionIdentity === "function" ? onSessionIdentity : () => {},
  };
}

async function shellEnvHook(config, input, output) {
  prependFrameworkPaths(output.env, config.scriptsDir, config.agentsDir);
  projectFrameworkEnvironment(output.env, config);
  projectSessionIdentity(input, output.env, config.onSessionIdentity);
  projectOtelEnvironment(output.env);
}

/**
 * Create the shell environment hook.
 * @param {object} deps - { activeAgentsDir?, agentsDir, scriptsDir, workspaceDir, version?, onSessionIdentity? }
 * @returns {Function} Shell env hook function
 */
export function createShellEnvHook(deps) {
  return shellEnvHook.bind(null, normalizeDependencies(deps));
}
