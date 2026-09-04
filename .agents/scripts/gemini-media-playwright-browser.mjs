// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, join } from 'node:path';

const HOME = homedir();
export const STATE_ROOT = join(HOME, '.aidevops', '.agent-workspace', 'auto-browse', 'gemini-media');
const ACCOUNTS_FILE = join(STATE_ROOT, 'accounts.json');
const TOOL_ROOT = join(HOME, '.aidevops', '.agent-workspace', 'tools', 'playwright-cli');
const CLI = join(TOOL_ROOT, 'node_modules', '.bin', 'playwright-cli');
const PLAYWRIGHT_CLI_VERSION = '0.1.19';
const DOWNLOAD_ROOT = join(HOME, 'Downloads', 'Gemini');
const BRAVE_CANDIDATES = [
  process.env.AIDEVOPS_BRAVE_EXECUTABLE,
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/usr/bin/brave-browser',
  '/usr/bin/brave',
  '/snap/bin/brave',
].filter(Boolean);
export const ENTRY_URLS = {
  image: 'https://gemini.google.com/app/download/mobile?android-min-version=301356232&ios-min-version=322.0&is_sa=1&target=image&hl=en-US&utm_campaign=microsite_gemini_image_generation_page&icid=microsite_gemini_image_generation_page&utm_source=gemini&utm_medium=web',
  video: 'https://gemini.google.com/veo',
  music: 'https://gemini.google.com/music',
};
const OUTPUT_DIR_NAMES = { image: 'Images', video: 'Videos', music: 'Music' };
export const ACTIONS = new Set([
  'click', 'close', 'dialog-dismiss', 'fill', 'find', 'hover', 'press', 'reload',
  'snapshot', 'tab-list', 'tab-select', 'type',
]);

export function fail(message) {
  console.error(`Error: ${message}`);
  process.exit(1);
}

function ensurePrivateDir(path) {
  mkdirSync(path, { recursive: true, mode: 0o700 });
  chmodSync(path, 0o700);
}

function resolveBrave() {
  const executable = BRAVE_CANDIDATES.find((candidate) => isAbsolute(candidate) && existsSync(candidate));
  if (!executable) fail('Brave Browser was not found; set AIDEVOPS_BRAVE_EXECUTABLE to its absolute executable path');
  return executable;
}

function loadAccounts() {
  if (!existsSync(ACCOUNTS_FILE)) return { default: null, accounts: {} };
  return JSON.parse(readFileSync(ACCOUNTS_FILE, 'utf8'));
}

function saveAccounts(registry) {
  ensurePrivateDir(STATE_ROOT);
  writeFileSync(ACCOUNTS_FILE, `${JSON.stringify(registry, null, 2)}\n`, { mode: 0o600 });
  chmodSync(ACCOUNTS_FILE, 0o600);
}

function normalizeAlias(value) {
  const alias = String(value || '').trim().toLowerCase();
  const hasControlCharacter = [...alias].some((character) => character.codePointAt(0) < 32);
  const hasPathSeparator = ['/', '\\'].some((separator) => alias.includes(separator));
  if (!alias) fail('account alias must be a non-empty email address or safe local label');
  if (alias.length > 254) fail('account alias must be a non-empty email address or safe local label');
  if (hasControlCharacter) fail('account alias must be a non-empty email address or safe local label');
  if (hasPathSeparator) fail('account alias must be a non-empty email address or safe local label');
  return alias;
}

export function safePathSegment(value) {
  return value.replace(/[^a-z0-9@._+-]+/gi, '_').replace(/^\.+/, '_').slice(0, 254) || 'account';
}

function immutableAccountId(alias) {
  return `acct-${createHash('sha256').update(alias).digest('hex').slice(0, 16)}`;
}

export function initializeAccount(aliasValue, setDefault = false) {
  const alias = normalizeAlias(aliasValue || 'default');
  const registry = loadAccounts();
  if (!registry.accounts[alias]) {
    registry.accounts[alias] = {
      id: immutableAccountId(alias),
      createdAt: new Date().toISOString(),
    };
  }
  if (setDefault || !registry.default) registry.default = alias;
  saveAccounts(registry);
  const account = { alias, ...registry.accounts[alias] };
  ensurePrivateDir(join(STATE_ROOT, 'accounts', account.id, 'profile'));
  return account;
}

export function resolveAccount(aliasValue, create = false) {
  const registry = loadAccounts();
  const requested = aliasValue ? normalizeAlias(aliasValue) : registry.default;
  if (!requested) return initializeAccount('default', true);
  if (!registry.accounts[requested]) {
    if (create) return initializeAccount(requested, !registry.default);
    fail('unknown account alias; run the login command for it first');
  }
  return { alias: requested, ...registry.accounts[requested] };
}

export function accountPaths(account, modality) {
  const accountRoot = join(STATE_ROOT, 'accounts', account.id);
  const runtimeDir = join(accountRoot, 'runtime', modality);
  const profileDir = join(accountRoot, 'profile');
  const configPath = join(accountRoot, `playwright-${modality}.json`);
  const downloadDir = join(DOWNLOAD_ROOT, safePathSegment(account.alias), OUTPUT_DIR_NAMES[modality]);
  ensurePrivateDir(runtimeDir);
  ensurePrivateDir(profileDir);
  mkdirSync(downloadDir, { recursive: true });
  return { accountRoot, runtimeDir, profileDir, configPath, downloadDir };
}

export function writeConfig(account, modality) {
  const paths = accountPaths(account, modality);
  const config = {
    browser: {
      browserName: 'chromium',
      isolated: false,
      userDataDir: paths.profileDir,
      launchOptions: { executablePath: resolveBrave() },
      contextOptions: {
        acceptDownloads: true,
        viewport: { width: 1440, height: 900 },
      },
    },
    outputDir: paths.runtimeDir,
    outputMode: 'stdout',
    timeouts: { action: 10000, navigation: 90000 },
    allowUnrestrictedFileAccess: false,
    codegen: 'none',
  };
  writeFileSync(paths.configPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  chmodSync(paths.configPath, 0o600);
  return paths;
}

function runProcess(executable, args, options = {}) {
  const result = spawnSync(executable, args, {
    encoding: 'utf8',
    stdio: options.capture ? 'pipe' : 'inherit',
  });
  if (result.error) fail(result.error.message);
  if (options.capture) return result;
  if (result.status !== 0) process.exit(result.status ?? 1);
  return result;
}

export function runCli(account, cliArgs) {
  if (!existsSync(CLI)) fail('Playwright CLI is missing; run gemini-media-playwright.mjs setup');
  runProcess(CLI, [`-s=gemini-${account.id}`, ...cliArgs]);
}

export function validateModality(value) {
  if (!Object.hasOwn(ENTRY_URLS, value)) fail('modality must be image, video, or music');
  return value;
}

export function renameAccount(oldValue, newValue) {
  const oldAlias = normalizeAlias(oldValue);
  const newAlias = normalizeAlias(newValue);
  const registry = loadAccounts();
  if (!registry.accounts[oldAlias]) fail('old account alias was not found');
  if (registry.accounts[newAlias]) fail('new account alias already exists');
  registry.accounts[newAlias] = registry.accounts[oldAlias];
  delete registry.accounts[oldAlias];
  if (registry.default === oldAlias) registry.default = newAlias;
  saveAccounts(registry);
  const oldDownload = join(DOWNLOAD_ROOT, safePathSegment(oldAlias));
  const newDownload = join(DOWNLOAD_ROOT, safePathSegment(newAlias));
  if (existsSync(oldDownload) && !existsSync(newDownload)) renameSync(oldDownload, newDownload);
  console.log('Account alias updated; the private browser profile was preserved.');
}

export function showAccounts() {
  const registry = loadAccounts();
  const result = Object.keys(registry.accounts).map((alias) => ({
    alias,
    default: alias === registry.default,
  }));
  console.log(JSON.stringify(result, null, 2));
}

export function setup() {
  ensurePrivateDir(TOOL_ROOT);
  runProcess('npm', [
    'install', '--prefix', TOOL_ROOT, '--save-exact', '--ignore-scripts', '--no-audit',
    `@playwright/cli@${PLAYWRIGHT_CLI_VERSION}`,
  ]);
}

export function audit() {
  runProcess('npm', ['audit', '--prefix', TOOL_ROOT, '--omit=dev']);
}

export function doctor() {
  const result = {
    node: process.version,
    brave: Boolean(BRAVE_CANDIDATES.find((candidate) => isAbsolute(candidate) && existsSync(candidate))),
    playwrightCli: false,
    expectedPlaywrightCliVersion: PLAYWRIGHT_CLI_VERSION,
  };
  if (existsSync(CLI)) {
    const version = runProcess(CLI, ['--version'], { capture: true });
    result.playwrightCliVersion = version.stdout.trim();
    result.playwrightCli = version.status === 0 && result.playwrightCliVersion === PLAYWRIGHT_CLI_VERSION;
  }
  console.log(JSON.stringify(result, null, 2));
  if (!result.brave || !result.playwrightCli) process.exitCode = 1;
}
