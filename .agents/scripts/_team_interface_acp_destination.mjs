// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const EVENT_ID_PATTERN = "[0-9a-f]{64}";
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

function trustedReplyInstructions(eventLines, contentIndex, tagsIndex) {
  const instructionPattern = new RegExp(
    "^IMPORTANT: [^\\r\\n]*use `--reply-to (" + EVENT_ID_PATTERN + ")`[^\\r\\n]*$",
    "i",
  );
  const instructions = [];
  for (const [index, line] of eventLines.entries()) {
    const trustedEnvelope = contentIndex < 0 || index < contentIndex ||
      (tagsIndex > contentIndex && index > tagsIndex);
    const instruction = line.match(instructionPattern);
    if (!instruction) {
      if (trustedEnvelope && line.startsWith("IMPORTANT: ") && line.includes("`--reply-to ")) {
        return null;
      }
      continue;
    }
    if (!trustedEnvelope) {
      return null;
    }
    instructions.push(instruction);
  }
  return instructions.length <= 1 ? instructions : null;
}

function collectEventBlocks(blocks, contextIndex, contextLines) {
  const eventMarker = contextLines.indexOf("[Event]");
  const eventBlocks = [];
  let invalidOrder = false;
  if (eventMarker >= 0) {
    eventBlocks.push({lines: contextLines.slice(eventMarker + 1), structured: false});
  }
  for (const [index, block] of blocks.entries()) {
    if (block.startsWith("[Buzz event:")) {
      invalidOrder ||= index <= contextIndex;
      eventBlocks.push({lines: block.split(/\r?\n/u), structured: true});
    }
  }
  return invalidOrder ? null : {eventBlocks, eventMarker};
}

function parseContext(message) {
  const blocks = promptBlocks(message);
  const contextIndexes = blocks
    ?.map((block, index) => block.startsWith("[Context]") ? index : -1)
    .filter((index) => index >= 0) ?? [];
  if (contextIndexes.length !== 1) {
    return null;
  }
  const contextIndex = contextIndexes[0];
  const contextLines = blocks[contextIndex].split(/\r?\n/u);
  const collected = collectEventBlocks(blocks, contextIndex, contextLines);
  if (!collected || collected.eventBlocks.length !== 1) {
    return null;
  }
  const contextHeader = collected.eventMarker < 0
    ? contextLines
    : contextLines.slice(0, collected.eventMarker);
  const channelLines = contextHeader.filter((line) => line.startsWith("Channel: "));
  const channel = channelLines.length === 1
    ? channelLines[0].match(new RegExp(`^Channel: [^\\r\\n]* \\(#(${UUID_PATTERN})\\)$`, "i"))
    : null;
  return channel ? {channel: channel[1], eventBlock: collected.eventBlocks[0]} : null;
}

function eventIndexes(eventLines) {
  return {
    content: eventLines
      .map((line, index) => line.startsWith("Content: ") ? index : -1)
      .filter((index) => index >= 0),
    tags: eventLines
      .map((line, index) => line.startsWith("Tags: ") ? index : -1)
      .filter((index) => index >= 0),
  };
}

function parseEventIdentity(eventLines, contentIndex) {
  const eventHeader = eventLines.slice(0, contentIndex < 0 ? undefined : contentIndex);
  const eventIdLines = eventHeader.filter((line) => line.startsWith("Event ID: "));
  const eventId = eventIdLines.length === 1
    ? eventIdLines[0].match(new RegExp(`^Event ID: (${EVENT_ID_PATTERN})$`, "i"))
    : null;
  const channelLines = eventHeader.filter((line) => line.startsWith("Channel: "));
  const channel = channelLines.length === 1
    ? channelLines[0].match(new RegExp(`^Channel: [^\\r\\n]* \\(#(${UUID_PATTERN})\\)$`, "i"))
    : null;
  return {channel, channelLineCount: channelLines.length, eventId};
}

function parseEvent(eventBlock, expectedChannel) {
  const {lines: eventLines, structured} = eventBlock;
  const indexes = eventIndexes(eventLines);
  const validStructure = !structured ||
    (indexes.content.length === 1 && indexes.tags.length === 1 &&
      indexes.tags[0] > indexes.content[0]);
  if (!validStructure) {
    return null;
  }
  const contentIndex = indexes.content[0] ?? -1;
  const tagsIndex = indexes.tags.at(-1) ?? -1;
  const identity = parseEventIdentity(eventLines, contentIndex);
  const channelMatches = identity.channelLineCount <= 1 &&
    (identity.channelLineCount === 0 || identity.channel?.[1] === expectedChannel);
  if (!identity.eventId || !channelMatches) {
    return null;
  }
  const instructedReplies = trustedReplyInstructions(eventLines, contentIndex, tagsIndex);
  const structuredFallback = structured && contentIndex >= 0 && tagsIndex > contentIndex &&
    identity.channelLineCount === 1;
  if (!instructedReplies || (instructedReplies.length === 0 && !structuredFallback)) {
    return null;
  }
  return instructedReplies[0]?.[1] ?? identity.eventId[1];
}

export function trustedReplyDestination(message) {
  const context = parseContext(message);
  const replyTo = context ? parseEvent(context.eventBlock, context.channel) : null;
  if (!context || !replyTo) {
    return null;
  }
  return {
    channel: context.channel,
    directGreeting: isDirectGreeting(message),
    replyTo,
  };
}

export {DIRECT_GREETING_REPLY};
