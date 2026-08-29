// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  cleanupPrivateRuntime,
  createPrivateRuntime,
  probeAuthenticatedRelay,
  validatePlaywriterCommand,
} from "../playwriter-authenticated-relay.mjs";

test("accepts only reviewed Playwriter package-runner commands", () => {
  assert.deepEqual(validatePlaywriterCommand(["npx", "playwriter@0.5.0"]), [
    "npx", "playwriter@0.5.0",
  ]);
  assert.deepEqual(validatePlaywriterCommand(["bun", "x", "playwriter@0.5.0"]), [
    "bun", "x", "playwriter@0.5.0",
  ]);
  assert.throws(
    () => validatePlaywriterCommand(["npx", "playwriter@latest"]),
    /reviewed Playwriter package shape/,
  );
  assert.throws(
    () => validatePlaywriterCommand(["sh", "-c", "playwriter@0.5.0"]),
    /reviewed Playwriter package shape/,
  );
});

test("proves both relay version and token enforcement", async (t) => {
  const token = "a".repeat(32);
  const server = createServer((request, response) => {
    if (request.url === "/version") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"version":"0.5.0"}');
      return;
    }
    const url = new URL(request.url, "http://127.0.0.1");
    response.writeHead(url.searchParams.get("token") === token ? 404 : 401);
    response.end();
  });
  await new Promise((resolvePromise) => server.listen(0, "127.0.0.1", resolvePromise));
  t.after(() => server.close());
  const address = server.address();

  assert.deepEqual(
    await probeAuthenticatedRelay({ token, port: address.port }),
    { reachable: true, ready: true },
  );
  assert.deepEqual(
    await probeAuthenticatedRelay({ token: "b".repeat(32), port: address.port }),
    { reachable: true, ready: false },
  );
});

test("removes only runtime directories with matching ownership evidence", (t) => {
  const tempRoot = mkdtempSync(join(tmpdir(), "aidevops-playwriter-relay-"));
  const runtime = createPrivateRuntime(tempRoot, "owned-token");
  t.after(() => {
    try { cleanupPrivateRuntime(runtime); } catch {}
  });
  assert.equal(readFileSync(runtime.markerPath, "utf8"), "owned-token");
  writeFileSync(runtime.markerPath, "foreign-token");
  assert.throws(() => cleanupPrivateRuntime(runtime), /matching ownership evidence/);
  writeFileSync(runtime.markerPath, "owned-token");
  cleanupPrivateRuntime(runtime);
});
