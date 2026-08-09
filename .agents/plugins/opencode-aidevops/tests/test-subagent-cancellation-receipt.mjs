// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { describe, test } from "node:test";

import {
  MAX_CANCELLATION_LEDGER_ENTRIES,
  MAX_CANCELLATION_RECEIPT_BYTES,
  classifySideEffect,
  createSubagentCancellationReceipt,
} from "../subagent-cancellation-receipt.mjs";

function event(type, properties) {
  return { event: { type, properties } };
}

function receiptFrom(output) {
  const marker = "[AIDevOps cancellation receipt]\n";
  return JSON.parse(output.output.slice(output.output.indexOf(marker) + marker.length));
}

describe("side-effect classification", () => {
  const fixtures = [
    ["Write", { filePath: "/private/file" }, "file", "write"],
    ["functions.apply_patch", { patchText: "secret" }, "file", "write"],
    ["bash", { command: "git worktree add /private/worktree branch" }, "git", "worktree"],
    ["bash", { command: "git update-ref refs/heads/private deadbeef" }, "git", "ref"],
    ["bash", { command: "git remote set-url origin private-url" }, "git", "remote"],
    ["bash", { command: "git commit -m private" }, "git", "commit"],
    ["bash", { command: "git push origin private" }, "git", "push"],
    ["bash", { command: "gh repo fork owner/private" }, "github", "fork"],
    ["bash", { command: "gh issue create --title private" }, "github", "issue"],
    ["bash", { command: "gh pr create --title private" }, "github", "pull_request"],
    ["bash", { command: "gh repo create private" }, "github", "repository"],
    ["bash", { command: "curl --request POST https://private.invalid" }, "external", "write"],
  ];

  for (const [tool, args, kind, operation] of fixtures) {
    test(`${kind}.${operation} from ${tool}`, () => {
      assert.deepEqual(classifySideEffect(tool, args), {
        kind,
        operation,
        tool: tool.toLowerCase(),
      });
    });
  }

  test("read-only and todo tools are not reported as side effects", () => {
    assert.equal(classifySideEffect("Read", { filePath: "/private/file" }), null);
    assert.equal(classifySideEffect("TodoWrite", { todos: [] }), null);
    assert.equal(classifySideEffect("bash", { command: "git status --short" }), null);
    assert.equal(classifySideEffect("bash", { command: "gh issue view 1" }), null);
  });
});

test("cancelled tasks wait for child termination and return a status-classified redacted ledger", async () => {
  let lifecycle;
  let abortCalled = false;
  const client = {
    session: {
      abort: async ({ path }) => {
        assert.equal(path.id, "child-1");
        abortCalled = true;
        queueMicrotask(() => lifecycle.handleEvent(event("session.status", {
          sessionID: "child-1",
          status: { type: "idle" },
        })));
        return { data: true };
      },
    },
  };
  lifecycle = createSubagentCancellationReceipt(client, {
    maxWaitMs: 100,
    pollMs: 1,
    recordReceipt: () => ({ recorded: true }),
  });

  lifecycle.beforeTool(
    { tool: "task", sessionID: "parent-1", callID: "task-call" },
    { args: { prompt: "private task" } },
  );
  lifecycle.handleEvent(event("session.created", {
    info: { id: "child-1", parentID: "parent-1" },
  }));

  lifecycle.beforeTool(
    { tool: "write", sessionID: "child-1", callID: "file-call" },
    { args: { filePath: "/Users/private/repository/file.txt", content: "ghp_privatevalue" } },
  );
  await lifecycle.afterTool(
    { tool: "write", sessionID: "child-1", callID: "file-call" },
    { output: "written" },
  );
  lifecycle.beforeTool(
    { tool: "bash", sessionID: "child-1", callID: "commit-call" },
    { args: { command: "git commit -m private" } },
  );
  await lifecycle.afterTool(
    { tool: "bash", sessionID: "child-1", callID: "commit-call" },
    { status: "failed", output: "failed" },
  );
  lifecycle.beforeTool(
    { tool: "bash", sessionID: "child-1", callID: "push-call" },
    { args: { command: "git push https://user:secret@example.invalid/private/repo" } },
  );
  lifecycle.beforeTool(
    { tool: "bash", sessionID: "child-1", callID: "fork-call" },
    { args: { command: "gh repo fork owner/private --clone=false" } },
  );
  await lifecycle.afterTool(
    { tool: "bash", sessionID: "child-1", callID: "fork-call" },
    { output: "forked" },
  );

  const output = {
    title: "Task aborted",
    output: "The task was aborted",
    metadata: { sessionId: "child-1", status: "aborted" },
  };
  const receipt = await lifecycle.afterTool(
    { tool: "task", sessionID: "parent-1", callID: "task-call" },
    output,
  );

  assert.equal(abortCalled, true);
  assert.equal(receipt.termination, "confirmed");
  assert.equal(receipt.reaped, true);
  assert.equal(receipt.telemetry, "recorded");
  assert.equal(receipt.complete, false);
  assert.ok(receipt.incomplete_reasons.includes("side_effect_outcome_unknown"));
  assert.deepEqual(new Set(receipt.ledger.map((entry) => entry.status)), new Set([
    "attempted", "completed", "failed", "unknown",
  ]));
  assert.deepEqual(new Set(receipt.ledger.map((entry) => `${entry.kind}.${entry.operation}`)), new Set([
    "file.write", "git.commit", "git.push", "github.fork",
  ]));
  assert.doesNotMatch(
    JSON.stringify(receipt),
    /Users|private|repository|ghp_|user:secret|owner\//i,
  );
  assert.deepEqual(output.metadata.aidevopsCancellationReceipt, receipt);
});

test("missing lifecycle events and telemetry produce an explicit incomplete unknown receipt", async () => {
  let abortCalls = 0;
  const lifecycle = createSubagentCancellationReceipt({
    session: {
      abort: async () => {
        abortCalls += 1;
        return { data: true };
      },
    },
  }, {
    maxWaitMs: 0,
    recordReceipt: () => null,
  });
  lifecycle.beforeTool(
    { tool: "task", sessionID: "parent-missing", callID: "task-missing" },
    { args: {} },
  );
  const output = {
    output: "Operation cancelled",
    metadata: { sessionId: "child-missing", status: "cancelled" },
  };

  const receipt = await lifecycle.afterTool(
    { tool: "task", sessionID: "parent-missing", callID: "task-missing" },
    output,
  );

  assert.equal(abortCalls, 1);
  assert.equal(receipt.termination, "unconfirmed");
  assert.equal(receipt.reaped, false);
  assert.equal(receipt.complete, false);
  assert.ok(receipt.incomplete_reasons.includes("termination_unconfirmed"));
  assert.ok(receipt.incomplete_reasons.includes("lifecycle_events_missing"));
  assert.ok(receipt.incomplete_reasons.includes("telemetry_unavailable"));
  assert.equal(receipt.ledger.length, 1);
  assert.equal(receipt.ledger[0].status, "unknown");
});

test("aggregate cancellation Task metadata remains intact and reports missing child identity", async () => {
  let abortCalls = 0;
  let persistedParentID = "not-recorded";
  const lifecycle = createSubagentCancellationReceipt({
    session: {
      abort: async () => {
        abortCalls += 1;
        return { data: true };
      },
    },
  }, {
    maxWaitMs: 0,
    recordReceipt: (_receipt, context) => {
      persistedParentID = context.parentSessionID;
      return true;
    },
  });
  lifecycle.beforeTool(
    { tool: "task", sessionID: "parent-aggregate", callID: "aggregate-cancel" },
    { args: {} },
  );
  const output = {
    output: "Task aborted",
    metadata: { sessionID: ["child-aggregate"], status: "aborted", hostValue: { preserved: true } },
  };

  const receipt = await lifecycle.afterTool(
    { tool: "task", sessionID: "parent-aggregate", callID: "aggregate-cancel" },
    output,
  );

  assert.equal(abortCalls, 0);
  assert.equal(receipt.termination, "unconfirmed");
  assert.ok(receipt.incomplete_reasons.includes("child_identity_missing"));
  assert.equal(persistedParentID, "parent-aggregate");
  assert.deepEqual(output.metadata.sessionID, ["child-aggregate"]);
  assert.deepEqual(output.metadata.hostValue, { preserved: true });
});

test("abort and receipt persistence failures are logged for diagnostics", async () => {
  const logs = [];
  const lifecycle = createSubagentCancellationReceipt({
    session: {
      abort: async () => {
        throw new Error("abort unavailable");
      },
    },
  }, {
    maxWaitMs: 0,
    qualityLog: (level, message) => logs.push([level, message]),
    recordReceipt: () => {
      throw new Error("telemetry unavailable");
    },
  });
  lifecycle.beforeTool(
    { tool: "task", sessionID: "parent-failure", callID: "task-failure" },
    { args: {} },
  );
  const output = {
    output: "Task aborted",
    metadata: { sessionId: "child-failure", status: "aborted" },
  };

  const receipt = await lifecycle.afterTool(
    { tool: "task", sessionID: "parent-failure", callID: "task-failure" },
    output,
  );

  assert.equal(receipt.complete, false);
  assert.ok(receipt.incomplete_reasons.includes("abort_api_failed"));
  assert.ok(receipt.incomplete_reasons.includes("telemetry_unavailable"));
  assert.deepEqual(logs.slice(0, 2), [
    ["WARN", "[subagent-cancellation] session abort failed: abort unavailable"],
    ["WARN", "[subagent-cancellation] receipt persistence failed: telemetry unavailable"],
  ]);
});

test("the parent-facing receipt remains entry- and byte-bounded", async () => {
  let lifecycle;
  const client = {
    session: {
      abort: async () => {
        lifecycle.handleEvent(event("session.status", {
          sessionID: "child-bounded",
          status: { type: "idle" },
        }));
        return { data: true };
      },
    },
  };
  lifecycle = createSubagentCancellationReceipt(client, {
    maxWaitMs: 0,
    recordReceipt: () => true,
  });
  lifecycle.beforeTool(
    { tool: "task", sessionID: "parent-bounded", callID: "task-bounded" },
    { args: {} },
  );
  lifecycle.handleEvent(event("session.created", {
    info: { id: "child-bounded", parentID: "parent-bounded" },
  }));
  for (let index = 0; index < MAX_CANCELLATION_LEDGER_ENTRIES + 8; index += 1) {
    const callID = `write-${index}`;
    lifecycle.beforeTool(
      { tool: "write", sessionID: "child-bounded", callID },
      { args: { filePath: `/private/${index}` } },
    );
    await lifecycle.afterTool(
      { tool: "write", sessionID: "child-bounded", callID },
      { output: "written" },
    );
  }
  const output = {
    output: "Task aborted",
    metadata: { sessionId: "child-bounded", status: "aborted" },
  };
  const receipt = await lifecycle.afterTool(
    { tool: "task", sessionID: "parent-bounded", callID: "task-bounded" },
    output,
  );

  assert.equal(receipt.ledger.length, MAX_CANCELLATION_LEDGER_ENTRIES);
  assert.equal(receipt.truncated, true);
  assert.equal(receipt.complete, false);
  assert.ok(Buffer.byteLength(JSON.stringify(receipt), "utf8") <= MAX_CANCELLATION_RECEIPT_BYTES);
  assert.deepEqual(receiptFrom(output), receipt);
});
