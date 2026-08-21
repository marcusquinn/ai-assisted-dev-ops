// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { lstatSync, realpathSync } from "fs";
import { basename, dirname, resolve } from "path";

function normalizePathPattern(value) {
  return typeof value === "string" ? value.replaceAll("\\", "/") : "";
}

function pathHasSymlinkComponent(target) {
  let current = resolve(target);
  try {
    while (true) {
      if (lstatSync(current).isSymbolicLink()) return true;
      const parent = dirname(current);
      if (parent === current) return false;
      current = parent;
    }
  } catch {
    return true;
  }
}

function hasExactToolOutputPattern(raw, directory) {
  const expected = `${normalizePathPattern(directory)}/*`;
  const input = raw?.patterns ?? raw?.pattern;
  const patterns = Array.isArray(input) ? input : input == null ? [] : [input];
  return patterns.length === 1 && normalizePathPattern(patterns[0]) === expected;
}

function managedToolOutputPath(raw, directory) {
  const filepath = raw?.metadata?.filepath || "";
  const parentDir = raw?.metadata?.parentDir || "";
  if (!filepath || !parentDir || resolve(parentDir) !== directory || dirname(resolve(filepath)) !== directory) return "";
  return basename(filepath).startsWith("tool_") ? filepath : "";
}

function isSafeManagedToolOutputFile(filepath, directory) {
  try {
    const info = lstatSync(filepath);
    return info.isFile()
      && !info.isSymbolicLink()
      && !pathHasSymlinkComponent(directory)
      && dirname(realpathSync(filepath)) === realpathSync(directory);
  } catch {
    return false;
  }
}

// OpenCode 1.18.21 normally allows its exact Truncate.GLOB without a plugin.
// Retain this fail-closed fallback for runtimes that still emit the equivalent
// external_directory event. It deliberately does not bridge symlinked paths.
export function isManagedToolOutputRead(toolCalls, raw, dataHome) {
  const permission = raw?.permission || raw?.type || "";
  const callID = raw?.tool?.callID || raw?.callID || "";
  if (permission !== "external_directory" || toolCalls.get(callID)?.tool !== "read") return false;

  const directory = resolve(dataHome, "opencode", "tool-output");
  if (!hasExactToolOutputPattern(raw, directory)) return false;
  const filepath = managedToolOutputPath(raw, directory);
  return Boolean(filepath) && isSafeManagedToolOutputFile(filepath, directory);
}
