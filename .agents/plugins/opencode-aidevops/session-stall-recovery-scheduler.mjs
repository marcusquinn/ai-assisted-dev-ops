// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const RECOVERY_REGISTRY = Symbol.for("aidevops.session-stall-recovery.registry");

class SessionRecoveryScheduler {
  constructor({ client, directory, fallbackOwner, checkNow, isEnabled, checkMs, log }) {
    const registry = globalThis[RECOVERY_REGISTRY] || new WeakMap();
    globalThis[RECOVERY_REGISTRY] = registry;
    const registryOwner = client && typeof client === "object" ? client : fallbackOwner;
    this.clientRegistry = registry.get(registryOwner) || new Map();
    registry.set(registryOwner, this.clientRegistry);
    this.registryKey = String(directory || "unknown-directory");
    this.checkNow = checkNow;
    this.isEnabled = isEnabled;
    this.checkMs = checkMs;
    this.log = log;
    this.timer = null;
    this.stop = this.stop.bind(this);
  }

  start() {
    const previousStop = this.clientRegistry.get(this.registryKey);
    if (previousStop) previousStop();
    if (this.isEnabled()) {
      this.timer = setInterval(() => {
        this.checkNow().catch((error) => {
          this.log("WARN", `[session-stall-recovery] check failed: ${error?.name || "Error"}`);
        });
      }, this.checkMs);
      this.timer.unref?.();
      this.clientRegistry.set(this.registryKey, this.stop);
    }
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    if (this.clientRegistry.get(this.registryKey) === this.stop) {
      this.clientRegistry.delete(this.registryKey);
    }
  }
}

export { SessionRecoveryScheduler };
