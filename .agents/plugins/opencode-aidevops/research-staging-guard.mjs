// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, lstatSync, readdirSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

const RESEARCH_STAGING_DIRECTORY = "research-staging";
const MAX_STAGED_ENTRIES = 10_000;
const STAGING_TOOLS = new Set(["read", "grep", "glob"]);
const CREDENTIAL_NAME = /^(?:\.env(?:\..*)?|\.ssh|\.gnupg|\.aws|\.azure|\.kube|\.netrc|\.npmrc|\.pypirc|\.git-credentials|auth\.json|credentials?.*)$/i;

function isPathWithin(base, candidate) {
  const remainder = relative(base, candidate);
  return remainder === ""
    || (!isAbsolute(remainder) && remainder !== ".." && !remainder.startsWith(`..${sep}`));
}

function toolPath(tool, args) {
  if (!STAGING_TOOLS.has(tool)) return "";
  return args.filePath || args.file_path || args.path || "";
}

function validatedChildDirectory(directory, entry, stagingRoot) {
  if (CREDENTIAL_NAME.test(entry.name)) throw new Error("Research staging contains a credential-like path");

  const child = join(directory, entry.name);
  if (entry.isSymbolicLink()) throw new Error("Research staging symlinks are denied");
  if (!isPathWithin(stagingRoot, realpathSync(child))) {
    throw new Error("Research staging path resolves outside the staging root");
  }
  return entry.isDirectory() ? child : "";
}

function validateTree(root, stagingRoot) {
  const queue = [root];
  let entries = 0;
  while (queue.length > 0) {
    const directory = queue.pop();
    const children = readdirSync(directory, { withFileTypes: true });
    entries += children.length;
    if (entries > MAX_STAGED_ENTRIES) throw new Error("Research staging tree exceeds the safe entry limit");

    for (const entry of children) {
      const childDirectory = validatedChildDirectory(directory, entry, stagingRoot);
      if (childDirectory) queue.push(childDirectory);
    }
  }
}

export function checkResearchStagingAccess(tool, args, env = process.env) {
  const requested = toolPath(tool, args);
  if (!requested || !isAbsolute(requested)) return;

  const tempRoot = resolve(
    env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp"),
  );
  const stagingRoot = join(tempRoot, RESEARCH_STAGING_DIRECTORY);
  const candidate = resolve(requested);
  if (!isPathWithin(stagingRoot, candidate)) return;
  if (!existsSync(stagingRoot) || !existsSync(candidate)) return;

  const resolvedRoot = realpathSync(stagingRoot);
  const resolvedCandidate = realpathSync(candidate);
  const resolvedTempRoot = realpathSync(tempRoot);
  if (!isPathWithin(resolvedTempRoot, resolvedRoot) || !isPathWithin(resolvedRoot, resolvedCandidate)) {
    throw new Error("Research staging path resolves outside the managed staging root");
  }
  if (lstatSync(candidate).isSymbolicLink()) throw new Error("Research staging symlinks are denied");
  for (const part of relative(resolvedRoot, resolvedCandidate).split(sep)) {
    if (CREDENTIAL_NAME.test(part)) throw new Error("Research staging blocks credential-like paths");
  }

  if ((tool === "grep" || tool === "glob") && lstatSync(candidate).isDirectory()) {
    validateTree(candidate, resolvedRoot);
  }
}
