#!/usr/bin/env node

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import {
  HIGGSFIELD_REAUTHORIZATION_MESSAGE,
  HiggsfieldTokenManager,
} from "./higgsfield-mcp-oauth.mjs";
import {
  parseServerSentEvents,
  readRemoteResponse,
  sanitizeToolSchemas,
} from "./higgsfield-mcp-protocol.mjs";

export { parseServerSentEvents, sanitizeToolSchemas };

export const HIGGSFIELD_MCP_URL = "https://mcp.higgsfield.ai/mcp";
export const DEFAULT_HIGGSFIELD_STATE_PATH = join(
  homedir(),
  ".config",
  "aidevops",
  "higgsfield-mcp-proxy",
  "state.json",
);

function fixedError(message) {
  return new Error(`Higgsfield MCP proxy: ${message}`);
}

function authorizationError() {
  return fixedError(HIGGSFIELD_REAUTHORIZATION_MESSAGE);
}

function isExpiredSessionMessage(message) {
  const contentText = Array.isArray(message?.result?.content)
    ? message.result.content.map((entry) => entry?.text).filter(Boolean).join(" ")
    : "";
  const text = [message?.error?.message, message?.error?.data?.message, contentText]
    .filter((value) => typeof value === "string")
    .join(" ");
  return /session has expired|session.*no longer valid|re-authorize the higgsfield connector/i.test(text);
}

function isAuthorizationRejection(remote) {
  return remote.response.status === 401 || remote.messages.some(isExpiredSessionMessage);
}

function requestId(message) {
  return Object.hasOwn(message, "id") ? message.id : undefined;
}

function jsonRpcError(message, error) {
  const id = requestId(message);
  if (id === undefined) return null;
  return {
    jsonrpc: "2.0",
    id,
    error: {
      code: -32000,
      message: error instanceof Error ? error.message : "Higgsfield MCP proxy request failed",
    },
  };
}

export class HiggsfieldMcpProxy {
  constructor({ tokenManager, fetchImpl = fetch, mcpUrl = HIGGSFIELD_MCP_URL }) {
    this.tokenManager = tokenManager;
    this.fetchImpl = fetchImpl;
    this.mcpUrl = mcpUrl;
    this.sessionId = null;
    this.protocolVersion = null;
  }

  async send(message, accessToken) {
    const headers = {
      accept: "application/json, text/event-stream",
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    };
    if (this.sessionId) headers["mcp-session-id"] = this.sessionId;
    if (this.protocolVersion) headers["mcp-protocol-version"] = this.protocolVersion;
    const response = await this.fetchImpl(this.mcpUrl, {
      method: "POST",
      headers,
      body: JSON.stringify(message),
      redirect: "error",
      signal: AbortSignal.timeout(120_000),
    });
    return readRemoteResponse(response);
  }

  updateConnectionState(request, remote) {
    if (remote.sessionId) this.sessionId = remote.sessionId;
    if (request.method === "initialize") {
      const initialization = remote.messages.find((message) => message?.result?.protocolVersion);
      if (initialization) this.protocolVersion = initialization.result.protocolVersion;
    }
  }

  async forward(message) {
    const originalToken = await this.tokenManager.accessToken();
    let remote = await this.send(message, originalToken);
    if (isAuthorizationRejection(remote)) {
      const refreshedToken = await this.tokenManager.refreshAfterRejection(originalToken);
      remote = await this.send(message, refreshedToken);
      if (isAuthorizationRejection(remote)) throw authorizationError();
    }
    if (!remote.response.ok) {
      throw fixedError(`upstream request failed with HTTP ${remote.response.status}`);
    }
    this.updateConnectionState(message, remote);
    return remote.messages.map(sanitizeToolSchemas);
  }
}

function parseInputMessage(line) {
  const message = JSON.parse(line);
  if (!message || typeof message !== "object" || Array.isArray(message)) {
    throw fixedError("JSON-RPC batching is not supported");
  }
  return message;
}

function writeMessages(output, responses) {
  for (const response of responses) output.write(`${JSON.stringify(response)}\n`);
}

function writeRequestFailure(message, error, output, errorOutput) {
  const response = message ? jsonRpcError(message, error) : {
    jsonrpc: "2.0",
    id: null,
    error: { code: -32700, message: "Higgsfield MCP proxy received invalid JSON" },
  };
  if (response) output.write(`${JSON.stringify(response)}\n`);
  else errorOutput.write(`${error instanceof Error ? error.message : "Higgsfield MCP proxy request failed"}\n`);
}

async function processInputLine(proxy, line, output, errorOutput) {
  let message;
  try {
    message = parseInputMessage(line);
    writeMessages(output, await proxy.forward(message));
  } catch (error) {
    writeRequestFailure(message, error, output, errorOutput);
  }
}

export async function runStdioProxy({
  input = process.stdin,
  output = process.stdout,
  errorOutput = process.stderr,
  environment = process.env,
  fetchImpl = fetch,
} = {}) {
  const statePath = environment.HIGGSFIELD_MCP_STATE_PATH || DEFAULT_HIGGSFIELD_STATE_PATH;
  if (!isAbsolute(statePath)) throw fixedError("HIGGSFIELD_MCP_STATE_PATH must be absolute");
  const tokenManager = new HiggsfieldTokenManager({ statePath, fetchImpl });
  const proxy = new HiggsfieldMcpProxy({ tokenManager, fetchImpl });
  const lines = createInterface({ input, crlfDelay: Infinity });

  for await (const line of lines) {
    if (line.trim()) await processInputLine(proxy, line, output, errorOutput);
  }
  return 0;
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath && fileURLToPath(import.meta.url) === invokedPath) {
  runStdioProxy().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Higgsfield MCP proxy failed"}\n`);
    process.exitCode = 1;
  });
}
