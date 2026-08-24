// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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
        await callLifecycle(action, name, options);
        if (action === "connect") {
          try {
            await waitForConnection(name, options);
          } catch (error) {
            if (!(error instanceof McpFailedStatusError)) throw error;
            await recoverFailedConnection(name, options, error);
          }
        }
      } catch (error) {
        return `Error: MCP ${action} failed for ${name}: ${error instanceof Error ? error.message : String(error)}`;
      }

      return action === "connect"
        ? `Connected MCP ${name}. Continue on the next step with its tools.`
        : `Disconnected MCP ${name}.`;
    },
  });
}
