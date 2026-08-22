// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  explicitChildSessionIdentity,
  scalarSessionID,
  uniqueScalarSessionID,
} from "./subagent-task-identity.mjs";

export { scalarSessionID } from "./subagent-task-identity.mjs";

const MAX_SESSION_STATES = 64;
const TERMINAL_SESSION_STATES = new Set([
  "aborted", "cancelled", "canceled", "completed", "deleted", "end_turn", "error", "idle", "stop",
]);

function capMap(map, maximum = MAX_SESSION_STATES) {
  while (map.size > maximum) map.delete(map.keys().next().value);
}

function rememberNativeTaskIdentity(taskCall, explicit) {
  if (explicit.reason === "child_identity_conflict") {
    taskCall.nativeChildID = "";
    taskCall.nativeIdentityConflict = true;
    return;
  }
  if (!explicit.childID || taskCall.nativeIdentityConflict) return;
  if (taskCall.nativeChildID && taskCall.nativeChildID !== explicit.childID) {
    taskCall.nativeChildID = "";
    taskCall.nativeIdentityConflict = true;
    return;
  }
  taskCall.nativeChildID = explicit.childID;
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
    this.taskCalls.set(callID, {
      nativeChildID: "",
      nativeIdentityConflict: false,
      parentID: scalarSessionID(parentID),
      startSequence: ++this.sequence,
    });
    capMap(this.taskCalls, MAX_SESSION_STATES * 2);
  }

  rememberTaskPart(part) {
    if (part?.type !== "tool" || !["task", "mcp_task"].includes(part?.tool)) return;
    const metadata = { ...part?.metadata, ...part?.state?.metadata };
    const explicit = explicitChildSessionIdentity({
      error: part?.state?.error,
      metadata,
      output: part?.state?.output,
    });
    const callIDs = [part?.id, part?.callID].map(scalarSessionID).filter(Boolean);
    for (const callID of callIDs) {
      const taskCall = this.taskCalls.get(callID);
      if (taskCall) rememberNativeTaskIdentity(taskCall, explicit);
    }
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
    if (event.type === "message.part.updated") {
      this.rememberTaskPart(event.properties?.part);
    } else if (["session.created", "session.updated"].includes(event.type)) {
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
    const explicit = explicitChildSessionIdentity(output);
    const nativeChildID = uniqueScalarSessionID([explicit.childID, taskCall?.nativeChildID]);
    const parentID = scalarSessionID(input?.sessionID) || taskCall?.parentID || "";
    let identity = { childID: "", reason: "child_identity_missing" };
    if (taskCall?.nativeIdentityConflict || explicit.reason === "child_identity_conflict") {
      identity = { childID: "", reason: "child_identity_conflict" };
    } else if (nativeChildID) {
      const known = this.sessions.get(nativeChildID);
      identity = known?.parentID && known.parentID !== parentID
        ? { childID: "", reason: "child_parent_mismatch" }
        : { childID: nativeChildID, reason: taskCall?.nativeChildID ? "native_task_id" : explicit.reason };
    } else if (explicit.childID || taskCall?.nativeChildID) {
      identity = { childID: "", reason: "child_identity_conflict" };
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
