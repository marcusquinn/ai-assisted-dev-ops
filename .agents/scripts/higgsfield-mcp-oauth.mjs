#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { isAbsolute } from "node:path";
import {
  HIGGSFIELD_REAUTHORIZATION_MESSAGE,
  oauthError,
  readHiggsfieldState,
  terminalAuthorizationError,
  withRefreshLock,
  writeHiggsfieldStateAtomic,
} from "./higgsfield-mcp-oauth-state.mjs";

export const HIGGSFIELD_TOKEN_ENDPOINT = "https://clerk.higgsfield.ai/oauth/token";
export { HIGGSFIELD_REAUTHORIZATION_MESSAGE };

const DEFAULT_REFRESH_SKEW_MS = 5 * 60 * 1_000;

function tokenContainer(state) {
  if (!state?.tokens || typeof state.tokens !== "object" || Array.isArray(state.tokens)) {
    throw terminalAuthorizationError();
  }
  return state.tokens;
}

function resolveClientId(state) {
  const client = state.client && typeof state.client === "object" ? state.client : {};
  const oauth = state.oauth && typeof state.oauth === "object" ? state.oauth : {};
  const tokens = tokenContainer(state);
  const candidates = [
    state.client_id,
    state.clientId,
    client.client_id,
    client.clientId,
    oauth.client_id,
    oauth.clientId,
    tokens.client_id,
    tokens.clientId,
  ];
  return candidates.find((candidate) => typeof candidate === "string" && candidate.length > 0) || "";
}

function epochMilliseconds(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0) return null;
  return numeric < 10_000_000_000 ? numeric * 1_000 : numeric;
}

function jwtExpiry(accessToken) {
  if (typeof accessToken !== "string") return null;
  const payload = accessToken.split(".")[1];
  if (!payload) return null;
  try {
    const decoded = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    return epochMilliseconds(decoded.exp);
  } catch {
    return null;
  }
}

export function tokenExpiry(state) {
  const tokens = tokenContainer(state);
  const explicitValues = [tokens.expires_at, tokens.expiresAt, state.expires_at, state.expiresAt];
  const explicit = explicitValues.map(epochMilliseconds).find(Boolean);
  if (explicit !== undefined) return explicit;

  const issuedValues = [
    tokens.obtained_at,
    tokens.obtainedAt,
    tokens.issued_at,
    tokens.issuedAt,
    state.obtained_at,
    state.obtainedAt,
  ];
  const issuedAt = issuedValues.map(epochMilliseconds).find(Boolean);
  const expiresIn = Number(tokens.expires_in === undefined ? tokens.expiresIn : tokens.expires_in);
  if (issuedAt && Number.isFinite(expiresIn) && expiresIn > 0) {
    return issuedAt + expiresIn * 1_000;
  }
  return jwtExpiry(tokens.access_token === undefined ? tokens.accessToken : tokens.access_token);
}

export function tokenNeedsRefresh(state, now = Date.now(), skewMs = DEFAULT_REFRESH_SKEW_MS) {
  const tokens = tokenContainer(state);
  const accessToken = tokens.access_token ?? tokens.accessToken;
  if (typeof accessToken !== "string" || accessToken.length === 0) return true;
  const expiry = tokenExpiry(state);
  return expiry !== null && expiry <= now + skewMs;
}

function refreshedState(currentState, responseTokens, now) {
  const currentTokens = tokenContainer(currentState);
  const expiresIn = Number(responseTokens.expires_in ?? responseTokens.expiresIn);
  const nextTokens = {
    ...currentTokens,
    ...responseTokens,
    refresh_token: responseTokens.refresh_token || currentTokens.refresh_token,
    obtained_at: now,
  };
  if (Number.isFinite(expiresIn) && expiresIn > 0) {
    nextTokens.expires_at = now + expiresIn * 1_000;
  } else {
    delete nextTokens.expires_at;
  }
  delete nextTokens.accessToken;
  delete nextTokens.refreshToken;
  delete nextTokens.expiresAt;
  return { ...currentState, tokens: nextTokens };
}

function stateAccessToken(state) {
  const tokens = tokenContainer(state);
  return tokens.access_token ?? tokens.accessToken ?? "";
}

export class HiggsfieldTokenManager {
  constructor({
    statePath,
    fetchImpl = fetch,
    now = Date.now,
    refreshSkewMs = DEFAULT_REFRESH_SKEW_MS,
    tokenEndpoint = HIGGSFIELD_TOKEN_ENDPOINT,
    readStateImpl = readHiggsfieldState,
    writeStateImpl = writeHiggsfieldStateAtomic,
  }) {
    if (!isAbsolute(statePath)) throw oauthError("state path must be absolute");
    this.statePath = statePath;
    this.fetchImpl = fetchImpl;
    this.now = now;
    this.refreshSkewMs = refreshSkewMs;
    this.tokenEndpoint = tokenEndpoint;
    this.readState = readStateImpl;
    this.writeState = writeStateImpl;
    this.refreshPromise = null;
    this.terminalAuthorizationFailure = false;
  }

  async accessToken() {
    if (this.terminalAuthorizationFailure) throw terminalAuthorizationError();
    const state = await this.readState(this.statePath);
    if (!tokenNeedsRefresh(state, this.now(), this.refreshSkewMs)) return stateAccessToken(state);
    return this.refresh({ rejectedToken: null });
  }

  async refreshAfterRejection(rejectedToken) {
    if (this.terminalAuthorizationFailure) throw terminalAuthorizationError();
    return this.refresh({ rejectedToken });
  }

  async refresh({ rejectedToken }) {
    if (!this.refreshPromise) this.refreshPromise = this.createRefreshPromise(rejectedToken);
    return this.refreshPromise;
  }

  createRefreshPromise(rejectedToken) {
    return withRefreshLock(
      this.statePath,
      () => this.refreshWithinLock(rejectedToken),
    ).finally(() => {
      this.refreshPromise = null;
    });
  }

  reusableAccessToken(state, rejectedToken) {
    const currentAccessToken = stateAccessToken(state);
    if (rejectedToken) {
      return currentAccessToken && currentAccessToken !== rejectedToken ? currentAccessToken : "";
    }
    return tokenNeedsRefresh(state, this.now(), this.refreshSkewMs) ? "" : currentAccessToken;
  }

  refreshCredentials(state) {
    const tokens = tokenContainer(state);
    const refreshToken = tokens.refresh_token ?? tokens.refreshToken;
    const clientId = resolveClientId(state);
    if (refreshToken && clientId) return { clientId, refreshToken };
    this.terminalAuthorizationFailure = true;
    throw terminalAuthorizationError();
  }

  async requestRefresh({ clientId, refreshToken }) {
    return this.fetchImpl(this.tokenEndpoint, {
      method: "POST",
      headers: {
        accept: "application/json",
        "content-type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: refreshToken,
        client_id: clientId,
      }),
      redirect: "error",
      signal: AbortSignal.timeout(15_000),
    });
  }

  async parseRefreshResponse(response) {
    try {
      return await response.json();
    } catch {
      throw oauthError("token endpoint returned an invalid response");
    }
  }

  async clearInvalidGrant(currentState) {
    const terminalState = {
      ...currentState,
      tokens: { ...tokenContainer(currentState), refresh_token: null },
    };
    delete terminalState.tokens.refreshToken;
    this.terminalAuthorizationFailure = true;
    await this.writeState(this.statePath, terminalState);
    throw terminalAuthorizationError();
  }

  async assertRefreshSucceeded(response, responseTokens, currentState) {
    if (responseTokens.error === "invalid_grant") await this.clearInvalidGrant(currentState);
    if (!response.ok || responseTokens.error) {
      throw oauthError(`token refresh failed with HTTP ${response.status}`);
    }
    if (typeof responseTokens.access_token !== "string" || responseTokens.access_token.length === 0) {
      throw oauthError("token endpoint response did not include an access token");
    }
  }

  async refreshWithinLock(rejectedToken) {
    const currentState = await this.readState(this.statePath);
    const reusableToken = this.reusableAccessToken(currentState, rejectedToken);
    if (reusableToken) return reusableToken;

    const response = await this.requestRefresh(this.refreshCredentials(currentState));
    const responseTokens = await this.parseRefreshResponse(response);
    await this.assertRefreshSucceeded(response, responseTokens, currentState);
    const nextState = refreshedState(currentState, responseTokens, this.now());
    await this.writeState(this.statePath, nextState);
    return nextState.tokens.access_token;
  }
}
