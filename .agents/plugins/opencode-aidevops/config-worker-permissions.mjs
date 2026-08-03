// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Signed, narrowly scoped worker permission grants used by the config hook.

import { execFileSync } from "child_process";
import { createHash } from "crypto";
import { appendWorkerBlockerEvent } from "../../scripts/worker-blocker-log.mjs";
import { verifyPermissionGrant } from "./worker-permission-grant-verification.mjs";

const PATTERN_CAPABLE_PERMISSIONS = new Set(["bash", "external_directory"]);
const FORBIDDEN_GRANT_PATTERN = /(?:approval-keys\/private|\/(?:\.ssh|\.gnupg|\.aws|\.azure|\.kube)(?:\/|$)|\/(?:\.config\/(?:gh|gcloud|glab-cli|hub)|\.docker)(?:\/|$)|\/(?:\.netrc|\.npmrc|\.pypirc|\.git-credentials)(?:$|\*)|auth\.json(?:$|\*)|credentials?(?:\.|\/|$)|(?:^|\/)\.env(?:\.|$|\/))/i;
const UNBOUNDED_GRANT_PATTERN = /^(?:\*|\*\*|\/\*\*|~\/\*\*|\$WORKTREE\/\*\*)$/;
const MAX_PERMISSION_GRANT_MS = 4 * 60 * 60 * 1000;

function ensurePermissionMap(target) {
  if (typeof target.permission === "string") {
    const fallback = target.permission;
    target.permission = { "*": fallback, external_directory: { "*": fallback } };
  } else if (!target.permission) {
    target.permission = {};
  }
}

function addApprovedCapabilityRule(target, capability) {
  const permission = capability.permission;
  const patterns = Array.isArray(capability.patterns) ? capability.patterns : [];
  if (!PATTERN_CAPABLE_PERMISSIONS.has(permission) || patterns.length === 0) return 0;
  const existing = target.permission[permission];
  if (existing === "allow") return 0;
  const rules = typeof existing === "string" ? { "*": existing } : { ...existing };
  let count = 0;
  for (const pattern of patterns) {
    if (typeof pattern !== "string" || pattern.length === 0 || pattern.length > 500) continue;
    delete rules[pattern];
    rules[pattern] = "allow";
    count++;
  }
  target.permission[permission] = rules;
  return count;
}

function addApprovedCapabilityRules(target, capabilities) {
  ensurePermissionMap(target);
  let count = 0;
  for (const capability of capabilities) {
    count += addApprovedCapabilityRule(target, capability);
  }
  return count;
}

function permissionGrantTargetMatches(grant) {
  if (grant?.schema !== "aidevops-permission-grant/v1") return false;
  if (grant.authority !== "worker-permissions") return false;
  const issue = String(process.env.WORKER_ISSUE_NUMBER || "");
  const repo = String(process.env.WORKER_REPO_SLUG || process.env.DISPATCH_REPO_SLUG || "").toLowerCase();
  if (String(grant.target?.number || "") !== issue) return false;
  return String(grant.target?.repository || "").toLowerCase() === repo;
}

function permissionGrantTimeReason(grant) {
  const issued = Date.parse(grant.issued_at || "");
  const expires = Date.parse(grant.expires_at || "");
  const now = Date.now();
  const rejection = [
    [!Number.isFinite(issued) || !Number.isFinite(expires), "grant_time_invalid"],
    [expires <= now, "grant_expired"],
    [issued > now + 5 * 60 * 1000, "grant_issued_in_future"],
    [expires <= issued, "grant_time_invalid"],
    [expires - issued > MAX_PERMISSION_GRANT_MS, "grant_duration_excessive"],
  ].find(([rejected]) => rejected);
  return rejection?.[1] || "";
}

function permissionGrantRequestValid(grant) {
  if (!/^perm-[0-9a-f]{16}$/.test(grant.request_id || "")) return false;
  return /^[0-9a-f]{64}$/.test(grant.request_sha256 || "");
}

function currentWorkerBranch(options, repositoryDir) {
  if (options.currentBranch !== undefined) return options.currentBranch;
  try {
    return execFileSync("git", ["-C", repositoryDir, "branch", "--show-current"], { encoding: "utf8" }).trim();
  } catch {
    return null;
  }
}

function permissionGrantBranchMatches(grantBranch, currentBranch) {
  if (typeof currentBranch !== "string" || currentBranch.length === 0) return false;
  if (typeof grantBranch !== "string" || grantBranch.length === 0) return false;
  return grantBranch === currentBranch;
}

function firstPermissionGrantReason(checks) {
  for (const check of checks) {
    const reason = check();
    if (reason) return reason;
  }
  return "";
}

function permissionGrantWorkerMismatchReason(grant, options) {
  const pendingRequest = String(options.pendingRequest || process.env.AIDEVOPS_PERMISSION_REQUEST_ID || "");
  const repositoryDir = String(options.repositoryDir || "");
  const currentSession = String(options.currentSession || process.env.WORKER_SESSION_KEY || "");
  return firstPermissionGrantReason([
    () => (!pendingRequest || grant.request_id !== pendingRequest) ? "grant_request_mismatch" : "",
    () => !repositoryDir ? "grant_worktree_unavailable" : "",
    () => grant.worker?.worktree_sha256 !== createHash("sha256").update(repositoryDir).digest("hex")
      ? "grant_worktree_mismatch" : "",
    () => (!currentSession || grant.worker?.session !== currentSession) ? "grant_session_mismatch" : "",
    () => permissionGrantBranchMatches(grant.worker?.branch, currentWorkerBranch(options, repositoryDir))
      ? "" : "grant_branch_mismatch",
  ]);
}

function permissionGrantPatternSafe(pattern) {
  if (typeof pattern !== "string") return false;
  if (pattern.length === 0 || pattern.length > 500) return false;
  if (FORBIDDEN_GRANT_PATTERN.test(pattern)) return false;
  return !UNBOUNDED_GRANT_PATTERN.test(pattern);
}

function permissionGrantCapabilitySafe(item) {
  if (item?.risk?.grantable !== true) return false;
  if (!PATTERN_CAPABLE_PERMISSIONS.has(item?.permission || "")) return false;
  if (!Array.isArray(item.patterns)) return false;
  if (item.patterns.length === 0 || item.patterns.length > 20) return false;
  return item.patterns.every(permissionGrantPatternSafe);
}

function permissionGrantCapabilitiesSafe(grant) {
  if (!Array.isArray(grant.capabilities)) return false;
  if (grant.capabilities.length === 0 || grant.capabilities.length > 20) return false;
  return grant.capabilities.every(permissionGrantCapabilitySafe);
}

function permissionGrantRejectionReason(grant, options) {
  return firstPermissionGrantReason([
    () => permissionGrantTargetMatches(grant) ? "" : "grant_target_mismatch",
    () => permissionGrantTimeReason(grant),
    () => permissionGrantRequestValid(grant) ? "" : "grant_request_invalid",
    () => permissionGrantWorkerMismatchReason(grant, options),
    () => permissionGrantCapabilitiesSafe(grant) ? "" : "grant_capabilities_unsafe",
  ]);
}

function recordPermissionGrantEvent({ options, grant, event, status, reason, blocking }) {
  appendWorkerBlockerEvent({
    event,
    status,
    reason,
    blocking,
    source: "opencode-config-hook",
    request_id: options.pendingRequest || process.env.AIDEVOPS_PERMISSION_REQUEST_ID || grant?.request_id || "",
    session_key: options.currentSession || process.env.WORKER_SESSION_KEY || grant?.worker?.session || "",
    detail: blocking ? "Worker permission grant was unavailable or rejected" : "Scoped worker permission grant applied",
  }, { logPath: options.blockerLogPath });
}

export function registerApprovedWorkerPermissions(config, options = {}) {
  const grantPath = options.grantPath || process.env.AIDEVOPS_PERMISSION_GRANT_FILE || "";
  const pendingRequest = String(options.pendingRequest || process.env.AIDEVOPS_PERMISSION_REQUEST_ID || "");
  if (!pendingRequest) return 0;
  const verification = verifyPermissionGrant(grantPath, options);
  if (!verification.grant) {
    const event = verification.reason === "grant_file_missing"
      ? "permission_awaiting_approval"
      : "permission_grant_rejected";
    recordPermissionGrantEvent({
      options: { ...options, pendingRequest }, grant: null, event,
      status: "blocked", reason: verification.reason, blocking: true,
    });
    return 0;
  }
  const grant = verification.grant;
  const rejectionReason = permissionGrantRejectionReason(grant, { ...options, pendingRequest });
  if (rejectionReason) {
    recordPermissionGrantEvent({
      options: { ...options, pendingRequest }, grant, event: "permission_grant_rejected",
      status: "blocked", reason: rejectionReason, blocking: true,
    });
    return 0;
  }
  let count = addApprovedCapabilityRules(config, grant.capabilities);
  for (const agent of Object.values(config.agent || {})) {
    count += addApprovedCapabilityRules(agent, grant.capabilities);
  }
  recordPermissionGrantEvent({
    options: { ...options, pendingRequest }, grant, event: "permission_grant_applied",
    status: "resuming", reason: "scoped_permission_granted", blocking: false,
  });
  return count;
}
