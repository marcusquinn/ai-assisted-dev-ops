// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

export function scalar(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function withinRoot(path, root) {
  return path === root || path.startsWith(`${root}/`);
}

export function commandError(command) {
  if (!Array.isArray(command) || command.length === 0) return "command must be a non-empty string array";
  if (command.some((part) => typeof part !== "string" || !part || part.includes("\0"))) {
    return "command entries must be non-empty strings without NUL bytes";
  }
  if (Buffer.byteLength(JSON.stringify(command)) > 64 * 1024) return "encoded command exceeds 64 KiB";
  return "";
}

export function boundedInteger(value, fallback, minimum, maximum) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.floor(parsed)));
}

export function canTerminate(operation) {
  if (!operation.child) return false;
  if (operation.childExited) return false;
  if (operation.child.exitCode !== null) return false;
  if (operation.child.signalCode !== null) return false;
  return ["running", "starting"].includes(operation.state);
}
