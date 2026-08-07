// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { existsSync, readFileSync } from "fs";
import {
  routingCandidateIndex,
  routingCandidates,
  routingModelIdentity,
  routingTierForModel,
  selectConnectedRoutingCandidate,
} from "./model-routing.mjs";

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
  return variant === "default" ? "" : variant;
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
  return policy[fullModelID] ?? policy[providerID] ?? policy.default ?? "";
}

export function clampReasoningVariant(requested, parentCap) {
  const child = normalizeVariant(requested);
  const parent = normalizeVariant(parentCap);
  if (!(child in VARIANT_RANK) || !(parent in VARIANT_RANK)) return child || requested;
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

function modelIdentity(value) {
  const rawProviderID = value?.providerID
    ?? value?.model?.providerID
    ?? value?.provider?.id
    ?? "";
  const providerID = typeof rawProviderID === "string" ? rawProviderID : "";
  const rawModelID = value?.modelID
    ?? value?.model?.modelID
    ?? value?.model?.id
    ?? (typeof value?.model === "string" ? value.model : "");
  const modelID = typeof rawModelID === "string" ? rawModelID : "";
  return modelID.includes("/") ? modelID : `${providerID || ""}/${modelID}`;
}

async function getParentRoute(client, childSession) {
  const parentID = childSession?.parentID;
  if (!parentID) return { model: "", variant: "" };

  const parentSession = await getSession(client, parentID);
  const sessionVariant = extractVariant(parentSession);
  const sessionModel = modelIdentity(parentSession);
  if (sessionVariant && sessionModel !== "/") {
    return { model: sessionModel, variant: sessionVariant };
  }

  const response = await client.session.messages({ path: { id: parentID } });
  const messages = unwrapResponse(response) || [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const info = messages[index]?.info ?? messages[index];
    const variant = extractVariant(info);
    const model = modelIdentity(info);
    if (variant) return { model: model === "/" ? sessionModel : model, variant };
  }
  return { model: sessionModel === "/" ? "" : sessionModel, variant: "" };
}

function prunePolicies(policies, now) {
  for (const [sessionID, policy] of policies) {
    if (now - policy.createdAt > POLICY_TTL_MS) policies.delete(sessionID);
  }
}

function createProviderStateResolver(client, ttlMs) {
  let snapshot = null;
  let refreshedAt = 0;
  return async () => {
    if (snapshot && Date.now() - refreshedAt < ttlMs) return snapshot;
    if (typeof client?.provider?.list !== "function") return null;
    try {
      const response = await client.provider.list();
      const data = unwrapResponse(response);
      if (!Array.isArray(data?.all) || !Array.isArray(data?.connected)) return null;
      snapshot = { all: data.all, connected: data.connected };
      refreshedAt = Date.now();
      return snapshot;
    } catch {
      return null;
    }
  };
}

function routedPolicy(agentRoutingState, agentName, text) {
  const explicit = /\[effort:(simple|standard|thinking)\]/i.test(text);
  const configuredTier = agentRoutingState?.tiers?.get(agentName);
  return {
    effort: explicit
      ? inferSubagentEffort(agentName, text)
      : normalizeEffortTier(configuredTier || inferSubagentEffort(agentName, text)),
    reason: explicit ? "explicit_effort_marker" : "agent_default",
    pinned: agentRoutingState?.pinned?.has(agentName) || false,
  };
}

export function createSubagentEffortHooks(client, options = {}) {
  const policies = new Map();
  const tierReasoning = options.tierReasoning || {};
  const modelRouting = options.modelRouting;
  const agentRoutingState = options.agentRoutingState;
  const onRoutingDecision = options.onRoutingDecision;
  const resolveProviderState = createProviderStateResolver(
    client,
    options.providerStateTtlMs ?? 30000,
  );

  return {
    chatMessage: async (_input, output) => {
      const message = output?.message || {};
      const sessionID = message.sessionID;
      if (!sessionID) return;

      const now = Date.now();
      prunePolicies(policies, now);
      const text = messageText(output.parts);
      const agentName = String(message.agent ?? message.mode ?? "");
      const route = routedPolicy(agentRoutingState, agentName, text);
      const policy = {
        effort: route.effort,
        reason: route.pinned ? "explicit_model" : route.reason,
        attempt: 0,
        createdAt: now,
      };
      policies.set(sessionID, policy);

      if (!modelRouting || route.pinned) return;
      const candidates = routingCandidates(modelRouting, route.effort);
      if (candidates.length === 0) {
        throw new Error(`[aidevops] Model routing tier '${route.effort}' is disabled`);
      }
      let childSession;
      try {
        childSession = await getSession(client, sessionID);
      } catch {
        return;
      }
      if (!childSession.parentID) return;

      const providerState = await resolveProviderState();
      if (!providerState) {
        policy.reason = "provider_state_unavailable_inherit";
        return;
      }
      const routedModel = selectConnectedRoutingCandidate(
        modelRouting,
        route.effort,
        providerState,
      );
      if (!routedModel) {
        throw new Error(`[aidevops] No connected model is available for '${route.effort}' routing`);
      }
      message.model = routingModelIdentity(routedModel);
      policy.routedModel = routedModel;
      policy.candidateIndex = routingCandidateIndex(modelRouting, route.effort, routedModel);
      policy.parentSessionID = childSession.parentID;
    },

    chatParams: async (input, output) => {
      const sessionID = input?.message?.sessionID;
      if (!sessionID) return;

      try {
        const childSession = await getSession(client, sessionID);
        const childModel = modelIdentity({
          providerID: input?.provider?.id ?? input?.model?.providerID,
          modelID: input?.model?.id ?? input?.model?.modelID,
        });
        const currentVariant = extractVariant(input.message)
          || output?.options?.reasoningEffort
          || output?.options?.reasoning_effort
          || extractVariant(input.model);
        if (!childSession.parentID) {
          const rootTier = routingTierForModel(modelRouting, childModel);
          const dispatchTier = process.env.AIDEVOPS_DISPATCH_TIER || "";
          if (rootTier && !dispatchTier && typeof onRoutingDecision === "function") {
            const routedVariant = resolveTierReasoning(
              rootTier,
              input?.provider?.id,
              input?.model?.id,
              tierReasoning,
            );
            await onRoutingDecision(sessionID, {
              tier: rootTier,
              model: childModel === "/" ? "" : childModel,
              variant: currentVariant || routedVariant,
              candidateIndex: routingCandidateIndex(modelRouting, rootTier, childModel),
              attempt: 1,
              reason: "model_profile",
            });
          }
          return;
        }

        const policy = policies.get(sessionID);
        const desiredEffort = policy?.effort
          ?? inferSubagentEffort(input.message.agent ?? childSession.agent);
        const requestedVariant = resolveTierReasoning(
          desiredEffort,
          input?.provider?.id,
          input?.model?.id,
          tierReasoning,
        );
        const parentRoute = await getParentRoute(client, childSession);
        let effectiveVariant = requestedVariant || currentVariant;
        if (
          requestedVariant
          && parentRoute.variant
          && parentRoute.model
          && parentRoute.model === childModel
        ) {
          effectiveVariant = clampReasoningVariant(requestedVariant, parentRoute.variant);
        }

        if (requestedVariant) {
          output.options.reasoningEffort = effectiveVariant;
          if (Object.hasOwn(output.options, "reasoning_effort")) {
            output.options.reasoning_effort = effectiveVariant;
          }
        }

        if (typeof onRoutingDecision === "function") {
          if (policy) policy.attempt += 1;
          await onRoutingDecision(sessionID, {
            parentSessionID: policy?.parentSessionID || childSession.parentID,
            tier: desiredEffort,
            model: policy?.routedModel || (childModel === "/" ? "" : childModel),
            variant: effectiveVariant,
            candidateIndex: policy?.candidateIndex
              ?? routingCandidateIndex(modelRouting, desiredEffort, childModel),
            attempt: policy?.attempt || 1,
            reason: policy?.reason || "agent_default",
          });
        }
      } catch {
        // Fail open: provider requests must continue if session metadata is unavailable.
      }
    },
  };
}
