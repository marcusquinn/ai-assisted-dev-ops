import { existsSync } from "fs";
import { join } from "path";
import { createHookStatusTool } from "./hook-status-tool.mjs";
import { createPreEditCheckTool } from "./pre-edit-check-tool.mjs";

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
      'A recall query matching a complete mem_... or obs_... ID uses exact lookup; an unknown ID returns no result without semantic fallback. ' +
      'Do not call with an empty payload; use {action:"recall",query:"...",limit:"5"} or {action:"store",content:"...",confidence:"medium"}.',
    args: {
      action: z.enum(["recall", "store"]).optional().describe('Memory operation to perform; defaults to "recall"'),
      query: z.string().optional().describe("Search query or exact mem_.../obs_... ID for memory recall"),
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
        const cmd = `bash "${memoryHelper}" recall --query ${shellEscape(query)} --limit ${shellEscape(limit)}`;
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
 * @param {{preEditTimeoutMs?: number, workerWorktree?: string, sessionOrigin?: string, poolToolFactory?: function}} [options] - Tool-specific test/runtime overrides
 * @returns {Record<string, object>}
 */
export function createTools(scriptsDir, run, options = {}) {
  if (options.sessionOrigin === "triage") return {};

  const tools = {
    aidevops: createAidevopsTool(run),
    aidevops_memory: createMemoryTool(scriptsDir, run),
    aidevops_pre_edit_check: createPreEditCheckTool(tool, z, scriptsDir, options.preEditTimeoutMs),
    aidevops_hook_status: createHookStatusTool(tool, z, { workerWorktree: options.workerWorktree }),
  };
  if (typeof options.poolToolFactory === "function") {
    tools["model-accounts-pool"] = options.poolToolFactory();
  }
  return tools;
}
