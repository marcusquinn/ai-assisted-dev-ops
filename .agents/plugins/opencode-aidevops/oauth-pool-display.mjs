/**
 * OAuth Pool — Display Formatting & Action Handlers (t2128)
 *
 * Read-only pool tool action handlers. Health checks and mutating account
 * actions live in focused modules and are re-exported here to preserve the
 * original public API.
 *
 * @module oauth-pool-display
 */

import {
  getAccounts, getPendingToken, getPoolFilePath,
} from "./oauth-pool-storage.mjs";
import { getEndpointCooldownValue } from "./oauth-pool-token-endpoint.mjs";
export {
  formatDuration, formatAgo, poolActionCheck,
} from "./oauth-pool-health-check.mjs";
export {
  poolActionRemove, poolActionResetCooldowns,
  poolActionAssignPending, poolActionSetPriority,
} from "./oauth-pool-account-actions.mjs";

// ---------------------------------------------------------------------------
// Pool tool action handlers
// ---------------------------------------------------------------------------

export function poolActionList(provider, accounts, hint, now) {
  if (accounts.length === 0) return `No accounts in the ${provider} pool.\n\n${hint}`;
  const lines = accounts.map((a, i) => {
    const cd = (a.cooldownUntil && a.cooldownUntil > now)
      ? ` (cooldown: ${Math.ceil((a.cooldownUntil - now) / 60000)}m remaining)` : "";
    const lu = a.lastUsed ? ` | last used: ${new Date(a.lastUsed).toLocaleString()}` : "";
    const aid = a.accountId ? ` | id: ${a.accountId.slice(0, 8)}...` : "";
    const pri = a.priority ? ` | priority: ${a.priority}` : "";
    return `${i + 1}. ${a.email} [${a.status}]${cd}${lu}${aid}${pri}`;
  });
  const pending = getPendingToken(provider);
  const pl = pending
    ? `\n\nPENDING: Unassigned token (added: ${pending.added}). Use assign-pending <email> to assign it.`
    : "";
  return `${provider} pool (${accounts.length} account${accounts.length === 1 ? "" : "s"}):\n\n${lines.join("\n")}${pl}`;
}

export function poolActionStatus(provider, accounts, hint, now) {
  if (accounts.length === 0) return `No accounts in the ${provider} pool.\n\n${hint}`;
  const active = accounts.filter((a) => ["active", "idle"].includes(a.status)).length;
  const rl = accounts.filter((a) => a.status === "rate-limited" && a.cooldownUntil && a.cooldownUntil > now).length;
  const ae = accounts.filter((a) => a.status === "auth-error").length;
  const avail = accounts.filter((a) => !a.cooldownUntil || a.cooldownUntil <= now).length;
  const epCd = getEndpointCooldownValue(provider);
  return [
    `${provider} pool status:`,
    `  Total accounts: ${accounts.length}`,
    `  Available now:  ${avail}`,
    `  Active/idle:    ${active}`,
    `  Rate limited:   ${rl}`,
    `  Auth errors:    ${ae}`,
    "",
    epCd > now
      ? `  TOKEN ENDPOINT: RATE LIMITED (${Math.ceil((epCd - now) / 60000)}m remaining)`
      : `  Token endpoint: OK`,
    `Pool file: ${getPoolFilePath()}`,
  ].join("\n");
}

export async function poolActionRotate(client, provider, accounts, resolveInjectFn) {
  if (accounts.length < 2) {
    const pn = { anthropic: "Anthropic Pool", openai: "OpenAI Pool", cursor: "Cursor Pool", google: "Google Pool" };
    return `Cannot rotate: only ${accounts.length} account(s). Add more via Ctrl+A -> ${pn[provider] || "Pool"}.`;
  }
  const current = [...accounts].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0];
  if (!(await resolveInjectFn(provider)(client, current?.email))) {
    return `Rotation failed (${provider}) -- no other active accounts available.`;
  }
  const newest = [...getAccounts(provider)].sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0];
  return `Rotated (${provider}): now using ${newest?.email || "unknown"}. Previous: ${current?.email || "unknown"}.`;
}
