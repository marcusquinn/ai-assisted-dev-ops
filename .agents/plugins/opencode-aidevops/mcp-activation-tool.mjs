// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * Create the bounded MCP activation tool.
 * @param {function} tool
 * @param {object} z
 * @param {{client: object, directory?: string, allowedNames: string[]}} options
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
        const result = await method.call(options.client, {
          name,
          ...(options.directory ? { directory: options.directory } : {}),
        });
        if (result?.error) {
          return `Error: MCP ${action} failed for ${name}: ${result.error.message || String(result.error)}`;
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
