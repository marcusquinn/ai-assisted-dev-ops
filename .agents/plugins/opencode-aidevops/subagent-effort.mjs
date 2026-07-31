// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, readFileSync } from "fs";

const VARIANT_RANK = {
  none: 0,
  minimal: 1,
  low: 2,
  medium: 3,
  high: 4,
  xhigh: 5,
  max: 6,
};

const SIMPLE_AGENTS = new Set([
  "explore",
  "qlty",
  "context7",
  "secretlint",
]);

const THINKING_AGENTS = new Set([
  "auditing",
  "architecture",
  "code-simplifier",
  "security-analysis",
  "security-audit",
]);

const POLICY_TTL_MS = 15 * 60 * 1000;

export function normalizeEffortTier(value) {
  const tier = String(value || "").trim().toLowerCase();
  switch (tier) {
    case "simple":
      return "simple";
    case "thinking":
      return "thinking";
    case "standard":
    case "":
      return "standard";
    default:
      return "standard";
  }
}

function normalizeVariant(value) {
  const variant = String(value || "").trim().toLowerCase();
  if (variant === "default" || !(variant in VARIANT_RANK)) return "medium";
  return variant;
}

export function loadTierReasoningPolicies(paths) {
  for (const path of paths || []) {
    if (!path || !existsSync(path)) continue;
    try {
      const routing = JSON.parse(readFileSync(path, "utf8"));
      const policies = {};
      for (const tier of ["simple", "standard", "thinking"]) {
        policies[tier] = routing?.tiers?.[tier]?.reasoning || {};
      }
      return policies;
    } catch {
      // Continue to the framework routing table when a custom file is invalid.
    }
  }
  return {};
}

export function resolveTierReasoning(tier, providerID, modelID, policies) {
  const policy = policies?.[normalizeEffortTier(tier)] || {};
  const fullModelID = modelID?.includes("/")
    ? modelID
    : `${providerID || ""}/${modelID || ""}`;
  return policy[fullModelID] ?? policy[providerID] ?? "";
}

export function clampReasoningVariant(requested, parentCap) {
  const child = normalizeVariant(requested);
  const parent = normalizeVariant(parentCap);
  return VARIANT_RANK[child] <= VARIANT_RANK[parent] ? child : parent;
}

export function inferSubagentEffort(agentName, text = "") {
  const marker = String(text).match(/\[effort:(simple|standard|thinking)\]/i);
  if (marker) return normalizeEffortTier(marker[1]);

  const agent = String(agentName || "").trim().toLowerCase();
  if (SIMPLE_AGENTS.has(agent)) return "simple";
  if (THINKING_AGENTS.has(agent)) return "thinking";
  return "standard";
}

function unwrapResponse(response) {
  return response?.data ?? response;
}

function extractVariant(value) {
  return value?.variant
    ?? value?.model?.variant
    ?? value?.options?.reasoningEffort
    ?? value?.options?.reasoning_effort
    ?? "";
}

function messageText(parts) {
  return (parts || [])
    .filter((part) => part?.type === "text")
    .map((part) => part.text || "")
    .join("\n");
}

async function getSession(client, sessionID) {
  const response = await client.session.get({ path: { id: sessionID } });
  return unwrapResponse(response) || {};
}

async function getParentVariant(client, childSession) {
  const parentID = childSession?.parentID;
  if (!parentID) return "";

  const parentSession = await getSession(client, parentID);
  const sessionVariant = extractVariant(parentSession);
  if (sessionVariant) return sessionVariant;

  const response = await client.session.messages({ path: { id: parentID } });
  const messages = unwrapResponse(response) || [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const info = messages[index]?.info ?? messages[index];
    const variant = extractVariant(info);
    if (variant) return variant;
  }
  return "";
}

function prunePolicies(policies, now) {
  for (const [sessionID, policy] of policies) {
    if (now - policy.createdAt > POLICY_TTL_MS) policies.delete(sessionID);
  }
}

export function createSubagentEffortHooks(client, options = {}) {
  const policies = new Map();
  const tierReasoning = options.tierReasoning || {};

  return {
    chatMessage: async (_input, output) => {
      const message = output?.message || {};
      const sessionID = message.sessionID;
      if (!sessionID) return;

      const now = Date.now();
      prunePolicies(policies, now);
      policies.set(sessionID, {
        effort: inferSubagentEffort(message.agent ?? message.mode, messageText(output.parts)),
        createdAt: now,
      });
    },

    chatParams: async (input, output) => {
      const sessionID = input?.message?.sessionID;
      if (!sessionID) return;

      try {
        const childSession = await getSession(client, sessionID);
        if (!childSession.parentID) return;

        const policy = policies.get(sessionID);
        const desiredEffort = policy?.effort
          ?? inferSubagentEffort(input.message.agent ?? childSession.agent);
        const requestedVariant = resolveTierReasoning(
          desiredEffort,
          input?.provider?.id,
          input?.model?.id,
          tierReasoning,
        );
        if (!requestedVariant) return;
        const currentVariant = extractVariant(input.message)
          || output?.options?.reasoningEffort
          || output?.options?.reasoning_effort
          || extractVariant(input.model);
        const parentVariant = await getParentVariant(client, childSession)
          || currentVariant;
        if (!parentVariant) return;

        output.options.reasoningEffort = clampReasoningVariant(
          requestedVariant,
          parentVariant,
        );
        if (Object.hasOwn(output.options, "reasoning_effort")) {
          output.options.reasoning_effort = output.options.reasoningEffort;
        }
      } catch {
        // Fail open: provider requests must continue if session metadata is unavailable.
      }
    },
  };
}
