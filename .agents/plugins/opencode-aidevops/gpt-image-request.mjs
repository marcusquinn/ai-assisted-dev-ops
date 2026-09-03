// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// OAuth request semantics were independently implemented after reviewing the
// MIT-licensed opencode-gpt-imagegen project by Yuji Hatakeyama:
// https://github.com/yuji-hatakeyama/opencode-gpt-imagegen

const CODEX_RESPONSES_ENDPOINT = "https://chatgpt.com/backend-api/codex/responses";
const OPENAI_IMAGES_GENERATE_ENDPOINT = "https://api.openai.com/v1/images/generations";
const OPENAI_IMAGES_EDIT_ENDPOINT = "https://api.openai.com/v1/images/edits";
const SUBSCRIPTION_ROUTER_MODEL = "gpt-5.5";
const MAX_SSE_BUFFER_CHARS = 96 * 1024 * 1024;
const MAX_SSE_TOTAL_BYTES = 128 * 1024 * 1024;
const MAX_API_RESPONSE_BYTES = 96 * 1024 * 1024;
const MAX_ERROR_RESPONSE_BYTES = 64 * 1024;
const IMAGE_REQUEST_TIMEOUT_MS = 180_000;

async function withImageRequestTimeout(operation) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), IMAGE_REQUEST_TIMEOUT_MS);
  timer.unref?.();
  try {
    return await operation(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}

function imageToolArgs(args) {
  return {
    type: "image_generation",
    output_format: "png",
    quality: args.quality || "auto",
    ...(args.size && args.size !== "auto" ? { size: args.size } : {}),
  };
}

function oauthRequestBody(args, images) {
  const content = [{ type: "input_text", text: args.prompt }];
  for (const image of images) content.push({ type: "input_image", image_url: image.dataUrl });
  return {
    model: SUBSCRIPTION_ROUTER_MODEL,
    instructions: "Generate the requested image by invoking the image_generation tool exactly once.",
    input: [{ role: "user", content }],
    tools: [imageToolArgs(args)],
    tool_choice: { type: "image_generation" },
    stream: true,
    store: false,
  };
}

function oauthHeaders(auth) {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${auth.accessToken}`,
    ...(auth.accountId ? { "ChatGPT-Account-Id": auth.accountId } : {}),
    originator: "opencode",
    Accept: "text/event-stream",
  };
}

function parseSseBlock(block) {
  const data = block
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart())
    .join("\n");
  if (!data || data === "[DONE]") return "";
  try {
    const event = JSON.parse(data);
    if (
      event.type === "response.output_item.done"
      && event.item?.type === "image_generation_call"
      && typeof event.item.result === "string"
    ) {
      return event.item.result;
    }
  } catch {
    return "";
  }
  return "";
}

function takeNextSseBlock(pending) {
  const delimiter = pending.match(/\r?\n\r?\n/);
  if (!delimiter || delimiter.index === undefined) return null;
  const end = delimiter.index + delimiter[0].length;
  return { block: pending.slice(0, delimiter.index), rest: pending.slice(end) };
}

async function cancelSseReader(reader) {
  await reader.cancel().catch(() => {});
}

async function consumeSseBlocks(reader, pending) {
  let next;
  while ((next = takeNextSseBlock(pending))) {
    pending = next.rest;
    if (next.block.length > MAX_SSE_BUFFER_CHARS) {
      await cancelSseReader(reader);
      throw new Error("OAuth image event exceeded the safe event-stream limit.");
    }
    const result = parseSseBlock(next.block);
    if (result) return { pending, result };
  }
  return { pending, result: "" };
}

async function enforceSseLimit(reader, exceeded, message) {
  if (!exceeded) return;
  await cancelSseReader(reader);
  throw new Error(message);
}

export async function parseImageSse(stream) {
  if (!stream?.getReader) throw new Error("OAuth image response did not include an event stream.");
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  let totalBytes = 0;
  while (true) {
    const { done, value } = await reader.read();
    totalBytes += value?.byteLength || 0;
    await enforceSseLimit(
      reader,
      totalBytes > MAX_SSE_TOTAL_BYTES,
      "OAuth image response exceeded the safe event-stream limit.",
    );
    pending += decoder.decode(value || new Uint8Array(), { stream: !done });
    const consumed = await consumeSseBlocks(reader, pending);
    pending = consumed.pending;
    if (consumed.result) {
      await cancelSseReader(reader);
      return consumed.result;
    }
    await enforceSseLimit(
      reader,
      pending.length > MAX_SSE_BUFFER_CHARS,
      "OAuth image response exceeded the safe event-stream limit.",
    );
    if (done) break;
  }
  const finalResult = parseSseBlock(pending);
  if (finalResult) return finalResult;
  throw new Error("OAuth image response did not contain a completed image.");
}

export async function requestOAuthImage(auth, args, images, fetchImpl) {
  return withImageRequestTimeout(async (signal) => {
    const response = await fetchImpl(CODEX_RESPONSES_ENDPOINT, {
      method: "POST",
      headers: oauthHeaders(auth),
      body: JSON.stringify(oauthRequestBody(args, images)),
      signal,
    });
    if (!response.ok) return { response, base64: "", error: await imageRequestError(response, "oauth") };
    return { response, base64: await parseImageSse(response.body) };
  });
}

function apiJsonBody(args) {
  return {
    model: "gpt-image-2",
    prompt: args.prompt,
    quality: args.quality || "auto",
    size: args.size || "auto",
    output_format: "png",
  };
}

function apiMultipartBody(args, images) {
  const body = new FormData();
  body.append("model", "gpt-image-2");
  body.append("prompt", args.prompt);
  body.append("quality", args.quality || "auto");
  body.append("size", args.size || "auto");
  body.append("output_format", "png");
  for (const image of images) {
    body.append("image[]", new Blob([image.buffer], { type: image.mime }), image.name);
  }
  return body;
}

function apiRequest(auth, args, images, signal) {
  const headers = { Authorization: `Bearer ${auth.accessToken}` };
  if (images.length === 0) {
    headers["Content-Type"] = "application/json";
    return {
      endpoint: OPENAI_IMAGES_GENERATE_ENDPOINT,
      init: { method: "POST", headers, body: JSON.stringify(apiJsonBody(args)), signal },
    };
  }
  return {
    endpoint: OPENAI_IMAGES_EDIT_ENDPOINT,
    init: { method: "POST", headers, body: apiMultipartBody(args, images), signal },
  };
}

async function readBoundedJson(response, byteLimit, label) {
  if (!response.body?.getReader) throw new Error(`${label} did not include a response body.`);
  const reader = response.body.getReader();
  const chunks = [];
  let totalBytes = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    totalBytes += value.byteLength;
    if (totalBytes > byteLimit) {
      await reader.cancel().catch(() => {});
      throw new Error(`${label} exceeded the safe response limit.`);
    }
    chunks.push(Buffer.from(value));
  }
  return JSON.parse(Buffer.concat(chunks, totalBytes).toString("utf8"));
}

export async function requestApiImage(auth, args, images, fetchImpl) {
  return withImageRequestTimeout(async (signal) => {
    const request = apiRequest(auth, args, images, signal);
    const response = await fetchImpl(request.endpoint, request.init);
    if (!response.ok) return { response, base64: "", error: await imageRequestError(response, "api") };
    const contentLength = Number(response.headers.get("content-length") || 0);
    if (contentLength > MAX_API_RESPONSE_BYTES) {
      await response.body?.cancel?.().catch(() => {});
      throw new Error("OpenAI Images API response exceeded the safe response limit.");
    }
    const payload = await readBoundedJson(response, MAX_API_RESPONSE_BYTES, "OpenAI Images API response");
    const base64 = payload?.data?.[0]?.b64_json;
    if (typeof base64 !== "string" || !base64) throw new Error("OpenAI Images API response did not contain an image.");
    return { response, base64 };
  });
}

function redactProviderDetail(value) {
  return String(value || "")
    .replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]")
    .replace(/\bsk-[A-Za-z0-9_-]+\b/g, "[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g, "[REDACTED]")
    .slice(0, 300);
}

export async function imageRequestError(response, mode) {
  let code = "";
  let message = "";
  try {
    const payload = await readBoundedJson(response, MAX_ERROR_RESPONSE_BYTES, "OpenAI image error response");
    code = payload?.error?.code || payload?.error?.type || "";
    message = payload?.error?.message || "";
  } catch {
    message = "provider returned a non-JSON error";
  }
  const detail = [code, message].filter(Boolean).map(redactProviderDetail).join(": ");
  return new Error(`OpenAI ${mode} image request failed (${response.status})${detail ? `: ${detail}` : "."}`);
}
