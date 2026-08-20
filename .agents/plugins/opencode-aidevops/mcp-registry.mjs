// ---------------------------------------------------------------------------
// MCP Server Registry + Config Hook helpers
// Extracted from index.mjs (t1914) — MCP registration logic.
// ---------------------------------------------------------------------------

import { accessSync, constants } from "fs";
import { homedir, platform } from "os";
import { delimiter, join } from "path";

const IS_MACOS = platform() === "darwin";

/**
 * Resolve an executable from PATH without spawning `which` during startup.
 * @param {string} name
 * @returns {string}
 */
function findExecutable(name) {
  if (!name) return "";

  const pathExts = process.platform === "win32"
    ? (process.env.PATHEXT || ".EXE;.CMD;.BAT;.COM").split(";")
    : [""];
  const pathDirs = (process.env.PATH || "").split(delimiter).filter(Boolean);
  const candidates = name.includes("/") || name.includes("\\")
    ? [name]
    : pathDirs.flatMap((dir) => pathExts.map((ext) => join(dir, `${name}${ext}`)));

  for (const candidate of candidates) {
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // keep searching
    }
  }

  return "";
}

/**
 * Resolve the package runner command (bun x preferred, npx fallback).
 * Cached after first call.
 * @returns {string}
 */
let _pkgRunner = null;
function getPkgRunner() {
  if (_pkgRunner !== null) return _pkgRunner;
  const bunPath = findExecutable("bun");
  const npxPath = findExecutable("npx");
  _pkgRunner = bunPath ? `${bunPath} x` : npxPath || "npx";
  return _pkgRunner;
}

/**
 * MCP Server Registry — canonical catalog of all known MCP servers.
 *
 * Each entry defines:
 *   - command: Array of command + args for local MCPs
 *   - url: URL for remote MCPs (mutually exclusive with command)
 *   - type: "local" (default) or "remote"
 *   - eager: true = start at launch, false = remain disabled until explicitly connected
 *   - toolPattern: glob pattern for tool permissions (e.g. "playwriter_*")
 *   - globallyEnabled: whether tools are enabled globally (true) or per-agent (false)
 *   - activationAgent: optional bounded agent that can connect the MCP on demand
 *   - agentSource: source path for an activation agent profile
 *   - requiresBinary: optional binary name that must exist for local MCPs
 *   - macOnly: optional flag for macOS-only MCPs
 *   - description: human-readable description for logging
 *
 * @returns {Array<object>}
 */
function getMcpRegistry() {
  const pkgRunner = getPkgRunner();
  const pkgRunnerParts = pkgRunner.split(" ");

  return [
    // --- Lazy-loaded MCPs (start on demand) ---
    {
      name: "playwriter",
      type: "local",
      command: [...pkgRunnerParts, "playwriter@latest"],
      eager: false,
      toolPattern: "playwriter_*",
      globallyEnabled: false,
      activationAgent: "playwriter",
      agentSource: ["tools", "browser", "playwriter.md"],
      modelTier: "standard",
      description: "Browser automation via Chrome extension",
    },
    {
      name: "context7",
      type: "remote",
      url: "https://mcp.context7.com/mcp",
      eager: false,
      toolPattern: "context7_*",
      globallyEnabled: false,
      description: "Library documentation lookup",
    },
    {
      name: "outscraper",
      type: "local",
      command: [
        "/bin/bash",
        "-c",
        "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server",
      ],
      eager: false,
      toolPattern: "outscraper_*",
      globallyEnabled: false,
      description: "Business intelligence extraction",
    },
    {
      name: "dataforseo",
      type: "local",
      command: [
        "/bin/bash",
        "-c",
        `source ~/.config/aidevops/credentials.sh && DATAFORSEO_USERNAME=$DATAFORSEO_USERNAME DATAFORSEO_PASSWORD=$DATAFORSEO_PASSWORD ${pkgRunner} dataforseo-mcp-server`,
      ],
      eager: false,
      toolPattern: "dataforseo_*",
      globallyEnabled: false,
      description: "Comprehensive SEO data",
    },
    {
      name: "shadcn",
      type: "local",
      command: ["npx", "shadcn@latest", "mcp"],
      eager: false,
      toolPattern: "shadcn_*",
      globallyEnabled: false,
      description: "UI component library",
    },
    {
      name: "claude-code-mcp",
      type: "local",
      command: ["npx", "-y", "github:marcusquinn/claude-code-mcp"],
      eager: false,
      toolPattern: "claude-code-mcp_*",
      globallyEnabled: false,
      alwaysOverwrite: true,
      description: "Claude Code one-shot execution",
    },
    {
      name: "macos-automator",
      type: "local",
      command: ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"],
      eager: false,
      toolPattern: "macos-automator_*",
      globallyEnabled: false,
      macOnly: true,
      description: "AppleScript and JXA automation",
    },
    {
      name: "ios-simulator",
      type: "local",
      command: ["npx", "-y", "ios-simulator-mcp"],
      eager: false,
      toolPattern: "ios-simulator_*",
      globallyEnabled: false,
      macOnly: true,
      description: "iOS Simulator interaction",
    },
    {
      name: "sentry",
      type: "remote",
      url: "https://mcp.sentry.dev/mcp",
      eager: false,
      toolPattern: "sentry_*",
      globallyEnabled: false,
      alwaysOverwrite: true, // migrate away from legacy local+token config
      description: "Error tracking via OAuth (mcp.sentry.dev)",
    },
    {
      name: "socket",
      type: "remote",
      url: "https://mcp.socket.dev/",
      eager: false,
      toolPattern: "socket_*",
      globallyEnabled: false,
      description: "Dependency security scanning",
    },
    // --- Remote MCPs (zero install, lazy-loaded) ---
    {
      name: "cloudflare-api",
      type: "remote",
      url: "https://mcp.cloudflare.com/mcp",
      eager: false,
      toolPattern: "cloudflare-api_*",
      globallyEnabled: false,
      description: "Cloudflare Workers, D1, KV, R2, Pages, AI Gateway",
    },
    {
      name: "openapi-search",
      type: "remote",
      url: "https://openapi-mcp.openapisearch.com/mcp",
      eager: false,
      toolPattern: "openapi-search_*",
      globallyEnabled: false,
      description: "OpenAPI schema search across public APIs",
    },
    // --- Local MCPs requiring installed binaries ---
    {
      name: "chrome-devtools",
      type: "local",
      command: [...pkgRunnerParts, "chrome-devtools-mcp@latest"],
      eager: false,
      toolPattern: "chrome-devtools_*",
      globallyEnabled: false,
      description: "Chrome DevTools debugging and inspection",
    },
    {
      name: "playwright",
      type: "local",
      command: ["npx", "-y", "@playwright/mcp@latest"],
      eager: false,
      toolPattern: "playwright_*",
      globallyEnabled: false,
      description: "Cross-browser test automation",
    },
    {
      name: "gsc",
      type: "local",
      command: [
        "/bin/bash",
        "-c",
        `GOOGLE_APPLICATION_CREDENTIALS=$\{GOOGLE_APPLICATION_CREDENTIALS:-~/.config/aidevops/gsc-credentials.json} ${pkgRunner} mcp-server-gsc`,
      ],
      eager: false,
      toolPattern: "gsc_*",
      globallyEnabled: false,
      description: "Google Search Console data",
    },
    {
      name: "google-analytics-mcp",
      type: "local",
      command: [
        "/bin/bash",
        "-c",
        "GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS:-~/.config/aidevops/gsc-credentials.json} analytics-mcp",
      ],
      eager: false,
      toolPattern: "google-analytics-mcp_*",
      globallyEnabled: false,
      requiresBinary: "analytics-mcp",
      description: "Google Analytics data",
    },
    {
      name: "quickfile",
      type: "local",
      command: [
        join(
          homedir(),
          ".aidevops",
          "agents",
          "scripts",
          "quickfile-mcp-launcher.sh",
        ),
      ],
      eager: false,
      toolPattern: "quickfile_*",
      globallyEnabled: false,
      requiresBinary: "aidevops",
      alwaysOverwrite: true,
      description: "Multi-account QuickFile UK accounting",
    },
    {
      name: "amazon-order-history",
      type: "local",
      command: [
        "/bin/bash",
        "-c",
        "node ~/Git/mcp/amazon-order-history-csv-download-mcp/dist/index.js",
      ],
      eager: false,
      toolPattern: "amazon-order-history_*",
      globallyEnabled: false,
      description: "Amazon order history export",
    },
    {
      name: "MCP_DOCKER",
      type: "local",
      command: ["docker", "mcp", "gateway", "run"],
      eager: false,
      toolPattern: "MCP_DOCKER_*",
      globallyEnabled: false,
      requiresBinary: "docker",
      description: "Docker MCP gateway",
    },
    {
      name: "shopify-dev-mcp",
      type: "local",
      command: [...pkgRunnerParts, "@shopify/dev-mcp@latest"],
      eager: false,
      toolPattern: "shopify-dev-mcp_*",
      globallyEnabled: false,
      description: "Shopify schema-aware GraphQL, Liquid validation, Admin API",
    },
  ];
}

/**
 * Return the bounded MCP activation-agent definitions.
 * These are intentionally explicit so OpenCode never returns to registering
 * hundreds of leaf agents during startup.
 * @returns {Array<object>}
 */
export function getOnDemandMcpAgents() {
  return getMcpRegistry()
    .filter((mcp) => mcp.activationAgent && Array.isArray(mcp.agentSource))
    .map((mcp) => ({
      name: mcp.name,
      agentName: mcp.activationAgent,
      agentSource: [...mcp.agentSource],
      toolPattern: mcp.toolPattern,
      modelTier: mcp.modelTier || "standard",
      description: mcp.description,
    }));
}

/**
 * Check if an MCP entry should be skipped (wrong platform, missing binary).
 * @param {object} mcp - MCP registry entry
 * @param {object} tools - Config tools object (mutable — disables pattern if binary missing)
 * @returns {boolean} true if the MCP should be skipped
 */
function shouldSkipMcp(mcp, tools) {
  if (mcp.macOnly && !IS_MACOS) return true;

  if (mcp.requiresBinary) {
    const binaryPath = findExecutable(mcp.requiresBinary);
    if (!binaryPath) {
      if (mcp.toolPattern) tools[mcp.toolPattern] = false;
      return true;
    }
  }

  return false;
}

/**
 * Build the MCP config entry (remote or local).
 * @param {object} mcp - MCP registry entry
 * @returns {object} Config entry for config.mcp[name]
 */
function buildMcpConfigEntry(mcp) {
  if (mcp.type === "remote" && mcp.url) {
    return { type: "remote", url: mcp.url, enabled: mcp.eager };
  }
  return { type: "local", command: mcp.command, enabled: mcp.eager };
}

/**
 * Register a single MCP server in the config. Returns true if newly registered.
 * @param {object} mcp - MCP registry entry
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {boolean} Whether a new registration was made
 */
function registerSingleMcp(mcp, config) {
  if (!config.mcp[mcp.name] || mcp.alwaysOverwrite) {
    config.mcp[mcp.name] = buildMcpConfigEntry(mcp);
    return true;
  }

  // Runtime-activated MCPs must stay disconnected at startup, including when
  // migrating older generated configs that marked them enabled.
  if (mcp.activationAgent) {
    config.mcp[mcp.name].enabled = false;
    return false;
  }

  // Respect explicit enabled:false from worker configs (t221).
  if (config.mcp[mcp.name].enabled === undefined) {
    config.mcp[mcp.name].enabled = mcp.eager;
  }
  return false;
}

/**
 * Set global tool permissions for an MCP, respecting worker config overrides.
 * @param {object} mcp - MCP registry entry
 * @param {object} tools - Config tools object (mutable)
 */
function applyMcpToolPermissions(mcp, tools) {
  if (!mcp.toolPattern) return;
  if (tools[mcp.toolPattern] !== false) {
    tools[mcp.toolPattern] = mcp.globallyEnabled;
  }
}

/**
 * Legacy MCP names to remove from opencode.json on startup.
 * Add entries here when an MCP is renamed, merged, or replaced.
 * Also removes the corresponding tools_* entry.
 */
const DEPRECATED_MCPS = [
  // auggie-mcp was a duplicate of augment-context-engine (same binary, same purpose)
  { name: "auggie-mcp", toolPattern: "auggie-mcp_*" },
  // augment-context-engine relied on the Auggie MCP; local code search is preferred.
  { name: "augment-context-engine", toolPattern: "augment-context-engine_*" },
  // gh_grep MCP (mcp.grep.app) removed — github-search subagent uses rg/bash instead
  { name: "gh_grep", toolPattern: "gh_grep_*" },
];

/**
 * Remove deprecated MCP entries from config.
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of entries removed
 */
function removeDeprecatedMcps(config) {
  let removed = 0;
  for (const { name, toolPattern } of DEPRECATED_MCPS) {
    if (config.mcp[name]) {
      delete config.mcp[name];
      removed++;
    }
    if (toolPattern && config.tools[toolPattern] !== undefined) {
      delete config.tools[toolPattern];
    }
  }
  return removed;
}

/**
 * Register MCP servers in the OpenCode config.
 * Complements generate-opencode-agents.sh by ensuring MCPs are always
 * registered even without re-running setup.sh.
 *
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of MCPs registered
 */
export function registerMcpServers(config) {
  if (!config.mcp) config.mcp = {};
  if (!config.tools) config.tools = {};

  removeDeprecatedMcps(config);

  const registry = getMcpRegistry();
  let registered = 0;

  for (const mcp of registry) {
    if (shouldSkipMcp(mcp, config.tools)) continue;

    if (registerSingleMcp(mcp, config)) registered++;
    applyMcpToolPermissions(mcp, config.tools);
  }

  return registered;
}
