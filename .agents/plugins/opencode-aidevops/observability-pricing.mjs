// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Pricing lookup and cost calculation for the OpenCode observability plugin.
 *
 * The shared JSON remains the source of truth. Hardcoded values preserve
 * observability when that configuration is unavailable.
 *
 * @module observability-pricing
 */

import { readFileSync } from "fs";
import { homedir } from "os";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const HOME = homedir();
const FALLBACK_PRICING_VERSION = "2026-08-21.1";

/** Hardcoded fallback — used only when model-pricing.json is unreadable */
const FALLBACK_PRICING = {
  "opus-4":    { input: 15.0,  output: 75.0,  cacheRead: 1.50,   cacheWrite: 18.75 },
  "sonnet-4":  { input: 3.0,   output: 15.0,  cacheRead: 0.30,   cacheWrite: 3.75  },
  "haiku-4":   { input: 0.80,  output: 4.0,   cacheRead: 0.08,   cacheWrite: 1.0   },
  "haiku-3":   { input: 0.80,  output: 4.0,   cacheRead: 0.08,   cacheWrite: 1.0   },
  "gpt-5.6-sol":   { input: 5.0,  output: 30.0, cacheRead: 0.50, cacheWrite: 6.25  },
  "gpt-5.6-terra": { input: 2.0,  output: 12.0, cacheRead: 0.20, cacheWrite: 2.50  },
  "gpt-5.6-luna":  { input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25  },
};
const FALLBACK_DEFAULT = { input: 3.0, output: 15.0, cacheRead: 0.30, cacheWrite: 3.75 };
export const UNKNOWN_PRICING_MODELS = ["gpt-5.6-sol-pro"];

/**
 * Load pricing from the shared JSON file.
 * The JSON uses snake_case keys (cache_read, cache_write) for cross-language
 * compatibility; we convert to camelCase for JS consumption.
 * @returns {{ models: Record<string, {input,output,cacheRead,cacheWrite}>, default: {input,output,cacheRead,cacheWrite} }}
 */
function loadPricingFromJSON() {
  // Resolve relative to this file's location (works in both dev repo and deployed ~/.aidevops/)
  const thisDir = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    join(thisDir, "..", "..", "configs", "model-pricing.json"),          // repo: .agents/plugins/../../configs/
    join(HOME, ".aidevops", "agents", "configs", "model-pricing.json"), // deployed
  ];

  for (const candidate of candidates) {
    try {
      const raw = JSON.parse(readFileSync(candidate, "utf-8"));
      const models = {};
      for (const [key, p] of Object.entries(raw.models || {})) {
        models[key] = {
          input: p.input,
          output: p.output,
          cacheRead: p.cache_read,
          cacheWrite: p.cache_write,
        };
      }
      const def = raw.default || {};
      const defaultPricing = {
        input: def.input ?? 3.0,
        output: def.output ?? 15.0,
        cacheRead: def.cache_read ?? 0.30,
        cacheWrite: def.cache_write ?? 3.75,
      };
      return {
        models,
        default: defaultPricing,
        version: String(raw.version || FALLBACK_PRICING_VERSION),
      };
    } catch {
      // Try next candidate
    }
  }

  // All candidates failed — use hardcoded fallback
  console.error("[aidevops] Observability: model-pricing.json not found, using hardcoded fallback");
  return {
    models: FALLBACK_PRICING,
    default: FALLBACK_DEFAULT,
    version: FALLBACK_PRICING_VERSION,
  };
}

const pricing = loadPricingFromJSON();
export const MODEL_PRICING = pricing.models;
export const DEFAULT_PRICING = pricing.default;
export const PRICING_VERSION = pricing.version;

/**
 * Look up pricing for a model ID. Matches against the pricing table keys
 * as substrings of the model ID (e.g., "claude-sonnet-4-20250514" matches "sonnet-4").
 * @param {string} modelID
 * @returns {{ input: number, output: number, cacheRead: number, cacheWrite: number }}
 */
export function getPricing(modelID) {
  if (!modelID) return DEFAULT_PRICING;
  const lower = modelID.toLowerCase();
  if (UNKNOWN_PRICING_MODELS.some((model) => lower.includes(model))) return DEFAULT_PRICING;
  for (const [key, modelPricing] of Object.entries(MODEL_PRICING)) {
    if (lower.includes(key)) return modelPricing;
  }
  return DEFAULT_PRICING;
}

/**
 * Calculate cost from token counts and model pricing.
 * OpenCode does not provide cost in message events — we must compute it.
 * @param {object} tokens - { input, output, reasoning, cache: { read, write } }
 * @param {string} modelID
 * @returns {number} Total cost in USD
 */
export function calculateCost(tokens, modelID) {
  if (!tokens) return 0.0;
  const modelPricing = getPricing(modelID);
  const inputTokens = tokens.input || 0;
  const outputTokens = tokens.output || 0;
  const reasoningTokens = tokens.reasoning || 0;
  const cacheRead = tokens.cache?.read || 0;
  const cacheWrite = tokens.cache?.write || 0;

  // Reasoning tokens are billed at output rate
  const cost =
    (inputTokens / 1e6) * modelPricing.input +
    ((outputTokens + reasoningTokens) / 1e6) * modelPricing.output +
    (cacheRead / 1e6) * modelPricing.cacheRead +
    (cacheWrite / 1e6) * modelPricing.cacheWrite;

  return Math.round(cost * 1e8) / 1e8; // 8 decimal places
}
