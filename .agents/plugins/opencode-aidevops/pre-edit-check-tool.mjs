// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync, spawn } from "child_process";
import { existsSync, realpathSync, statSync } from "fs";
import { join } from "path";

const PRE_EDIT_GUIDANCE = {
  1: "STOP — you are on main/master branch. Create a worktree first.",
  2: "Create a worktree before proceeding with edits.",
  3: "WARNING — proceed with caution.",
};

/**
 * Resolve and validate a requested Git worktree path.
 * @param {string} requestedWorkdir
 * @returns {string}
 */
export function resolveGitWorktree(requestedWorkdir) {
  let targetWorkdir = "";
  try {
    const resolvedWorkdir = realpathSync(requestedWorkdir);
    if (statSync(resolvedWorkdir).isDirectory()) {
      const insideWorktree = execFileSync(
        "git",
        ["-C", resolvedWorkdir, "rev-parse", "--is-inside-work-tree"],
        {
          encoding: "utf-8",
          timeout: 5000,
          stdio: ["ignore", "pipe", "ignore"],
        },
      ).trim();
      if (insideWorktree === "true") targetWorkdir = resolvedWorkdir;
    }
  } catch {
    targetWorkdir = "";
  }
  return targetWorkdir;
}

/**
 * Format the pre-edit subprocess outcome for the tool response.
 * @param {{code: number|null, stdout: string, stderr: string, timedOut: boolean, error?: Error}} result
 * @param {number} timeoutMs
 * @returns {string}
 */
function formatPreEditCheckResult(result, timeoutMs) {
  const cmdOutput = (result.stdout + result.stderr).trim();
  let response;
  if (result.timedOut) {
    response = `Pre-edit check TIMED OUT after ${timeoutMs}ms: child process tree terminated before returning\n${cmdOutput}`;
  } else if (result.error) {
    response = `Pre-edit check failed to start: ${result.error.message}\n${cmdOutput}`;
  } else {
    const code = result.code ?? 1;
    response = code === 0
      ? `Pre-edit check PASSED (exit 0):\n${cmdOutput}`
      : `Pre-edit check exit ${code}: ${PRE_EDIT_GUIDANCE[code] || "Unknown"}\n${cmdOutput}`;
  }
  return response;
}

/**
 * Create the pre-edit check tool.
 * @param {function} tool - OpenCode tool factory
 * @param {object} z - OpenCode tool schema helpers
 * @param {string} scriptsDir - Path to scripts directory
 * @param {number} [timeoutMs=120000] - Maximum check runtime
 * @returns {object} Tool definition
 */
export function createPreEditCheckTool(tool, z, scriptsDir, timeoutMs = 120000) {
  return tool({
    description:
      'Run the pre-edit git safety check before modifying files. Returns exit code and guidance. Args: task (optional string for loop mode), workdir (optional target Git worktree)',
    args: {
      task: z.string().optional().describe('Optional task description for loop-mode worktree guidance'),
      workdir: z.string().optional().describe('Optional target Git worktree to validate'),
    },
    async execute(args) {
      args = args && typeof args === "object" ? args : {};
      const script = join(scriptsDir, "pre-edit-check.sh");
      if (!existsSync(script)) {
        return "pre-edit-check.sh not found — cannot verify git safety";
      }
      const requestedWorkdir = args.workdir || process.cwd();
      const targetWorkdir = resolveGitWorktree(requestedWorkdir);
      if (!targetWorkdir) {
        return `Pre-edit check exit 1: target workdir must resolve to an existing Git worktree\n${requestedWorkdir}`;
      }
      const taskArgs = args.task ? ["--loop-mode", "--task", args.task] : [];
      const result = await runPreEditCheck(script, taskArgs, targetWorkdir, timeoutMs);
      return formatPreEditCheckResult(result, timeoutMs);
    },
  });
}

/**
 * Run loop-mode checks in their own process group so a timeout cannot leave a
 * helper running long enough to create a worktree after the tool has returned.
 * @param {string} script
 * @param {string[]} args
 * @param {string} cwd
 * @param {number} timeoutMs
 * @returns {Promise<{code: number|null, stdout: string, stderr: string, timedOut: boolean, error?: Error}>}
 */
function runPreEditCheck(script, args, cwd, timeoutMs) {
  return new Promise((resolve) => {
    const child = spawn("bash", [script, ...args], {
      cwd,
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let spawnError;

    child.stdout.setEncoding("utf-8");
    child.stderr.setEncoding("utf-8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => { spawnError = error; });

    const timer = setTimeout(() => {
      timedOut = true;
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    }, timeoutMs);

    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut, error: spawnError });
    });
  });
}
