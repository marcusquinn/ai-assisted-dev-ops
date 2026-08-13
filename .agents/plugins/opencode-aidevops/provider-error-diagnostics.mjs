// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const REQUEST_ID_HEADERS = [
  "x-request-id",
  "request-id",
  "cf-ray",
  "traceparent",
];

function statusCode(error) {
  const value = Number(error?.data?.statusCode);
  return Number.isInteger(value) && value >= 100 && value <= 599 ? value : null;
}

function responseBodyKind(body) {
  let kind = "unknown";
  if (body === undefined || body === null) {
    kind = "unavailable";
  } else if (typeof body === "string") {
    const trimmed = body.trim();
    if (!trimmed) {
      kind = "empty";
    } else if (/^(?:<!doctype\s+html|<html\b)/i.test(trimmed)) {
      kind = "html";
    } else {
      try {
        JSON.parse(trimmed);
        kind = "json";
      } catch {
        kind = "text";
      }
    }
  }
  return kind;
}

function requestIdentity(headers) {
  if (!headers || typeof headers !== "object") return {};
  const normalized = new Map(
    Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]),
  );
  for (const header of REQUEST_ID_HEADERS) {
    const value = normalized.get(header);
    if (typeof value === "string" && value.trim()) {
      return { request_id: value.trim().slice(0, 256), request_id_source: header };
    }
  }
  return {};
}

function endpointOrigin(metadata) {
  if (!metadata || typeof metadata !== "object") return null;
  const candidate = metadata.url || metadata.requestURL || metadata.requestUrl || metadata.endpoint;
  if (typeof candidate !== "string") return null;
  try {
    const url = new URL(candidate);
    return url.protocol === "https:" || url.protocol === "http:" ? url.origin : null;
  } catch {
    return null;
  }
}

/** Reduce an OpenCode provider error to safe, provider-neutral diagnostics. */
export function normalizeProviderError(error) {
  if (!error || typeof error !== "object" || error.name !== "APIError") return null;
  const status = statusCode(error);
  const bodyKind = responseBodyKind(error.data?.responseBody);
  const message = String(error.data?.message || "").toLowerCase();
  let classification = "provider_error";
  if (status === 403 && (bodyKind === "html" || /gateway|proxy/.test(message))) {
    classification = "gateway_denied";
  } else if (status === 403) {
    classification = "access_denied";
  } else if (status === 401) {
    classification = "authentication_failed";
  } else if (status === 429) {
    classification = "rate_limited";
  } else if (status !== null && status >= 500) {
    classification = "provider_unavailable";
  }

  return {
    classification,
    status_code: status,
    response_body_kind: bodyKind,
    is_retryable: error.data?.isRetryable === true,
    endpoint_origin: endpointOrigin(error.data?.metadata),
    ...requestIdentity(error.data?.responseHeaders),
  };
}

function providerLabel(modelIdentity) {
  const provider = String(modelIdentity || "").split("/", 1)[0];
  return provider || "The provider";
}

function toastMessage(diagnostic, modelIdentity) {
  const provider = providerLabel(modelIdentity);
  if (diagnostic.classification === "gateway_denied") {
    return `${provider} returned HTTP 403 with an HTML gateway response. This is an edge/proxy denial, not proof that your account lost permission. Retry once; if it repeats, switch model/provider. Safe diagnostics were recorded.`;
  }
  return `${provider} returned HTTP 403. This can indicate model, account, or policy access. No credential rotation was attempted; try an alternate route or check provider access. Safe diagnostics were recorded.`;
}

/** Explain provider 403 failures without exposing response bodies or headers. */
export function createProviderErrorHandler({ client, isHeadless, resolveSessionModel, now = Date.now }) {
  const emitted = new Map();
  return async function providerErrorHandler(input) {
    if (isHeadless()) return;
    const event = input?.event || input || {};
    const sessionID = event.properties?.sessionID || event.properties?.info?.id || "";
    if (event.type === "session.deleted") {
      emitted.delete(sessionID);
      return;
    }
    if (event.type !== "session.error" || !sessionID) return;
    const diagnostic = normalizeProviderError(event.properties?.error);
    if (!diagnostic || !["gateway_denied", "access_denied"].includes(diagnostic.classification)) return;
    const timestamp = now();
    const previousTimestamp = emitted.get(sessionID) || 0;
    if (timestamp - previousTimestamp < 30000) return;
    emitted.set(sessionID, timestamp);
    const modelIdentity = resolveSessionModel?.(sessionID) || "";
    try {
      await client.tui.showToast({
        body: {
          title: "Provider request denied",
          message: toastMessage(diagnostic, modelIdentity),
          variant: "warning",
          duration: 15000,
        },
      });
    } catch (error) {
      if (emitted.get(sessionID) === timestamp) {
        if (previousTimestamp) emitted.set(sessionID, previousTimestamp);
        else emitted.delete(sessionID);
      }
      throw error;
    }
  };
}
