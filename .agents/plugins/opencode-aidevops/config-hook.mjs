// ---------------------------------------------------------------------------
// Config Hook — agent registration, MCP setup, provider cleanup
// Extracted from index.mjs (t1914).
// ---------------------------------------------------------------------------

import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { applyAgentMcpTools } from "./agent-loader.mjs";
import { registerMcpServers } from "./mcp-registry.mjs";
import { registerPoolProvider, getAccounts, ensureValidToken } from "./oauth-pool.mjs";
import { getCursorProxyPort, registerCursorProvider } from "./cursor-proxy.mjs";
import { getGoogleProxyPort, registerGoogleProvider } from "./google-proxy.mjs";
import { getClaudeProxyPort, registerClaudeProvider } from "./claude-proxy.mjs";
import { checkOpenCodeVersionDriftAsync } from "./version-tracking.mjs";
import { registerApprovedWorkerPermissions } from "./config-worker-permissions.mjs";
import {
  registerAgentRoutingIntent,
  registerAgents,
  registerResearchOnlyAgent,
} from "./config-agent-profiles.mjs";
import {
  enforcePublicTriageIsolation,
  ensureAgentGuard,
  registerManagedDirectoryPermissions,
} from "./config-safety-guards.mjs";
import {
  CLAUDE_MODEL_LIMITS,
  GPT56_CONTEXT_DEFAULT,
  GPT56_INPUT_DEFAULT,
  GPT56_MODEL_IDS,
  GPT56_OUTPUT_DEFAULT,
} from "./model-limits.mjs";

export { registerApprovedWorkerPermissions };
export { registerResearchOnlyAgent, enforcePublicTriageIsolation, registerManagedDirectoryPermissions };

/**
 * Shared model definition template for Claude models managed by aidevops.
 * @param {object} overrides
 * @returns {object}
 */
function claudeModelDef(overrides) {
  return {
    attachment: true,
    tool_call: false,
    temperature: true,
    reasoning: true,
    modalities: { input: ["text", "image"], output: ["text"] },
    cost: { input: 0, output: 0, cache_read: 0, cache_write: 0 },
    ...overrides,
  };
}

/**
 * Build a provider model map from CLAUDE_MODEL_LIMITS with provider-specific
 * display names. Preserves backward compatibility with the previous
 * ANTHROPIC_MODELS / CLAUDECLI_MODELS shapes.
 *
 * Note: CLAUDE_MODEL_LIMITS lives in `model-limits.mjs` so claude-proxy.mjs
 * (the Claude CLI proxy provider drift-copy that previously hardcoded the
 * same numbers) can share it. See model-limits.mjs for the env-var override
 * (AIDEVOPS_OPUS_47_CONTEXT) and the MRCR rationale.
 * @param {Record<string,string>} names - model id → display name
 * @returns {Record<string,object>}
 */
function buildClaudeModelMap(names) {
  const out = {};
  for (const [id, limit] of Object.entries(CLAUDE_MODEL_LIMITS)) {
    out[id] = claudeModelDef({ name: names[id] || id, limit });
  }
  return out;
}

/** Models registered under the built-in anthropic provider (via aidevops OAuth pool). */
const ANTHROPIC_MODELS = buildClaudeModelMap({
  "claude-haiku-4-5":  "Claude Haiku 4.5 (via aidevops)",
  "claude-sonnet-4-5": "Claude Sonnet 4.5 (via aidevops)",
  "claude-sonnet-4-6": "Claude Sonnet 4.6 (via aidevops)",
  "claude-opus-4-5":   "Claude Opus 4.5 (via aidevops)",
  "claude-opus-4-6":   "Claude Opus 4.6 (via aidevops)",
  "claude-opus-4-7":   "Claude Opus 4.7 (via aidevops)",
});

/** Models registered under the claudecli provider (via Claude CLI proxy). */
const CLAUDECLI_MODELS = buildClaudeModelMap({
  "claude-haiku-4-5":  "Claude Haiku 4.5 (via CLI)",
  "claude-sonnet-4-5": "Claude Sonnet 4.5 (via CLI)",
  "claude-sonnet-4-6": "Claude Sonnet 4.6 (via CLI)",
  "claude-opus-4-5":   "Claude Opus 4.5 (via CLI)",
  "claude-opus-4-6":   "Claude Opus 4.6 (via CLI)",
  "claude-opus-4-7":   "Claude Opus 4.7 (via CLI)",
});

/**
 * Upsert aidevops-managed models into the anthropic and claudecli providers.
 * Preserves any user options already set on the providers.
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} number of model entries upserted
 */
function registerAnthropicModels(config) {
  if (!config.provider) config.provider = {};
  let count = 0;

  // anthropic provider — via aidevops OAuth pool
  if (!config.provider.anthropic) config.provider.anthropic = {};
  if (!config.provider.anthropic.models) config.provider.anthropic.models = {};
  for (const [id, def] of Object.entries(ANTHROPIC_MODELS)) {
    const existing = config.provider.anthropic.models[id];
    // Always merge — ensures stale fields (modalities, attachment) get updated
    config.provider.anthropic.models[id] = { ...existing, ...def };
    if (!existing) count++;
  }

  // claudecli provider — via Claude CLI proxy
  if (!config.provider.claudecli) {
    config.provider.claudecli = {
      name: "Claude CLI",
      npm: "@ai-sdk/openai-compatible",
      api: "http://127.0.0.1:32125/v1",
    };
  } else if (
    config.provider.claudecli.name === "Claude CLI (coming soon)" ||
    config.provider.claudecli.name === "Claude CLI (via aidevops proxy)"
  ) {
    // Migrate legacy provider names
    config.provider.claudecli.name = "Claude CLI";
  }
  if (!config.provider.claudecli.models) config.provider.claudecli.models = {};
  for (const [id, def] of Object.entries(CLAUDECLI_MODELS)) {
    const existing = config.provider.claudecli.models[id];
    // Always merge — ensures stale fields (modalities, attachment) get updated
    config.provider.claudecli.models[id] = { ...existing, ...def };
    if (!existing) count++;
  }

  return count;
}

/**
 * Return whether aidevops should advertise a cost-aware 300K GPT-5.6 window.
 * The feature defaults on; users can opt out with `aidevops gpt56-context
 * disable`, which writes the durable preference consumed here on startup.
 * @returns {boolean}
 */
export function gpt56ContextCapEnabled() {
  const settingsPath = process.env.AIDEVOPS_SETTINGS_FILE ||
    join(homedir(), ".config", "aidevops", "settings.json");
  try {
    if (!existsSync(settingsPath)) return true;
    const settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
    return settings?.runtime?.opencode?.gpt56_context_cap !== false;
  } catch {
    return true;
  }
}

/**
 * Override built-in OpenAI GPT-5.6 model metadata without replacing any other
 * model fields. OpenCode validates plugin-added model entries before merging
 * built-in registry metadata, so every limit must include required fields.
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} number of model limits applied
 */
export function registerGpt56ContextLimits(config) {
  if (!gpt56ContextCapEnabled()) return 0;
  if (!config.provider) config.provider = {};
  if (!config.provider.openai) config.provider.openai = {};
  if (!config.provider.openai.models) config.provider.openai.models = {};

  for (const id of GPT56_MODEL_IDS) {
    const existing = config.provider.openai.models[id] || {};
    config.provider.openai.models[id] = {
      ...existing,
      limit: {
        output: GPT56_OUTPUT_DEFAULT,
        ...existing.limit,
        context: GPT56_CONTEXT_DEFAULT,
        input: GPT56_INPUT_DEFAULT,
      },
    };
  }
  return GPT56_MODEL_IDS.length;
}

/**
 * Discover models for a proxy provider and register them in config.
 * Deduplicates the cursor/google model discovery pattern.
 * @param {object} opts
 * @param {string} opts.provider - Pool provider name ("cursor" | "google")
 * @param {number} opts.port - Proxy port
 * @param {Function} opts.discoverModels - async (token) => models[]
 * @param {Function} opts.registerProvider - (config, port, models) => boolean
 * @param {object} opts.config - OpenCode Config object (mutable)
 * @returns {Promise<number>} Number of models registered
 */
async function discoverAndRegisterModels(opts) {
  const { provider, port, discoverModels, registerProvider, config } = opts;
  if (!port) return 0;

  try {
    const accounts = getAccounts(provider);
    const account = accounts.find((a) => a.status === "active");
    const token = account ? await ensureValidToken(provider, account) : null;
    const models = token ? await discoverModels(token) : [];

    if (models.length > 0 && registerProvider(config, port, models)) {
      return models.length;
    }
  } catch (err) {
    console.error(`[aidevops] Config hook: ${provider} model registration failed: ${err.message}`);
  }
  return 0;
}

/**
 * Register Claude CLI proxy models when the proxy is already running.
 *
 * When the proxy is NOT yet running (lazy-start path, GH#21944), the
 * `claudecli` provider entry was already eagerly registered by
 * `registerAnthropicModels` above with the hardcoded default port — leave
 * it intact so the models stay visible in the picker. The proxy will be
 * brought up by the system.transform hook on the first claudecli/* request.
 *
 * Historical behaviour deleted the entry when the proxy was absent, which
 * worked under the eager-startup model (the proxy was always running by
 * the time this hook fired) but would silently strip claudecli/* from the
 * picker now that startup is deferred. See GH#21944.
 *
 * @param {object} config - OpenCode Config object (mutable)
 * @returns {number} Number of models registered
 */
function registerClaudeCliModels(config) {
  const claudeProxyPort = getClaudeProxyPort();
  if (!claudeProxyPort) {
    // Proxy not running yet — registerAnthropicModels already populated the
    // provider with the hardcoded default port; lazy-start will bring up
    // the listener on the same port when needed.
    return 0;
  }
  const claudeModels = Object.entries(CLAUDECLI_MODELS).map(([id, def]) => ({
    id,
    name: def.name,
    reasoning: def.reasoning !== false,
    contextWindow: def.limit?.context || 200000,
    maxTokens: def.limit?.output || 32000,
  }));
  return registerClaudeProvider(config, claudeProxyPort, claudeModels)
    ? claudeModels.length
    : 0;
}

/**
 * Log a summary of config hook changes (silent when nothing changed).
 * @param {object} counts - config registration counts
 */
function logConfigSummary(counts) {
  const labels = [
    [counts.agents, "agents"],
    [counts.mcps, "MCPs"],
    [counts.agentTools, "agent tool perms"],
    [counts.directories, "managed directory perms"],
    [counts.permissionGrants, "signed worker permission grants"],
    [counts.poolCleaned, `cleaned ${counts.poolCleaned} stale pool provider${counts.poolCleaned === 1 ? "" : "s"}`],
    [counts.anthropic, "anthropic models"],
    [counts.openai, "OpenAI context limits"],
    [counts.cursor, "Cursor models"],
    [counts.google, "Google models"],
    [counts.claude, "Claude CLI models"],
  ];
  const parts = labels
    .filter(([n]) => n > 0)
    .map(([n, label]) => (typeof label === "string" && label.startsWith("cleaned")) ? label : `${n} ${label}`);

  if (parts.length > 0) {
    console.error(`[aidevops] Config hook: ${parts.join(", ")}`);
  }
}

/**
 * Check OpenCode/plugin version drift without blocking startup.
 * @param {string} pluginDir
 */
function logVersionDriftAsync(pluginDir) {
  checkOpenCodeVersionDriftAsync(pluginDir, (versionDrift) => {
    console.error(`[aidevops] Version drift: ${versionDrift}`);
  });
}

/**
 * Create the config hook function.
 * @param {object} deps - { agentsDir, workspaceDir, pluginDir, repositoryDir }
 * @returns {Function} Config hook
 */
export function createConfigHook(deps) {
  const {
    agentsDir,
    workspaceDir,
    pluginDir,
    repositoryDir,
    modelRouting,
    agentRoutingState = { tiers: new Map(), pinned: new Set() },
  } = deps;

  /**
   * Modify OpenCode config to register aidevops subagents, MCP servers,
   * and per-agent tool permissions.
   * @param {object} config - OpenCode Config object (mutable)
   */
  return async function configHook(config) {
    if (!config.agent) config.agent = {};
    agentRoutingState.tiers.clear();
    agentRoutingState.pinned.clear();

    let agents = registerAgents(config, agentsDir, modelRouting, agentRoutingState);
    ensureAgentGuard(config, workspaceDir);

    const mcps = registerMcpServers(config);
    const agentTools = applyAgentMcpTools(config);
    const directories = registerManagedDirectoryPermissions(config);
    const permissionGrants = registerApprovedWorkerPermissions(config, { repositoryDir });
    agents += registerResearchOnlyAgent(config, agentsDir);
    registerAgentRoutingIntent(
      agentRoutingState,
      "research-only",
      config.agent["research-only"],
      "standard",
      modelRouting,
    );
    const poolCleaned = registerPoolProvider(config);
    const anthropic = registerAnthropicModels(config);
    const openai = registerGpt56ContextLimits(config);
    // Discover and register proxy provider models only when a proxy listener is
    // already active. The normal startup path intentionally leaves these ports
    // null until first use, so unconditional imports/discovery here made config
    // hook latency depend on optional providers. See GH#22157.
    let cursor = 0;
    let google = 0;

    const cursorProxyPort = getCursorProxyPort();
    if (cursorProxyPort) {
      const { getCursorModels } = await import("./cursor/models.js");
      cursor = await discoverAndRegisterModels({
        provider: "cursor",
        port: cursorProxyPort,
        discoverModels: getCursorModels,
        registerProvider: registerCursorProvider,
        config,
      });
    }

    const googleProxyPort = getGoogleProxyPort();
    if (googleProxyPort) {
      const { discoverGoogleModels } = await import("./google-proxy.mjs");
      google = await discoverAndRegisterModels({
        provider: "google",
        port: googleProxyPort,
        discoverModels: discoverGoogleModels,
        registerProvider: registerGoogleProvider,
        config,
      });
    }

    const claude = registerClaudeCliModels(config);
    enforcePublicTriageIsolation(config);

    logConfigSummary(
      { agents, mcps, agentTools, directories, permissionGrants, poolCleaned, anthropic, openai, cursor, google, claude },
    );
    logVersionDriftAsync(pluginDir);
  };
}
