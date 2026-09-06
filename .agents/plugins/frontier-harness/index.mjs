// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Opt-in OpenCode plugin for isolated benchmark contestants, never global config.
// Load this INSTEAD of the aidevops plugin; it composes that plugin when requested.
import { createHash } from "node:crypto";
import { closeSync, openSync, writeSync } from "node:fs";
import { isAbsolute } from "node:path";

const opaque = (value) => createHash("sha256").update(String(value)).digest("hex").slice(0, 24);
const number = (value) => Number.isFinite(value) && value >= 0 ? value : null;

// overflow.ts / provider/transform.ts at OpenCode v1.18.29 (16747470).
// Only the pinned adapter route is calibrated; other versions stay unknown.
function capacityFor(model, runtimeVersion, reserved) {
  const limit = model?.limit;
  if (runtimeVersion !== "1.18.29" || !limit?.context
    || !(limit?.input > 0) || !(limit?.output > 0)) return null;
  const reserve = reserved ?? Math.min(20000, limit.output, 32000);
  return { formula: "opencode-1.18.29-explicit-input-v1", reserve,
    reserve_source: reserved === undefined ? "runtime-default" : "compaction.reserved",
    usable_input: Math.max(0, limit.input - reserve) };
}

function recordInitialUsage(state, message, emit) {
  if (state.confirmed || message.summary) return;
  const earlier = state.initial && state.created <= message.time?.created;
  if (!message.time?.completed || earlier) return;
  state.created = message.time.created;
  const fields = [message.tokens?.input, message.tokens?.cache?.read, message.tokens?.cache?.write];
  const inputTokens = !message.error && fields.every((value) => number(value) !== null)
    ? fields.reduce((a, b) => a + b, 0) : null;
  state.initial = { input_tokens_including_cache: inputTokens };
  emit({ type: "calibration.initial", session: opaque(message.sessionID),
    ...state.initial, capacity: state.capacity ?? null,
    status: inputTokens === null || !state.capacity ? "unknown"
      : inputTokens >= state.capacity.usable_input ? "initial_input_exceeds_usable" : "initial_input_fits" });
}

async function checkInitialBudget(state, { client, sessionID, emit }) {
  // Bus delivery can lag the next turn. Read the completed first response
  // from this session only, never a global or previous-trial measurement.
  if (state.capacity && !state.confirmed && client?.session?.messages) {
    const result = await client.session.messages({ path: { id: sessionID } })
      .catch(() => ({ data: [] }));
    const first = result.data?.filter((row) => row.info?.role === "assistant"
      && row.info.sessionID === sessionID && !row.info.summary)
      .sort((a, b) => a.info.time.created - b.info.time.created)[0];
    if (first?.info.time?.completed) {
      state.initial = null;
      recordInitialUsage(state, first.info, emit);
      state.confirmed = true;
    }
  }
  const inputTokens = state.initial?.input_tokens_including_cache;
  const exceedsCapacity = state.capacity && inputTokens != null && inputTokens >= state.capacity.usable_input;
  if (state.confirmed && exceedsCapacity) {
    emit({ type: "calibration.stopped", session: opaque(sessionID),
      reason: "initial_input_exceeds_usable", capacity: state.capacity, ...state.initial });
    throw new Error("FrontierCalibrationInfeasible: initial input exceeds usable capacity; preserve this attempt");
  }
}

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
  const sessions = new Map();
  let reserved;
  const stateFor = (id) => {
    if (!sessions.has(id)) sessions.set(id, {});
    return sessions.get(id);
  };
  const capacity = (model) => capacityFor(model, options.runtimeVersion, reserved);
  const initialUsage = (message) => recordInitialUsage(stateFor(message.sessionID), message, emit);
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
      reserved = number(config.compaction?.reserved) ?? undefined;
      emit({ type: "config.applied" });
    },
    dispose: async () => {
      await hooks.dispose?.();
      if (!closed) { closed = true; closeSync(fd); }
    },
    "chat.params": async (event, output) => {
      await hooks["chat.params"]?.(event, output);
      const state = stateFor(event.sessionID);
      if (!("capacity" in state)) state.capacity = capacity(event.model);
      emit({
        type: "request", session: opaque(event.sessionID),
        context_limit: number(event.model?.limit?.context),
        input_limit: number(event.model?.limit?.input),
        output_limit: number(event.model?.limit?.output),
        capacity: capacity(event.model),
      });
    },
    "experimental.chat.system.transform": async (event, output) => {
      await hooks["experimental.chat.system.transform"]?.(event, output);
      emit({ type: "request.footprint", session: opaque(event.sessionID),
        system_bytes: output.system.reduce((sum, text) => sum + Buffer.byteLength(text), 0),
        system_entries: output.system.length });
    },
    "experimental.session.compacting": async (event, output) => {
      emit({ type: "compaction.requested", session: opaque(event.sessionID) });
      if (options.experimental) {
        await checkInitialBudget(stateFor(event.sessionID), { client: input.client, sessionID: event.sessionID, emit });
      }
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
      if (event?.type !== "message.updated" || message?.role !== "assistant") return;
      if (!message.time?.completed || !message.id || seen.has(message.id)) return;
      seen.add(message.id);
      initialUsage(message);
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
