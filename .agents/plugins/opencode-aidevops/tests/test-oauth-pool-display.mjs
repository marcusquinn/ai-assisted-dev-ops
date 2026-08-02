// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  formatDuration, formatAgo, poolActionCheck,
} from "../oauth-pool-display.mjs";
import { poolActionCheck as healthCheckAction } from "../oauth-pool-health-check.mjs";

test("display formatting keeps minute and hour output", () => {
  assert.equal(formatDuration(59_999), "0m");
  assert.equal(formatDuration(3_900_000), "1h 5m");
  assert.equal(formatAgo(3_900_000), "1h 5m ago");
});

test("display module preserves the health-check action export", () => {
  assert.equal(poolActionCheck, healthCheckAction);
});
