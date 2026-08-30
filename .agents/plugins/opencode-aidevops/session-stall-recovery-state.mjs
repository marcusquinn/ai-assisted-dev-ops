// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const MAX_SESSION_STATES = 64;
const SAFE_TOOLS = new Set([
  "glob",
  "grep",
  "read",
  "skill",
  "todowrite",
  "webfetch",
  "functions.glob",
  "functions.grep",
  "functions.read",
  "functions.skill",
  "functions.todowrite",
  "functions.webfetch",
]);

function safeToolCall(tool, args = {}) {
  const name = String(tool || "").toLowerCase();
  if (SAFE_TOOLS.has(name)) return true;
  if (name === "aidevops_memory" || name === "functions.aidevops_memory") {
    return String(args?.action || "recall").toLowerCase() === "recall";
  }
  return false;
}

function initialState(clock) {
  return {
    activeTool: null,
    busySince: 0,
    lastActivityAt: clock(),
    parentKnown: false,
    parentID: "",
    pendingPermissionIDs: new Set(),
    recoveryIntervened: false,
    recoveryPending: false,
    status: "",
    turnUnsafe: false,
  };
}

class SessionStallStateStore {
  constructor(clock) {
    this.clock = clock;
    this.sessions = new Map();
  }

  stateFor(sessionID) {
    if (!this.sessions.has(sessionID)) {
      this.sessions.set(sessionID, initialState(this.clock));
      while (this.sessions.size > MAX_SESSION_STATES) {
        this.sessions.delete(this.sessions.keys().next().value);
      }
    }
    return this.sessions.get(sessionID);
  }

  recordTool(input, args) {
    const sessionID = String(input?.sessionID || "");
    if (sessionID) {
      const state = this.stateFor(sessionID);
      if (state.recoveryPending) state.recoveryIntervened = true;
      const safe = safeToolCall(input?.tool, args);
      state.activeTool = { callID: String(input?.callID || ""), safe };
      state.lastActivityAt = this.clock();
      if (!safe) state.turnUnsafe = true;
    }
  }

  beforeTool(input, output) {
    this.recordTool(input, output?.args || input?.args || {});
  }

  afterTool(input) {
    const sessionID = String(input?.sessionID || "");
    if (sessionID) {
      const state = this.stateFor(sessionID);
      const callID = String(input?.callID || "");
      if (!state.activeTool?.callID || state.activeTool.callID === callID) {
        state.activeTool = null;
      }
      state.lastActivityAt = this.clock();
    }
  }
}

export { safeToolCall, SessionStallStateStore };
