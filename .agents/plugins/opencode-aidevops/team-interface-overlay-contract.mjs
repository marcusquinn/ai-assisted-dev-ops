// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {createHash} from "node:crypto";

export const CONVERSATION_OVERLAY_ENV = "AIDEVOPS_TEAM_INTERFACE_OVERLAY";
export const CONVERSATION_ORIGIN = "conversation";
export const CONVERSATION_PERMISSION_PROFILE = "conversation_read_only_v1";
export const REMOTE_INTERACTIVE_PERMISSION_PROFILE = "remote_interactive_v1";

const DOCUMENT_KEYS = [
  "agent",
  "config_digest",
  "context",
  "context_digest",
  "document_type",
  "overlay_digest",
  "overlay_id",
  "permission_profile",
  "roster_digest",
  "roster_id",
  "schema_version",
  "workload_tier",
];
const AGENT_KEYS = ["agent_id", "display_name", "kind", "source_digest", "source_ref"];
const CONTEXT_PREFIXES = Object.freeze({
  actor_ref: "actor",
  app_team_ref: "app-team",
  community_ref: "community",
  conversation_ref: "conversation",
  correlation_ref: "correlation",
  provider_ref: "provider",
  trust_ref: "trust",
});
const DIGEST_PATTERN = /^sha256:[a-f0-9]{64}$/;
const AGENT_ID_PATTERN = /^agent\.[a-z0-9][a-z0-9._-]*$/;
const SOURCE_REF_PATTERN = /^agents:([A-Za-z0-9][A-Za-z0-9._-]*\.md)$/;
const REFERENCE_PAYLOAD_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$/;
const WORKLOAD_TIERS = new Set(["simple", "standard", "thinking"]);
const PERMISSION_PROFILES = new Set([
  CONVERSATION_PERMISSION_PROFILE,
  REMOTE_INTERACTIVE_PERMISSION_PROFILE,
]);

export class ConversationOverlayError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ConversationOverlayError";
    this.code = code;
  }
}

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function canonicalDigest(value) {
  return `sha256:${createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ConversationOverlayError("invalid_document", `${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (canonicalJson(actual) !== canonicalJson(wanted)) {
    throw new ConversationOverlayError("invalid_document", `${label} contains missing or unsupported fields`);
  }
}

function requireDigest(value, label) {
  if (!DIGEST_PATTERN.test(value || "")) {
    throw new ConversationOverlayError("invalid_digest", `${label} must be a tagged SHA-256 digest`);
  }
}

function validateReference(name, value) {
  const prefix = CONTEXT_PREFIXES[name];
  if (typeof value !== "string" || !value.startsWith(`${prefix}:`)) {
    throw new ConversationOverlayError("invalid_reference", `${name} must use the ${prefix}: reference namespace`);
  }
  const payload = value.slice(prefix.length + 1);
  const pathSegments = payload.split("/");
  if (
    !REFERENCE_PAYLOAD_PATTERN.test(payload)
    || value.includes("://")
    || /[\\~@=\u0000-\u001f\u007f]/u.test(value)
    || pathSegments.some((segment) => segment === "." || segment === "..")
  ) {
    throw new ConversationOverlayError("invalid_reference", `${name} is not a bounded interface reference`);
  }
}

export function validateInterfaceContext(context) {
  exactKeys(context, Object.keys(CONTEXT_PREFIXES), "interface context");
  for (const name of Object.keys(CONTEXT_PREFIXES)) validateReference(name, context[name]);
  return context;
}

function readPermissionRules() {
  return {
    "*": "allow",
    "*.env": "deny",
    "*.env.*": "deny",
    "*.env.example": "allow",
    "**/.env": "deny",
    "**/.env.*": "deny",
    "**/.env.example": "allow",
    "**/.ssh/**": "deny",
    "**/.gnupg/**": "deny",
    "**/.aws/**": "deny",
    "**/.azure/**": "deny",
    "**/.kube/**": "deny",
    "**/.config/gh/**": "deny",
    "**/.docker/**": "deny",
    "**/.netrc": "deny",
    "**/.npmrc": "deny",
    "**/.pypirc": "deny",
    "**/.git-credentials": "deny",
    "**/auth.json": "deny",
  };
}

export function conversationTools() {
  return {
    "*": false,
    apply_patch: false,
    bash: false,
    edit: false,
    glob: true,
    grep: true,
    question: false,
    read: true,
    skill: false,
    task: false,
    todowrite: false,
    webfetch: false,
    websearch: false,
    write: false,
  };
}

export function conversationPermissions() {
  return {
    "*": "deny",
    apply_patch: "deny",
    bash: "deny",
    edit: "deny",
    external_directory: "deny",
    glob: "allow",
    grep: "allow",
    question: "deny",
    read: readPermissionRules(),
    skill: "deny",
    task: "deny",
    todowrite: "deny",
    webfetch: "deny",
    websearch: "deny",
    write: "deny",
  };
}

export function conversationBootstrapConfig(pluginUrl) {
  let parsedPluginUrl;
  try {
    parsedPluginUrl = new URL(pluginUrl);
  } catch {
    throw new ConversationOverlayError("invalid_environment", "conversation plugin URL is invalid");
  }
  const forbiddenUrlParts = [
    parsedPluginUrl.username,
    parsedPluginUrl.password,
    parsedPluginUrl.search,
    parsedPluginUrl.hash,
  ].filter(Boolean);
  if (parsedPluginUrl.protocol !== "file:" || forbiddenUrlParts.length > 0) {
    throw new ConversationOverlayError("invalid_environment", "conversation plugin URL must identify one local file");
  }
  return {
    "$schema": "https://opencode.ai/config.json",
    command: {},
    formatter: false,
    instructions: [],
    lsp: false,
    mcp: {},
    permission: conversationPermissions(),
    plugin: [parsedPluginUrl.href],
    share: "disabled",
    snapshot: false,
    tools: conversationTools(),
  };
}

export function conversationConfigEvidence(agentName) {
  const profile = {
    mode: "primary",
    permission: conversationPermissions(),
    tools: conversationTools(),
  };
  return {
    agent: {[agentName]: profile},
    default_agent: agentName,
    formatter: false,
    lsp: false,
    mcp: {},
    permission: conversationPermissions(),
    permission_profile: CONVERSATION_PERMISSION_PROFILE,
    share: "disabled",
    snapshot: false,
    subagent_depth: 0,
    tools: conversationTools(),
  };
}

export function remoteInteractiveConfigEvidence(agentName) {
  return {
    default_agent: agentName,
    permission_profile: REMOTE_INTERACTIVE_PERMISSION_PROFILE,
  };
}

export function configEvidenceForPermissionProfile(agentName, permissionProfile) {
  if (permissionProfile === CONVERSATION_PERMISSION_PROFILE) {
    return conversationConfigEvidence(agentName);
  }
  if (permissionProfile === REMOTE_INTERACTIVE_PERMISSION_PROFILE) {
    return remoteInteractiveConfigEvidence(agentName);
  }
  throw new ConversationOverlayError("invalid_document", "team-interface permission profile is not supported");
}

export function sourceFilenameFromReference(sourceRef) {
  const match = SOURCE_REF_PATTERN.exec(sourceRef || "");
  if (!match) {
    throw new ConversationOverlayError("invalid_agent", "selected agent source reference is invalid");
  }
  return match[1];
}

function validAgentDisplayName(value) {
  if (typeof value !== "string") return false;
  if (value.trim() !== value) return false;
  if (value.length < 1 || value.length > 100) return false;
  return !/[/\\~\u0000-\u001f\u007f]/u.test(value);
}

function validateSelectedAgent(agent) {
  exactKeys(agent, AGENT_KEYS, "selected agent");
  if (!AGENT_ID_PATTERN.test(agent.agent_id || "")) {
    throw new ConversationOverlayError("invalid_agent", "selected agent ID is invalid");
  }
  if (!["primary", "framework_guide"].includes(agent.kind)) {
    throw new ConversationOverlayError("invalid_agent", "selected agent kind is invalid");
  }
  if (!validAgentDisplayName(agent.display_name)) {
    throw new ConversationOverlayError("invalid_agent", "selected agent display name is invalid");
  }
  sourceFilenameFromReference(agent.source_ref);
  requireDigest(agent.source_digest, "selected source digest");
  if (agent.kind !== "framework_guide") return;
  if (agent.agent_id !== "agent.aidevops-guide" || agent.source_ref !== "agents:aidevops.md") {
    throw new ConversationOverlayError("invalid_agent", "framework guide identity is not canonical");
  }
}

export function validateOverlayDocument(document) {
  exactKeys(document, DOCUMENT_KEYS, "OpenCode launch overlay");
  if (document.schema_version !== 1 || document.document_type !== "opencode_launch_overlay") {
    throw new ConversationOverlayError("invalid_document", "unsupported OpenCode launch overlay version");
  }
  if (document.overlay_id !== "opencode-launch-overlay.aidevops") {
    throw new ConversationOverlayError("invalid_document", "OpenCode launch overlay ID is not canonical");
  }
  if (document.roster_id !== "agent-roster.aidevops") {
    throw new ConversationOverlayError("invalid_document", "agent roster ID is not canonical");
  }
  if (!PERMISSION_PROFILES.has(document.permission_profile)) {
    throw new ConversationOverlayError("invalid_document", "team-interface permission profile is not supported");
  }
  if (!WORKLOAD_TIERS.has(document.workload_tier)) {
    throw new ConversationOverlayError("invalid_document", "workload tier is not canonical");
  }
  requireDigest(document.roster_digest, "roster digest");
  requireDigest(document.context_digest, "context digest");
  requireDigest(document.config_digest, "config digest");
  requireDigest(document.overlay_digest, "overlay digest");
  validateSelectedAgent(document.agent);
  validateInterfaceContext(document.context);

  if (document.context_digest !== canonicalDigest(document.context)) {
    throw new ConversationOverlayError("digest_mismatch", "interface context digest does not match its canonical content");
  }
  const configEvidence = configEvidenceForPermissionProfile(
    document.agent.display_name,
    document.permission_profile,
  );
  if (document.config_digest !== canonicalDigest(configEvidence)) {
    throw new ConversationOverlayError("digest_mismatch", "team-interface config digest does not match the enforced profile");
  }
  const unsigned = clone(document);
  delete unsigned.overlay_digest;
  if (document.overlay_digest !== canonicalDigest(unsigned)) {
    throw new ConversationOverlayError("digest_mismatch", "OpenCode launch overlay digest does not match its canonical content");
  }
  return document;
}

export function createOverlayDocument({
  roster,
  agent,
  workloadTier,
  context,
  permissionProfile = CONVERSATION_PERMISSION_PROFILE,
}) {
  const selectedAgent = {
    agent_id: agent.agent_id,
    display_name: agent.display_name,
    kind: agent.kind,
    source_digest: agent.source_digest,
    source_ref: agent.source_ref,
  };
  const unsigned = {
    agent: selectedAgent,
    config_digest: canonicalDigest(configEvidenceForPermissionProfile(
      selectedAgent.display_name,
      permissionProfile,
    )),
    context: clone(validateInterfaceContext(context)),
    context_digest: canonicalDigest(context),
    document_type: "opencode_launch_overlay",
    overlay_id: "opencode-launch-overlay.aidevops",
    permission_profile: permissionProfile,
    roster_digest: roster.roster_digest,
    roster_id: roster.roster_id,
    schema_version: 1,
    workload_tier: workloadTier,
  };
  const document = {...unsigned, overlay_digest: canonicalDigest(unsigned)};
  return validateOverlayDocument(document);
}

export function parseCanonicalOverlayText(text) {
  let document;
  try {
    document = JSON.parse(text);
  } catch {
    throw new ConversationOverlayError("invalid_json", "OpenCode launch overlay is not valid JSON");
  }
  validateOverlayDocument(document);
  if (text !== `${canonicalJson(document)}\n`) {
    throw new ConversationOverlayError("noncanonical_document", "OpenCode launch overlay bytes are not canonical JSON");
  }
  return document;
}
