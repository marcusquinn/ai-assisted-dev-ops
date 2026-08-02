// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — Health Check Formatting
 *
 * Formats account health details and checks provider access-token validity.
 * Pool management action handlers remain in oauth-pool-display.mjs.
 *
 * @module oauth-pool-health-check
 */

import { getAccounts, getPendingToken } from "./oauth-pool-storage.mjs";
import {
  ANTHROPIC_USER_AGENT, OPENCODE_USER_AGENT,
  getEndpointCooldownValue,
} from "./oauth-pool-token-endpoint.mjs";
import { GOOGLE_HEALTH_CHECK_URL } from "./oauth-pool-constants.mjs";

export function formatDuration(ms) {
  const mins = Math.floor(ms / 60000);
  const hours = Math.floor(mins / 60);
  return hours > 0 ? `${hours}h ${mins % 60}m` : `${mins}m`;
}

export function formatAgo(ms) {
  const mins = Math.floor(ms / 60000);
  const hours = Math.floor(mins / 60);
  return hours > 0 ? `${hours}h ${mins % 60}m ago` : `${mins}m ago`;
}

function interpretValidityStatus(status, okOn403, on403msg) {
  if (status === 401) return "INVALID (401 -- needs refresh)";
  if (status === 403 && okOn403) return on403msg || "OK";
  if (status >= 200 && status < 300) return "OK";
  return `HTTP ${status}`;
}

async function checkAccountTokenValidity(prov, account) {
  try {
    if (prov === "anthropic") {
      const r = await fetch("https://api.anthropic.com/v1/models", {
        method: "GET",
        headers: {
          "Authorization": `Bearer ${account.access}`,
          "User-Agent": ANTHROPIC_USER_AGENT,
          "anthropic-version": "2023-06-01",
          "anthropic-beta": "oauth-2025-04-20",
        },
      });
      return interpretValidityStatus(r.status, true);
    }
    if (prov === "openai") {
      const r = await fetch("https://api.openai.com/v1/models", {
        headers: { "Authorization": `Bearer ${account.access}`, "User-Agent": OPENCODE_USER_AGENT },
      });
      return interpretValidityStatus(r.status, false);
    }
    if (prov === "google") {
      const r = await fetch(GOOGLE_HEALTH_CHECK_URL, {
        headers: { "Authorization": `Bearer ${account.access}` },
      });
      return interpretValidityStatus(r.status, true, "OK (403 -- token valid, check AI Pro/Ultra subscription)");
    }
    return `(skipped -- ${prov} uses proxy)`;
  } catch (err) { return `ERROR (${err.code || err.message})`; }
}

async function formatAccountCheckLines(prov, account, now) {
  const lines = [`  ${account.email}:`];
  const expiresIn = account.expires - now;
  lines.push(expiresIn <= 0
    ? `    Token: EXPIRED (${new Date(account.expires).toLocaleString()})`
    : `    Token: expires in ${formatDuration(expiresIn)}`);
  lines.push(`    Status: ${account.status}`);
  if (account.cooldownUntil && account.cooldownUntil > now) {
    lines.push(`    Cooldown: ${Math.ceil((account.cooldownUntil - now) / 60000)}m remaining`);
  }
  if (account.lastUsed) lines.push(`    Last used: ${formatAgo(now - new Date(account.lastUsed).getTime())}`);
  lines.push(`    Refresh token: ${account.refresh ? "present" : "MISSING"}`);
  if (account.access && expiresIn > 0) {
    lines.push(`    Validity: ${await checkAccountTokenValidity(prov, account)}`);
  } else if (expiresIn <= 0) {
    lines.push(`    Validity: EXPIRED -- will auto-refresh on next use`);
  } else {
    lines.push(`    Validity: no access token`);
  }
  return lines.join("\n");
}

export async function poolActionCheck(providerArg, now) {
  const provs = providerArg ? [providerArg] : ["anthropic", "openai", "cursor", "google"];
  const results = [];
  for (const prov of provs) {
    const accts = getAccounts(prov);
    if (accts.length === 0) continue;
    results.push(`\n## ${prov} (${accts.length} account${accts.length === 1 ? "" : "s"})`);
    for (const a of accts) results.push(await formatAccountCheckLines(prov, a, now));
    const epCd = getEndpointCooldownValue(prov);
    results.push(epCd > now
      ? `  Token endpoint: RATE LIMITED (${Math.ceil((epCd - now) / 60000)}m remaining)`
      : `  Token endpoint: OK`);
    const pending = getPendingToken(prov);
    if (pending) results.push(`  PENDING: Unassigned token (added: ${pending.added})`);
  }
  return results.length === 0
    ? `No accounts in any pool.\n\nTo add: run \`opencode auth login\` (Ctrl+A), select a pool provider, enter email, complete OAuth, then switch to the main provider.`
    : `OAuth Pool Health Check${results.join("\n")}`;
}
