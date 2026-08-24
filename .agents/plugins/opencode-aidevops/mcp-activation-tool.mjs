// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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
      const error = new Error(`MCP entered ${status} status`);
      error.mcpStatus = status;
      throw error;
    }
    await pause(pollIntervalMs);
  } while (Date.now() < deadline);

  throw new Error(`MCP did not become ready (last status: ${status})`);
}

function lifecycleRequest(name, options) {
  return {
    path: { name },
    ...(options.directory ? { query: { directory: options.directory } } : {}),
  };
}

function recoveryFailure(name, detail, resetAttempted) {
  const state = resetAttempted ? "after one reset attempt" : "because automatic reset is unavailable";
  return `Error: MCP connect failed for ${name} ${state}: ${detail}. `
    + `Run mcp-diagnose.sh ${name}; restart OpenCode after fixing the cause.`;
}

async function recoverFailedConnection(name, options) {
  const disconnectMethod = options.client?.disconnect;
  if (typeof disconnectMethod !== "function") {
    return recoveryFailure(name, "OpenCode does not expose MCP disconnect in this runtime", false);
  }

  const request = lifecycleRequest(name, options);
  try {
    const disconnectResult = await disconnectMethod.call(options.client, request);
    if (disconnectResult?.error) {
      throw new Error(disconnectResult.error.message || String(disconnectResult.error));
    }
    const reconnectResult = await options.client.connect.call(options.client, request);
    if (reconnectResult?.error) {
      throw new Error(reconnectResult.error.message || String(reconnectResult.error));
    }
    await waitForConnection(name, options);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return recoveryFailure(name, detail, true);
  }

  return null;
}

/**
 * Create the bounded MCP activation tool.
 * @param {function} tool
 * @param {object} z
 * @param {{client: object, directory?: string, allowedNames: string[], connectTimeoutMs?: number, pollIntervalMs?: number, pause?: function}} options
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

      try {
        const result = await method.call(options.client, lifecycleRequest(name, options));
        if (result?.error) {
          return `Error: MCP ${action} failed for ${name}: ${result.error.message || String(result.error)}`;
        }
        if (action === "connect") await waitForConnection(name, options);
      } catch (error) {
        if (action === "connect" && error?.mcpStatus) {
          const recoveryError = await recoverFailedConnection(name, options);
          if (!recoveryError) {
            return `Connected MCP ${name} after one automatic reset. Continue on the next step with its tools.`;
          }
          return recoveryError;
        }
        return `Error: MCP ${action} failed for ${name}: ${error instanceof Error ? error.message : String(error)}`;
      }

      return action === "connect"
        ? `Connected MCP ${name}. Continue on the next step with its tools.`
        : `Disconnected MCP ${name}.`;
    },
  });
}
