#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  chmod,
  lstat,
  mkdir,
  open,
  readFile,
  rename,
  unlink,
} from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname, isAbsolute } from "node:path";

export const HIGGSFIELD_TOKEN_ENDPOINT = "https://clerk.higgsfield.ai/oauth/token";
export const HIGGSFIELD_REAUTHORIZATION_MESSAGE =
  "Higgsfield authorization must be renewed in a browser; remove and re-add the connector, then retry";

const DEFAULT_REFRESH_SKEW_MS = 5 * 60 * 1_000;
const DEFAULT_LOCK_TIMEOUT_MS = 5_000;
const STALE_LOCK_MS = 30_000;

function fixedError(message) {
  return new Error(`Higgsfield MCP OAuth: ${message}`);
}

function terminalAuthorizationError() {
  return fixedError(HIGGSFIELD_REAUTHORIZATION_MESSAGE);
}

function tokenContainer(state) {
  if (!state?.tokens || typeof state.tokens !== "object" || Array.isArray(state.tokens)) {
    throw terminalAuthorizationError();
  }
  return state.tokens;
}

function resolveClientId(state) {
  const candidates = [
    state?.client_id,
    state?.clientId,
    state?.client?.client_id,
    state?.client?.clientId,
    state?.oauth?.client_id,
    state?.oauth?.clientId,
    state?.tokens?.client_id,
    state?.tokens?.clientId,
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
  const explicit = epochMilliseconds(
    tokens.expires_at
      ?? tokens.expiresAt
      ?? state.expires_at
      ?? state.expiresAt,
  );
  if (explicit) return explicit;

  const issuedAt = epochMilliseconds(
    tokens.obtained_at
      ?? tokens.obtainedAt
      ?? tokens.issued_at
      ?? tokens.issuedAt
      ?? state.obtained_at
      ?? state.obtainedAt,
  );
  const expiresIn = Number(tokens.expires_in ?? tokens.expiresIn);
  if (issuedAt && Number.isFinite(expiresIn) && expiresIn > 0) {
    return issuedAt + expiresIn * 1_000;
  }
  return jwtExpiry(tokens.access_token ?? tokens.accessToken);
}

export function tokenNeedsRefresh(state, now = Date.now(), skewMs = DEFAULT_REFRESH_SKEW_MS) {
  const tokens = tokenContainer(state);
  const accessToken = tokens.access_token ?? tokens.accessToken;
  if (typeof accessToken !== "string" || accessToken.length === 0) return true;
  const expiry = tokenExpiry(state);
  return expiry !== null && expiry <= now + skewMs;
}

export async function readHiggsfieldState(statePath) {
  if (!isAbsolute(statePath)) throw fixedError("state path must be absolute");
  let stats;
  try {
    stats = await lstat(statePath);
  } catch (error) {
    if (error?.code === "ENOENT") throw terminalAuthorizationError();
    throw fixedError("could not inspect the OAuth state file");
  }
  if (!stats.isFile() || stats.isSymbolicLink()) {
    throw fixedError("OAuth state path must be a regular file");
  }
  try {
    return JSON.parse(await readFile(statePath, "utf8"));
  } catch {
    throw fixedError("OAuth state file is not valid JSON");
  }
}

export async function writeHiggsfieldStateAtomic(statePath, state) {
  if (!isAbsolute(statePath)) throw fixedError("state path must be absolute");
  const parent = dirname(statePath);
  await mkdir(parent, { recursive: true, mode: 0o700 });

  try {
    const current = await lstat(statePath);
    if (!current.isFile() || current.isSymbolicLink()) {
      throw fixedError("refusing to replace a non-regular OAuth state file");
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }

  const temporaryPath = `${statePath}.tmp.${process.pid}.${randomUUID()}`;
  let handle;
  try {
    handle = await open(temporaryPath, "wx", 0o600);
    await handle.writeFile(`${JSON.stringify(state, null, 2)}\n`, "utf8");
    await handle.sync();
    await handle.close();
    handle = null;
    await chmod(temporaryPath, 0o600);
    await rename(temporaryPath, statePath);
    await chmod(statePath, 0o600);
  } catch (error) {
    if (handle) await handle.close().catch(() => {});
    await unlink(temporaryPath).catch(() => {});
    throw fixedError(`could not persist refreshed OAuth state (${error?.code || "write failed"})`);
  }
}

function processIsGone(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return false;
  } catch (error) {
    return error?.code === "ESRCH";
  }
}

async function staleLockCanBeRemoved(lockPath, now) {
  let stats;
  try {
    stats = await lstat(lockPath);
  } catch (error) {
    if (error?.code === "ENOENT") return true;
    throw fixedError("could not inspect the refresh lock");
  }
  if (!stats.isFile() || stats.isSymbolicLink()) {
    throw fixedError("refresh lock path is not a regular file");
  }
  if (now() - stats.mtimeMs <= STALE_LOCK_MS) return false;
  try {
    const owner = JSON.parse(await readFile(lockPath, "utf8"));
    return processIsGone(owner.pid);
  } catch {
    return true;
  }
}

async function withRefreshLock(statePath, action, {
  now = Date.now,
  sleep = (milliseconds) => new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds)),
  timeoutMs = DEFAULT_LOCK_TIMEOUT_MS,
} = {}) {
  const lockPath = `${statePath}.refresh.lock`;
  const ownerToken = randomUUID();
  const deadline = now() + timeoutMs;
  await mkdir(dirname(statePath), { recursive: true, mode: 0o700 });

  while (true) {
    let created = false;
    try {
      const handle = await open(lockPath, "wx", 0o600);
      created = true;
      try {
        await handle.writeFile(JSON.stringify({ pid: process.pid, token: ownerToken }), "utf8");
      } finally {
        await handle.close();
      }
      break;
    } catch (error) {
      if (created) await unlink(lockPath).catch(() => {});
      if (error?.code !== "EEXIST") throw fixedError("could not acquire the refresh lock");
      if (await staleLockCanBeRemoved(lockPath, now)) {
        await unlink(lockPath).catch(() => {});
        continue;
      }
      if (now() >= deadline) throw fixedError("timed out waiting for another token refresh");
      await sleep(50);
    }
  }

  try {
    return await action();
  } finally {
    try {
      const owner = JSON.parse(await readFile(lockPath, "utf8"));
      if (owner.token === ownerToken) await unlink(lockPath);
    } catch {
      // A missing or replaced lock is not ours to remove.
    }
  }
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
    if (!isAbsolute(statePath)) throw fixedError("state path must be absolute");
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
    if (!this.refreshPromise) {
      this.refreshPromise = withRefreshLock(this.statePath, async () => {
        const currentState = await this.readState(this.statePath);
        const currentAccessToken = stateAccessToken(currentState);
        if (rejectedToken && currentAccessToken && currentAccessToken !== rejectedToken) {
          return currentAccessToken;
        }
        if (!rejectedToken && !tokenNeedsRefresh(currentState, this.now(), this.refreshSkewMs)) {
          return currentAccessToken;
        }

        const tokens = tokenContainer(currentState);
        const refreshToken = tokens.refresh_token ?? tokens.refreshToken;
        const clientId = resolveClientId(currentState);
        if (!refreshToken || !clientId) {
          this.terminalAuthorizationFailure = true;
          throw terminalAuthorizationError();
        }

        const response = await this.fetchImpl(this.tokenEndpoint, {
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

        let responseTokens = {};
        try {
          responseTokens = await response.json();
        } catch {
          throw fixedError("token endpoint returned an invalid response");
        }
        if (!response.ok || responseTokens.error) {
          if (responseTokens.error === "invalid_grant") {
            const terminalState = {
              ...currentState,
              tokens: { ...tokens, refresh_token: null },
            };
            delete terminalState.tokens.refreshToken;
            this.terminalAuthorizationFailure = true;
            await this.writeState(this.statePath, terminalState);
            throw terminalAuthorizationError();
          }
          throw fixedError(`token refresh failed with HTTP ${response.status}`);
        }
        if (typeof responseTokens.access_token !== "string" || responseTokens.access_token.length === 0) {
          throw fixedError("token endpoint response did not include an access token");
        }

        const acquiredAt = this.now();
        const nextState = refreshedState(currentState, responseTokens, acquiredAt);
        await this.writeState(this.statePath, nextState);
        return nextState.tokens.access_token;
      }).finally(() => {
        this.refreshPromise = null;
      });
    }
    return this.refreshPromise;
  }
}
