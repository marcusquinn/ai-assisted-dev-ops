// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";

import { BoundedInteractiveOperationManager } from "../bounded-interactive-operation.mjs";

const root = mkdtempSync(join(tmpdir(), "aidevops-bounded-operation-"));
const owner = { sessionID: "ses_owner" };
const recorded = [];
const managers = [];

after(() => {
  for (const manager of managers) manager.dispose();
  rmSync(root, { recursive: true, force: true });
});

function manager(options = {}) {
  const instance = new BoundedInteractiveOperationManager({
    projectRoot: root,
    killGraceMs: 10,
    recordOutput: async (content, evidence) => {
      recorded.push({ content: String(content), evidence });
      return `out_fixture_${recorded.length}`;
    },
    ...options,
  });
  managers.push(instance);
  return instance;
}

function launcher({ started = false } = {}) {
  return (runtime) => {
    const child = new EventEmitter();
    child.stdin = { end() {} };
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.connected = false;
    child.exitCode = null;
    child.signalCode = null;
    queueMicrotask(() => {
      child.emit("spawn");
      if (started) {
        child.emit("message", {
          type: "aidevops.operation",
          event: "command_started",
          operationID: "op_fixture",
          runtime: "node v22.23.1",
        });
      }
      child.exitCode = 0;
      child.emit("exit", 0, null);
      child.emit("close", 0, null);
    });
    assert.equal(runtime, "node");
    return child;
  };
}

async function terminal(instance, operationID, context = owner, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  let receipt;
  do {
    receipt = instance.status(operationID, context);
    if (!["starting", "running", "cancelling", "timing_out", "restoring", "finalizing"].includes(receipt.state)) return receipt;
    await new Promise((resolve) => setTimeout(resolve, 10));
  } while (Date.now() < deadline);
  throw new Error(`operation ${operationID} did not reach a terminal state: ${receipt?.state}`);
}

describe("bounded interactive operations", () => {
  test("start returns control and explicit progress reaches a private terminal receipt", async () => {
    const instance = manager();
    const before = Date.now();
    const started = await instance.start({
      command: [process.execPath, "-e", "console.log('AIDEVOPS_PROGRESS: phase-one'); setTimeout(() => process.exit(0), 80)"],
      cwd: root,
      budgetMs: 1000,
      progressIntervalMs: 30,
    }, owner);

    assert.equal(started.state, "running");
    assert.ok(Date.now() - before < 500, "start waited for command completion");
    const result = await terminal(instance, started.operation_id);
    assert.equal(result.state, "succeeded");
    assert.equal(result.process_exit, 0);
    assert.equal(result.progress_events, 1);
    assert.equal(result.output_id, "out_fixture_1");
    assert.equal(result.evidence_state, "recorded");
    assert.equal(result.restoration_state, "not_required");
    assert.equal(result.command_execution, "observed");
    assert.match(result.supervisor_runtime, /^node v\d+\./);
    assert.equal(JSON.stringify(result).includes("phase-one"), false);
  });

  test("failure, timeout, and scoped cancellation cannot appear as success", async () => {
    const instance = manager();
    const failed = await instance.start({
      command: [process.execPath, "-e", "process.exit(7)"],
      budgetMs: 1000,
      progressIntervalMs: 20,
    }, owner);
    assert.equal((await terminal(instance, failed.operation_id)).state, "failed");

    const timed = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"],
      budgetMs: 30,
      progressIntervalMs: 10,
    }, owner);
    const timedResult = await terminal(instance, timed.operation_id);
    assert.equal(timedResult.state, "timed_out");
    assert.notEqual(timedResult.process_signal, null);

    const forked = await instance.start({
      command: [process.execPath, "-e", "const {spawn}=require('node:child_process'); const c=spawn(process.execPath,['-e','setTimeout(()=>{},1000)'],{stdio:['ignore','inherit','inherit']}); c.unref()"],
      budgetMs: 60,
      progressIntervalMs: 20,
    }, owner);
    assert.equal((await terminal(instance, forked.operation_id)).state, "timed_out");

    const cancellable = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"],
      budgetMs: 1000,
      progressIntervalMs: 20,
    }, owner);
    assert.throws(() => instance.cancel(cancellable.operation_id, { sessionID: "ses_other" }), /owner mismatch/);
    assert.equal(instance.status(cancellable.operation_id, owner).state, "running");
    assert.equal(instance.cancel(cancellable.operation_id, owner).state, "cancelling");
    assert.equal((await terminal(instance, cancellable.operation_id)).state, "cancelled");

    const spawnFailure = await instance.start({
      command: [join(root, "missing-executable")],
      restorationCommand: [process.execPath, "-e", "process.exit(0)"],
      budgetMs: 1000,
      restorationBudgetMs: 1000,
    }, owner);
    const spawnFailureResult = await terminal(instance, spawnFailure.operation_id);
    assert.equal(spawnFailureResult.state, "failed");
    assert.equal(spawnFailureResult.restoration_state, "succeeded");
  });

  test("a launcher cannot report success without supervisor command evidence", async () => {
    const missingEvidence = manager({
      makeID: () => "op_fixture",
      spawn: launcher(),
    });
    const missingStarted = await missingEvidence.start({
      command: ["git", "--version"],
      budgetMs: 1000,
    }, owner);
    const missingResult = await terminal(missingEvidence, missingStarted.operation_id);
    assert.equal(missingResult.state, "failed");
    assert.equal(missingResult.process_exit, 0);
    assert.equal(missingResult.command_execution, "missing");

    const verifiedEvidence = manager({
      makeID: () => "op_fixture",
      spawn: launcher({ started: true }),
    });
    const verifiedStarted = await verifiedEvidence.start({
      command: ["git", "--version"],
      budgetMs: 1000,
    }, owner);
    const verifiedResult = await terminal(verifiedEvidence, verifiedStarted.operation_id);
    assert.equal(verifiedResult.state, "succeeded");
    assert.equal(verifiedResult.command_execution, "observed");
    assert.equal(verifiedResult.supervisor_runtime, "node v22.23.1");
  });

  test("restoration runs after success and remains visible when it fails", async () => {
    const instance = manager();
    const restored = await instance.start({
      command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "process.exit(0)"],
      budgetMs: 1000,
      restorationBudgetMs: 1000,
    }, owner);
    const restoredResult = await terminal(instance, restored.operation_id);
    assert.equal(restoredResult.state, "succeeded");
    assert.equal(restoredResult.restoration_state, "succeeded");
    assert.equal(restoredResult.restoration_exit, 0);

    const brokenRestore = await instance.start({
      command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "process.exit(9)"],
      budgetMs: 1000,
      restorationBudgetMs: 1000,
    }, owner);
    const brokenResult = await terminal(instance, brokenRestore.operation_id);
    assert.equal(brokenResult.state, "restoration_failed");
    assert.equal(brokenResult.restoration_state, "failed");
    assert.equal(brokenResult.restoration_exit, 9);

    const timedRestore = await instance.start({
      command: [process.execPath, "-e", "process.exit(0)"],
      restorationCommand: [process.execPath, "-e", "const {spawn}=require('node:child_process'); const c=spawn(process.execPath,['-e','setTimeout(()=>{},1000)'],{stdio:['ignore','inherit','inherit']}); c.unref()"],
      budgetMs: 1000,
      restorationBudgetMs: 30,
    }, owner);
    const timedRestoreResult = await terminal(instance, timedRestore.operation_id);
    assert.equal(timedRestoreResult.state, "restoration_failed");
    assert.equal(timedRestoreResult.restoration_state, "timed_out");
  });

  test("expired generations and private command data stay isolated", async () => {
    const instance = manager();
    assert.throws(() => instance.status("op_stale_generation", owner), /expired generation/);
    const privateValue = `${root}/private-token-value`;
    const started = await instance.start({
      command: [process.execPath, "-e", `console.log(${JSON.stringify(privateValue)})`],
      budgetMs: 1000,
    }, owner);
    const result = await terminal(instance, started.operation_id);
    const serialized = JSON.stringify(result);
    assert.equal(serialized.includes(root), false);
    assert.equal(serialized.includes("private-token-value"), false);
    assert.match(result.output_id, /^out_fixture_/);

    const newlineFree = await instance.start({
      command: [process.execPath, "-e", "process.stdout.write('x'.repeat(20000))"],
      budgetMs: 1000,
    }, owner);
    await terminal(instance, newlineFree.operation_id);
    assert.ok(instance.operations.get(newlineFree.operation_id).progressRemainder.length <= 4096);
  });

  test("session deletion cancels only operations owned by that session", async () => {
    const instance = manager();
    const first = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => {}, 1000)"],
      budgetMs: 1000,
    }, owner);
    const secondOwner = { sessionID: "ses_second" };
    const second = await instance.start({
      command: [process.execPath, "-e", "setTimeout(() => process.exit(0), 100)"],
      budgetMs: 1000,
    }, secondOwner);
    instance.handleEvent({ event: { type: "session.deleted", properties: { info: { id: owner.sessionID } } } });
    const deadline = Date.now() + 2000;
    while (instance.operations.has(first.operation_id) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(instance.operations.has(first.operation_id), false);
    assert.equal((await terminal(instance, second.operation_id, secondOwner)).state, "succeeded");
  });
});
