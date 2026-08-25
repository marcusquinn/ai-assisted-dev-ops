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
  readdirSync,
  realpathSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import { pathInside } from "./model-replay-common.mjs";

const MAX_CAPTURE_BYTES = 8 * 1024 * 1024;
const WORKSPACE_ENVIRONMENTS = new Map();
const LINUX_BWRAP_CANDIDATES = ["/usr/bin/bwrap", "/bin/bwrap"];
const LINUX_RUNTIME_ROOTS = ["/usr", "/bin", "/sbin", "/lib", "/lib64"];
const LINUX_RUNTIME_PATHS = [
  "/etc/group",
  "/etc/ld.so.cache",
  "/etc/ld.so.conf",
  "/etc/ld.so.conf.d",
  "/etc/localtime",
  "/etc/nsswitch.conf",
  "/etc/passwd",
  "/etc/ssl/certs",
];
let verifiedSandboxBackend = null;
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
  const cache = join(environmentRoot, "cache");
  const data = join(environmentRoot, "data");
  const runtime = join(environmentRoot, "runtime");
  const state = join(environmentRoot, "state");
  const gitTemplate = join(environmentRoot, "git-template");
  for (const directory of [home, temporary, config, cache, data, runtime, state, gitTemplate]) {
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
    XDG_CACHE_HOME: cache,
    XDG_CONFIG_HOME: config,
    XDG_DATA_HOME: data,
    XDG_RUNTIME_DIR: runtime,
    XDG_STATE_HOME: state,
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

function executableFile(path) {
  try {
    accessSync(path, constants.X_OK);
    const metadata = lstatSync(path);
    return metadata.isFile() && !metadata.isSymbolicLink();
  } catch {
    return false;
  }
}

function unavailableSandbox(platform) {
  throw new Error(`No enforcing verifier filesystem sandbox is available on ${platform}`);
}

export function verifierSandboxBackend({
  platform = process.platform,
  linuxCandidates = LINUX_BWRAP_CANDIDATES,
} = {}) {
  if (platform === "darwin" && executableFile("/usr/bin/sandbox-exec")) {
    return { kind: "seatbelt", executable: "/usr/bin/sandbox-exec" };
  }
  if (platform === "linux") {
    const executable = linuxCandidates.find(executableFile);
    if (executable) return { kind: "bubblewrap", executable };
  }
  return unavailableSandbox(platform);
}

function bubblewrapProbe(executable) {
  const probeExecutable = ["/usr/bin/true", "/bin/true"].find(executableFile);
  if (!probeExecutable) unavailableSandbox(process.platform);
  const probeArguments = [
    "--die-with-parent",
    "--new-session",
    "--unshare-all",
  ];
  for (const path of LINUX_RUNTIME_ROOTS.filter(existsSync)) {
    probeArguments.push("--ro-bind", realpathSync(path), path);
  }
  probeArguments.push(
    "--proc", "/proc",
    "--dev", "/dev",
    probeExecutable,
  );
  const result = spawnSync(executable, probeArguments, {
    encoding: "utf8",
    timeout: 10000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    const detail = compactOutput(result.stderr || result.stdout || result.error?.message || "probe failed");
    throw new Error(`Linux verifier filesystem sandbox is unavailable: ${detail}`);
  }
}

export function assertVerifierSandboxAvailable() {
  if (verifiedSandboxBackend) return { ...verifiedSandboxBackend };
  const backend = verifierSandboxBackend();
  if (backend.kind === "bubblewrap") bubblewrapProbe(backend.executable);
  verifiedSandboxBackend = backend;
  return { ...backend };
}

function mountParentDirectories(paths) {
  const directories = new Set();
  for (const path of paths) {
    let parent = dirname(path);
    while (parent !== "/" && parent !== ".") {
      directories.add(parent);
      parent = dirname(parent);
    }
  }
  return [...directories].sort((left, right) => (
    left.split(sep).length - right.split(sep).length || left.localeCompare(right)
  ));
}

function linuxRuntimeExecutable(argv, workspace) {
  const command = argv[0];
  if (!isAbsolute(command)) return null;
  const executable = realpathSync(command);
  if (LINUX_RUNTIME_ROOTS.some((root) => executable === root || executable.startsWith(`${root}${sep}`))) {
    return null;
  }
  const nodeExecutable = realpathSync(process.execPath);
  if (executable !== nodeExecutable) {
    pathInside(workspace, executable);
    return null;
  }
  return { source: executable, destination: command };
}

function bubblewrapSandboxCommand(argv, workspace, environmentRoot, executable) {
  const key = realpathSync(workspace);
  const canonicalEnvironment = realpathSync(environmentRoot);
  const isolatedTemporary = realpathSync(join(canonicalEnvironment, "tmp"));
  const runtimeRoots = LINUX_RUNTIME_ROOTS.filter(existsSync).map((path) => ({
    destination: path,
    source: realpathSync(path),
  }));
  const runtimePaths = LINUX_RUNTIME_PATHS.filter(existsSync).map((path) => ({
    destination: path,
    source: realpathSync(path),
  }));
  const extraExecutable = linuxRuntimeExecutable(argv, key);
  const mounts = [
    ...runtimeRoots,
    ...runtimePaths,
    { source: key, destination: key },
    { source: canonicalEnvironment, destination: canonicalEnvironment },
    { source: isolatedTemporary, destination: "/tmp" },
  ];
  if (extraExecutable) mounts.push(extraExecutable);
  // Bubblewrap retains namespace setup capabilities, then drops them before exec.
  const command = [
    executable,
    "--die-with-parent",
    "--new-session",
    "--unshare-all",
  ];
  for (const directory of mountParentDirectories([
    "/dev",
    "/proc",
    "/tmp",
    ...mounts.map((mount) => mount.destination),
  ])) {
    command.push("--dir", directory);
  }
  for (const mount of runtimeRoots) {
    command.push("--ro-bind", mount.source, mount.destination);
  }
  for (const mount of runtimePaths) {
    command.push("--ro-bind", mount.source, mount.destination);
  }
  if (extraExecutable) {
    command.push("--ro-bind", extraExecutable.source, extraExecutable.destination);
  }
  command.push(
    "--proc", "/proc",
    "--dev", "/dev",
    "--bind", key, key,
    "--bind", canonicalEnvironment, canonicalEnvironment,
    "--bind", isolatedTemporary, "/tmp",
    "--remount-ro", "/",
    "--chdir", key,
    "--",
    ...argv,
  );
  return command;
}

export function verifierSandboxCommand(argv, workspace, environmentRoot) {
  const backend = assertVerifierSandboxAvailable();
  if (backend.kind === "bubblewrap") {
    return bubblewrapSandboxCommand(argv, workspace, environmentRoot, backend.executable);
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
  return [backend.executable, "-p", profile, ...argv];
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
