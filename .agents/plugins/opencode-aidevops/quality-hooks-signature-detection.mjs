// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Signature footer gate detection helpers. Extracted from
// quality-hooks-signature.mjs so the gate orchestrator keeps only repair and
// enforcement flow while command-shape detection remains independently tested
// through the existing public re-exports.

export const SIG_MARKER = "<!-- aidevops:sig -->";

/**
 * Strip heredoc body lines from a multi-line command string.
 * Lines inside <<MARKER ... MARKER blocks are removed so that prose inside a
 * heredoc body cannot trigger false-positive gh-write detection (GH#20735).
 * @param {string} cmd
 * @returns {string} cmd with heredoc body lines removed
 */
function stripHeredocBodies(cmd) {
  const lines = cmd.split("\n");
  const result = [];
  let terminator = null;
  for (const line of lines) {
    if (terminator !== null) {
      if (line.trim() === terminator) {
        terminator = null;
      }
      continue;
    }
    const match = line.match(/<<-?\s*['"]?([\w-]+)['"]?/);
    if (match) {
      terminator = match[1];
    }
    result.push(line);
  }
  return result.join("\n");
}

/**
 * Strip balanced single and double quoted strings from a shell line so quoted
 * prose containing `gh issue create` remains invisible to command detection.
 * @param {string} line
 * @returns {string}
 */
function stripQuotedStrings(line) {
  const withoutDouble = line.replace(/"(?:[^"\\]|\\.)*"/g, (quoted) => {
    const substitutions = quoted.match(/\$\((?:[^()]|\([^()]*\))*\)/g) ?? [];
    return `""${substitutions.join(" ")}`;
  });
  return withoutDouble.replace(/'[^']*'/g, "''");
}

function isCommentLine(trimmedLine) {
  return trimmedLine.startsWith("#");
}

function hasExplicitShimBypassWrite(trimmedLine) {
  const bypassPrefix =
    /(^|[;&|(`!]|\$\()\s*AIDEVOPS_GH_SHIM_DISABLE=.*\bgh\s+/;
  if (!bypassPrefix.test(trimmedLine)) return false;
  return (
    /\bgh\s+(?:pr\s+(?:create|comment)|issue\s+(?:create|comment))\b/.test(
      trimmedLine,
    ) ||
    (/\bgh\s+issue\s+close\b/.test(trimmedLine) &&
      /(?:^|\s)(?:--comment(?:=|\s)|-c(?:=|\s))/.test(trimmedLine))
  );
}

function lineHasGhWriteCommand(line, ghWritePattern, ghIssueClosePattern) {
  const trimmed = line.trim();
  if (isCommentLine(trimmed)) return false;
  if (hasExplicitShimBypassWrite(trimmed)) return true;
  const command = stripQuotedStrings(trimmed);
  if (ghWritePattern.test(command)) return true;
  // A close without a comment is a state-only mutation and must retain native
  // behaviour. A close with --comment/-c publishes content and therefore needs
  // the same signature gate as issue comment/create.
  return (
    ghIssueClosePattern.test(command) &&
    /(?:^|\s)(?:--comment(?:=|\s)|-c(?:=|\s))/.test(command)
  );
}

/**
 * Decide whether a given bash command is a gh write that needs sig enforcement.
 * @param {string} cmd - Raw bash command string (may be multi-line)
 * @returns {boolean}
 */
export function isGhWriteCommand(cmd) {
  if (typeof cmd !== "string") return false;
  const assignment = String.raw`[A-Za-z_][A-Za-z0-9_]*=(?:\$\((?:[^()]|\([^()]*\))*\)|\S*)`;
  const prefix = String.raw`(?:(?:${assignment}|sudo|command(?:\s+-\S+)*|time(?:\s+-\S+)*|env(?:\s+(?:(?:-\S+)(?:\s+\S+)?|${assignment}))*)\s+)*`;
  const boundary = String.raw`(^|[;&|(` + "!" + String.raw`]|\$\()`;
  const ghWritePattern = new RegExp(
    String.raw`${boundary}\s*${prefix}gh\s+(pr\s+(create|comment)|issue\s+(create|comment))\b`,
  );
  const ghIssueClosePattern = new RegExp(
    String.raw`${boundary}\s*${prefix}gh\s+issue\s+close\b`,
  );
  return stripHeredocBodies(cmd)
    .split("\n")
    .some((line) => lineHasGhWriteCommand(line, ghWritePattern, ghIssueClosePattern));
}

/**
 * Machine-protocol comments that are exempt from sig enforcement.
 * @param {string} cmd
 * @returns {boolean}
 */
export function isMachineProtocolCommand(cmd) {
  if (typeof cmd !== "string") return false;
  return /DISPATCH_CLAIM|KILL_WORKER|DISPATCH_ACK|<!-- MERGE_SUMMARY -->/.test(cmd);
}

/**
 * Good-path signal: direct helper use, canonical marker, or footer variable.
 * @param {string} cmd
 * @returns {boolean}
 */
export function hasTrustedSignatureSignal(cmd) {
  if (typeof cmd !== "string") return false;
  return (
    cmd.includes("gh-signature-helper.sh") ||
    cmd.includes("gh-signature-helper ") ||
    cmd.includes(SIG_MARKER) ||
    /\$\{?\w*(?:footer|FOOTER|signature|SIGNATURE)\w*\}?/i.test(cmd)
  );
}
