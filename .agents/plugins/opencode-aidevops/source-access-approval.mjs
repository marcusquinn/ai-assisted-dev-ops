// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, parse, relative, resolve, sep } from "node:path";

export const SOURCE_ACCESS_REASON = "secret-bearing basename";
const RECEIPT_SCHEMA = "aidevops-source-access-receipt/v1";
const PAYLOAD_SCHEMA = "aidevops-source-access-approval/v1";
const SIGNATURE_NAMESPACE = "aidevops-source-access-v1";
const SIGNER_IDENTITY = "source-access@aidevops.sh";
const MAX_TTL_SECONDS = 12 * 60 * 60;
const MAX_SOURCE_BYTES = 10 * 1024 * 1024;
const DEFAULT_STATE_DIR = "/var/run/aidevops/source-access";
const DEFAULT_PUBLIC_KEY = "/etc/aidevops/source-access/source-access.pub";
const ROOT_BROKER = "/etc/aidevops/source-access/source-access-helper.py";

function readPath(args) {
  return args?.filePath || args?.file_path || "";
}

function runSourceAccessHelper(scriptsDir, helperArgs, run = execFileSync) {
  const helperPath = join(scriptsDir, "source-access-helper.sh");
  return String(
    run("/bin/bash", [helperPath, ...helperArgs], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 15000,
    }),
  ).trim();
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stableValue(value[key])]),
    );
  }
  return value;
}

export function canonicalReceiptPayload(payload) {
  return JSON.stringify(stableValue(payload));
}

function trustedRegularFile(filePath, trustUid) {
  try {
    const metadata = lstatSync(filePath);
    return (
      metadata.isFile() &&
      !metadata.isSymbolicLink() &&
      metadata.uid === trustUid &&
      (metadata.mode & 0o022) === 0
    );
  } catch {
    return false;
  }
}

function trustedDirectory(directoryPath, trustUid) {
  try {
    const metadata = lstatSync(directoryPath);
    return (
      metadata.isDirectory() &&
      !metadata.isSymbolicLink() &&
      metadata.uid === trustUid &&
      (metadata.mode & 0o022) === 0
    );
  } catch {
    return false;
  }
}

function hasSymlinkComponent(filePath) {
  const absolute = resolve(filePath);
  const root = parse(absolute).root;
  let current = root;
  for (const part of absolute.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, part);
    try {
      if (lstatSync(current).isSymbolicLink()) return true;
    } catch {
      return false;
    }
  }
  return false;
}

function approvalScopeId(sessionId, uid, filePath, reason) {
  return createHash("sha256")
    .update(`${sessionId}\0${uid}\0${filePath}\0${reason}`, "utf8")
    .digest("hex");
}

function isGitTrackedFile(filePath, git, run = execFileSync) {
  try {
    const gitRoot = realpathSync(
      String(
        run(git, ["-C", dirname(filePath), "rev-parse", "--show-toplevel"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
          timeout: 15000,
        }),
      ).trim(),
    );
    const relativePath = relative(gitRoot, filePath);
    if (!relativePath || relativePath.startsWith(`..${sep}`) || isAbsolute(relativePath)) return false;
    run(git, ["-C", gitRoot, "ls-files", "--error-unmatch", "--", relativePath], {
      encoding: "utf8",
      stdio: ["ignore", "ignore", "ignore"],
      timeout: 15000,
    });
    return true;
  } catch {
    return false;
  }
}

function verificationTempRoot() {
  return process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp");
}

function isManagedSnapshotPath(filePath) {
  if (!isAbsolute(filePath)) return false;
  const snapshotRoot = join(DEFAULT_STATE_DIR, "snapshots");
  try {
    const canonicalRoot = realpathSync(snapshotRoot);
    const canonicalPath = realpathSync(filePath);
    return canonicalPath.startsWith(`${canonicalRoot}${sep}`);
  } catch {
    return resolve(filePath).startsWith(`${resolve(snapshotRoot)}${sep}`);
  }
}

function sourceDigestMatches(filePath, expectedDigest) {
  let descriptor = -1;
  try {
    descriptor = openSync(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    const opened = fstatSync(descriptor);
    if (!opened.isFile() || opened.nlink !== 1 || opened.size > MAX_SOURCE_BYTES) return false;
    const content = readFileSync(descriptor);
    if (content.length > MAX_SOURCE_BYTES) return false;
    const current = lstatSync(filePath);
    if (
      !current.isFile() ||
      current.isSymbolicLink() ||
      current.dev !== opened.dev ||
      current.ino !== opened.ino
    ) {
      return false;
    }
    return createHash("sha256").update(content).digest("hex") === expectedDigest;
  } catch {
    return false;
  } finally {
    if (descriptor >= 0) closeSync(descriptor);
  }
}

function requireValidReceipt(condition) {
  if (!condition) throw new Error("source-access receipt is invalid");
}

function validatedReceipt(options) {
  const {
    sessionId,
    filePath,
    reason,
    now = Math.floor(Date.now() / 1000),
    uid = typeof process.getuid === "function" ? process.getuid() : -1,
    trustUid = 0,
    stateDir = DEFAULT_STATE_DIR,
    publicKeyPath = DEFAULT_PUBLIC_KEY,
    sshKeygen = "/usr/bin/ssh-keygen",
    git = "/usr/bin/git",
    gitRun = execFileSync,
    run = execFileSync,
  } = options;
  requireValidReceipt(/^[A-Za-z0-9._:-]{6,256}$/.test(sessionId));
  requireValidReceipt(reason === SOURCE_ACCESS_REASON);
  requireValidReceipt(uid >= 0);
  requireValidReceipt(isAbsolute(filePath));
  requireValidReceipt(!hasSymlinkComponent(filePath));
  const canonicalPath = realpathSync(filePath);
  requireValidReceipt(statSync(canonicalPath).isFile());
  requireValidReceipt(isGitTrackedFile(canonicalPath, git, gitRun));
  const approvalId = approvalScopeId(sessionId, uid, canonicalPath, reason);
  const receiptPath = join(stateDir, "approvals", String(uid), `${approvalId}.json`);
  requireValidReceipt(trustedDirectory(dirname(receiptPath), trustUid));
  requireValidReceipt(trustedDirectory(dirname(publicKeyPath), trustUid));
  requireValidReceipt(trustedRegularFile(receiptPath, trustUid));
  requireValidReceipt(trustedRegularFile(publicKeyPath, trustUid));

  const receipt = JSON.parse(readFileSync(receiptPath, "utf8"));
  const payload = receipt?.payload;
  requireValidReceipt(receipt?.schema === RECEIPT_SCHEMA);
  requireValidReceipt(payload?.schema === PAYLOAD_SCHEMA);
  requireValidReceipt(payload.approval_id === approvalId);
  requireValidReceipt(payload.session_id === sessionId);
  requireValidReceipt(payload.uid === uid);
  requireValidReceipt(payload.path === canonicalPath);
  requireValidReceipt(payload.reason === reason);
  requireValidReceipt(/^[a-f0-9]{64}$/.test(payload.content_sha256 || ""));
  requireValidReceipt(sourceDigestMatches(canonicalPath, payload.content_sha256));
  const snapshotPath = join(stateDir, "snapshots", String(uid), `${approvalId}.source`);
  requireValidReceipt(payload.snapshot_path === snapshotPath);
  requireValidReceipt(trustedDirectory(dirname(snapshotPath), trustUid));
  requireValidReceipt(trustedRegularFile(snapshotPath, trustUid));
  requireValidReceipt(statSync(snapshotPath).size <= MAX_SOURCE_BYTES);
  const snapshotDigest = createHash("sha256").update(readFileSync(snapshotPath)).digest("hex");
  requireValidReceipt(snapshotDigest === payload.content_sha256);
  requireValidReceipt(Number.isInteger(payload.issued_at));
  requireValidReceipt(Number.isInteger(payload.expires_at));
  requireValidReceipt(now >= payload.issued_at);
  requireValidReceipt(now < payload.expires_at);
  requireValidReceipt(payload.expires_at - payload.issued_at <= MAX_TTL_SECONDS);
  requireValidReceipt(typeof receipt.signature === "string");
  requireValidReceipt(receipt.signature.includes("SSH SIGNATURE"));
  return {payload, publicKeyPath, receipt, run, snapshotPath, sshKeygen};
}

function verifyReceiptSignature({payload, publicKeyPath, receipt, run, snapshotPath, sshKeygen}) {
  const tempRoot = verificationTempRoot();
  mkdirSync(tempRoot, { recursive: true, mode: 0o700 });
  const tempDir = mkdtempSync(join(tempRoot, "source-access-verify-"));
  try {
    chmodSync(tempDir, 0o700);
    const signaturePath = join(tempDir, "payload.sig");
    const allowedSignersPath = join(tempDir, "allowed_signers");
    writeFileSync(signaturePath, receipt.signature, { mode: 0o600 });
    const publicKey = readFileSync(publicKeyPath, "utf8").trim();
    writeFileSync(
      allowedSignersPath,
      `${SIGNER_IDENTITY} namespaces="${SIGNATURE_NAMESPACE}" ${publicKey}\n`,
      { mode: 0o600 },
    );
    run(
      sshKeygen,
      [
        "-Y",
        "verify",
        "-f",
        allowedSignersPath,
        "-I",
        SIGNER_IDENTITY,
        "-n",
        SIGNATURE_NAMESPACE,
        "-s",
        signaturePath,
      ],
      {
        input: canonicalReceiptPayload(payload),
        encoding: "utf8",
        stdio: ["pipe", "ignore", "ignore"],
        timeout: 15000,
      },
    );
    return { approvedPath: snapshotPath };
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

/** Verify a root-owned receipt directly inside the already-loaded plugin. */
export function verifySourceAccessReceipt(options) {
  try {
    return verifyReceiptSignature(validatedReceipt(options));
  } catch {
    return false;
  }
}

/**
 * Preserve the existing source-read guard while allowing one exact, signed scope.
 * Every verifier or request failure falls back to the unchanged guard.
 */
export function checkSecretReadWithApproval({
  tool,
  args,
  sessionId,
  scriptsDir,
  isReadTool,
  secretReadBlockReason,
  checkSecretReadGate,
  log = () => {},
  verify = verifySourceAccessReceipt,
  requestRun = execFileSync,
}) {
  const filePath = readPath(args);
  if (!isReadTool(tool) || !filePath) {
    checkSecretReadGate(tool, args, log);
    return;
  }

  if (isManagedSnapshotPath(filePath)) {
    throw new Error("[source-access] direct reads of approval snapshots are denied");
  }

  const reason = secretReadBlockReason(filePath);
  if (reason !== SOURCE_ACCESS_REASON || !sessionId || !scriptsDir) {
    checkSecretReadGate(tool, args, log);
    return;
  }

  const approval = verify({ sessionId, filePath, reason });
  if (approval?.approvedPath) {
    if (Object.hasOwn(args, "filePath")) args.filePath = approval.approvedPath;
    if (Object.hasOwn(args, "file_path")) args.file_path = approval.approvedPath;
    log("INFO", `[source-access] verified session-bound read approval for ${filePath}`);
    return;
  }

  let requestId = "";
  try {
    requestId = runSourceAccessHelper(
      scriptsDir,
      ["request", "--session", sessionId, "--path", filePath, "--reason", reason],
      requestRun,
    );
  } catch {
    // Request generation is advisory; the original guard remains authoritative.
  }

  try {
    checkSecretReadGate(tool, args, log);
  } catch (error) {
    if (!requestId) throw error;
    const originalMessage = error instanceof Error ? error.message : String(error);
    throw new Error(
      `${originalMessage}\n\nTo approve only this tracked source path for this session, run:\n` +
        `sudo -k /usr/bin/python3 ${ROOT_BROKER} approve ${requestId} --ttl 12h`,
    );
  }
}
