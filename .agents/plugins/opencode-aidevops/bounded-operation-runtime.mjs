// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

const MAX_CAPTURE_BYTES = 1024 * 1024;
const MAX_PROGRESS_REMAINDER_BYTES = 4096;
const RECEIPT_SCHEMA = "aidevops.interactive-operation/v1";

export function appendCapture(operation, chunk) {
  const value = Buffer.from(chunk);
  const remaining = MAX_CAPTURE_BYTES - operation.outputBytes;
  if (remaining <= 0) {
    operation.outputTruncated = true;
    return;
  }
  operation.output.push(value.subarray(0, remaining));
  operation.outputBytes += Math.min(value.length, remaining);
  if (value.length > remaining) operation.outputTruncated = true;
}

export function observeProgress(operation, chunk, now) {
  const text = `${operation.progressRemainder}${String(chunk)}`;
  const lines = text.split(/\r?\n/);
  operation.progressRemainder = lines.pop() || "";
  if (Buffer.byteLength(operation.progressRemainder) > MAX_PROGRESS_REMAINDER_BYTES) {
    operation.progressRemainder = operation.progressRemainder.slice(-MAX_PROGRESS_REMAINDER_BYTES);
  }
  for (const line of lines) {
    if (/^AIDEVOPS_PROGRESS:\s*\S/.test(line)) {
      operation.lastMeaningfulProgressAt = now();
      operation.progressEvents += 1;
    }
  }
}

export function signalSupervisor(child) {
  if (!child?.connected || child.exitCode !== null || child.signalCode !== null) return false;
  try {
    child.send({ action: "terminate" });
    return true;
  } catch {
    return false;
  }
}

export function trimTerminalOperations(operations, maximum) {
  if (operations.size < maximum) return;
  for (const [id, operation] of operations) {
    if (!operation.child && !operation.restorationChild) operations.delete(id);
    if (operations.size < maximum) return;
  }
  throw new Error("too many active bounded operations");
}

export function operationReceipt(operation, now) {
  const elapsedMs = Math.max(0, now - operation.startedAt);
  const lastProgressAgeMs = operation.lastMeaningfulProgressAt === null
    ? null
    : Math.max(0, now - operation.lastMeaningfulProgressAt);
  return {
    schema: RECEIPT_SCHEMA,
    operation_id: operation.id,
    containment: "owned_process_group",
    state: operation.state,
    elapsed_ms: elapsedMs,
    budget_ms: operation.budgetMs,
    remaining_ms: Math.max(0, operation.budgetMs - elapsedMs),
    progress_interval_ms: operation.progressIntervalMs,
    progress_events: operation.progressEvents,
    last_meaningful_progress_age_ms: lastProgressAgeMs,
    progress_overdue: elapsedMs >= operation.progressIntervalMs
      && (lastProgressAgeMs === null || lastProgressAgeMs >= operation.progressIntervalMs),
    process_exit: operation.processExit,
    process_signal: operation.processSignal || null,
    command_execution: operation.state === "starting" || operation.state === "running"
      ? "pending"
      : (operation.commandStarted ? "observed" : "missing"),
    supervisor_runtime: operation.supervisorRuntime || null,
    restoration_state: operation.restorationState,
    restoration_exit: operation.restorationExit,
    output_id: operation.outputID || null,
    evidence_state: operation.state === "finalizing" ? "pending" : (operation.outputID ? "recorded" : "unavailable"),
    output_truncated: operation.outputTruncated,
  };
}

export function disposeOperations(operations, kill, clearTimer) {
  for (const operation of operations.values()) {
    if (operation.child && !operation.childExited
      && operation.child.exitCode === null && operation.child.signalCode === null) {
      kill(operation.child, "SIGTERM");
    }
    if (operation.restorationChild && !operation.restorationChildExited
      && operation.restorationChild.exitCode === null && operation.restorationChild.signalCode === null) {
      kill(operation.restorationChild, "SIGTERM");
    }
    if (operation.budgetTimer) clearTimer(operation.budgetTimer);
    if (operation.killTimer) clearTimer(operation.killTimer);
    if (operation.restorationTimer) clearTimer(operation.restorationTimer);
  }
}
