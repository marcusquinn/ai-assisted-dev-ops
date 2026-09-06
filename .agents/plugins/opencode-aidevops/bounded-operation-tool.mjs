// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

const RECEIPT_SCHEMA = "aidevops.interactive-operation/v1";

function responseError(message) {
  return JSON.stringify({ schema: RECEIPT_SCHEMA, error: message });
}

export function createBoundedInteractiveOperationTool(tool, z, manager) {
  return tool({
    description:
      "Start, inspect, or cancel a bounded long-running command without blocking the interactive session. " +
      "Use start for operations expected to exceed the progress interval, then call status periodically. " +
      "Commands are argv arrays, remain confined to the active project root, and must not daemonize or create a new process session. " +
      "Cancellation is session-owned and restoration evidence remains explicit.",
    args: {
      action: z.enum(["start", "status", "cancel"]),
      operation_id: z.string().optional(),
      command: z.array(z.string()).optional(),
      cwd: z.string().optional(),
      budget_seconds: z.number().optional(),
      progress_interval_seconds: z.number().optional(),
      restoration_budget_seconds: z.number().optional(),
      restoration_command: z.array(z.string()).optional(),
    },
    async execute(args, context) {
      try {
        let receipt;
        if (args.action === "start") {
          receipt = await manager.start({
            command: args.command,
            cwd: args.cwd,
            budgetMs: Number(args.budget_seconds || 900) * 1000,
            progressIntervalMs: Number(args.progress_interval_seconds || 900) * 1000,
            restorationBudgetMs: Number(args.restoration_budget_seconds || 60) * 1000,
            restorationCommand: args.restoration_command,
          }, context);
        } else if (args.action === "status") {
          receipt = manager.status(args.operation_id, context);
        } else if (args.action === "cancel") {
          receipt = manager.cancel(args.operation_id, context);
        } else {
          return responseError("unknown action");
        }
        return JSON.stringify(receipt);
      } catch (error) {
        return responseError(error?.message || "bounded operation failed");
      }
    },
  });
}
