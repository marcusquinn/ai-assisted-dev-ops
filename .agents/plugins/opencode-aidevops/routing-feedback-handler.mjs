// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  formatRoutingFeedbackToast,
  routingFeedbackFingerprint,
} from "../../scripts/routing-feedback.mjs";

function eventFrom(input) {
  return input?.event || input || {};
}

function sessionIDFrom(event) {
  return event.properties?.sessionID || event.properties?.info?.sessionID || event.properties?.info?.id || "";
}

/** Emit one updated routing summary whenever an interactive session becomes idle. */
export function createRoutingFeedbackHandler({ client, isHeadless, getFeedback }) {
  const emitted = new Map();

  const pendingToastFor = (sessionID) => {
    const summary = getFeedback(sessionID);
    const fingerprint = routingFeedbackFingerprint(summary);
    const message = formatRoutingFeedbackToast(summary);
    return fingerprint && emitted.get(sessionID) !== fingerprint && message ? { fingerprint, message } : null;
  };
  const hasPending = (sessionID) => Boolean(pendingToastFor(sessionID));

  const routingFeedbackHandler = async (input) => {
    if (isHeadless()) return;
    const event = eventFrom(input);
    const sessionID = sessionIDFrom(event);
    if (sessionID && event.type === "session.deleted") {
      emitted.delete(sessionID);
    }
    if (event.type !== "session.idle") return;

    const pending = sessionID ? pendingToastFor(sessionID) : null;
    if (!pending) return;

    await client.tui.showToast({
      body: {
        title: "Routing feedback",
        message: pending.message,
        variant: "info",
        duration: 12000,
      },
    });
    emitted.set(sessionID, pending.fingerprint);
  };

  routingFeedbackHandler.hasPending = hasPending;
  return routingFeedbackHandler;
}
