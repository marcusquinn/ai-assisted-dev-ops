// ---------------------------------------------------------------------------
// OpenCode Version Tracking (t1857)
// Extracted from index.mjs (t1914) — version drift detection.
// ---------------------------------------------------------------------------

import { readFileSync, existsSync } from "fs";
import { execSync, execFile } from "child_process";
import { join } from "path";

/**
 * Read a file if it exists, or return empty string.
 * @param {string} filepath
 * @returns {string}
 */
function readIfExists(filepath) {
  try {
    if (existsSync(filepath)) {
      return readFileSync(filepath, "utf-8").trim();
    }
  } catch {
    // ignore
  }
  return "";
}

/**
 * Run a shell command and return stdout, or empty string on failure.
 * @param {string} cmd
 * @param {number} [timeout=5000]
 * @returns {string}
 */
function run(cmd, timeout = 5000) {
  try {
    return execSync(cmd, {
      encoding: "utf-8",
      timeout,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch {
    return "";
  }
}

/**
 * Read the tracked opencode version from the plugin's package.json.
 * @param {string} pluginDir - Path to the plugin directory
 * @returns {{ tracked: string, repo: string } | null}
 */
function getTrackedOpenCodeVersion(pluginDir) {
  const pkgPath = join(pluginDir, "package.json");
  const content = readIfExists(pkgPath);
  if (!content) return null;

  try {
    const pkg = JSON.parse(content);
    const meta = pkg.opencode;
    if (meta && meta.tracked_version) {
      return { tracked: meta.tracked_version, repo: meta.repo || "anomalyco/opencode" };
    }
  } catch {
    // Malformed JSON — skip
  }
  return null;
}

/**
 * Compare semver strings (major.minor.patch). Returns:
 *   -1 if a < b, 0 if equal, 1 if a > b.
 * @param {string} a
 * @param {string} b
 * @returns {number}
 */
export function compareSemver(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    const va = pa[i] || 0;
    const vb = pb[i] || 0;
    if (va < vb) return -1;
    if (va > vb) return 1;
  }
  return 0;
}

/**
 * Build a version drift notice from tracked metadata and running version text.
 * @param {{ tracked: string, repo: string }} meta
 * @param {string} running
 * @returns {string | null}
 */
function buildVersionDriftNotice(meta, running) {
  const runningClean = String(running || "").replace(/^v/, "").trim();
  if (!runningClean) return null;

  const cmp = compareSemver(meta.tracked, runningClean);
  if (cmp < 0) {
    return `opencode ${runningClean} running, plugin tested against ${meta.tracked} — review ${meta.repo} changelog`;
  }

  return null;
}

/**
 * Check if the running opencode version is ahead of the tracked version.
 * Logs a notice if an update to the plugin's tracked_version is needed.
 * @param {string} pluginDir - Path to the plugin directory
 * @returns {string | null} Notice message, or null if versions match
 */
export function checkOpenCodeVersionDrift(pluginDir) {
  const meta = getTrackedOpenCodeVersion(pluginDir);
  if (!meta) return null;

  const running = run("opencode --version 2>/dev/null");
  return buildVersionDriftNotice(meta, running);
}

/**
 * Check the running opencode version without blocking the config hook.
 * @param {string} pluginDir
 * @param {(notice: string) => void} onNotice
 * @returns {boolean} true when the async check was scheduled
 */
export function checkOpenCodeVersionDriftAsync(pluginDir, onNotice) {
  const meta = getTrackedOpenCodeVersion(pluginDir);
  if (!meta) return false;

  try {
    execFile("opencode", ["--version"], { timeout: 5000 }, (err, stdout) => {
      if (err) return;
      const notice = buildVersionDriftNotice(meta, stdout);
      if (notice) onNotice?.(notice);
    });
  } catch {
    return false;
  }

  return true;
}
