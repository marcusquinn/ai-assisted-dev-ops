// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  formatDuration, formatAgo, poolActionCheck,
  poolActionRemove, poolActionResetCooldowns,
  poolActionAssignPending, poolActionSetPriority,
} from "../oauth-pool-display.mjs";
import { poolActionCheck as healthCheckAction } from "../oauth-pool-health-check.mjs";
import {
  poolActionRemove as accountRemoveAction,
  poolActionResetCooldowns as accountResetCooldownsAction,
  poolActionAssignPending as accountAssignPendingAction,
  poolActionSetPriority as accountSetPriorityAction,
} from "../oauth-pool-account-actions.mjs";

test("display formatting keeps minute and hour output", () => {
  assert.equal(formatDuration(59_999), "0m");
  assert.equal(formatDuration(3_900_000), "1h 5m");
  assert.equal(formatAgo(3_900_000), "1h 5m ago");
});

test("display module preserves the health-check action export", () => {
  assert.equal(poolActionCheck, healthCheckAction);
});

test("display module preserves account action exports", () => {
  assert.equal(poolActionRemove, accountRemoveAction);
  assert.equal(poolActionResetCooldowns, accountResetCooldownsAction);
  assert.equal(poolActionAssignPending, accountAssignPendingAction);
  assert.equal(poolActionSetPriority, accountSetPriorityAction);
});
