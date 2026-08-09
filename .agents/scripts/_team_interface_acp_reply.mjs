// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const MAX_REPLY_BYTES = 16 * 1024;
const UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const EVENT_ID_PATTERN = "[0-9a-f]{64}";
const REPLY_OPEN = "<buzz-reply>";
const REPLY_CLOSE = "</buzz-reply>";
const DIRECT_GREETING_REPLY = "Hi! What would you like to work on?";

function promptBlocks(message) {
  const prompt = message?.params?.prompt;
  if (!Array.isArray(prompt)) {
    return null;
  }
  return prompt
    .filter((block) => block && typeof block === "object" && typeof block.text === "string")
    .map((block) => block.text);
}

function isDirectGreeting(message) {
  const prompt = message?.params?.prompt;
  if (!Array.isArray(prompt)) {
    return false;
  }
  const contextBlock = prompt.find(
    (block) => typeof block?.text === "string" && block.text.startsWith("[Context]"),
  );
  const eventBlock = [...prompt].reverse().find(
    (block) => typeof block?.text === "string" && block.text.startsWith("[Buzz event:"),
  );
  if (!contextBlock?.text.match(/^Scope: dm$/im) || !eventBlock) {
    return false;
  }
  const eventLines = eventBlock.text.split(/\r?\n/u);
  const contentIndex = eventLines.findIndex((line) => line.startsWith("Content: "));
  const tagsIndex = eventLines.findLastIndex((line) => line.startsWith("Tags: "));
  if (contentIndex < 0 || tagsIndex !== contentIndex + 1) {
    return false;
  }
  const content = eventLines[contentIndex].slice("Content: ".length).trim();
  return /^(?:hi|hello|hey|hiya|howdy|good (?:morning|afternoon|evening))[!.?]*$/iu.test(
    content || "",
  );
}

function trustedReplyDestination(message) {
  const blocks = promptBlocks(message);
  if (!blocks || blocks.length === 0 || !blocks[0].startsWith("[Context]")) {
    return null;
  }
  const contextLines = blocks[0].split(/\r?\n/u);
  const eventMarker = contextLines.indexOf("[Event]");
  const contextHeader = eventMarker < 0 ? contextLines : contextLines.slice(0, eventMarker);
  const channelLines = contextHeader.filter((line) => line.startsWith("Channel: "));
  const channel = channelLines.length === 1
    ? channelLines[0].match(new RegExp(`^Channel: [^\\r\\n]* \\(#(${UUID_PATTERN})\\)$`, "i"))
    : null;
  const eventBlocks = [];
  if (eventMarker >= 0) {
    eventBlocks.push(contextLines.slice(eventMarker + 1));
  }
  for (const block of blocks.slice(1)) {
    if (block.startsWith("[Buzz event:")) {
      eventBlocks.push(block.split(/\r?\n/u));
    }
  }
  if (!channel || eventBlocks.length !== 1) {
    return null;
  }
  const contentIndex = eventBlocks[0].findIndex((line) => line.startsWith("Content: "));
  const eventHeader = eventBlocks[0].slice(0, contentIndex < 0 ? undefined : contentIndex);
  const eventIds = eventHeader
    .filter((line) => line.startsWith("Event ID: "))
    .map((line) => line.match(new RegExp(`^Event ID: (${EVENT_ID_PATTERN})$`, "i")))
    .filter(Boolean);
  const instructedReplies = eventBlocks[0]
    .map((line) => line.match(
      new RegExp(
        "^IMPORTANT: [^\\r\\n]*use `--reply-to (" + EVENT_ID_PATTERN + ")`[^\\r\\n]*$",
        "i",
      ),
    ))
    .filter(Boolean);
  if (eventIds.length !== 1 || instructedReplies.length !== 1) {
    return null;
  }
  const eventChannels = eventHeader
    .filter((line) => line.startsWith("Channel: "))
    .map((line) => line.match(new RegExp(`^Channel: [^\\r\\n]* \\(#(${UUID_PATTERN})\\)$`, "i")))
    .filter(Boolean);
  if (
    eventChannels.length > 1 ||
    (eventChannels.length === 1 && eventChannels[0][1] !== channel[1])
  ) {
    return null;
  }
  return {
    channel: channel[1],
    directGreeting: isDirectGreeting(message),
    replyTo: instructedReplies[0][1],
  };
}

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
