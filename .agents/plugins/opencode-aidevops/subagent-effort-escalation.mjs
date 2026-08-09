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
  parts.push({
    type: "text",
    synthetic: true,
    text: [
      marker,
      "After bounded attempts, emit `BLOCKED: capability limit - <evidence>` only when model capability is the sole blocker.",
      "Do not use it for permission, authentication, provider, rate-limit, secret, policy, trust-boundary, locality, billing, or side-effect uncertainty.",
    ].join("\n"),
  });
  output.parts = parts;
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

  beforeTool(input, output) {
    if (!this.enabled()) return;
    const tool = safeToolName(input?.tool);
    const sessionID = String(input?.sessionID || "");
    const callID = String(input?.callID || "");
    if (TASK_TOOLS.has(tool)) {
      this.lifecycle.beforeTask(callID, sessionID);
      return;
    }

    const effect = classifySideEffect(tool, output?.args || input?.args || {});
    if (sessionID && effect) {
      this.sideEffects.set(sessionID, true);
      capMap(this.sideEffects);
    }
  }

  handleEvent(input) {
    if (!this.enabled()) return;
    this.lifecycle.handleEvent(input?.event || input || {});
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

  async escalateTask(output, childID) {
    let evidence = capabilityEscalationEvidence(output?.output);
    const policy = this.context.policies.get(childID);
    if (!evidence || !policy || policy.pinned || toolFailed(output)) return null;
    if (this.sideEffects.get(childID)) {
      this.skippedForSideEffects(output);
      return null;
    }

    let childSession;
    try {
      childSession = await this.context.getSession(this.context.client, childID);
    } catch {
      return null;
    }

    const route = [policy.effort];
    let finalText = String(output.output || "").trim();
    while (evidence) {
      const nextTier = nextRoutingTier(this.context.modelRouting, policy.effort);
      if (!nextTier) break;
      const providerState = await this.context.resolveProviderState();
      if (!providerState) break;
      const model = selectConnectedRoutingCandidate(
        this.context.modelRouting,
        nextTier,
        providerState,
      );
      if (!model) break;

      this.prepareRoute(policy, nextTier, model);
      let response;
      try {
        response = await this.promptNextTier(childID, childSession, model);
      } catch (error) {
        policy.awaitingEscalationPrompt = false;
        this.safeLog("WARN", `[subagent-routing] capability escalation request failed: ${error?.name || "Error"}`);
        break;
      }
      policy.awaitingEscalationPrompt = false;
      if (responseError(response)) break;
      const text = responseText(response);
      if (!text) break;
      route.push(nextTier);
      finalText = text;
      evidence = capabilityEscalationEvidence(text);
      if (evidence && this.sideEffects.get(childID)) {
        finalText = [finalText, SIDE_EFFECT_SKIP].join("\n\n");
        evidence = "";
      }
    }

    if (route.length === 1) return null;
    output.output = `[AIDEvOps capability escalation: ${route.join(" → ")}]\n\n${finalText}`;
    output.metadata = {
      ...output.metadata,
      aidevopsRoutingEscalation: {
        attempts: route.length,
        route,
      },
    };
    return output.metadata.aidevopsRoutingEscalation;
  }

  async afterTool(input, output) {
    if (!this.enabled() || !TASK_TOOLS.has(safeToolName(input?.tool))) return null;
    const identity = this.lifecycle.takeChildIdentity(input, output);
    try {
      return await this.escalateTask(output, identity.childID);
    } finally {
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
