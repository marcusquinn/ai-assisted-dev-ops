// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Opt-in OpenCode plugin for isolated benchmark contestants, never global config.
// Load this INSTEAD of the aidevops plugin; it composes that plugin when requested.
import { createHash } from "node:crypto";
import { closeSync, openSync, writeSync } from "node:fs";
import { isAbsolute } from "node:path";

async function FrontierObserver(input, options = {}) {
  const profile = options.profile;
  if (!["stock", "aidevops", "aidevops-native-compaction"].includes(profile)) {
    throw new Error("An explicit benchmark profile is required");
  }
  if (!isAbsolute(options.events || "")) {
    throw new Error("An absolute, fresh benchmark events path is required");
  }
  // Exclusive creation refuses existing files/symlinks and prevents accidental
  // reuse of a prior trial. Only numeric measurements and opaque IDs are logged.
  const fd = openSync(options.events, "wx", 0o600);
  let closed = false;
  let sequence = 0;
  const emit = (data) => {
    if (closed) return;
    if (++sequence > 100000) throw new Error("Benchmark telemetry limit reached");
    writeSync(fd, `${JSON.stringify({ schema: 1, sequence, time_ms: Date.now(), profile, ...data })}\n`);
  };
  const opaque = (value) => createHash("sha256").update(String(value)).digest("hex").slice(0, 24);
  const number = (value) => Number.isFinite(value) && value >= 0 ? value : null;
  let hooks = {};
  if (profile !== "stock") {
    const { AidevopsPlugin } = await import("../opencode-aidevops/index.mjs");
    hooks = await AidevopsPlugin(input);
  }
  emit({ type: "observer.started", framework_loaded: profile !== "stock",
    framework_tool_count: Object.keys(hooks.tool || {}).length });
  const seen = new Set();
  return {
    ...hooks,
    config: async (config) => {
      await hooks.config?.(config);
      emit({ type: "config.applied" });
    },
    dispose: async () => {
      await hooks.dispose?.();
      if (!closed) { closed = true; closeSync(fd); }
    },
    "chat.params": async (event, output) => {
      await hooks["chat.params"]?.(event, output);
      emit({
        type: "request", session: opaque(event.sessionID),
        context_limit: number(event.model?.limit?.context),
        input_limit: number(event.model?.limit?.input),
        output_limit: number(event.model?.limit?.output),
      });
    },
    "experimental.session.compacting": async (event, output) => {
      emit({ type: "compaction.requested", session: opaque(event.sessionID) });
      // This ablates the entire custom context injection, including restored
      // operational state, NOT native compaction or the autocontinue hook.
      if (profile !== "aidevops-native-compaction") {
        await hooks["experimental.session.compacting"]?.(event, output);
      }
    },
    event: async (eventInput) => {
      await hooks.event?.(eventInput);
      const event = eventInput.event;
      const message = event?.properties?.info;
      if (event?.type === "session.compacted") {
        emit({ type: "compaction.completed", session: opaque(event.properties.sessionID) });
      }
      if (event?.type !== "message.updated" || message?.role !== "assistant"
        || !message.time?.completed || !message.id || seen.has(message.id)) return;
      seen.add(message.id);
      emit({
        type: "completion", session: opaque(message.sessionID), message: opaque(message.id),
        summary: message.summary === true, error: Boolean(message.error),
        duration_ms: number(message.time.completed - message.time.created),
        input_tokens: number(message.tokens?.input),
        output_tokens: number(message.tokens?.output),
        reasoning_tokens: number(message.tokens?.reasoning),
        cache_read_tokens: number(message.tokens?.cache?.read),
        cache_write_tokens: number(message.tokens?.cache?.write),
      });
    },
  };
}

export default { id: "aidevops-frontier-eval", server: FrontierObserver };
