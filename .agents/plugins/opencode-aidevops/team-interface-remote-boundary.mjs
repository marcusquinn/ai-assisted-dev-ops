// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {lstatSync, readFileSync, realpathSync} from "node:fs";
import {isAbsolute, join, resolve} from "node:path";

import {ConversationOverlayError} from "./team-interface-overlay-contract.mjs";

const FORBIDDEN_ENVIRONMENT = [
  "BUZZ_PRIVATE_KEY",
  "NOSTR_PRIVATE_KEY",
  "BUZZ_AUTH_TAG",
  "BUZZ_API_TOKEN",
  "BUZZ_ACP_PRIVATE_KEY",
  "BUZZ_ACP_API_TOKEN",
  "BUZZ_RELAY_URL",
  "OPENCODE_CONFIG",
  "OPENCODE_CONFIG_CONTENT",
  "OPENCODE_CONFIG_DIR",
  "OPENCODE_DISABLE_AUTOCOMPACT",
  "OPENCODE_DISABLE_DEFAULT_PLUGINS",
  "OPENCODE_DISABLE_PROJECT_CONFIG",
  "OPENCODE_MODEL",
  "OPENCODE_PURE",
];

function requireDirectory(directoryPath, label) {
  if (!isAbsolute(directoryPath || "")) {
    throw new ConversationOverlayError("invalid_environment", `${label} must be absolute`);
  }
  const metadata = lstatSync(directoryPath);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new ConversationOverlayError("unsafe_path", `${label} must be a non-symlink directory`);
  }
  const canonicalPath = realpathSync(directoryPath);
  if (canonicalPath !== resolve(directoryPath)) {
    throw new ConversationOverlayError("unsafe_path", `${label} must already be canonical`);
  }
  return canonicalPath;
}

function validatePinnedPlugin(agentsDir, pluginEntryPath) {
  const expected = realpathSync(join(resolve(agentsDir), "plugins", "opencode-aidevops", "index.mjs"));
  const actual = realpathSync(pluginEntryPath || "");
  if (actual !== expected) {
    throw new ConversationOverlayError("invalid_environment", "remote interactive plugin is not pinned to the canonical agent bundle");
  }
}

function validateRuntimeAnchor(env, agentsDir) {
  const required = env?.AIDEVOPS_REMOTE_REQUIRE_PINNED_RUNTIME === "1";
  const configured = env?.AIDEVOPS_REMOTE_RUNTIME_ANCHOR || "";
  if (!configured) {
    if (required) {
      throw new ConversationOverlayError("invalid_environment", "remote interactive runtime anchor is required");
    }
    return;
  }
  const anchor = requireDirectory(configured, "remote interactive runtime anchor");
  const anchoredAgents = requireDirectory(join(anchor, "agents"), "anchored agents directory");
  const configuredAgents = requireDirectory(agentsDir, "configured agents directory");
  if (anchoredAgents !== configuredAgents) {
    throw new ConversationOverlayError("invalid_environment", "remote interactive agents do not match the runtime anchor");
  }
  const configHome = requireDirectory(join(anchor, "opencode-config"), "anchored OpenCode config root");
  if (requireDirectory(env?.XDG_CONFIG_HOME, "remote interactive XDG config root") !== configHome) {
    throw new ConversationOverlayError("invalid_environment", "OpenCode config does not match the runtime anchor");
  }
  const markerPath = join(anchor, "buzz-runtime-anchor-v1.json");
  let marker;
  try {
    const metadata = lstatSync(markerPath);
    if (!metadata.isFile() || metadata.isSymbolicLink()) throw new Error("unsafe marker");
    marker = JSON.parse(readFileSync(markerPath, "utf8"));
  } catch {
    throw new ConversationOverlayError("unsafe_path", "remote interactive runtime anchor marker is invalid");
  }
  if (marker?.schema_version !== 2 || marker?.runtime_id !== "aidevops-interactive-v1") {
    throw new ConversationOverlayError("invalid_environment", "remote interactive runtime anchor marker is invalid");
  }
  const digestPattern = /^[a-f0-9]{64}$/;
  for (const name of ["agents_digest", "config_digest", "content_digest"]) {
    if (!digestPattern.test(marker?.[name] || "")) {
      throw new ConversationOverlayError("invalid_environment", "remote interactive runtime anchor marker is invalid");
    }
  }
}

export function validateRemoteInteractiveRuntimeBoundary(
  env,
  agentsDir,
  {pluginEntryPath, repositoryDir},
) {
  if (env?.AIDEVOPS_SESSION_ORIGIN !== "interactive" || env?.AIDEVOPS_REMOTE_INTERFACE !== "1") {
    throw new ConversationOverlayError("invalid_environment", "remote interactive overlay requires the trusted interactive Buzz origin");
  }
  if (env?.AIDEVOPS_OPENCODE_ISOLATED_DB !== "1") {
    throw new ConversationOverlayError("invalid_environment", "remote interactive OpenCode data isolation is unavailable");
  }
  for (const name of FORBIDDEN_ENVIRONMENT) {
    if (env?.[name]) {
      throw new ConversationOverlayError("invalid_environment", `${name} is forbidden in remote interactive mode`);
    }
  }
  for (const name of Object.keys(env || {})) {
    if (name.startsWith("BUZZ_") || name.startsWith("AIDEVOPS_BUZZ_")) {
      throw new ConversationOverlayError("invalid_environment", "Buzz control-plane environment crossed into OpenCode");
    }
  }
  const expectedProjectRoot = requireDirectory(
    env?.AIDEVOPS_REMOTE_PROJECT_ROOT,
    "remote interactive project root",
  );
  const repositoryRoot = requireDirectory(repositoryDir, "OpenCode repository root");
  if (repositoryRoot !== expectedProjectRoot) {
    throw new ConversationOverlayError("invalid_environment", "OpenCode runtime cwd does not match the remote interactive project root");
  }
  requireDirectory(env?.XDG_DATA_HOME, "remote interactive XDG data root");
  validateRuntimeAnchor(env, agentsDir);
  validatePinnedPlugin(agentsDir, pluginEntryPath);
  return {projectRoot: repositoryRoot};
}
