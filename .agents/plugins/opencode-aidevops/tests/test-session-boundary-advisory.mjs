// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createSessionBoundaryAdvisory,
  DEFAULT_THRESHOLD_MS,
} from "../session-boundary-advisory.mjs";

function event(type, properties = {}) {
  return { event: { type, properties } };
}

function fixture({ headless = false, competing = false, now = DEFAULT_THRESHOLD_MS } = {}) {
  const toasts = [];
  let currentTime = now;
  let competingToast = competing;
  const sessions = new Map();
  const handler = createSessionBoundaryAdvisory({
    client: {
      session: { get: async ({ path }) => ({ data: sessions.get(path.id) }) },
      tui: { showToast: async (toast) => toasts.push(toast) },
    },
    hasCompetingToast: () => competingToast,
    isHeadless: () => headless,
    now: () => currentTime,
  });
  return {
    handler,
    sessions,
    toasts,
    setCompeting: (value) => {
      competingToast = value;
    },
    setNow: (value) => {
      currentTime = value;
    },
  };
}

test("emits once at an eligible interactive root idle boundary", async () => {
  const f = fixture({ now: 0 });
  await f.handler(event("session.created", { info: { id: "root", time: { created: 0 } } }));
  await f.handler(event("session.status", { sessionID: "root", status: { type: "busy" } }));
  f.setNow(DEFAULT_THRESHOLD_MS - 1);
  await f.handler(event("session.idle", { sessionID: "root" }));
  assert.equal(f.toasts.length, 0);

  await f.handler(event("session.updated", { info: { id: "root" } }));
  f.setNow(DEFAULT_THRESHOLD_MS);
  await f.handler(event("session.idle", { sessionID: "root" }));
  await f.handler(event("session.idle", { sessionID: "root" }));
  assert.equal(f.toasts.length, 1);
  assert.equal(f.toasts[0].body.title, "Session checkpoint");
  assert.match(f.toasts[0].body.message, /continuation checkpoint/);
  assert.match(f.toasts[0].body.message, /task IDs/);
  assert.match(f.toasts[0].body.message, /\/new/);
  assert.match(f.toasts[0].body.message, /Active work continues/);
});

test("excludes child, unknown, under-threshold, and headless sessions", async () => {
  const child = fixture({ now: DEFAULT_THRESHOLD_MS });
  await child.handler(event("session.created", {
    info: { id: "child", parentID: "root", time: { created: 0 } },
  }));
  await child.handler(event("session.idle", { sessionID: "child" }));
  await child.handler(event("session.idle", { sessionID: "unknown" }));
  assert.equal(child.toasts.length, 0);

  const headless = fixture({ headless: true, now: DEFAULT_THRESHOLD_MS });
  await headless.handler(event("session.created", { info: { id: "root", time: { created: 0 } } }));
  await headless.handler(event("session.idle", { sessionID: "root" }));
  assert.equal(headless.toasts.length, 0);
});

test("defers to another idle toast and clears state on deletion", async () => {
  const f = fixture({ competing: true, now: DEFAULT_THRESHOLD_MS });
  await f.handler(event("session.created", { info: { id: "root", time: { created: 0 } } }));
  await f.handler(event("session.idle", { sessionID: "root" }));
  assert.equal(f.toasts.length, 0);

  f.setCompeting(false);
  await f.handler(event("session.idle", { sessionID: "root" }));
  assert.equal(f.toasts.length, 1);
  await f.handler(event("session.deleted", { info: { id: "root" } }));
  await f.handler(event("session.created", { info: { id: "root", time: { created: 0 } } }));
  await f.handler(event("session.idle", { sessionID: "root" }));
  assert.equal(f.toasts.length, 2);
});
