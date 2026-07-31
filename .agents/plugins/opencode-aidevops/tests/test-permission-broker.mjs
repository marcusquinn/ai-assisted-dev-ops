// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

import { createPermissionBroker, sanitizePermissionText } from "../permission-broker.mjs";

const WORKER_ENV_KEYS = [
  "AIDEVOPS_PERMISSION_REQUEST_FILE",
  "WORKER_ISSUE_NUMBER",
  "WORKER_REPO_SLUG",
  "WORKER_SESSION_KEY",
];

function preserveWorkerEnvironment() {
  return Object.fromEntries(WORKER_ENV_KEYS.map((key) => [key, process.env[key]]));
}

function restoreWorkerEnvironment(previous) {
  for (const key of WORKER_ENV_KEYS) {
    if (previous[key] === undefined) delete process.env[key];
    else process.env[key] = previous[key];
  }
}

function toolOutputPermissionEvent({ id, callID, outputDir, outputPath }) {
  return { event: { type: "permission.asked", properties: {
    id,
    sessionID: "session-output",
    permission: "external_directory",
    patterns: [`${outputDir}/*`],
    metadata: { filepath: outputPath, parentDir: outputDir },
    tool: { callID, messageID: `message-${id}` },
  } } };
}

test("headless workers auto-approve only regular OpenCode tool-output reads", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-permission-broker-")));
  const dataHome = join(root, "xdg-data");
  const outputDir = join(dataHome, "opencode", "tool-output");
  const outputPath = join(outputDir, "tool_01TESTOUTPUT");
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  mkdirSync(outputDir, { recursive: true });
  writeFileSync(outputPath, "bounded output\n");
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true,
    home: root,
    dataHome,
    blockerLogPath: blockerLog,
  });
  broker.recordToolCall({ tool: "read", callID: "call-output" }, { args: {} });

  await broker.handleEvent(toolOutputPermissionEvent({
    id: "permission-output",
    callID: "call-output",
    outputDir,
    outputPath,
  }));

  assert.equal(replies[0].body.response, "once");
  assert.equal(existsSync(requestFile), false);
  assert.equal(existsSync(blockerLog), false);

  broker.recordToolCall({ tool: "read", callID: "call-output-legacy" }, { args: {} });
  const legacyOutput = { status: "ask" };
  await broker.permissionAsk({
    id: "permission-output-legacy",
    type: "external_directory",
    pattern: `${outputDir}/*`,
    callID: "call-output-legacy",
    metadata: { filepath: outputPath, parentDir: outputDir },
  }, legacyOutput);
  assert.equal(legacyOutput.status, "allow");
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("tool-output read approval failure falls back to capture and rejection", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-permission-broker-")));
  const dataHome = join(root, "xdg-data");
  const outputDir = join(dataHome, "opencode", "tool-output");
  const outputPath = join(outputDir, "tool_01FAILEDAPPROVAL");
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  mkdirSync(outputDir, { recursive: true });
  writeFileSync(outputPath, "bounded output\n");
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => {
      replies.push(value);
      if (value.body.response === "once") return { error: { message: "approval failed" }, response: { ok: false } };
      return { data: {}, response: { ok: true } };
    } },
    isHeadless: () => true,
    home: root,
    dataHome,
    blockerLogPath: blockerLog,
  });
  broker.recordToolCall({ tool: "read", callID: "call-output-failed" }, { args: {} });

  await broker.handleEvent(toolOutputPermissionEvent({
    id: "permission-output-failed",
    callID: "call-output-failed",
    outputDir,
    outputPath,
  }));

  assert.deepEqual(replies.map((reply) => reply.body.response), ["once", "reject"]);
  assert.equal(JSON.parse(readFileSync(requestFile, "utf8")).requests[0].tool, "read");
  assert.equal(JSON.parse(readFileSync(blockerLog, "utf8")).reason, "permission_required");
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("tool-output exception rejects mutation tools and symlink escapes", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-permission-broker-")));
  const physicalDataHome = join(root, "physical-xdg-data");
  const dataHome = join(root, "linked-xdg-data");
  const physicalOutputDir = join(physicalDataHome, "opencode", "tool-output");
  const outputDir = join(dataHome, "opencode", "tool-output");
  const outsidePath = join(root, "outside.txt");
  const linkedOutput = join(outputDir, "tool_01LINKEDOUTPUT");
  const regularOutput = join(outputDir, "tool_01REGULAROUTPUT");
  const requestFile = join(root, "request.json");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  mkdirSync(physicalOutputDir, { recursive: true });
  symlinkSync(physicalDataHome, dataHome, "dir");
  writeFileSync(outsidePath, "outside\n");
  writeFileSync(regularOutput, "regular\n");
  symlinkSync(outsidePath, linkedOutput);
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true,
    home: root,
    dataHome,
    blockerLogPath: join(root, "blockers.jsonl"),
  });
  broker.recordToolCall({ tool: "edit", callID: "call-edit" }, { args: {} });
  broker.recordToolCall({ tool: "read", callID: "call-symlink" }, { args: {} });
  broker.recordToolCall({ tool: "read", callID: "call-symlink-directory" }, { args: {} });

  for (const [id, callID, outputPath] of [
    ["permission-edit", "call-edit", regularOutput],
    ["permission-symlink", "call-symlink", linkedOutput],
    ["permission-symlink-directory", "call-symlink-directory", regularOutput],
  ]) {
    await broker.handleEvent(toolOutputPermissionEvent({
      id,
      callID,
      outputDir,
      outputPath,
    }));
  }

  assert.deepEqual(replies.map((reply) => reply.body.response), ["reject", "reject", "reject"]);
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.deepEqual(capture.requests.map((request) => request.tool), ["edit", "read"]);
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("headless permission event is sanitized, persisted, and rejected", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  process.env.WORKER_ISSUE_NUMBER = "123";
  process.env.WORKER_REPO_SLUG = "owner/repo";
  process.env.WORKER_SESSION_KEY = "issue-123";
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true,
    home: "/Users/example",
    blockerLogPath: blockerLog,
  });
  broker.recordToolCall(
    { tool: "read", callID: "call-1" },
    { args: { agent__intent: "Reading SDK declarations token=secret-value" } },
  );
  await broker.handleEvent({ event: { type: "permission.asked", properties: {
    id: "permission-1",
    sessionID: "session-1",
    permission: "external_directory",
    patterns: ["/Users/example/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
    tool: { callID: "call-1", messageID: "message-1" },
  } } });
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(capture.issue, "123");
  assert.equal(capture.requests[0].tool, "read");
  assert.match(capture.requests[0].patterns[0], /^~\//);
  assert.doesNotMatch(capture.requests[0].intent, /secret-value/);
  assert.equal(replies[0].body.response, "reject");
  const blocker = JSON.parse(readFileSync(blockerLog, "utf8").trim());
  assert.equal(blocker.reason, "permission_required");
  assert.equal(blocker.blocking, true);
  assert.equal(blocker.issue_number, 123);
  assert.equal(blocker.repo_slug, "owner/repo");
  assert.equal(blocker.session_key, "issue-123");
  assert.doesNotMatch(blocker.detail, /secret-value/);
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("blocker events retain identity from an existing permission capture", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  delete process.env.WORKER_ISSUE_NUMBER;
  delete process.env.WORKER_REPO_SLUG;
  delete process.env.WORKER_SESSION_KEY;
  writeFileSync(requestFile, `${JSON.stringify({
    schema: "aidevops-permission-capture/v1",
    issue: "321",
    repo: "owner/repo",
    worker_session: "issue-321",
    requests: [],
  })}\n`);
  const broker = createPermissionBroker({
    client: {},
    isHeadless: () => true,
    home: "/Users/example",
    blockerLogPath: blockerLog,
  });
  await broker.permissionAsk({
    id: "permission-existing-capture",
    type: "external_directory",
    pattern: "/Users/example/.cache/opencode/tool/**",
  }, { status: "ask" });
  const blocker = JSON.parse(readFileSync(blockerLog, "utf8").trim());
  assert.equal(blocker.issue_number, 321);
  assert.equal(blocker.repo_slug, "owner/repo");
  assert.equal(blocker.session_key, "issue-321");
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("sensitive locations are non-grantable", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const blockerLog = join(root, "blockers.jsonl");
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example", blockerLogPath: blockerLog });
  const output = { status: "ask" };
  await broker.permissionAsk({
    id: "permission-2",
    type: "external_directory",
    pattern: "/Users/example/.ssh/**",
  }, output);
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(output.status, "deny");
  assert.equal(capture.requests[0].risk.grantable, false);
  assert.equal(JSON.parse(readFileSync(blockerLog, "utf8").trim()).reason, "permission_non_grantable");
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("requests without an exact pattern are non-grantable", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example", blockerLogPath: join(root, "blockers.jsonl") });
  const output = { status: "ask" };
  await broker.permissionAsk({ id: "permission-3", type: "bash", patterns: [] }, output);
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(capture.requests[0].risk.grantable, false);
  assert.match(capture.requests[0].risk.reason, /exact permission pattern/);
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("action-only permissions are non-grantable", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example", blockerLogPath: join(root, "blockers.jsonl") });
  await broker.permissionAsk({ id: "permission-4", type: "webfetch", patterns: ["example.invalid"] }, { status: "ask" });
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(capture.requests[0].risk.grantable, false);
  assert.match(capture.requests[0].risk.reason, /exact OpenCode pattern rule/);
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("capture write failure still denies the permission without crashing", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const blocker = join(root, "not-a-directory");
  writeFileSync(blocker, "block");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = join(blocker, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example", blockerLogPath: blockerLog });
  const output = { status: "ask" };
  await broker.permissionAsk({ id: "permission-5", type: "bash", patterns: ["git status"] }, output);
  assert.equal(output.status, "deny");
  assert.equal(JSON.parse(readFileSync(blockerLog, "utf8").trim()).reason, "capture_file_write_failed");
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("sanitizer normalizes home and redacts credential-like values", () => {
  const value = sanitizePermissionText("/Users/example/file token=abc123", { home: "/Users/example" });
  assert.equal(value, "~/file token=[REDACTED]");
});
