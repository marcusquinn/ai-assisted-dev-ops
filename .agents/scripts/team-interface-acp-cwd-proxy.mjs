#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {spawn} from "node:child_process";
import {once} from "node:events";
import {constants, accessSync, lstatSync, realpathSync} from "node:fs";
import path from "node:path";
import {createInterface} from "node:readline";

import {childEnvironment, publishReply} from "./_team_interface_acp_publish.mjs";
import {TurnState} from "./_team_interface_acp_reply.mjs";

const CONFIG_EXIT = 78;
const DEFAULT_BUZZ_CLI = "/Applications/Buzz.app/Contents/MacOS/buzz";

function validateExecutable(configuredPath, label) {
  if (!path.isAbsolute(configuredPath)) {
    throw new Error(`${label} must be absolute`);
  }
  const metadata = lstatSync(configuredPath);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error(`${label} must be a non-symlink regular file`);
  }
  const executable = realpathSync(configuredPath);
  if (executable !== path.resolve(configuredPath)) {
    throw new Error(`${label} must already be canonical`);
  }
  accessSync(executable, constants.X_OK);
  return executable;
}

function parseArguments(argumentsList) {
  const separator = argumentsList.indexOf("--");
  if (![2, 4].includes(separator) || argumentsList[0] !== "--cwd" || argumentsList.length < separator + 2) {
    throw new Error(
      "usage: team-interface-acp-cwd-proxy.mjs --cwd ABSOLUTE_PATH " +
      "[--buzz-cli ABSOLUTE_PATH] -- COMMAND [ARGS...]",
    );
  }
  if (separator === 4 && argumentsList[2] !== "--buzz-cli") {
    throw new Error("ACP proxy received an unsupported option");
  }
  const configuredCwd = argumentsList[1];
  if (!path.isAbsolute(configuredCwd)) {
    throw new Error("ACP proxy cwd must be absolute");
  }
  const metadata = lstatSync(configuredCwd);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new Error("ACP proxy cwd must be a non-symlink directory");
  }
  const cwd = realpathSync(configuredCwd);
  if (cwd !== path.resolve(configuredCwd)) {
    throw new Error("ACP proxy cwd must already be canonical");
  }
  return {
    buzzCli: validateExecutable(
      separator === 4 ? argumentsList[3] : DEFAULT_BUZZ_CLI,
      "Buzz CLI",
    ),
    command: argumentsList[separator + 1],
    commandArguments: argumentsList.slice(separator + 2),
    cwd,
  };
}

function bindSessionCwd(line, cwd) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    throw new Error("ACP proxy received malformed NDJSON");
  }
  if (message?.method !== "session/new") {
    return line;
  }
  if (!message.params || typeof message.params !== "object" || Array.isArray(message.params)) {
    throw new Error("ACP session/new request has invalid params");
  }
  message.params = {...message.params, cwd};
  return JSON.stringify(message);
}

async function writeLine(stream, line) {
  if (!stream.write(`${line}\n`, "utf8")) {
    await once(stream, "drain");
  }
}

async function forwardRequests(input, childInput, output, runtime) {
  for await (const line of input) {
    if (line.length === 0) {
      continue;
    }
    const rebound = bindSessionCwd(line, runtime.cwd);
    const message = JSON.parse(rebound);
    if (message?.method === "session/prompt") {
      const directReply = runtime.turns.begin(message);
      if (directReply) {
        await publishReply(runtime.buzzCli, directReply);
        await writeLine(output, JSON.stringify({
          id: message.id,
          jsonrpc: message.jsonrpc || "2.0",
          result: {stopReason: "end_turn"},
        }));
        continue;
      }
    }
    await writeLine(childInput, rebound);
  }
  childInput.end();
}

async function forwardResponses(childOutput, output, runtime) {
  const responses = createInterface({input: childOutput, crlfDelay: Infinity});
  for await (const line of responses) {
    if (line.length === 0) {
      continue;
    }
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      throw new Error("ACP child emitted malformed NDJSON");
    }
    if (message?.method === "session/update") {
      runtime.turns.append(message);
    }
    const turn = runtime.turns.finish(message);
    if (turn) {
      await publishReply(runtime.buzzCli, turn);
    }
    await writeLine(output, line);
  }
}

async function main() {
  const {buzzCli, command, commandArguments, cwd} = parseArguments(process.argv.slice(2));
  const child = spawn(command, commandArguments, {
    env: childEnvironment(),
    shell: false,
    stdio: ["pipe", "pipe", "inherit"],
  });
  const exited = once(child, "exit");
  const input = createInterface({input: process.stdin, crlfDelay: Infinity});
  const runtime = {buzzCli, cwd, turns: new TurnState()};

  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => {
      child.kill(signal);
    });
  }

  try {
    const monitorExit = (async () => {
      const result = await exited;
      input.close();
      return result;
    })();
    const [exitResult] = await Promise.all([
      monitorExit,
      forwardRequests(input, child.stdin, process.stdout, runtime),
      forwardResponses(child.stdout, process.stdout, runtime),
    ]);
    const [code, signal] = exitResult;
    if (signal) {
      throw new Error(`ACP child exited from signal ${signal}`);
    }
    process.exitCode = code ?? 1;
  } catch (error) {
    input.close();
    child.stdin.destroy();
    child.kill("SIGTERM");
    await exited;
    throw error;
  }
}

main().catch((error) => {
  process.stderr.write(`team-interface-acp-cwd-proxy: ${error.message}\n`);
  process.exitCode = CONFIG_EXIT;
});
