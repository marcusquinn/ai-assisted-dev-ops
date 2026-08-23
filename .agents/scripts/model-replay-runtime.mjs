// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawnSync } from "node:child_process";
import {
  accessSync,
  chmodSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { writeJson, writePrivateFile } from "./model-replay-core.mjs";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const MODEL_REPLAY_AGENT = resolve(SCRIPT_DIR, "../workflows/model-replay.md");
const SENSITIVE_TEMP_HELPER = join(SCRIPT_DIR, "sensitive-temp-helper.sh");

function ensureOwnedDirectory(path) {
  if (existsSync(path)) {
    const metadata = lstatSync(path);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
      throw new Error(`Owned directory is not a real directory: ${path}`);
    }
  }
  mkdirSync(path, { recursive: true, mode: 0o700 });
  chmodSync(path, 0o700);
  return realpathSync(path);
}

function isExecutableAbsoluteFile(path) {
  if (!path || !isAbsolute(path)) return false;
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

export function assertModelReplayEgressConfigured() {
  const backend = process.env.AIDEVOPS_WORKER_EGRESS_BACKEND || "";
  if (!isExecutableAbsoluteFile(backend)) {
    throw new Error(
      "Real model replay requires AIDEVOPS_WORKER_EGRESS_BACKEND to be an executable absolute file",
    );
  }
  return backend;
}

export function prepareModelReplayRuntime(workRoot) {
  if (!existsSync(MODEL_REPLAY_AGENT) || lstatSync(MODEL_REPLAY_AGENT).isSymbolicLink()) {
    throw new Error("Trusted model replay agent is unavailable");
  }
  const configDirectory = ensureOwnedDirectory(join(workRoot, "runtime-config"));
  const agentDirectory = ensureOwnedDirectory(join(configDirectory, "agent"));
  const agentPath = join(agentDirectory, "model-replay.md");
  const configPath = join(configDirectory, "opencode.json");
  writePrivateFile(agentPath, readFileSync(MODEL_REPLAY_AGENT), 0o400);
  const tools = {
    "*": false,
    read: true,
    grep: true,
    glob: true,
    write: true,
    edit: true,
    apply_patch: true,
    bash: false,
    task: false,
    webfetch: false,
    websearch: false,
  };
  const permission = {
    "*": "deny",
    read: "allow",
    grep: "allow",
    glob: "allow",
    write: "allow",
    edit: "allow",
    apply_patch: "allow",
    bash: "deny",
    task: "deny",
    external_directory: "deny",
  };
  writeJson(configPath, {
    $schema: "https://opencode.ai/config.json",
    default_agent: "model-replay",
    agent: { "model-replay": { mode: "primary", tools, permission } },
    tools,
    permission,
    mcp: {},
    formatter: false,
    lsp: false,
    share: "disabled",
    subagent_depth: 0,
  }, 0o400);
  return { configDirectory, configPath };
}

function runSensitiveTempHelper(command, args) {
  if (!existsSync(SENSITIVE_TEMP_HELPER) || lstatSync(SENSITIVE_TEMP_HELPER).isSymbolicLink()) {
    throw new Error("Sensitive temporary storage helper is unavailable");
  }
  const result = spawnSync("bash", [
    "-c", command, "aidevops-model-replay", SENSITIVE_TEMP_HELPER, ...args,
  ], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0 || result.error || result.signal) {
    throw new Error("Sensitive temporary storage helper failed");
  }
  return String(result.stdout || "").trim();
}

function startRuntimeCleanupGuardian(workRoot, cell) {
  const timeout = Number(cell?.timeout_seconds ?? 3600);
  const maxAge = Number.isInteger(timeout) && timeout > 0
    ? Math.min(timeout + 300, 25200)
    : 3900;
  runSensitiveTempHelper(
    'source "$1"; aidevops_sensitive_temp_start_guardian "$2" "$3" "$4" "$5"',
    [workRoot, String(process.pid), String(maxAge), "2"],
  );
}

export function createRuntimeWorkRoot(cell) {
  const workRoot = runSensitiveTempHelper(
    'source "$1"; aidevops_sensitive_temp_create_dir "$2"',
    ["model-replay"],
  );
  if (!workRoot) throw new Error("Sensitive model replay work root was not created");
  const ownedRoot = ensureOwnedDirectory(workRoot);
  try {
    startRuntimeCleanupGuardian(ownedRoot, cell);
    return ownedRoot;
  } catch (error) {
    rmSync(ownedRoot, { recursive: true, force: true });
    throw error;
  }
}

export function modelReplayHelperPath() {
  return process.env.AIDEVOPS_HEADLESS_RUNTIME_HELPER
    || join(SCRIPT_DIR, "headless-runtime-helper.sh");
}
