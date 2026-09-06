// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn } from "node:child_process";

export function createOutputSandboxRecorder(helperPath, spawnImpl = spawn, timeoutMs = 5000) {
  const activeChildren = new Set();
  const recorder = (content, evidence = {}) => new Promise((resolve) => {
    const exitCode = Number.isInteger(evidence.exitCode) ? evidence.exitCode : 1;
    const child = spawnImpl("bash", [
      helperPath, "store", "--command", "bounded-interactive-operation",
      "--exit-code", String(exitCode), "--tag", "interactive-operation",
    ], { stdio: ["pipe", "pipe", "ignore"] });
    activeChildren.add(child);
    let stdout = "";
    let settled = false;
    const finish = (outputID = "") => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      activeChildren.delete(child);
      resolve(outputID);
    };
    const timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      finish();
    }, timeoutMs);
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => { stdout += chunk; });
    child.once("error", () => finish());
    child.once("close", (code) => {
      const match = code === 0 ? stdout.match(/^output_id:\s*(\S+)/m) : null;
      finish(match?.[1] || "");
    });
    child.stdin?.end(content);
  });
  recorder.dispose = () => {
    for (const child of activeChildren) {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }
    activeChildren.clear();
  };
  return recorder;
}
