// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const VALUE_OPTION_KEYS = new Map([
  ["--active-days", "activeDays"],
  ["--archive-dir", "archiveDir"],
  ["--before", "cutoff"],
  ["--db", "dbPath"],
  ["--max-duration-seconds", "maxDurationSeconds"],
  ["--max-partitions", "maxPartitions"],
  ["--max-rows", "maxRows"],
]);

function parseCli(argv) {
  const options = {};
  const command = argv[0] || "inventory";
  for (let index = 1; index < argv.length; index++) {
    const argument = argv[index];
    if (argument === "--apply" || argument === "--dry-run") {
      options.apply = argument === "--apply";
      continue;
    }
    if (argument === "--json") continue;
    const optionKey = VALUE_OPTION_KEYS.get(argument);
    if (!optionKey) throw new TypeError(`unknown retention argument: ${argument}`);
    const value = argv[++index];
    if (!value) throw new TypeError(`${argument} requires a value`);
    options[optionKey] = value;
  }
  return { command, options };
}

export function runRetentionCommand(argv, actions) {
  try {
    const { command, options } = parseCli(argv);
    const action = actions[command];
    if (typeof action !== "function") throw new TypeError("command must be inventory, archive, or maintain");
    process.stdout.write(`${JSON.stringify(action(options))}\n`);
    return 0;
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    process.stderr.write(`runtime-event retention failed: ${message}\n`);
    return 1;
  }
}
