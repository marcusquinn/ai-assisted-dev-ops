// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { pathInside } from "./model-replay-common.mjs";

const MAX_CAPTURE_BYTES = 8 * 1024 * 1024;
const WORKSPACE_ENVIRONMENTS = new Map();
const SAFE_ENVIRONMENT_NAMES = [
  "COMSPEC",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "LOGNAME",
  "PATH",
  "PATHEXT",
  "SHELL",
  "SYSTEMROOT",
  "TERM",
  "TZ",
  "USER",
  "WINDIR",
];

function compactOutput(value) {
  const text = String(value || "");
  return text.length <= 2000 ? text : `${text.slice(0, 2000)}\n[truncated]`;
}

export function createCommandEnvironment(environmentRoot) {
  const home = join(environmentRoot, "home");
  const temporary = join(environmentRoot, "tmp");
  const config = join(environmentRoot, "config");
  const gitTemplate = join(environmentRoot, "git-template");
  for (const directory of [home, temporary, config, gitTemplate]) {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    chmodSync(directory, 0o700);
  }
  const environment = {};
  for (const name of SAFE_ENVIRONMENT_NAMES) {
    if (typeof process.env[name] === "string") environment[name] = process.env[name];
  }
  return {
    ...environment,
    CI: "1",
    HOME: home,
    TMPDIR: temporary,
    TMP: temporary,
    TEMP: temporary,
    XDG_CONFIG_HOME: config,
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
  };
}

function trustedGitMetadata(gitFile, expectedContent) {
  if (!existsSync(gitFile)) return false;
  const metadata = lstatSync(gitFile);
  if (metadata.isSymbolicLink()) return false;
  if (!metadata.isFile()) return false;
  if (metadata.nlink !== 1) return false;
  return readFileSync(gitFile, "utf8") === expectedContent;
}

export function workspaceExecutionEnvironment(workspace) {
  const key = resolve(workspace);
  const record = WORKSPACE_ENVIRONMENTS.get(key);
  if (!record) throw new Error(`Synthetic workspace environment is unavailable: ${key}`);
  const gitFile = join(key, ".git");
  if (!trustedGitMetadata(gitFile, record.gitFileContent)) {
    throw new Error(`Synthetic workspace Git metadata changed: ${key}`);
  }
  const gitDirectory = realpathSync(resolve(key, record.gitDirectoryReference));
  if (gitDirectory !== record.gitDirectory) {
    throw new Error(`Synthetic workspace Git directory changed: ${key}`);
  }
  pathInside(record.ownerRoot, gitDirectory);
  return { ...record.environment };
}

export function workspaceEnvironmentRecord(workspace) {
  return WORKSPACE_ENVIRONMENTS.get(resolve(workspace));
}

export function registerWorkspaceEnvironment(workspace, record) {
  WORKSPACE_ENVIRONMENTS.set(resolve(workspace), record);
  return 0;
}

export function deleteWorkspaceEnvironment(workspace) {
  WORKSPACE_ENVIRONMENTS.delete(resolve(workspace));
  return 0;
}

function hasControlCharacter(value) {
  for (const character of String(value)) {
    const code = character.charCodeAt(0);
    if (code <= 0x1f || code === 0x7f) return true;
  }
  return false;
}

function seatbeltLiteral(path) {
  if (hasControlCharacter(path)) {
    throw new Error(`Verifier sandbox path contains control characters: ${path}`);
  }
  const escaped = path.split("\\").join("\\\\").split('"').join('\\"');
  return `"${escaped}"`;
}

export function verifierSandboxCommand(argv, workspace, environmentRoot) {
  if (process.platform !== "darwin") {
    throw new Error(`No enforcing verifier filesystem sandbox is available on ${process.platform}`);
  }
  if (!existsSync("/usr/bin/sandbox-exec")) {
    throw new Error(`No enforcing verifier filesystem sandbox is available on ${process.platform}`);
  }
  const key = realpathSync(workspace);
  const canonicalEnvironment = realpathSync(environmentRoot);
  const readableRoots = [
    "/bin",
    "/Library",
    "/opt/homebrew",
    "/sbin",
    "/System",
    "/usr",
    key,
    canonicalEnvironment,
  ].filter((path) => existsSync(path));
  const readRules = readableRoots.map((path) => `(subpath ${seatbeltLiteral(path)})`).join(" ");
  const writeRules = [key, canonicalEnvironment]
    .map((path) => `(subpath ${seatbeltLiteral(path)})`).join(" ");
  const profile = [
    "(version 1)",
    "(deny default)",
    '(import "system.sb")',
    "(allow process*)",
    "(allow signal)",
    `(allow file-read* file-test-existence ${readRules})`,
    `(allow file-write* ${writeRules})`,
    "(deny network*)",
  ].join("");
  return ["/usr/bin/sandbox-exec", "-p", profile, ...argv];
}

export function assertNoSymlinks(root) {
  const canonicalRoot = realpathSync(root);
  const pending = [canonicalRoot];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      const metadata = lstatSync(path);
      if (metadata.isSymbolicLink()) {
        throw new Error(`Synthetic workspace contains a forbidden symlink: ${path}`);
      }
      if (metadata.isDirectory()) pending.push(path);
    }
  }
  return 0;
}

function commandArgumentsAreValid(argv) {
  if (!Array.isArray(argv)) return false;
  if (argv.length === 0) return false;
  return argv.every((part) => typeof part === "string");
}

function commandOutput(value, compact) {
  if (compact) return compactOutput(value);
  return String(value || "");
}

function completedCommand(result, compact, startedAt) {
  return {
    status: Number.isInteger(result.status) ? result.status : null,
    signal: result.signal || "",
    timedOut: result.error?.code === "ETIMEDOUT",
    error: result.error?.message || "",
    stdout: commandOutput(result.stdout, compact),
    stderr: commandOutput(result.stderr, compact),
    durationMs: Date.now() - startedAt,
  };
}

export function execute(
  argv,
  { cwd, timeoutMs = 120000, env = process.env, compact = true } = {},
) {
  if (!commandArgumentsAreValid(argv)) {
    throw new Error("Command argv must be a non-empty string array");
  }
  const startedAt = Date.now();
  const result = spawnSync(argv[0], argv.slice(1), {
    cwd,
    env,
    encoding: "utf8",
    maxBuffer: MAX_CAPTURE_BYTES,
    timeout: timeoutMs,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return completedCommand(result, compact, startedAt);
}

export function executeRequired(argv, options = {}) {
  const result = execute(argv, options);
  if (result.status !== 0) {
    throw new Error(
      `Command failed (${argv.join(" ")}): ${result.stderr || result.stdout || result.error}`,
    );
  }
  return result.stdout.trim();
}
