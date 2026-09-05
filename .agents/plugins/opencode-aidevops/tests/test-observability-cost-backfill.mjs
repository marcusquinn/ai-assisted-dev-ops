// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { backfillCosts } from "../observability-cost-backfill.mjs";
import { createSchema } from "../observability-init.mjs";
import {
  setDbPath, shutdownSqlite, sqliteExecSync,
} from "../observability-sqlite.mjs";

test("cost backfill rewrites exact stale GPT-5.6 estimates idempotently", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-cost-backfill-"));
  const dbPath = join(root, "llm-requests.db");
  const markerPath = join(root, "cost-backfill-v2.done");
  setDbPath(dbPath);

  try {
    assert.equal(createSchema(), true);
    sqliteExecSync(`
INSERT INTO llm_requests (
  session_id, provider_id, model_id, tokens_input, tokens_output,
  tokens_reasoning, tokens_cache_read, tokens_cache_write, tokens_total, cost
) VALUES
  ('luna-old', 'openai', 'gpt-5.6-luna', 1000000, 100000, 100000, 100000, 100000, 1300000, 2.335),
  ('terra-old', 'openai', 'gpt-5.6-terra', 1000000, 100000, 100000, 100000, 100000, 1300000, 5.8375),
  ('terra-unverified', 'openai', 'gpt-5.6-terra', 1000000, 0, 0, 0, 0, 1000000, 1.25),
  ('sol-zero', 'openai', 'gpt-5.6-sol', 1000000, 0, 0, 0, 0, 1000000, 0.0);
    `);

    backfillCosts(markerPath);
    const first = sqliteExecSync(`
SELECT session_id || '|' || printf('%.8f', cost) || '|' || COALESCE(pricing_version, '')
FROM llm_requests ORDER BY session_id;
    `);
    assert.equal(first, [
      "luna-old|0.46700000|2026-09-05.1",
      "sol-zero|4.00000000|2026-09-05.1",
      "terra-old|4.67000000|2026-09-05.1",
      "terra-unverified|1.25000000|legacy-unverified",
    ].join("\n"));
    assert.match(readFileSync(markerPath, "utf8"), /^\d{4}-\d{2}-\d{2}T/);

    backfillCosts(markerPath);
    const second = sqliteExecSync(`
SELECT session_id || '|' || printf('%.8f', cost) || '|' || COALESCE(pricing_version, '')
FROM llm_requests ORDER BY session_id;
    `);
    assert.equal(second, first);
  } finally {
    shutdownSqlite();
    rmSync(root, { recursive: true, force: true });
  }
});
