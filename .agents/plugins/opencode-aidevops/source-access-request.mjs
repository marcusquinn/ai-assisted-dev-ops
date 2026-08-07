// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

export const ROOT_BROKER = "/etc/aidevops/source-access/source-access-helper.py";
const REQUEST_ID_PATTERN = /^[a-f0-9]{32,64}$/;

function runSourceAccessHelper(helperArgs, run) {
  return String(
    run("/usr/bin/python3", ["-I", "-B", ROOT_BROKER, ...helperArgs], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 15000,
    }),
  ).trim();
}

export function brokerMatchesCurrentRelease(brokerMatches, scriptsDir) {
  try {
    return brokerMatches({ scriptsDir });
  } catch {
    return false;
  }
}

export function applyApprovedRead(args, approval, filePath, log) {
  if (!approval?.approvedPath) return false;
  if (Object.hasOwn(args, "filePath")) args.filePath = approval.approvedPath;
  if (Object.hasOwn(args, "file_path")) args.file_path = approval.approvedPath;
  log("INFO", `[source-access] verified session-bound read approval for ${filePath}`);
  return true;
}

export function requestApprovalId({ brokerCurrent, filePath, reason, requestRun, sessionId }) {
  if (!brokerCurrent) return "";
  try {
    const requestId = runSourceAccessHelper(
      ["request", "--session", sessionId, "--path", filePath, "--reason", reason],
      requestRun,
    );
    return REQUEST_ID_PATTERN.test(requestId) ? requestId : "";
  } catch {
    // Request generation is advisory; the original guard remains authoritative.
    return "";
  }
}

export function checkGateWithApprovalInstructions({
  args,
  brokerCurrent,
  checkSecretReadGate,
  filePath,
  log,
  requestId,
  tool,
}) {
  try {
    checkSecretReadGate(tool, args, log);
  } catch (error) {
    const originalMessage = error instanceof Error ? error.message : String(error);
    if (!brokerCurrent) {
      throw new Error(
        `${originalMessage}\n\nThe root-owned source-access broker does not match this release. ` +
          "Run aidevops update from an interactive terminal to reconcile it.",
      );
    }
    if (!requestId) throw error;
    throw new Error(
      `${originalMessage}\n\nTo approve only this tracked source path for this session, run:\n` +
        `sudo -k /usr/bin/python3 -I -B ${ROOT_BROKER} approve ${requestId} --ttl 12h`,
    );
  }
}
