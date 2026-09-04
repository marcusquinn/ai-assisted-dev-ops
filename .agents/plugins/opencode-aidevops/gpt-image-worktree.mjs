// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFile } from "node:child_process";
import { lstat, realpath } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { promisify } from "node:util";
import { requireProjectRoot } from "./gpt-image-paths.mjs";

const execFileAsync = promisify(execFile);

async function gitPath(root, argument) {
  try {
    const { stdout } = await execFileAsync("git", ["-C", root, "rev-parse", argument], {
      encoding: "utf8",
      timeout: 5_000,
    });
    const value = stdout.trim();
    if (!value) throw new Error("missing Git path");
    return realpath(isAbsolute(value) ? value : resolve(root, value));
  } catch {
    throw new Error("Image workdir must be an existing Git worktree root.");
  }
}

async function gitWorktreeIdentity(root) {
  const topLevel = await gitPath(root, "--show-toplevel");
  if (topLevel !== root) throw new Error("Image workdir must name the Git worktree root.");
  return {
    commonDir: await gitPath(root, "--git-common-dir"),
    gitDir: await gitPath(root, "--git-dir"),
  };
}

async function verifyRegisteredOwnership({ root, sessionID, scriptsDir }) {
  if (!scriptsDir) throw new Error("Image worktree ownership verification is unavailable.");
  try {
    const { stdout } = await execFileAsync(
      join(scriptsDir, "worktree-helper.sh"),
      ["registry", "verify-owner", root, sessionID],
      { encoding: "utf8", timeout: 10_000 },
    );
    if (stdout.trim() !== "VERIFIED") throw new Error("unexpected verification receipt");
  } catch {
    throw new Error("Image workdir is not owned by the current OpenCode session.");
  }
}

export async function resolveGptImageProjectRoot(requestedWorkdir, projectRoot, context, options = {}) {
  const startupRoot = await requireProjectRoot(projectRoot);
  if (requestedWorkdir === undefined) return { root: startupRoot, linked: false };
  if (typeof requestedWorkdir !== "string" || !isAbsolute(requestedWorkdir)) {
    throw new Error("Image workdir must be an absolute linked-worktree path.");
  }

  let requestedStats;
  try {
    requestedStats = await lstat(requestedWorkdir);
  } catch {
    throw new Error("Image workdir is unavailable or unsafe.");
  }
  if (!requestedStats.isDirectory() || requestedStats.isSymbolicLink()) {
    throw new Error("Image workdir is unavailable or unsafe.");
  }
  const root = await requireProjectRoot(requestedWorkdir);
  const sessionID = String(context?.sessionID || "");
  if (!/^ses_[A-Za-z0-9_-]+$/.test(sessionID)) {
    throw new Error("Image workdir requires a current OpenCode session identity.");
  }

  const startupIdentity = await gitWorktreeIdentity(await gitPath(startupRoot, "--show-toplevel"));
  const requestedIdentity = await gitWorktreeIdentity(root);
  if (startupIdentity.commonDir !== requestedIdentity.commonDir) {
    throw new Error("Image workdir belongs to an unrelated Git repository.");
  }
  if (requestedIdentity.gitDir === requestedIdentity.commonDir) {
    throw new Error("Image workdir must be a linked Git worktree, not a canonical checkout.");
  }

  const verifyOwnership = options.verifyWorktreeOwnership || verifyRegisteredOwnership;
  await verifyOwnership({ root, sessionID, scriptsDir: options.scriptsDir });
  return { root, linked: true };
}
