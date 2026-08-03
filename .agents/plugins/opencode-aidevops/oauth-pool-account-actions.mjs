// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

/**
 * OAuth Pool — Account Management Actions
 *
 * Mutating pool tool actions for account removal, cooldown resets, pending
 * token assignment, and priority updates.
 *
 * @module oauth-pool-account-actions
 */

import {
  getAccounts, getPendingToken, removeAccount, assignPendingToken,
  withPoolLock, loadPool, savePool,
} from "./oauth-pool-storage.mjs";
import { resetEndpointCooldown } from "./oauth-pool-token-endpoint.mjs";

export function poolActionRemove(provider, email) {
  if (!email) return "Error: email is required for remove action. Usage: remove <email>";
  if (!removeAccount(provider, email)) return `Account ${email} not found in ${provider} pool.`;
  const remaining = getAccounts(provider).length;
  return `Removed ${email} from ${provider} pool (${remaining} account${remaining === 1 ? "" : "s"} remaining).`;
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
