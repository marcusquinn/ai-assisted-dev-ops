// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn, spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

function boundedInteger(value, fallback, minimum, maximum) {
  value = Number(value);
  return Number.isFinite(value) ? Math.max(minimum, Math.min(maximum, Math.floor(value))) : fallback;
}

async function readPrivateConfig() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > 70 * 1024) return null;
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return null;
  }
}

function groupMemberCount(groupID) {
  const result = spawnSync("ps", ["-ax", "-o", "pid=", "-o", "pgid="], {
    detached: true,
    encoding: "utf8",
    timeout: 1000,
  });
  if (result.status !== 0) return -1;
  let count = 0;
  for (const line of result.stdout.split(/\r?\n/)) {
    const fields = line.trim().split(/\s+/);
    if (Number(fields[1]) === groupID) count += 1;
  }
  return count;
}

function reportCommandStarted(operationID) {
  if (typeof process.send !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    try {
      process.send({
        type: "aidevops.operation",
        event: "command_started",
        operationID: String(operationID || ""),
        runtime: `node ${process.version}`,
      }, resolve);
    } catch {
      // The parent closes IPC during cancellation or an abnormal launcher exit.
      resolve();
    }
  });
}

export async function runSupervisor() {
  const config = await readPrivateConfig();
  const command = config?.command;
  if (!Array.isArray(command) || command.length === 0
    || command.some((part) => typeof part !== "string" || !part)) return 125;

  const budgetMs = boundedInteger(config.budgetMs, 15 * 60 * 1000, 10, 24 * 60 * 60 * 1000);
  const killGraceMs = boundedInteger(config.killGraceMs, 500, 10, 30 * 1000);
  let terminating = false;
  let childFinished = false;
  let childExit = 1;
  let commandStarted = Promise.resolve();

  const terminateOwnedGroup = () => {
    if (terminating) return;
    terminating = true;
    try {
      process.kill(-process.pid, "SIGTERM");
    } catch {
      // The group may already contain only this supervisor.
    }
    setTimeout(() => {
      try {
        process.kill(-process.pid, "SIGKILL");
      } catch {
        process.exit(1);
      }
    }, killGraceMs).unref();
  };

  process.on("SIGTERM", terminateOwnedGroup);
  process.on("SIGINT", terminateOwnedGroup);
  process.on("message", (message) => {
    if (message?.action === "terminate") terminateOwnedGroup();
  });
  const budgetTimer = setTimeout(terminateOwnedGroup, budgetMs);

  const child = spawn(command[0], command.slice(1), {
    cwd: process.cwd(),
    env: { ...process.env, AIDEVOPS_OPERATION_ID: String(config.operationID || "") },
    stdio: ["ignore", "inherit", "inherit"],
  });

  child.once("spawn", () => { commandStarted = reportCommandStarted(config.operationID); });
  child.once("error", () => {
    childFinished = true;
    childExit = 127;
  });
  child.once("exit", (code) => {
    childFinished = true;
    childExit = Number.isInteger(code) ? code : 1;
  });

  return new Promise((resolve) => {
    const drainTimer = setInterval(() => {
      if (!childFinished) return;
      const members = groupMemberCount(process.pid);
      if (members !== 1) return;
      clearInterval(drainTimer);
      clearTimeout(budgetTimer);
      commandStarted.finally(() => resolve(childExit));
    }, 25);
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(await runSupervisor());
}
