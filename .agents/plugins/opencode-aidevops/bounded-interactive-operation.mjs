// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { randomBytes } from "node:crypto";
import { realpathSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const RECEIPT_SCHEMA = "aidevops.interactive-operation/v1";
const MAX_CAPTURE_BYTES = 1024 * 1024;
const MAX_OPERATIONS = 24;
const MAX_PROGRESS_REMAINDER_BYTES = 4096;
const SUPERVISOR_PATH = fileURLToPath(new URL("./bounded-operation-supervisor.mjs", import.meta.url));

function scalar(value) {
  return typeof value === "string" ? value.trim() : "";
}

function withinRoot(path, root) {
  return path === root || path.startsWith(`${root}/`);
}

function commandError(command) {
  if (!Array.isArray(command) || command.length === 0) return "command must be a non-empty string array";
  if (command.some((part) => typeof part !== "string" || !part || part.includes("\0"))) {
    return "command entries must be non-empty strings without NUL bytes";
  }
  if (Buffer.byteLength(JSON.stringify(command)) > 64 * 1024) return "encoded command exceeds 64 KiB";
  return "";
}

function boundedInteger(value, fallback, minimum, maximum) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.floor(parsed)));
}

function appendCapture(operation, chunk) {
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

function observeProgress(operation, chunk, now) {
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

function signalSupervisor(child) {
  if (!child?.connected || child.exitCode !== null || child.signalCode !== null) return false;
  try {
    child.send({ action: "terminate" });
    return true;
  } catch {
    return false;
  }
}

function responseError(message) {
  return JSON.stringify({ schema: RECEIPT_SCHEMA, error: message });
}

export function createOutputSandboxRecorder(helperPath, spawnImpl = spawn, timeoutMs = 5000) {
  const activeChildren = new Set();
  const recorder = (content, evidence = {}) => new Promise((resolve) => {
    const exitCode = Number.isInteger(evidence.exitCode) ? evidence.exitCode : 1;
    const child = spawnImpl("bash", [
      helperPath, "store", "--command", "bounded-interactive-operation",
      "--exit-code", String(exitCode), "--tag", "interactive-operation",
    ], { stdio: ["pipe", "pipe", "ignore"] });
    activeChildren.add(child);
    let stdout = "";
    let settled = false;
    const finish = (outputID = "") => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      activeChildren.delete(child);
      resolve(outputID);
    };
    const timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      finish();
    }, timeoutMs);
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => { stdout += chunk; });
    child.once("error", () => finish());
    child.once("close", (code) => {
      const match = code === 0 ? stdout.match(/^output_id:\s*(\S+)/m) : null;
      finish(match?.[1] || "");
    });
    child.stdin?.end(content);
  });
  recorder.dispose = () => {
    for (const child of activeChildren) {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }
    activeChildren.clear();
  };
  return recorder;
}

export class BoundedInteractiveOperationManager {
  constructor(options = {}) {
    this.projectRoot = realpathSync(options.projectRoot || process.cwd());
    this.spawn = options.spawn || spawn;
    this.now = options.now || Date.now;
    this.makeID = options.makeID || (() => `op_${this.now()}_${randomBytes(6).toString("hex")}`);
    this.recordOutput = options.recordOutput || (async () => "");
    this.kill = options.kill || signalSupervisor;
    this.killGraceMs = options.killGraceMs ?? 500;
    this.setTimer = options.setTimer || setTimeout;
    this.clearTimer = options.clearTimer || clearTimeout;
    this.operations = new Map();
  }

  resolveCwd(requested) {
    const cwd = realpathSync(requested || this.projectRoot);
    if (!withinRoot(cwd, this.projectRoot)) throw new Error("cwd must remain inside the active project root");
    return cwd;
  }

  trimTerminalOperations() {
    if (this.operations.size < MAX_OPERATIONS) return;
    for (const [id, operation] of this.operations) {
      if (!operation.child && !operation.restorationChild) this.operations.delete(id);
      if (this.operations.size < MAX_OPERATIONS) return;
    }
    throw new Error("too many active bounded operations");
  }

  attachOutput(operation, child) {
    for (const stream of [child.stdout, child.stderr]) {
      stream?.on("data", (chunk) => {
        appendCapture(operation, chunk);
        observeProgress(operation, chunk, this.now);
      });
    }
  }

  spawnOwned(operation, command) {
    const childBudgetMs = command === operation.command ? operation.budgetMs : operation.restorationBudgetMs;
    const child = this.spawn(process.execPath, [SUPERVISOR_PATH], {
      cwd: operation.cwd,
      detached: true,
      env: process.env,
      stdio: ["pipe", "pipe", "pipe", "ipc"],
    });
    child.stdin.end(JSON.stringify({
      budgetMs: childBudgetMs,
      command,
      killGraceMs: this.killGraceMs,
      operationID: operation.id,
    }));
    this.attachOutput(operation, child);
    return child;
  }

  async start(args, context = {}) {
    const owner = scalar(context.sessionID);
    if (!owner) throw new Error("runtime session identity is required");
    const invalid = commandError(args.command) || (args.restorationCommand ? commandError(args.restorationCommand) : "");
    if (invalid) throw new Error(invalid);
    this.trimTerminalOperations();

    const startedAt = this.now();
    const operation = {
      id: this.makeID(),
      owner,
      cwd: this.resolveCwd(args.cwd),
      command: [...args.command],
      restorationCommand: args.restorationCommand ? [...args.restorationCommand] : null,
      budgetMs: boundedInteger(args.budgetMs, 15 * 60 * 1000, 10, 24 * 60 * 60 * 1000),
      progressIntervalMs: boundedInteger(args.progressIntervalMs, 15 * 60 * 1000, 10, 60 * 60 * 1000),
      restorationBudgetMs: boundedInteger(args.restorationBudgetMs, 60 * 1000, 10, 10 * 60 * 1000),
      startedAt,
      state: "starting",
      disposition: "running",
      processExit: null,
      processSignal: "",
      restorationState: args.restorationCommand ? "pending" : "not_required",
      restorationExit: null,
      lastMeaningfulProgressAt: null,
      progressEvents: 0,
      progressRemainder: "",
      output: [],
      outputBytes: 0,
      outputTruncated: false,
      outputID: "",
      ownerDeleted: false,
      child: null,
      childExited: false,
      restorationChild: null,
      restorationChildExited: false,
      restorationTimer: null,
      budgetTimer: null,
      killTimer: null,
    };
    this.operations.set(operation.id, operation);

    await new Promise((resolve) => {
      const child = this.spawnOwned(operation, operation.command);
      operation.child = child;
      child.once("exit", () => { operation.childExited = true; });
      child.once("spawn", () => {
        operation.state = "running";
        operation.budgetTimer = this.setTimer(() => this.requestTermination(operation, "timed_out"), operation.budgetMs);
        resolve();
      });
      child.once("error", async () => {
        operation.spawnFailed = true;
        operation.disposition = "failed";
        operation.child = null;
        if (operation.restorationCommand) await this.runRestoration(operation);
        await this.finalize(operation);
        resolve();
      });
      child.once("close", (code, signal) => {
        if (!operation.spawnFailed) this.mainClosed(operation, code, signal);
      });
    });
    return this.receipt(operation);
  }

  requestTermination(operation, disposition) {
    if (!operation.child || operation.childExited
      || operation.child.exitCode !== null || operation.child.signalCode !== null
      || !["running", "starting"].includes(operation.state)) return false;
    operation.disposition = disposition;
    operation.state = disposition === "cancelled" ? "cancelling" : "timing_out";
    operation.processSignal = "SIGTERM";
    const signalled = this.kill(operation.child, "SIGTERM");
    return signalled;
  }

  async mainClosed(operation, code, signal) {
    if (operation.budgetTimer) this.clearTimer(operation.budgetTimer);
    if (operation.killTimer) this.clearTimer(operation.killTimer);
    operation.child = null;
    operation.processExit = Number.isInteger(code) ? code : null;
    operation.processSignal = scalar(signal);
    if (operation.disposition === "running") operation.disposition = code === 0 ? "succeeded" : "failed";
    if (operation.restorationCommand) await this.runRestoration(operation);
    await this.finalize(operation);
  }

  async runRestoration(operation) {
    operation.state = "restoring";
    operation.restorationState = "running";
    await new Promise((resolve) => {
      let settled = false;
      const finish = (state, code = null) => {
        if (settled) return;
        settled = true;
        if (operation.restorationTimer) this.clearTimer(operation.restorationTimer);
        operation.restorationChild = null;
        operation.restorationExit = Number.isInteger(code) ? code : null;
        operation.restorationState = state;
        resolve();
      };
      const child = this.spawnOwned(operation, operation.restorationCommand);
      operation.restorationChild = child;
      operation.restorationChildExited = false;
      child.once("exit", () => { operation.restorationChildExited = true; });
      operation.restorationTimer = this.setTimer(() => {
        operation.restorationState = "timing_out";
        if (!operation.restorationChildExited && child.exitCode === null && child.signalCode === null) {
          this.kill(child, "SIGTERM");
        }
      }, operation.restorationBudgetMs);
      child.once("error", () => finish("failed"));
      child.once("close", (code, signal) => {
        const timedOut = operation.restorationState === "timing_out";
        finish(timedOut ? "timed_out" : (code === 0 ? "succeeded" : "failed"), code);
      });
    });
  }

  async finalize(operation) {
    const finalState = !["not_required", "succeeded"].includes(operation.restorationState)
      && operation.disposition === "succeeded"
      ? "restoration_failed"
      : operation.disposition;
    operation.state = "finalizing";
    try {
      operation.outputID = await this.recordOutput(Buffer.concat(operation.output), {
        exitCode: operation.processExit,
        state: finalState,
      });
    } catch {
      operation.outputID = "";
    }
    operation.output = [];
    operation.state = finalState;
    if (operation.ownerDeleted) this.operations.delete(operation.id);
  }

  ownedOperation(id, context = {}) {
    const operation = this.operations.get(scalar(id));
    if (!operation) throw new Error("operation is unavailable or belongs to an expired generation");
    if (!scalar(context.sessionID) || operation.owner !== scalar(context.sessionID)) {
      throw new Error("operation owner mismatch");
    }
    return operation;
  }

  status(id, context = {}) {
    return this.receipt(this.ownedOperation(id, context));
  }

  cancel(id, context = {}) {
    const operation = this.ownedOperation(id, context);
    if (!["running", "starting"].includes(operation.state)) return this.receipt(operation);
    if (!this.requestTermination(operation, "cancelled")) throw new Error("owned process could not be signalled");
    return this.receipt(operation);
  }

  handleEvent(input) {
    const event = input?.event || input;
    if (event?.type !== "session.deleted") return;
    const owner = scalar(event.properties?.info?.id || event.properties?.sessionID);
    if (!owner) return;
    for (const operation of this.operations.values()) {
      if (operation.owner !== owner) continue;
      operation.ownerDeleted = true;
      this.requestTermination(operation, "cancelled");
      if (!operation.child && !operation.restorationChild) this.operations.delete(operation.id);
    }
  }

  receipt(operation) {
    const now = this.now();
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
      restoration_state: operation.restorationState,
      restoration_exit: operation.restorationExit,
      output_id: operation.outputID || null,
      evidence_state: operation.state === "finalizing" ? "pending" : (operation.outputID ? "recorded" : "unavailable"),
      output_truncated: operation.outputTruncated,
    };
  }

  dispose() {
    for (const operation of this.operations.values()) {
      if (operation.child && !operation.childExited
        && operation.child.exitCode === null && operation.child.signalCode === null) {
        this.kill(operation.child, "SIGTERM");
      }
      if (operation.restorationChild && !operation.restorationChildExited
        && operation.restorationChild.exitCode === null && operation.restorationChild.signalCode === null) {
        this.kill(operation.restorationChild, "SIGTERM");
      }
      if (operation.budgetTimer) this.clearTimer(operation.budgetTimer);
      if (operation.killTimer) this.clearTimer(operation.killTimer);
      if (operation.restorationTimer) this.clearTimer(operation.restorationTimer);
    }
    this.recordOutput.dispose?.();
  }
}

export function createBoundedInteractiveOperationTool(tool, z, manager) {
  return tool({
    description:
      "Start, inspect, or cancel a bounded long-running command without blocking the interactive session. " +
      "Use start for operations expected to exceed the progress interval, then call status periodically. " +
      "Commands are argv arrays, remain confined to the active project root, and must not daemonize or create a new process session. " +
      "Cancellation is session-owned and restoration evidence remains explicit.",
    args: {
      action: z.enum(["start", "status", "cancel"]),
      operation_id: z.string().optional(),
      command: z.array(z.string()).optional(),
      cwd: z.string().optional(),
      budget_seconds: z.number().optional(),
      progress_interval_seconds: z.number().optional(),
      restoration_budget_seconds: z.number().optional(),
      restoration_command: z.array(z.string()).optional(),
    },
    async execute(args, context) {
      try {
        let receipt;
        if (args.action === "start") {
          receipt = await manager.start({
            command: args.command,
            cwd: args.cwd,
            budgetMs: Number(args.budget_seconds || 900) * 1000,
            progressIntervalMs: Number(args.progress_interval_seconds || 900) * 1000,
            restorationBudgetMs: Number(args.restoration_budget_seconds || 60) * 1000,
            restorationCommand: args.restoration_command,
          }, context);
        } else if (args.action === "status") {
          receipt = manager.status(args.operation_id, context);
        } else if (args.action === "cancel") {
          receipt = manager.cancel(args.operation_id, context);
        } else {
          return responseError("unknown action");
        }
        return JSON.stringify(receipt);
      } catch (error) {
        return responseError(error?.message || "bounded operation failed");
      }
    },
  });
}
