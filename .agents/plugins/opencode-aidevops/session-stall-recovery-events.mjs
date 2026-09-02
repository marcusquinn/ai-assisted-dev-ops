// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const ACTIVE_TOOL_STATES = new Set(["pending", "running"]);
const FINISHED_TOOL_STATES = new Set([
  "completed",
  "error",
  "failed",
  "aborted",
  "cancelled",
  "canceled",
]);

function sessionIDFromEvent(event) {
  const candidates = [
    event?.properties?.sessionID,
    event?.properties?.info?.sessionID,
    event?.properties?.info?.id,
    event?.properties?.part?.sessionID,
  ];
  return String(candidates.find(Boolean) || "");
}

function markIntervention(state) {
  if (state.recoveryPending) state.recoveryIntervened = true;
}

class SessionStallEventHandler {
  constructor(store, clock) {
    this.store = store;
    this.clock = clock;
    this.handlers = new Map([
      ["session.created", this.updateSession.bind(this)],
      ["session.updated", this.updateSession.bind(this)],
      ["session.deleted", this.deleteSession.bind(this)],
      ["permission.asked", this.askPermission.bind(this)],
      ["permission.updated", this.askPermission.bind(this)],
      ["permission.replied", this.replyPermission.bind(this)],
      ["session.status", this.updateStatus.bind(this)],
      ["session.idle", this.markIdle.bind(this)],
      ["message.part.updated", this.updatePart.bind(this)],
      ["message.part.delta", this.updatePart.bind(this)],
      ["message.updated", this.updateMessage.bind(this)],
      ["session.error", this.recordError.bind(this)],
    ]);
  }

  handle({ event } = {}) {
    const sessionID = sessionIDFromEvent(event);
    const handler = this.handlers.get(event?.type);
    if (sessionID && handler) {
      handler(event, this.store.stateFor(sessionID), sessionID);
    }
  }

  updateSession(event, state) {
    const info = event.properties?.info || {};
    if (!state.parentKnown || Object.hasOwn(info, "parentID")) {
      state.parentKnown = true;
      state.parentID = String(info.parentID || "");
    }
    state.lastActivityAt = this.clock();
  }

  deleteSession(_event, _state, sessionID) {
    this.store.sessions.delete(sessionID);
  }

  askPermission(event, state) {
    const requestID = String(event.properties?.id || "");
    if (requestID) state.pendingPermissionIDs.add(requestID);
    markIntervention(state);
    state.lastActivityAt = this.clock();
  }

  replyPermission(event, state) {
    const requestID = String(event.properties?.requestID || event.properties?.permissionID || "");
    if (requestID) state.pendingPermissionIDs.delete(requestID);
    state.lastActivityAt = this.clock();
  }

  updateStatus(event, state) {
    const status = String(event.properties?.status?.type || "").toLowerCase();
    if (status) {
      const startingTurn = ["busy", "retry"].includes(status)
        && !["busy", "retry"].includes(state.status);
      if (startingTurn) {
        markIntervention(state);
        state.busySince = this.clock();
        state.lastActivityAt = this.clock();
        state.turnUnsafe = false;
      }
      state.status = status;
      if (status === "idle") state.activeTool = null;
    }
  }

  markIdle(_event, state) {
    state.status = "idle";
    state.activeTool = null;
  }

  updatePart(event, state, sessionID) {
    const part = event.properties?.part;
    state.lastActivityAt = this.clock();
    if (part?.type !== "tool") {
      markIntervention(state);
    } else {
      this.updateToolPart(part, state, sessionID);
    }
  }

  updateToolPart(part, state, sessionID) {
    const status = String(part?.state?.status || "").toLowerCase();
    if (ACTIVE_TOOL_STATES.has(status)) {
      markIntervention(state);
      this.store.recordTool({ sessionID, callID: part.callID, tool: part.tool }, part.state?.input || {});
    } else if (FINISHED_TOOL_STATES.has(status)) {
      const callID = String(part.callID || "");
      if (!state.activeTool?.callID || state.activeTool.callID === callID) {
        state.activeTool = null;
      }
    }
  }

  updateMessage(event, state) {
    state.lastActivityAt = this.clock();
    if (event.properties?.info?.role === "user") markIntervention(state);
  }

  recordError(_event, state) {
    state.lastActivityAt = this.clock();
  }
}

export { SessionStallEventHandler };
