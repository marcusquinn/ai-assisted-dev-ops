/**
 * SimpleX Bot — Exec Approval Manager
 *
 * Manages the approval flow for remote command execution via chat.
 * Three-tier classification:
 *   - allowlist: execute immediately (safe commands like /status, /tasks)
 *   - approval-required: send approval request, wait for /approve, timeout-to-reject
 *   - blocklist: always rejected (dangerous patterns like rm -rf, shutdown)
 *
 * Reference: t1327.10 exec approval flow specification
 */

import type {
  ExecApprovalConfig,
  ExecClassification,
  PendingApproval,
} from "./types";
import { DEFAULT_EXEC_APPROVAL_CONFIG } from "./types";

// =============================================================================
// Approval Manager
// =============================================================================

/** Manages pending approval requests with timeout-to-reject */
export class ApprovalManager {
  private config: ExecApprovalConfig;
  private pending: Map<string, PendingApproval> = new Map();
  private timers: Map<string, ReturnType<typeof setTimeout>> = new Map();

  /** Create an approval manager with optional config overrides */
  constructor(config: Partial<ExecApprovalConfig> = {}) {
    this.config = { ...DEFAULT_EXEC_APPROVAL_CONFIG, ...config };
  }

  /** Classify a command string into allowed/approval-required/blocked */
  classify(command: string): ExecClassification {
    const normalised = command.toLowerCase().trim();

    // Check blocklist first (safety takes priority)
    for (const pattern of this.config.blocklist) {
      if (normalised.includes(pattern.toLowerCase())) {
        return "blocked";
      }
    }

    // Check allowlist
    for (const pattern of this.config.allowlist) {
      if (normalised.startsWith(pattern.toLowerCase())) {
        return "allowed";
      }
    }

    // Default behaviour
    return this.config.requireApprovalByDefault ? "approval-required" : "allowed";
  }

  /** Generate a short unique approval ID (4 hex chars) */
  private generateId(): string {
    let id: string;
    do {
      const bytes = new Uint8Array(2);
      crypto.getRandomValues(bytes);
      id = Array.from(bytes)
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
    } while (this.pending.has(id));
    return id;
  }

  /**
   * Create a pending approval request.
   * Returns the PendingApproval with a unique ID.
   * Starts the timeout timer — if not approved within the timeout, auto-rejects.
   */
  createRequest(
    command: string,
    contactId: number,
    contactName: string,
    reply: (text: string) => Promise<void>,
  ): PendingApproval {
    const id = this.generateId();
    const request: PendingApproval = {
      id,
      command,
      contactId,
      contactName,
      createdAt: Date.now(),
      state: "pending",
      reply,
    };

    this.pending.set(id, request);

    // Start timeout timer
    const timer = setTimeout(() => {
      this.expireRequest(id);
    }, this.config.approvalTimeoutMs);
    this.timers.set(id, timer);

    return request;
  }

  /**
   * Approve a pending request by ID.
   * Returns the request if found and still pending, null otherwise.
   */
  approve(id: string, approverContactId: number): PendingApproval | null {
    const request = this.pending.get(id);
    if (!request) {
      return null;
    }

    if (request.state !== "pending") {
      return null;
    }

    // Only the original requester can approve their own commands
    if (request.contactId !== approverContactId) {
      return null;
    }

    request.state = "approved";
    this.clearTimer(id);
    return request;
  }

  /**
   * Reject a pending request by ID.
   * Returns the request if found and still pending, null otherwise.
   */
  reject(id: string): PendingApproval | null {
    const request = this.pending.get(id);
    if (!request) {
      return null;
    }

    if (request.state !== "pending") {
      return null;
    }

    request.state = "rejected";
    this.clearTimer(id);
    this.pending.delete(id);
    return request;
  }

  /** Get a pending request by ID */
  getRequest(id: string): PendingApproval | undefined {
    return this.pending.get(id);
  }

  /** List all pending requests for a given contact */
  listPending(contactId?: number): PendingApproval[] {
    const results: PendingApproval[] = [];
    for (const request of this.pending.values()) {
      if (request.state !== "pending") {
        continue;
      }
      if (contactId !== undefined && request.contactId !== contactId) {
        continue;
      }
      results.push(request);
    }
    return results;
  }

  /** Format the approval timeout as a human-readable string */
  formatTimeout(): string {
    const seconds = Math.round(this.config.approvalTimeoutMs / 1000);
    if (seconds >= 60 * 60) {
      const hours = Math.round(seconds / (60 * 60));
      return `${hours}h`;
    }
    if (seconds >= 60) {
      const minutes = Math.round(seconds / 60);
      return `${minutes}m`;
    }
    return `${seconds}s`;
  }

  /** Clean up a completed/expired request */
  private cleanupRequest(id: string): void {
    this.clearTimer(id);
    this.pending.delete(id);
  }

  /** Clear the timeout timer for a request */
  private clearTimer(id: string): void {
    const timer = this.timers.get(id);
    if (timer) {
      clearTimeout(timer);
      this.timers.delete(id);
    }
  }

  /** Expire a request (called by timeout timer) */
  private expireRequest(id: string): void {
    const request = this.pending.get(id);
    if (!request || request.state !== "pending") {
      this.cleanupRequest(id);
      return;
    }

    request.state = "expired";

    // Notify the requester that their command expired
    void request.reply(
      `Approval request [${id}] expired.\n` +
      `Command: ${request.command}\n` +
      `Timed out after ${this.formatTimeout()}. Re-run the command to try again.`,
    ).catch(() => {
      // Best-effort notification — don't crash on reply failure
    });

    this.cleanupRequest(id);
  }

  /** Shut down the manager — clear all timers */
  shutdown(): void {
    for (const timer of this.timers.values()) {
      clearTimeout(timer);
    }
    this.timers.clear();
    this.pending.clear();
  }
}

// =============================================================================
// Command Execution
// =============================================================================

/**
 * Execute a shell command and return the output.
 * Used after approval is granted.
 * Enforces a per-command timeout to prevent runaway processes.
 *
 * Security note — intentional use of `sh -c`:
 * This bot's core purpose is to execute arbitrary approved shell commands
 * (including pipes, redirects, compound expressions, and shell builtins).
 * Array-based argument passing (e.g. `Bun.spawn([...args])`) cannot support
 * this use case because it bypasses shell interpretation entirely.
 *
 * The security boundary is the three-tier approval flow in `ApprovalManager`:
 *   1. Blocklist — patterns like `rm -rf`, `shutdown`, `dd` are always rejected.
 *   2. Allowlist — safe read-only commands execute immediately.
 *   3. Approval-required — everything else requires explicit human approval
 *      via `/approve <id>` before execution.
 *
 * Commands only reach this function after passing classification AND receiving
 * explicit approval. The `sh -c` pattern is therefore a deliberate design
 * choice, not a vulnerability. See t1327.10 exec approval flow specification
 * and the dismissal rationale in GH#3283.
 */
export async function executeShellCommand(
  command: string,
  timeoutMs: number = 30_000,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  // sh -c is intentional — see JSDoc above for security rationale
  const proc = Bun.spawn(["sh", "-c", command], {
    stdout: "pipe",
    stderr: "pipe",
  });

  // Race between command completion and timeout
  let timeoutId: ReturnType<typeof setTimeout> | undefined;
  const timeoutPromise = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(() => {
      proc.kill();
      reject(new Error(`Command timed out after ${Math.round(timeoutMs / 1000)}s`));
    }, timeoutMs);
  });

  try {
    const [stdout, stderr, exitCode] = await Promise.race([
      Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]),
      timeoutPromise,
    ]);

    clearTimeout(timeoutId);
    return {
      exitCode,
      stdout: truncateOutput(stdout),
      stderr: truncateOutput(stderr),
    };
  } catch (err) {
    clearTimeout(timeoutId);
    return {
      exitCode: -1,
      stdout: "",
      stderr: String(err),
    };
  }
}

/** Truncate command output to prevent flooding the chat */
function truncateOutput(text: string, maxLength: number = 2000): string {
  const trimmed = text.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return `${trimmed.substring(0, maxLength)}\n... (truncated)`;
}
