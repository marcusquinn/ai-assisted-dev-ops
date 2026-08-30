// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, open, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

const DEFAULT_CHECK_MS = 60_000;
const DEFAULT_STALE_MS = 10 * 60_000;
const DEFAULT_COOLDOWN_MS = 30 * 60_000;
const DEFAULT_IDLE_WAIT_MS = 5_000;
const DEFAULT_LOCK_STALE_MS = 60_000;
const MAX_SESSION_STATES = 64;
const RECOVERY_REGISTRY = Symbol.for("aidevops.session-stall-recovery.registry");
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

function unwrap(response) {
  return response?.data ?? response;
}

function responseError(response) {
  return response?.error || response?.data?.error || null;
}

function sessionIDFromEvent(event) {
  return String(
    event?.properties?.sessionID
      || event?.properties?.info?.id
      || event?.properties?.info?.sessionID
      || event?.properties?.part?.sessionID
      || "",
  );
}

function safeToolCall(tool, args = {}) {
  const name = String(tool || "").toLowerCase();
  if (SAFE_TOOLS.has(name)) return true;
  if (name === "aidevops_memory" || name === "functions.aidevops_memory") {
    return String(args?.action || "recall").toLowerCase() === "recall";
  }
  return false;
}

function toolPartState(part) {
  return String(part?.state?.status || "").toLowerCase();
}

function capMap(map) {
  while (map.size > MAX_SESSION_STATES) map.delete(map.keys().next().value);
}

function processIsLive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

async function createLock(lockPath) {
  const lock = await open(lockPath, "wx", 0o600);
  try {
    await lock.writeFile(`${process.pid}\n`);
    return lock;
  } catch (error) {
    await lock.close();
    await rm(lockPath, { force: true });
    throw error;
  }
}

function recoveryFingerprint(sessionID, state) {
  return createHash("sha256")
    .update(`${sessionID}:${state.busySince}:${state.lastActivityAt}`)
    .digest("hex")
    .slice(0, 16);
}

class PersistentRecoveryLedger {
  constructor(root, clock, lockStaleMs = DEFAULT_LOCK_STALE_MS) {
    this.root = root;
    this.clock = clock;
    this.lockStaleMs = lockStaleMs;
  }

  pathFor(sessionID) {
    const name = createHash("sha256").update(sessionID).digest("hex").slice(0, 24);
    return join(this.root, `${name}.json`);
  }

  async claim(sessionID, fingerprint, cooldownMs) {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    await chmod(this.root, 0o700);
    const markerPath = this.pathFor(sessionID);
    const lockPath = `${markerPath}.lock`;
    let lock;
    try {
      lock = await createLock(lockPath);
    } catch (error) {
      if (error?.code !== "EEXIST") return false;
      try {
        const existing = await lstat(lockPath);
        const owned = existing.isFile()
          && !existing.isSymbolicLink()
          && existing.uid === process.getuid()
          && (existing.mode & 0o077) === 0;
        if (!owned || this.clock() - existing.mtimeMs < this.lockStaleMs) return false;
        const ownerPid = Number.parseInt(await readFile(lockPath, "utf8"), 10);
        if (processIsLive(ownerPid)) return false;
        await rm(lockPath);
        lock = await createLock(lockPath);
      } catch {
        return false;
      }
    }

    try {
      let previous = null;
      try {
        previous = JSON.parse(await readFile(markerPath, "utf8"));
      } catch {
        previous = null;
      }
      const attemptedAt = Number(previous?.attempted_at || 0);
      if (attemptedAt > 0 && this.clock() - attemptedAt < cooldownMs) return false;

      const temporaryPath = `${markerPath}.${process.pid}.${this.clock()}.tmp`;
      await writeFile(temporaryPath, `${JSON.stringify({ fingerprint, attempted_at: this.clock() })}\n`, {
        mode: 0o600,
        flag: "wx",
      });
      await rename(temporaryPath, markerPath);
      await chmod(markerPath, 0o600);
      return true;
    } finally {
      await lock.close();
      await rm(lockPath, { force: true });
    }
  }
}

async function liveStatus(client, sessionID, directory) {
  if (typeof client?.session?.status !== "function") return "";
  for (const args of [{ query: { directory } }, {}]) {
    try {
      const statuses = unwrap(await client.session.status(args));
      const status = statuses?.[sessionID];
      if (typeof status?.type === "string") return status.type.toLowerCase();
    } catch {
      // Try the next SDK argument shape.
    }
  }
  return "";
}

export function createSessionStallRecovery({
  client,
  directory,
  workDir,
  isEnabled = () => process.env.AIDEVOPS_STALLED_SESSION_RECOVERY === "1",
  clock = () => Date.now(),
  checkMs = DEFAULT_CHECK_MS,
  staleMs = DEFAULT_STALE_MS,
  cooldownMs = DEFAULT_COOLDOWN_MS,
  idleWaitMs = DEFAULT_IDLE_WAIT_MS,
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
  ledger = new PersistentRecoveryLedger(join(workDir, "opencode-stall-recovery"), clock),
  log = () => {},
} = {}) {
  const sessions = new Map();
  const checks = new Set();

  function stateFor(sessionID) {
    if (!sessions.has(sessionID)) {
      sessions.set(sessionID, {
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
      });
      capMap(sessions);
    }
    return sessions.get(sessionID);
  }

  function recordTool(input, args) {
    const sessionID = String(input?.sessionID || "");
    if (!sessionID) return;
    const state = stateFor(sessionID);
    if (state.recoveryPending) state.recoveryIntervened = true;
    const safe = safeToolCall(input?.tool, args);
    state.activeTool = { callID: String(input?.callID || ""), safe };
    state.lastActivityAt = clock();
    if (!safe) state.turnUnsafe = true;
  }

  function beforeTool(input, output) {
    recordTool(input, output?.args || input?.args || {});
  }

  function afterTool(input) {
    const sessionID = String(input?.sessionID || "");
    if (!sessionID) return;
    const state = stateFor(sessionID);
    if (!state.activeTool?.callID || state.activeTool.callID === String(input?.callID || "")) {
      state.activeTool = null;
    }
    state.lastActivityAt = clock();
  }

  function handleEvent({ event } = {}) {
    if (!event) return;
    const sessionID = sessionIDFromEvent(event);
    if (!sessionID) return;
    const state = stateFor(sessionID);

    if (["session.created", "session.updated"].includes(event.type)) {
      const info = event.properties?.info || {};
      if (!state.parentKnown || Object.hasOwn(info, "parentID")) {
        state.parentKnown = true;
        state.parentID = String(info.parentID || "");
      }
      state.lastActivityAt = clock();
      return;
    }
    if (event.type === "session.deleted") {
      sessions.delete(sessionID);
      return;
    }
    if (["permission.asked", "permission.updated"].includes(event.type)) {
      const requestID = String(event.properties?.id || "");
      if (requestID) state.pendingPermissionIDs.add(requestID);
      if (state.recoveryPending) state.recoveryIntervened = true;
      state.lastActivityAt = clock();
      return;
    }
    if (event.type === "permission.replied") {
      const requestID = String(event.properties?.requestID || event.properties?.permissionID || "");
      if (requestID) state.pendingPermissionIDs.delete(requestID);
      state.lastActivityAt = clock();
      return;
    }
    if (event.type === "session.status") {
      const status = String(event.properties?.status?.type || "").toLowerCase();
      if (!status) return;
      if (["busy", "retry"].includes(status) && !["busy", "retry"].includes(state.status)) {
        if (state.recoveryPending) state.recoveryIntervened = true;
        state.busySince = clock();
        state.lastActivityAt = clock();
        state.turnUnsafe = false;
      }
      state.status = status;
      if (status === "idle") state.activeTool = null;
      return;
    }
    if (event.type === "session.idle") {
      state.status = "idle";
      state.activeTool = null;
      return;
    }
    if (["message.part.updated", "message.part.delta"].includes(event.type)) {
      const part = event.properties?.part;
      state.lastActivityAt = clock();
      if (part?.type !== "tool") {
        if (state.recoveryPending) state.recoveryIntervened = true;
        return;
      }
      const status = toolPartState(part);
      if (["pending", "running"].includes(status)) {
        if (state.recoveryPending) state.recoveryIntervened = true;
        recordTool({ sessionID, callID: part.callID, tool: part.tool }, part.state?.input || {});
      } else if (["completed", "error", "failed", "aborted", "cancelled", "canceled"].includes(status)) {
        if (!state.activeTool?.callID || state.activeTool.callID === String(part.callID || "")) {
          state.activeTool = null;
        }
      }
      return;
    }
    if (event.type === "message.updated") {
      state.lastActivityAt = clock();
      if (state.recoveryPending && event.properties?.info?.role === "user") {
        state.recoveryIntervened = true;
      }
    } else if (event.type === "session.error") {
      state.lastActivityAt = clock();
    }
  }

  async function waitForIdle(sessionID) {
    const deadline = clock() + idleWaitMs;
    while (clock() < deadline) {
      const status = await liveStatus(client, sessionID, directory);
      if (status === "idle") return true;
      await sleep(Math.min(250, Math.max(1, deadline - clock())));
    }
    return false;
  }

  async function recover(sessionID, state) {
    if (!state.parentKnown || state.parentID || !["busy", "retry"].includes(state.status)) return false;
    if (state.pendingPermissionIDs.size > 0) return false;
    if (state.turnUnsafe || state.activeTool?.safe === false) return false;
    if (clock() - state.lastActivityAt < staleMs || checks.has(sessionID)) return false;
    checks.add(sessionID);
    state.recoveryIntervened = false;
    state.recoveryPending = true;
    try {
      const status = await liveStatus(client, sessionID, directory);
      if (!["busy", "retry"].includes(status)) return false;
      if (state.recoveryIntervened || state.pendingPermissionIDs.size > 0 || state.turnUnsafe || state.activeTool?.safe === false) return false;
      const fingerprint = recoveryFingerprint(sessionID, state);
      if (!await ledger.claim(sessionID, fingerprint, cooldownMs)) return false;
      if (state.recoveryIntervened || state.pendingPermissionIDs.size > 0 || state.turnUnsafe || state.activeTool?.safe === false) return false;

      if (typeof client?.session?.abort !== "function") return false;
      const aborted = await client.session.abort({ path: { id: sessionID }, body: {} });
      if (responseError(aborted) || unwrap(aborted) !== true || !await waitForIdle(sessionID)) return false;
      if (state.recoveryIntervened || state.pendingPermissionIDs.size > 0 || state.turnUnsafe) return false;

      const text = [
        "AIDEVOPS SAFE STALL RECOVERY.",
        "The previous assistant turn stopped producing activity and was aborted.",
        "Re-read the recent conversation and inspect current state before continuing the unfinished safe step.",
        "Do not repeat any write, deployment, external request, or other side effect. If safe continuation is uncertain, stop and ask the user.",
        `Recovery marker: ${fingerprint}`,
      ].join("\n");
      if (typeof client?.session?.prompt !== "function") return false;
      const prompted = await client.session.prompt({
        path: { id: sessionID },
        body: { parts: [{ type: "text", text, synthetic: true }] },
      });
      if (responseError(prompted)) return false;
      log("INFO", `[session-stall-recovery] resumed session marker=${fingerprint}`);
      return true;
    } catch (error) {
      log("WARN", `[session-stall-recovery] recovery failed: ${error?.name || "Error"}`);
      return false;
    } finally {
      state.recoveryPending = false;
      checks.delete(sessionID);
    }
  }

  async function checkNow() {
    if (!isEnabled()) return [];
    const recovered = [];
    for (const [sessionID, state] of sessions) {
      if (await recover(sessionID, state)) recovered.push(sessionID);
    }
    return recovered;
  }

  const registry = globalThis[RECOVERY_REGISTRY] || new WeakMap();
  globalThis[RECOVERY_REGISTRY] = registry;
  const registryOwner = client && typeof client === "object" ? client : sessions;
  const clientRegistry = registry.get(registryOwner) || new Map();
  registry.set(registryOwner, clientRegistry);
  const registryKey = String(directory || "unknown-directory");
  clientRegistry.get(registryKey)?.();
  let timer = null;
  const stop = () => {
    if (timer) clearInterval(timer);
    timer = null;
    if (clientRegistry.get(registryKey) === stop) clientRegistry.delete(registryKey);
  };
  if (isEnabled()) {
    timer = setInterval(() => {
      checkNow().catch((error) => log("WARN", `[session-stall-recovery] check failed: ${error?.name || "Error"}`));
    }, checkMs);
    timer.unref?.();
    clientRegistry.set(registryKey, stop);
  }

  return {
    afterTool,
    beforeTool,
    checkNow,
    handleEvent,
    stop,
  };
}

export { PersistentRecoveryLedger, safeToolCall };
