// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  routingCandidateIndex,
  routingCandidates,
  routingModelIdentity,
  routingTierForModel,
  selectConnectedRoutingCandidate,
} from "./model-routing.mjs";

async function routeChatMessage(context, output) {
  const message = output?.message || {};
  const sessionID = message.sessionID;
  if (!sessionID) return;

  const now = Date.now();
  context.prunePolicies(context.policies, now);
  const text = context.messageText(output.parts);
  const agentName = String(message.agent ?? message.mode ?? "");
  const route = context.routedPolicy(context.agentRoutingState, agentName, text);
  const policy = {
    effort: route.effort,
    reason: route.pinned ? "explicit_model" : route.reason,
    attempt: 0,
    createdAt: now,
  };
  context.policies.set(sessionID, policy);

  if (!context.modelRouting || route.pinned) return;
  const candidates = routingCandidates(context.modelRouting, route.effort);
  if (candidates.length === 0) {
    throw new Error(`[aidevops] Model routing tier '${route.effort}' is disabled`);
  }

  let childSession;
  try {
    childSession = await context.getSession(context.client, sessionID);
  } catch {
    return;
  }
  if (!childSession.parentID) return;

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
  policy.parentSessionID = childSession.parentID;
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
  if (policy) policy.attempt += 1;
  await context.onRoutingDecision(sessionID, {
    parentSessionID: policy?.parentSessionID || childSession.parentID,
    tier: desiredEffort,
    model: policy?.routedModel || (childModel === "/" ? "" : childModel),
    variant: effectiveVariant,
    candidateIndex: policy?.candidateIndex
      ?? routingCandidateIndex(context.modelRouting, desiredEffort, childModel),
    attempt: policy?.attempt || 1,
    reason: policy?.reason || "agent_default",
  });
}

async function routeChatParams(context, input, output) {
  const sessionID = input?.message?.sessionID;
  if (!sessionID) return;

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
