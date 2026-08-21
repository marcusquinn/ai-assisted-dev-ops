// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { test } from "node:test";

import { getPricing } from "../observability.mjs";
import { PRICING_VERSION } from "../observability-pricing.mjs";

test("GPT-5.6 pricing uses published API rates", () => {
  assert.deepEqual(getPricing("gpt-5.6-sol"), {
    input: 5.0, output: 30.0, cacheRead: 0.50, cacheWrite: 6.25,
  });
  assert.deepEqual(getPricing("gpt-5.6-terra"), {
    input: 2.0, output: 12.0, cacheRead: 0.20, cacheWrite: 2.50,
  });
  assert.deepEqual(getPricing("gpt-5.6-luna"), {
    input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25,
  });
  assert.equal(PRICING_VERSION, "2026-08-21.1");
});

test("Sol Pro does not inherit unpublished standard Sol pricing", () => {
  assert.deepEqual(getPricing("gpt-5.6-sol-pro"), {
    input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75,
  });
});
