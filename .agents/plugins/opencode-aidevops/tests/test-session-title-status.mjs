// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import { createSessionTitleStatusHandler } from "../session-title-status.mjs";
import {
  createTerminalTitleController,
  TERMINAL_TITLE_CONTROLLER_SYMBOL,
  terminalTitleSequence,
  withTerminalTitleStatus,
} from "../terminal-title.mjs";

function event(type, properties = {}) {
  return { event: { type, properties } };
}

test("terminal titles map OpenCode status to compact idempotent emoji prefixes", () => {
  assert.equal(withTerminalTitleStatus("Issue #123: improve tabs", "busy"), "⚪ Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("🟢 Issue #123: improve tabs", "retry"), "🔴 Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("🔴 Issue #123: improve tabs", "busy"), "⚪ Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("⚪ Issue #123: improve tabs", "permission"), "🟡 Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("🟡 Issue #123: improve tabs", "idle"), "🟢 Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("[RUN] Issue #123: improve tabs", "idle"), "🟢 Issue #123: improve tabs");
  assert.equal(withTerminalTitleStatus("Issue #123: improve tabs", "unknown"), "Issue #123: improve tabs");
});

test("terminal title controller preserves status across later session title updates", () => {
  const writes = [];
  const controller = createTerminalTitleController({
    isEnabled: () => true,
    writeTitle: (title) => writes.push(title),
  });

  controller.emit("Issue #123: initial title");
  controller.setStatus("busy");
  controller.emit("Issue #123: renamed title");
  controller.setStatus("retry");
  controller.setStatus("permission");
  controller.setStatus("busy");
  controller.setStatus("idle");
  controller.setStatus("");
  controller.reset();
  controller.setStatus("busy");

  assert.deepEqual(writes, [
    "Issue #123: initial title",
    "⚪ Issue #123: initial title",
    "⚪ Issue #123: renamed title",
    "🔴 Issue #123: renamed title",
    "🟡 Issue #123: renamed title",
    "⚪ Issue #123: renamed title",
    "🟢 Issue #123: renamed title",
    "Issue #123: renamed title",
  ]);
});

test("terminal title controller reasserts an unchanged status after a competing write", () => {
  const writes = [];
  const controller = createTerminalTitleController({
    isEnabled: () => true,
    writeTitle: (title) => writes.push(title),
  });

  controller.emit("Issue #123: durable status");
  controller.setStatus("busy");
  writes.push("OC | Issue #123: durable status");
  controller.setStatus("busy");

  assert.equal(writes.at(-1), "⚪ Issue #123: durable status");
  assert.equal(typeof Reflect.get(globalThis, TERMINAL_TITLE_CONTROLLER_SYMBOL)?.emit, "function");
});

test("terminal title controller yields to explicit native ownership", () => {
  const previousOwner = process.env.AIDEVOPS_TERMINAL_TITLE_OWNER;
  const writes = [];
  process.env.AIDEVOPS_TERMINAL_TITLE_OWNER = "native";
  try {
    const controller = createTerminalTitleController({ writeTitle: (title) => writes.push(title) });
    assert.equal(controller.emit("Issue #123: native owner"), false);
    assert.equal(controller.setStatus("busy"), false);
    assert.deepEqual(writes, []);
  } finally {
    if (previousOwner === undefined) delete process.env.AIDEVOPS_TERMINAL_TITLE_OWNER;
    else process.env.AIDEVOPS_TERMINAL_TITLE_OWNER = previousOwner;
  }
});

test("terminal title sequences reject empty and control-only titles", () => {
  assert.equal(terminalTitleSequence("\n\t"), "");
  assert.equal(terminalTitleSequence("Task\u0007 title"), "\u001B]0;Task  title\u0007");
});

test("session status handler follows only the active interactive root session", async () => {
  const statuses = [];
  let resets = 0;
  const handler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    isEnabled: () => true,
    resetTerminalTitleState: () => {
      resets += 1;
    },
    setTerminalTitleStatus: (status) => statuses.push(status),
  });

  await handler(event("session.created", { info: { id: "root-1", title: "Root" } }));
  await handler(event("session.created", { info: { id: "child-1", parentID: "root-1", title: "Child" } }));
  await handler(event("session.status", { sessionID: "child-1", status: { type: "busy" } }));
  await handler(event("permission.replied", { requestID: "unknown", sessionID: "root-1", reply: "once" }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "busy" } }));
  await handler(event("permission.asked", { id: "permission-child", sessionID: "child-1" }));
  await handler(event("permission.asked", { id: "permission-root", sessionID: "root-1" }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "idle" } }));
  await handler(event("permission.replied", { requestID: "permission-root", sessionID: "root-1", reply: "once" }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "retry" } }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "idle" } }));
  await handler(event("session.created", { info: { id: "root-2", title: "New root" } }));
  await handler(event("session.status", { sessionID: "root-1", status: { type: "busy" } }));
  await handler(event("session.status", { sessionID: "root-2", status: { type: "idle" } }));

  assert.equal(resets, 2);
  assert.deepEqual(statuses, ["idle", "busy", "permission", "busy", "retry", "idle", "idle", "idle"]);
});

test("first root user message marks the session busy before native status", async () => {
  const statuses = [];
  const handler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    isEnabled: () => true,
    setTerminalTitleStatus: (status) => statuses.push(status),
  });

  await handler(event("message.updated", { info: { role: "user" } }));
  await handler(event("permission.asked", { id: "permission-without-session" }));
  await handler(event("session.created", { info: { id: "root-1", title: "Root" } }));
  await handler(event("message.updated", {
    sessionID: "child-1",
    info: { id: "message-child", sessionID: "child-1", role: "user" },
  }));
  await handler(event("message.updated", {
    sessionID: "root-1",
    info: { id: "message-assistant", sessionID: "root-1", role: "assistant" },
  }));
  await handler(event("message.updated", {
    sessionID: "root-1",
    info: { id: "message-user", sessionID: "root-1", role: "user" },
  }));
  await handler(event("permission.asked", { id: "permission-root", sessionID: "root-1" }));
  await handler(event("message.updated", {
    sessionID: "root-1",
    info: { id: "message-user-2", sessionID: "root-1", role: "user" },
  }));

  assert.deepEqual(statuses, ["idle", "busy", "permission"]);
});

test("terminal root assistant completion restores idle without a native idle event", async () => {
  const statuses = [];
  const handler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    isEnabled: () => true,
    setTerminalTitleStatus: (status) => statuses.push(status),
  });

  await handler(event("session.created", { info: { id: "root-completion", title: "Completion" } }));
  await handler(event("message.updated", {
    info: { id: "user-1", sessionID: "root-completion", role: "user", time: { created: 10 } },
  }));
  await handler(event("message.updated", {
    info: {
      id: "assistant-tools",
      sessionID: "root-completion",
      parentID: "user-1",
      role: "assistant",
      finish: "tool-calls",
      time: { created: 10, completed: 20 },
    },
  }));
  await handler(event("message.updated", {
    info: {
      id: "assistant-without-parent",
      sessionID: "root-completion",
      role: "assistant",
      finish: "stop",
      time: { created: 10, completed: 20 },
    },
  }));
  await handler(event("message.updated", {
    info: {
      id: "assistant-stale",
      sessionID: "root-completion",
      parentID: "older-user",
      role: "assistant",
      finish: "stop",
      time: { created: 10, completed: 20 },
    },
  }));
  const terminalCompletion = event("message.updated", {
    info: {
      id: "assistant-final",
      sessionID: "root-completion",
      parentID: "user-1",
      role: "assistant",
      finish: "stop",
      time: { created: 10, completed: 30 },
    },
  });
  await handler(terminalCompletion);
  await handler(terminalCompletion);
  await handler(event("session.status", { sessionID: "root-completion", status: { type: "busy" } }));
  await handler(event("message.updated", {
    info: { id: "user-2", sessionID: "root-completion", role: "user", time: { created: 40 } },
  }));
  await handler(event("message.updated", {
    info: { id: "user-1", sessionID: "root-completion", role: "user", time: { created: 10 } },
  }));
  await handler(event("message.updated", {
    info: { id: "unseen-older-user", sessionID: "root-completion", role: "user", time: { created: 5 } },
  }));
  await handler(terminalCompletion);
  await handler(event("message.updated", {
    info: {
      id: "assistant-final-2",
      sessionID: "root-completion",
      parentID: "user-2",
      role: "assistant",
      finish: "end_turn",
      time: { created: 40, completed: 50 },
    },
  }));

  assert.deepEqual(statuses, ["idle", "busy", "idle", "busy", "idle"]);
});

test("legacy idle and permission events retain lifecycle status compatibility", async () => {
  const statuses = [];
  const handler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    isEnabled: () => true,
    setTerminalTitleStatus: (status) => statuses.push(status),
  });

  await handler(event("session.created", { info: { id: "root-legacy", title: "Legacy" } }));
  await handler(event("session.idle", { sessionID: "root-legacy" }));
  await handler(event("permission.updated", { id: "permission-legacy", sessionID: "root-legacy" }));
  await handler(event("session.idle", { sessionID: "root-legacy" }));
  await handler(event("permission.replied", {
    permissionID: "permission-legacy",
    response: "once",
    sessionID: "root-legacy",
  }));
  await handler(event("session.idle", { sessionID: "root-legacy" }));

  assert.deepEqual(statuses, ["idle", "idle", "permission", "busy", "idle"]);
});

test("permission status persists until current and legacy requests both reply", async () => {
  const statuses = [];
  const handler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    isEnabled: () => true,
    setTerminalTitleStatus: (status) => statuses.push(status),
  });

  await handler(event("session.created", { info: { id: "root-pending", title: "Pending" } }));
  await handler(event("permission.asked", { id: "permission-current", sessionID: "root-pending" }));
  await handler(event("permission.updated", { id: "permission-legacy", sessionID: "root-pending" }));
  await handler(event("permission.replied", {
    requestID: "permission-current",
    reply: "once",
    sessionID: "root-pending",
  }));
  await handler(event("session.status", { sessionID: "root-pending", status: { type: "idle" } }));
  await handler(event("permission.replied", {
    permissionID: "permission-legacy",
    response: "once",
    sessionID: "root-pending",
  }));
  await handler(event("session.idle", { sessionID: "root-pending" }));

  assert.deepEqual(statuses, ["idle", "permission", "permission", "busy", "idle"]);
});

test("event lifecycle renders idle, busy, permission, and waiting titles end to end", async () => {
  const writes = [];
  const controller = createTerminalTitleController({
    isEnabled: () => true,
    writeTitle: (title) => writes.push(title),
  });
  const handler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    isEnabled: () => true,
    resetTerminalTitleState: () => controller.reset(),
    setTerminalTitleStatus: (status) => controller.setStatus(status),
  });

  await handler(event("session.created", { info: { id: "root-e2e", title: "Lifecycle" } }));
  controller.emit("Issue #123: lifecycle status");
  await handler(event("message.updated", {
    sessionID: "root-e2e",
    info: { id: "message-user", sessionID: "root-e2e", role: "user" },
  }));
  await handler(event("permission.asked", { id: "permission-current", sessionID: "root-e2e" }));
  await handler(event("session.status", { sessionID: "root-e2e", status: { type: "idle" } }));
  await handler(event("permission.replied", {
    requestID: "permission-current",
    reply: "once",
    sessionID: "root-e2e",
  }));
  await handler(event("session.status", { sessionID: "root-e2e", status: { type: "idle" } }));

  assert.deepEqual(writes, [
    "🟢 Issue #123: lifecycle status",
    "⚪ Issue #123: lifecycle status",
    "🟡 Issue #123: lifecycle status",
    "⚪ Issue #123: lifecycle status",
    "🟢 Issue #123: lifecycle status",
  ]);
});

test("session status handler supports hot-loaded root sessions and ignores headless sessions", async () => {
  const statuses = [];
  let resets = 0;
  const interactiveHandler = createSessionTitleStatusHandler({
    isHeadless: () => false,
    resetTerminalTitleState: () => {
      resets += 1;
    },
    setTerminalTitleStatus: (status) => statuses.push(status),
  });
  await interactiveHandler(event("session.updated", { info: { id: "restored-root", title: "Restored" } }));
  await interactiveHandler(event("session.status", { sessionID: "restored-root", status: { type: "busy" } }));
  await interactiveHandler(event("message.updated", {
    info: {
      id: "historical-assistant",
      sessionID: "restored-root",
      parentID: "historical-user",
      role: "assistant",
      finish: "stop",
      time: { created: 10, completed: 20 },
    },
  }));

  const headlessHandler = createSessionTitleStatusHandler({
    isHeadless: () => true,
    resetTerminalTitleState: () => {
      resets += 1;
    },
    setTerminalTitleStatus: (status) => statuses.push(status),
  });
  await headlessHandler(event("session.created", { info: { id: "headless-root" } }));
  await headlessHandler(event("message.updated", {
    sessionID: "headless-root",
    info: { id: "message-user", sessionID: "headless-root", role: "user" },
  }));
  await headlessHandler(event("session.status", { sessionID: "headless-root", status: { type: "idle" } }));

  assert.equal(resets, 1);
  assert.deepEqual(statuses, ["idle", "busy"]);
});
