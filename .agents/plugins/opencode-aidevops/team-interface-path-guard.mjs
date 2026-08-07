// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {existsSync, lstatSync, readdirSync, realpathSync} from "node:fs";
import {isAbsolute, join, relative, resolve, sep} from "node:path";

import {secretReadBlockReason} from "./quality-hooks-secret-read.mjs";

const CONVERSATION_PATH_TOOLS = new Set(["glob", "grep", "read"]);
const MAX_SEARCH_ENTRIES = 50_000;
const DEFAULT_IGNORED_DIRECTORIES = new Set([".git", ".venv", "node_modules", "vendor"]);

function normalizedToolName(tool) {
  return String(tool || "").split(".").at(-1).toLowerCase();
}

function isPathWithin(base, candidate) {
  const remainder = relative(base, candidate);
  return remainder === ""
    || (!isAbsolute(remainder) && remainder !== ".." && !remainder.startsWith(`..${sep}`));
}

function requestedPath(tool, args, projectRoot) {
  const supplied = args?.filePath || args?.file_path || args?.path || "";
  if (!supplied && tool === "read") {
    throw new Error("[conversation-path-guard] read requires an explicit project path");
  }
  return resolve(projectRoot, supplied || ".");
}

function rejectCredentialPath(candidate) {
  if (secretReadBlockReason(candidate)) {
    throw new Error("[conversation-path-guard] credential-like paths are denied");
  }
}

function rejectSymlinkTraversal(projectRoot, candidate) {
  const remainder = relative(projectRoot, candidate);
  let current = projectRoot;
  for (const part of remainder.split(sep).filter(Boolean)) {
    current = join(current, part);
    if (!existsSync(current)) break;
    if (lstatSync(current).isSymbolicLink()) {
      throw new Error("[conversation-path-guard] symbolic-link traversal is denied");
    }
  }
}

function rejectSearchSymlink(entry, child, projectRoot) {
  if (!entry.isSymbolicLink()) return;
  const resolvedChild = realpathSync(child);
  if (!isPathWithin(projectRoot, resolvedChild)) {
    throw new Error("[conversation-path-guard] search scope contains an out-of-root symbolic link");
  }
  throw new Error("[conversation-path-guard] search scope contains symbolic-link traversal");
}

function inspectSearchEntry(entry, directory, projectRoot, queue) {
  if (entry.isDirectory() && DEFAULT_IGNORED_DIRECTORIES.has(entry.name)) return;
  const child = join(directory, entry.name);
  rejectCredentialPath(child);
  rejectSearchSymlink(entry, child, projectRoot);
  if (entry.isDirectory()) queue.push(child);
}

function validateSearchTree(candidate, projectRoot) {
  if (!lstatSync(candidate).isDirectory()) return;
  const queue = [candidate];
  let entryCount = 0;
  while (queue.length > 0) {
    const directory = queue.pop();
    const entries = readdirSync(directory, {withFileTypes: true});
    entryCount += entries.length;
    if (entryCount > MAX_SEARCH_ENTRIES) {
      throw new Error("[conversation-path-guard] search scope exceeds the fail-closed entry limit");
    }
    for (const entry of entries) inspectSearchEntry(entry, directory, projectRoot, queue);
  }
}

function validateSearchPattern(tool, args) {
  const pattern = tool === "glob" ? args?.pattern : args?.include;
  if (!pattern) return;
  if (
    typeof pattern !== "string"
    || pattern.startsWith("/")
    || pattern.split(/[\\/]/u).some((part) => part === "..")
    || /[\u0000-\u001f\u007f]/u.test(pattern)
  ) {
    throw new Error("[conversation-path-guard] search pattern escapes the project boundary");
  }
  rejectCredentialPath(pattern);
}

export function enforceConversationPathAccess(toolName, args, conversation) {
  if (!conversation) return 0;
  const tool = normalizedToolName(toolName);
  if (!CONVERSATION_PATH_TOOLS.has(tool)) return 0;

  const projectRoot = realpathSync(conversation.projectRoot);
  const candidate = requestedPath(tool, args, projectRoot);
  if (!isPathWithin(projectRoot, candidate)) {
    throw new Error("[conversation-path-guard] requested path is outside the validated project root");
  }
  rejectCredentialPath(candidate);
  rejectSymlinkTraversal(projectRoot, candidate);
  if (!existsSync(candidate)) {
    throw new Error("[conversation-path-guard] requested path is unavailable");
  }
  const resolvedCandidate = realpathSync(candidate);
  if (!isPathWithin(projectRoot, resolvedCandidate)) {
    throw new Error("[conversation-path-guard] requested path resolves outside the validated project root");
  }
  validateSearchPattern(tool, args || {});
  if (tool === "grep" || tool === "glob") {
    validateSearchTree(candidate, projectRoot);
  }
  return 1;
}
