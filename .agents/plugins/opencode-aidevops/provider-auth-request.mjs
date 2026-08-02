/**
 * Request/response transformation helpers for provider-auth.mjs.
 * Extracted to keep per-file complexity below the threshold.
 */

import { getAnthropicUserAgent, DETECTED_STAINLESS_PACKAGE_VERSION } from "./oauth-pool.mjs";
import { loadCCHConstants } from "./provider-auth-cch.mjs";

export { TOOL_PREFIX } from "./provider-auth-tool-names.mjs";
export { injectIntentParameter, transformRequestBody } from "./provider-auth-body.mjs";
export { transformResponseStream } from "./provider-auth-stream.mjs";

// ---------------------------------------------------------------------------
// Tool name namespace
// ---------------------------------------------------------------------------

export const REQUIRED_BETAS = [
  "oauth-2025-04-20",
  "interleaved-thinking-2025-05-14",
  "prompt-caching-scope-2026-01-05",
  "claude-code-20250219",
];

export const DEPRECATED_BETAS = new Set([
  "code-execution-2025-01-24",
  "extended-cache-ttl-2025-04-11",
]);

// ---------------------------------------------------------------------------
// Header building
// ---------------------------------------------------------------------------

function copyHeadersInstance(target, source) {
  source.forEach((value, key) => target.set(key, value));
}

function copyHeadersArray(target, entries) {
  for (const [key, value] of entries) {
    if (typeof value !== "undefined") target.set(key, String(value));
  }
}

function copyHeadersObject(target, obj) {
  for (const [key, value] of Object.entries(obj)) {
    if (typeof value !== "undefined") target.set(key, String(value));
  }
}

function mergeInitHeaders(target, initHeaders) {
  if (!initHeaders) return;
  if (initHeaders instanceof Headers) copyHeadersInstance(target, initHeaders);
  else if (Array.isArray(initHeaders)) copyHeadersArray(target, initHeaders);
  else copyHeadersObject(target, initHeaders);
}

function mergeBetaHeaders() {
  return REQUIRED_BETAS.join(",");
}

/**
 * Build outgoing request headers with auth, betas, stainless metadata.
 * @param {Request|string|URL} input @param {RequestInit} init @param {string} accessToken
 */
export function buildRequestHeaders(input, init, accessToken) {
  const requestHeaders = new Headers();
  if (input instanceof Request) input.headers.forEach((value, key) => requestHeaders.set(key, value));
  mergeInitHeaders(requestHeaders, init?.headers);
  requestHeaders.set("authorization", `Bearer ${accessToken}`);
  requestHeaders.set("anthropic-beta", mergeBetaHeaders());
  requestHeaders.set("anthropic-dangerous-direct-browser-access", "true");
  requestHeaders.set("anthropic-version", "2023-06-01");
  requestHeaders.set("user-agent", getAnthropicUserAgent());
  requestHeaders.set("x-app", "cli");
  requestHeaders.set("accept", "application/json");
  requestHeaders.set("content-type", "application/json");
  if (!requestHeaders.has("x-claude-code-session-id")) {
    requestHeaders.set("x-claude-code-session-id", globalThis._claudeCodeSessionId ??= crypto.randomUUID());
  }
  requestHeaders.set("x-client-request-id", crypto.randomUUID());
  const { version } = loadCCHConstants();
  requestHeaders.set("X-Stainless-Arch", process.arch === "arm64" ? "arm64" : "x64");
  requestHeaders.set("X-Stainless-Lang", "js");
  requestHeaders.set("X-Stainless-OS", process.platform === "darwin" ? "Mac OS X" : "Linux");
  requestHeaders.set("X-Stainless-Package-Version", DETECTED_STAINLESS_PACKAGE_VERSION);
  requestHeaders.set("X-Stainless-Retry-Count", "0");
  requestHeaders.set("X-Stainless-Runtime", "node");
  requestHeaders.set("X-Stainless-Runtime-Version", process.version);
  requestHeaders.set("X-Stainless-Timeout", "600");
  requestHeaders.delete("x-api-key");
  requestHeaders.delete("x-session-affinity");
  return requestHeaders;
}

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

function parseRequestUrl(input) {
  try {
    if (typeof input === "string" || input instanceof URL) return new URL(input.toString());
    if (input instanceof Request) return new URL(input.url);
  } catch { /* ignore */ }
  return null;
}

function rewriteUrlWithBeta(url, input) {
  url.searchParams.set("beta", "true");
  return input instanceof Request ? new Request(url.toString(), input) : url;
}

/**
 * Add ?beta=true to /v1/messages requests if not already present.
 * @param {Request|string|URL} input @returns {Request|URL|string}
 */
export function addBetaQueryParam(input) {
  const requestUrl = parseRequestUrl(input);
  if (!requestUrl || requestUrl.pathname !== "/v1/messages" || requestUrl.searchParams.has("beta")) return input;
  return rewriteUrlWithBeta(requestUrl, input);
}
