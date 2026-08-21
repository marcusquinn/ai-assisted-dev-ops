// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  nextRoutingTier,
  routingCandidateIndex,
  routingModelIdentity,
  selectConnectedRoutingCandidate,
} from "./model-routing.mjs";
import { SubagentLifecycleTracker } from "./subagent-lifecycle-tracker.mjs";
import { classifySideEffect, safeToolName } from "./subagent-side-effect-classifier.mjs";

const TASK_TOOLS = new Set(["task", "mcp_task"]);
const TERMINAL_TOOL_FAILURES = new Set([
  "aborted", "cancelled", "canceled", "error", "failed",
]);
const FORBIDDEN_ESCALATION_EVIDENCE = /\b(?:auth(?:entication|orization)?|billing|credential|locality|permission|policy|provider|rate[ -]?limit|secret|trust[ -]?boundary)\b/i;
const MAX_TRACKED_SESSIONS = 64;
const SIDE_EFFECT_SKIP = "[AIDEvOps automatic capability escalation skipped: the child attempted side effects, so parent review is required before retry.]";

const ESCALATION_PROMPT = [
  "[AIDEvOps capability escalation]",
  "Continue the exact task in this session using the prior attempt and evidence.",
  "Do not repeat completed discovery. Produce the requested result and verification evidence.",
  "If model capability alone still blocks safe completion after bounded attempts, end with `BLOCKED: capability limit - <evidence>`.",
  "Never use that marker for permission, authentication, provider, rate-limit, secret, policy, trust-boundary, locality, billing, or side-effect uncertainty.",
].join("\n");

function capMap(map) {
  while (map.size > MAX_TRACKED_SESSIONS) map.delete(map.keys().next().value);
}

function responsePayload(response) {
  return response?.data ?? response ?? {};
}

function responseError(response) {
  return response?.error || response?.data?.error || null;
}

function responseText(response) {
  const payload = responsePayload(response);
  return (payload.parts || [])
    .filter((part) => part?.type === "text")
    .map((part) => part.text || "")
    .join("\n")
    .trim();
}

function toolFailed(output) {
  const status = String(output?.metadata?.status || output?.status || "").toLowerCase();
  return TERMINAL_TOOL_FAILURES.has(status);
}

/** Return safe capability-only evidence from the exact escalation marker. */
export function capabilityEscalationEvidence(value) {
  const match = String(value || "").match(/^BLOCKED: capability limit - ([^\r\n]+)$/im);
  const evidence = String(match?.[1] || "").trim();
  if (!evidence || FORBIDDEN_ESCALATION_EVIDENCE.test(evidence)) return "";
  return evidence;
}

/** Add the bounded failure contract once to an eligible child prompt. */
export function appendCapabilityEscalationContract(output) {
  const marker = "[AIDEvOps capability escalation contract]";
  const parts = Array.isArray(output?.parts) ? output.parts : [];
  if (parts.some((part) => part?.type === "text" && String(part.text || "").includes(marker))) return;
  const targetIndex = parts.findIndex((part) => part?.type === "text"
    && typeof part.id === "string"
    && typeof part.sessionID === "string"
    && typeof part.messageID === "string");
  if (targetIndex < 0) return;

  const contract = [
    marker,
    "After bounded attempts, emit `BLOCKED: capability limit - <evidence>` only when model capability is the sole blocker.",
    "Do not use it for permission, authentication, provider, rate-limit, secret, policy, trust-boundary, locality, billing, or side-effect uncertainty.",
  ].join("\n");
  const target = parts[targetIndex];
  const originalText = String(target.text || "");
  output.parts = parts.map((part, index) => index === targetIndex
    ? { ...target, text: originalText ? `${originalText}\n\n${contract}` : contract }
    : part);
}

class InteractiveSubagentEscalator {
  constructor(context, options = {}) {
    this.context = context;
    this.isHeadless = options.isHeadless || (() => false);
    this.qualityLog = options.qualityLog;
    this.lifecycle = new SubagentLifecycleTracker();
    this.sideEffects = new Map();
  }

  enabled() {
    return !this.isHeadless()
      && Boolean(this.context.modelRouting)
      && typeof this.context.client?.session?.prompt === "function";
  }

  safeLog(level, message) {
    try {
      this.qualityLog?.(level, message);
    } catch {
      // Escalation remains fail-open when diagnostic logging is unavailable.
    }
  }

  trackingEnabled() {
    return this.enabled() || typeof this.context.onSubagentOutcome === "function";
  }

  recordOutcome(evidence) {
    try {
      const result = this.context.onSubagentOutcome?.(evidence);
      result?.catch?.(() => {});
    } catch {
      // Outcome observability remains fail-open.
    }
  }

  beforeTool(input, output) {
    const tool = safeToolName(input?.tool);
    const sessionID = String(input?.sessionID || "");
    const callID = String(input?.callID || "");
    if (TASK_TOOLS.has(tool)) {
      if (!this.trackingEnabled()) return;
      this.lifecycle.beforeTask(callID, sessionID);
      this.recordOutcome({
        stage: "dispatch_requested",
        callID,
        parentSessionID: sessionID,
        status: "requested",
      });
      return;
    }

    if (!this.enabled()) return;

    const effect = classifySideEffect(tool, output?.args || input?.args || {});
    if (sessionID && effect) {
      this.sideEffects.set(sessionID, true);
      capMap(this.sideEffects);
    }
  }

  handleEvent(input) {
    if (!this.trackingEnabled()) return;
    this.lifecycle.handleEvent(input?.event || input || {});
  }

  recordHostOutcome(input, output, identity) {
    const terminalEvidence = identity.childID
      ? this.lifecycle.terminalEvidence(identity.childID)
      : "";
    const failed = toolFailed(output) || TERMINAL_TOOL_FAILURES.has(terminalEvidence);
    const status = String(output?.metadata?.status || output?.status || terminalEvidence || "completed")
      .toLowerCase();
    this.recordOutcome({
      stage: "host_outcome",
      callID: identity.callID,
      parentSessionID: String(input?.sessionID || ""),
      childSessionID: identity.childID,
      childSessionObserved: identity.childID
        ? this.lifecycle.observedSession(identity.childID)
        : false,
      identityReason: identity.reason,
      terminalEvidence,
      outcomeCategory: failed ? "host_failed" : "host_completed",
      status,
      success: !failed,
    });
  }

  prepareRoute(policy, tier, model) {
    policy.effort = tier;
    policy.attempt = Math.max(1, Number(policy.attempt) || 1) + 1;
    policy.reason = "capability_escalation";
    policy.escalated = true;
    policy.routedModel = model;
    policy.candidateIndex = routingCandidateIndex(this.context.modelRouting, tier, model);
    policy.awaitingEscalationPrompt = true;
    policy.createdAt = Date.now();
  }

  async promptNextTier(childID, childSession, model) {
    const body = {
      model: routingModelIdentity(model),
      parts: [{ type: "text", text: ESCALATION_PROMPT, synthetic: true }],
    };
    if (childSession?.agent) body.agent = childSession.agent;
    return this.context.client.session.prompt({ path: { id: childID }, body });
  }

  skippedForSideEffects(output) {
    output.output = [
      String(output.output || "").trim(),
      SIDE_EFFECT_SKIP,
    ].filter(Boolean).join("\n\n");
  }

  initialEscalationState(output, childID) {
    const evidence = capabilityEscalationEvidence(output?.output);
    const policy = this.context.policies.get(childID);
    if (!evidence || !policy || policy.pinned || toolFailed(output)) return null;
    if (this.sideEffects.get(childID)) {
      this.skippedForSideEffects(output);
      return null;
    }

    return {
      evidence,
      finalText: String(output.output || "").trim(),
      policy,
      route: [policy.effort],
    };
  }

  async loadChildSession(childID) {
    try {
      const session = await this.context.getSession(this.context.client, childID);
      return { available: true, session };
    } catch {
      return { available: false, session: null };
    }
  }

  async nextEscalationCandidate(policy) {
    const tier = nextRoutingTier(this.context.modelRouting, policy.effort);
    if (!tier) return null;
    const providerState = await this.context.resolveProviderState();
    if (!providerState) return null;
    const model = selectConnectedRoutingCandidate(
      this.context.modelRouting,
      tier,
      providerState,
    );
    return model ? { model, tier } : null;
  }

  async requestEscalation(childID, childSession, policy, candidate) {
    this.prepareRoute(policy, candidate.tier, candidate.model);
    try {
      const response = await this.promptNextTier(childID, childSession, candidate.model);
      if (responseError(response)) return "";
      return responseText(response);
    } catch (error) {
      this.safeLog("WARN", `[subagent-routing] capability escalation request failed: ${error?.name || "Error"}`);
      return "";
    } finally {
      policy.awaitingEscalationPrompt = false;
    }
  }

  recordEscalationResponse(state, candidate, text, childID) {
    state.route.push(candidate.tier);
    state.finalText = text;
    state.evidence = capabilityEscalationEvidence(text);
    if (state.evidence && this.sideEffects.get(childID)) {
      state.finalText = [state.finalText, SIDE_EFFECT_SKIP].join("\n\n");
      state.evidence = "";
    }
  }

  completeEscalation(output, state) {
    if (state.route.length === 1) return null;
    output.output = `[AIDEvOps capability escalation: ${state.route.join(" → ")}]\n\n${state.finalText}`;
    output.metadata = {
      ...output.metadata,
      aidevopsRoutingEscalation: {
        attempts: state.route.length,
        route: state.route,
      },
    };
    return output.metadata.aidevopsRoutingEscalation;
  }

  async escalateTask(output, childID) {
    const state = this.initialEscalationState(output, childID);
    if (!state) return null;
    const child = await this.loadChildSession(childID);
    if (!child.available) return null;

    while (state.evidence) {
      const candidate = await this.nextEscalationCandidate(state.policy);
      if (!candidate) break;
      const text = await this.requestEscalation(
        childID,
        child.session,
        state.policy,
        candidate,
      );
      if (!text) break;
      this.recordEscalationResponse(state, candidate, text, childID);
    }

    return this.completeEscalation(output, state);
  }

  async afterTool(input, output) {
    if (!TASK_TOOLS.has(safeToolName(input?.tool)) || !this.trackingEnabled()) return null;
    const identity = this.lifecycle.takeChildIdentity(input, output);
    if (this.enabled() && !identity.childID) {
      output.metadata = {
        ...output.metadata,
        aidevopsRoutingIdentity: { reason: identity.reason },
      };
    }
    try {
      return this.enabled() ? await this.escalateTask(output, identity.childID) : null;
    } finally {
      this.recordHostOutcome(input, output, identity);
      if (identity.childID) this.sideEffects.delete(identity.childID);
    }
  }
}

/** Retry capability-only interactive child failures at the next configured tier. */
export function createInteractiveSubagentEscalator(context, options = {}) {
  const escalator = new InteractiveSubagentEscalator(context, options);
  return {
    afterTool: escalator.afterTool.bind(escalator),
    beforeTool: escalator.beforeTool.bind(escalator),
    handleEvent: escalator.handleEvent.bind(escalator),
  };
}
