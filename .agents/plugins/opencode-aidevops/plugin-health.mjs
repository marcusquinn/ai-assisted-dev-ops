// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  chmodSync,
  existsSync,
  lstatSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";

export const PLUGIN_HEALTH_SCHEMA = "aidevops.opencode-plugin-health/v1";

function probeTarget(env) {
  const filePath = env.AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE || "";
  const nonce = env.AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE || "";
  if (!filePath || !/^[a-zA-Z0-9._:-]{16,128}$/.test(nonce)) return null;

  const tempRoot = resolve(
    env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops", ".agent-workspace", "tmp"),
  );
  try {
    const root = realpathSync(tempRoot);
    const parent = realpathSync(dirname(filePath));
    const relativeParent = relative(root, parent);
    if (relativeParent === ".." || relativeParent.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) {
      return null;
    }
    const metadata = lstatSync(filePath);
    if (!metadata.isFile() || metadata.isSymbolicLink() || (metadata.mode & 0o077) !== 0) return null;
    return { filePath: realpathSync(filePath), nonce };
  } catch {
    return null;
  }
}

export function pluginHealthProbeRequested(env = process.env) {
  return env.AIDEVOPS_PLUGIN_HEALTH_PROBE_ONLY === "1" && Boolean(probeTarget(env));
}

export function recordPluginHealthStage(stage, details = {}, env = process.env) {
  const target = probeTarget(env);
  if (!target || !/^[a-z_]{3,32}$/.test(stage)) return false;

  let current;
  try {
    current = JSON.parse(readFileSync(target.filePath, "utf8"));
  } catch {
    return false;
  }
  if (current?.nonce !== target.nonce) return false;

  const stages = Array.isArray(current.stages) ? current.stages.filter((value) => typeof value === "string") : [];
  if (!stages.includes(stage)) stages.push(stage);
  const next = {
    schema: PLUGIN_HEALTH_SCHEMA,
    nonce: target.nonce,
    stages,
    details: { ...(current.details || {}), [stage]: details },
  };
  const tempPath = `${target.filePath}.next-${process.pid}`;
  try {
    if (existsSync(tempPath)) rmSync(tempPath);
    writeFileSync(tempPath, `${JSON.stringify(next)}\n`, { encoding: "utf8", flag: "wx", mode: 0o600 });
    chmodSync(tempPath, 0o600);
    renameSync(tempPath, target.filePath);
    return true;
  } catch {
    try {
      rmSync(tempPath);
    } catch {
      // Probe reporting is diagnostic-only and must never break plugin startup.
    }
    return false;
  }
}
