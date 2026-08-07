// ---------------------------------------------------------------------------
// Phase 3: Quality Hooks (t008.3)
// Extracted from index.mjs (t1914) — tool execution hook wiring.
// Logging, scanning, and pipeline logic in quality-logging.mjs.
// ---------------------------------------------------------------------------

import { existsSync } from "fs";
import { execFileSync, execFile } from "child_process";
import { join } from "path";
import { recordToolCall } from "./observability.mjs";
import { extractAndStoreIntent, consumeIntent } from "./intent-tracing.mjs";
import { recordToolStart, consumeToolDuration } from "./timing-tracing.mjs";
import { qualityLog, runFileQualityGate } from "./quality-logging.mjs";
import { enrichActiveSpan, detectTaskId, detectSessionOrigin } from "./otel-enrichment.mjs";
import {
  checkSecretReadGate,
  isReadTool,
  secretReadBlockReason,
} from "./quality-hooks-secret-read.mjs";
import { checkSecretReadWithApproval } from "./source-access-approval.mjs";
import { checkResearchStagingAccess } from "./research-staging-guard.mjs";
import {
  bindActiveScriptsDir,
  checkCanonicalGitSafetyGate,
  checkCanonicalWriteSafetyGate,
  isApplyPatchMutationTool,
  isDirectFileMutationTool,
} from "./quality-hooks-git-safety.mjs";

// Re-export for consumers that import from this module
export { scanForSecrets } from "./quality-logging.mjs";
export { checkSecretReadGate, isReadTool } from "./quality-hooks-secret-read.mjs";

// ---------------------------------------------------------------------------
// Credential transcript scrub (GH#20207, Layer 4 of t2458)
// Mirrors shared-constants.sh scrub_credentials regex.
// Applied in handleToolAfter to redact tokens before they reach the model
// or are persisted to the SQLite transcript store.
// ---------------------------------------------------------------------------

const CREDENTIAL_PATTERN =
  /(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/g;

const REDACTION_TOKEN = "[redacted-credential]";
const OPERATION_TITLE_MAX_LENGTH = 500;

/**
 * Scrub known credential token prefixes from a string value.
 * @param {string} text
 * @returns {{ scrubbed: string, count: number }}
 */
export function scrubCredentials(text) {
  let count = 0;
  const scrubbed = text.replace(CREDENTIAL_PATTERN, (_match, boundary) => {
    count++;
    return `${boundary}${REDACTION_TOKEN}`;
  });
  return { scrubbed, count };
}

/**
 * Prepare an untrusted tool title for bounded, single-line telemetry storage.
 * @param {string} title
 * @returns {string}
 */
export function sanitizeOperationTitle(title) {
  const { scrubbed } = scrubCredentials(title);
  return scrubbed
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, OPERATION_TITLE_MAX_LENGTH);
}

/**
 * Recursively scrub credentials from any JSON-serialisable value.
 * @param {unknown} value
 * @returns {{ value: unknown, count: number }}
 */
function scrubValue(value) {
  if (typeof value === "string") {
    const { scrubbed, count } = scrubCredentials(value);
    return { value: scrubbed, count };
  }
  if (Array.isArray(value)) {
    let total = 0;
    const result = value.map((item) => {
      const { value: v, count } = scrubValue(item);
      total += count;
      return v;
    });
    return { value: result, count: total };
  }
  if (value !== null && typeof value === "object") {
    let total = 0;
    const result = {};
    for (const [k, v] of Object.entries(value)) {
      const { value: scrubbed, count } = scrubValue(v);
      result[k] = scrubbed;
      total += count;
    }
    return { value: result, count: total };
  }
  return { value, count: 0 };
}

/**
 * Scrub credentials from tool output. Returns the sanitised output and a
 * boolean indicating whether any redaction occurred.
 * @param {unknown} output
 * @returns {{ output: unknown, redacted: boolean }}
 */
function scrubToolOutput(output) {
  const { value, count } = scrubValue(output);
  return { output: value, redacted: count > 0 };
}

// ---------------------------------------------------------------------------
// Tool classification helpers
// ---------------------------------------------------------------------------

/**
 * Check if a tool name is a Write or Edit operation.
 * @param {string} tool
 * @returns {boolean}
 */
function isWriteOrEditTool(tool) {
  return isDirectFileMutationTool(tool);
}

/**
 * Check if a tool name is a Bash operation.
 * @param {string} tool
 * @returns {boolean}
 */
function isBashTool(tool) {
  return tool === "Bash" || tool === "bash";
}

// ---------------------------------------------------------------------------
// Signature footer gate (GH#12805, t1755, t2685)
// ---------------------------------------------------------------------------
// Implementation extracted to quality-hooks-signature.mjs (t2685) to keep
// this module below the qlty file-complexity ratchet. We import + export
// rather than using `export { … } from "./module"` because the latter is a
// re-export only and does NOT create a local binding — `checkSignatureFooterGate`
// is called locally at handleToolAfter below, so it must be imported into
// this module's scope. See GH hotfix: re-export-only form broke all Bash
// tool calls with `ReferenceError: checkSignatureFooterGate is not defined`.

import {
  SIG_MARKER,
  isGhWriteCommand,
  isMachineProtocolCommand,
  hasTrustedSignatureSignal,
  tryRepairSignature,
  checkSignatureFooterGate,
} from "./quality-hooks-signature.mjs";

export {
  SIG_MARKER,
  isGhWriteCommand,
  isMachineProtocolCommand,
  hasTrustedSignatureSignal,
  tryRepairSignature,
  checkSignatureFooterGate,
};

// ---------------------------------------------------------------------------
// Pattern tracking
// ---------------------------------------------------------------------------

/**
 * Run a shell command and return stdout, or empty string on failure.
 * @param {string} cmd
 * @param {number} [timeout=5000]
 * @returns {string}
 */
/**
 * Record a git operation pattern via pattern-tracker-helper.sh.
 * @param {string} scriptsDir
 * @param {string} title
 * @param {string} outputText
 */
function recordGitPattern(scriptsDir, title, outputText) {
  const patternTracker = join(scriptsDir, "pattern-tracker-helper.sh");
  if (!existsSync(patternTracker)) return;

  const success = !outputText.includes("error") && !outputText.includes("fatal");
  const patternType = success ? "SUCCESS_PATTERN" : "FAILURE_PATTERN";

  try {
    execFileSync(
      "bash",
      [patternTracker, "record", patternType, `git operation: ${title.substring(0, 100)}`, "--tag", "quality-hook"],
      { encoding: "utf-8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"] },
    );
  } catch {
    // best-effort
  }
}

/**
 * Track Bash tool operations (git, lint) for pattern recording.
 * @param {object} ctx - { scriptsDir, logsDir, qualityLogPath }
 * @param {string} title
 * @param {string} outputText
 */
function trackBashOperation(ctx, title, outputText) {
  const boundedTitle = sanitizeOperationTitle(title);
  if (title.includes("git commit") || title.includes("git push")) {
    // Tool titles can contain entire commands and long file lists. Keep this
    // informational telemetry in the quality log: writing it to stderr draws
    // over OpenCode's TUI and makes payload text part of console routing.
    qualityLog(ctx.logsDir, ctx.qualityLogPath, "INFO", `Git operation: ${boundedTitle}`);
    recordGitPattern(ctx.scriptsDir, boundedTitle, outputText);
  }

  if (title.includes("shellcheck") || title.includes("linters-local")) {
    const passed = !outputText.includes("error") && !outputText.includes("violation");
    qualityLog(ctx.logsDir, ctx.qualityLogPath, passed ? "INFO" : "WARN", `Lint run: ${boundedTitle} — ${passed ? "PASS" : "issues found"}`);
  }
}

/**
 * Handle post-tool tracking for task tool calls (GH#17511).
 * @param {string} taskId
 * @param {string} scriptsDir
 * @param {Function} log - Quality logger function
 */
function recordChildSubagent(taskId, scriptsDir, log) {
  if (!taskId) return;
  const helper = join(scriptsDir, "gh-signature-helper.sh");
  if (!existsSync(helper)) return;
  execFile(helper, ["record-child", "--child", taskId], (err) => {
    if (err) log("WARN", `record-child failed: ${err.message}`);
  });
}

// ---------------------------------------------------------------------------
// Hook factory
// ---------------------------------------------------------------------------

/**
 * Create the quality hook functions (toolExecuteBefore, toolExecuteAfter).
 * @param {object} deps - { scriptsDir, logsDir, repositoryDir }
 * @returns {{ toolExecuteBefore: Function, toolExecuteAfter: Function, qualityLog: Function }}
 */
/**
 * Pre-tool-execution handler: intent tracing, signature gate, file quality.
 * @param {object} ctx - Quality hooks context
 * @param {Function} log - Bound quality logger
 * @param {object} input - Tool input
 * @param {object} output - Tool output
 */
function enforceDirectFileMutationSafety(ctx, input, output) {
  if (!isDirectFileMutationTool(input.tool)) return;
  const writeCwd = output.args?.workdir || output.args?.cwd || ctx.repositoryDir || process.cwd();
  const filePath = output.args?.filePath || output.args?.file_path || output.args?.path || "";
  const rawPatchText = output.args?.patchText || output.args?.patch_text || "";
  const patchText = isApplyPatchMutationTool(input.tool)
    ? (typeof rawPatchText === "string" ? rawPatchText : "")
    : null;
  checkCanonicalWriteSafetyGate(filePath, ctx.scriptsDir, writeCwd, patchText);
}

function handleToolBefore(ctx, log, input, output) {
  ctx.continuationGuard?.beforeTool(input, output);
  enforceDirectFileMutationSafety(ctx, input, output);

  const callID = input.callID || "";
  let intent = "";
  if (callID && output.args) {
    intent = extractAndStoreIntent(callID, output.args) || "";
    if (intent) {
      log("INFO", `Intent [${input.tool}] callID=${callID}: ${intent}`);
    }
  }

  // t2184: pair with tool.execute.after to compute duration_ms for the
  // tool_calls INSERT. recordToolStart no-ops on empty callID.
  recordToolStart(callID);

  // OTEL span enrichment (t2177) — attaches aidevops attributes to opencode's
  // active tool span when OTEL is enabled. Async fire-and-forget; errors
  // swallowed inside enrichActiveSpan to isolate the host tool from OTEL SDK
  // failures.
  enrichActiveSpan({
    "aidevops.intent": intent,
    "aidevops.tool_name": input.tool || "",
    "aidevops.task_id": detectTaskId(),
    "aidevops.session_origin": detectSessionOrigin(),
    "aidevops.runtime": "opencode",
  }).catch(() => {});

  const sessionId = input.sessionID || input.sessionId || input.session?.id || "";
  if (isBashTool(input.tool)) {
    const bashArgs = output.args ?? {};
    const bashCwd = bashArgs.workdir || bashArgs.cwd || process.cwd();
    bashArgs.command = checkCanonicalGitSafetyGate(
      bashArgs.command || "",
      ctx.scriptsDir,
      bashCwd,
      {
        activeScriptsDir: ctx.activeScriptsDir,
        activeScriptsDirBinding: ctx.activeScriptsDirBinding,
      },
    );
    // t2685: pass scriptsDir + output so the hook can repair (mutate
    // output.args.command) or block (throw) as appropriate.
    const signatureModel = ctx.resolveSessionModel(sessionId);
    checkSignatureFooterGate(bashArgs.command || "", log, ctx.scriptsDir, output, {
      model: signatureModel,
      useProcessModelFallback: false,
    });
  }

  checkSecretReadWithApproval({
    tool: input.tool,
    args: output.args || {},
    sessionId,
    scriptsDir: ctx.scriptsDir,
    isReadTool,
    secretReadBlockReason,
    checkSecretReadGate,
    log,
  });
  checkResearchStagingAccess(input.tool, output.args || {});

  if (!isWriteOrEditTool(input.tool)) return;

  const filePath = output.args?.filePath || output.args?.file_path || "";
  if (filePath) {
    runFileQualityGate(ctx, filePath, output.args);
  }
}

/**
 * Post-tool-execution handler: bash tracking, file logging, observability.
 * @param {object} ctx - Quality hooks context
 * @param {Function} log - Bound quality logger
 * @param {string} scriptsDir
 * @param {object} input - Tool input
 * @param {object} output - Tool output
 */
function handleToolAfter(ctx, log, scriptsDir, input, output) {
  const toolName = input.tool || "";

  // GH#20207 (t2458 Layer 4): scrub credentials from tool output before
  // persisting to the SQLite transcript store or sending to the model.
  // Applies to all tools — credentials can arrive via user scripts, third-party
  // CLIs, or runtime error backtraces, not just framework helpers.
  const rawOutput = output.output;
  if (rawOutput !== undefined) {
    const { output: scrubbedOutput, redacted } = scrubToolOutput(rawOutput);
    if (redacted) {
      output.output = scrubbedOutput;
      log("WARN", `[credential-scrub] redacted credential token(s) from ${toolName} output`);
    }
  }

  const continuationResult = ctx.continuationGuard?.afterTool(input, output);
  if (continuationResult?.replan) {
    log("WARN", `[session-continuation] repeated ${toolName} failure requires replanning`);
  }

  if (isBashTool(toolName)) {
    trackBashOperation(ctx, output.title || "", output.output || "");
  }

  if (isWriteOrEditTool(toolName)) {
    const filePath = output.metadata?.filePath || "";
    if (filePath) {
      log("INFO", `File modified: ${filePath} via ${toolName}`);
    }
  }

  const intent = consumeIntent(input.callID || "");
  // t2184: consumeToolDuration returns null when the callID wasn't paired
  // (e.g., hook race on plugin reload) — recordToolCall emits SQL NULL.
  const durationMs = consumeToolDuration(input.callID || "");
  recordToolCall(input, output, intent, durationMs);

  if (toolName === "mcp_task" || toolName === "task") {
    recordChildSubagent(output?.metadata?.task_id || "", scriptsDir, log);
  }
}

export function createQualityHooks(deps) {
  const { scriptsDir, logsDir, continuationGuard } = deps;
  const activeScriptsDir = deps.activeScriptsDir ?? scriptsDir;
  const activeScriptsDirBinding = bindActiveScriptsDir(activeScriptsDir, scriptsDir);
  const qualityLogPath = join(logsDir, "quality-hooks.log");
  // t2120: qualityDetailLog (in quality-logging.mjs) reads ctx.detailLogPath
  // and ctx.detailMaxBytes. Previously these were never populated here, so
  // every call to logQualityGateResult → qualityDetailLog threw
  // "path must be a string or a file descriptor" from appendFileSync(undefined)
  // at quality-logging.mjs:86. The warning was swallowed by the catch block
  // but `console.error` polluted every worker's stderr on every file write.
  // It also meant real quality-gate diagnostics (shellcheck reports, markdown
  // lint, secret scan details) were silently lost for every edit — the
  // framework's own write-time quality discipline was invisible.
  const detailLogPath = join(logsDir, "quality-hooks-detail.log");
  const detailMaxBytes = 5 * 1024 * 1024; // 5MB before rotation
  const ctx = {
    scriptsDir,
    activeScriptsDir,
    activeScriptsDirBinding,
    logsDir,
    qualityLogPath,
    detailLogPath,
    detailMaxBytes,
    repositoryDir: deps.repositoryDir,
    continuationGuard,
    resolveSessionModel: typeof deps.resolveSessionModel === "function"
      ? deps.resolveSessionModel
      : () => "",
  };

  function boundQualityLog(level, message) {
    qualityLog(logsDir, qualityLogPath, level, message);
  }

  return {
    toolExecuteBefore: async (input, output) => handleToolBefore(ctx, boundQualityLog, input, output),
    toolExecuteAfter: async (input, output) => handleToolAfter(ctx, boundQualityLog, scriptsDir, input, output),
    qualityLog: boundQualityLog,
  };
}
