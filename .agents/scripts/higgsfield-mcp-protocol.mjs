// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

function fixedError(message) {
  return new Error(`Higgsfield MCP proxy: ${message}`);
}

function isSchemaValue(value) {
  return value !== null && typeof value === "object";
}

function ensureArrayItems(schema) {
  const types = Array.isArray(schema.type) ? schema.type : [schema.type];
  if (types.includes("array") && !Object.hasOwn(schema, "items")) {
    schema.items = { type: "string" };
  }
}

function ensureClosedObject(schema) {
  const types = Array.isArray(schema.type) ? schema.type : [schema.type];
  if (types.includes("object") && schema.properties && !Object.hasOwn(schema, "additionalProperties")) {
    schema.additionalProperties = false;
  }
}

function fixSchema(schema) {
  if (!isSchemaValue(schema)) return;
  if (Array.isArray(schema)) {
    schema.forEach(fixSchema);
    return;
  }
  ensureArrayItems(schema);
  ensureClosedObject(schema);
  Object.values(schema).forEach(fixSchema);
}

export function sanitizeToolSchemas(message) {
  const tools = message?.result?.tools;
  if (!Array.isArray(tools)) return message;
  for (const tool of tools) fixSchema(tool?.inputSchema ?? tool?.parameters);
  return message;
}

function parseEventData(dataLines) {
  try {
    return JSON.parse(dataLines.join("\n"));
  } catch {
    throw fixedError("upstream SSE event did not contain valid JSON-RPC");
  }
}

export function parseServerSentEvents(body) {
  const messages = [];
  let dataLines = [];
  const dispatch = () => {
    if (dataLines.length === 0) return;
    messages.push(parseEventData(dataLines));
    dataLines = [];
  };

  for (const line of body.replace(/\r\n/g, "\n").split("\n")) {
    if (line === "") dispatch();
    else if (line.startsWith("data:")) dataLines.push(line.slice(5).replace(/^ /, ""));
  }
  dispatch();
  return messages;
}

function remoteResult(response, sessionId, messages = []) {
  return { response, sessionId, messages };
}

function parseJsonResponse(response, sessionId, body) {
  try {
    const parsed = JSON.parse(body);
    return remoteResult(response, sessionId, Array.isArray(parsed) ? parsed : [parsed]);
  } catch {
    throw fixedError("upstream returned invalid JSON-RPC");
  }
}

function parseRemoteBody(response, sessionId, body, contentType) {
  if (contentType.includes("text/event-stream")) {
    return remoteResult(response, sessionId, parseServerSentEvents(body));
  }
  if (contentType.includes("application/json")) {
    return parseJsonResponse(response, sessionId, body);
  }
  return remoteResult(response, sessionId);
}

export async function readRemoteResponse(response) {
  const sessionId = response.headers.get("mcp-session-id");
  if (response.status === 202 || response.status === 204) {
    return remoteResult(response, sessionId);
  }
  const body = await response.text();
  if (!body) return remoteResult(response, sessionId);
  return parseRemoteBody(
    response,
    sessionId,
    body,
    response.headers.get("content-type") || "",
  );
}
