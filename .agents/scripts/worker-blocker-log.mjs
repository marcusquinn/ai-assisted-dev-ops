#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  closeSync,
  constants,
  existsSync,
  fchmodSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

import {
  acquireWorkerBlockerLock as acquireLock,
  releaseWorkerBlockerLock as releaseLock,
} from "./worker-blocker-lock.mjs";

export const WORKER_BLOCKER_SCHEMA = "aidevops-worker-blocker/v1";
export const DEFAULT_WORKER_BLOCKER_LOG_MAX_BYTES = 5 * 1024 * 1024;

const MIN_LOG_MAX_BYTES = 512;
const MAX_DETAIL_LENGTH = 500;
const MAX_FIELD_LENGTH = 200;
const CREDENTIAL_PATTERN = /(^|[^A-Za-z0-9_-])(sk-|GOCSPX-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;

function cleanText(value, maxLength, options = {}) {
  if (value === null || value === undefined) return "";
  const home = options.home || homedir();
  const workDir = options.workDir || process.env.WORKER_WORKTREE_PATH || "";
  let text = String(value)
    .replace(CREDENTIAL_PATTERN, "$1[redacted-credential]")
    .replace(/(authorization\s*:\s*bearer\s+)[^\s,;]+/gi, "$1[REDACTED]")
    .replace(/((?:api[_-]?key|token|secret|password|authorization|credential)\s*[:=]\s*)[^\s,;]+/gi, "$1[REDACTED]")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .trim();
  if (home && text.includes(home)) text = text.split(home).join("~");
  if (workDir && text.includes(workDir)) text = text.split(workDir).join("$WORKTREE");
  return text.slice(0, maxLength);
}

export function cleanWorkerBlockerIssueNumber(value) {
  const text = String(value ?? "");
  if (!/^[0-9]+$/.test(text)) return null;
  const parsed = Number(text);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

export function normalizeWorkerBlockerRepoSlug(value, options = {}) {
  return cleanText(value || "", MAX_FIELD_LENGTH, options).toLowerCase();
}

export function normalizeWorkerBlockerSessionKey(value, options = {}) {
  return cleanText(value || "", MAX_FIELD_LENGTH, options);
}

export function normalizeWorkerBlockerRequestId(value, options = {}) {
  return cleanText(value || "", MAX_FIELD_LENGTH, options);
}

export function resolveWorkerBlockerLogPath(options = {}) {
  return options.logPath
    || process.env.AIDEVOPS_WORKER_BLOCKER_LOG_FILE
    || resolve(homedir(), ".aidevops", "logs", "worker-progress-blockers.jsonl");
}

export function resolveWorkerBlockerMaxBytes(options = {}) {
  const raw = options.maxBytes ?? process.env.AIDEVOPS_WORKER_BLOCKER_LOG_MAX_BYTES;
  const parsed = Number(raw || DEFAULT_WORKER_BLOCKER_LOG_MAX_BYTES);
  if (!Number.isSafeInteger(parsed) || parsed < MIN_LOG_MAX_BYTES) {
    return DEFAULT_WORKER_BLOCKER_LOG_MAX_BYTES;
  }
  return parsed;
}

export function normalizeWorkerBlockerEvent(input = {}, options = {}) {
  const now = options.now instanceof Date ? options.now : new Date();
  const issueValue = Object.hasOwn(input, "issue_number")
    ? input.issue_number
    : process.env.WORKER_ISSUE_NUMBER;
  const issueNumber = cleanWorkerBlockerIssueNumber(issueValue);
  const grantable = typeof input.grantable === "boolean" ? input.grantable : null;
  return {
    schema: WORKER_BLOCKER_SCHEMA,
    ts: Math.floor(now.getTime() / 1000),
    timestamp: now.toISOString(),
    event: cleanText(input.event || "worker_progress_blocked", MAX_FIELD_LENGTH, options),
    status: cleanText(input.status || "blocked", 50, options),
    reason: cleanText(input.reason || "unknown", MAX_FIELD_LENGTH, options),
    blocking: input.blocking !== false,
    source: cleanText(input.source || "unknown", MAX_FIELD_LENGTH, options),
    issue_number: issueNumber,
    repo_slug: normalizeWorkerBlockerRepoSlug(input.repo_slug || process.env.WORKER_REPO_SLUG || process.env.DISPATCH_REPO_SLUG || "", options),
    session_key: normalizeWorkerBlockerSessionKey(input.session_key || process.env.WORKER_SESSION_KEY || "", options),
    request_id: normalizeWorkerBlockerRequestId(input.request_id || process.env.AIDEVOPS_PERMISSION_REQUEST_ID || "", options),
    permission: cleanText(input.permission || "", 100, options),
    tool: cleanText(input.tool || "", 100, options),
    risk_level: cleanText(input.risk_level || "", 20, options),
    grantable,
    detail: cleanText(input.detail || "", MAX_DETAIL_LENGTH, options),
  };
}

function newestCompleteLinesWithinBudget(content, budget) {
  if (budget <= 0) return "";
  const lines = content.toString("utf8").split("\n").filter(Boolean);
  const kept = [];
  let bytes = 0;
  for (let index = lines.length - 1; index >= 0; index--) {
    const line = `${lines[index]}\n`;
    const lineBytes = Buffer.byteLength(line);
    if (lineBytes > budget - bytes) break;
    kept.push(line);
    bytes += lineBytes;
  }
  return kept.reverse().join("");
}

function trimBeforeAppend(logPath, incomingBytes, maxBytes) {
  if (!existsSync(logPath)) return;
  if (lstatSync(logPath).isSymbolicLink()) throw new Error("Refusing symlinked blocker log");
  const currentSize = statSync(logPath).size;
  if (currentSize + incomingBytes <= maxBytes) return;
  const retained = newestCompleteLinesWithinBudget(readFileSync(logPath), maxBytes - incomingBytes);
  const temporary = `${logPath}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(temporary, retained, { mode: 0o600 });
  renameSync(temporary, logPath);
}

export function appendNormalizedWorkerBlockerEventsUnlocked(logPath, inputs, options, maxBytes) {
  const content = inputs
    .map((input) => `${JSON.stringify(normalizeWorkerBlockerEvent(input, options))}\n`)
    .join("");
  const incomingBytes = Buffer.byteLength(content);
  if (!content || incomingBytes > maxBytes) return false;
  trimBeforeAppend(logPath, incomingBytes, maxBytes);
  const descriptor = openSync(logPath, constants.O_APPEND | constants.O_CREAT | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
  try {
    writeFileSync(descriptor, content);
    fchmodSync(descriptor, 0o600);
  } finally {
    closeSync(descriptor);
  }
  return true;
}

export function appendWorkerBlockerEvent(input, options = {}) {
  let lockPath = "";
  let lockToken = "";
  try {
    const logPath = resolveWorkerBlockerLogPath(options);
    const maxBytes = resolveWorkerBlockerMaxBytes(options);
    mkdirSync(dirname(logPath), { recursive: true, mode: 0o700 });
    if (existsSync(logPath) && lstatSync(logPath).isSymbolicLink()) return false;
    lockPath = `${logPath}.lock`;
    lockToken = acquireLock(lockPath);
    if (!lockToken) return false;
    return appendNormalizedWorkerBlockerEventsUnlocked(logPath, [input], options, maxBytes);
  } catch {
    return false;
  } finally {
    if (lockToken) {
      try {
        releaseLock(lockPath, lockToken);
      } catch {
        // Logging remains best effort and must never stop worker execution.
      }
    }
  }
}

async function main() {
  const { runWorkerBlockerCli } = await import("./worker-blocker-cli.mjs");
  return runWorkerBlockerCli(process.argv.slice(2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main()
    .then((exitCode) => { process.exitCode = exitCode; })
    .catch(() => { process.exitCode = 1; });
}
