// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Managed-directory, agent-availability, and public-triage capability guards.

import { appendFileSync, realpathSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { execFileSync } from "child_process";

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

const MANAGED_EXTERNAL_DIRECTORIES = [
  "~/.aidevops",
  "~/.aidevops/**",
  "~/.config/aidevops",
  "~/.config/aidevops/**",
  "~/.config/opencode/command",
  "~/.config/opencode/command/**",
  "~/.config/opencode/skills",
  "~/.config/opencode/skills/**",
  "~/Git/_worktrees",
  "~/Git/_worktrees/**",
  ...[...tempDirectories].sort().flatMap((path) => [path, `${path}/**`]),
];

function addManagedDirectoryRules(target) {
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
  let count = 0;
  for (const path of MANAGED_EXTERNAL_DIRECTORIES) {
    if (rules[path] !== "allow") count++;
    // OpenCode uses the last matching rule, so managed exceptions must follow
    // broad user defaults such as `"*": "ask"`.
    delete rules[path];
    rules[path] = "allow";
  }
  target.permission.external_directory = rules;
  return count;
}

export function registerManagedDirectoryPermissions(config) {
  let count = addManagedDirectoryRules(config);
  for (const agent of Object.values(config.agent || {})) {
    count += addManagedDirectoryRules(agent);
  }
  return count;
}

const PUBLIC_TRIAGE_AGENT_NAME = "triage-review";
const PUBLIC_TRIAGE_SESSION_ORIGIN = "triage";
const PUBLIC_TRIAGE_BUILTIN_AGENTS = ["build", "plan", "general", "explore"];

export function enforcePublicTriageIsolation(
  config,
  sessionOrigin = process.env.AIDEVOPS_SESSION_ORIGIN,
) {
  if (sessionOrigin !== PUBLIC_TRIAGE_SESSION_ORIGIN) return 0;
  if (!config.agent?.[PUBLIC_TRIAGE_AGENT_NAME] || config.agent[PUBLIC_TRIAGE_AGENT_NAME].disable) {
    throw new Error("Public triage agent profile is unavailable");
  }

  config.tools = { "*": false };
  config.permission = { "*": "deny" };
  config.mcp = {};
  config.formatter = false;
  config.lsp = false;
  config.share = "disabled";
  config.subagent_depth = 0;
  config.default_agent = PUBLIC_TRIAGE_AGENT_NAME;

  const triageProfile = config.agent[PUBLIC_TRIAGE_AGENT_NAME];
  config.agent[PUBLIC_TRIAGE_AGENT_NAME] = {
    ...triageProfile,
    mode: "primary",
    tools: { "*": false },
    permission: { "*": "deny" },
  };
  const disabledAgentNames = new Set([
    ...Object.keys(config.agent),
    ...PUBLIC_TRIAGE_BUILTIN_AGENTS,
  ]);
  disabledAgentNames.delete(PUBLIC_TRIAGE_AGENT_NAME);
  for (const agentName of disabledAgentNames) {
    config.agent[agentName] = { disable: true };
  }
  return 1;
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
