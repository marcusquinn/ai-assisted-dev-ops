/**
 * OAuth Pool — MCP Tool (t2128 refactor)
 *
 * Tool definition for /model-accounts-pool. Action handlers and display
 * formatting are in oauth-pool-display.mjs.
 *
 * @module oauth-pool-tool
 */

import { getAccounts } from "./oauth-pool-storage.mjs";
import { resolveInjectFn } from "./oauth-pool.mjs";
import { tool } from "./tools.mjs";
import {
  poolActionList, poolActionRemove, poolActionStatus,
  poolActionResetCooldowns, poolActionRotate, poolActionAssignPending,
  poolActionCheck, poolActionSetPriority, poolAccountAddCommand,
} from "./oauth-pool-display.mjs";

const z = tool.schema;

// ---------------------------------------------------------------------------
// Tool definition
// ---------------------------------------------------------------------------

export function createPoolTool(client) {
  return tool({
    description: "Manage OAuth account pool for provider credential rotation. Actions: list, rotate, remove, assign-pending, check, status, reset-cooldowns, set-priority. Providers: anthropic, openai, cursor, google. Shell equivalent: oauth-pool-helper.sh.",
    args: {
      action: z.enum(["list", "remove", "status", "reset-cooldowns", "rotate", "assign-pending", "check", "set-priority"]).describe("Action to perform"),
      email: z.string().optional().describe("Account email (for remove/assign-pending/set-priority)"),
      provider: z.enum(["anthropic", "openai", "cursor", "google"]).optional().describe("Provider (default: anthropic)"),
      priority: z.number().optional().describe("Rotation priority for set-priority (higher = preferred; 0 = LRU)"),
    },
    async execute(args) {
      args = args && typeof args === "object" ? args : {};
      const provider = args.provider || "anthropic";
      const accounts = getAccounts(provider);
      const now = Date.now();
      const hint = `To add an account, run \`${poolAccountAddCommand(provider)}\`.`;
      const actions = {
        "list": () => poolActionList(provider, accounts, hint, now),
        "remove": () => poolActionRemove(provider, args.email),
        "status": () => poolActionStatus(provider, accounts, hint, now),
        "reset-cooldowns": () => poolActionResetCooldowns(provider),
        "rotate": () => poolActionRotate(client, provider, accounts, resolveInjectFn),
        "assign-pending": () => poolActionAssignPending(provider, accounts, args.email),
        "check": () => poolActionCheck(args.provider, now),
        "set-priority": () => poolActionSetPriority(provider, args.email, args.priority),
      };
      const handler = actions[args.action];
      return handler ? handler() : `Unknown action: ${args.action}. Available: ${Object.keys(actions).join(", ")}`;
    },
  });
}
