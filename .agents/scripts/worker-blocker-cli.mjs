// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { appendWorkerBlockerEvent } from "./worker-blocker-log.mjs";
import {
  listActiveWorkerBlockerIssues,
  resolveWorkerBlockersForIssue,
  resolveWorkerBlockersForSession,
} from "./worker-blocker-reconcile.mjs";

function parseCliArguments(argv) {
  const event = {};
  const options = {};
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "--blocking") {
      event.blocking = value !== "false";
      index++;
    } else if (flag === "--log-file") {
      options.logPath = value;
      index++;
    } else if (flag === "--max-bytes") {
      options.maxBytes = Number(value);
      index++;
    } else if (flag?.startsWith("--")) {
      const key = flag.slice(2).replaceAll("-", "_");
      event[key] = value ?? "";
      index++;
    }
  }
  return { event, options };
}

function runResolution(resolver, event, options) {
  const result = resolver(event, options);
  if (result.ok) process.stdout.write(`${result.resolvedCount}\n`);
  return result.ok ? 0 : 1;
}

function runIssueList(event, options) {
  const result = listActiveWorkerBlockerIssues(event, options);
  if (result.ok && result.issues.length > 0) process.stdout.write(`${result.issues.join("\n")}\n`);
  return result.ok ? 0 : 1;
}

const COMMAND_HANDLERS = new Map([
  ["append", (event, options) => (appendWorkerBlockerEvent(event, options) ? 0 : 1)],
  ["resolve-issue", (event, options) => runResolution(resolveWorkerBlockersForIssue, event, options)],
  ["resolve-session", (event, options) => runResolution(resolveWorkerBlockersForSession, event, options)],
  ["list-active-issues", runIssueList],
]);

export function runWorkerBlockerCli(argv = process.argv.slice(2)) {
  const [command, ...args] = argv;
  const handler = COMMAND_HANDLERS.get(command);
  if (!handler) return 2;
  const { event, options } = parseCliArguments(args);
  return handler(event, options);
}
