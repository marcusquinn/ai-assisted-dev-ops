// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  routingCandidateIndex,
  routingCandidates,
  routingModelIdentity,
  routingTierForModel,
  nextRoutingTier,
  selectConnectedRoutingCandidate,
} from "./model-routing.mjs";
import { loadDelegatedDomainKnowledge } from "./agent-loader.mjs";

const DOMAIN_KNOWLEDGE_MARKER = "\n\n[AIDEvOps canonical domain knowledge]";
const DOMAIN_REQUIRED_FIELDS = ["task", "objective", "scope", "source", "decisions", "evidence", "output"];

function validDomainEnvelope(envelope) {
  if (!envelope) return false;
  const hasText = (key) => typeof envelope[key] === "string" && Boolean(envelope[key].trim());
  const checks = [
    DOMAIN_REQUIRED_FIELDS.every(hasText),
    ["simple", "standard"].includes(envelope.effort),
    envelope.authority === "inference-only",
    Array.isArray(envelope.tools) && envelope.tools.length === 0,
  ];
  return checks.every(Boolean);
}

function domainEnvelope(text) {
  let envelope;
  try {
    envelope = JSON.parse(text.split(DOMAIN_KNOWLEDGE_MARKER)[0]
      .replace(/^\[effort:(simple|standard|thinking)\]\s*/i, ""));
  } catch {
    throw new Error("[aidevops] Domain delegation requires a JSON child envelope");
  }
  if (!validDomainEnvelope(envelope)) {
    throw new Error("[aidevops] Invalid domain envelope: bounded evidence, effort and inference-only authority required");
  }
  return envelope;
}

async function routeDomainMessage(context, output, registry, agentName) {
  const envelope = domainEnvelope(context.messageText(output.parts));
  const child = await loadChildSessionWithParent(context, output.message.sessionID);
  if (!child) throw new Error("[aidevops] Domain delegation requires an observed parent session");
  const parent = await context.getParentRoute(context.client, child);
  if (!parent.model || !["none", "minimal", "low", "medium", "high", "xhigh", "max"].includes(parent.variant)) {
    throw new Error("[aidevops] Parent model/effort ceiling unavailable; domain delegation refused");
  }
  const light = agentName === "domain-light";
  const delivered = loadDelegatedDomainKnowledge(registry, envelope.source, light);
  const effort = light ? "simple" : envelope.effort;
  // Keep the exact parent model: cross-model effort names are not compute ceilings.
  output.message.model = routingModelIdentity(parent.model);
  const variant = context.clampReasoningVariant(effort === "simple" ? "low" : "medium", parent.variant);
  context.policies.set(output.message.sessionID, {
    effort, reason: "bounded_domain", pinned: true, attempt: 1, createdAt: Date.now(),
    parentSessionID: child.parentID, routedModel: parent.model, domainVariant: variant,
  });
  const target = output.parts.find((part) => part.type === "text");
  target.text = `${JSON.stringify(envelope)}${DOMAIN_KNOWLEDGE_MARKER}\nSource: ${delivered.source}\nSHA256: ${delivered.sha256}\n${delivered.knowledge}`;
  // No second transcript or duplicated canonical payload on repeated transformation.
  output.parts = output.parts.filter((part) => part.type !== "text" || part === target);
}

async function loadChildSessionWithParent(context, sessionID) {
  try {
    const childSession = await context.getSession(context.client, sessionID);
    return childSession?.parentID ? childSession : null;
  } catch {
    return null;
  }
}

async function applyConnectedRoutingModel(context, route, message, policy) {
  const providerState = await context.resolveProviderState();
  if (!providerState) {
    policy.reason = "provider_state_unavailable_inherit";
    return;
  }
  const routedModel = selectConnectedRoutingCandidate(
    context.modelRouting,
    route.effort,
    providerState,
  );
  if (!routedModel) {
    throw new Error(`[aidevops] No connected model is available for '${route.effort}' routing`);
  }
  message.model = routingModelIdentity(routedModel);
  policy.routedModel = routedModel;
  policy.candidateIndex = routingCandidateIndex(context.modelRouting, route.effort, routedModel);
}

async function routeChatMessage(context, output) {
  const message = output?.message || {};
  const sessionID = message.sessionID;
  if (!sessionID) return;

  const now = Date.now();
  context.prunePolicies(context.policies, now);
  const existingPolicy = context.policies.get(sessionID);
  if (existingPolicy?.awaitingEscalationPrompt) {
    existingPolicy.awaitingEscalationPrompt = false;
    existingPolicy.createdAt = now;
    if (existingPolicy.routedModel) {
      message.model = routingModelIdentity(existingPolicy.routedModel);
    }
    return;
  }

  const text = context.messageText(output.parts);
  const agentName = String(message.agent ?? message.mode ?? "");
  const domainRegistry = context.agentRoutingState?.domainDelegation;
  if (domainRegistry?.profiles?.has(agentName)) {
    await routeDomainMessage(context, output, domainRegistry, agentName);
    return;
  }
  const route = context.routedPolicy(context.agentRoutingState, agentName, text);
  const policy = {
    effort: route.effort,
    reason: route.pinned ? "explicit_model" : route.reason,
    attempt: 1,
    escalated: false,
    pinned: route.pinned,
    createdAt: now,
  };
  context.policies.set(sessionID, policy);

  if (!context.modelRouting || route.pinned) return;
  const candidates = routingCandidates(context.modelRouting, route.effort);
  if (candidates.length === 0) {
    throw new Error(`[aidevops] Model routing tier '${route.effort}' is disabled`);
  }

  const childSession = await loadChildSessionWithParent(context, sessionID);
  if (!childSession) return;
  policy.parentSessionID = childSession.parentID;
  if (nextRoutingTier(context.modelRouting, route.effort)) {
    context.appendCapabilityEscalationContract(output);
  }

  await applyConnectedRoutingModel(context, route, message, policy);
}

function childModelFrom(context, input) {
  return context.modelIdentity({
    providerID: input?.provider?.id ?? input?.model?.providerID,
    modelID: input?.model?.id ?? input?.model?.modelID,
  });
}

function currentVariantFrom(context, input, output) {
  return context.extractVariant(input.message)
    || output?.options?.reasoningEffort
    || output?.options?.reasoning_effort
    || context.extractVariant(input.model);
}

async function recordRootRouting(context, sessionID, input, childModel, currentVariant) {
  const rootTier = routingTierForModel(context.modelRouting, childModel);
  const dispatchTier = process.env.AIDEVOPS_DISPATCH_TIER || "";
  const shouldRecord = rootTier && !dispatchTier
    && typeof context.onRoutingDecision === "function";
  if (!shouldRecord) return;

  const routedVariant = context.resolveTierReasoning(
    rootTier,
    input?.provider?.id,
    input?.model?.id,
    context.tierReasoning,
  );
  await context.onRoutingDecision(sessionID, {
    tier: rootTier,
    model: childModel === "/" ? "" : childModel,
    variant: currentVariant || routedVariant,
    candidateIndex: routingCandidateIndex(context.modelRouting, rootTier, childModel),
    attempt: 1,
    reason: "model_profile",
    population: "top_level_profile",
  });
}

async function effectiveChildVariant(context, childSession, childModel, requestedVariant, currentVariant) {
  const parentRoute = await context.getParentRoute(context.client, childSession);
  const comparableModels = [requestedVariant, parentRoute.variant, parentRoute.model].every(Boolean);
  if (comparableModels && parentRoute.model === childModel) {
    return context.clampReasoningVariant(requestedVariant, parentRoute.variant);
  }
  return requestedVariant || currentVariant;
}

function applyRequestedVariant(output, requestedVariant, effectiveVariant) {
  if (!requestedVariant) return;
  output.options.reasoningEffort = effectiveVariant;
  if (Object.hasOwn(output.options, "reasoning_effort")) {
    output.options.reasoning_effort = effectiveVariant;
  }
}

async function recordChildRouting(context, {
  sessionID,
  childSession,
  childModel,
  desiredEffort,
  effectiveVariant,
  policy,
}) {
  if (typeof context.onRoutingDecision !== "function") return;
  await context.onRoutingDecision(sessionID, {
    parentSessionID: policy?.parentSessionID || childSession.parentID,
    tier: desiredEffort,
    model: policy?.routedModel || (childModel === "/" ? "" : childModel),
    variant: effectiveVariant,
    candidateIndex: policy?.candidateIndex
      ?? routingCandidateIndex(context.modelRouting, desiredEffort, childModel),
    attempt: policy?.attempt || 1,
    reason: policy?.reason || "agent_default",
    escalated: Boolean(policy?.escalated),
    population: "interactive_child",
  });
}

async function routeChatParams(context, input, output) {
  const sessionID = input?.message?.sessionID;
  if (!sessionID) return;

  const domainPolicy = context.policies.get(sessionID);
  const domainName = input?.message?.agent;
  if (domainPolicy?.reason === "bounded_domain"
    || context.agentRoutingState?.domainDelegation?.profiles?.has(domainName)) {
    if (!domainPolicy?.domainVariant || childModelFrom(context, input) !== domainPolicy.routedModel) {
      throw new Error("[aidevops] Domain parent ceiling unavailable or model changed");
    }
    applyRequestedVariant(output, domainPolicy.domainVariant, domainPolicy.domainVariant);
    return;
  }

  try {
    const childSession = await context.getSession(context.client, sessionID);
    const childModel = childModelFrom(context, input);
    const currentVariant = currentVariantFrom(context, input, output);
    if (!childSession.parentID) {
      await recordRootRouting(context, sessionID, input, childModel, currentVariant);
      return;
    }

    const policy = context.policies.get(sessionID);
    const desiredEffort = policy?.effort
      ?? context.inferSubagentEffort(input.message.agent ?? childSession.agent);
    const requestedVariant = context.resolveTierReasoning(
      desiredEffort,
      input?.provider?.id,
      input?.model?.id,
      context.tierReasoning,
    );
    const effectiveVariant = await effectiveChildVariant(
      context,
      childSession,
      childModel,
      requestedVariant,
      currentVariant,
    );
    applyRequestedVariant(output, requestedVariant, effectiveVariant);
    await recordChildRouting(context, {
      sessionID,
      childSession,
      childModel,
      desiredEffort,
      effectiveVariant,
      policy,
    });
  } catch {
    // Fail open: provider requests must continue if session metadata is unavailable.
  }
}

export function createSubagentEffortHandlers(context) {
  return {
    chatMessage: (_input, output) => routeChatMessage(context, output),
    chatParams: (input, output) => routeChatParams(context, input, output),
  };
}
