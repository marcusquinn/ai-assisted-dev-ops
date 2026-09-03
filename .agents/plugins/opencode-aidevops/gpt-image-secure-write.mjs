// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { fileURLToPath } from "node:url";
import { isAbsolute, join } from "node:path";
import { runImageWriter } from "./gpt-image-writer-process.mjs";

const DEFAULT_HELPER = fileURLToPath(new URL("../../scripts/gpt-image-secure-write.py", import.meta.url));

function pathIsSafe(path) {
  if (typeof path !== "string" || !path || isAbsolute(path)) return false;
  const parts = path.split(/[\\/]+/);
  if (parts.some((part) => !part || part === "." || part === "..")) return false;
  return parts[0].toLowerCase() !== ".git";
}

function parseWriterOutput(stdout) {
  let result;
  try {
    result = JSON.parse(stdout);
  } catch {
    throw new Error("Secure image writer returned an invalid receipt.");
  }
  const path = result?.path;
  if (!pathIsSafe(path)) throw new Error("Secure image writer returned an unsafe output path.");
  return {
    cleanupWarning: result.cleanup_warning === true,
    projectPath: path,
    versioned: result.versioned === true,
  };
}

export async function secureWriteGeneratedImage(buffer, out, projectRoot, options = {}) {
  const helper = options.scriptsDir ? join(options.scriptsDir, "gpt-image-secure-write.py") : DEFAULT_HELPER;
  const stdout = await runImageWriter(helper, buffer, out, projectRoot, options.spawnImpl);
  return parseWriterOutput(stdout);
}
