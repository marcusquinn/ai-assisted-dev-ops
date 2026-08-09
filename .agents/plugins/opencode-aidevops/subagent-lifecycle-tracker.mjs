// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const MAX_SESSION_STATES = 64;
const TERMINAL_SESSION_STATES = new Set([
  "aborted", "cancelled", "canceled", "completed", "deleted", "end_turn", "error", "idle", "stop",
]);

/** Return a non-empty scalar session ID without coercing aggregate metadata. */
export function scalarSessionID(value) {
  return typeof value === "string" ? value.trim() : "";
}

function metadataChildSessionID(metadata) {
  const values = [metadata?.sessionId, metadata?.sessionID, metadata?.session_id]
    .filter((value) => value !== undefined && value !== null && value !== "");
  if (values.some((value) => typeof value !== "string")) return "";
  const ids = [...new Set(values.map(scalarSessionID).filter(Boolean))];
  return ids.length === 1 ? ids[0] : "";
}

function capMap(map, maximum = MAX_SESSION_STATES) {
  while (map.size > maximum) map.delete(map.keys().next().value);
}

export function eventSessionID(event) {
  const candidates = [
    event?.properties?.sessionID,
    event?.properties?.sessionId,
    event?.properties?.info?.id,
    event?.properties?.part?.sessionID,
  ];
  return candidates.map(scalarSessionID).find(Boolean) || "";
}

export class SubagentLifecycleTracker {
  constructor() {
    this.sessions = new Map();
    this.taskCalls = new Map();
    this.sequence = 0;
    this.trackingFailed = false;
  }

  beforeTask(callID, parentID) {
    this.taskCalls.set(callID, { parentID: scalarSessionID(parentID), startSequence: ++this.sequence });
    capMap(this.taskCalls, MAX_SESSION_STATES * 2);
  }

  rememberSession(info) {
    const sessionID = scalarSessionID(info?.id);
    if (!sessionID) return;
    const previous = this.sessions.get(sessionID) || {};
    this.sessions.set(sessionID, {
      ...previous,
      observed: true,
      parentID: scalarSessionID(info?.parentID) || previous.parentID || "",
      sequence: previous.sequence || ++this.sequence,
    });
    capMap(this.sessions);
  }

  rememberStatus(sessionID, status) {
    sessionID = scalarSessionID(sessionID);
    if (!sessionID) return;
    const previous = this.sessions.get(sessionID) || { observed: false, parentID: "", sequence: ++this.sequence };
    this.sessions.set(sessionID, { ...previous, status: String(status || "").toLowerCase() });
    capMap(this.sessions);
  }

  routeEvent(event) {
    const sessionID = eventSessionID(event);
    if (["session.created", "session.updated"].includes(event.type)) {
      this.rememberSession(event.properties?.info);
    } else if (event.type === "session.status") {
      this.rememberStatus(sessionID, event.properties?.status?.type);
    } else if (event.type === "session.idle") {
      this.rememberStatus(sessionID, "idle");
    } else if (event.type === "session.error") {
      this.rememberStatus(sessionID, "error");
    } else if (event.type === "session.deleted") {
      this.rememberStatus(sessionID, "deleted");
    } else if (event.type === "message.updated") {
      const message = event.properties?.info;
      if (message?.role === "assistant" && message?.finish) this.rememberStatus(message.sessionID, message.finish);
    }
  }

  handleEvent(event) {
    try {
      this.routeEvent(event);
    } catch {
      this.trackingFailed = true;
    }
  }

  takeChildIdentity(input, output) {
    const callID = String(input?.callID || "");
    const taskCall = this.taskCalls.get(callID);
    this.taskCalls.delete(callID);
    const metadata = output?.metadata || {};
    const explicit = metadataChildSessionID(metadata);
    const parentID = scalarSessionID(input?.sessionID) || taskCall?.parentID || "";
    let identity = { childID: "", reason: "child_identity_missing" };
    if (explicit) {
      const known = this.sessions.get(explicit);
      identity = known?.parentID && known.parentID !== parentID
        ? { childID: "", reason: "child_parent_mismatch" }
        : { childID: explicit, reason: "metadata" };
    } else {
      const candidates = [...this.sessions.entries()]
        .filter(([, state]) => state.parentID === parentID && state.sequence >= (taskCall?.startSequence || 0))
        .sort((left, right) => right[1].sequence - left[1].sequence);
      if (candidates.length > 0) identity = { childID: candidates[0][0], reason: "lifecycle" };
    }
    return { ...identity, callID };
  }

  terminalEvidence(childID) {
    const status = this.sessions.get(childID)?.status || "";
    return TERMINAL_SESSION_STATES.has(status) ? status : "";
  }

  observedSession(childID) {
    return Boolean(this.sessions.get(childID)?.observed);
  }
}
