// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { SubagentCancellationLedger, shortSessionHash } from "./subagent-cancellation-ledger.mjs";
import { SubagentLifecycleTracker, scalarSessionID } from "./subagent-lifecycle-tracker.mjs";
import { classifySideEffect, safeToolName } from "./subagent-side-effect-classifier.mjs";

export { classifySideEffect };
export const MAX_CANCELLATION_LEDGER_ENTRIES = 24;
export const MAX_CANCELLATION_RECEIPT_BYTES = 8 * 1024;

function taskWasCancelled(output) {
  const status = String(output?.metadata?.status || output?.status || "").toLowerCase();
  return ["aborted", "cancelled", "canceled"].includes(status)
    || /\b(?:abort(?:ed)?|cancel(?:led|ed)?)\b/i.test(`${output?.title || ""} ${output?.output || ""}`);
}

function responseError(response) {
  return response?.error || response?.data?.error || null;
}

function boundedReceipt(receipt) {
  const bounded = { ...receipt, ledger: [...receipt.ledger] };
  let json = JSON.stringify(bounded);
  while (Buffer.byteLength(json, "utf8") > MAX_CANCELLATION_RECEIPT_BYTES && bounded.ledger.length > 0) {
    bounded.ledger.pop();
    bounded.truncated = true;
    bounded.complete = false;
    if (!bounded.incomplete_reasons.includes("receipt_size_limit")) {
      bounded.incomplete_reasons.push("receipt_size_limit");
    }
    json = JSON.stringify(bounded);
  }
  return { receipt: bounded, json };
}

class SubagentCancellationReceipt {
  constructor(client, options) {
    this.client = client;
    this.maxWaitMs = options.maxWaitMs ?? 3000;
    this.pollMs = options.pollMs ?? 25;
    this.sleep = options.sleep || ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
    this.recordReceipt = options.recordReceipt;
    this.lifecycle = new SubagentLifecycleTracker();
    this.ledger = new SubagentCancellationLedger(
      options.maxEntries || MAX_CANCELLATION_LEDGER_ENTRIES,
      options.qualityLog,
      this.lifecycle,
    );
  }

  async terminateAndConfirm(childID) {
    const result = { abortRequested: false, evidence: "", reason: "child_identity_missing" };
    if (childID && typeof this.client?.session?.abort === "function") {
      result.reason = "abort_api_failed";
      try {
        const response = await this.client.session.abort({ path: { id: childID } });
        if (!responseError(response)) {
          result.abortRequested = true;
          result.reason = "termination_unconfirmed";
          const deadline = Date.now() + this.maxWaitMs;
          result.evidence = this.lifecycle.terminalEvidence(childID);
          while (!result.evidence && Date.now() < deadline) {
            await this.sleep(this.pollMs);
            result.evidence = this.lifecycle.terminalEvidence(childID);
          }
          if (result.evidence) result.reason = "";
        }
      } catch (error) {
        this.ledger.safeLog(
          "WARN",
          `[subagent-cancellation] session abort failed: ${error?.message || error?.name || "Error"}`,
        );
        result.reason = "abort_api_failed";
      }
    } else if (childID) {
      result.reason = "abort_api_unavailable";
      result.evidence = this.lifecycle.terminalEvidence(childID);
    }
    return result;
  }

  incompleteReasons(termination, observedSession, ledgerState) {
    const reasons = [];
    if (!termination.abortRequested) reasons.push(termination.reason || "abort_not_requested");
    if (!termination.evidence) reasons.push("termination_unconfirmed");
    if (!observedSession) reasons.push("lifecycle_events_missing");
    if (ledgerState.unknown) reasons.push("side_effect_outcome_unknown");
    if (ledgerState.truncated) reasons.push("ledger_truncated");
    if (this.ledger.trackingFailed || this.lifecycle.trackingFailed) reasons.push("event_tracking_failed");
    return [...new Set(reasons)];
  }

  buildReceipt(identity, termination) {
    const observedSession = this.lifecycle.observedSession(identity.childID);
    const ledgerState = this.ledger.ledgerFor(identity.childID);
    if ((!identity.childID || !observedSession) && ledgerState.ledger.length === 0) {
      ledgerState.ledger.push({
        call: `sha256:${shortSessionHash(identity.callID)}`,
        kind: "subagent",
        operation: "activity",
        status: "unknown",
        tool: "task",
      });
    }
    const incompleteReasons = this.incompleteReasons(termination, observedSession, ledgerState);
    return {
      version: 1,
      child: `sha256:${shortSessionHash(identity.childID)}`,
      complete: incompleteReasons.length === 0,
      incomplete_reasons: incompleteReasons,
      ledger: ledgerState.ledger.slice(0, MAX_CANCELLATION_LEDGER_ENTRIES),
      reaped: Boolean(termination.abortRequested && termination.evidence),
      telemetry: "pending",
      termination: termination.evidence ? "confirmed" : "unconfirmed",
      termination_evidence: termination.evidence || "none",
      truncated: ledgerState.truncated,
    };
  }

  persistReceipt(receipt, input, childID) {
    let recorded = false;
    try {
      recorded = Boolean(this.recordReceipt?.(receipt, {
        childSessionID: childID,
        parentSessionID: scalarSessionID(input?.sessionID),
      }));
    } catch (error) {
      this.ledger.safeLog(
        "WARN",
        `[subagent-cancellation] receipt persistence failed: ${error?.message || error?.name || "Error"}`,
      );
      recorded = false;
    }
    receipt.telemetry = recorded ? "recorded" : "unavailable";
    if (!recorded) {
      receipt.complete = false;
      receipt.incomplete_reasons.push("telemetry_unavailable");
    }
  }

  appendReceipt(output, receipt) {
    const bounded = boundedReceipt(receipt);
    output.output = `${String(output.output || "").trim()}\n\n[AIDevOps cancellation receipt]\n${bounded.json}`.trim();
    output.metadata = { ...output.metadata, aidevopsCancellationReceipt: bounded.receipt };
    this.ledger.safeLog(
      bounded.receipt.complete ? "INFO" : "WARN",
      `[subagent-cancellation] child ${bounded.receipt.child} termination=${bounded.receipt.termination} receipt=${bounded.receipt.complete ? "complete" : "incomplete"}`,
    );
    return bounded.receipt;
  }

  async cancelledTaskReceipt(input, output) {
    const identity = this.lifecycle.takeChildIdentity(input, output);
    const termination = await this.terminateAndConfirm(identity.childID);
    const receipt = this.buildReceipt(identity, termination);
    this.persistReceipt(receipt, input, identity.childID);
    return this.appendReceipt(output, receipt);
  }

  async afterTool(input, output) {
    const tool = safeToolName(input?.tool);
    let receipt = null;
    if (tool === "task" || tool === "mcp_task") {
      if (taskWasCancelled(output)) receipt = await this.cancelledTaskReceipt(input, output);
      else this.lifecycle.takeChildIdentity(input, output);
    } else {
      this.ledger.afterSideEffect(input, output);
    }
    return receipt;
  }
}

/** Delay a cancelled Task result until child termination is confirmed. */
export function createSubagentCancellationReceipt(client, options = {}) {
  const handler = new SubagentCancellationReceipt(client, options);
  return {
    afterTool: handler.afterTool.bind(handler),
    beforeTool: handler.ledger.beforeTool.bind(handler.ledger),
    handleEvent: handler.ledger.handleEvent.bind(handler.ledger),
  };
}
