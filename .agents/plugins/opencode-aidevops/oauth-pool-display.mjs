/**
 * OAuth Pool — Display Formatting & Action Handlers (t2128)
 *
 * Individual pool tool action handlers. Health-check formatting and token
 * validity checks live in oauth-pool-health-check.mjs and are re-exported here
 * to preserve the original public API.
 *
 * @module oauth-pool-display
 */

import {
  getAccounts, getPendingToken, removeAccount, assignPendingToken,
  withPoolLock, loadPool, savePool, getPoolFilePath,
} from "./oauth-pool-storage.mjs";
import {
  getEndpointCooldownValue, resetEndpointCooldown,
} from "./oauth-pool-token-endpoint.mjs";
export {
  formatDuration, formatAgo, poolActionCheck,
} from "./oauth-pool-health-check.mjs";

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

export function poolActionRemove(provider, email) {
  if (!email) return "Error: email is required for remove action. Usage: remove <email>";
  if (!removeAccount(provider, email)) return `Account ${email} not found in ${provider} pool.`;
  const remaining = getAccounts(provider).length;
  return `Removed ${email} from ${provider} pool (${remaining} account${remaining === 1 ? "" : "s"} remaining).`;
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

export function poolActionResetCooldowns(provider) {
  const wasGated = resetEndpointCooldown(provider);
  const resetCount = withPoolLock(() => {
    const pool = loadPool();
    let count = 0;
    if (pool[provider]) {
      for (const a of pool[provider]) {
        if (a.cooldownUntil) { a.cooldownUntil = null; a.status = "idle"; count++; }
      }
      savePool(pool);
    }
    return count;
  });
  const parts = [];
  if (wasGated) parts.push("token endpoint cooldown cleared");
  if (resetCount > 0) parts.push(`${resetCount} account cooldown${resetCount === 1 ? "" : "s"} cleared`);
  if (parts.length === 0) parts.push("no active cooldowns");
  return `Reset (${provider}): ${parts.join(", ")}. Token endpoint requests will proceed on next attempt.`;
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

export function poolActionAssignPending(provider, accounts, email) {
  const pending = getPendingToken(provider);
  if (!pending) return `No pending token for ${provider}.`;
  if (!email) {
    return `Pending ${provider} token found (added: ${pending.added}). Assign to: ${accounts.map((a) => a.email).join(", ")}\n\nUsage: assign-pending with email parameter.`;
  }
  return assignPendingToken(provider, email)
    ? `Assigned pending token to ${email} in ${provider} pool.`
    : `Failed: account ${email} not found. Available: ${accounts.map((a) => a.email).join(", ")}`;
}

export function poolActionSetPriority(provider, email, priority) {
  if (!email) return "Error: email is required for set-priority action.";
  if (priority === undefined || priority === null) return "Error: priority (integer) is required.";
  const p = Number(priority);
  if (!Number.isInteger(p)) return `Error: priority must be an integer, got: ${priority}`;
  return withPoolLock(() => {
    const pool = loadPool();
    const accts = pool[provider] || [];
    const idx = accts.findIndex((a) => a.email === email);
    if (idx < 0) return `Account ${email} not found in ${provider} pool.`;
    if (p === 0) delete accts[idx].priority; else accts[idx].priority = p;
    savePool(pool);
    return p === 0
      ? `Cleared priority for ${email} (defaults to LRU order).`
      : `Set priority ${p} for ${email}. Higher-priority accounts preferred during rotation.`;
  });
}
