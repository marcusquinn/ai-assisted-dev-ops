// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawn } from "node:child_process";

const WRITER_TIMEOUT_MS = 60_000;
const MAX_DIAGNOSTIC_CHARS = 4_096;
const PYTHON_BINARY = "/usr/bin/python3";

function writerProcess(helper, out, projectRoot, spawnImpl) {
  return spawnImpl(PYTHON_BINARY, ["-I", "-B", helper, "--root", ".", "--out", out], {
    cwd: projectRoot,
    env: {
      LANG: process.env.LANG || "C.UTF-8",
      PYTHONIOENCODING: "utf-8",
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function collectWriterOutput(child, buffer) {
  return new Promise((resolve, reject) => {
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), WRITER_TIMEOUT_MS);
    timer.unref?.();
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout = (stdout + chunk).slice(0, MAX_DIAGNOSTIC_CHARS); });
    child.stderr.on("data", (chunk) => { stderr = (stderr + chunk).slice(0, MAX_DIAGNOSTIC_CHARS); });
    child.on("error", () => {
      clearTimeout(timer);
      reject(new Error("Secure image writer could not start."));
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (signal === "SIGKILL") reject(new Error("Secure image writer timed out."));
      else if (code !== 0) reject(new Error(stderr.trim() || "Secure image writer failed."));
      else resolve(stdout);
    });
    child.stdin.on("error", () => {});
    child.stdin.end(buffer);
  });
}

export function runImageWriter(helper, buffer, out, projectRoot, spawnImpl = spawn) {
  return collectWriterOutput(writerProcess(helper, out, projectRoot, spawnImpl), buffer);
}
