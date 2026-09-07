// ---------------------------------------------------------------------------
// Agent-to-MCP Tool Permissions
// Extracted from agent-loader.mjs to reduce file-level complexity.
// ---------------------------------------------------------------------------

import { platform } from "os";

const IS_MACOS = platform() === "darwin";

/**
 * Map of subagent names to the MCP tool patterns they need enabled.
 * Used by the config hook to set per-agent tool permissions.
 *
 * Only includes subagents that need MCP tools beyond the defaults.
 * Agents not listed here get only the globally-enabled tools.
 */
const AGENT_MCP_TOOLS = {
  // Browser / automation
  "chrome-devtools": ["chrome-devtools_*"],
  playwright: ["playwright_*"],
  playwriter: ["playwriter_*"],
  "macos-automator": IS_MACOS ? ["macos-automator_*"] : [],
  mac: IS_MACOS ? ["macos-automator_*"] : [],
  "ios-simulator-mcp": IS_MACOS ? ["ios-simulator_*"] : [],
  // Context / search
  context7: ["context7_*"],
  "openapi-search": ["openapi-search_*"],
  // Cloud / API
  "cloudflare-mcp": ["cloudflare-api_*"],
  // SEO / analytics
  "google-search-console": ["gsc_*"],
  dataforseo: ["dataforseo_*"],
  "google-analytics": ["google-analytics-mcp_*"],
  // Monitoring
  sentry: ["sentry_*"],
  socket: ["socket_*"],
  // UI
  shadcn: ["shadcn_*"],
  blender: ["blender-lab_*"],
  // Data / accounting
  outscraper: ["outscraper_*"],
  mainwp: ["localwp_*"],
  localwp: ["localwp_*"],
  quickfile: ["quickfile_*"],
  "amazon-order-history": ["amazon-order-history_*"],
  // AI tooling
  "claude-code": ["claude-code-mcp_*"],
  // Ecommerce
  shopify: ["shopify-dev-mcp_*"],
};

/**
 * Apply tool patterns to a single agent config entry.
 * Only sets tools not already configured (shell script takes precedence).
 * @param {object} agentEntry - Mutable agent config object
 * @param {string[]} toolPatterns - Tool patterns to enable
 * @returns {number} Number of tools newly enabled
 */
export function applyToolPatternsToAgent(agentEntry, toolPatterns) {
  let count = 0;
  if (!agentEntry.tools) {
    agentEntry.tools = {};
  }
  for (const pattern of toolPatterns) {
    if (!(pattern in agentEntry.tools)) {
      agentEntry.tools[pattern] = true;
      count++;
    }
  }
  return count;
}

/**
 * Apply per-agent MCP tool permissions.
 * Ensures subagents that need specific MCP tools have them enabled
 * in their agent config, even if the tools are disabled globally.
 *
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of agents updated
 */
export function applyAgentMcpTools(config) {
  if (!config.agent) return 0;

  let updated = 0;

  for (const [mcpAgentName, toolPatterns] of Object.entries(AGENT_MCP_TOOLS)) {
    if (toolPatterns.length === 0) continue;

    const matchingKeys = Object.keys(config.agent).filter(
      (key) => key === mcpAgentName || key.endsWith("/" + mcpAgentName),
    );

    for (const matchKey of matchingKeys) {
      updated += applyToolPatternsToAgent(config.agent[matchKey], toolPatterns);
    }
  }

  return updated;
}
