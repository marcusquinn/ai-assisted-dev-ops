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

export async function parseImageSse(stream) {
  if (!stream?.getReader) throw new Error("OAuth image response did not include an event stream.");
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  while (true) {
    const { done, value } = await reader.read();
    pending += decoder.decode(value || new Uint8Array(), { stream: !done });
    let next;
    while ((next = takeNextSseBlock(pending))) {
      pending = next.rest;
      const result = parseSseBlock(next.block);
      if (result) {
        await reader.cancel().catch(() => {});
        return result;
      }
    }
    if (pending.length > MAX_SSE_BUFFER_CHARS) {
      await reader.cancel().catch(() => {});
      throw new Error("OAuth image response exceeded the safe event-stream limit.");
    }
    if (done) break;
  }
  const finalResult = parseSseBlock(pending);
  if (finalResult) return finalResult;
  throw new Error("OAuth image response did not contain a completed image.");
}

export async function requestOAuthImage(auth, args, images, fetchImpl) {
  const response = await fetchImpl(CODEX_RESPONSES_ENDPOINT, {
    method: "POST",
    headers: oauthHeaders(auth),
    body: JSON.stringify(oauthRequestBody(args, images)),
  });
  if (!response.ok) return { response, base64: "" };
  return { response, base64: await parseImageSse(response.body) };
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

function apiRequest(auth, args, images) {
  const headers = { Authorization: `Bearer ${auth.accessToken}` };
  if (images.length === 0) {
    headers["Content-Type"] = "application/json";
    return {
      endpoint: OPENAI_IMAGES_GENERATE_ENDPOINT,
      init: { method: "POST", headers, body: JSON.stringify(apiJsonBody(args)) },
    };
  }
  return {
    endpoint: OPENAI_IMAGES_EDIT_ENDPOINT,
    init: { method: "POST", headers, body: apiMultipartBody(args, images) },
  };
}

export async function requestApiImage(auth, args, images, fetchImpl) {
  const request = apiRequest(auth, args, images);
  const response = await fetchImpl(request.endpoint, request.init);
  if (!response.ok) return { response, base64: "" };
  const payload = await response.json();
  const base64 = payload?.data?.[0]?.b64_json;
  if (typeof base64 !== "string" || !base64) {
    throw new Error("OpenAI Images API response did not contain an image.");
  }
  return { response, base64 };
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
    const payload = await response.json();
    code = payload?.error?.code || payload?.error?.type || "";
    message = payload?.error?.message || "";
  } catch {
    message = "provider returned a non-JSON error";
  }
  const detail = [code, message].filter(Boolean).map(redactProviderDetail).join(": ");
  return new Error(`OpenAI ${mode} image request failed (${response.status})${detail ? `: ${detail}` : "."}`);
}
