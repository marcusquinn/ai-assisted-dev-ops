// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("completed child responses join queued routing decisions to parent feedback", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-routing-join-"));
  process.env.AIDEVOPS_OBS_DB_OVERRIDE = join(root, "llm-requests.db");
  const observability = await import(`../observability.mjs?routing-join=${Date.now()}`);
  const sqlite = await import("../../../scripts/sqlite-process.mjs");

  try {
    assert.equal(observability.initObservability(), true);
    observability.recordRoutingDecision("child-session", {
      parentSessionID: "root-session",
      tier: "simple",
      model: "openai/gpt-5.6-luna",
      variant: "max",
      candidateIndex: 0,
      attempt: 1,
      reason: "subagent_profile",
      escalated: false,
    });
    observability.handleEvent({
      event: {
        type: "message.updated",
        properties: {
          info: {
            id: "message-1",
            sessionID: "child-session",
            role: "assistant",
            providerID: "openai",
            modelID: "gpt-5.6-luna",
            variant: "max",
            finish: "stop",
            time: { created: 1000, completed: 1100 },
            tokens: { input: 10, output: 5, reasoning: 2, total: 17, cache: { read: 0, write: 0 } },
          },
        },
      },
    });

    const summary = observability.getRoutingFeedback("root-session");
    assert.equal(summary.requestCount, 1);
    assert.deepEqual(summary.tierPath, ["simple"]);
    assert.equal(summary.tokensTotal, 17);
    assert.equal(summary.models[0], "openai/gpt-5.6-luna");
  } finally {
    sqlite.shutdownSqlite();
    delete process.env.AIDEVOPS_OBS_DB_OVERRIDE;
    rmSync(root, { recursive: true, force: true });
  }
});
