// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const WARNING_LINE_PREFIXES = ["Pulse stalled", "[OPENCODE MAINTENANCE]", "[WARNING]", "[WARN]"];

/**
 * Classify each line of update-check output into toast variants.
 *
 * @param {string} output
 * @returns {{ info: string[], success: string[], warning: string[], error: string[] }}
 */
export function classifyLines(output) {
  const info = [];
  const success = [];
  const warning = [];
  const error = [];

  for (const rawLine of output.split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;

    // Skip UPDATE_AVAILABLE| sentinel lines — those are machine-readable
    // markers consumed by the model greeting, not human banner text.
    if (line.startsWith("UPDATE_AVAILABLE|") || line === "AUTO_UPDATE_ENABLED") {
      continue;
    }

    // Order matters: errors first (most specific), then warnings, then
    // success, then info (catch-all for version/env lines).
    if (line.startsWith("[SECURITY ADVISORY]") || line.startsWith("[ERROR]")) {
      error.push(line);
    } else if (isWarningLine(line)) {
      warning.push(line);
    } else if (line.startsWith("Security: all protections active")) {
      success.push(line);
    } else {
      info.push(line);
    }
  }

  return { info, success, warning, error };
}

function isWarningLine(line) {
  return WARNING_LINE_PREFIXES.some((prefix) => line.startsWith(prefix)) || /contribution\(s\) need/i.test(line);
}

/**
 * Consolidate classified lines into a single toast body.
 *
 * OpenCode's TUI renders one toast at a time — each new client.tui.showToast()
 * call replaces the previous one before the user can read it (t2727, observed
 * after PR #20424 deployed: end user saw only the final "success" toast of the
 * original four-emit sequence). So we collapse the four-category Phase 1
 * design into a single emit that preserves severity ordering in the message
 * body.
 *
 * Variant follows the highest severity present (error > warning > info >
 * success); duration follows the variant's existing mapping (30s/15s/8s/5s).
 * Returns null when all buckets are empty so the caller can skip the emit.
 *
 * @param {{ info: string[], success: string[], warning: string[], error: string[] }} buckets
 * @returns {{ title: string, message: string, variant: "info"|"success"|"warning"|"error", duration: number } | null}
 */
export function buildToast(buckets) {
  const lines = [
    ...buckets.error,
    ...buckets.warning,
    ...buckets.info,
    ...buckets.success,
  ];

  if (lines.length === 0) return null;

  let variant, duration;
  if (buckets.error.length > 0) {
    variant = "error";
    duration = 30000;
  } else if (buckets.warning.length > 0) {
    variant = "warning";
    duration = 15000;
  } else if (buckets.info.length > 0) {
    variant = "info";
    duration = 8000;
  } else {
    variant = "success";
    duration = 5000;
  }

  return {
    title: "aidevops",
    message: lines.join("\n"),
    variant,
    duration,
  };
}

function greetingToast(output) {
  return buildToast(classifyLines(output));
}

export function emitCachedGreeting(client, cached) {
  if (!cached) return;
  const toast = greetingToast(cached.output);
  if (toast) emitToast(client, toast);
}

/**
 * Emit one toast via client.tui.showToast(). Logs failures when DEBUG is on.
 *
 * @param {any} client
 * @param {{ title: string, message: string, variant: string, duration: number }} body
 */
export async function emitToast(client, body) {
  try {
    await client.tui.showToast({ body });
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: toast emitted (variant=${body.variant}, ${body.message.length} chars)`);
    }
  } catch (err) {
    // Log on DEBUG; otherwise swallow (failures here are non-fatal —
    // the user still has the message-context greeting in Phase 1).
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] greeting: toast failed: ${err.message}`);
    }
  }
}
