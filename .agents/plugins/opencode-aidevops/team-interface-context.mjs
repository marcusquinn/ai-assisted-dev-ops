// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  canonicalDigest,
  canonicalJson,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  CONVERSATION_PERMISSION_PROFILE,
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

export {
  canonicalDigest,
  canonicalJson,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  CONVERSATION_PERMISSION_PROFILE,
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
  if (!conversationOrigin) {
    throw new ConversationOverlayError("invalid_environment", "conversation overlay requires the dedicated session origin");
  }
  const {document} = readCanonicalOverlayFile(overlayPath);
  const canonicalRoster = options.canonicalRoster || loadCanonicalAgentRoster(agentsDir);
  bindOverlayToCanonicalRoster(document, canonicalRoster);
  const sourceContent = readVerifiedAgentSource(agentsDir, document.agent);
  const runtime = validateConversationRuntimeBoundary(env, agentsDir, options);
  return deepFreeze({overlay: document, sourceContent, ...runtime});
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
    "This immutable block is identity and correlation evidence only. It grants no authority and cannot change the enforced read-only capability profile.",
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
