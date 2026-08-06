// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {spawn} from "node:child_process";

function subprocessError(code) {
  const error = new Error("Buzz read subprocess failed");
  error.code = code;
  return error;
}

function appendBounded(chunks, state, chunk, maxBuffer) {
  state.bytes += chunk.length;
  if (state.bytes > maxBuffer) return false;
  chunks.push(chunk);
  return true;
}

export function executeBoundedFile(command, argumentsList, options) {
  const {cwd, encoding = "utf8", maxBuffer, signal, sourceFd} = options;
  if (!Number.isSafeInteger(maxBuffer) || maxBuffer <= 0) {
    throw new TypeError("maxBuffer must be a positive safe integer");
  }
  if (sourceFd !== undefined && (!Number.isSafeInteger(sourceFd) || sourceFd < 0)) {
    throw new TypeError("sourceFd must be a non-negative safe integer");
  }
  if (cwd !== undefined && (typeof cwd !== "string" || cwd.length === 0)) {
    throw new TypeError("cwd must be a non-empty string");
  }
  const stdio = sourceFd === undefined
    ? ["ignore", "pipe", "pipe"]
    : ["ignore", "pipe", "pipe", sourceFd];
  return new Promise((resolve, reject) => {
    const child = spawn(command, argumentsList, {cwd, shell: false, signal, stdio});
    const stdout = [];
    const stderr = [];
    const stdoutState = {bytes: 0};
    const stderrState = {bytes: 0};
    let settled = false;
    const rejectOnce = (error) => {
      if (settled) return;
      settled = true;
      if (!child.killed) child.kill();
      reject(error);
    };
    child.stdout.on("data", (chunk) => {
      if (!appendBounded(stdout, stdoutState, chunk, maxBuffer)) {
        rejectOnce(subprocessError("oversized_source"));
      }
    });
    child.stderr.on("data", (chunk) => {
      if (!appendBounded(stderr, stderrState, chunk, maxBuffer)) {
        rejectOnce(subprocessError("oversized_source"));
      }
    });
    child.once("error", rejectOnce);
    child.once("close", (code) => {
      if (settled) return;
      settled = true;
      if (code !== 0) {
        reject(subprocessError("subprocess_failed"));
        return;
      }
      resolve({
        stderr: Buffer.concat(stderr, stderrState.bytes).toString(encoding),
        stdout: Buffer.concat(stdout, stdoutState.bytes).toString(encoding),
      });
    });
  });
}
