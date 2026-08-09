// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  chmodSync,
  closeSync,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const SESSION_ID_RE = /^ses_[A-Za-z0-9]{6,128}$/;
const CONTROL_CHAR_RE = /[\u0000-\u001F\u007F]/;
const MARKER_BASENAME = "recovery.json";

function pathIsInside(parent, candidate) {
  const child = relative(parent, candidate);
  return child === "" || (!child.startsWith("..") && !isAbsolute(child));
}

function assertSafeText(value, label) {
  if (typeof value !== "string" || !value || CONTROL_CHAR_RE.test(value)) {
    throw new Error(`Invalid ${label}`);
  }
  return value;
}

function assertPrivateDirectory(path, uid) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o077) !== 0) {
    throw new Error("Unsafe recovery marker directory");
  }
}

function assertPrivateFile(path, uid) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o077) !== 0) {
    throw new Error("Unsafe recovery marker file");
  }
}

function ensurePrivateDirectory(path) {
  if (existsSync(path)) {
    const stat = lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) {
      throw new Error("Unsafe recovery marker directory");
    }
  } else {
    mkdirSync(path, { recursive: true, mode: 0o700 });
  }
  chmodSync(path, 0o700);
  assertPrivateDirectory(path, process.getuid());
}

export function recoveryRoot(workDir) {
  return join(workDir, "opencode-tabby-recovery");
}

export function currentDirectorySequence(directory) {
  const safeDirectory = assertSafeText(directory, "terminal recovery directory");
  return `\u001B]1337;CurrentDir=${safeDirectory}\u0007`;
}

export function writeCurrentDirectory(directory) {
  const sequence = currentDirectorySequence(directory);
  let ttyFd;
  try {
    ttyFd = openSync("/dev/tty", "w");
    writeSync(ttyFd, sequence);
    return true;
  } catch {
    return false;
  } finally {
    if (ttyFd !== undefined) {
      try {
        closeSync(ttyFd);
      } catch {
        // Tabby recovery synchronization is best-effort while OpenCode is live.
      }
    }
  }
}

export function writeSessionRecoveryMarker({ sessionID, directory, dataDir, workDir }) {
  if (!SESSION_ID_RE.test(sessionID)) throw new Error("Invalid OpenCode session ID");
  assertSafeText(directory, "session directory");
  assertSafeText(dataDir, "OpenCode data directory");
  assertSafeText(workDir, "aidevops work directory");
  if (!isAbsolute(directory) || !isAbsolute(dataDir) || !isAbsolute(workDir)) {
    throw new Error("Recovery marker paths must be absolute");
  }

  const canonicalDirectory = realpathSync(directory);
  const canonicalDataDir = realpathSync(dataDir);
  const root = recoveryRoot(resolve(workDir));
  const markerDirectory = join(root, sessionID);
  ensurePrivateDirectory(root);
  ensurePrivateDirectory(markerDirectory);

  const markerPath = join(markerDirectory, MARKER_BASENAME);
  const temporaryPath = join(markerDirectory, `.recovery.${process.pid}.${Date.now()}.tmp`);
  const payload = `${JSON.stringify({
    schema_version: 1,
    session_id: sessionID,
    directory: canonicalDirectory,
    data_dir: canonicalDataDir,
  })}\n`;

  try {
    writeFileSync(temporaryPath, payload, { encoding: "utf8", flag: "wx", mode: 0o600 });
    renameSync(temporaryPath, markerPath);
    chmodSync(markerPath, 0o600);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
  assertPrivateFile(markerPath, process.getuid());
  return markerDirectory;
}

function querySessionDirectory(databasePath, sessionID) {
  const sql = `SELECT directory FROM session WHERE id='${sessionID}' AND parent_id IS NULL LIMIT 2;`;
  const result = spawnSync("sqlite3", ["-readonly", databasePath, sql], {
    encoding: "utf8",
    timeout: 5000,
  });
  if (result.error || result.status !== 0) throw new Error("Could not validate OpenCode recovery database");
  const rows = result.stdout.trimEnd().split("\n").filter(Boolean);
  if (rows.length !== 1) throw new Error("OpenCode recovery session was not found");
  return rows[0];
}

function canonicalMarkerDirectory(cwd, workDir, uid) {
  const root = recoveryRoot(resolve(workDir));
  if (!existsSync(root)) return null;
  if (lstatSync(root).isSymbolicLink()) throw new Error("Invalid recovery marker root");
  const canonicalRoot = realpathSync(root);
  const canonicalCwd = realpathSync(cwd);
  if (!pathIsInside(canonicalRoot, canonicalCwd)) return null;

  if (lstatSync(cwd).isSymbolicLink()) throw new Error("Invalid recovery marker location");
  assertPrivateDirectory(canonicalRoot, uid);
  assertPrivateDirectory(canonicalCwd, uid);
  if (dirname(canonicalCwd) !== canonicalRoot) throw new Error("Invalid recovery marker location");
  return canonicalCwd;
}

function readRecoveryMarker(canonicalCwd, uid) {
  const markerPath = join(canonicalCwd, MARKER_BASENAME);
  assertPrivateFile(markerPath, uid);
  const marker = JSON.parse(readFileSync(markerPath, "utf8"));
  if (marker.schema_version !== 1 || !SESSION_ID_RE.test(marker.session_id)) {
    throw new Error("Invalid recovery marker schema");
  }
  if (basename(canonicalCwd) !== marker.session_id) throw new Error("Recovery marker session mismatch");
  return marker;
}

function canonicalRecoveryDataDir(dataDir, workDir, uid) {
  const dataDirStat = lstatSync(dataDir);
  if (!dataDirStat.isDirectory() || dataDirStat.isSymbolicLink() || dataDirStat.uid !== uid) {
    throw new Error("Unsafe OpenCode recovery data directory");
  }
  const canonicalDataDir = realpathSync(dataDir);
  const isolatedRootPath = join(resolve(workDir), "opencode-interactive");
  const isolatedRootStat = lstatSync(isolatedRootPath);
  if (!isolatedRootStat.isDirectory() || isolatedRootStat.isSymbolicLink() || isolatedRootStat.uid !== uid) {
    throw new Error("Unsafe OpenCode isolated storage root");
  }
  const isolatedRoot = realpathSync(isolatedRootPath);
  if (!pathIsInside(isolatedRoot, canonicalDataDir) || canonicalDataDir === isolatedRoot) {
    throw new Error("Recovery marker data directory is outside isolated storage");
  }
  return canonicalDataDir;
}

function validateRecoveryDatabase(canonicalDataDir, sessionID, canonicalDirectory, uid) {
  const databasePath = join(canonicalDataDir, "opencode", "opencode.db");
  const databaseStat = lstatSync(databasePath);
  if (!databaseStat.isFile() || databaseStat.isSymbolicLink() || databaseStat.uid !== uid) {
    throw new Error("Unsafe OpenCode recovery database");
  }
  const databaseDirectory = querySessionDirectory(databasePath, sessionID);
  if (realpathSync(databaseDirectory) !== canonicalDirectory) {
    throw new Error("Recovery marker directory does not match the OpenCode session");
  }
}

export function resolveSessionRecoveryMarker({ cwd, workDir }) {
  assertSafeText(cwd, "recovered working directory");
  assertSafeText(workDir, "aidevops work directory");
  if (!isAbsolute(cwd) || !isAbsolute(workDir)) throw new Error("Recovery paths must be absolute");

  const uid = process.getuid();
  const canonicalCwd = canonicalMarkerDirectory(cwd, workDir, uid);
  if (!canonicalCwd) return null;
  const marker = readRecoveryMarker(canonicalCwd, uid);
  const directory = assertSafeText(marker.directory, "marker session directory");
  const dataDir = assertSafeText(marker.data_dir, "marker OpenCode data directory");
  if (!isAbsolute(directory) || !isAbsolute(dataDir)) throw new Error("Recovery marker paths must be absolute");
  const canonicalDirectory = realpathSync(directory);
  const canonicalDataDir = canonicalRecoveryDataDir(dataDir, workDir, uid);
  validateRecoveryDatabase(canonicalDataDir, marker.session_id, canonicalDirectory, uid);

  return {
    sessionID: marker.session_id,
    directory: canonicalDirectory,
    dataDir: canonicalDataDir,
    markerDirectory: canonicalCwd,
  };
}

function eventSessionInfo(event) {
  return event?.properties?.info || event?.properties?.session || null;
}

function eventSessionID(event, info) {
  return String(info?.id || info?.sessionID || event?.properties?.sessionID || "");
}

export function createSessionRecoveryMarkerHandler({
  directory,
  dataDir,
  workDir,
  isEnabled = () => process.env.AIDEVOPS_TABBY_SESSION_RECOVERY === "1",
  writeMarker = writeSessionRecoveryMarker,
  writeDirectory = writeCurrentDirectory,
}) {
  const emitted = new Set();
  return async ({ event } = {}) => {
    if (!isEnabled() || !event || !["session.created", "session.updated"].includes(event.type)) return;
    const info = eventSessionInfo(event);
    if (info?.parentID) return;
    const sessionID = eventSessionID(event, info);
    if (!SESSION_ID_RE.test(sessionID) || emitted.has(sessionID)) return;
    const markerDirectory = writeMarker({ sessionID, directory, dataDir, workDir });
    writeDirectory(markerDirectory);
    emitted.add(sessionID);
  };
}

function parseCliArgs(argv) {
  const parsed = parseArgs({
    args: argv,
    options: {
      cwd: { type: "string" },
      "work-dir": { type: "string" },
    },
    strict: true,
  });
  return { cwd: parsed.values.cwd || "", workDir: parsed.values["work-dir"] || "" };
}

function runCli(argv) {
  const [command, ...options] = argv;
  if (command !== "resolve") throw new Error("Expected recovery resolver command");
  const parsed = parseCliArgs(options);
  const workDir = parsed.workDir || join(homedir(), ".aidevops", ".agent-workspace", "work");
  const result = resolveSessionRecoveryMarker({ cwd: parsed.cwd, workDir });
  if (!result) return 2;
  process.stdout.write(`${result.directory}\t${result.dataDir}\t${result.sessionID}\n`);
  return 0;
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`Session recovery marker rejected: ${error.message}\n`);
    process.exitCode = 1;
  }
}
