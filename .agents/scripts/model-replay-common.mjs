// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fstatSync,
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
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const CORPUS_SCHEMA = "aidevops-model-replay-corpus/v1";
export const CASE_SCHEMA = "aidevops-model-replay-case/v1";
export const CATALOG_SCHEMA = "aidevops-model-replay-repositories/v1";
export const QUALIFICATION_SCHEMA = "aidevops-model-replay-qualification/v1";
export const POLICY_VERSION = "model-replay-policy-v1";
export const TIERS = ["simple", "standard", "thinking"];
export const MODES = ["autonomous", "prescriptive"];

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "../..");

function compareEntryKeys([left], [right]) {
  return left < right ? -1 : Number(left > right);
}

function sortedValue(value) {
  if (Array.isArray(value)) return value.map(sortedValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).sort(compareEntryKeys)
        .map(([key, entryValue]) => [key, sortedValue(entryValue)]),
    );
  }
  return value;
}

function charactersAreAllowed(value, characters) {
  return [...value].every((character) => characters.includes(character));
}

export function isFullCommitSHA(value) {
  const text = String(value || "");
  if (text.length !== 40 && text.length !== 64) return false;
  return charactersAreAllowed(text, "0123456789abcdef");
}

export function stableJson(value) {
  return `${JSON.stringify(sortedValue(value), null, 2)}\n`;
}

export function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function sha256File(path) {
  return sha256(readFileSync(path));
}

export function harnessIdentity() {
  const versionPath = join(REPO_ROOT, "VERSION");
  return {
    policy_version: POLICY_VERSION,
    framework_version: existsSync(versionPath) ? readFileSync(versionPath, "utf8").trim() : "unknown",
    node_version: process.version,
  };
}

export function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Cannot read JSON ${path}: ${error.message}`);
  }
}

export function writePrivateFile(path, value, mode = 0o600) {
  const parent = dirname(path);
  mkdirSync(parent, { recursive: true, mode: 0o700 });
  const parentMetadata = lstatSync(parent);
  if (!parentMetadata.isDirectory() || parentMetadata.isSymbolicLink()) {
    throw new Error(`Refusing to write through a non-directory parent: ${parent}`);
  }
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, value, { flag: "wx", mode });
    chmodSync(temporary, mode);
    renameSync(temporary, path);
  } finally {
    rmSync(temporary, { force: true });
  }
  return path;
}

export function writeJson(path, value, mode = 0o600) {
  return writePrivateFile(path, stableJson(value), mode);
}

export function appendJsonLine(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  let descriptor;
  try {
    descriptor = openSync(
      path,
      constants.O_WRONLY | constants.O_CREAT | constants.O_APPEND | constants.O_NOFOLLOW,
      0o600,
    );
    const metadata = fstatSync(descriptor);
    if (!metadata.isFile() || metadata.nlink !== 1) {
      throw new Error(`Refusing to append through a linked or non-regular path: ${path}`);
    }
    writeSync(descriptor, `${JSON.stringify(value)}\n`);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
  chmodSync(path, 0o600);
  return 0;
}

export function assertSafeID(value, label = "identifier") {
  const identifier = String(value || "");
  const first = identifier[0] || "";
  const valid = identifier.length >= 3 && identifier.length <= 80
    && "abcdefghijklmnopqrstuvwxyz0123456789".includes(first)
    && charactersAreAllowed(identifier, "abcdefghijklmnopqrstuvwxyz0123456789._-");
  if (!valid) {
    throw new Error(`${label} must match ^[a-z0-9][a-z0-9._-]{2,79}$`);
  }
  return identifier;
}

export function pathInside(root, child) {
  const requestedRoot = resolve(root);
  const requestedChild = resolve(child);
  const rel = relative(requestedRoot, requestedChild);
  if (!rel || rel.startsWith("..") || isAbsolute(rel)) {
    throw new Error(`Unsafe path outside owned root: ${requestedChild}`);
  }
  const canonicalRoot = existsSync(requestedRoot) ? realpathSync(requestedRoot) : requestedRoot;
  let current = canonicalRoot;
  for (const component of rel.split(sep)) {
    current = join(current, component);
    if (existsSync(current) && lstatSync(current).isSymbolicLink()) {
      throw new Error(`Unsafe symlink inside owned root: ${current}`);
    }
  }
  return join(canonicalRoot, rel);
}

export function regularFileInside(root, requested, label) {
  const path = pathInside(root, join(root, requested));
  if (!existsSync(path) || !lstatSync(path).isFile()) {
    throw new Error(`${label} is not a regular file: ${requested}`);
  }
  return path;
}
