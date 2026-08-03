// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";

import { transformResponseStream } from "../provider-auth-request.mjs";

function responseFromChunks(chunks) {
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  });
  return new Response(body, {
    status: 206,
    statusText: "Partial Content",
    headers: { "x-stream-test": "preserved" },
  });
}

test("restores tool names split across SSE chunks and preserves response metadata", async () => {
  const response = responseFromChunks([
    'data: {"type":"content_block_start","name":"mcp__aide',
    'vops__custom_tool"}\n',
    'data: {"type":"content_block_start","name": "Todo',
    'Write"}\n\n',
  ]);

  const transformed = transformResponseStream(response);

  assert.equal(transformed.status, 206);
  assert.equal(transformed.statusText, "Partial Content");
  assert.equal(transformed.headers.get("x-stream-test"), "preserved");
  assert.equal(
    await transformed.text(),
    'data: {"type":"content_block_start","name":"custom_tool"}\n' +
      'data: {"type":"content_block_start","name":"todowrite"}\n\n',
  );
});
