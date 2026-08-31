/**
 * OpenAI provider OAuth pool runtime recovery.
 *
 * The built-in OpenAI provider does not pass through the Anthropic AuthHook,
 * so interactive sessions need a response-aware fetch guard that marks
 * usage-limited accounts and retries once with another pooled account.
 */

import { getAccounts, patchAccount, rotateOpenAIPoolToken } from "./oauth-pool.mjs";
import { handleOpenAITokenRefreshFailure, isOpenAITokenRefreshRequest, readOpenAITokenRefreshBody } from "./openai-auth-refresh-recovery.mjs";
import { injectIntentSchemaProperty } from "./provider-auth-body.mjs";

export { isOpenAITokenRefreshRequest } from "./openai-auth-refresh-recovery.mjs";

const OPENAI_API_HOST = "api.openai.com";
const OPENAI_API_PREFIX = "/v1/";
const DEFAULT_OPENAI_COOLDOWN_MS = 300_000;
const USAGE_LIMIT_MARKERS = [
  "usage limit",
  "rate limit",
  "too many requests",
  "quota",
  "insufficient_quota",
  "rate_limit_exceeded",
];

let installed = false;

function transformOpenAITool(tool) {
  if (tool?.type !== "function") return tool;
  if (tool.function?.parameters) {
    const parameters = injectIntentSchemaProperty(tool.function.parameters);
    if (parameters === tool.function.parameters) return tool;
    return { ...tool, function: { ...tool.function, parameters } };
  }
  if (tool.parameters) {
    const parameters = injectIntentSchemaProperty(tool.parameters);
    if (parameters === tool.parameters) return tool;
    return { ...tool, parameters };
  }
  return tool;
}

/** Inject intent into OpenAI Responses and Chat Completions function schemas. */
export function injectOpenAIIntentParameter(tools) {
  return tools.map(transformOpenAITool);
}

/** Transform a serialized OpenAI request body without retaining its contents. */
export function transformOpenAIRequestBody(body) {
  if (!body || typeof body !== "string") return body;
  try {
    const parsed = JSON.parse(body);
    if (!Array.isArray(parsed.tools)) return body;
    parsed.tools = injectOpenAIIntentParameter(parsed.tools);
    return JSON.stringify(parsed);
  } catch {
    return body;
  }
}

export function parseRetryAfterMs(response) {
  const raw = response.headers?.get?.("retry-after");
  if (!raw) return DEFAULT_OPENAI_COOLDOWN_MS;
  const seconds = parseInt(raw, 10);
  if (Number.isFinite(seconds) && seconds > 0) return Math.max(seconds * 1000, DEFAULT_OPENAI_COOLDOWN_MS);
  const date = Date.parse(raw);
  if (Number.isFinite(date)) return Math.max(date - Date.now(), DEFAULT_OPENAI_COOLDOWN_MS);
  return DEFAULT_OPENAI_COOLDOWN_MS;
}

function requestUrl(input) {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.toString();
  return input?.url || "";
}

export function isOpenAIProviderRequest(input) {
  try {
    const url = new URL(requestUrl(input));
    return url.hostname === OPENAI_API_HOST && url.pathname.startsWith(OPENAI_API_PREFIX);
  } catch { return false; }
}

async function readOpenAIErrorPayload(response) {
  try {
    const cloned = response.clone();
    const contentType = cloned.headers?.get?.("content-type") || "";
    if (contentType.includes("application/json")) return await cloned.json();
    return { error: { message: await cloned.text() } };
  } catch { return null; }
}

export async function isOpenAIUsageLimitResponse(response) {
  if (response.status === 429) return true;
  if (![400, 403].includes(response.status)) return false;
  const payload = await readOpenAIErrorPayload(response);
  const error = payload?.error || payload;
  const code = String(error?.code || error?.type || "").toLowerCase();
  const message = String(error?.message || "").toLowerCase();
  return [code, message].some((text) => USAGE_LIMIT_MARKERS.some((marker) => text.includes(marker)));
}

function headersFrom(input, init) {
  if (init?.headers) return new Headers(init.headers);
  if (typeof Request !== "undefined" && input instanceof Request) return new Headers(input.headers);
  return new Headers();
}

export function extractBearerToken(input, init) {
  const authorization = headersFrom(input, init).get("authorization") || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
}

export function resolveOpenAIAccount(accessToken) {
  const accounts = getAccounts("openai");
  if (accessToken) {
    const byAccess = accounts.find((account) => account.access === accessToken);
    if (byAccess) return byAccess;
  }
  return [...accounts].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0] || null;
}

function isUnavailableAccount(account) {
  if (!account) return false;
  if (account.status === "auth-error") return true;
  return !!(account.cooldownUntil && account.cooldownUntil > Date.now());
}

function buildRetryRequest(input) {
  if (typeof Request !== "undefined" && input instanceof Request) return input.clone();
  return input;
}

function extendRequestInit(init, overrides) {
  if (init == null) return { ...overrides };
  return Object.assign(Object.create(Object(init)), overrides);
}

async function prepareOpenAIRequest(input, init) {
  const initHasBody = init != null && "body" in Object(init);
  if (initHasBody && typeof init.body !== "string") return { input, init };
  let body = initHasBody ? init.body : "";
  if (!initHasBody && typeof Request !== "undefined" && input instanceof Request) {
    try {
      body = await input.clone().text();
    } catch {
      return { input, init };
    }
  }
  const transformedBody = transformOpenAIRequestBody(body);
  if (!body || transformedBody === body) return { input, init };
  return { input, init: extendRequestInit(init, { body: transformedBody }) };
}

function buildRetryInit(input, init, accessToken) {
  const retryHeaders = headersFrom(input, init);
  retryHeaders.set("authorization", `Bearer ${accessToken}`);
  return extendRequestInit(init, { headers: retryHeaders });
}

async function handleOpenAIUsageLimit(ctx) {
  const { client, originalFetch, input, init, response, retryInput } = ctx;
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  const currentEmail = current?.email || "unknown";
  if (current) {
    patchAccount("openai", current.email, {
      status: "rate-limited",
      cooldownUntil: Date.now() + parseRetryAfterMs(response),
      lastUsed: new Date().toISOString(),
    });
  }
  console.error(`[aidevops] OpenAI provider: usage/rate limit for ${currentEmail} — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return response;
  const retryInit = buildRetryInit(input, init, rotated.access);
  return originalFetch(buildRetryRequest(retryInput), retryInit);
}

async function maybeRotateBeforeOpenAIFetch(client, input, init) {
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!isUnavailableAccount(current)) return init;
  const currentEmail = current?.email || "unknown";
  console.error(`[aidevops] OpenAI provider: current account ${currentEmail} unavailable before request — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return init;
  return buildRetryInit(input, init, rotated.access);
}

async function handleOpenAIFetchRequest(ctx) {
  const { client, originalFetch, input, init } = ctx;
  const openaiRequest = isOpenAIProviderRequest(input);
  const tokenRefreshRequest = isOpenAITokenRefreshRequest(input);
  const tokenRefreshBody = tokenRefreshRequest ? await readOpenAITokenRefreshBody(input, init) : "";
  const prepared = openaiRequest ? await prepareOpenAIRequest(input, init) : { input, init };
  const retryInput = openaiRequest ? buildRetryRequest(prepared.input) : prepared.input;
  const firstInit = openaiRequest
    ? await maybeRotateBeforeOpenAIFetch(client, prepared.input, prepared.init)
    : prepared.init;
  const response = await originalFetch(prepared.input, firstInit);
  let result = response;

  if (tokenRefreshRequest) {
    result = await handleOpenAITokenRefreshFailure({
      client,
      response,
      bodyText: tokenRefreshBody,
    });
  } else if (openaiRequest && await isOpenAIUsageLimitResponse(response)) {
    result = await handleOpenAIUsageLimit({
      client,
      originalFetch,
      input: prepared.input,
      init: firstInit,
      response,
      retryInput,
    });
  }
  return result;
}

export function installOpenAIProviderFetchRotation(client) {
  if (installed || typeof globalThis.fetch !== "function") return false;
  installed = true;
  const originalFetch = globalThis.fetch.bind(globalThis);
  globalThis.fetch = async (input, init) => {
    return handleOpenAIFetchRequest({ client, originalFetch, input, init });
  };
  return true;
}
