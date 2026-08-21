// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Managed-directory, agent-availability, and public-triage capability guards.

import { appendFileSync, realpathSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { execFileSync } from "child_process";
import {
  applyRemoteInteractiveAgentSelection,
  conversationPermissions,
  conversationTools,
  isRestrictedConversation,
  restrictedConversationAgentMap,
} from "./team-interface-context.mjs";

const tempDirectories = new Set();

function addTempDirectory(path) {
  const normalized = path.replace(/\/+$/, "");
  if (!normalized) return;
  tempDirectories.add(normalized);
  try {
    tempDirectories.add(realpathSync(normalized));
  } catch {
    // The unresolved path remains a valid, least-privilege fallback.
  }
}

addTempDirectory(tmpdir());
if (process.platform === "darwin") {
  try {
    const darwinTemp = execFileSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim();
    addTempDirectory(darwinTemp);
  } catch {
    // The configured tmpdir() remains available when getconf is unavailable.
  }
}

const STABLE_MANAGED_EXTERNAL_DIRECTORIES = [
  "~/.aidevops",
  "~/.aidevops/**",
  "~/.config/aidevops",
  "~/.config/aidevops/**",
  "~/.config/opencode/command",
  "~/.config/opencode/command/**",
  "~/.config/opencode/skills",
  "~/.config/opencode/skills/**",
];

function safeRuntimeManagedDirectory(value) {
  if (typeof value !== "string") return "";
  const normalized = value.replace(/\/+$/, "");
  if (!normalized.startsWith("/") || normalized === "/") return "";
  if (/[*?\n\r\0]/.test(normalized)) return "";
  return normalized;
}

function runtimeManagedExternalDirectories(env) {
  const promptDir = safeRuntimeManagedDirectory(env.AIDEVOPS_HEADLESS_PROMPT_DIR);
  return promptDir ? [promptDir, `${promptDir}/**`] : [];
}

export function managedExternalDirectories(env = process.env) {
  const isConfigured = Object.hasOwn(env, "AIDEVOPS_WORKTREE_BASE_DIR");
  const configured = env.AIDEVOPS_WORKTREE_BASE_DIR;
  const worktreeBase = isConfigured ? configured.replace(/\/+$/, "") : "~/Git/_worktrees";
  if (isConfigured && (!worktreeBase.startsWith("/") || worktreeBase === "/")) {
    throw new TypeError("AIDEVOPS_WORKTREE_BASE_DIR must be a non-root absolute path");
  }
  return [
    ...STABLE_MANAGED_EXTERNAL_DIRECTORIES,
    worktreeBase,
    `${worktreeBase}/**`,
    ...runtimeManagedExternalDirectories(env),
    ...[...tempDirectories].sort().flatMap((path) => [path, `${path}/**`]),
  ];
}

function addManagedDirectoryRules(target, env) {
  if (typeof target.permission === "string") {
    const defaultPermission = target.permission;
    target.permission = {
      "*": defaultPermission,
      external_directory: { "*": defaultPermission },
    };
  } else if (!target.permission) {
    target.permission = {};
  }

  const existing = target.permission.external_directory;
  if (existing === "allow") return 0;

  const rules = typeof existing === "string"
    ? { "*": existing }
    : { ...existing };
  const configuredWorktreeBase = managedExternalDirectories(env)[STABLE_MANAGED_EXTERNAL_DIRECTORIES.length];
  if (configuredWorktreeBase !== "~/Git/_worktrees") {
    delete rules["~/Git/_worktrees"];
    delete rules["~/Git/_worktrees/**"];
  }
  let count = 0;
  for (const path of managedExternalDirectories(env)) {
    if (rules[path] !== "allow") count++;
    // OpenCode uses the last matching rule, so managed exceptions must follow
    // broad user defaults such as `"*": "ask"`.
    delete rules[path];
    rules[path] = "allow";
  }
  target.permission.external_directory = rules;
  return count;
}

export function registerManagedDirectoryPermissions(config, env = process.env) {
  let count = addManagedDirectoryRules(config, env);
  for (const agent of Object.values(config.agent || {})) {
    count += addManagedDirectoryRules(agent, env);
  }
  return count;
}

const PUBLIC_TRIAGE_AGENT_NAME = "triage-review";
const PUBLIC_TRIAGE_SESSION_ORIGIN = "triage";
const FOCUSED_RESEARCH_AGENT_NAME = "research-only";
const FOCUSED_RESEARCH_SESSION_ORIGIN = "ai-research";
const PUBLIC_TRIAGE_BUILTIN_AGENTS = ["build", "plan", "general", "explore"];

// Both origins arrive through the triage-grade headless boundary. The origin
// selects the prompt persona only; each resulting profile is inference-only.
export function enforcePublicTriageIsolation(
  config,
  sessionOrigin = process.env.AIDEVOPS_SESSION_ORIGIN,
) {
  const isolatedAgentName = sessionOrigin === PUBLIC_TRIAGE_SESSION_ORIGIN
    ? PUBLIC_TRIAGE_AGENT_NAME
    : sessionOrigin === FOCUSED_RESEARCH_SESSION_ORIGIN
      ? FOCUSED_RESEARCH_AGENT_NAME
      : "";
  if (!isolatedAgentName) return 0;
  if (!config.agent?.[isolatedAgentName] || config.agent[isolatedAgentName].disable) {
    const boundary = sessionOrigin === PUBLIC_TRIAGE_SESSION_ORIGIN
      ? "Public triage"
      : "Focused research";
    throw new Error(`${boundary} agent profile is unavailable`);
  }

  config.tools = { "*": false };
  config.permission = { "*": "deny" };
  config.mcp = {};
  config.formatter = false;
  config.lsp = false;
  config.share = "disabled";
  config.subagent_depth = 0;
  config.default_agent = isolatedAgentName;

  const isolatedProfile = config.agent[isolatedAgentName];
  config.agent[isolatedAgentName] = {
    ...isolatedProfile,
    mode: "primary",
    tools: { "*": false },
    permission: { "*": "deny" },
  };
  const disabledAgentNames = new Set([
    ...Object.keys(config.agent),
    ...PUBLIC_TRIAGE_BUILTIN_AGENTS,
  ]);
  disabledAgentNames.delete(isolatedAgentName);
  for (const agentName of disabledAgentNames) {
    config.agent[agentName] = { disable: true };
  }
  return 1;
}

export function enforceTeamInterfaceConversationIsolation(config, conversation) {
  if (!isRestrictedConversation(conversation)) return 0;

  config.command = {};
  config.tools = conversationTools();
  config.permission = conversationPermissions();
  config.plugin = [conversation.pluginUrl];
  config.instructions = [];
  config.mcp = {};
  config.formatter = false;
  config.lsp = false;
  config.share = "disabled";
  config.snapshot = false;
  config.subagent_depth = 0;
  config.default_agent = conversation.overlay.agent.display_name;
  config.agent = restrictedConversationAgentMap(conversation);
  return 1;
}

export function enforceTeamInterfaceRemoteInteractiveSelection(config, conversation) {
  return applyRemoteInteractiveAgentSelection(config, conversation);
}

export function ensureAgentGuard(config, workspaceDir) {
  const enabledAgents = Object.entries(config.agent).filter(
    ([, value]) => !value.disable,
  );
  if (enabledAgents.length > 0) return;

  if (config.agent.build) {
    delete config.agent.build.disable;
  } else {
    config.agent.build = { description: "Default coding agent" };
  }
  const logPath = join(workspaceDir, "tmp", "plugin-warnings.log");
  try {
    appendFileSync(
      logPath,
      `[${new Date().toISOString()}] WARN: All agents disabled — re-enabled 'build' as fallback to prevent crash\n`,
    );
  } catch {
    // best-effort logging
  }
}
