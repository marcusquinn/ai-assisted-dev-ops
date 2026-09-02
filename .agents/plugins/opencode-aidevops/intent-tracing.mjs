// ---------------------------------------------------------------------------
// Phase 4.5: Intent Tracing (t1309)
// Extracted from index.mjs (t1914) — intent extraction and storage.
// ---------------------------------------------------------------------------
// Inspired by oh-my-pi's agent__intent pattern. The LLM is instructed via
// system prompt to include an `agent__intent` field in every tool call,
// describing its intent in present participle form. The field is extracted
// from tool args in the `tool.execute.before` hook and stored in the
// observability DB alongside the tool call record.

/**
 * Field name for intent tracing — matches oh-my-pi convention.
 * @type {string}
 */
export const INTENT_FIELD = "agent__intent";

/**
 * Per-callID intent store. Bridges tool.execute.before → tool.execute.after.
 * Maps callID → bounded intent record.
 * @type {Map<string, {intent: string, source: "explicit" | "fallback"}>}
 */
const intentByCallId = new Map();

const FALLBACK_INTENT_BY_OPERATION = new Map([
  ["read", "Reading requested context"],
  ["search", "Searching requested context"],
  ["execute", "Running the requested operation"],
  ["write", "Updating requested files"],
  ["research", "Researching requested context"],
  ["fetch", "Fetching the requested reference"],
  ["track", "Tracking requested work"],
  ["load", "Loading requested guidance"],
  ["use", "Using the requested tool"],
]);

const TOOL_OPERATION_BY_NAME = new Map([
  ["read", "read"],
  ["grep", "search"],
  ["glob", "search"],
  ["osgrep", "search"],
  ["bash", "execute"],
  ["apply_patch", "write"],
  ["edit", "write"],
  ["write", "write"],
  ["task", "research"],
  ["ai_research", "research"],
  ["webfetch", "fetch"],
  ["todowrite", "track"],
  ["skill", "load"],
]);

function operationClass(toolName) {
  const normalized = typeof toolName === "string"
    ? toolName.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").slice(0, 64)
    : "";
  return normalized ? (TOOL_OPERATION_BY_NAME.get(normalized) || "use") : "";
}

/** Derive a privacy-safe fallback from tool identity alone. */
export function deriveFallbackIntent(toolName) {
  const operation = operationClass(toolName);
  return operation ? FALLBACK_INTENT_BY_OPERATION.get(operation) : undefined;
}

function storeIntentRecord(callID, record) {
  if (!callID || !record) return;
  intentByCallId.set(callID, record);

  // Prune old entries to prevent unbounded memory growth.
  if (intentByCallId.size > 5000) {
    const keys = Array.from(intentByCallId.keys());
    for (const k of keys.slice(0, 2500)) {
      intentByCallId.delete(k);
    }
  }
}

function cloneArgsWithoutIntent(args) {
  const clone = {};
  const descriptors = Object.getOwnPropertyDescriptors(args);
  for (const key of Reflect.ownKeys(descriptors)) {
    const descriptor = descriptors[key];
    if (key === INTENT_FIELD || !descriptor.enumerable) continue;
    Object.defineProperty(clone, key, descriptor);
  }
  return clone;
}

function ownIntentDescriptor(args) {
  let descriptor;
  if (args && typeof args === "object") {
    try {
      descriptor = Object.getOwnPropertyDescriptor(args, INTENT_FIELD);
    } catch {
      descriptor = undefined;
    }
  }
  return descriptor;
}

function stripOwnIntent(args, descriptor) {
  let sanitizedArgs = args;
  if (descriptor) {
    try {
      delete args[INTENT_FIELD];
    } catch {
      // Fall through to a replacement object below.
    }
    if (Object.prototype.hasOwnProperty.call(args, INTENT_FIELD)) {
      sanitizedArgs = cloneArgsWithoutIntent(args);
    }
  }
  return sanitizedArgs;
}

/**
 * Prepare tool args and intent metadata as one fail-closed boundary operation.
 * A non-configurable intent field is removed through a replacement plain object.
 */
export function prepareIntent(callID, args, toolName = "") {
  const descriptor = ownIntentDescriptor(args);
  const raw = descriptor && "value" in descriptor ? descriptor.value : undefined;
  const sanitizedArgs = stripOwnIntent(args, descriptor);
  const explicitIntent = typeof raw === "string" ? raw.trim() : "";
  const intent = explicitIntent || deriveFallbackIntent(toolName);
  const source = intent ? (explicitIntent ? "explicit" : "fallback") : undefined;
  if (intent) storeIntentRecord(callID, { intent, source });
  return { args: sanitizedArgs, intent, source };
}

/**
 * Extract, store, and strip the intent field from tool call args.
 * Called from toolExecuteBefore — stores intent keyed by callID for
 * retrieval in toolExecuteAfter when the tool call is recorded to the DB.
 * The metadata is consumed by aidevops observability and must not remain in
 * executable tool arguments passed onward to OpenCode or host tools.
 *
 * @param {string} callID - Unique tool call identifier
 * @param {object} args - Tool call arguments (may contain agent__intent)
 * @param {string} [toolName] - Host tool identity; never tool arguments
 * @returns {string | undefined} Explicit or fallback intent string
 */
export function extractAndStoreIntent(callID, args, toolName = "") {
  return prepareIntent(callID, args, toolName).intent;
}

/** Return intent provenance without consuming the current call record. */
export function peekIntentSource(callID) {
  return intentByCallId.get(callID)?.source;
}

/** Retrieve and remove the complete intent record for one call. */
export function consumeIntentRecord(callID) {
  const record = intentByCallId.get(callID);
  if (record !== undefined) intentByCallId.delete(callID);
  return record;
}

/**
 * Retrieve and remove the stored intent for a callID.
 * Called from toolExecuteAfter — consumes the intent stored by extractAndStoreIntent.
 *
 * @param {string} callID
 * @returns {string | undefined}
 */
export function consumeIntent(callID) {
  return consumeIntentRecord(callID)?.intent;
}
