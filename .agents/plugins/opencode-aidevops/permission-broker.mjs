// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { homedir } from "os";
import { appendWorkerBlockerEvent } from "../../scripts/worker-blocker-log.mjs";
import { isManagedToolOutputRead } from "./permission-broker-tool-output.mjs";

const REQUEST_SCHEMA = "aidevops-permission-capture/v1";
const MAX_PATTERN_LENGTH = 500;
const MAX_INTENT_LENGTH = 500;
const MAX_REQUESTS = 20;
const PATTERN_CAPABLE_PERMISSIONS = new Set(["bash", "external_directory"]);
const FORBIDDEN_PATTERN = /(?:approval-keys\/private|\/(?:\.ssh|\.gnupg|\.aws|\.azure|\.kube)(?:\/|$)|\/(?:\.config\/(?:gh|gcloud|glab-cli|hub)|\.docker)(?:\/|$)|\/(?:\.netrc|\.npmrc|\.pypirc|\.git-credentials)(?:$|\*)|auth\.json(?:$|\*)|credentials?(?:\.|\/|$)|(?:^|\/)\.env(?:\.|$|\/))/i;
const HIGH_RISK_PATTERN = /(?:\.config\/opencode|node_modules\/@opencode-ai\/plugin|(?:^|\/)\.git(?:\/|$))/i;

function redactSecrets(value) {
  return value
    .replace(/((?:api[_-]?key|token|secret|password|authorization)\s*[:=]\s*)[^\s,;]+/gi, "$1[REDACTED]")
    .replace(/\b(?:sk|ghp|github_pat|sntryu)_[A-Za-z0-9_-]{12,}\b/g, "[REDACTED]");
}

export function sanitizePermissionText(value, options = {}) {
  if (typeof value !== "string") return "";
  const home = options.home || homedir();
  const workDir = options.workDir || process.env.WORKER_WORKTREE_PATH || "";
  let sanitized = value.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  sanitized = redactSecrets(sanitized);
  sanitized = sanitized.replace(/~~~/g, "~ ~ ~");
  if (home && sanitized.includes(home)) sanitized = sanitized.split(home).join("~");
  if (workDir && sanitized.includes(workDir)) sanitized = sanitized.split(workDir).join("$WORKTREE");
  return sanitized.slice(0, options.maxLength || MAX_PATTERN_LENGTH);
}

function classifyRisk(permission, patterns, tool) {
  const combined = patterns.join("\n");
  let risk;
  if (!PATTERN_CAPABLE_PERMISSIONS.has(permission)) {
    risk = { level: "critical", grantable: false, reason: "permission cannot be represented as an exact OpenCode pattern rule" };
  } else if (patterns.length === 0) {
    risk = { level: "critical", grantable: false, reason: "request omitted an exact permission pattern" };
  } else if (patterns.some((pattern) => FORBIDDEN_PATTERN.test(pattern))) {
    risk = { level: "critical", grantable: false, reason: "sensitive credential or signing-key location" };
  } else if (["bash", "edit", "write"].includes(tool) || ["bash", "edit"].includes(permission)) {
    risk = { level: "high", grantable: true, reason: "capability can modify or execute content" };
  } else if (HIGH_RISK_PATTERN.test(combined)) {
    risk = { level: "high", grantable: true, reason: "shared runtime or OpenCode configuration path" };
  } else if (permission === "external_directory") {
    risk = { level: "medium", grantable: true, reason: "access crosses the worker project boundary" };
  } else {
    risk = { level: "low", grantable: true, reason: "bounded non-destructive capability" };
  }
  return risk;
}

function stableRequestID(request) {
  const canonical = JSON.stringify({
    issue: request.issue,
    repo: request.repo,
    permission: request.permission,
    patterns: [...request.patterns].sort(),
    tool: request.tool,
    intent: request.intent,
  });
  return `perm-${createHash("sha256").update(canonical).digest("hex").slice(0, 16)}`;
}

function readCaptureFile(path) {
  if (!path || !existsSync(path)) return null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return parsed?.schema === REQUEST_SCHEMA ? parsed : null;
  } catch {
    return null;
  }
}

function writeCaptureFile(path, capture) {
  let written = false;
  if (path) {
    const temporary = `${path}.${process.pid}.tmp`;
    try {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(temporary, `${JSON.stringify(capture, null, 2)}\n`, { mode: 0o600 });
      renameSync(temporary, path);
      written = true;
    } catch {
      try {
        rmSync(temporary, { force: true });
      } catch {
        // Capturing is best effort and must not crash the runtime.
      }
    }
  }
  return written;
}

function normalizePatterns(input, options) {
  const source = Array.isArray(input) ? input : input == null ? [] : [input];
  return [...new Set(source
    .map((value) => sanitizePermissionText(String(value), options))
    .filter(Boolean))].slice(0, 20);
}

function recordPermissionToolCall(toolCalls, isHeadless, home, input, output) {
  if (!isHeadless()) return;
  const callID = input?.callID || input?.callId;
  if (!callID) return;
  const args = output?.args || input?.args || {};
  toolCalls.set(callID, {
    tool: sanitizePermissionText(input?.tool || input?.name || "unknown", { home, maxLength: 100 }),
    intent: sanitizePermissionText(args?.agent__intent || "", { home, maxLength: MAX_INTENT_LENGTH }),
  });
  while (toolCalls.size > 100) toolCalls.delete(toolCalls.keys().next().value);
}

function recordPermissionBlocker({ loggedEvents, home, blockerLogPath, capture, request, event, reason, detail }) {
  const dedupeKey = `${event}:${request?.request_id || "unknown"}`;
  if (loggedEvents.has(dedupeKey)) return;
  loggedEvents.add(dedupeKey);
  while (loggedEvents.size > 100) loggedEvents.delete(loggedEvents.values().next().value);
  appendWorkerBlockerEvent({
    event,
    status: "blocked",
    reason,
    blocking: true,
    source: "opencode-permission-broker",
    issue_number: capture?.issue || process.env.WORKER_ISSUE_NUMBER || "",
    repo_slug: capture?.repo || process.env.WORKER_REPO_SLUG || process.env.DISPATCH_REPO_SLUG || "",
    session_key: capture?.worker_session || process.env.WORKER_SESSION_KEY || "",
    request_id: request?.request_id || "",
    permission: request?.permission || "",
    tool: request?.tool || "",
    risk_level: request?.risk?.level || "",
    grantable: request?.risk?.grantable,
    detail,
  }, { home, logPath: blockerLogPath });
}

function capturePermissionRequest(toolCalls, loggedEvents, home, blockerLogPath, raw) {
  const requestFile = process.env.AIDEVOPS_PERMISSION_REQUEST_FILE || "";
  const callID = raw?.tool?.callID || raw?.callID || "";
  const toolContext = toolCalls.get(callID) || {};
  const options = { home, workDir: process.env.WORKER_WORKTREE_PATH || "" };
  const permission = sanitizePermissionText(raw?.permission || raw?.type || "unknown", { ...options, maxLength: 100 });
  const patterns = normalizePatterns(raw?.patterns ?? raw?.pattern, options);
  const tool = sanitizePermissionText(toolContext.tool || raw?.metadata?.tool || permission, { ...options, maxLength: 100 });
  const request = {
    request_id: "",
    permission,
    patterns,
    tool,
    intent: sanitizePermissionText(toolContext.intent || raw?.metadata?.description || raw?.title || "", { ...options, maxLength: MAX_INTENT_LENGTH }),
    risk: classifyRisk(permission, patterns, tool),
    opencode: {
      request_id: sanitizePermissionText(raw?.id || "", { ...options, maxLength: 100 }),
      session_id: sanitizePermissionText(raw?.sessionID || "", { ...options, maxLength: 100 }),
      message_id: sanitizePermissionText(raw?.tool?.messageID || raw?.messageID || "", { ...options, maxLength: 100 }),
      call_id: sanitizePermissionText(callID, { ...options, maxLength: 100 }),
    },
    captured_at: new Date().toISOString(),
  };
  const capture = readCaptureFile(requestFile) || {
    schema: REQUEST_SCHEMA,
    issue: sanitizePermissionText(process.env.WORKER_ISSUE_NUMBER || "", { ...options, maxLength: 30 }),
    repo: sanitizePermissionText(process.env.WORKER_REPO_SLUG || process.env.DISPATCH_REPO_SLUG || "", { ...options, maxLength: 200 }),
    worker_session: sanitizePermissionText(process.env.WORKER_SESSION_KEY || "", { ...options, maxLength: 200 }),
    requests: [],
  };
  request.request_id = stableRequestID({ ...request, issue: capture.issue, repo: capture.repo });
  if (!requestFile) {
    recordPermissionBlocker({
      loggedEvents, home, blockerLogPath, capture, request, event: "permission_capture_failed",
      reason: "request_file_unset", detail: "Headless permission request capture path was unavailable",
    });
    return request;
  }
  const existingIndex = capture.requests.findIndex((item) => item.request_id === request.request_id);
  if (existingIndex >= 0) capture.requests[existingIndex] = request;
  else capture.requests.push(request);
  capture.requests = capture.requests.slice(-MAX_REQUESTS);
  const written = writeCaptureFile(requestFile, capture);
  if (!written) {
    recordPermissionBlocker({
      loggedEvents, home, blockerLogPath, capture, request, event: "permission_capture_failed",
      reason: "capture_file_write_failed", detail: "Permission request could not be persisted",
    });
  } else if (request.risk.grantable) {
    recordPermissionBlocker({
      loggedEvents, home, blockerLogPath, capture, request, event: "permission_request_captured",
      reason: "permission_required", detail: request.risk.reason,
    });
  } else {
    recordPermissionBlocker({
      loggedEvents, home, blockerLogPath, capture, request, event: "permission_request_non_grantable",
      reason: "permission_non_grantable", detail: request.risk.reason,
    });
  }
  return request;
}

async function replyPermissionRequest(client, request, response) {
  if (!request?.id || !request?.sessionID || !client?.postSessionIdPermissionsPermissionId) return false;
  try {
    const result = await client.postSessionIdPermissionsPermissionId({
      path: { id: request.sessionID, permissionID: request.id },
      body: { response },
      throwOnError: true,
    });
    return !result?.error && (!result?.response || result.response.ok !== false);
  } catch {
    return false;
  }
}

async function handlePermissionEvent(context, input) {
  const { client, isHeadless, toolCalls, loggedEvents, home, dataHome, blockerLogPath } = context;
  const event = input?.event;
  if (!isHeadless() || event?.type !== "permission.asked") return;
  const request = event.properties || {};
  if (isManagedToolOutputRead(toolCalls, request, dataHome)
    && await replyPermissionRequest(client, request, "once")) return;
  capturePermissionRequest(toolCalls, loggedEvents, home, blockerLogPath, request);
  await replyPermissionRequest(client, request, "reject");
}

function handlePermissionAsk(context, input, output) {
  const { isHeadless, toolCalls, loggedEvents, home, dataHome, blockerLogPath } = context;
  if (!isHeadless()) return;
  if (isManagedToolOutputRead(toolCalls, input, dataHome)) {
    output.status = "allow";
    return;
  }
  capturePermissionRequest(toolCalls, loggedEvents, home, blockerLogPath, input || {});
  output.status = "deny";
}

export function createPermissionBroker({
  client,
  isHeadless,
  home = homedir(),
  dataHome = process.env.XDG_DATA_HOME || "",
  blockerLogPath = undefined,
}) {
  const toolCalls = new Map();
  const loggedEvents = new Set();
  const context = {
    client,
    isHeadless,
    toolCalls,
    loggedEvents,
    home,
    dataHome: dataHome || join(home, ".local", "share"),
    blockerLogPath,
  };
  return {
    recordToolCall: (input, output) => recordPermissionToolCall(toolCalls, isHeadless, home, input, output),
    handleEvent: (input) => handlePermissionEvent(context, input),
    permissionAsk: (input, output) => handlePermissionAsk(context, input, output),
  };
}
