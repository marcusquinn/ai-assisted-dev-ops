// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {closeSync, constants, fstatSync, lstatSync, openSync, readSync} from "node:fs";
import {homedir} from "node:os";
import {isAbsolute, join, parse, resolve, sep} from "node:path";

export class TeamInterfaceError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "TeamInterfaceError";
    this.code = code;
  }
}

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    const entries = Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`);
    return `{${entries.join(",")}}`;
  }
  return JSON.stringify(value);
}

export function canonicalDigest(value) {
  return `sha256:${createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
}

export function compareCanonicalText(left, right) {
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

export function existingPathStats(filePath) {
  try {
    return lstatSync(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

export function assertNoSymlinkComponents(filePath) {
  const absolutePath = resolve(filePath);
  const root = parse(absolutePath).root;
  let current = root;
  for (const component of absolutePath.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, component);
    const stats = existingPathStats(current);
    if (!stats) break;
    if (stats.isSymbolicLink()) throw new TeamInterfaceError("unsafe_path", "runtime path must not traverse symbolic links");
  }
}

export function expandRuntimePath(filePath, baseDirectory = process.cwd()) {
  if (typeof filePath !== "string" || filePath.length === 0 || filePath.includes("\0")) {
    throw new TeamInterfaceError("invalid_path", "runtime path is invalid");
  }
  let expanded = filePath;
  if (filePath === "~") expanded = homedir();
  else if (filePath.startsWith("~/")) expanded = join(homedir(), filePath.slice(2));
  else if (filePath.startsWith("~")) throw new TeamInterfaceError("invalid_path", "named-home expansion is unsupported");
  return resolve(isAbsolute(expanded) ? expanded : join(baseDirectory, expanded));
}

function openRuntimeDocument(filePath, label) {
  try {
    return openSync(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
  } catch (error) {
    if (error?.code === "ENOENT") throw new TeamInterfaceError("missing_document", `${label} is missing`);
    if (["ELOOP", "EMLINK"].includes(error?.code)) {
      throw new TeamInterfaceError("unsafe_path", `${label} must not be a symbolic link`);
    }
    throw error;
  }
}

function assertOpenedDocument(filePath, descriptor, maxBytes, label) {
  const stats = fstatSync(descriptor);
  if (!stats.isFile()) throw new TeamInterfaceError("invalid_path", `${label} must be a regular file`);
  if (stats.size > maxBytes) throw new TeamInterfaceError("document_too_large", `${label} exceeds its size limit`);
  assertNoSymlinkComponents(filePath);
  const currentStats = existingPathStats(filePath);
  if (!currentStats) throw new TeamInterfaceError("unsafe_path", `${label} changed while it was opened`);
  if (currentStats.isSymbolicLink()) throw new TeamInterfaceError("unsafe_path", `${label} changed while it was opened`);
  if (currentStats.dev !== stats.dev) throw new TeamInterfaceError("unsafe_path", `${label} changed while it was opened`);
  if (currentStats.ino !== stats.ino) throw new TeamInterfaceError("unsafe_path", `${label} changed while it was opened`);
}

function readDescriptorText(descriptor, maxBytes, label) {
  const buffer = Buffer.allocUnsafe(maxBytes + 1);
  let bytesRead = 0;
  while (bytesRead < buffer.length) {
    const count = readSync(descriptor, buffer, bytesRead, buffer.length - bytesRead, null);
    if (count === 0) break;
    bytesRead += count;
  }
  if (bytesRead > maxBytes) throw new TeamInterfaceError("document_too_large", `${label} exceeds its size limit`);
  return buffer.subarray(0, bytesRead).toString("utf8");
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    if (error instanceof SyntaxError) throw new TeamInterfaceError("invalid_json", `${label} is not valid JSON`);
    throw error;
  }
}

export function readBoundedJson(filePath, maxBytes, label) {
  assertNoSymlinkComponents(filePath);
  const descriptor = openRuntimeDocument(filePath, label);
  try {
    assertOpenedDocument(filePath, descriptor, maxBytes, label);
    return parseJson(readDescriptorText(descriptor, maxBytes, label), label);
  } finally {
    closeSync(descriptor);
  }
}

export function assertUniqueIds(records, property, label) {
  const ids = records.map((record) => record[property]);
  if (new Set(ids).size !== ids.length) throw new TeamInterfaceError("duplicate_identity", `${label} contains duplicate ${property} values`);
}

export function deepFreeze(value) {
  if (!value || typeof value !== "object") return value;
  for (const child of Object.values(value)) deepFreeze(child);
  return Object.isFrozen(value) ? value : Object.freeze(value);
}

export function requireTimestamp(value, label) {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) throw new TeamInterfaceError("invalid_timestamp", `${label} is invalid`);
  return timestamp;
}
