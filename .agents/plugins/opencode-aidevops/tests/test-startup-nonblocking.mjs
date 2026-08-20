// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression coverage for GH#22157: optional proxy model discovery must not
// block OpenCode plugin startup. Cursor/Google OAuth refresh + upstream model
// listing can take seconds; the plugin entry point should schedule that work in
// the background and return hooks immediately.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const pluginDir = resolve(__dirname, "..");

test("index.mjs does not await optional proxy preparation during plugin startup", () => {
  const src = readFileSync(resolve(pluginDir, "index.mjs"), "utf8");

  assert.match(
    src,
    /const prepareOptionalProxy = \(label, prepare\) => \{\s*prepare\(\)\s*\.catch/,
    "AidevopsPlugin should use a fire-and-forget helper for optional proxy preparation.",
  );
  assert.match(
    src,
    /prepareOptionalProxy\("Cursor gRPC"[\s\S]+startCursorProxy\(client\)/,
    "Cursor proxy preparation should still be scheduled best-effort in the background.",
  );
  assert.match(
    src,
    /prepareOptionalProxy\("Google"[\s\S]+startGoogleProxy\(client\)/,
    "Google proxy preparation should still be scheduled best-effort in the background.",
  );
});

test("config-hook.mjs skips optional provider discovery until proxy ports are active", () => {
  const src = readFileSync(resolve(pluginDir, "config-hook.mjs"), "utf8");

  assert.match(
    src,
    /const cursorProxyPort = getCursorProxyPort\(\);\s*if \(cursorProxyPort\)/,
    "Cursor model discovery must be gated on an active proxy port.",
  );
  assert.match(
    src,
    /const googleProxyPort = getGoogleProxyPort\(\);\s*if \(googleProxyPort\)/,
    "Google model discovery must be gated on an active proxy port.",
  );
  assert.doesNotMatch(
    src,
    /const \{ getCursorModels \} = await import\("\.\/cursor\/models\.js"\);\s*const \{ discoverGoogleModels \} = await import\("\.\/google-proxy\.mjs"\);/,
    "Config hook must not unconditionally import both optional provider discovery modules.",
  );
});

test("config-hook.mjs does not run opencode --version synchronously during startup", () => {
  const src = readFileSync(resolve(pluginDir, "config-hook.mjs"), "utf8");

  assert.match(
    src,
    /checkOpenCodeVersionDriftAsync\(pluginDir/,
    "Version drift checks should be scheduled asynchronously.",
  );
  assert.doesNotMatch(
    src,
    /checkOpenCodeVersionDrift\(pluginDir\)/,
    "Config hook must not block startup on the opencode CLI version probe.",
  );
});

test("mcp-registry.mjs resolves binaries without spawning which", () => {
  const src = readFileSync(resolve(pluginDir, "mcp-registry.mjs"), "utf8");

  assert.match(
    src,
    /function findExecutable\(name\)/,
    "MCP registry should use an in-process PATH lookup.",
  );
  assert.doesNotMatch(
    src,
    /execSync|which /,
    "MCP registration must not spawn `which` during the config hook.",
  );
});

test("observability.mjs skips heavy cost backfill when no rows need migration", () => {
  const src = readFileSync(resolve(pluginDir, "observability.mjs"), "utf8");
  const backfillSrc = readFileSync(resolve(pluginDir, "observability-cost-backfill.mjs"), "utf8");

  assert.match(
    src,
    /scheduleCostBackfill\(COST_BACKFILL_MARKER\);/,
    "Historical cost backfills should be scheduled outside synchronous startup.",
  );
  assert.match(
    backfillSrc,
    /function hasCostBackfillCandidates\(markerPath\)/,
    "Observability should still probe before running the expensive backfill.",
  );
  assert.match(
    src,
    /COST_BACKFILL_MARKER/,
    "Completed one-time backfills should be memoized outside the hot startup path.",
  );
  assert.match(
    backfillSrc,
    /if \(!hasCostBackfillCandidates\(markerPath\)\) return;/,
    "The expensive cost UPDATE must be skipped once the backfill is complete.",
  );
  assert.match(
    src,
    /_runDataMigrations\(\{ toolCallColumnsReady: true, routingColumnsReady: true \}\)/,
    "Known-good schemas should skip redundant tool-call and routing-column migration probes.",
  );
});

test("initPoolAuth does not seed unsupported pending auth entries", async () => {
  const tempHome = mkdtempSync(resolve(tmpdir(), "aidevops-oauth-pool-"));
  const previousHome = process.env.HOME;
  const previousXdgDataHome = process.env.XDG_DATA_HOME;
  const previousUserProfile = process.env.USERPROFILE;
  process.env.HOME = tempHome;
  process.env.XDG_DATA_HOME = resolve(tempHome, ".local", "share");
  process.env.USERPROFILE = tempHome;

  const authWrites = [];
  const client = {
    auth: {
      async set(args) {
        authWrites.push(args);
      },
    },
  };

  try {
    const { initPoolAuth } = await import(`../oauth-pool.mjs?test=${Date.now()}`);
    await initPoolAuth(client);
  } finally {
    if (previousHome === undefined) delete process.env.HOME;
    else process.env.HOME = previousHome;
    if (previousXdgDataHome === undefined) delete process.env.XDG_DATA_HOME;
    else process.env.XDG_DATA_HOME = previousXdgDataHome;
    if (previousUserProfile === undefined) delete process.env.USERPROFILE;
    else process.env.USERPROFILE = previousUserProfile;
    rmSync(tempHome, { recursive: true, force: true });
  }

  assert.deepEqual(
    authWrites.filter((write) => write?.body?.type === "pending"),
    [],
    "Startup must not pass aidevops pending pool state to OpenCode auth.set().",
  );
  assert.deepEqual(
    authWrites.filter((write) => !["oauth", "api"].includes(write?.body?.type)),
    [],
    "Startup auth writes must use OpenCode-supported auth body types only.",
  );
});
