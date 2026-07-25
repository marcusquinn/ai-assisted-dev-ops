import { execFileSync, execSync, spawn } from "child_process";
import { existsSync, lstatSync, readFileSync, realpathSync, statSync } from "fs";
import { isAbsolute, join, resolve } from "path";

export let tool;
try {
  ({ tool } = await import("@opencode-ai/plugin"));
} catch {
  const schemaNode = {
    _zod: {},
    optional() {
      return this;
    },
    describe() {
      return this;
    },
  };
  tool = (definition) => definition;
  tool.schema = {
    enum() {
      return schemaNode;
    },
    string() {
      return schemaNode;
    },
    number() {
      return schemaNode;
    },
    union() {
      return schemaNode;
    },
  };
}

const z = tool.schema;

/**
 * Escape a string for safe interpolation into a shell command.
 * Wraps in single quotes and escapes any internal single quotes.
 * @param {string} str
 * @returns {string}
 */
function shellEscape(str) {
  return "'" + String(str).replace(/'/g, "'\\''") + "'";
}

/**
 * Validate that a CLI command string contains only safe characters.
 * Allows alphanumeric, spaces, hyphens, underscores, dots, forward slashes,
 * colons, hash signs (#), and at-signs (@) — sufficient for all aidevops subcommands and file path arguments.
 * Rejects shell metacharacters ($, `, ;, |, &, (, ), etc.).
 * @param {string} command
 * @returns {boolean}
 */
function isSafeCommand(command) {
  return /^[a-zA-Z0-9 _\-./:#@]+$/.test(command);
}

/**
 * Validate memory tool arguments before invoking the shell helper.
 * @param {object} args
 * @returns {string}
 */
function getMemoryArgsError(args) {
  const action = String(args.action || "recall");
  const query = typeof args.query === "string" ? args.query.trim() : "";
  const content = typeof args.content === "string" ? args.content.trim() : "";
  let error = "";

  if (!args.action && !query && !content) {
    error = 'Error: aidevops_memory requires a complete payload. Use {action:"recall", query:"<keywords>", limit:"5"} or {action:"store", content:"<lesson>", confidence:"medium"}; do not use empty calls as placeholders.';
  } else if (action === "recall" && !query) {
    error = 'Error: query is required for memory recall. Use {action:"recall", query:"<keywords>", limit:"5"}.';
  } else if (action === "store" && !content) {
    error = 'Error: content is required to store a memory. Use {action:"store", content:"<lesson>", confidence:"medium"}; do not store placeholders.';
  } else if (action !== "recall" && action !== "store") {
    error = `Unknown action: ${action}. Use "recall" or "store".`;
  }

  return error;
}

/**
 * Create the aidevops CLI tool.
 * @param {function} run - Shell command runner
 * @returns {object} Tool definition
 */
function createAidevopsTool(run) {
  return tool({
    description:
      'Run aidevops CLI commands (status, repos, features, secret, etc.). Pass command as string e.g. "status", "repos", "features"',
    args: {
      command: z.string().describe('aidevops command and arguments, e.g. "status" or "repos"'),
    },
    async execute(args) {
      const rawCmd = String(args.command || args);
      if (!isSafeCommand(rawCmd)) {
        return `Error: command contains disallowed characters. Only alphanumeric, spaces, hyphens, underscores, dots, slashes, colons, # and @ are permitted.`;
      }
      const cmd = `aidevops ${rawCmd}`;
      const result = run(cmd, 15000);
      return result || `Command completed: ${cmd}`;
    },
  });
}

/**
 * Create the unified memory tool (recall and store in one tool).
 *
 * Consolidates the former aidevops_memory_recall and aidevops_memory_store tools.
 * Both operations share the same helper script and execution pattern — a single
 * tool with an action discriminator is cleaner for the LLM and reduces tool count.
 *
 * @param {string} scriptsDir - Path to scripts directory
 * @param {function} run - Shell command runner
 * @returns {object} Tool definition
 */
function createMemoryTool(scriptsDir, run) {
  return tool({
    description:
      'Recall or store memories in the aidevops cross-session memory system. ' +
      'Args: action ("recall"|"store"), query (non-empty string, for recall), ' +
      'limit (string, default "5", for recall), ' +
      'content (non-empty string, for store), confidence ("low"|"medium"|"high", default "medium", for store). ' +
      'Do not call with an empty payload; use {action:"recall",query:"...",limit:"5"} or {action:"store",content:"...",confidence:"medium"}.',
    args: {
      action: z.enum(["recall", "store"]).optional().describe('Memory operation to perform; defaults to "recall"'),
      query: z.string().optional().describe("Search query for memory recall"),
      limit: z.union([z.string(), z.number()]).optional().describe('Maximum recall results; defaults to "5"'),
      content: z.string().optional().describe("Memory content to store"),
      confidence: z.enum(["low", "medium", "high"]).optional().describe('Stored memory confidence; defaults to "medium"'),
    },
    async execute(args) {
      args = args && typeof args === "object" ? args : {};
      const memoryHelper = join(scriptsDir, "memory-helper.sh");
      if (!existsSync(memoryHelper)) {
        return "Memory system not available (memory-helper.sh not found)";
      }

      const validationError = getMemoryArgsError(args);
      if (validationError) {
        return validationError;
      }

      const action = String(args.action || "recall");

      if (action === "recall") {
        const query = args.query.trim();
        const limit = String(args.limit ?? "").trim() || "5";
        const cmd = `bash "${memoryHelper}" recall ${shellEscape(query)} --limit ${shellEscape(limit)}`;
        const result = run(cmd, 10000);
        return result || "No memories found for this query.";
      }

      if (action === "store") {
        const content = args.content.trim();
        const confidence = args.confidence || "medium";
        const cmd = `bash "${memoryHelper}" store ${shellEscape(content)} --confidence ${shellEscape(confidence)}`;
        const result = run(cmd, 10000);
        return result || "Memory stored successfully.";
      }

      return validationError;
    },
  });
}

const PRE_EDIT_GUIDANCE = {
  1: "STOP — you are on main/master branch. Create a worktree first.",
  2: "Create a worktree before proceeding with edits.",
  3: "WARNING — proceed with caution.",
};

const MAX_HOOK_INSPECTION_BYTES = 1024 * 1024;
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

/**
 * Resolve and validate a requested Git worktree path.
 * @param {string} requestedWorkdir
 * @returns {string}
 */
function resolveGitWorktree(requestedWorkdir) {
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

function inspectHookFile(hooksDir, hookName, markers, directorySafe) {
  const markerStatus = Object.fromEntries(Object.keys(markers).map((name) => [name, false]));
  if (!directorySafe) return { status: "unsafe-hooks-directory", markers: markerStatus };

  const hookPath = join(hooksDir, hookName);
  let hookStat;
  try {
    hookStat = lstatSync(hookPath);
  } catch {
    return { status: "missing", markers: markerStatus };
  }
  if (hookStat.isSymbolicLink()) return { status: "unsafe-symlink", markers: markerStatus };
  if (!hookStat.isFile()) return { status: "unsupported-file-type", markers: markerStatus };
  if (hookStat.size > MAX_HOOK_INSPECTION_BYTES) return { status: "oversized", markers: markerStatus };

  const content = readFileSync(hookPath, "utf-8");
  for (const [name, marker] of Object.entries(markers)) markerStatus[name] = content.includes(marker);
  return { status: "regular-file", markers: markerStatus };
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

function createHookStatusTool(options = {}) {
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
 * @param {string} scriptsDir - Path to scripts directory
 * @param {number} [timeoutMs=120000] - Maximum check runtime
 * @returns {object} Tool definition
 */
function createPreEditCheckTool(scriptsDir, timeoutMs = 120000) {
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

/**
 * Create all tool definitions for the plugin.
 *
 * Tools (5 total):
 *   - aidevops              — aidevops CLI runner
 *   - aidevops_memory       — unified recall/store (merged from former recall + store pair)
 *   - aidevops_pre_edit_check — git safety check before file edits
 *   - aidevops_hook_status — bounded Git hook marker inspection
 *   - model-accounts-pool   — OAuth account pool management (added in index.mjs)
 *
 * NOTE: aidevops_quality_check was removed. Quality checks run automatically
 * via the tool.execute.before hook on every Write/Edit operation — an explicit
 * LLM-callable tool is redundant and adds unnecessary context overhead.
 *
 * NOTE: aidevops_install_hooks was removed. Hook installation is a one-time
 * setup operation best done via Bash: `bash ~/.aidevops/agents/scripts/install-hooks-helper.sh install`
 * or `aidevops security posture`. A dedicated plugin tool adds ~90 lines of
 * code for a task the LLM can perform directly via the Bash tool.
 *
 * NOTE: opencode 1.1.56+ uses Zod v4 to validate tool args schemas.
 * Use `tool.schema` from `@opencode-ai/plugin` for args definitions; plain
 * JSON schema objects are not valid here because OpenCode expects Zod objects.
 *
 * @param {string} scriptsDir - Path to scripts directory
 * @param {function} run - Shell command runner
 * @param {{preEditTimeoutMs?: number, workerWorktree?: string}} [options] - Tool-specific test/runtime overrides
 * @returns {Record<string, object>}
 */
export function createTools(scriptsDir, run, options = {}) {
  return {
    aidevops: createAidevopsTool(run),
    aidevops_memory: createMemoryTool(scriptsDir, run),
    aidevops_pre_edit_check: createPreEditCheckTool(scriptsDir, options.preEditTimeoutMs),
    aidevops_hook_status: createHookStatusTool({ workerWorktree: options.workerWorktree }),
  };
}
