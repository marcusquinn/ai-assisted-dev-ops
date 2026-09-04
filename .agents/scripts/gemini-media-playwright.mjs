#!/usr/bin/env node

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  ACTIONS,
  audit,
  doctor,
  ENTRY_URLS,
  fail,
  initializeAccount,
  renameAccount,
  resolveAccount,
  runCli,
  setup,
  showAccounts,
  validateModality,
  writeConfig,
} from './gemini-media-playwright-browser.mjs';
import { deliver, recordBudget } from './gemini-media-playwright-output.mjs';

function parseFlags(args) {
  const values = { positional: [] };
  for (let index = 0; index < args.length; index += 1) {
    const item = args[index];
    if (!item.startsWith('--')) {
      values.positional.push(item);
      continue;
    }
    const key = item.slice(2);
    if (key === 'default' || key === 'headed') {
      values[key] = true;
      continue;
    }
    const next = args[index + 1];
    if (!next || next.startsWith('--')) fail(`missing value for --${key}`);
    values[key] = next;
    index += 1;
  }
  return values;
}

function usage() {
  console.log(`Usage:
  gemini-media-playwright.mjs setup
  gemini-media-playwright.mjs audit
  gemini-media-playwright.mjs doctor
  gemini-media-playwright.mjs login [--account EMAIL_OR_ALIAS] [--default]
  gemini-media-playwright.mjs open <image|video|music> [--account EMAIL_OR_ALIAS] [--headed]
  gemini-media-playwright.mjs action <image|video|music> [--account EMAIL_OR_ALIAS] -- <safe playwright-cli command>
  gemini-media-playwright.mjs deliver <image|video|music> [--account EMAIL_OR_ALIAS]
  gemini-media-playwright.mjs budget <image|video|music> [--account EMAIL_OR_ALIAS] [--consumed N|unknown] [--remaining N|unknown] [--unit UNIT] [--period TEXT] [--evidence TEXT]
  gemini-media-playwright.mjs accounts
  gemini-media-playwright.mjs rename <OLD_ALIAS> <NEW_ALIAS>`);
}

function login(args) {
  const flags = parseFlags(args);
  const account = initializeAccount(flags.account || 'default', Boolean(flags.default));
  const paths = writeConfig(account, 'video');
  runCli(account, ['open', ENTRY_URLS.video, '--config', paths.configPath, '--persistent', '--headed']);
}

function open(args) {
  const flags = parseFlags(args);
  const modality = validateModality(flags.positional[0]);
  const account = resolveAccount(flags.account);
  const paths = writeConfig(account, modality);
  const options = ['open', ENTRY_URLS[modality], '--config', paths.configPath, '--persistent'];
  if (flags.headed) options.push('--headed');
  runCli(account, options);
}

function action(args) {
  const divider = args.indexOf('--');
  if (divider === -1) fail('action requires -- before the playwright-cli command');
  const flags = parseFlags(args.slice(0, divider));
  validateModality(flags.positional[0]);
  const cliArgs = args.slice(divider + 1);
  if (!ACTIONS.has(cliArgs[0])) fail('playwright-cli command is not in the safe action allowlist');
  runCli(resolveAccount(flags.account), cliArgs);
}

function deliverOutput(args) {
  const flags = parseFlags(args);
  const modality = validateModality(flags.positional[0]);
  deliver(resolveAccount(flags.account), modality);
}

function recordAllowance(args) {
  const flags = parseFlags(args);
  const modality = validateModality(flags.positional[0]);
  recordBudget(resolveAccount(flags.account), modality, flags);
}

const handlers = new Map([
  ['setup', setup],
  ['audit', audit],
  ['doctor', doctor],
  ['accounts', showAccounts],
  ['rename', (args) => renameAccount(args[0], args[1])],
  ['login', login],
  ['open', open],
  ['action', action],
  ['deliver', deliverOutput],
  ['budget', recordAllowance],
]);

const [command, ...rawArgs] = process.argv.slice(2);
if (!command || command === 'help' || command === '--help') {
  usage();
} else {
  const handler = handlers.get(command);
  if (!handler) fail('unknown command');
  handler(rawArgs);
}
