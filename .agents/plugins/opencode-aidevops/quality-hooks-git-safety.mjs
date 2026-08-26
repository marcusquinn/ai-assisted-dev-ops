// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { classifyFullLoopCommitAndPr } from "./quality-hooks-full-loop-trust.mjs";

export { bindActiveScriptsDir } from "./quality-hooks-full-loop-trust.mjs";

function processIdentity(pid) {
  const psBinary = existsSync("/bin/ps") ? "/bin/ps" : "ps";
  try {
    return execFileSync(
      psBinary,
      ["-p", String(pid), "-o", "lstart="],
      {
        encoding: "utf8",
        env: { ...process.env, LC_ALL: "C", TZ: "UTC" },
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 5000,
      },
    ).trim().replaceAll(/\s+/g, " ");
  } catch {
    return "";
  }
}

const RUNTIME_PROCESS_IDENTITY = processIdentity(process.pid);

function isWorkerContext(env = process.env) {
  if (env.AIDEVOPS_WORKER_ID) return true;
  return [
    "FULL_LOOP_HEADLESS", "AIDEVOPS_HEADLESS", "OPENCODE_HEADLESS",
    "CLAUDE_HEADLESS", "Claude_HEADLESS", "HEADLESS", "GITHUB_ACTIONS",
  ]
    .some((key) => ["1", "true", "yes"].includes((env[key] || "").toLowerCase()));
}

function normaliseToolName(tool) {
  if (typeof tool !== "string") return "";
  return tool
    .replaceAll("::", ".")
    .replaceAll("/", ".")
    .split(".")
    .at(-1)
    .replaceAll("-", "_")
    .toLowerCase();
}

export function isDirectFileMutationTool(tool) {
  return [
    "write", "write_file", "edit", "edit_file", "apply_patch", "applypatch",
  ].includes(normaliseToolName(tool));
}

export function isApplyPatchMutationTool(tool) {
  return ["apply_patch", "applypatch"].includes(normaliseToolName(tool));
}

function parsePolicyPayload(raw) {
  const result = JSON.parse(raw);
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new TypeError("policy returned a non-object payload");
  }
  return result;
}

export function checkCanonicalWriteSafetyGate(
  filePath,
  scriptsDir,
  cwd = process.cwd(),
  patchText = null,
) {
  const helper = join(scriptsDir, "canonical-write-policy-helper.py");
  if (!existsSync(helper)) {
    throw new Error("BLOCKED: required canonical-write policy helper is missing");
  }
  let raw = "";
  try {
    const helperArgs = [
      helper,
      patchText === null ? "check-write" : "check-patch",
      "--cwd",
      cwd,
    ];
    if (patchText === null) helperArgs.push("--path", filePath || "");
    raw = execFileSync(
      "python3",
      helperArgs,
      {
        encoding: "utf8",
        input: patchText === null
          ? undefined
          : (typeof patchText === "string" ? patchText : ""),
        stdio: ["pipe", "pipe", "pipe"],
        timeout: 10000,
      },
    );
  } catch (error) {
    const detail = error?.stderr?.toString().trim() || error?.message || "policy check failed";
    throw new Error(`BLOCKED: canonical-write policy failed closed: ${detail}`);
  }
  let result;
  try {
    result = parsePolicyPayload(raw);
  } catch {
    throw new Error("BLOCKED: canonical-write policy returned malformed output");
  }
  if (result.decision !== "allow") {
    throw new Error(
      `BLOCKED by canonical write policy: ${result.reason || "invalid policy response"}. ACTION_REQUIRED=create_or_use_linked_worktree`,
    );
  }
}

function commandPolicyError(result) {
  return new Error(
    `BLOCKED by shared command policy (${result.decision || "forbid"}, ${result.rule_id || "policy.invalid-response"}): ${result.reason || "invalid policy response"}`,
  );
}

function executeCommandPolicy(helperArgs) {
  let raw = "";
  let executionError = null;
  try {
    raw = execFileSync(
      "python3",
      helperArgs,
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        timeout: 10000,
      },
    );
  } catch (error) {
    executionError = error;
    raw = error?.stdout?.toString() || "";
  }
  let result;
  try {
    result = parsePolicyPayload(raw);
  } catch {
    const detail = executionError?.stderr?.toString().trim()
      || executionError?.message
      || "command policy returned malformed output";
    throw new Error(`BLOCKED: command policy failed closed: ${detail}`);
  }
  if (executionError) throw commandPolicyError(result);
  return result;
}

export function checkCommandSafetyGate(command, scriptsDir, cwd = process.cwd(), options = {}) {
  if (typeof command !== "string" || !command) return;
  const helper = join(scriptsDir, "command-policy-helper.py");
  if (!existsSync(helper)) {
    throw new Error("BLOCKED: required command policy helper is missing");
  }
  const namesFullLoopCommitAndPr = /full-loop-helper\.sh\s+commit-and-pr(?:\s|$)/.test(command);
  const activeScriptsDir = options.activeScriptsDir
    ?? join(homedir(), ".aidevops", "agents", "scripts");
  const fullLoop = classifyFullLoopCommitAndPr(
    command,
    scriptsDir,
    cwd,
    activeScriptsDir,
    options.activeScriptsDirBinding,
  );
  if (namesFullLoopCommitAndPr && !fullLoop.trusted) {
    throw new Error("BLOCKED: unclassified nested Git invocation from an untrusted full-loop wrapper");
  }
  // #aidevops:trust-boundary — only the repository-owned full-loop wrapper
  // receives nested Git authority, and only from a verified linked worktree.
  const guardedCommand = fullLoop.trusted
    ? "git commit --dry-run"
    : command;
  const helperArgs = [helper, "check-command", "--cwd", cwd, "--command", guardedCommand];
  // #aidevops:trust-boundary — process.pid and its start identity come from
  // the running OpenCode plugin host, never from the command being checked.
  helperArgs.push(
    "--runtime-pid",
    String(options.runtimePid ?? process.pid),
    "--runtime-process-identity",
    options.runtimeProcessIdentity ?? RUNTIME_PROCESS_IDENTITY,
  );
  if (options.processTableFixture) {
    helperArgs.push("--process-table-fixture", options.processTableFixture);
  }
  if (options.approvalHelper) {
    helperArgs.push("--approval-helper", options.approvalHelper);
  }
  const worker = options.worker ?? isWorkerContext();
  if (worker) {
    helperArgs.push(
      "--worker",
      "--worker-id",
      options.workerId || process.env.AIDEVOPS_WORKER_ID || "opencode-worker",
    );
  }
  const result = executeCommandPolicy(helperArgs);
  if (result.decision !== "allow") {
    throw commandPolicyError(result);
  }
  return fullLoop.command;
}

export const checkCanonicalGitSafetyGate = checkCommandSafetyGate;
