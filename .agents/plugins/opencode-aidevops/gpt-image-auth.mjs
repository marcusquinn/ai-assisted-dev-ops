// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import { patchAccount } from "./oauth-pool-storage.mjs";

const API_SECRET_PREFIX = "OPENAI_IMAGE_API_KEY_";
const DEFAULT_COOLDOWN_MS = 300_000;

export function normalizeImageAccountAlias(value) {
  const alias = String(value || "").trim();
  if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(alias)) {
    throw new Error("API image account must use 1-64 letters, numbers, or underscores and start with a letter.");
  }
  return alias.toUpperCase();
}

export function imageApiSecretName(account, env = process.env) {
  const selected = account || env.AIDEVOPS_OPENAI_IMAGE_ACCOUNT;
  if (!selected) {
    throw new Error(
      "API image generation requires an explicit account alias or AIDEVOPS_OPENAI_IMAGE_ACCOUNT default.",
    );
  }
  return `${API_SECRET_PREFIX}${normalizeImageAccountAlias(selected)}`;
}

function validateCredential(value, secretName) {
  const credential = String(value || "").trim();
  if (credential.length < 20 || /\s/.test(credential)) {
    throw new Error(`Configured secret ${secretName} is missing or invalid.`);
  }
  return credential;
}

export function readImageApiKey(secretName, options = {}) {
  const env = options.env || process.env;
  if (env[secretName]) return validateCredential(env[secretName], secretName);

  const run = options.execFile || execFileSync;
  try {
    const value = run("aidevops", ["secret", "get", secretName], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 10_000,
    });
    return validateCredential(value, secretName);
  } catch {
    throw new Error(
      `OpenAI image API secret ${secretName} is not configured. Run: aidevops secret set ${secretName}`,
    );
  }
}

async function resolveOAuthAuth(args, options) {
  const resolver = options.resolveOAuthAccount;
  if (typeof resolver !== "function") {
    throw new Error("OpenAI OAuth account selection is unavailable in this runtime.");
  }
  const requestedAccount = String(args.account || "").trim();
  const account = await resolver(requestedAccount || undefined);
  if (!account?.access) {
    const qualifier = requestedAccount ? "requested" : "available";
    throw new Error(
      `No ${qualifier} ChatGPT OAuth account can generate images. Add or inspect OpenAI Pool accounts with model-accounts-pool.`,
    );
  }
  return {
    mode: "oauth",
    accessToken: account.access,
    accountId: account.accountId || "",
    account,
    pinned: Boolean(requestedAccount),
  };
}

function resolveApiAuth(args, options) {
  const env = options.env || process.env;
  const secretName = imageApiSecretName(args.account, env);
  const reader = options.readSecret || ((name) => readImageApiKey(name, options));
  return {
    mode: "api",
    accessToken: reader(secretName),
    accountId: "",
    account: null,
    pinned: true,
  };
}

export async function resolveGptImageAuth(args, options = {}) {
  const mode = args.auth || "oauth";
  if (mode === "oauth") return resolveOAuthAuth(args, options);
  if (mode === "api") return resolveApiAuth(args, options);
  throw new Error("Image auth must be oauth or api.");
}

function retryAfterMs(response) {
  const raw = response.headers?.get?.("retry-after");
  const seconds = Number.parseInt(raw || "", 10);
  if (Number.isFinite(seconds) && seconds > 0) {
    return Math.max(seconds * 1000, DEFAULT_COOLDOWN_MS);
  }
  return DEFAULT_COOLDOWN_MS;
}

export function markOAuthImageRateLimit(auth, response) {
  if (!auth.account?.email) return;
  patchAccount("openai", auth.account.email, {
    status: "rate-limited",
    cooldownUntil: Date.now() + retryAfterMs(response),
    lastUsed: new Date().toISOString(),
  });
}

export function markOAuthImageSuccess(auth) {
  if (!auth.account?.email) return;
  patchAccount("openai", auth.account.email, {
    status: "active",
    cooldownUntil: null,
    lastUsed: new Date().toISOString(),
  });
}

export async function rotateOAuthImageAccount(auth, options = {}) {
  if (auth.mode !== "oauth" || auth.pinned || !auth.account?.email) return null;
  const rotate = options.rotateOAuthAccount;
  if (typeof rotate !== "function") return null;
  const account = await rotate(auth.account.email);
  if (!account?.access) return null;
  return {
    mode: "oauth",
    accessToken: account.access,
    accountId: account.accountId || "",
    account,
    pinned: false,
  };
}
