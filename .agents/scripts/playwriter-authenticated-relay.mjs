#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawn } from "node:child_process";
import {
  chmodSync,
  closeSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const PLAYWRITER_PACKAGE = "playwriter@0.5.0";
const RELAY_HOST = "127.0.0.1";
const RELAY_PORT = 19988;
const START_TIMEOUT_MS = 5_000;

function fixedError(message) {
  return new Error(`Authenticated Playwriter relay: ${message}`);
}

export function validatePlaywriterCommand(command) {
  if (!Array.isArray(command) || command.some((part) => typeof part !== "string" || !part)) {
    throw fixedError("invalid package-runner command");
  }
  const runner = basename(command[0]);
  const args = command.slice(1);
  const npxShape = runner === "npx"
    && (args.length === 1 || (args.length === 2 && args[0] === "-y"))
    && args.at(-1) === PLAYWRITER_PACKAGE;
  const bunShape = runner === "bun"
    && args.length === 2
    && args[0] === "x"
    && args[1] === PLAYWRITER_PACKAGE;
  if (!npxShape && !bunShape) {
    throw fixedError("command is not the reviewed Playwriter package shape");
  }
  return [...command];
}

function requireToken(environment) {
  const token = environment.PLAYWRITER_TOKEN;
  if (typeof token !== "string" || token.length < 32) {
    throw fixedError("PLAYWRITER_TOKEN must be injected through the environment and contain at least 32 characters");
  }
  return token;
}

function privateDirectory(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  const stats = lstatSync(path);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw fixedError("private runtime path is not a regular directory");
  }
  chmodSync(path, 0o700);
}

export function createPrivateRuntime(tempRoot, ownerToken = randomUUID()) {
  if (!isAbsolute(tempRoot)) throw fixedError("AIDEVOPS_TEMP_DIR must be absolute");
  privateDirectory(tempRoot);
  const physicalTempRoot = realpathSync(tempRoot);
  const parent = resolve(tempRoot, "mcp", "playwriter", "authenticated-relay");
  privateDirectory(parent);
  const physicalParent = realpathSync(parent);
  const relativeParent = relative(physicalTempRoot, physicalParent);
  if (relativeParent.startsWith("..") || isAbsolute(relativeParent)) {
    throw fixedError("private runtime path escapes AIDEVOPS_TEMP_DIR");
  }
  const directory = join(physicalParent, `session-${process.pid}-${randomUUID()}`);
  mkdirSync(directory, { mode: 0o700 });
  const markerPath = join(directory, ".aidevops-owned-relay");
  writeFileSync(markerPath, ownerToken, { flag: "wx", mode: 0o600 });
  return {
    directory,
    markerPath,
    ownerToken,
    logPath: join(directory, "relay.log"),
    statePath: join(directory, "state.json"),
  };
}

export function cleanupPrivateRuntime(runtime) {
  const stats = lstatSync(runtime.directory);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw fixedError("refusing cleanup of a non-regular runtime directory");
  }
  if (readFileSync(runtime.markerPath, "utf8") !== runtime.ownerToken) {
    throw fixedError("refusing cleanup without matching ownership evidence");
  }
  rmSync(runtime.directory, { recursive: true, force: false });
}

function relayUrl(path, port = RELAY_PORT) {
  return `http://${RELAY_HOST}:${port}${path}`;
}

async function boundedFetch(fetchImpl, url, options = {}) {
  return fetchImpl(url, {
    ...options,
    redirect: "error",
    signal: AbortSignal.timeout(1_000),
  });
}

export async function probeAuthenticatedRelay({
  token,
  port = RELAY_PORT,
  fetchImpl = fetch,
} = {}) {
  try {
    const versionResponse = await boundedFetch(fetchImpl, relayUrl("/version", port));
    if (!versionResponse.ok) return { reachable: true, ready: false };
    const versionPayload = await versionResponse.json();
    if (versionPayload?.version !== "0.5.0") return { reachable: true, ready: false };

    const wrongToken = randomUUID();
    const wrongResponse = await boundedFetch(
      fetchImpl,
      relayUrl(`/cdp/aidevops-proof?token=${encodeURIComponent(wrongToken)}`, port),
    );
    const rightResponse = await boundedFetch(
      fetchImpl,
      relayUrl(`/cdp/aidevops-proof?token=${encodeURIComponent(token)}`, port),
    );
    return {
      reachable: true,
      ready: wrongResponse.status === 401 && rightResponse.status === 404,
    };
  } catch {
    return { reachable: false, ready: false };
  }
}

function spawnRelay(command, environment, runtime) {
  const logDescriptor = openSync(runtime.logPath, "a", 0o600);
  chmodSync(runtime.logPath, 0o600);
  try {
    const child = spawn(command[0], [...command.slice(1), "serve", "--host", RELAY_HOST], {
      env: environment,
      shell: false,
      stdio: ["ignore", logDescriptor, logDescriptor],
    });
    child.spawnFailed = false;
    child.once("error", () => { child.spawnFailed = true; });
    return child;
  } finally {
    closeSync(logDescriptor);
  }
}

async function waitForRelay(token, child) {
  const deadline = Date.now() + START_TIMEOUT_MS;
  do {
    const proof = await probeAuthenticatedRelay({ token });
    if (proof.ready) return proof;
    if (proof.reachable || child.spawnFailed || child.exitCode !== null) return proof;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  } while (Date.now() < deadline);
  return { reachable: false, ready: false };
}

async function terminateChild(child) {
  if (!child || child.exitCode !== null) return;
  child.kill("SIGTERM");
  await Promise.race([
    new Promise((resolvePromise) => child.once("exit", resolvePromise)),
    new Promise((resolvePromise) => setTimeout(resolvePromise, 2_000)),
  ]);
  if (child.exitCode === null) child.kill("SIGKILL");
}

async function ensureRelay(command, environment, runtime, token) {
  const existing = await probeAuthenticatedRelay({ token });
  if (existing.ready) return { child: null, owned: false };
  if (existing.reachable) {
    throw fixedError("port 19988 is occupied without matching token and version proof");
  }

  const child = spawnRelay(command, environment, runtime);
  const proof = await waitForRelay(token, child);
  if (!proof.ready) {
    await terminateChild(child);
    throw fixedError("could not prove the localhost relay version and token contract");
  }
  if (child.exitCode !== null || child.spawnFailed) {
    return { child: null, owned: false };
  }
  return { child, owned: true };
}

function writeState(runtime, relay) {
  const state = {
    schema: "aidevops-playwriter-relay/v1",
    host: RELAY_HOST,
    port: RELAY_PORT,
    version: "0.5.0",
    supervisorPid: process.pid,
    relayPid: relay.owned ? relay.child.pid : null,
    owned: relay.owned,
  };
  writeFileSync(runtime.statePath, `${JSON.stringify(state)}\n`, { flag: "wx", mode: 0o600 });
}

async function supervise(command, environment) {
  const token = requireToken(environment);
  const tempRoot = environment.AIDEVOPS_TEMP_DIR
    || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  const runtime = createPrivateRuntime(tempRoot);
  let relay = null;
  let mcp = null;
  let stopping = false;
  try {
    relay = await ensureRelay(command, environment, runtime, token);
    writeState(runtime, relay);
    mcp = spawn(command[0], command.slice(1), {
      env: {
        ...environment,
        PLAYWRITER_HOST: RELAY_HOST,
      },
      shell: false,
      stdio: "inherit",
    });

    const forwardSignal = (signal) => {
      stopping = true;
      if (mcp.exitCode === null) mcp.kill(signal);
    };
    process.once("SIGINT", () => forwardSignal("SIGINT"));
    process.once("SIGTERM", () => forwardSignal("SIGTERM"));
    if (relay.owned) {
      relay.child.once("exit", () => {
        if (!stopping && mcp?.exitCode === null) mcp.kill("SIGTERM");
      });
    }

    const result = await new Promise((resolvePromise) => {
      mcp.once("error", () => resolvePromise({ code: 1, signal: null }));
      mcp.once("exit", (code, signal) => resolvePromise({ code, signal }));
    });
    stopping = true;
    return result.code ?? (result.signal ? 1 : 0);
  } finally {
    stopping = true;
    await terminateChild(mcp);
    if (relay?.owned) await terminateChild(relay.child);
    cleanupPrivateRuntime(runtime);
  }
}

export async function main(argv = process.argv.slice(2), environment = process.env) {
  if (environment.AIDEVOPS_PLAYWRITER_AUTHENTICATED_RELAY !== "1") {
    throw fixedError("opt-in environment flag is not enabled");
  }
  const command = validatePlaywriterCommand(argv);
  return supervise(command, environment);
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath && fileURLToPath(import.meta.url) === invokedPath) {
  main()
    .then((code) => { process.exitCode = code; })
    .catch((error) => {
      process.stderr.write(`${error instanceof Error ? error.message : "Authenticated Playwriter relay failed"}\n`);
      process.exitCode = 1;
    });
}
