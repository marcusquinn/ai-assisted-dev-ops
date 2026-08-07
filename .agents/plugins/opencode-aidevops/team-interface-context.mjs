// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
} from "node:fs";
import {isAbsolute, join, resolve} from "node:path";
import {
  canonicalDigest,
  canonicalJson,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  CONVERSATION_PERMISSION_PROFILE,
  conversationConfigEvidence,
  conversationPermissions,
  conversationTools,
  ConversationOverlayError,
  createOverlayDocument,
  parseCanonicalOverlayText,
  sourceFilenameFromReference,
  validateInterfaceContext,
  validateOverlayDocument,
} from "./team-interface-overlay-contract.mjs";

export {
  canonicalDigest,
  canonicalJson,
  CONVERSATION_ORIGIN,
  CONVERSATION_OVERLAY_ENV,
  CONVERSATION_PERMISSION_PROFILE,
  conversationConfigEvidence,
  conversationPermissions,
  conversationTools,
  ConversationOverlayError,
  createOverlayDocument,
  parseCanonicalOverlayText,
  validateInterfaceContext,
  validateOverlayDocument,
};

const BUILTIN_AGENT_NAMES = ["build", "plan", "general", "explore"];
const MAX_OVERLAY_BYTES = 64 * 1024;
const MAX_AGENT_SOURCE_BYTES = 1024 * 1024;

function readBoundedRegularFile(filePath, maximumBytes, label) {
  const absolutePath = resolve(filePath);
  let before;
  try {
    before = lstatSync(absolutePath);
  } catch {
    throw new ConversationOverlayError("missing_document", `${label} is unavailable`);
  }
  if (!before.isFile() || before.isSymbolicLink()) {
    throw new ConversationOverlayError("unsafe_path", `${label} must be a regular non-symlink file`);
  }
  if (before.size > maximumBytes) {
    throw new ConversationOverlayError("document_too_large", `${label} exceeds its size limit`);
  }

  let descriptor;
  try {
    descriptor = openSync(absolutePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0));
    const opened = fstatSync(descriptor);
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino) {
      throw new ConversationOverlayError("unsafe_path", `${label} changed while it was opened`);
    }
    const bytes = readFileSync(descriptor);
    if (bytes.length > maximumBytes) {
      throw new ConversationOverlayError("document_too_large", `${label} exceeds its size limit`);
    }
    const after = lstatSync(absolutePath);
    if (!after.isFile() || after.isSymbolicLink() || after.dev !== opened.dev || after.ino !== opened.ino) {
      throw new ConversationOverlayError("unsafe_path", `${label} changed while it was read`);
    }
    return {absolutePath, bytes, contents: bytes.toString("utf8")};
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

export function readCanonicalOverlayFile(filePath) {
  if (!isAbsolute(filePath || "")) {
    throw new ConversationOverlayError("unsafe_path", "OpenCode launch overlay path must be absolute");
  }
  const {absolutePath, contents} = readBoundedRegularFile(filePath, MAX_OVERLAY_BYTES, "OpenCode launch overlay");
  return {absolutePath, document: parseCanonicalOverlayText(contents)};
}

function readVerifiedAgentSource(agentsDir, agent) {
  const sourcePath = join(resolve(agentsDir), sourceFilenameFromReference(agent.source_ref));
  const {bytes, contents} = readBoundedRegularFile(sourcePath, MAX_AGENT_SOURCE_BYTES, "selected agent source");
  const sourceDigest = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
  if (sourceDigest !== agent.source_digest) {
    throw new ConversationOverlayError("digest_mismatch", "selected agent source digest no longer matches the overlay");
  }
  return contents;
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  for (const child of Object.values(value)) deepFreeze(child);
  return Object.freeze(value);
}

export function loadTeamInterfaceConversation(env, agentsDir) {
  const overlayPath = env?.[CONVERSATION_OVERLAY_ENV];
  if (!overlayPath) return null;
  if (env.AIDEVOPS_SESSION_ORIGIN !== CONVERSATION_ORIGIN) {
    throw new ConversationOverlayError("invalid_environment", "conversation overlay requires the dedicated session origin");
  }
  const {document} = readCanonicalOverlayFile(overlayPath);
  const sourceContent = readVerifiedAgentSource(agentsDir, document.agent);
  return deepFreeze({overlay: document, sourceContent});
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

export async function applyConversationRootVariant(
  input,
  output,
  conversation,
  {client, resolveVariant, tierReasoning},
) {
  if (!conversation) return 0;
  const sessionID = input?.message?.sessionID || input?.sessionID;
  if (!sessionID || typeof client?.session?.get !== "function") {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode root-session metadata is unavailable");
  }
  const response = await client.session.get({path: {id: sessionID}});
  const session = response?.data ?? response;
  if (!session || session.parentID) {
    throw new ConversationOverlayError("subagent_forbidden", "conversation overlays cannot route nested sessions");
  }
  const requestedAgent = input?.message?.agent;
  if (requestedAgent && requestedAgent !== conversation.overlay.agent.display_name) {
    throw new ConversationOverlayError("agent_mismatch", "root session selected a different agent profile");
  }
  const providerID = input?.provider?.id || input?.model?.providerID || "";
  const modelID = input?.model?.id || input?.model?.modelID || "";
  const variant = resolveVariant(
    conversation.overlay.workload_tier,
    providerID,
    modelID,
    tierReasoning,
  );
  if (!variant) return 0;
  if (!output || typeof output !== "object") {
    throw new ConversationOverlayError("runtime_incompatible", "OpenCode chat parameter output is unavailable");
  }
  output.options ||= {};
  output.options.reasoningEffort = variant;
  if (Object.hasOwn(output.options, "reasoning_effort")) {
    output.options.reasoning_effort = variant;
  }
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
