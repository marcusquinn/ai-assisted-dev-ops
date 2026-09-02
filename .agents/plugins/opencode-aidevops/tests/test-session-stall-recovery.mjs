// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  createSessionStallRecovery,
  PersistentRecoveryLedger,
  safeToolCall,
} from "../session-stall-recovery.mjs";

function event(type, properties) {
  return { event: { type, properties } };
}

function memoryLedger() {
  const claims = new Set();
  return {
    async claim(sessionID, fingerprint) {
      const key = `${sessionID}:${fingerprint}`;
      if (claims.has(key)) return false;
      claims.add(key);
      return true;
    },
  };
}

function fixture() {
  let current = 1_000;
  let status = "busy";
  let statusAvailable = true;
  let statusHook = async () => {};
  let abortHook = async () => {};
  const calls = { abort: 0, prompt: 0 };
  const client = {
    session: {
      abort: async () => {
        calls.abort += 1;
        status = "idle";
        await abortHook();
        return { data: true };
      },
      prompt: async () => {
        calls.prompt += 1;
        return { data: true };
      },
      status: async () => {
        await statusHook();
        statusHook = async () => {};
        return statusAvailable ? { data: { ses_primary: { type: status } } } : { data: {} };
      },
    },
  };
  const recovery = createSessionStallRecovery({
    client,
    directory: "/workspace",
    workDir: "/unused",
    isEnabled: () => true,
    clock: () => current,
    staleMs: 100,
    idleWaitMs: 10,
    sleep: async (milliseconds) => { current += milliseconds; },
    ledger: memoryLedger(),
  });
  recovery.handleEvent(event("session.created", { info: { id: "ses_primary" } }));
  recovery.handleEvent(event("session.status", { sessionID: "ses_primary", status: { type: "busy" } }));
  return {
    calls,
    recovery,
    advance: (milliseconds) => { current += milliseconds; },
    onAbort: (hook) => { abortHook = hook; },
    onStatus: (hook) => { statusHook = hook; },
    setStatus: (value) => { status = value; },
    setStatusAvailable: (value) => { statusAvailable = value; },
  };
}

assert.equal(safeToolCall("read"), true);
assert.equal(safeToolCall("aidevops_memory", { action: "recall" }), true);
assert.equal(safeToolCall("aidevops_memory", { action: "store" }), false);
assert.equal(safeToolCall("bash", { command: "npm test" }), false);
assert.equal(safeToolCall("apply_patch"), false);

{
  const test = fixture();
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), ["ses_primary"]);
  assert.deepEqual(test.calls, { abort: 1, prompt: 1 });
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 1, prompt: 1 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.onStatus(async () => {
    test.recovery.handleEvent(event("permission.asked", {
      sessionID: "ses_primary",
      id: "permission-during-check",
    }));
  });
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 0, prompt: 0 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.recovery.handleEvent(event("permission.asked", {
    sessionID: "ses_primary",
    id: "permission-1",
  }));
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 0, prompt: 0 });
  test.recovery.handleEvent(event("permission.replied", {
    sessionID: "ses_primary",
    requestID: "permission-1",
  }));
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), ["ses_primary"]);
  test.recovery.stop();
}

{
  const test = fixture();
  test.recovery.beforeTool(
    { sessionID: "ses_primary", callID: "call-write", tool: "apply_patch" },
    { args: { patchText: "redacted" } },
  );
  test.recovery.afterTool({ sessionID: "ses_primary", callID: "call-write", tool: "apply_patch" });
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 0, prompt: 0 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.recovery.beforeTool(
    { sessionID: "ses_primary", callID: "call-read", tool: "read" },
    { args: { filePath: "/workspace/file" } },
  );
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), ["ses_primary"]);
  assert.deepEqual(test.calls, { abort: 1, prompt: 1 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.setStatus("idle");
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 0, prompt: 0 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.recovery.handleEvent(event("session.updated", {
    info: { id: "ses_primary", parentID: "ses_parent" },
  }));
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 0, prompt: 0 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.onAbort(async () => {
    test.recovery.handleEvent(event("message.part.updated", {
      part: {
        sessionID: "ses_primary",
        callID: "call-read",
        type: "tool",
        tool: "read",
        state: { status: "aborted" },
      },
    }));
  });
  test.recovery.beforeTool(
    { sessionID: "ses_primary", callID: "call-read", tool: "read" },
    { args: { filePath: "/workspace/file" } },
  );
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), ["ses_primary"]);
  assert.deepEqual(test.calls, { abort: 1, prompt: 1 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.onAbort(async () => {
    test.recovery.handleEvent(event("message.updated", {
      info: { id: "msg_user", sessionID: "ses_primary", role: "user" },
    }));
  });
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 1, prompt: 0 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.onStatus(async () => {
    test.recovery.handleEvent(event("message.updated", {
      info: { sessionID: "ses_primary", role: "user" },
    }));
  });
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 0, prompt: 0 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.onAbort(async () => { test.setStatusAvailable(false); });
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 1, prompt: 0 });
  test.recovery.stop();
}

{
  const test = fixture();
  test.recovery.handleEvent(event("session.updated", {
    info: { id: "ses_primary", parentID: "ses_parent" },
  }));
  test.recovery.handleEvent(event("session.updated", { info: { id: "ses_primary" } }));
  test.advance(101);
  assert.deepEqual(await test.recovery.checkNow(), []);
  assert.deepEqual(test.calls, { abort: 0, prompt: 0 });
  test.recovery.stop();
}

{
  const tempRoot = process.env.AIDEVOPS_TEMP_DIR
    || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  await mkdir(tempRoot, { recursive: true, mode: 0o700 });
  const root = await mkdtemp(join(tempRoot, "stall-recovery-ledger-"));
  let current = 100_000;
  try {
    const ledger = new PersistentRecoveryLedger(root, () => current, 1_000);
    const lockPath = `${ledger.pathFor("ses_primary")}.lock`;
    await writeFile(lockPath, "", { mode: 0o600 });
    await utimes(lockPath, new Date(0), new Date(0));
    assert.equal(await ledger.claim("ses_primary", "fingerprint", 5_000), true);
    assert.equal(await ledger.claim("ses_primary", "fingerprint", 5_000), false);
    current += 5_001;
    assert.equal(await ledger.claim("ses_primary", "fingerprint", 5_000), true);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

console.log("session stall recovery tests passed");
