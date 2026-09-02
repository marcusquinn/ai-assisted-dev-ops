// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";

const MANIFEST_RECEIPT_SCHEMA = "aidevops-source-access-receipt/v2";
const MANIFEST_PAYLOAD_SCHEMA = "aidevops-source-access-approval/v2";
const MAX_TTL_SECONDS = 12 * 60 * 60;
const MAX_SOURCE_BYTES = 10 * 1024 * 1024;
const MAX_MANIFEST_ENTRIES = 32;
const DEFAULT_STATE_DIR = "/var/run/aidevops/source-access";
const DEFAULT_PUBLIC_KEY = "/etc/aidevops/source-access/source-access.pub";

function repositoryId(repoRoot) {
  return createHash("sha256").update(repoRoot, "utf8").digest("hex");
}

function manifestScopeId(sessionId, uid, repoRoot, reason, paths) {
  return createHash("sha256")
    .update([sessionId, String(uid), repoRoot, reason, ...paths].join("\0"), "utf8")
    .digest("hex");
}

function normalizedEntries(payload, context) {
  let totalBytes = 0;
  return payload.entries.map((entry) => {
    context.requireValidReceipt(entry && typeof entry === "object");
    context.requireValidReceipt(isAbsolute(entry.path));
    context.requireValidReceipt(!context.hasSymlinkComponent(entry.path));
    const path = realpathSync(entry.path);
    const identity = context.trackedFileIdentity(path, context.git, context.gitRun);
    context.requireValidReceipt(identity);
    context.requireValidReceipt(identity.repoRoot === context.requestedIdentity.repoRoot);
    context.requireValidReceipt(entry.path === path);
    context.requireValidReceipt(entry.relative_path === identity.relativePath);
    context.requireValidReceipt(/^[a-f0-9]{64}$/.test(entry.content_sha256 || ""));
    totalBytes += statSync(path).size;
    context.requireValidReceipt(totalBytes <= MAX_SOURCE_BYTES);
    if (!context.authorizedApprovalId) {
      context.requireValidReceipt(context.sourceDigestMatches(path, entry.content_sha256));
    }
    return { entry, path, relativePath: identity.relativePath };
  });
}

function validateEntryOrder(entries, requireValidReceipt) {
  const sortedRelativePaths = entries.map(({ relativePath }) => relativePath).sort();
  requireValidReceipt(
    entries.every(({ relativePath }, index) => relativePath === sortedRelativePaths[index]),
  );
  const paths = entries.map(({ path }) => path);
  requireValidReceipt(new Set(paths).size === paths.length);
  return paths;
}

function approvedSnapshot(entries, context) {
  let approvedPath = "";
  for (const { entry, path } of entries) {
    const entryId = createHash("sha256").update(path, "utf8").digest("hex").slice(0, 32);
    const snapshotPath = join(
      context.stateDir,
      "snapshots",
      String(context.uid),
      `${context.approvalId}-${entryId}.source`,
    );
    context.requireValidReceipt(entry.snapshot_path === snapshotPath);
    context.requireValidReceipt(context.trustedDirectory(dirname(snapshotPath), context.trustUid));
    context.requireValidReceipt(context.trustedRegularFile(snapshotPath, context.trustUid));
    context.requireValidReceipt(statSync(snapshotPath).size <= MAX_SOURCE_BYTES);
    context.requireValidReceipt(context.fileSha256(snapshotPath) === entry.content_sha256);
    if (path === context.canonicalPath) approvedPath = snapshotPath;
  }
  context.requireValidReceipt(approvedPath);
  return approvedPath;
}

function validateManifestReceipt(receiptName, context) {
  const receiptPath = join(context.approvalsDir, receiptName);
  context.requireValidReceipt(context.trustedRegularFile(receiptPath, context.trustUid));
  const receipt = JSON.parse(readFileSync(receiptPath, "utf8"));
  const payload = receipt?.payload;
  context.requireValidReceipt(receipt?.schema === MANIFEST_RECEIPT_SCHEMA);
  context.requireValidReceipt(payload?.schema === MANIFEST_PAYLOAD_SCHEMA);
  context.requireValidReceipt(payload.session_id === context.sessionId);
  context.requireValidReceipt(payload.uid === context.uid);
  context.requireValidReceipt(payload.reason === context.reason);
  context.requireValidReceipt(
    Array.isArray(payload.entries) &&
      payload.entries.length >= 2 &&
      payload.entries.length <= MAX_MANIFEST_ENTRIES,
  );
  const entries = normalizedEntries(payload, context);
  const paths = validateEntryOrder(entries, context.requireValidReceipt);
  const approvalId = manifestScopeId(
    context.sessionId,
    context.uid,
    context.requestedIdentity.repoRoot,
    context.reason,
    paths,
  );
  if (context.authorizedApprovalId) {
    context.requireValidReceipt(context.authorizedApprovalId === approvalId);
  }
  context.requireValidReceipt(payload.approval_id === approvalId);
  context.requireValidReceipt(payload.request_id === approvalId);
  context.requireValidReceipt(receiptName === `${approvalId}.json`);
  context.requireValidReceipt(payload.repo_root === context.requestedIdentity.repoRoot);
  context.requireValidReceipt(payload.repository_id === repositoryId(context.requestedIdentity.repoRoot));
  const snapshotPath = approvedSnapshot(entries, { ...context, approvalId });
  context.requireValidReceipt(Number.isInteger(payload.issued_at));
  context.requireValidReceipt(Number.isInteger(payload.expires_at));
  context.requireValidReceipt(context.now >= payload.issued_at);
  context.requireValidReceipt(context.now < payload.expires_at);
  context.requireValidReceipt(payload.expires_at - payload.issued_at <= MAX_TTL_SECONDS);
  context.requireValidReceipt(typeof receipt.signature === "string");
  context.requireValidReceipt(receipt.signature.includes("SSH SIGNATURE"));
  const requestedEntry = entries.find(({ path }) => path === context.canonicalPath);
  context.requireValidReceipt(requestedEntry);
  return {
    approvalId,
    canonicalPath: context.canonicalPath,
    contentSha256: requestedEntry.entry.content_sha256,
    expiresAt: payload.expires_at,
    payload,
    publicKeyPath: context.publicKeyPath,
    receipt,
    repoRoot: context.requestedIdentity.repoRoot,
    relativePath: context.requestedIdentity.relativePath,
    run: context.run,
    snapshotPath,
    sshKeygen: context.sshKeygen,
  };
}

export function validatedManifestReceipt(options, dependencies) {
  const {
    sessionId,
    filePath,
    reason,
    repositoryDir = "",
    now = Math.floor(Date.now() / 1000),
    uid = typeof process.getuid === "function" ? process.getuid() : -1,
    trustUid = 0,
    stateDir = DEFAULT_STATE_DIR,
    publicKeyPath = DEFAULT_PUBLIC_KEY,
    sshKeygen = "/usr/bin/ssh-keygen",
    git = "/usr/bin/git",
    gitRun = execFileSync,
    run = execFileSync,
    authorizedApprovalId = "",
  } = options;
  const { requireValidReceipt } = dependencies;
  requireValidReceipt(/^[A-Za-z0-9._:-]{6,256}$/.test(sessionId));
  requireValidReceipt(reason === dependencies.sourceAccessReason);
  requireValidReceipt(uid >= 0);
  requireValidReceipt(isAbsolute(filePath));
  requireValidReceipt(!dependencies.hasSymlinkComponent(filePath));
  const canonicalPath = realpathSync(filePath);
  const requestedIdentity = dependencies.trackedFileIdentity(canonicalPath, git, gitRun);
  requireValidReceipt(requestedIdentity);
  if (repositoryDir) requireValidReceipt(realpathSync(repositoryDir) === requestedIdentity.repoRoot);
  const approvalsDir = join(stateDir, "approvals", String(uid));
  requireValidReceipt(dependencies.trustedDirectory(approvalsDir, trustUid));
  requireValidReceipt(dependencies.trustedDirectory(dirname(publicKeyPath), trustUid));
  requireValidReceipt(dependencies.trustedRegularFile(publicKeyPath, trustUid));
  const context = {
    ...dependencies,
    approvalsDir,
    authorizedApprovalId,
    canonicalPath,
    git,
    gitRun,
    now,
    publicKeyPath,
    reason,
    requestedIdentity,
    run,
    sessionId,
    sshKeygen,
    stateDir,
    trustUid,
    uid,
  };
  for (const receiptName of dependencies.receiptNames(approvalsDir)) {
    try {
      return validateManifestReceipt(receiptName, context);
    } catch {
      // A malformed or unrelated receipt cannot broaden access; try another exact manifest.
    }
  }
  throw new Error("source-access receipt is invalid");
}
