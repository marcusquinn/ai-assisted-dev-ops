// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { lstatSync, readFileSync } from "fs";
import { join } from "path";

const MAX_HOOK_INSPECTION_BYTES = 1024 * 1024;

function readHookStat(hookPath) {
  let hookStat;
  let status = "";
  try {
    hookStat = lstatSync(hookPath);
  } catch {
    status = "missing";
  }
  return { hookStat, status };
}

function classifyHookStat(hookStat) {
  let status = "regular-file";
  if (hookStat.isSymbolicLink()) status = "unsafe-symlink";
  else if (!hookStat.isFile()) status = "unsupported-file-type";
  else if (hookStat.size > MAX_HOOK_INSPECTION_BYTES) status = "oversized";
  return status;
}

export function inspectHookFile(hooksDir, hookName, markers, directorySafe) {
  const markerStatus = Object.fromEntries(Object.keys(markers).map((name) => [name, false]));
  let status = "unsafe-hooks-directory";
  let content = "";

  if (directorySafe) {
    const hookPath = join(hooksDir, hookName);
    const inspected = readHookStat(hookPath);
    status = inspected.status;
    if (inspected.hookStat) {
      status = classifyHookStat(inspected.hookStat);
      if (status === "regular-file") content = readFileSync(hookPath, "utf-8");
    }
  }

  for (const [name, marker] of Object.entries(markers)) markerStatus[name] = content.includes(marker);
  return { status, markers: markerStatus };
}
