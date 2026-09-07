// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";
import { lstatSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { SOURCE_CONTEXT_REPLY, sourceContextInstanceId } from "./source-access-context.mjs";
import { sourceAccessGit } from "./source-access-git.mjs";

export const BOUND_RECEIPT_SCHEMA = "aidevops-source-access-receipt/v3";
export const BOUND_PAYLOAD_SCHEMA = "aidevops-source-access-approval/v3";
const CONTEXT_FIELDS = ["session_id", "repo_root", "runtime_pid", "uid",
  "runtime_instance_id", "session_created_at", "project_id"];

function validateRuntimeBinding(payload, context) {
  const check = context.requireValidReceipt;
  const current = context.sourceContext;
  const recorded = payload.proposal?.runtime_context;
  check(current?.schema === SOURCE_CONTEXT_REPLY && current.authority === "none");
  // Never accept environment/tool-argument identity as the consuming runtime.
  check(current.runtime_instance_id === sourceContextInstanceId && current.runtime_pid === process.pid);
  check(current.uid === process.getuid() && current.uid === context.uid);
  check(current.session_id === context.sessionId && current.repo_root === context.requestedIdentity.repoRoot);
  check(Number.isSafeInteger(current.session_created_at) && current.session_created_at >= 0);
  check(typeof current.project_id === "string" && current.project_id.length > 0 && current.project_id.length <= 256);
  check(recorded && CONTEXT_FIELDS.every((key) => recorded[key] === current[key]));
}

function checkIdentity(path, expected, check, directory = false) {
  const metadata = lstatSync(path);
  check(!metadata.isSymbolicLink() && (directory ? metadata.isDirectory() : metadata.isFile()));
  if (!directory) check(metadata.nlink === 1);
  check(expected?.device === metadata.dev && expected?.inode === metadata.ino);
}

function validateRepositoryBinding(repository, context) {
  const check = context.requireValidReceipt;
  const root = context.requestedIdentity.repoRoot;
  check(repository?.root === root && typeof repository.head === "string" && /^[a-f0-9]{40,64}$/.test(repository.head));
  checkIdentity(root, repository.root_identity, check, true);
  const options = { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 3000 };
  for (const [argument, field, identity] of [["--absolute-git-dir", "git_dir", "git_identity"],
    ["--git-common-dir", "common_dir", "common_identity"]]) {
    const path = realpathSync(resolve(root, String(sourceAccessGit(context.git,
      ["-C", root, "rev-parse", argument], options, context.gitRun)).trim()));
    check(path === repository[field] && !context.hasSymlinkComponent(path));
    checkIdentity(path, repository[identity], check, true);
  }
  check(repository.git_dir !== repository.common_dir);
  // HEAD is approval-time evidence. Observed direct edits and their commits may
  // advance it; inode, exact file bytes/provenance and live owner checks remain.
}

/** Validate V3 additions before the unchanged snapshot/signature checks run. */
export function boundManifestIdentity(payload, context) {
  const check = context.requireValidReceipt;
  validateRuntimeBinding(payload, context);
  const proposal = payload.proposal;
  check(proposal.uid === payload.uid && proposal.session_id === payload.session_id);
  check(proposal.reason === payload.reason);
  check(typeof proposal.nonce === "string" && /^[a-f0-9]{32}$/.test(proposal.nonce));
  check(Number.isSafeInteger(proposal.created_at) && proposal.created_at >= 0
    && proposal.created_at <= payload.issued_at);
  check(typeof proposal.issue_snapshot_sha256 === "string" && /^[a-f0-9]{64}$/.test(proposal.issue_snapshot_sha256));
  check(payload.issue_snapshot_sha256 === proposal.issue_snapshot_sha256);
  validateRepositoryBinding(proposal.repository, context);
  check(Array.isArray(proposal.entries) && proposal.entries.length === payload.entries.length);
  for (const [index, entry] of payload.entries.entries()) {
    const proposed = proposal.entries[index];
    check(proposed?.path === entry.path && proposed.relative_path === entry.relative_path
      && proposed.content_sha256 === entry.content_sha256);
    if (!context.authorizedApprovalId) checkIdentity(entry.path, proposed.identity, check);
  }
  const id = createHash("sha256").update(context.canonicalReceiptPayload(proposal)).digest("hex");
  check(payload.proposal_id === id);
  return id;
}
