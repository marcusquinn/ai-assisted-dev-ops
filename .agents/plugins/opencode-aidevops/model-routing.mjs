// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Provider-neutral routing-table reader shared by OpenCode config and request
// hooks. Candidate order is policy: availability moves right within a tier;
// capability failure moves down escalationOrder.

import { existsSync, readFileSync } from "fs";

export const DEFAULT_ESCALATION_ORDER = ["simple", "standard", "thinking"];

export function normalizeRoutingTier(value) {
  const tier = String(value || "").trim().toLowerCase();
  return DEFAULT_ESCALATION_ORDER.includes(tier) ? tier : "standard";
}

function normalizeTierConfig(value) {
  const models = Array.isArray(value?.models)
    ? value.models.filter((model) => typeof model === "string" && model.includes("/"))
    : [];
  const reasoning = value?.reasoning && typeof value.reasoning === "object"
    ? { ...value.reasoning }
    : {};
  return { models, reasoning };
}

export function normalizeModelRouting(value = {}) {
  const configuredOrder = Array.isArray(value?.escalation_order)
    ? value.escalation_order.filter((tier) => DEFAULT_ESCALATION_ORDER.includes(tier))
    : [];
  const escalationOrder = [...new Set(configuredOrder)];
  for (const tier of DEFAULT_ESCALATION_ORDER) {
    if (!escalationOrder.includes(tier)) escalationOrder.push(tier);
  }

  const tiers = {};
  for (const tier of DEFAULT_ESCALATION_ORDER) {
    tiers[tier] = normalizeTierConfig(value?.tiers?.[tier]);
  }
  return { tiers, escalationOrder, specialistAdvisor: normalizeSpecialistAdvisor(value.specialist_advisor) };
}

function normalizeSpecialistAdvisor(value) {
  if (!value || typeof value.model !== "string" || !value.model.includes("/")) return null;
  if (!["low", "medium", "high"].includes(value.variant)) return null;
  return { model: value.model, variant: value.variant };
}

export function mergeModelRouting(base, override = {}) {
  const merged = normalizeModelRouting();
  merged.specialistAdvisor = Object.hasOwn(override, "specialist_advisor")
    ? normalizeSpecialistAdvisor(override.specialist_advisor)
    : base?.specialistAdvisor || null;
  for (const tier of DEFAULT_ESCALATION_ORDER) {
    merged.tiers[tier] = {
      models: [...(base?.tiers?.[tier]?.models || [])],
      reasoning: { ...(base?.tiers?.[tier]?.reasoning || {}) },
    };
    const tierOverride = override?.tiers?.[tier];
    if (!tierOverride || typeof tierOverride !== "object") continue;
    if (Object.hasOwn(tierOverride, "models") && Array.isArray(tierOverride.models)) {
      merged.tiers[tier].models = tierOverride.models
        .filter((model) => typeof model === "string" && model.includes("/"));
    }
    if (tierOverride.reasoning && typeof tierOverride.reasoning === "object") {
      merged.tiers[tier].reasoning = {
        ...merged.tiers[tier].reasoning,
        ...tierOverride.reasoning,
      };
    }
  }
  merged.escalationOrder = Array.isArray(override?.escalation_order)
    ? normalizeModelRouting(override).escalationOrder
    : [...(base?.escalationOrder || DEFAULT_ESCALATION_ORDER)];
  return merged;
}

export function loadModelRouting(paths) {
  let routing = normalizeModelRouting();
  for (const path of [...(paths || [])].reverse()) {
    if (!path || !existsSync(path)) continue;
    try {
      routing = mergeModelRouting(routing, JSON.parse(readFileSync(path, "utf8")));
    } catch {
      // Continue through lower-precedence valid tables when an override is invalid.
    }
  }
  return routing;
}

export function routingCandidates(routing, tier) {
  return routing?.tiers?.[normalizeRoutingTier(tier)]?.models || [];
}

export function routingModelIdentity(model) {
  const value = String(model || "");
  const separator = value.indexOf("/");
  if (separator <= 0 || separator === value.length - 1) {
    return { providerID: "", modelID: "" };
  }
  return {
    providerID: value.slice(0, separator),
    modelID: value.slice(separator + 1),
  };
}

export function selectConnectedRoutingCandidate(routing, tier, providerState) {
  const connected = new Set(Array.isArray(providerState?.connected) ? providerState.connected : []);
  const providers = new Map(
    (Array.isArray(providerState?.all) ? providerState.all : [])
      .filter((provider) => provider?.id)
      .map((provider) => [provider.id, provider]),
  );

  for (const candidate of routingCandidates(routing, tier)) {
    const { providerID, modelID } = routingModelIdentity(candidate);
    const provider = providers.get(providerID);
    if (!provider || !connected.has(providerID)) continue;
    const models = provider.models && typeof provider.models === "object" ? provider.models : {};
    const registered = Object.entries(models).some(
      ([key, value]) => key === modelID || value?.id === modelID,
    );
    if (registered) return candidate;
  }
  return "";
}

export function routingPrimary(routing, tier) {
  return routingCandidates(routing, tier)[0] || "";
}

export function routingVariant(routing, tier, model) {
  const policy = routing?.tiers?.[normalizeRoutingTier(tier)]?.reasoning || {};
  const provider = String(model || "").split("/", 1)[0];
  return policy[model] ?? policy[provider] ?? policy.default ?? "";
}

export function routingCandidateIndex(routing, tier, model) {
  return routingCandidates(routing, tier).indexOf(model);
}

export function routingTierForModel(routing, model) {
  for (const tier of routing?.escalationOrder || DEFAULT_ESCALATION_ORDER) {
    if (routingCandidates(routing, tier).includes(model)) return tier;
  }
  return "";
}

export function nextRoutingTier(routing, tier) {
  const order = routing?.escalationOrder || DEFAULT_ESCALATION_ORDER;
  const index = order.indexOf(normalizeRoutingTier(tier));
  if (index < 0) return "";
  return order.slice(index + 1).find((candidate) => routingCandidates(routing, candidate).length > 0) || "";
}

export function routingProfile(routing, tier) {
  const normalizedTier = normalizeRoutingTier(tier);
  const model = routingPrimary(routing, normalizedTier);
  if (!model) return { tier: normalizedTier, model: "", variant: "" };
  return {
    tier: normalizedTier,
    model,
    variant: routingVariant(routing, normalizedTier, model),
  };
}
