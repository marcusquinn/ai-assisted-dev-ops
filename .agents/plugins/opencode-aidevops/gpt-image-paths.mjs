// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { lstat, realpath } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

export function pathIsWithin(parent, candidate) {
  const relation = relative(parent, candidate);
  return relation === "" || (relation !== ".." && !relation.startsWith(`..${sep}`) && !isAbsolute(relation));
}

export function requireRelativePath(value, label) {
  const requested = String(value || "").trim();
  if (!requested || isAbsolute(requested) || requested.split(/[\\/]+/).includes("..")) {
    throw new Error(`${label} must be a project-relative path without parent traversal.`);
  }
  return requested;
}

export async function requireProjectRoot(projectRoot) {
  try {
    const requestedRoot = resolve(projectRoot);
    const requestedStats = await lstat(requestedRoot);
    if (!requestedStats.isDirectory() || requestedStats.isSymbolicLink()) throw new Error("unsafe root");
    const root = await realpath(requestedRoot);
    const stats = await lstat(root);
    if (!stats.isDirectory() || stats.isSymbolicLink()) throw new Error("unsafe root");
    return root;
  } catch {
    throw new Error("OpenCode project root is unavailable or unsafe.");
  }
}

export async function assertNoSymlinkSegments(root, target) {
  const relation = relative(root, target);
  let cursor = root;
  for (const segment of relation.split(sep).filter(Boolean)) {
    cursor = join(cursor, segment);
    try {
      const stats = await lstat(cursor);
      if (stats.isSymbolicLink()) throw new Error("Image paths cannot traverse symbolic links.");
    } catch (error) {
      if (error?.code === "ENOENT") return;
      if (error?.message === "Image paths cannot traverse symbolic links.") throw error;
      throw new Error("Image path is unavailable or unsafe.");
    }
  }
}
