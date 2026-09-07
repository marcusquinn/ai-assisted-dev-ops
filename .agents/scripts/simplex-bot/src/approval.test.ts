/**
 * Tests for the Exec Approval Manager
 *
 * Verifies: classification, request lifecycle, timeout, approve/reject flows.
 * Run: bun test
 */

import { beforeEach, describe, expect, mock, test } from "bun:test";
import { ApprovalManager } from "./approval";
import { DEFAULT_EXEC_APPROVAL_CONFIG } from "./types";

describe("ApprovalManager", () => {
  let manager: ApprovalManager;
  const noopReply = mock(async (_text: string): Promise<void> => {});

  beforeEach(() => {
    manager = new ApprovalManager();
    noopReply.mockClear();
  });

  // ===========================================================================
  // Classification
  // ===========================================================================

  describe("classify", () => {
    test("allowlisted commands return 'allowed'", () => {
      expect(manager.classify("aidevops status")).toBe("allowed");
      expect(manager.classify("aidevops repos")).toBe("allowed");
      expect(manager.classify("aidevops features")).toBe("allowed");
    });

    test("allowlist matching is case-insensitive", () => {
      expect(manager.classify("AIDEVOPS STATUS")).toBe("allowed");
      expect(manager.classify("Aidevops Repos")).toBe("allowed");
    });

    test("allowlist matches prefix (allows args after allowlisted command)", () => {
      expect(manager.classify("aidevops status --verbose")).toBe("allowed");
    });

    test("blocklisted patterns return 'blocked'", () => {
      expect(manager.classify("rm -rf /")).toBe("blocked");
      expect(manager.classify("sudo shutdown -h now")).toBe("blocked");
      expect(manager.classify("reboot")).toBe("blocked");
      expect(manager.classify("mkfs.ext4 /dev/sda1")).toBe("blocked");
    });

    test("blocklist takes priority over allowlist", () => {
      const custom = new ApprovalManager({
        allowlist: ["rm -rf"],
        blocklist: ["rm -rf"],
      });
      expect(custom.classify("rm -rf /tmp")).toBe("blocked");
    });

    test("unknown commands require approval by default", () => {
      expect(manager.classify("curl https://example.com")).toBe("approval-required");
      expect(manager.classify("ls -la")).toBe("approval-required");
      expect(manager.classify("docker ps")).toBe("approval-required");
    });

    test("requireApprovalByDefault=false allows unknown commands", () => {
      const permissive = new ApprovalManager({
        requireApprovalByDefault: false,
      });
      expect(permissive.classify("curl https://example.com")).toBe("allowed");
    });
  });

  // ===========================================================================
  // Request Lifecycle
  // ===========================================================================

  describe("createRequest", () => {
    test("creates a pending request with unique ID", () => {
      const req = manager.createRequest("docker ps", 1, "alice", noopReply);
      expect(req.id).toHaveLength(4);
      expect(req.command).toBe("docker ps");
      expect(req.contactId).toBe(1);
      expect(req.contactName).toBe("alice");
      expect(req.state).toBe("pending");
    });

    test("multiple requests get unique IDs", () => {
      const req1 = manager.createRequest("cmd1", 1, "alice", noopReply);
      const req2 = manager.createRequest("cmd2", 1, "alice", noopReply);
      expect(req1.id).not.toBe(req2.id);
    });
  });

  describe("approve", () => {
    test("approves a pending request from the same contact", () => {
      const req = manager.createRequest("docker ps", 1, "alice", noopReply);
      const approved = manager.approve(req.id, 1);
      expect(approved).not.toBeNull();
      expect(approved?.state).toBe("approved");
    });

    test("rejects approval from a different contact", () => {
      const req = manager.createRequest("docker ps", 1, "alice", noopReply);
      const result = manager.approve(req.id, 2);
      expect(result).toBeNull();
    });

    test("returns null for non-existent request", () => {
      expect(manager.approve("xxxx", 1)).toBeNull();
    });

    test("returns null for already-approved request", () => {
      const req = manager.createRequest("docker ps", 1, "alice", noopReply);
      manager.approve(req.id, 1);
      const second = manager.approve(req.id, 1);
      expect(second).toBeNull();
    });
  });

  describe("reject", () => {
    test("rejects a pending request", () => {
      const req = manager.createRequest("docker ps", 1, "alice", noopReply);
      const rejected = manager.reject(req.id);
      expect(rejected).not.toBeNull();
      expect(rejected?.state).toBe("rejected");
    });

    test("returns null for non-existent request", () => {
      expect(manager.reject("xxxx")).toBeNull();
    });
  });

  describe("listPending", () => {
    test("lists all pending requests", () => {
      manager.createRequest("cmd1", 1, "alice", noopReply);
      manager.createRequest("cmd2", 2, "bob", noopReply);
      expect(manager.listPending()).toHaveLength(2);
    });

    test("filters by contactId", () => {
      manager.createRequest("cmd1", 1, "alice", noopReply);
      manager.createRequest("cmd2", 2, "bob", noopReply);
      expect(manager.listPending(1)).toHaveLength(1);
      expect(manager.listPending(1)[0].contactName).toBe("alice");
    });

    test("excludes non-pending requests", () => {
      const req = manager.createRequest("cmd1", 1, "alice", noopReply);
      manager.approve(req.id, 1);
      manager.createRequest("cmd2", 1, "alice", noopReply);
      expect(manager.listPending(1)).toHaveLength(1);
    });
  });

  // ===========================================================================
  // Timeout
  // ===========================================================================

  describe("timeout", () => {
    test("expires request after timeout and notifies requester", async () => {
      const replyMock = mock(async (_text: string): Promise<void> => {});
      const shortTimeout = new ApprovalManager({ approvalTimeoutMs: 100 });
      const req = shortTimeout.createRequest("docker ps", 1, "alice", replyMock);

      try {
        await new Promise((resolve) => setTimeout(resolve, 200));

        // Request should be expired and cleaned up
        expect(shortTimeout.getRequest(req.id)).toBeUndefined();
        expect(shortTimeout.listPending()).toHaveLength(0);

        // Reply should have been called with expiry message
        expect(replyMock).toHaveBeenCalledTimes(1);
        const callArg = replyMock.mock.calls[0][0];
        expect(callArg).toContain("expired");
        expect(callArg).toContain(req.id);
      } finally {
        shortTimeout.shutdown();
      }
    });
  });

  // ===========================================================================
  // Shutdown
  // ===========================================================================

  describe("shutdown", () => {
    test("clears all pending requests and timers", () => {
      manager.createRequest("cmd1", 1, "alice", noopReply);
      manager.createRequest("cmd2", 2, "bob", noopReply);
      manager.shutdown();
      expect(manager.listPending()).toHaveLength(0);
    });
  });

  // ===========================================================================
  // Custom Config
  // ===========================================================================

  describe("custom config", () => {
    test("defaults to a 12-hour approval window", () => {
      expect(DEFAULT_EXEC_APPROVAL_CONFIG.approvalTimeoutMs).toBe(12 * 60 * 60 * 1000);
      expect(manager.formatTimeout()).toBe("12h");
    });

    test("custom allowlist overrides defaults", () => {
      const custom = new ApprovalManager({
        allowlist: ["git status", "git log"],
      });
      expect(custom.classify("git status")).toBe("allowed");
      expect(custom.classify("aidevops status")).toBe("approval-required");
    });

    test("custom blocklist merges with intent", () => {
      const custom = new ApprovalManager({
        blocklist: [...DEFAULT_EXEC_APPROVAL_CONFIG.blocklist, "curl"],
      });
      expect(custom.classify("curl https://evil.com")).toBe("blocked");
      expect(custom.classify("rm -rf /")).toBe("blocked");
    });

    test("formatTimeout returns human-readable string", () => {
      const m1 = new ApprovalManager({ approvalTimeoutMs: 60_000 });
      expect(m1.formatTimeout()).toBe("1m");

      const m2 = new ApprovalManager({ approvalTimeoutMs: 30_000 });
      expect(m2.formatTimeout()).toBe("30s");

      const m3 = new ApprovalManager({ approvalTimeoutMs: 120_000 });
      expect(m3.formatTimeout()).toBe("2m");

      const m4 = new ApprovalManager({ approvalTimeoutMs: 12 * 60 * 60 * 1000 });
      expect(m4.formatTimeout()).toBe("12h");
    });
  });
});
