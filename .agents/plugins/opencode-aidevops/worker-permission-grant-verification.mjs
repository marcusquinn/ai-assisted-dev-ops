// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Cryptographic envelope verification for scoped worker permission grants.

import { existsSync, readFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { execFileSync } from "child_process";

function readPermissionGrantFile(grantPath) {
  try {
    return JSON.parse(readFileSync(grantPath, "utf8"));
  } catch {
    return null;
  }
}

function parsePermissionGrantPayload(payload) {
  try {
    return JSON.parse(payload);
  } catch {
    return null;
  }
}

function verifyPermissionGrantSignature(grant, publicKey, tempBase) {
  let verifyDir = "";
  let verified = false;
  try {
    mkdirSync(tempBase, { recursive: true });
    verifyDir = mkdtempSync(join(tempBase, "permission-grant-"));
    const signaturePath = join(verifyDir, "signature");
    const signersPath = join(verifyDir, "allowed-signers");
    writeFileSync(signaturePath, grant.signature, { mode: 0o600 });
    const key = readFileSync(publicKey, "utf8").trim();
    writeFileSync(signersPath, `approval@aidevops.sh namespaces="aidevops-approve" ${key}\n`, { mode: 0o600 });
    execFileSync("ssh-keygen", [
      "-Y", "verify", "-f", signersPath, "-I", "approval@aidevops.sh",
      "-n", "aidevops-approve", "-s", signaturePath,
    ], { input: grant.payload, stdio: ["pipe", "ignore", "ignore"] });
    verified = true;
  } catch {
    verified = false;
  } finally {
    if (verifyDir) {
      try {
        rmSync(verifyDir, { recursive: true, force: true });
      } catch {
        // Verification already completed; temporary cleanup remains best effort.
      }
    }
  }
  return verified;
}

function permissionGrantPrerequisiteReason(grantPath, publicKey) {
  if (!grantPath) return "grant_path_unset";
  if (!existsSync(grantPath)) return "grant_file_missing";
  if (!existsSync(publicKey)) return "approval_public_key_missing";
  return "";
}

export function verifyPermissionGrant(grantPath, options = {}) {
  const publicKey = options.publicKey || join(homedir(), ".aidevops", "approval-keys", "approval.pub");
  const prerequisiteReason = permissionGrantPrerequisiteReason(grantPath, publicKey);
  if (prerequisiteReason) return { grant: null, reason: prerequisiteReason };
  const grant = readPermissionGrantFile(grantPath);
  if (typeof grant?.payload !== "string" || typeof grant?.signature !== "string") {
    return { grant: null, reason: "grant_envelope_invalid" };
  }
  const tempBase = options.tempBase || process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
  if (!verifyPermissionGrantSignature(grant, publicKey, tempBase)) {
    return { grant: null, reason: "grant_signature_invalid" };
  }
  const payload = parsePermissionGrantPayload(grant.payload);
  if (!payload) return { grant: null, reason: "grant_payload_invalid" };
  return { grant: payload, reason: "verified" };
}
