// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { join } from "node:path";

import { SessionStallEventHandler } from "./session-stall-recovery-events.mjs";
import { PersistentRecoveryLedger } from "./session-stall-recovery-ledger.mjs";
import { SessionRecoveryRunner } from "./session-stall-recovery-runner.mjs";
import { SessionRecoveryScheduler } from "./session-stall-recovery-scheduler.mjs";
import { safeToolCall, SessionStallStateStore } from "./session-stall-recovery-state.mjs";

const DEFAULT_CHECK_MS = 60_000;
const DEFAULT_STALE_MS = 10 * 60_000;
const DEFAULT_COOLDOWN_MS = 30 * 60_000;
const DEFAULT_IDLE_WAIT_MS = 5_000;

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
  const store = new SessionStallStateStore(clock);
  const eventHandler = new SessionStallEventHandler(store, clock);
  const runner = new SessionRecoveryRunner({
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
  });
  const scheduler = new SessionRecoveryScheduler({
    client,
    directory,
    fallbackOwner: store.sessions,
    checkNow: runner.checkNow.bind(runner),
    isEnabled,
    checkMs,
    log,
  });
  scheduler.start();

  return {
    afterTool: store.afterTool.bind(store),
    beforeTool: store.beforeTool.bind(store),
    checkNow: runner.checkNow.bind(runner),
    handleEvent: eventHandler.handle.bind(eventHandler),
    stop: scheduler.stop,
  };
}

export { PersistentRecoveryLedger, safeToolCall };
