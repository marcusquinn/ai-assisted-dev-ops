// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Signature footer gate (GH#12805, t1755, t2685, t2893)
// ---------------------------------------------------------------------------
// Enforces that every `gh issue create|comment` and `gh pr create|comment`
// command posts a body ending with the canonical aidevops signature footer.
// Extracted from quality-hooks.mjs (t2685) to keep the main module below
// the qlty file-complexity ratchet.
//
// Detection tiers:
//   1. cmd contains the literal "gh-signature-helper" → trust the caller,
//      pass through (good-path: they're invoking the helper explicitly).
//   2. cmd contains the canonical HTML marker `<!-- aidevops:sig -->` →
//      a helper-produced footer is already inline. Pass through.
//   3. Footer variable interpolation (`$FOOTER`, `$SIGNATURE`, …) in cmd →
//      likely good-path, log INFO and pass through.
//   4. Machine-protocol comments (DISPATCH_CLAIM, KILL_WORKER, MERGE_SUMMARY)
//      → exempt by design. These are machine-to-machine protocols that
//      workers/pulse parse structurally; adding a footer would corrupt them.
//   5. Otherwise: attempt transparent repair by invoking gh-signature-helper
//      and mutating output.args.command in place. If repair succeeds, the
//      model never sees an error; the command just silently gets the correct
//      footer. If repair fails (heredoc, command substitution in body,
//      unparseable structure), THROW an error that blocks the tool call and
//      educates the next attempt.
//
// Pre-execution race (t2893)
// --------------------------
// This hook runs PRE-bash-execution. When the model writes a single bash
// call that creates a `--body-file` and then immediately posts it (e.g.
// `cp x /tmp/foo.md && gh issue comment --body-file /tmp/foo.md`), the
// readFileSync in _repairBodyFile sees ENOENT — bash hasn't executed the
// file-creation step yet. Prior to t2893 this surfaced as a generic
// "likely heredoc/cmd-sub/quoting" error that didn't name the actual
// cause; the model wasted 3-5 tool calls on the wrong hypothesis.
//
// As of t2893, repair helpers return structured failures
// `{ status: "ok"|"fail", reason?: string, detail?: string, cmd?: string }`,
// the throw site formats the specific cause, and the FILE_NOT_FOUND path
// includes targeted same-bash-call mentorship. The PATH shim at
// .agents/scripts/gh runs at exec-time (after bash creates the file) and
// is the correct enforcement layer for the same-bash-call shape.

import { existsSync } from "fs";
import { execFileSync } from "child_process";
import { join } from "path";

import { FAIL_REASON, formatGateThrowMessage } from "./quality-hooks-signature-failures.mjs";
import { repairBodyFile } from "./quality-hooks-signature-body-file.mjs";
import {
  SIG_MARKER,
  hasTrustedSignatureSignal,
  isGhWriteCommand,
  isMachineProtocolCommand,
} from "./quality-hooks-signature-detection.mjs";

// Re-export FAIL_REASON so existing test imports
// (`import { FAIL_REASON } from "../quality-hooks-signature.mjs"`) keep
// working. Definition lives in quality-hooks-signature-failures.mjs to
// keep this file under the qlty per-file complexity threshold (t2893).
export { FAIL_REASON };
export { SIG_MARKER, hasTrustedSignatureSignal, isGhWriteCommand, isMachineProtocolCommand };

function _signatureHelperEnv(explicitModel = "", useProcessModelFallback = true) {
  const helperEnv = {
    ...process.env,
    AIDEVOPS_SIG_CLI: process.env.AIDEVOPS_SIG_CLI || "OpenCode",
    AIDEVOPS_SIG_TOKENS: process.env.AIDEVOPS_SIG_TOKENS || "0",
  };
  const fallbackModel = useProcessModelFallback
    ? process.env.AIDEVOPS_SIG_MODEL || process.env.OPENCODE_MODEL || ""
    : "";
  const model = explicitModel || fallbackModel;
  if (model) {
    helperEnv.AIDEVOPS_SIG_MODEL = model;
  } else {
    delete helperEnv.AIDEVOPS_SIG_MODEL;
  }
  return helperEnv;
}

/**
 * Generate a signature footer by invoking gh-signature-helper.sh synchronously.
 * Returns `{ status: "ok", sig }` on success or
 * `{ status: "fail", reason: FAIL_REASON.HELPER_FAILED, detail }` on any
 * failure (missing helper, helper error, output missing marker) (t2893).
 * @param {string} helperPath
 * @param {string} bodyValue - body text passed to --body arg of helper
 * @param {Function} log
 * @returns {{ status: "ok", sig: string } | { status: "fail", reason: string, detail: string }}
 */
function _generateSignature(helperPath, bodyValue, log, options = {}) {
  try {
    const sig = execFileSync(helperPath, ["footer", "--no-session", "--body", bodyValue], {
      encoding: "utf-8",
      timeout: 1500,
      stdio: ["pipe", "pipe", "pipe"],
      env: _signatureHelperEnv(options.model, options.useProcessModelFallback),
    });
    if (!sig || !sig.includes(SIG_MARKER)) {
      log("WARN", "gh-signature-helper output missing marker; refusing to inject");
      return {
        status: "fail",
        reason: FAIL_REASON.HELPER_FAILED,
        detail: "helper output missing canonical marker",
      };
    }
    return { status: "ok", sig };
  } catch (e) {
    log("WARN", `gh-signature-helper invocation failed: ${e.message}`);
    return {
      status: "fail",
      reason: FAIL_REASON.HELPER_FAILED,
      detail: e.message,
    };
  }
}

/**
 * Check if the command uses unparseable body syntax (heredoc, process
 * substitution, or command substitution in the body argument). These forms
 * are too dynamic to rewrite safely and the caller should use the helper
 * explicitly. Returns true if unparseable.
 * @param {string} cmd
 * @returns {boolean}
 */
function _hasUnparseableBody(cmd) {
  const bodyStart = cmd.search(/--body(?:-file)?(?:=|\s)/);
  const afterBody = bodyStart === -1 ? "" : cmd.slice(bodyStart);
  return (
    /--body(?:-file)?\s*=?\s*(?:<<-?\s*['"]?\w+|<\()/.test(cmd) ||
    afterBody.includes("$(") ||
    /`[^`]*`/.test(afterBody)
  );
}

/**
 * Match the `--body "value"` / `--body 'value'` / `--body=QUOTED` forms.
 * Returns { match, bodyValue, quote } on the first match, or null.
 *
 * Returning null is "no body arg matched" — distinct from a structured
 * failure object; the caller (`tryRepairSignature`) maps null to
 * `BODY_ARG_NO_MATCH`. (t2893)
 * @param {string} cmd
 * @returns {{ match: RegExpMatchArray, bodyValue: string, quote: string } | null}
 */
function _matchBodyArg(cmd) {
  const patterns = [
    { re: /--body\s+"((?:[^"\\]|\\.)*)"/, quote: '"' },
    { re: /--body\s+'((?:[^'\\]|\\.)*)'/, quote: "'" },
    { re: /--body=(['"])((?:(?!\1).)*)\1/, quote: null },
  ];
  for (const pat of patterns) {
    const m = cmd.match(pat.re);
    if (!m) continue;
    const quote = pat.quote !== null ? pat.quote : m[1];
    const bodyValue = pat.quote !== null ? m[1] : m[2];
    return { match: m, bodyValue, quote };
  }
  return null;
}

/**
 * Repair a `--body "VALUE"` form by rewriting the command with sig-augmented
 * body.
 *
 * Returns `{ status: "ok", cmd }` on success or
 * `{ status: "fail", reason, detail }` when the helper failed or the
 * generated signature contains the same delimiter quote as the body
 * (`BODY_ARG_QUOTING`) which would break shell escaping. (t2893)
 * @param {string} cmd
 * @param {{ match: RegExpMatchArray, bodyValue: string, quote: string }} parsed
 * @param {string} helperPath
 * @param {Function} log
 * @returns {{ status: "ok", cmd: string } | { status: "fail", reason: string, detail: string }}
 */
function _repairBodyArg(cmd, parsed, helperPath, log, options = {}) {
  const { match, bodyValue, quote } = parsed;
  const sigResult = _generateSignature(helperPath, bodyValue, log, options);
  if (sigResult.status === "fail") return sigResult;
  const { sig } = sigResult;
  // If sig contains our delimiter quote, rewrite would break escaping —
  // let the block path force explicit helper invocation.
  if (sig.includes(quote)) {
    log("WARN", `Signature contains delimiter quote ${quote}; cannot safely rewrite --body`);
    return {
      status: "fail",
      reason: FAIL_REASON.BODY_ARG_QUOTING,
      detail: `delimiter ${quote}`,
    };
  }
  const fullMatch = match[0];
  const newArg = fullMatch.slice(0, -1) + sig + quote;
  log("INFO", `Auto-appended signature footer to --body arg (t2685)`);
  return { status: "ok", cmd: cmd.replace(fullMatch, newArg) };
}

/**
 * Attempt to append the canonical signature footer to the command's body.
 * Handles `--body "value"`, `--body=value`, and `--body-file path` forms.
 *
 * Returns a structured result so the throw site can name the specific
 * failure cause:
 *   - `{ status: "ok", cmd }` — repair succeeded; cmd may equal input if
 *     the body was already signed.
 *   - `{ status: "fail", reason, detail }` — repair could not be applied;
 *     reason is one of the FAIL_REASON values. (t2893)
 *
 * @param {string} cmd
 * @param {string} scriptsDir
 * @param {Function} log
 * @returns {{ status: "ok", cmd: string } | { status: "fail", reason: string, detail?: string }}
 */
export function tryRepairSignature(cmd, scriptsDir, log, options = {}) {
  if (hasTrustedSignatureSignal(cmd) || isMachineProtocolCommand(cmd)) {
    log("INFO", "Command is exempt or already includes trusted signature signal; no repair needed");
    return { status: "ok", cmd };
  }

  const helperPath = join(scriptsDir, "gh-signature-helper.sh");
  if (_hasUnparseableBody(cmd)) {
    log("WARN", "Command has unparseable body (heredoc/command-sub); refusing auto-repair (t2685)");
    return { status: "fail", reason: FAIL_REASON.UNPARSEABLE_BODY };
  }

  // --body-file PATH form: filesystem-side repair.
  const bodyFileMatch = cmd.match(
    /--body-file(?:=(['"]?)([^\s'"]+)\1|\s+(['"]?)([^\s'"]+)\3)/,
  );
  if (bodyFileMatch) {
    const filePath = bodyFileMatch[2] || bodyFileMatch[4];
    return repairBodyFile(cmd, filePath, helperPath, log, {
      commandWorkdir: options.commandWorkdir,
      sigMarker: SIG_MARKER,
      isMachineProtocolCommand,
      generateSignature: (path, body, signatureLog) =>
        _generateSignature(path, body, signatureLog, options),
    });
  }

  // --body VALUE form: command-side repair.
  const helperAvailable = existsSync(helperPath);
  const parsed = helperAvailable ? _matchBodyArg(cmd) : null;
  if (!helperAvailable || !parsed) {
    const reason = helperAvailable ? FAIL_REASON.BODY_ARG_NO_MATCH : FAIL_REASON.HELPER_MISSING;
    const detail = helperAvailable ? undefined : helperPath;
    log("WARN", helperAvailable
      ? "Could not parse --body argument; refusing auto-repair"
      : `gh-signature-helper.sh not found at ${helperPath}; cannot repair`);
    return { status: "fail", reason, ...(detail ? { detail } : {}) };
  }
  return _repairBodyArg(cmd, parsed, helperPath, log, options);
}

/**
 * Check signature footer gate on gh write commands (GH#12805, t1755, t2685, t2893).
 * @param {string} cmd - Bash command string
 * @param {Function} log - Quality logger function
 * @param {string} scriptsDir - Path to .agents/scripts (for helper invocation)
 * @param {object} output - Tool output (mutated on successful repair)
 */
export function checkSignatureFooterGate(cmd, log, scriptsDir, output, options = {}) {
  if (!isGhWriteCommand(cmd)) return;
  if (isMachineProtocolCommand(cmd)) return;
  if (hasTrustedSignatureSignal(cmd)) return;

  // Transparent repair — the common case: model pasted a gh write command
  // without thinking about the footer. Mutate the command in place so the
  // user/session gets correct output without an error-retry cycle.
  if (scriptsDir && output && output.args) {
    const commandWorkdir = output.args.workdir || output.args.cwd || process.cwd();
    const result = tryRepairSignature(cmd, scriptsDir, log, {
      commandWorkdir,
      model: options.model,
      useProcessModelFallback: options.useProcessModelFallback,
    });
    if (result.status === "ok") {
      if (result.cmd !== cmd) {
        output.args.command = result.cmd;
      }
      return;
    }

    // Repair failed — block the tool call with a mentoring error message
    // that names the SPECIFIC failure cause (t2893). The throw propagates
    // up through opencode's tool execution path and surfaces to the
    // session/model as a tool_error, which means the next attempt can
    // correct itself with knowledge of the actual cause.
    const snippet = cmd.length > 300 ? cmd.substring(0, 300) + "…" : cmd;
    log(
      "ERROR",
      `Blocked gh write missing signature footer (t2685): ${result.reason}` +
        (result.detail ? ` (${result.detail})` : "") +
        ` | cmd: ${snippet}`,
    );
    throw new Error(formatGateThrowMessage(result, snippet));
  }
}
