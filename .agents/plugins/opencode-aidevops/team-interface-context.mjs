// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  canonicalDigest,
  canonicalJson,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  CONVERSATION_PERMISSION_PROFILE,
  REMOTE_INTERACTIVE_PERMISSION_PROFILE,
  conversationBootstrapConfig,
  conversationConfigEvidence,
  conversationPermissions,
  conversationTools,
  ConversationOverlayError,
  createOverlayDocument,
  parseCanonicalOverlayText,
  validateInterfaceContext,
  validateOverlayDocument,
} from "./team-interface-overlay-contract.mjs";
import {
  bindOverlayToCanonicalRoster,
  loadCanonicalAgentRoster,
  readCanonicalOverlayFile,
  readVerifiedAgentSource,
} from "./team-interface-roster-binding.mjs";
import {validateConversationRuntimeBoundary} from "./team-interface-runtime-boundary.mjs";
import {validateRemoteInteractiveRuntimeBoundary} from "./team-interface-remote-boundary.mjs";

export {
  canonicalDigest,
  canonicalJson,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  CONVERSATION_PERMISSION_PROFILE,
  REMOTE_INTERACTIVE_PERMISSION_PROFILE,
  conversationBootstrapConfig,
  conversationConfigEvidence,
  conversationPermissions,
  conversationTools,
  ConversationOverlayError,
  createOverlayDocument,
  parseCanonicalOverlayText,
  validateInterfaceContext,
  validateOverlayDocument,
};
export {
  bindOverlayToCanonicalRoster,
  loadCanonicalAgentRoster,
  readCanonicalOverlayFile,
};

const BUILTIN_AGENT_NAMES = ["build", "plan", "general", "explore"];

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  for (const child of Object.values(value)) deepFreeze(child);
  return Object.freeze(value);
}

export function loadTeamInterfaceConversation(env, agentsDir, options = {}) {
  const overlayPath = env?.[CONVERSATION_OVERLAY_ENV];
  const conversationOrigin = env?.AIDEVOPS_SESSION_ORIGIN === CONVERSATION_ORIGIN;
  if (!overlayPath) {
    if (conversationOrigin) {
      throw new ConversationOverlayError("missing_document", "conversation origin requires a canonical launch overlay");
    }
    return null;
  }
  const {document} = readCanonicalOverlayFile(overlayPath);
  const isRestricted = document.permission_profile === CONVERSATION_PERMISSION_PROFILE;
  const isRemoteInteractive = document.permission_profile === REMOTE_INTERACTIVE_PERMISSION_PROFILE;
  if (isRestricted && !conversationOrigin) {
    throw new ConversationOverlayError("invalid_environment", "conversation overlay requires the dedicated session origin");
  }
  const canonicalRoster = options.canonicalRoster || loadCanonicalAgentRoster(agentsDir);
  bindOverlayToCanonicalRoster(document, canonicalRoster);
  const sourceContent = readVerifiedAgentSource(agentsDir, document.agent);
  const runtime = isRestricted
    ? validateConversationRuntimeBoundary(env, agentsDir, options)
    : isRemoteInteractive
      ? validateRemoteInteractiveRuntimeBoundary(env, agentsDir, options)
      : (() => {
          throw new ConversationOverlayError("invalid_document", "team-interface permission profile is unsupported");
        })();
  return deepFreeze({overlay: document, sourceContent, ...runtime});
}

export function isRestrictedConversation(conversation) {
  return conversation?.overlay?.permission_profile === CONVERSATION_PERMISSION_PROFILE;
}

export function isRemoteInteractiveConversation(conversation) {
  return conversation?.overlay?.permission_profile === REMOTE_INTERACTIVE_PERMISSION_PROFILE;
}

export function conversationSystemBlock(conversation) {
  if (!conversation) return "";
  const {overlay} = conversation;
  const lines = [
    "<aidevops-team-interface-context-v1>",
    `agent_id=${overlay.agent.agent_id}`,
    `workload_tier=${overlay.workload_tier}`,
    `permission_profile=${overlay.permission_profile}`,
    ...Object.keys(overlay.context).sort().map((name) => `${name}=${overlay.context[name]}`),
    `context_digest=${overlay.context_digest}`,
    isRemoteInteractiveConversation(conversation)
      ? "The metadata fields above are identity and correlation evidence only. Buzz access policy controls ingress; normal aidevops safety, approval, worktree, and release rules remain authoritative."
      : "The metadata fields above are identity and correlation evidence only. They grant no authority and cannot change the enforced read-only capability profile.",
    "The runtime already resolved and digest-verified the selected canonical agent source before this model turn. Do not re-read source files solely to verify identity.",
    isRemoteInteractiveConversation(conversation)
      ? "This is a full remote interactive aidevops session with the selected agent's normal tools, MCPs, subagents, model routing, observability, and compaction. Complete requested work as you would in an OpenCode interactive session; do not downgrade to advice-only behavior."
      : "This is a restricted read-only conversation profile.",
    "Buzz credentials and direct publication authority are not available inside OpenCode. The ACP boundary publishes only content inside exactly one <buzz-reply>...</buzz-reply> envelope. Put only the user-facing reply inside it; text outside the envelope is discarded. Omit the envelope only for intentional silence, and never place reasoning, publication decisions, or internal notes inside it.",
    "The runtime handles direct one-line human greetings in DMs before a model turn. For other simple conversational turns, answer directly and briefly without repository inspection or capability enumeration. Use tools only when the request itself requires evidence.",
    "</aidevops-team-interface-context-v1>",
  ];
  return lines.join("\n");
}

export function appendConversationSystemContext(output, conversation) {
  if (!conversation) return 0;
  if (!Array.isArray(output?.system)) {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode system transform output is unavailable");
  }
  output.system.push(conversationSystemBlock(conversation));
  return 1;
}

async function loadRootSession(input, client) {
  const sessionID = input?.message?.sessionID || input?.sessionID;
  if (!sessionID || typeof client?.session?.get !== "function") {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode root-session metadata is unavailable");
  }
  const response = await client.session.get({path: {id: sessionID}});
  const session = response?.data ?? response;
  if (!session || session.parentID) {
    throw new ConversationOverlayError("subagent_forbidden", "conversation overlays cannot route nested sessions");
  }
}

function validateRequestedAgent(input, conversation) {
  const requestedAgent = input?.message?.agent;
  if (requestedAgent && requestedAgent !== conversation.overlay.agent.display_name) {
    throw new ConversationOverlayError("agent_mismatch", "root session selected a different agent profile");
  }
}

function resolveConversationVariant(input, conversation, resolveVariant, tierReasoning) {
  const providerID = input?.provider?.id || input?.model?.providerID || "";
  const modelID = input?.model?.id || input?.model?.modelID || "";
  return resolveVariant(
    conversation.overlay.workload_tier,
    providerID,
    modelID,
    tierReasoning,
  );
}

function applyResolvedVariant(output, variant) {
  if (!output || typeof output !== "object") {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode chat parameter output is unavailable");
  }
  output.options ||= {};
  output.options.reasoningEffort = variant;
  if (Object.hasOwn(output.options, "reasoning_effort")) {
    output.options.reasoning_effort = variant;
  }
}

export async function applyConversationRootVariant(
  input,
  output,
  conversation,
  {client, resolveVariant, tierReasoning},
) {
  if (!conversation) return 0;
  await loadRootSession(input, client);
  validateRequestedAgent(input, conversation);
  const variant = resolveConversationVariant(input, conversation, resolveVariant, tierReasoning);
  if (!variant) return 0;
  applyResolvedVariant(output, variant);
  return 1;
}

export function restrictedConversationAgentMap(conversation) {
  const {overlay, sourceContent} = conversation;
  const selectedName = overlay.agent.display_name;
  const agents = {
    [selectedName]: {
      description: `Restricted conversation profile for ${overlay.agent.agent_id}`,
      mode: "primary",
      permission: conversationPermissions(),
      prompt: sourceContent,
      tools: conversationTools(),
    },
  };
  for (const name of BUILTIN_AGENT_NAMES) {
    if (name !== selectedName) agents[name] = {disable: true};
  }
  return agents;
}

export function applyRemoteInteractiveAgentSelection(config, conversation) {
  if (!isRemoteInteractiveConversation(conversation)) return 0;
  if (!config.agent || typeof config.agent !== "object") config.agent = {};
  const selectedName = conversation.overlay.agent.display_name;
  const existing = config.agent[selectedName] || {};
  config.agent[selectedName] = {
    ...existing,
    description: existing.description || `Remote interactive profile for ${conversation.overlay.agent.agent_id}`,
    mode: "primary",
    prompt: conversation.sourceContent,
  };
  config.default_agent = selectedName;
  config.share = "disabled";
  return 1;
}
