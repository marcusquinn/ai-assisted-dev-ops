// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { TOOL_NAME_REVERSE } from "./provider-auth-tool-names.mjs";
import { textResponse } from "./response-helpers.mjs";

function stripMcpPrefix(text) {
  // Reverse PascalCase tool names back to OpenCode's native lowercase
  // and strip mcp__aidevops__ prefix from custom tools.
  text = text.replace(/"name"\s*:\s*"mcp__aidevops__([^"]+)"/g, '"name":"$1"');
  for (const [pascal, native] of Object.entries(TOOL_NAME_REVERSE)) {
    text = text.replaceAll(`"name":"${pascal}"`, `"name":"${native}"`);
    text = text.replaceAll(`"name": "${pascal}"`, `"name":"${native}"`);
  }
  return text;
}

// Buffer incomplete SSE lines across chunk boundaries. JSON strings cannot
// contain literal newlines, so transforming complete lines preserves tool names
// even when an upstream chunk splits a name token.
function makeStreamPullHandler(reader, decoder, encoder) {
  let pending = "";
  return async function pull(controller) {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) {
        const tail = pending;
        pending = "";
        controller.enqueue(encoder.encode(stripMcpPrefix(tail)));
        controller.close();
        return;
      }
      pending += decoder.decode(value, { stream: true });
      const nl = pending.lastIndexOf("\n");
      if (nl < 0) continue;
      const emit = pending.slice(0, nl + 1);
      pending = pending.slice(nl + 1);
      controller.enqueue(encoder.encode(stripMcpPrefix(emit)));
      return;
    }
  };
}

/**
 * Wrap a response body stream to restore OpenCode-native tool names.
 * @param {Response} response @returns {Response}
 */
export function transformResponseStream(response) {
  if (!response.body) return response;
  const reader = response.body.getReader();
  const stream = new ReadableStream({
    pull: makeStreamPullHandler(reader, new TextDecoder(), new TextEncoder()),
  });
  return textResponse(stream, { status: response.status, statusText: response.statusText, headers: response.headers });
}
