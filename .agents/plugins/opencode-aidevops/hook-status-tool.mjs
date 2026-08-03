// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "child_process";
import { lstatSync, realpathSync } from "fs";
import { isAbsolute, join, resolve } from "path";
import { inspectHookFile } from "./hook-file-inspection.mjs";
import { resolveGitWorktree } from "./pre-edit-check-tool.mjs";

const HOOK_MARKERS = {
  "pre-commit": {
    quality: "# aidevops-pre-commit-hook",
    markdoc: "# aidevops-markdoc-validate-hook",
  },
  "pre-push": {
    ghWrapper: "# aidevops-gh-wrapper-guard",
    quality: "# aidevops-pre-push-quality-hook",
  },
};

function resolveGitMetadataPath(worktree, selector) {
  const rawPath = execFileSync(
    "git",
    ["-C", worktree, "rev-parse", selector],
    {
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "ignore"],
    },
  ).trim();
  return realpathSync(isAbsolute(rawPath) ? rawPath : resolve(worktree, rawPath));
}

function inspectGitHooks(worktree) {
  const gitDir = resolveGitMetadataPath(worktree, "--git-dir");
  const commonDir = resolveGitMetadataPath(worktree, "--git-common-dir");
  const hooksDir = join(commonDir, "hooks");
  let hooksDirectoryStatus = "missing";
  let directorySafe = false;
  try {
    const hooksStat = lstatSync(hooksDir);
    if (hooksStat.isSymbolicLink()) hooksDirectoryStatus = "unsafe-symlink";
    else if (hooksStat.isDirectory()) {
      hooksDirectoryStatus = "directory";
      directorySafe = true;
    } else hooksDirectoryStatus = "unsupported-file-type";
  } catch {
    hooksDirectoryStatus = "missing";
  }

  return {
    schema: "aidevops-hook-status/v1",
    sharedGitDirectory: gitDir !== commonDir,
    hooksDirectory: hooksDirectoryStatus,
    hooks: Object.fromEntries(Object.entries(HOOK_MARKERS).map(([hookName, markers]) => [
      hookName,
      inspectHookFile(hooksDir, hookName, markers, directorySafe),
    ])),
  };
}

/**
 * Create the bounded Git hook status tool.
 * @param {function} tool - OpenCode tool factory
 * @param {object} z - OpenCode tool schema helpers
 * @param {{workerWorktree?: string}} [options] - Tool-specific runtime overrides
 * @returns {object} Tool definition
 */
export function createHookStatusTool(tool, z, options = {}) {
  return tool({
    description:
      "Inspect known aidevops Git hook markers for an existing worktree without reading canonical .git/hooks through file tools. " +
      "Use this for pre-commit/pre-push hook integrity checks. Returns statuses only—never hook contents or filesystem paths.",
    args: {
      workdir: z.string().optional().describe("Optional existing Git worktree; defaults to the current worktree"),
    },
    async execute(args) {
      args = args && typeof args === "object" ? args : {};
      const requestedWorkdir = args.workdir || process.cwd();
      const targetWorkdir = resolveGitWorktree(requestedWorkdir);
      if (!targetWorkdir) return "Hook status unavailable: target must resolve to an existing Git worktree";

      const workerWorktree = options.workerWorktree ?? process.env.WORKER_WORKTREE_PATH ?? "";
      if (workerWorktree) {
        const boundWorktree = resolveGitWorktree(workerWorktree);
        if (!boundWorktree || boundWorktree !== targetWorkdir) {
          return "Hook status denied: headless workers may inspect only their assigned worktree";
        }
      }

      try {
        return JSON.stringify(inspectGitHooks(targetWorkdir), null, 2);
      } catch {
        return "Hook status unavailable: Git metadata could not be validated";
      }
    },
  });
}
