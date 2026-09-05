// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// model-limits.mjs — single source of truth for aidevops-managed model
// context/output limits, including the cost-aware GPT-5.6 context cap and the
// optional user override for the opus-4-7 context window.
//
// Why this module exists (t2435):
//   The opus-4-7 context window is intentionally capped at 250K (not the 1M
//   API ceiling) so OpenCode's 80% auto-compact threshold triggers right at
//   the 200K MRCR reliability boundary. That default protects most users
//   from coherence collapse past 200K. Some users want to opt into the full
//   1M window anyway — to experiment, or because their prompts don't hit
//   the cold-retrieval failure mode. The AIDEVOPS_OPUS_47_CONTEXT env var
//   is the opt-in.
//
//   Previously the limits table lived inline in config-hook.mjs and a
//   drift-prone copy lived in claude-proxy.mjs (`getClaudeProxyModels`).
//   Centralising here also fixes the drift surface flagged in t1960's PR.
// ---------------------------------------------------------------------------

/** Default opus-4-7 context window. See models-opus.md for the MRCR rationale. */
export const OPUS_47_CONTEXT_DEFAULT = 250000;

/** Hard upper bound — Anthropic's API ceiling for opus-4-7. */
export const OPUS_47_CONTEXT_MAX = 1000000;

/**
 * Advertised GPT-5.6 context used by OpenCode.
 */
export const GPT56_CONTEXT_DEFAULT = 300000;

/**
 * GPT-5.6 input budget used by OpenCode. OpenCode compacts at
 * `limit.input - compaction.reserved`; its default 20K reserve therefore
 * triggers compaction at 240K. Setting context alone does not control the
 * current compaction threshold when built-in metadata supplies input=380K.
 */
export const GPT56_INPUT_DEFAULT = 260000;

/** Maximum GPT-5.6 response size advertised by OpenCode's model registry. */
export const GPT56_OUTPUT_DEFAULT = 128000;

/** Managed Astra compaction target, not a claim about provider capacity. */
export const ASTRA_COMPACTION_TARGET = 400000;
export const ASTRA_OUTPUT_DEFAULT = 128000;

/** GPT-5.6 model IDs currently exposed by the OpenAI provider. */
export const GPT56_MODEL_IDS = [
  "gpt-5.6-sol",
  "gpt-5.6-sol-pro",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
];

/**
 * Resolve the opus-4-7 context window from env, falling back to the default.
 * Reads `process.env.AIDEVOPS_OPUS_47_CONTEXT` each call (so tests can mutate
 * env between invocations without re-importing the module).
 *
 * Validation:
 *   - Unset / empty → default (250000)
 *   - Non-numeric  → default (250000), warn at module-load time
 *   - <= 0         → default (250000), warn at module-load time
 *   - > MAX        → clamped to MAX (1000000), warn at module-load time
 *   - Otherwise    → the parsed integer
 *
 * @returns {number} resolved context window in tokens
 */
export function resolveOpus47Context() {
  const raw = process.env.AIDEVOPS_OPUS_47_CONTEXT;
  if (raw === undefined || raw === "") return OPUS_47_CONTEXT_DEFAULT;

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return OPUS_47_CONTEXT_DEFAULT;
  if (parsed > OPUS_47_CONTEXT_MAX) return OPUS_47_CONTEXT_MAX;
  return parsed;
}

/**
 * Describe what the env var did at module load — used for the one-shot warn.
 * Returns null when no override was attempted (silent default path).
 *
 * @returns {{kind: "applied"|"clamped"|"invalid", raw: string, resolved: number} | null}
 */
export function describeOpus47Override() {
  const raw = process.env.AIDEVOPS_OPUS_47_CONTEXT;
  if (raw === undefined || raw === "") return null;

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return { kind: "invalid", raw, resolved: OPUS_47_CONTEXT_DEFAULT };
  }
  if (parsed > OPUS_47_CONTEXT_MAX) {
    return { kind: "clamped", raw, resolved: OPUS_47_CONTEXT_MAX };
  }
  if (parsed === OPUS_47_CONTEXT_DEFAULT) {
    // Set explicitly to the default — treat as a no-op, no warn.
    return null;
  }
  return { kind: "applied", raw, resolved: parsed };
}

/**
 * Single source of truth for Claude model limits.
 * Both the anthropic provider models (config-hook.mjs) and the Claude CLI
 * proxy models (claude-proxy.mjs) derive their context/output values from
 * this table.
 */
export const CLAUDE_MODEL_LIMITS = {
  "claude-haiku-4-5":  { context: 1000000, output: 32000 },
  "claude-sonnet-4-5": { context:  200000, output: 64000 },
  "claude-sonnet-4-6": { context: 1000000, output: 64000 },
  "claude-opus-4-5":   { context:  200000, output: 64000 },
  "claude-opus-4-6":   { context: 1000000, output: 64000 },
  // Opus 4.7 context default 250K (not the 1M API ceiling). Anthropic's own
  // MRCR v2 8-needle data shows long-context retrieval collapse past 200K
  // (256K: 91.9% -> 59.2%, 1M: 78.3% -> 32.2%). Setting the limit to 250K lets
  // OpenCode's 80% auto-compact threshold trigger right at the 200K reliability
  // boundary -- users get the full functional window before compaction kicks in,
  // instead of compacting at 160K (80% of a 200K cap). Override via env var
  // AIDEVOPS_OPUS_47_CONTEXT=<integer> if you understand the MRCR tradeoff.
  // See tools/ai-assistants/models-opus.md for the full rationale.
  "claude-opus-4-7":   { context: resolveOpus47Context(), output: 64000 },
};

// One-shot warn at module load when the env override changed something.
// Module load runs once per process (Node caches), so this won't spam.
const _override = describeOpus47Override();
if (_override) {
  if (_override.kind === "applied") {
    // eslint-disable-next-line no-console
    console.warn(
      `[aidevops] AIDEVOPS_OPUS_47_CONTEXT=${_override.raw} — opus-4-7 context overridden to ${_override.resolved} ` +
      `(default ${OPUS_47_CONTEXT_DEFAULT}). Be aware: MRCR v2 8-needle retrieval drops ` +
      `from 91.9% at 256K to 59.2%, and to 32.2% at 1M. See models-opus.md.`
    );
  } else if (_override.kind === "clamped") {
    // eslint-disable-next-line no-console
    console.warn(
      `[aidevops] AIDEVOPS_OPUS_47_CONTEXT=${_override.raw} exceeds the 1M API ceiling. ` +
      `Clamped to ${OPUS_47_CONTEXT_MAX}.`
    );
  } else {
    // eslint-disable-next-line no-console
    console.warn(
      `[aidevops] AIDEVOPS_OPUS_47_CONTEXT=${_override.raw} is not a positive integer. ` +
      `Ignored — using default ${OPUS_47_CONTEXT_DEFAULT}.`
    );
  }
}
