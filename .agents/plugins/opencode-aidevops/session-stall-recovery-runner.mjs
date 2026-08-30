// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { recoveryFingerprint } from "./session-stall-recovery-ledger.mjs";

const ACTIVE_SESSION_STATES = new Set(["busy", "retry"]);

function unwrap(response) {
  return response?.data ?? response;
}

function responseError(response) {
  return response?.error || response?.data?.error || null;
}

class SessionRecoveryRunner {
  constructor({
    client,
    directory,
    store,
    ledger,
    clock,
    staleMs,
    cooldownMs,
    idleWaitMs,
    sleep,
    isEnabled,
    log,
  }) {
    this.client = client;
    this.directory = directory;
    this.store = store;
    this.ledger = ledger;
    this.clock = clock;
    this.staleMs = staleMs;
    this.cooldownMs = cooldownMs;
    this.idleWaitMs = idleWaitMs;
    this.sleep = sleep;
    this.isEnabled = isEnabled;
    this.log = log;
    this.checks = new Set();
  }

  async liveStatus(sessionID) {
    if (typeof this.client?.session?.status !== "function") return "";
    for (const args of [{ query: { directory: this.directory } }, {}]) {
      try {
        const response = await this.client.session.status(args);
        const statuses = unwrap(response);
        const status = statuses?.[sessionID];
        if (typeof status?.type === "string") return status.type.toLowerCase();
      } catch {
        // Try the next SDK argument shape.
      }
    }
    return "";
  }

  recoveryAllowed(sessionID, state) {
    if (!state.parentKnown || state.parentID) return false;
    if (!ACTIVE_SESSION_STATES.has(state.status)) return false;
    if (state.pendingPermissionIDs.size > 0) return false;
    if (state.turnUnsafe || state.activeTool?.safe === false) return false;
    return this.clock() - state.lastActivityAt >= this.staleMs && !this.checks.has(sessionID);
  }

  stateStillSafe(state, checkActiveTool = true) {
    if (state.recoveryIntervened || state.pendingPermissionIDs.size > 0) return false;
    if (state.turnUnsafe) return false;
    if (checkActiveTool && state.activeTool?.safe === false) return false;
    return true;
  }

  async waitForIdle(sessionID) {
    const deadline = this.clock() + this.idleWaitMs;
    while (this.clock() < deadline) {
      const status = await this.liveStatus(sessionID);
      if (status === "idle") return true;
      await this.sleep(Math.min(250, Math.max(1, deadline - this.clock())));
    }
    return false;
  }

  async abortAndWait(sessionID) {
    if (typeof this.client?.session?.abort !== "function") return false;
    const aborted = await this.client.session.abort({ path: { id: sessionID }, body: {} });
    if (responseError(aborted) || unwrap(aborted) !== true) return false;
    return this.waitForIdle(sessionID);
  }

  async promptResume(sessionID, state, fingerprint) {
    if (!this.stateStillSafe(state, false)) return false;
    if (typeof this.client?.session?.prompt !== "function") return false;
    const text = [
      "AIDEVOPS SAFE STALL RECOVERY.",
      "The previous assistant turn stopped producing activity and was aborted.",
      "Re-read the recent conversation and inspect current state before continuing the unfinished safe step.",
      "Do not repeat any write, deployment, external request, or other side effect. If safe continuation is uncertain, stop and ask the user.",
      `Recovery marker: ${fingerprint}`,
    ].join("\n");
    const prompted = await this.client.session.prompt({
      path: { id: sessionID },
      body: { parts: [{ type: "text", text, synthetic: true }] },
    });
    if (responseError(prompted)) return false;
    this.log("INFO", `[session-stall-recovery] resumed session marker=${fingerprint}`);
    return true;
  }

  async claimRecovery(sessionID, state) {
    const status = await this.liveStatus(sessionID);
    if (!ACTIVE_SESSION_STATES.has(status)) return "";
    if (!this.stateStillSafe(state)) return "";
    const fingerprint = recoveryFingerprint(sessionID, state);
    if (!await this.ledger.claim(sessionID, fingerprint, this.cooldownMs)) return "";
    if (!this.stateStillSafe(state)) return "";
    return fingerprint;
  }

  async performRecovery(sessionID, state) {
    const fingerprint = await this.claimRecovery(sessionID, state);
    if (!fingerprint) return false;
    if (!await this.abortAndWait(sessionID)) return false;
    return this.promptResume(sessionID, state, fingerprint);
  }

  async recover(sessionID, state) {
    if (!this.recoveryAllowed(sessionID, state)) return false;
    this.checks.add(sessionID);
    state.recoveryIntervened = false;
    state.recoveryPending = true;
    let recovered = false;
    try {
      recovered = await this.performRecovery(sessionID, state);
    } catch (error) {
      this.log("WARN", `[session-stall-recovery] recovery failed: ${error?.name || "Error"}`);
    } finally {
      state.recoveryPending = false;
      this.checks.delete(sessionID);
    }
    return recovered;
  }

  async checkNow() {
    if (!this.isEnabled()) return [];
    const recovered = [];
    for (const [sessionID, state] of this.store.sessions) {
      if (await this.recover(sessionID, state)) recovered.push(sessionID);
    }
    return recovered;
  }
}

export { SessionRecoveryRunner };
