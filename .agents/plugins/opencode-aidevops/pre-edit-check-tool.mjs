// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync, spawn } from "child_process";
import { existsSync, realpathSync, statSync } from "fs";
import { isAbsolute, join, relative, resolve, sep } from "path";

const PRE_EDIT_GUIDANCE = {
  1: "STOP — you are on main/master branch. Create a worktree first.",
  2: "Create a worktree before proceeding with edits.",
  3: "WARNING — proceed with caution.",
};
const MAX_TARGET_PATHS = 32;
const EXTERNAL_TARGET_RESPONSE =
  "Git isolation not applicable: all explicit targetPaths resolve outside Git worktrees.\n"
  + "This result does not authorize file writes; runtime path, secret, destructive-operation, and managed-directory policies still apply.";

class PreEditRequestError extends Error {}

function pathIsWithin(candidate, parent) {
  const relation = relative(parent, candidate);
  return relation === "" || (relation !== ".." && !relation.startsWith(`..${sep}`) && !isAbsolute(relation));
}

function parsePolicyPayload(raw) {
  const payload = JSON.parse(raw);
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new TypeError("policy returned a non-object payload");
  }
  return payload;
}

function validateTargetPaths(targetPaths) {
  if (!Array.isArray(targetPaths) || targetPaths.length > MAX_TARGET_PATHS) {
    throw new TypeError(`targetPaths must contain 1-${MAX_TARGET_PATHS} non-empty strings`);
  }
  if (targetPaths.some((targetPath) => typeof targetPath !== "string" || !targetPath.trim())) {
    throw new TypeError(`targetPaths must contain 1-${MAX_TARGET_PATHS} non-empty strings`);
  }
  if (targetPaths.some((targetPath) => targetPath.split(/[\\/]+/).includes(".."))) {
    throw new TypeError("targetPaths containing parent traversal are ambiguous and must be normalized by the caller");
  }
}

function classifyExplicitTarget(helper, targetPath, workdir) {
  const raw = execFileSync(
    "python3",
    [helper, "check-write", "--cwd", workdir, "--path", targetPath],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 10000,
    },
  );
  const policy = parsePolicyPayload(raw);
  const repoRoot = policy.context?.repo_root;
  const lexicalTarget = resolve(workdir, targetPath);
  const lexicallyRepositoryLocal = typeof repoRoot === "string"
    && repoRoot !== ""
    && pathIsWithin(lexicalTarget, repoRoot);
  return { policy, targetPath, lexicallyRepositoryLocal };
}

function classifyExplicitTargets(targetPaths, scriptsDir, workdir) {
  validateTargetPaths(targetPaths);
  const helper = join(scriptsDir, "canonical-write-policy-helper.py");
  if (!existsSync(helper)) {
    throw new Error("required canonical-write policy helper is missing");
  }
  return targetPaths.map((targetPath) => classifyExplicitTarget(helper, targetPath, workdir));
}

function explicitTargetFailure(error) {
  const detail = error?.stderr?.toString().trim() || error?.message || "target classification failed";
  return `Pre-edit check exit 1: explicit target path classification failed closed\n${detail}`;
}

function targetIsUnsafe({ policy, lexicallyRepositoryLocal }) {
  if (policy.decision === "allow") return false;
  const sameCanonicalRepository = policy.context?.classification === "canonical"
    && policy.target?.classification === "canonical"
    && policy.context?.common_dir === policy.target?.common_dir
    && lexicallyRepositoryLocal;
  return !sameCanonicalRepository;
}

function targetIsExternal({ policy, lexicallyRepositoryLocal }) {
  return policy.decision === "allow"
    && policy.target?.classification === "outside"
    && !lexicallyRepositoryLocal;
}

function targetIsRepositoryLocal({ policy, lexicallyRepositoryLocal }) {
  return lexicallyRepositoryLocal || ["canonical", "linked"].includes(policy.target?.classification);
}

function resolveRepositoryTargetScope(classifications) {
  const repositoryTargets = classifications.filter(targetIsRepositoryLocal);
  const targetWorkdir = repositoryTargets[0]?.policy.target?.repo_root;
  if (typeof targetWorkdir !== "string" || !targetWorkdir) {
    throw new Error("target repository root is missing or indeterminate");
  }
  if (repositoryTargets.some(({ policy }) => policy.target?.repo_root !== targetWorkdir)) {
    throw new Error("explicit repository targets span multiple worktrees");
  }
  return {
    repositoryTarget: repositoryTargets[0].targetPath,
    targetWorkdir,
    terminalResponse: "",
  };
}

function resolveExplicitTargetScope(targetPaths, scriptsDir, targetWorkdir) {
  const classifications = classifyExplicitTargets(targetPaths, scriptsDir, targetWorkdir);
  const deniedTarget = classifications.find(targetIsUnsafe);
  if (deniedTarget) {
    throw new Error(deniedTarget.policy.reason || "unsafe explicit target");
  }
  if (classifications.every(targetIsExternal)) {
    return { repositoryTarget: "", targetWorkdir, terminalResponse: EXTERNAL_TARGET_RESPONSE };
  }
  if (!classifications.some(targetIsRepositoryLocal)) {
    throw new Error("target scope is mixed or indeterminate");
  }
  return resolveRepositoryTargetScope(classifications);
}

function requirePreEditScript(scriptsDir) {
  const script = join(scriptsDir, "pre-edit-check.sh");
  if (!existsSync(script)) {
    throw new PreEditRequestError("pre-edit-check.sh not found — cannot verify git safety");
  }
  return script;
}

function requireTargetWorktree(requestedWorkdir) {
  const targetWorkdir = resolveGitWorktree(requestedWorkdir);
  if (!targetWorkdir) {
    throw new PreEditRequestError(
      `Pre-edit check exit 1: target workdir must resolve to an existing Git worktree\n${requestedWorkdir}`,
    );
  }
  return targetWorkdir;
}

function normalizeTargetPaths(targetPaths) {
  if (!Array.isArray(targetPaths)) {
    throw new PreEditRequestError(explicitTargetFailure(new TypeError("targetPaths must be an array")));
  }
  return targetPaths;
}

function preparePreEditInvocation(args, scriptsDir) {
  const script = requirePreEditScript(scriptsDir);
  const requestedWorkdir = args.workdir || process.cwd();
  const targetWorkdir = requireTargetWorktree(requestedWorkdir);
  const targetPaths = normalizeTargetPaths(args.targetPaths === undefined ? [] : args.targetPaths);
  let targetScope = { repositoryTarget: "", targetWorkdir, terminalResponse: "" };
  try {
    if (targetPaths.length > 0) {
      targetScope = resolveExplicitTargetScope(targetPaths, scriptsDir, targetWorkdir);
    }
  } catch (error) {
    throw new PreEditRequestError(explicitTargetFailure(error));
  }
  return { script, ...targetScope };
}

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
      'Run the pre-edit git safety check before modifying files. Returns exit code and guidance. Args: task (optional string for loop mode), workdir (optional target Git worktree), targetPaths (optional intended write paths)',
    args: {
      task: z.string().optional().describe('Optional task description for loop-mode worktree guidance'),
      workdir: z.string().optional().describe('Optional target Git worktree to validate'),
      targetPaths: z.array(z.string()).optional().describe('Optional intended write paths, resolved relative to workdir'),
    },
    async execute(args) {
      const normalizedArgs = args && typeof args === "object" ? args : {};
      let invocation;
      try {
        invocation = preparePreEditInvocation(normalizedArgs, scriptsDir);
      } catch (error) {
        return error instanceof PreEditRequestError ? error.message : explicitTargetFailure(error);
      }
      if (invocation.terminalResponse) return invocation.terminalResponse;
      const { script, targetWorkdir, repositoryTarget } = invocation;
      const taskArgs = repositoryTarget
        ? [...(normalizedArgs.task ? ["--loop-mode"] : []), "--file", repositoryTarget]
        : (normalizedArgs.task ? ["--loop-mode", "--task", normalizedArgs.task] : []);
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
