/**
 * OpenAI provider OAuth pool runtime recovery.
 *
 * The built-in OpenAI provider does not pass through the Anthropic AuthHook,
 * so interactive sessions need a response-aware fetch guard that marks
 * usage-limited accounts and retries once with another pooled account.
 */

import {
  applyOpenAIPoolAccount,
  forceRefreshOpenAIToken,
  getAccounts,
  markRejectedTokenFailure,
  patchAccount,
  rotateOpenAIPoolToken,
} from "./oauth-pool.mjs";
import { handleOpenAITokenRefreshFailure, isOpenAITokenRefreshRequest, readOpenAITokenRefreshBody } from "./openai-auth-refresh-recovery.mjs";
import { injectIntentSchemaProperty } from "./provider-auth-body.mjs";
import { parseRetryAfterValue } from "./provider-auth-pool-recovery.mjs";

export { isOpenAITokenRefreshRequest } from "./openai-auth-refresh-recovery.mjs";

const OPENAI_API_HOST = "api.openai.com";
const OPENAI_API_PREFIX = "/v1/";
const OPENAI_CODEX_HOST = "chatgpt.com";
const OPENAI_CODEX_PREFIX = "/backend-api/codex/";
const DEFAULT_OPENAI_COOLDOWN_MS = 300_000;
const USAGE_LIMIT_MARKERS = [
  "usage limit",
  "rate limit",
  "too many requests",
  "quota",
  "insufficient_quota",
  "rate_limit_exceeded",
];
const AUTH_FAILURE_MARKERS = [
  "authentication token is expired",
  "access token has expired",
  "expired token",
  "expired access token",
  "invalid access token",
  "invalid token",
  "invalid_api_key",
  "invalid_token",
  "sign in again",
  "token_expired",
  "unauthorized",
];

let installed = false;

function transformOpenAITool(tool) {
  if (tool?.type !== "function") return tool;
  const owner = tool.function?.parameters ? tool.function : (tool.parameters ? tool : null);
  if (!owner) return tool;
  const parameters = injectIntentSchemaProperty(owner.parameters);
  if (parameters === owner.parameters) return tool;
  return owner === tool
    ? { ...tool, parameters }
    : { ...tool, function: { ...tool.function, parameters } };
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
  const parsed = raw ? parseRetryAfterValue(raw) : null;
  return Math.max(parsed ?? DEFAULT_OPENAI_COOLDOWN_MS, DEFAULT_OPENAI_COOLDOWN_MS);
}

export function isOpenAIProviderRequest(input) {
  const rawUrl = typeof input === "string" || input instanceof URL ? input.toString() : input?.url;
  const url = URL.parse(rawUrl);
  return Boolean(url && (
    (url.hostname === OPENAI_API_HOST && url.pathname.startsWith(OPENAI_API_PREFIX))
    || (url.hostname === OPENAI_CODEX_HOST && url.pathname.startsWith(OPENAI_CODEX_PREFIX))
  ));
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

export async function isOpenAIAuthFailureResponse(response) {
  if (response.status === 401) return true;
  if (response.status !== 403 || await isOpenAIUsageLimitResponse(response)) return false;
  const payload = await readOpenAIErrorPayload(response);
  const error = payload?.error || payload;
  const code = String(error?.code || error?.type || "").toLowerCase();
  const message = String(error?.message || error?.detail || payload?.detail || error || "").toLowerCase();
  return [code, message].some((text) => AUTH_FAILURE_MARKERS.some((marker) => text.includes(marker)));
}

function headersFrom(input, init) {
  const requestHeaders = typeof Request !== "undefined" && input instanceof Request ? input.headers : undefined;
  return new Headers(init?.headers ?? requestHeaders);
}

export function extractBearerToken(input, init) {
  const authorization = headersFrom(input, init).get("authorization") || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
}

export function resolveOpenAIAccount(accessToken) {
  const accounts = getAccounts("openai");
  if (accessToken) return accounts.find((account) => account.access === accessToken) ?? null;
  return [...accounts].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0] ?? null;
}

function isUnavailableAccount(account) {
  return Boolean(account && (
    account.status === "auth-error"
    || (account.cooldownUntil && account.cooldownUntil > Date.now())
  ));
}

function buildRetryRequest(input) {
  return typeof Request !== "undefined" && input instanceof Request ? input.clone() : input;
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
    body = await input.clone().text().catch(() => null);
  }
  if (body === null) return { input, init };
  const transformedBody = transformOpenAIRequestBody(body);
  if (!body || transformedBody === body) return { input, init };
  return { input, init: extendRequestInit(init, { body: transformedBody }) };
}

function buildRetryInit(input, init, account) {
  const retryHeaders = headersFrom(input, init);
  retryHeaders.set("authorization", `Bearer ${account.access}`);
  retryHeaders.delete("chatgpt-account-id");
  if (account.accountId) retryHeaders.set("chatgpt-account-id", account.accountId);
  return extendRequestInit(init, { headers: retryHeaders });
}

function retryOpenAIRequest(originalFetch, retryInput, input, init, account) {
  const retryInit = buildRetryInit(input, init, account);
  return originalFetch(buildRetryRequest(retryInput), retryInit);
}

async function handleOpenAIUsageLimit(ctx) {
  const { client, originalFetch, input, init, response, retryInput } = ctx;
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!current) return response;
  const currentEmail = current?.email || "unknown";
  patchAccount("openai", current.email, {
    status: "rate-limited",
    cooldownUntil: Date.now() + parseRetryAfterMs(response),
    lastUsed: new Date().toISOString(),
  });
  console.error(`[aidevops] OpenAI provider: usage/rate limit for ${currentEmail} — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return response;
  return retryOpenAIRequest(originalFetch, retryInput, input, init, rotated);
}

async function handleOpenAIAuthFailure(ctx) {
  const { client, originalFetch, input, init, response, retryInput } = ctx;
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!current) return response;
  const currentEmail = current?.email || "unknown";
  const requestAccountId = headersFrom(input, init).get("chatgpt-account-id");
  if (!current.accountId && requestAccountId) {
    current.accountId = requestAccountId;
    patchAccount("openai", current.email, { accountId: requestAccountId });
  }
  console.error(`[aidevops] OpenAI provider: rejected token for ${currentEmail} — forcing one refresh`);
  const refreshedAccess = await forceRefreshOpenAIToken(current);
  if (refreshedAccess) {
    await applyOpenAIPoolAccount(client, current);
    const retryResponse = await retryOpenAIRequest(originalFetch, retryInput, input, init, current);
    if (await isOpenAIAuthFailureResponse(retryResponse)) {
      markRejectedTokenFailure("openai", current);
    }
    return retryResponse;
  }
  console.error(`[aidevops] OpenAI provider: refresh unavailable for ${currentEmail} — trying another pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return response;
  const retryResponse = await retryOpenAIRequest(originalFetch, retryInput, input, init, rotated);
  if (await isOpenAIAuthFailureResponse(retryResponse)) {
    markRejectedTokenFailure("openai", rotated);
  }
  return retryResponse;
}

async function maybeRotateBeforeOpenAIFetch(client, input, init) {
  const current = resolveOpenAIAccount(extractBearerToken(input, init));
  if (!isUnavailableAccount(current)) return init;
  const currentEmail = current?.email || "unknown";
  console.error(`[aidevops] OpenAI provider: current account ${currentEmail} unavailable before request — rotating pool account`);
  const rotated = await rotateOpenAIPoolToken(client, current?.email);
  if (!rotated?.access) return init;
  return buildRetryInit(input, init, rotated);
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
  } else if (openaiRequest) {
    const responseContext = {
      client,
      originalFetch,
      input: prepared.input,
      init: firstInit,
      response,
      retryInput,
    };
    if (await isOpenAIUsageLimitResponse(response)) {
      result = await handleOpenAIUsageLimit(responseContext);
    } else if (await isOpenAIAuthFailureResponse(response)) {
      result = await handleOpenAIAuthFailure(responseContext);
    }
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
