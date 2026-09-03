// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { parseImageSse, requestApiImage, requestOAuthImage } from "../gpt-image-request.mjs";

const IMAGE_RESULT = "aW1hZ2UtcmVzdWx0";

function splitStream(text, splitAt) {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(text.slice(0, splitAt)));
      controller.enqueue(encoder.encode(text.slice(splitAt)));
      controller.close();
    },
  });
}

describe("GPT image provider requests", () => {
  test("parses a completed image from split SSE frames", async () => {
    const event = `data: ${JSON.stringify({
      type: "response.output_item.done",
      item: { type: "image_generation_call", result: IMAGE_RESULT },
    })}\n\n`;
    assert.equal(await parseImageSse(splitStream(event, 17)), IMAGE_RESULT);
  });

  test("builds the OAuth hosted-tool request with references", async () => {
    let captured;
    const event = `data: ${JSON.stringify({
      type: "response.output_item.done",
      item: { type: "image_generation_call", result: IMAGE_RESULT },
    })}\n\n`;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return new Response(splitStream(event, 9), { status: 200, headers: { "Content-Type": "text/event-stream" } });
    };
    const result = await requestOAuthImage(
      { accessToken: "oauth-test-token", accountId: "account-test" },
      { prompt: "draw a test", quality: "low", size: "1024x1024", format: "webp" },
      [{ dataUrl: "data:image/png;base64,dGVzdA==" }],
      fetchImpl,
    );
    const body = JSON.parse(captured.init.body);
    assert.equal(captured.url, "https://chatgpt.com/backend-api/codex/responses");
    assert.equal(captured.init.headers.Authorization, "Bearer oauth-test-token");
    assert.equal(body.tools[0].type, "image_generation");
    assert.equal(body.tools[0].output_format, "webp");
    assert.equal(body.input[0].content[1].type, "input_image");
    assert.equal(result.base64, IMAGE_RESULT);
  });

  test("uses the explicit GPT Image 2 generations endpoint for API auth", async () => {
    let captured;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return Response.json({ data: [{ b64_json: IMAGE_RESULT }] });
    };
    const result = await requestApiImage(
      { accessToken: "unit-test-credential-value" },
      { prompt: "draw a test", quality: "auto", size: "auto" },
      [],
      fetchImpl,
    );
    assert.equal(captured.url, "https://api.openai.com/v1/images/generations");
    const body = JSON.parse(captured.init.body);
    assert.equal(body.model, "gpt-image-2");
    assert.equal(body.output_format, "png");
    assert.equal(result.base64, IMAGE_RESULT);
  });

  test("selects JPEG output for API generation", async () => {
    let captured;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return Response.json({ data: [{ b64_json: IMAGE_RESULT }] });
    };
    await requestApiImage(
      { accessToken: "unit-test-credential-value" },
      { prompt: "draw a test", quality: "auto", size: "auto", format: "jpeg" },
      [],
      fetchImpl,
    );
    assert.equal(JSON.parse(captured.init.body).output_format, "jpeg");
  });

  test("uses multipart GPT Image 2 edits when API references are present", async () => {
    let captured;
    const fetchImpl = async (url, init) => {
      captured = { url, init };
      return Response.json({ data: [{ b64_json: IMAGE_RESULT }] });
    };
    await requestApiImage(
      { accessToken: "unit-test-credential-value" },
      { prompt: "edit a test", quality: "high", size: "1024x1024", format: "webp" },
      [{ buffer: Buffer.from("image"), mime: "image/png", name: "source.png" }],
      fetchImpl,
    );
    assert.equal(captured.url, "https://api.openai.com/v1/images/edits");
    assert.ok(captured.init.body instanceof FormData);
    assert.equal(captured.init.body.get("model"), "gpt-image-2");
    assert.equal(captured.init.body.get("output_format"), "webp");
    assert.equal(captured.init.body.getAll("image[]").length, 1);
    assert.equal(new Headers(captured.init.headers).has("Content-Type"), false);
  });
});
