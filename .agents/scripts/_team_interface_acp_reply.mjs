// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  DIRECT_GREETING_REPLY,
  trustedReplyDestination,
} from "./_team_interface_acp_destination.mjs";

const MAX_REPLY_BYTES = 16 * 1024;
const REPLY_OPEN = "<buzz-reply>";
const REPLY_CLOSE = "</buzz-reply>";

function sanitizeReply(text) {
  return text
    .replace(/\u001B\][^\u0007]*(?:\u0007|\u001B\\)/gu, "")
    .replace(/\u001B\[[0-?]*[ -/]*[@-~]/gu, "")
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/gu, "")
    .trim();
}

function extractPublishableReply(text) {
  const sanitized = sanitizeReply(text);
  const openingCount = sanitized.split(REPLY_OPEN).length - 1;
  const closingCount = sanitized.split(REPLY_CLOSE).length - 1;
  if (openingCount === 0 && closingCount === 0) {
    return "";
  }
  if (openingCount !== 1 || closingCount !== 1) {
    throw new Error("ACP reply has an invalid Buzz publication envelope");
  }
  const contentStart = sanitized.indexOf(REPLY_OPEN) + REPLY_OPEN.length;
  const closingIndex = sanitized.indexOf(REPLY_CLOSE, contentStart);
  if (closingIndex < contentStart) {
    throw new Error("ACP reply has an invalid Buzz publication envelope");
  }
  return sanitizeReply(sanitized.slice(contentStart, closingIndex));
}

export class TurnState {
  constructor() {
    this.byRequest = new Map();
    this.requestsBySession = new Map();
  }

  begin(message) {
    const requestId = message?.id;
    const sessionId = message?.params?.sessionId;
    const destination = trustedReplyDestination(message);
    if (requestId === undefined || typeof sessionId !== "string" || !destination) {
      return null;
    }
    const activeRequests = this.requestsBySession.get(sessionId) ?? new Set();
    if (destination.directGreeting && activeRequests.size === 0) {
      return {...destination, text: DIRECT_GREETING_REPLY};
    }
    const turn = {
      ...destination,
      bytes: 0,
      concurrent: activeRequests.size > 0,
      overflowed: false,
      sessionId,
      text: "",
    };
    if (turn.concurrent) {
      for (const activeRequest of activeRequests) {
        const activeTurn = this.byRequest.get(activeRequest);
        if (activeTurn) {
          activeTurn.concurrent = true;
        }
      }
    }
    this.byRequest.set(requestId, turn);
    activeRequests.add(requestId);
    this.requestsBySession.set(sessionId, activeRequests);
    return null;
  }

  append(message) {
    const sessionId = message?.params?.sessionId;
    const update = message?.params?.update;
    const text = update?.content?.text;
    if (
      typeof sessionId !== "string" ||
      update?.sessionUpdate !== "agent_message_chunk" ||
      typeof text !== "string"
    ) {
      return;
    }
    const activeRequests = this.requestsBySession.get(sessionId);
    if (!activeRequests || activeRequests.size !== 1) {
      return;
    }
    const [requestId] = activeRequests;
    const turn = this.byRequest.get(requestId);
    if (!turn || turn.concurrent || turn.overflowed) {
      return;
    }
    turn.bytes += Buffer.byteLength(text, "utf8");
    if (turn.bytes > MAX_REPLY_BYTES) {
      turn.text = "";
      turn.overflowed = true;
      return;
    }
    turn.text += text;
  }

  finish(message) {
    const requestId = message?.id;
    if (requestId === undefined || (!("result" in message) && !("error" in message))) {
      return null;
    }
    const turn = this.byRequest.get(requestId);
    if (!turn) {
      return null;
    }
    this.byRequest.delete(requestId);
    const activeRequests = this.requestsBySession.get(turn.sessionId);
    activeRequests?.delete(requestId);
    if (activeRequests?.size === 0) {
      this.requestsBySession.delete(turn.sessionId);
    }
    if (turn.concurrent) {
      return null;
    }
    if (turn.overflowed) {
      throw new Error("ACP reply exceeded the safe publication limit");
    }
    if (message?.result?.stopReason !== "end_turn") {
      return null;
    }
    turn.text = extractPublishableReply(turn.text);
    return turn.text.length > 0 ? turn : null;
  }
}
