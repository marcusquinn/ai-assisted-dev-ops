// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for informational tool telemetry leaking into OpenCode's
// stderr-backed TUI. Tool titles are unbounded payloads (often full commands),
// so they must go to persistent logs rather than console.error.

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createQualityHooks } from "../quality-hooks.mjs";
import { installPluginConsoleRouter } from "../plugin-console.mjs";

test("tagged diagnostics are persisted without payload-based TUI routing", () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-console-router-"));
  const logPath = join(tempDir, "plugin.log");
  const calls = [];
  const fakeConsole = { error: (...args) => calls.push(args) };
  const restore = installPluginConsoleRouter({ consoleObject: fakeConsole, logPath });

  try {
    fakeConsole.error("[aidevops] account error@example.invalid refreshed");
    fakeConsole.error("[aidevops] proxy failed\r\n[forged]", new Error("connection refused"));
    fakeConsole.error("host error");

    const diagnosticLog = readFileSync(logPath, "utf8");
    assert.match(diagnosticLog, /account error@example\.invalid refreshed/);
    assert.match(diagnosticLog, /proxy failed\\r\\n\[forged].*connection refused/);
    assert.equal(diagnosticLog.trim().split("\n").length, 2);
    assert.deepEqual(calls, [["host error"]]);
  } finally {
    restore();
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("diagnostic rotation keeps a bounded set of process archives", () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-console-retention-"));
  const logPath = join(tempDir, "plugin.log");
  const fakeConsole = { error() {} };
  const restore = installPluginConsoleRouter({ consoleObject: fakeConsole, logPath });

  try {
    for (let pid = 100; pid < 105; pid++) writeFileSync(`${logPath}.${pid}.1`, `${pid}`);
    writeFileSync(`${logPath}.manual.1`, "unrelated");
    writeFileSync(logPath, "x".repeat((5 * 1024 * 1024) + 1));
    fakeConsole.error("[aidevops] rotate now");

    const archives = readdirSync(tempDir).filter((name) => /^plugin\.log\.\d+\.1$/.test(name));
    assert.ok(archives.length <= 3, `rotation retained ${archives.length} archives`);
    assert.ok(archives.includes(`plugin.log.${process.pid}.1`));
    assert.match(readFileSync(logPath, "utf8"), /\[aidevops] rotate now/);
    assert.equal(readFileSync(`${logPath}.manual.1`, "utf8"), "unrelated");
  } finally {
    restore();
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("post-tool operation telemetry stays out of the TUI and is safely persisted", async () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-tui-routing-"));
  const trackerPath = join(tempDir, "pattern-tracker-helper.sh");
  const capturePath = join(tempDir, "tracker-args.txt");
  const injectionMarker = join(tempDir, "must-not-exist");
  const previousCapture = process.env.AIDEVOPS_TEST_PATTERN_CAPTURE;
  const originalConsoleError = console.error;
  const consoleCalls = [];
  const credential = `ghp_${"a".repeat(36)}`;
  const title = `git commit shellcheck \"$(touch ${injectionMarker})\"; headless-runtime-failure.sh\n${credential}\t${"x".repeat(600)}`;

  writeFileSync(
    trackerPath,
    "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > \"$AIDEVOPS_TEST_PATTERN_CAPTURE\"\n",
  );
  process.env.AIDEVOPS_TEST_PATTERN_CAPTURE = capturePath;
  console.error = (...args) => consoleCalls.push(args);

  try {
    const hooks = createQualityHooks({ scriptsDir: tempDir, logsDir: tempDir });
    await hooks.toolExecuteAfter(
      { tool: "bash", callID: "" },
      { title, output: "", metadata: {} },
    );

    const qualityLog = readFileSync(join(tempDir, "quality-hooks.log"), "utf8");
    const trackerArgs = readFileSync(capturePath, "utf8");
    assert.doesNotMatch(qualityLog, /ghp_|[\r\t]/);
    assert.match(qualityLog, /\[redacted-credential]/);
    assert.match(qualityLog, /Git operation:/);
    assert.match(qualityLog, /Lint run:/);
    for (const line of qualityLog.trim().split("\n")) {
      const payload = line.replace(/^.*(?:Git operation: |Lint run: )/, "").replace(/ — (?:PASS|issues found)$/, "");
      assert.ok(payload.length <= 500, `telemetry payload exceeded 500 characters: ${payload.length}`);
    }
    assert.doesNotMatch(trackerArgs, /ghp_|[\r\t]/);
    assert.equal(existsSync(injectionMarker), false);
    assert.deepEqual(consoleCalls, []);
  } finally {
    console.error = originalConsoleError;
    if (previousCapture === undefined) delete process.env.AIDEVOPS_TEST_PATTERN_CAPTURE;
    else process.env.AIDEVOPS_TEST_PATTERN_CAPTURE = previousCapture;
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("pre-tool bash handling tolerates a missing args payload", async () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-missing-tool-args-"));

  try {
    const hooks = createQualityHooks({ scriptsDir: tempDir, logsDir: tempDir });
    await assert.doesNotReject(
      hooks.toolExecuteBefore(
        { tool: "bash", callID: "" },
        {},
      ),
    );
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("pre-tool handling replaces args when intent cannot be deleted in place", async () => {
  const tempDir = mkdtempSync(join(tmpdir(), "aidevops-immutable-tool-args-"));
  const todos = [];
  const getTodos = () => todos;
  const args = {};
  Object.defineProperty(args, "todos", {
    enumerable: true,
    get: getTodos,
  });
  Object.defineProperty(args, "agent__intent", {
    configurable: false,
    enumerable: true,
    value: "Inspecting repository status",
  });
  const output = { args };

  try {
    const hooks = createQualityHooks({ scriptsDir: tempDir, logsDir: tempDir });
    await hooks.toolExecuteBefore(
      { tool: "todowrite", callID: "call-immutable-intent" },
      output,
    );

    assert.notEqual(output.args, args);
    assert.equal(Object.getOwnPropertyDescriptor(output.args, "todos").get, getTodos);
    assert.equal(output.args.todos, todos);
    assert.ok(!Object.prototype.hasOwnProperty.call(output.args, "agent__intent"));
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});
