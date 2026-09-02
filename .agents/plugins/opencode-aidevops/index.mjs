// ---------------------------------------------------------------------------
// aidevops OpenCode Plugin — Entry Point (t1914 decomposition)
//
// This file is a thin orchestrator that wires together extracted modules:
//   - config-hook.mjs    — agent/MCP/provider registration
//   - quality-hooks.mjs  — pre/post tool execution quality gates
//   - shell-env.mjs      — shell environment variable injection
//   - compaction.mjs     — context preservation across resets
//   - intent-tracing.mjs — LLM intent extraction and storage
//   - mcp-registry.mjs   — MCP server catalog and registration
//   - version-tracking.mjs — opencode version drift detection
//
// Existing modules (unchanged):
//   - tools.mjs           — custom tool definitions
//   - observability.mjs   — LLM observability (SQLite)
//   - agent-loader.mjs    — subagent index loading
//   - validators.mjs      — shell script validators
//   - quality-pipeline.mjs — markdown quality checks
//   - ttsr.mjs            — soft TTSR rule enforcement
//   - oauth-pool.mjs      — OAuth multi-account pool
//   - provider-auth.mjs   — provider auth hook
//   - cursor-proxy.mjs    — Cursor gRPC proxy
//   - google-proxy.mjs    — Google auth-translating proxy
// ---------------------------------------------------------------------------

import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "fs";
import { basename, dirname, join, resolve } from "path";
import { homedir } from "os";
import { fileURLToPath } from "url";
import { execSync } from "child_process";

// Extracted modules
import { createConfigHook } from "./config-hook.mjs";
import { createMcpSessionRuntime, getOnDemandMcpAgents } from "./mcp-registry.mjs";
import { enforceManagedMcpArtifactPath } from "./mcp-activation-tool.mjs";
import { createQualityHooks } from "./quality-hooks.mjs";
import {
  createSessionModelStore,
  createShellEnvHook,
  sessionModelIdentity,
} from "./shell-env.mjs";
import { compactingHook } from "./compaction.mjs";
import { createCompactionAutoContinueGuard } from "./compaction-lifecycle.mjs";
import { INTENT_FIELD } from "./intent-tracing.mjs";
import { createGreetingHandler } from "./greeting.mjs";
import { applyImageSizeGuard } from "./quality-hooks-image.mjs";
import { createSessionTitleFallbackHandler } from "./session-title-fallback.mjs";
import { createSessionTitleStatusHandler } from "./session-title-status.mjs";
import { createSessionTitleSuffixHandler } from "./session-title-suffix.mjs";
import { installPluginConsoleRouter } from "./plugin-console.mjs";
import {
  createSubagentEffortHooks,
  loadTierReasoningPolicies,
  resolveTierReasoning,
} from "./subagent-effort.mjs";
import { loadModelRouting } from "./model-routing.mjs";
import { createSessionContinuationGuard } from "./session-continuation-guard.mjs";
import { createSessionRecoveryMarkerHandler } from "./session-recovery-marker.mjs";
import { createSessionStallRecovery } from "./session-stall-recovery.mjs";
import { createPermissionBroker } from "./permission-broker.mjs";
import { createSubagentCancellationReceipt } from "./subagent-cancellation-receipt.mjs";
import { createRoutingFeedbackHandler } from "./routing-feedback-handler.mjs";
import { createSessionBoundaryAdvisory } from "./session-boundary-advisory.mjs";
import { createProviderErrorHandler } from "./provider-error-diagnostics.mjs";
import {
  appendConversationSystemContext,
  applyConversationRootVariant,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  loadTeamInterfaceConversation,
  isRestrictedConversation,
  isRemoteInteractiveConversation,
} from "./team-interface-context.mjs";
import { enforceConversationPathAccess } from "./team-interface-path-guard.mjs";

// Existing modules
import { createTools } from "./tools.mjs";
import {
  initObservability,
  getRoutingFeedback,
  handleEvent,
  recordRoutingDecision,
  recordSubagentCancellationReceipt,
  recordSubagentOutcome,
} from "./observability.mjs";
import { createSessionStartGreetingGate, createTtsrHooks } from "./ttsr.mjs";
import { createPoolAuthHook, createPoolTool, initPoolAuth, getAccounts } from "./oauth-pool.mjs";
import { createProviderAuthHook } from "./provider-auth.mjs";
import { installOpenAIProviderFetchRotation } from "./openai-provider-auth.mjs";
import { startCursorProxy, ensureCursorProxyServer } from "./cursor-proxy.mjs";
import { startGoogleProxy, ensureGoogleProxyServer } from "./google-proxy.mjs";
import { startClaudeProxy } from "./claude-proxy.mjs";
import { isHeadless } from "./proxy-lifecycle.mjs";
import { pluginHealthProbeRequested, recordPluginHealthStage } from "./plugin-health.mjs";

// ---------------------------------------------------------------------------
// Directory constants
// ---------------------------------------------------------------------------

const HOME = homedir();
const PLUGIN_ENTRY_PATH = realpathSync(fileURLToPath(import.meta.url));
const MODULE_AGENTS_DIR = realpathSync(resolve(dirname(PLUGIN_ENTRY_PATH), "../.."));
const CONVERSATION_ENVIRONMENT = process.env.AIDEVOPS_SESSION_ORIGIN === CONVERSATION_ORIGIN
  || Boolean(process.env[CONVERSATION_OVERLAY_ENV]);
const ACTIVE_AGENTS_DIR = CONVERSATION_ENVIRONMENT
  ? MODULE_AGENTS_DIR
  : join(HOME, ".aidevops", "agents");
// Resolve the activation link exactly once at plugin load. Every hook and shell
// spawned by this OpenCode process remains pinned to this immutable bundle.
const AGENTS_DIR = CONVERSATION_ENVIRONMENT ? MODULE_AGENTS_DIR : (() => {
  try {
    return realpathSync(ACTIVE_AGENTS_DIR);
  } catch {
    return ACTIVE_AGENTS_DIR;
  }
})();
const SCRIPTS_DIR = join(AGENTS_DIR, "scripts");
const PLUGIN_DIR = join(AGENTS_DIR, "plugins", "opencode-aidevops");
const WORKSPACE_DIR = join(HOME, ".aidevops", ".agent-workspace");
const LOGS_DIR = join(HOME, ".aidevops", "logs");

recordPluginHealthStage("imported");

// Keep the immutable bundle backing this process until OpenCode exits. Setup
// also applies an age floor for sessions started before lease support existed.
const RUNTIME_BUNDLE_LEASE = (() => {
  if (CONVERSATION_ENVIRONMENT) return "";
  const bundleDir = dirname(AGENTS_DIR);
  if (basename(dirname(bundleDir)) !== "runtime-bundles") return "";
  const lease = join(dirname(bundleDir), ".leases", basename(bundleDir), String(process.pid));
  try {
    mkdirSync(dirname(lease), { recursive: true });
    writeFileSync(lease, `${AGENTS_DIR}\n`, { mode: 0o600 });
    return lease;
  } catch {
    return "";
  }
})();

if (RUNTIME_BUNDLE_LEASE) {
  process.once("exit", () => {
    try {
      rmSync(RUNTIME_BUNDLE_LEASE, { force: true });
    } catch {
      // Dead-process lease cleanup is also performed by setup.
    }
  });
}

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

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

function currentAidevopsVersion() {
  const values = [
    readIfExists(join(ACTIVE_AGENTS_DIR, "VERSION")),
    readIfExists(join(AGENTS_DIR, "VERSION")),
    readIfExists(join(AGENTS_DIR, "..", "VERSION")),
    process.env.AIDEVOPS_VERSION,
  ];
  const value = values.find(Boolean) || "";
  return value.split(/\r?\n/, 1)[0].trim();
}

// ---------------------------------------------------------------------------
// Plugin diagnostics are persisted without writing over OpenCode's TUI.
// AIDEVOPS_PLUGIN_DEBUG=1 additionally mirrors them to stderr.
// ---------------------------------------------------------------------------

installPluginConsoleRouter({
  logPath: join(LOGS_DIR, "opencode-plugin.log"),
  debug: process.env.AIDEVOPS_PLUGIN_DEBUG === "1",
});

function createConversationHooks({client, conversation, directory}) {
  const configHook = createConfigHook({
    agentsDir: AGENTS_DIR,
    workspaceDir: WORKSPACE_DIR,
    pluginDir: PLUGIN_DIR,
    repositoryDir: directory,
    conversation,
  });
  const tierReasoning = loadTierReasoningPolicies([
    join(AGENTS_DIR, "custom", "configs", "model-routing-table.json"),
    join(AGENTS_DIR, "configs", "model-routing-table.json"),
  ]);
  return {
    config: configHook,
    "chat.message": async () => 0,
    "chat.params": async (input, output) => applyConversationRootVariant(
      input,
      output,
      conversation,
      {client, resolveVariant: resolveTierReasoning, tierReasoning},
    ),
    "tool.execute.before": async (input, output) => enforceConversationPathAccess(
      input.tool,
      output.args || {},
      conversation,
    ),
    "experimental.chat.system.transform": async (_input, output) =>
      appendConversationSystemContext(output, conversation),
  };
}

const prepareOptionalProxy = (label, prepare) => {
  prepare()
    .catch((err) => {
      console.error(`[aidevops] ${label} proxy failed to register: ${err.message}`);
    });
};

function prepareLocalProviderProxies(client) {
  const cursorAccounts = getAccounts("cursor");
  if (cursorAccounts.length > 0) {
    prepareOptionalProxy("Cursor gRPC", async () => {
      const result = await startCursorProxy(client);
      if (result) {
        console.error(`[aidevops] Cursor gRPC proxy registered on port ${result.port} with ${result.models.length} models (listener lazy)`);
      }
    });
  }

  const googleAccounts = getAccounts("google");
  if (googleAccounts.length > 0) {
    if (!process.env.GOOGLE_GENERATIVE_AI_API_KEY) {
      process.env.GOOGLE_GENERATIVE_AI_API_KEY = "google-pool-proxy";
    }
    prepareOptionalProxy("Google", async () => {
      const result = await startGoogleProxy(client);
      if (result) {
        console.error(`[aidevops] Google proxy registered on port ${result.port} with ${result.models.length} models (listener lazy)`);
      }
    });
  }
}

// ---------------------------------------------------------------------------
// Main Plugin Export
// ---------------------------------------------------------------------------

/**
 * aidevops OpenCode Plugin
 *
 * Provides:
 * 1. Config hook — lightweight agent index + MCP server registration (t1040)
 * 2. Custom tools — aidevops CLI, memory, pre-edit check, OAuth pool
 * 3. Quality hooks — full pre-commit pipeline on Write/Edit operations
 * 4. Shell environment — aidevops paths and variables
 * 5. Soft TTSR — preventative rule enforcement (t1304)
 * 6. LLM observability — event-driven data collection to SQLite (t1308)
 * 7. Intent tracing — logs LLM-provided intent alongside tool calls (t1309)
 * 8. Compaction context — preserves operational state across context resets
 * 9. OAuth multi-account pool — Anthropic, OpenAI, Cursor, Google (t1543+)
 *
 * @type {import('@opencode-ai/plugin').Plugin}
 */
export async function AidevopsPlugin({ directory, client }) {
  const initializedAtMs = Date.now();
  const conversation = loadTeamInterfaceConversation(process.env, AGENTS_DIR, {
    pluginEntryPath: PLUGIN_ENTRY_PATH,
    repositoryDir: directory,
  });

  if (isRestrictedConversation(conversation)) {
    return createConversationHooks({client, conversation, directory});
  }

  const mcpRuntime = createMcpSessionRuntime(WORKSPACE_DIR, { repositoryDir: directory });

  if (pluginHealthProbeRequested()) {
    const modelRouting = loadModelRouting([
      process.env.AIDEVOPS_MODEL_ROUTING_TABLE,
      join(AGENTS_DIR, "custom", "configs", "model-routing-table.json"),
      join(AGENTS_DIR, "configs", "model-routing-table.json"),
    ]);
    const configHook = createConfigHook({
      agentsDir: AGENTS_DIR,
      workspaceDir: WORKSPACE_DIR,
      pluginDir: PLUGIN_DIR,
      repositoryDir: directory,
      conversation,
      mcpRuntime,
      modelRouting,
      agentRoutingState: { tiers: new Map(), pinned: new Set() },
    });
    const sessionTitleStatusHandler = createSessionTitleStatusHandler({ isHeadless });
    recordPluginHealthStage("factory_initialized", {
      config_hook: true,
      terminal_title_status: true,
    });
    return {
      config: async (config) => {
        const result = await configHook(config);
        recordPluginHealthStage("config_applied", {
          gpt56_limits: config.provider?.openai?.models?.["gpt-5.6-sol"]?.limit || null,
          terminal_title_status: true,
        });
        return result;
      },
      event: sessionTitleStatusHandler,
    };
  }

  // Initialise LLM observability
  initObservability({ aidevopsVersion: currentAidevopsVersion() });

  // Cursor gRPC proxy — prepare models/provider in the background so OpenCode
  // startup never waits on network-bound model discovery or OAuth refresh.
  // Listener bind remains LAZY (see systemTransformHook below) — deferred until
  // the first cursor/* request. See GH#21948 and GH#22157.
  // Google auth-translating proxy — same non-blocking preparation / lazy
  // listener split as Cursor. The picker uses the last persisted provider entry
  // immediately, then refreshes when the background preparation completes.
  prepareLocalProviderProxies(client);

  // Claude CLI transport proxy — lazy-started on first claudecli/* request
  // (see systemTransformHook composition below). Eagerly starting on every
  // plugin init wasted resources in headless workers (which use anthropic/*
  // via OAuth pool, never claudecli/*) and caused N-instance EADDRINUSE
  // races when N OpenCode sessions started simultaneously. See GH#21944
  // for the original Claude-only fix and GH#21948 for the consolidation
  // that brought cursor + google onto the same lazy-start pattern.

  // Create tools
  const baseTools = createTools(SCRIPTS_DIR, run, {
    sessionOrigin: process.env.AIDEVOPS_SESSION_ORIGIN,
    poolToolFactory: () => createPoolTool(client),
    mcpClient: client.mcp,
    mcpDirectory: directory,
    managedMcpNames: getOnDemandMcpAgents().map((mcp) => mcp.name),
    managedMcpWorkspaces: mcpRuntime.workspaces,
  });

  // Create hooks from extracted modules
  const modelRouting = loadModelRouting([
    process.env.AIDEVOPS_MODEL_ROUTING_TABLE,
    join(AGENTS_DIR, "custom", "configs", "model-routing-table.json"),
    join(AGENTS_DIR, "configs", "model-routing-table.json"),
  ]);
  const agentRoutingState = { tiers: new Map(), pinned: new Set() };
  const configHook = createConfigHook({
    agentsDir: AGENTS_DIR,
    workspaceDir: WORKSPACE_DIR,
    pluginDir: PLUGIN_DIR,
    repositoryDir: directory,
    conversation,
    mcpRuntime,
    modelRouting,
    agentRoutingState,
  });

  const continuationGuard = createSessionContinuationGuard({
    repository: directory,
    checkpointHelper: join(SCRIPTS_DIR, "session-checkpoint-helper.sh"),
  });
  const sessionModels = createSessionModelStore();
  const { toolExecuteBefore, toolExecuteAfter, qualityLog } = createQualityHooks({
    activeScriptsDir: join(ACTIVE_AGENTS_DIR, "scripts"),
    scriptsDir: SCRIPTS_DIR,
    logsDir: LOGS_DIR,
    repositoryDir: directory,
    continuationGuard,
    resolveSessionModel: (sessionId) => sessionModels.resolve(sessionId),
  });

  const shellEnvHook = createShellEnvHook({
    activeAgentsDir: ACTIVE_AGENTS_DIR,
    agentsDir: AGENTS_DIR,
    scriptsDir: SCRIPTS_DIR,
    workspaceDir: WORKSPACE_DIR,
    onSessionIdentity: (sessionId, modelId) => sessionModels.remember(sessionId, modelId),
  });
  const tierReasoning = Object.fromEntries(
    Object.entries(modelRouting.tiers).map(([tier, route]) => [tier, route.reasoning]),
  );
  const subagentEffortHooks = createSubagentEffortHooks(client, {
    tierReasoning,
    modelRouting,
    agentRoutingState,
    onRoutingDecision: recordRoutingDecision,
    onSubagentOutcome: recordSubagentOutcome,
    isHeadless,
    qualityLog,
  });
  const shouldInjectGreeting = createSessionStartGreetingGate(client, isHeadless);
  const permissionBroker = createPermissionBroker({ client, isHeadless });
  const compactionContinuation = createCompactionAutoContinueGuard(client, { qualityLog });
  const cancellationReceipt = createSubagentCancellationReceipt(client, {
    qualityLog,
    recordReceipt: recordSubagentCancellationReceipt,
  });

  // TTSR hooks
  const {
    systemTransformHook: ttsrSystemTransformHook,
    messagesTransformHook: ttsrMessagesTransformHook,
    textCompleteHook,
  } = createTtsrHooks({
    agentsDir: AGENTS_DIR,
    scriptsDir: SCRIPTS_DIR,
    readIfExists,
    qualityLog,
    run,
    intentField: INTENT_FIELD,
    isHeadless,
    shouldInjectGreeting,
    initializedAtMs,
  });

  // Lazy-start dispatch table for local proxies. Keys are OpenCode
  // `model.providerID` values; values are thunks that bring up the
  // proxy listener on demand via the shared lifecycle helper (which
  // handles probe-first adoption, EADDRINUSE retry, and idempotent
  // re-entry — see proxy-lifecycle.mjs). Repeat calls per request are
  // cheap because the lifecycle caches the bound port. Headless workers
  // skip dispatch entirely (they only ever target anthropic/* via the
  // OAuth pool). See GH#21944 (Claude-only original) and GH#21948
  // (consolidation across all three proxies).
  const proxyStarters = {
    claudecli: () => startClaudeProxy(client, directory),
    cursor: () => ensureCursorProxyServer(),
    google: () => ensureGoogleProxyServer(),
  };

  // Composed system.transform hook: lazy-start the appropriate local
  // proxy on the first request whose providerID matches, then delegate
  // to TTSR enforcement. Failures here are logged but never block the
  // request — the underlying provider call will surface a clearer error
  // if the proxy is genuinely unreachable.
  const systemTransformHook = async (input, output) => {
    const providerID = input?.model?.providerID;
    if (providerID && !isHeadless()) {
      const starter = proxyStarters[providerID];
      if (starter) {
        try {
          await starter();
        } catch (err) {
          console.error(`[aidevops] ${providerID} proxy lazy-start failed: ${err.message}`);
        }
      }
    }
    await ttsrSystemTransformHook(input, output);
    if (isRemoteInteractiveConversation(conversation)) {
      appendConversationSystemContext(output, conversation);
    }
  };

  // Composed messages transform: TTSR enforcement + image size guard (GH#21793).
  // The image guard runs after TTSR so corrections are applied to the final
  // message list. Fail-open — errors in the guard must not block the message.
  const messagesTransformHook = async (input, output) => {
    await ttsrMessagesTransformHook(input, output);
    try {
      applyImageSizeGuard(output, qualityLog);
    } catch (err) {
      qualityLog("WARN", `[image-size-guard] Unexpected error: ${err?.message ?? err}`);
    }
  };

  // Compose recovery completion validation after TTSR annotations. The guard
  // only changes explicit terminal claims; ordinary progress remains intact.
  const completionTextHook = async (input, output) => {
    await textCompleteHook(input, output);
    continuationGuard.completeText(input, output);
  };

  // Greeting handler (t2724) — emits session-start framework status as
  // TUI toasts via client.tui.showToast(). Fires once per plugin init on
  // the first session.created event. See greeting.mjs for classification
  // and variant rules.
  const greetingHandler = createGreetingHandler({
    scriptsDir: SCRIPTS_DIR,
    client,
    isHeadless,
    initializedAtMs,
  });
  const sessionTitleSuffixHandler = createSessionTitleSuffixHandler({
    activeAgentsDir: ACTIVE_AGENTS_DIR,
    agentsDir: AGENTS_DIR,
    client,
  });
  const sessionTitleStatusHandler = createSessionTitleStatusHandler({ isHeadless });
  const routingFeedbackHandler = createRoutingFeedbackHandler({ client, isHeadless, getFeedback: getRoutingFeedback });
  const sessionBoundaryAdvisory = createSessionBoundaryAdvisory({
    client,
    isHeadless,
    hasCompetingToast: (sessionID) => routingFeedbackHandler.hasPending(sessionID),
  });
  const providerErrorHandler = createProviderErrorHandler({
    client,
    isHeadless,
    resolveSessionModel: (sessionId) => sessionModels.resolve(sessionId),
  });
  const sessionTitleFallbackHandler = createSessionTitleFallbackHandler({
    agentsDir: ACTIVE_AGENTS_DIR,
    client,
  });
  const sessionRecoveryMarkerHandler = createSessionRecoveryMarkerHandler({
    directory,
    dataDir: process.env.XDG_DATA_HOME || "",
    workDir: process.env.AIDEVOPS_WORK_DIR || join(WORKSPACE_DIR, "work"),
  });
  const sessionStallRecovery = createSessionStallRecovery({
    client,
    directory,
    workDir: process.env.AIDEVOPS_WORK_DIR || join(WORKSPACE_DIR, "work"),
    log: qualityLog,
  });

  const debugEventError = (label, err) => {
    if (process.env.AIDEVOPS_PLUGIN_DEBUG) {
      console.error(`[aidevops] ${label} error:`, err);
    }
  };

  recordPluginHealthStage("factory_initialized", {
    config_hook: true,
    session_boundary_advisory: true,
    terminal_title_status: true,
  });

  return {
    // Config: agent index, MCP registration, OAuth pool injection
    config: async (config) => {
      // HOTFIX: run initPoolAuth non-blocking — OpenCode 1.4.8 blocks
      // on client.auth.set() inside the config hook. Fire-and-forget so
      // the config hook can complete and the session becomes responsive.
      initPoolAuth(client).catch(() => {});
      const result = await configHook(config);
      recordPluginHealthStage("config_applied", {
        gpt56_limits: config.provider?.openai?.models?.["gpt-5.6-sol"]?.limit || null,
        terminal_title_status: true,
      });
      return result;
    },

    // Custom tools + pool management
    tool: baseTools,

    // Record routed request identity and select parent-safe child effort.
    "chat.message": subagentEffortHooks.chatMessage,
    "chat.params": async (input, output) => {
      const { sessionId, modelId } = sessionModelIdentity(input);
      sessionModels.remember(sessionId, modelId);
      await subagentEffortHooks.chatParams(input, output);
      return applyConversationRootVariant(
        input,
        output,
        isRestrictedConversation(conversation) ? conversation : null,
        {
        client,
        resolveVariant: resolveTierReasoning,
        tierReasoning,
        },
      );
    },

    // Quality hooks
    "tool.execute.before": async (input, output) => {
      enforceManagedMcpArtifactPath(input, output, mcpRuntime.workspaces);
      sessionStallRecovery.beforeTool(input, output);
      permissionBroker.recordToolCall(input, output);
      cancellationReceipt.beforeTool(input, output);
      subagentEffortHooks.beforeTool(input, output);
      return toolExecuteBefore(input, output);
    },
    "tool.execute.after": async (input, output) => {
      sessionStallRecovery.afterTool(input, output);
      await cancellationReceipt.afterTool(input, output);
      await subagentEffortHooks.afterTool(input, output);
      return toolExecuteAfter(input, output);
    },

    // Shell environment
    "shell.env": shellEnvHook,

    // Soft TTSR — rule enforcement
    "experimental.chat.system.transform": systemTransformHook,
    "experimental.chat.messages.transform": messagesTransformHook,
    "experimental.text.complete": completionTextHook,

    // LLM observability + session-start toast greeting (t2724).
    // Both run on every event; greeting self-gates to session.created.
    event: async (input) => {
      // Fire both in parallel — neither depends on the other's result.
      await Promise.all([
        handleEvent(input, { resolveSessionModel: (sessionId) => sessionModels.resolve(sessionId) }),
        Promise.resolve(subagentEffortHooks.handleEvent(input)),
        compactionContinuation.handleEvent(input),
        Promise.resolve(cancellationReceipt.handleEvent(input)),
        permissionBroker.handleEvent(input).catch((err) => debugEventError("permission broker", err)),
        sessionTitleStatusHandler(input).catch((err) => debugEventError("title status handler", err)),
        routingFeedbackHandler(input).catch((err) => debugEventError("routing feedback handler", err)),
        sessionBoundaryAdvisory(input).catch((err) => debugEventError("session boundary advisory", err)),
        providerErrorHandler(input).catch((err) => debugEventError("provider error handler", err)),
        sessionTitleSuffixHandler(input).catch((err) => debugEventError("title suffix handler", err)),
        sessionTitleFallbackHandler(input).catch((err) => debugEventError("title fallback handler", err)),
        sessionRecoveryMarkerHandler(input).catch((err) => debugEventError("session recovery marker", err)),
        Promise.resolve(sessionStallRecovery.handleEvent(input)),
        greetingHandler(input).catch((err) => debugEventError("greeting handler", err)),
      ]);
    },

    // Legacy OpenCode compatibility. Current runtimes publish
    // `permission.asked` through the event hook instead.
    "permission.ask": permissionBroker.permissionAsk,

    // OAuth multi-account pool + provider auth
    auth: (() => {
      const poolHook = createPoolAuthHook(client);
      const providerHook = createProviderAuthHook(client);
      installOpenAIProviderFetchRotation(client);
      return {
        provider: "anthropic",
        methods: poolHook.methods,
        loader: providerHook.loader,
      };
    })(),

    // Compaction context
    "experimental.session.compacting": async (input, output) =>
      compactingHook(
        { workspaceDir: WORKSPACE_DIR, scriptsDir: SCRIPTS_DIR },
        input,
        output,
        directory,
      ),
    "experimental.compaction.autocontinue": compactionContinuation.autoContinue,
  };
}
