// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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

class McpFailedStatusError extends Error {
  constructor(status) {
    super(`MCP entered ${status} status`);
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
  if (typeof method !== "function") {
    throw new Error(`OpenCode does not expose MCP ${action} in this runtime.`);
  }
  const result = await method.call(options.client, lifecycleRequest(name, options));
  if (result?.error) {
    throw new Error(result.error.message || String(result.error));
  }
}

async function waitForConnection(name, options) {
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
    if (result?.error) {
      throw new Error(result.error.message || String(result.error));
    }
    const payload = result?.data ?? result;
    status = payload?.[name]?.status || "unknown";
    if (status === "connected") return;
    if (["error", "failed"].includes(status)) {
      throw new McpFailedStatusError(status);
    }
    await pause(pollIntervalMs);
  } while (Date.now() < deadline);

  throw new Error(`MCP did not become ready (last status: ${status})`);
}

async function recoverFailedConnection(name, options, statusError) {
  if (typeof options.client?.disconnect !== "function") {
    throw new Error(
      `${statusError.message}; bounded reset unavailable because OpenCode does not expose MCP disconnect in this runtime.`,
    );
  }

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
    await waitForConnection(name, options);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`${message} after one bounded reset`);
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
  if (!pathIsWithin(physicalTempRoot, physicalWorkspace)) {
    throw new Error("managed MCP workspace escapes its temporary root");
  }
  if (workspace.repositoryDir) {
    const physicalRepository = projectedPhysicalPath(workspace.repositoryDir);
    if (pathIsWithin(physicalRepository, physicalWorkspace)) {
      throw new Error("managed MCP workspace resolves inside the repository");
    }
  }
}

function validateOwnedWorkspace(workspace) {
  const stats = lstatSync(workspace.directory);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw new Error("managed MCP workspace is not a regular directory");
  }
  const markerStats = lstatSync(workspace.markerPath);
  if (!markerStats.isFile() || markerStats.isSymbolicLink()) {
    throw new Error("managed MCP workspace marker is not a regular file");
  }
  if (readFileSync(workspace.markerPath, "utf8") !== workspace.markerToken) {
    throw new Error("managed MCP workspace ownership marker does not match");
  }
}

function prepareManagedWorkspace(workspace) {
  let newlyOwned = false;
  validateWorkspaceBoundary(workspace);
  if (!existsSync(workspace.directory)) {
    mkdirSync(workspace.directory, { recursive: true, mode: 0o700 });
    newlyOwned = true;
  } else {
    const stats = lstatSync(workspace.directory);
    if (!stats.isDirectory() || stats.isSymbolicLink()) {
      throw new Error("managed MCP workspace is not a regular directory");
    }
  }
  validateWorkspaceBoundary(workspace);
  chmodSync(workspace.directory, 0o700);
  if (!existsSync(workspace.markerPath)) {
    if (readdirSync(workspace.directory).length > 0) {
      throw new Error("managed MCP workspace is non-empty without an ownership marker");
    }
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
  if (!pathIsWithin(physicalTempRoot, physicalWorkspace)) {
    throw new Error("managed MCP workspace physical path escapes its temporary root");
  }
  const cleanupSuffix = workspace.markerToken.replace(/[^a-zA-Z0-9._-]/g, "-");
  const quarantine = `${physicalWorkspace}.cleanup-${cleanupSuffix}`;
  if (existsSync(quarantine)) {
    throw new Error("managed MCP cleanup quarantine already exists");
  }
  renameSync(physicalWorkspace, quarantine);
  const quarantinedWorkspace = {
    ...workspace,
    directory: quarantine,
    markerPath: join(quarantine, basename(workspace.markerPath)),
  };
  validateOwnedWorkspace(quarantinedWorkspace);
  rmSync(quarantine, { recursive: true, force: true });
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
  if (typeof filename !== "string") {
    throw new Error("Playwright screenshot filename must be a relative path inside managed temporary storage.");
  }
  const segments = filename.split(/[\\/]+/);
  if (isAbsolute(filename) || win32.isAbsolute(filename) || segments.includes("..")) {
    throw new Error("Playwright screenshot filename must not be absolute or contain '..' traversal.");
  }
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
      const action = String(args.action || "");
      const name = String(args.name || "");
      if (!allowed.has(name) || !["connect", "disconnect"].includes(action)) {
        return "Error: only registry-approved MCP activation requests are allowed.";
      }

      const method = options.client?.[action];
      if (typeof method !== "function") {
        return `Error: OpenCode does not expose MCP ${action} in this runtime.`;
      }

      const workspace = managedWorkspace(name, options);
      let cleanupOnConnectFailure = false;
      try {
        if (action === "connect" && workspace) {
          cleanupOnConnectFailure = prepareManagedWorkspace(workspace);
        }
        await callLifecycle(action, name, options);
        if (action === "connect") {
          try {
            await waitForConnection(name, options);
          } catch (error) {
            if (!(error instanceof McpFailedStatusError)) throw error;
            await recoverFailedConnection(name, options, error);
          }
        } else if (workspace) {
          cleanupManagedWorkspace(workspace);
        }
      } catch (error) {
        let cleanupError = "";
        if (action === "connect" && cleanupOnConnectFailure) {
          try {
            cleanupManagedWorkspace(workspace);
          } catch (cleanupFailure) {
            cleanupError = `; workspace cleanup failed: ${cleanupFailure instanceof Error ? cleanupFailure.message : String(cleanupFailure)}`;
          }
        }
        return `Error: MCP ${action} failed for ${name}: ${error instanceof Error ? error.message : String(error)}${cleanupError}`;
      }

      return action === "connect"
        ? `Connected MCP ${name}. Continue on the next step with its tools.`
        : `Disconnected MCP ${name}.`;
    },
  });
}
