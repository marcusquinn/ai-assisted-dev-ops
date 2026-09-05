// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { ok as assert } from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, win32 } from "node:path";

const PLAYWRIGHT_OUTPUT_TOOLS = new Set([
  "playwright_browser_console_messages",
  "playwright_browser_evaluate",
  "playwright_browser_network_request",
  "playwright_browser_network_requests",
  "playwright_browser_pdf_save",
  "playwright_browser_snapshot",
  "playwright_browser_start_video",
  "playwright_browser_storage_state",
  "playwright_browser_take_screenshot",
]);

const MCP_DIAGNOSTIC_UNAVAILABLE =
  "diagnostic unavailable; use the documented secure CLI diagnostic path";
const MCP_STATUS_VALUES = new Set(["connected", "connecting", "disabled", "error", "failed"]);

function safeMcpStatusDiagnostic() {
  // The OpenCode SDK currently types the /mcp response as unknown. Until it
  // exposes a finite structured error code, every status-entry detail remains
  // untrusted and must stay out of user-visible activation results.
  return MCP_DIAGNOSTIC_UNAVAILABLE;
}

class McpFailedStatusError extends Error {
  constructor(status, phase) {
    super(`MCP entered ${status} status during ${phase}; ${safeMcpStatusDiagnostic()}`);
    this.name = "McpFailedStatusError";
  }
}

function lifecycleRequest(name, options) {
  return {
    path: { name },
    ...(options.directory ? { query: { directory: options.directory } } : {}),
  };
}

async function callLifecycle(action, name, options) {
  const method = options.client?.[action];
  assert(
    typeof method === "function",
    new Error(`OpenCode does not expose MCP ${action} in this runtime.`),
  );
  const result = await method.call(options.client, lifecycleRequest(name, options));
  assert(!result?.error, new Error(result?.error?.message || String(result?.error)));
}

async function waitForConnection(name, options, phase) {
  const statusMethod = options.client?.status;
  if (typeof statusMethod !== "function") return;

  const request = options.directory ? { query: { directory: options.directory } } : {};
  const deadline = Date.now() + (options.connectTimeoutMs || 30_000);
  const pollIntervalMs = options.pollIntervalMs || 500;
  const pause = options.pause
    || ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
  let status = "unknown";
  do {
    const result = await statusMethod.call(options.client, request);
    assert(!result?.error, new Error(result?.error?.message || String(result?.error)));
    const payload = result?.data ?? result;
    const statusEntry = payload?.[name];
    status = MCP_STATUS_VALUES.has(statusEntry?.status) ? statusEntry.status : "unknown";
    if (status === "connected") return;
    assert(!["error", "failed"].includes(status), new McpFailedStatusError(status, phase));
    await pause(pollIntervalMs);
  } while (Date.now() < deadline);

  throw new Error(`MCP did not become ready (last status: ${status})`);
}

async function recoverFailedConnection(name, options, statusError) {
  assert(
    typeof options.client?.disconnect === "function",
    new Error(
      `${statusError.message}; bounded reset unavailable because OpenCode does not expose MCP disconnect in this runtime.`,
    ),
  );

  try {
    await callLifecycle("disconnect", name, options);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${statusError.message}; bounded reset disconnect failed: ${message}`);
  }

  try {
    await callLifecycle("connect", name, options);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${statusError.message}; bounded reset reconnect failed: ${message}`);
  }

  try {
    await waitForConnection(name, options, "post-reset activation");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${statusError.message}; ${message} after one bounded reset`);
  }
}

function managedWorkspace(name, options) {
  return options.managedWorkspaces?.[name] || null;
}

function projectedPhysicalPath(targetPath) {
  const missingSegments = [];
  let cursor = resolve(targetPath);
  while (!existsSync(cursor)) {
    const parent = dirname(cursor);
    if (parent === cursor) break;
    missingSegments.unshift(basename(cursor));
    cursor = parent;
  }
  return resolve(realpathSync(cursor), ...missingSegments);
}

function pathIsWithin(parentPath, candidatePath) {
  const relativePath = relative(parentPath, candidatePath);
  return relativePath === "" || (!relativePath.startsWith("..") && !isAbsolute(relativePath));
}

function validateWorkspaceBoundary(workspace) {
  const physicalTempRoot = projectedPhysicalPath(workspace.tempRoot);
  const physicalWorkspace = projectedPhysicalPath(workspace.directory);
  assert(
    pathIsWithin(physicalTempRoot, physicalWorkspace),
    "managed MCP workspace escapes its temporary root",
  );
  assert(
    !workspace.repositoryDir
      || !pathIsWithin(projectedPhysicalPath(workspace.repositoryDir), physicalWorkspace),
    "managed MCP workspace resolves inside the repository",
  );
}

function validateOwnedWorkspace(workspace) {
  const stats = lstatSync(workspace.directory);
  assert(
    stats.isDirectory() && !stats.isSymbolicLink(),
    "managed MCP workspace is not a regular directory",
  );
  const markerStats = lstatSync(workspace.markerPath);
  assert(
    markerStats.isFile() && !markerStats.isSymbolicLink(),
    "managed MCP workspace marker is not a regular file",
  );
  assert(
    readFileSync(workspace.markerPath, "utf8") === workspace.markerToken,
    "managed MCP workspace ownership marker does not match",
  );
}

function prepareManagedWorkspace(workspace) {
  let newlyOwned = false;
  validateWorkspaceBoundary(workspace);
  if (!existsSync(workspace.directory)) {
    mkdirSync(workspace.directory, { recursive: true, mode: 0o700 });
    newlyOwned = true;
  } else {
    const stats = lstatSync(workspace.directory);
    assert(
      stats.isDirectory() && !stats.isSymbolicLink(),
      "managed MCP workspace is not a regular directory",
    );
  }
  validateWorkspaceBoundary(workspace);
  chmodSync(workspace.directory, 0o700);
  if (!existsSync(workspace.markerPath)) {
    assert(
      readdirSync(workspace.directory).length === 0,
      "managed MCP workspace is non-empty without an ownership marker",
    );
    writeFileSync(workspace.markerPath, workspace.markerToken, { flag: "wx", mode: 0o600 });
    newlyOwned = true;
  }
  validateOwnedWorkspace(workspace);
  return newlyOwned;
}

function cleanupManagedWorkspace(workspace) {
  if (!existsSync(workspace.directory)) return;
  validateWorkspaceBoundary(workspace);
  validateOwnedWorkspace(workspace);
  const physicalWorkspace = realpathSync(workspace.directory);
  const physicalTempRoot = projectedPhysicalPath(workspace.tempRoot);
  assert(
    pathIsWithin(physicalTempRoot, physicalWorkspace),
    "managed MCP workspace physical path escapes its temporary root",
  );
  const cleanupSuffix = workspace.markerToken.replace(/[^a-zA-Z0-9._-]/g, "-");
  const quarantine = `${physicalWorkspace}.cleanup-${cleanupSuffix}`;
  assert(!existsSync(quarantine), "managed MCP cleanup quarantine already exists");
  renameSync(physicalWorkspace, quarantine);
  const quarantinedWorkspace = {
    ...workspace,
    directory: quarantine,
    markerPath: join(quarantine, basename(workspace.markerPath)),
  };
  validateOwnedWorkspace(quarantinedWorkspace);
  rmSync(quarantine, { recursive: true, force: true });
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

async function waitForInitialConnection(name, options) {
  try {
    await waitForConnection(name, options, "initial activation");
  } catch (error) {
    if (!(error instanceof McpFailedStatusError)) throw error;
    await recoverFailedConnection(name, options, error);
  }
}

function cleanupAfterFailedConnect(workspace, cleanupOnFailure) {
  if (!cleanupOnFailure) return "";
  try {
    cleanupManagedWorkspace(workspace);
    return "";
  } catch (error) {
    return `; workspace cleanup failed: ${errorMessage(error)}`;
  }
}

async function connectMcp(name, options, workspace) {
  const cleanupOnFailure = workspace ? prepareManagedWorkspace(workspace) : false;
  try {
    await callLifecycle("connect", name, options);
    await waitForInitialConnection(name, options);
  } catch (error) {
    const cleanupError = cleanupAfterFailedConnect(workspace, cleanupOnFailure);
    throw new Error(`${errorMessage(error)}${cleanupError}`);
  }
}

async function disconnectMcp(name, options, workspace) {
  await callLifecycle("disconnect", name, options);
  if (workspace) cleanupManagedWorkspace(workspace);
}

async function executeMcpActivation(args, allowed, options) {
  const action = String(args.action || "");
  const name = String(args.name || "");
  if (!allowed.has(name) || !["connect", "disconnect"].includes(action)) {
    return "Error: only registry-approved MCP activation requests are allowed.";
  }

  if (typeof options.client?.[action] !== "function") {
    return `Error: OpenCode does not expose MCP ${action} in this runtime.`;
  }

  const workspace = managedWorkspace(name, options);
  try {
    if (action === "connect") {
      await connectMcp(name, options, workspace);
    } else {
      await disconnectMcp(name, options, workspace);
    }
  } catch (error) {
    return `Error: MCP ${action} failed for ${name}: ${errorMessage(error)}`;
  }

  return action === "connect"
    ? `Connected MCP ${name}. Lifecycle readiness does not grant its tools to the current agent; continue in the dedicated ${name} agent, where its tool permissions are scoped.`
    : `Disconnected MCP ${name}.`;
}

/**
 * Reject screenshot filenames that can escape the managed Playwright cwd.
 * @param {object} input
 * @param {object} output
 * @param {object} managedWorkspaces
 */
export function enforceManagedMcpArtifactPath(input, output, managedWorkspaces) {
  if (!managedWorkspaces?.playwright || !PLAYWRIGHT_OUTPUT_TOOLS.has(input?.tool)) return;
  const filename = output?.args?.filename;
  if (filename === undefined || filename === null || filename === "") return;
  assert(
    typeof filename === "string",
    new Error("Playwright screenshot filename must be a relative path inside managed temporary storage."),
  );
  const segments = filename.split(/[\\/]+/);
  assert(
    !isAbsolute(filename) && !win32.isAbsolute(filename) && !segments.includes(".."),
    new Error("Playwright screenshot filename must not be absolute or contain '..' traversal."),
  );
}

/**
 * Create the bounded MCP activation tool.
 * @param {function} tool
 * @param {object} z
 * @param {{client: object, directory?: string, allowedNames: string[], managedWorkspaces?: object, connectTimeoutMs?: number, pollIntervalMs?: number, pause?: function}} options
 * @returns {object}
 */
export function createMcpActivationTool(tool, z, options) {
  const allowedNames = [...new Set(options.allowedNames || [])];
  const allowed = new Set(allowedNames);

  return tool({
    description:
      "Connect or disconnect an aidevops-managed MCP server on demand. "
      + "Only registry-approved servers are accepted; arbitrary commands and URLs are rejected.",
    args: {
      action: z.enum(["connect", "disconnect"]).describe("MCP lifecycle action"),
      name: z.enum(allowedNames).describe("Registry-approved MCP server name"),
    },
    async execute(args) {
      return executeMcpActivation(args, allowed, options);
    },
  });
}
