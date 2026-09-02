// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  directFileMutations,
  expectedSimpleMutationContent,
  isDirectFileMutationTool,
} from "./quality-hooks-git-safety.mjs";
import {
  applyApprovedMutationPatch,
  renderApprovedSourceContent,
} from "./source-access-manifest-approval.mjs";

export const ROOT_BROKER = "/etc/aidevops/source-access/source-access-helper.py";
const REQUEST_ID_PATTERN = /^[a-f0-9]{32,64}$/;

function provenanceKey(sessionId, filePath) {
  return `${sessionId}\0${resolve(filePath)}`;
}

function operationKey(sessionId, callId) {
  return `${sessionId}\0${callId}`;
}

function sameIdentity(candidate, state) {
  return Boolean(candidate) && candidate.repoRoot === state.repoRoot &&
    candidate.relativePath === state.relativePath;
}

function completeMutationMatches(approval, snapshot, state, entry) {
  return sameIdentity(approval, state) && sameIdentity(snapshot, state) &&
    snapshot.contentSha256 === entry.expectedSha256 && snapshot.content.equals(entry.expectedContent);
}

function expectedApprovedMutationContent(state, mutation) {
  const simple = expectedSimpleMutationContent(state, mutation);
  return simple === undefined ? applyApprovedMutationPatch(state, mutation) : simple;
}

class MutationProvenance {
  constructor(options) {
    Object.assign(this, options);
    this.approvals = new Map();
    this.pendingMutations = new Map();
    this.pendingReads = new Map();
    this.denialReasons = new Map();
  }

  invalidate(key, reason) {
    this.approvals.delete(key);
    this.denialReasons.set(key, reason);
  }

  revalidate(state, sessionId, filePath, reason) {
    if (this.now() >= state.expiresAt) return { denial: "expired" };
    let approval = false;
    try {
      approval = this.verify({
        sessionId, filePath, reason, repositoryDir: this.repositoryDir,
        authorizedApprovalId: state.approvalId,
      });
    } catch {
      return { denial: "invalid" };
    }
    if (!sameIdentity(approval, state)) return { denial: "invalid" };
    const snapshot = this.snapshot(filePath, this.git, this.gitRun);
    if (!sameIdentity(snapshot, state) || snapshot.contentSha256 !== state.contentSha256) {
      return { denial: "drift" };
    }
    return { approval, snapshot };
  }

  rememberApproval({ sessionId, filePath, approval }) {
    const fields = ["approvalId", "canonicalPath", "contentSha256", "expiresAt", "repoRoot", "relativePath"];
    if (!fields.every((field) => approval?.[field])) return;
    try {
      const content = readFileSync(approval.approvedPath);
      if (createHash("sha256").update(content).digest("hex") !== approval.contentSha256) return;
      this.approvals.set(provenanceKey(sessionId, filePath), { ...approval, content });
      this.denialReasons.delete(provenanceKey(sessionId, filePath));
    } catch {
      // The initial root-owned snapshot remains mandatory; never cache an unreadable path.
    }
  }

  authorizeRead({ sessionId, callId, filePath, reason, args }) {
    const key = provenanceKey(sessionId, filePath);
    const state = this.approvals.get(key);
    if (!state || !callId) return false;
    const result = this.revalidate(state, sessionId, filePath, reason);
    if (!result.approval) {
      this.invalidate(key, result.denial);
      return false;
    }
    this.pendingReads.set(operationKey(sessionId, callId), {
      args: { ...args }, content: Buffer.from(state.content),
    });
    return { ...result.approval, approvedPath: state.approvedPath };
  }

  finishRead(sessionId, callId, output, succeeded) {
    const key = operationKey(sessionId, callId);
    const pending = this.pendingReads.get(key);
    this.pendingReads.delete(key);
    if (!pending || !succeeded) return;
    output.output = renderApprovedSourceContent(pending.content, pending.args, output.output);
    output.metadata = { ...(output.metadata || {}), sourceAccessContinuation: true };
  }

  beginMutation({ sessionId, callId, mutations, reason = this.reason }) {
    if (!callId || !Array.isArray(mutations)) return;
    const entries = [];
    for (const mutation of mutations) {
      const key = provenanceKey(sessionId, mutation.filePath);
      const state = this.approvals.get(key);
      if (!state) continue;
      const result = this.revalidate(state, sessionId, mutation.filePath, reason);
      const expectedContent = result.approval && expectedApprovedMutationContent(state, mutation);
      if (!expectedContent) {
        this.invalidate(key, result.denial || "drift");
        continue;
      }
      entries.push({
        expectedContent,
        expectedSha256: createHash("sha256").update(expectedContent).digest("hex"),
        filePath: mutation.filePath,
        key,
        state,
      });
    }
    if (entries.length > 0) this.pendingMutations.set(operationKey(sessionId, callId), entries);
  }

  finishMutation({ sessionId, callId, succeeded, reason = this.reason }) {
    const pendingKey = operationKey(sessionId, callId);
    const entries = this.pendingMutations.get(pendingKey) || [];
    this.pendingMutations.delete(pendingKey);
    for (const entry of entries) this.finishMutationEntry(entry, sessionId, reason, succeeded);
  }

  finishMutationEntry(entry, sessionId, reason, succeeded) {
    if (!succeeded) {
      this.invalidate(entry.key, "drift");
      return;
    }
    let approval = false;
    try {
      approval = this.verify({
        sessionId, filePath: entry.filePath, reason, repositoryDir: this.repositoryDir,
        authorizedApprovalId: entry.state.approvalId,
      });
    } catch {
      this.invalidate(entry.key, "invalid");
      return;
    }
    const snapshot = this.snapshot(entry.filePath, this.git, this.gitRun);
    if (!completeMutationMatches(approval, snapshot, entry.state, entry)) {
      this.invalidate(entry.key, "drift");
      return;
    }
    this.approvals.set(entry.key, {
      ...entry.state, content: Buffer.from(snapshot.content), contentSha256: snapshot.contentSha256,
    });
    this.denialReasons.delete(entry.key);
  }

  denialReason(sessionId, filePath) {
    return this.denialReasons.get(provenanceKey(sessionId, filePath)) || "missing";
  }
}

export function createMutationProvenance(options) {
  return new MutationProvenance(options);
}

export function observedToolSucceeded(output, classify) {
  if (!output || typeof output !== "object") return false;
  const hasOutcome = typeof output.output === "string" || (output.metadata && typeof output.metadata === "object");
  return hasOutcome && classify(output);
}

export function beginObservedSourceMutation(context, input, output) {
  if (!isDirectFileMutationTool(input.tool)) return;
  context.sourceAccessProvenance.beginMutation({
    sessionId: context.sessionId,
    callId: input.callID || "",
    mutations: directFileMutations(input.tool, output.args, context.repositoryDir),
    reason: context.sourceAccessReason,
  });
}

export function finishObservedSourceAccess(context, input, output, classify) {
  const callId = input.callID || "";
  const succeeded = observedToolSucceeded(output, classify);
  context.sourceAccessProvenance.finishRead(context.sessionId, callId, output, succeeded);
  if (!isDirectFileMutationTool(input.tool)) return;
  context.sourceAccessProvenance.finishMutation({
    sessionId: context.sessionId,
    callId,
    succeeded,
    reason: context.sourceAccessReason,
  });
}

function runSourceAccessHelper(helperArgs, run) {
  return String(
    run("/usr/bin/python3", ["-I", "-B", ROOT_BROKER, ...helperArgs], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 15000,
    }),
  ).trim();
}

export function brokerMatchesCurrentRelease(brokerMatches, scriptsDir) {
  try {
    return brokerMatches({ scriptsDir });
  } catch {
    return false;
  }
}

export function applyApprovedRead(args, approval, filePath, log) {
  if (!approval?.approvedPath) return false;
  if (Object.hasOwn(args, "filePath")) args.filePath = approval.approvedPath;
  if (Object.hasOwn(args, "file_path")) args.file_path = approval.approvedPath;
  log("INFO", `[source-access] verified session-bound read approval for ${filePath}`);
  return true;
}

export function requestApprovalId({ brokerCurrent, filePath, reason, requestRun, sessionId }) {
  if (!brokerCurrent) return "";
  try {
    const requestId = runSourceAccessHelper(
      ["request", "--session", sessionId, "--path", filePath, "--reason", reason],
      requestRun,
    );
    return REQUEST_ID_PATTERN.test(requestId) ? requestId : "";
  } catch {
    // Request generation is advisory; the original guard remains authoritative.
    return "";
  }
}

export function checkGateWithApprovalInstructions({
  args,
  brokerCurrent,
  checkSecretReadGate,
  filePath,
  log,
  requestId,
  denialReason = "missing",
  tool,
}) {
  try {
    checkSecretReadGate(tool, args, log);
  } catch (error) {
    const originalMessage = error instanceof Error ? error.message : String(error);
    if (!brokerCurrent) {
      throw new Error(
        `${originalMessage}\n\nThe root-owned source-access broker does not match this release. ` +
          "Run aidevops setup --scope source-access from an interactive terminal to reconcile it.",
      );
    }
    if (!requestId) throw error;
    const explanation = {
      drift: "The prior approval was invalidated by an unobserved content transition.",
      expired: "The prior approval has expired.",
      invalid: "The prior approval was revoked or its repository/worktree identity is no longer valid.",
      missing: "No source-access approval exists for this exact path and session.",
    }[denialReason] || "No valid source-access approval exists for this exact path and session.";
    throw new Error(
      `${originalMessage}\n\n${explanation}\n\nTo approve only this tracked source path for this session, run:\n` +
        `sudo -k /usr/bin/python3 -I -B ${ROOT_BROKER} approve ${requestId} --ttl 12h\n\n` +
        "For one approval covering several exact tracked paths, create one request with " +
        "`aidevops source-access request --session <session> --reason 'secret-bearing basename' " +
        "--path <path-1> --path <path-2> ...`, then approve the returned request ID.",
    );
  }
}
