#!/usr/bin/env node

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { spawnSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { basename, delimiter, dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const MODULE_ENV = 'AIDEVOPS_PLAYWRIGHT_MODULE';
const NPM_FALLBACK_ENV = 'AIDEVOPS_PLAYWRIGHT_NPX_FALLBACK';

function moduleUrl(value) {
  if (!value) return null;
  if (value.startsWith('file:')) return value;
  return pathToFileURL(realpathSync(value)).href;
}

function resolveFromAnchor(anchor) {
  try {
    const require = createRequire(pathToFileURL(anchor));
    return pathToFileURL(realpathSync(require.resolve('playwright'))).href;
  } catch {
    return null;
  }
}

function resolutionAnchors() {
  const anchors = [fileURLToPath(import.meta.url), join(process.cwd(), '.aidevops-playwright-resolver.cjs')];
  for (const entry of (process.env.PATH || '').split(delimiter)) {
    if (!entry || dirname(entry) === entry) continue;
    if (basename(entry) === '.bin' && basename(dirname(entry)) === 'node_modules') {
      anchors.push(join(dirname(entry), '.aidevops-playwright-resolver.cjs'));
    }
  }
  return [...new Set(anchors)];
}

async function validateModule(resolved) {
  if (!resolved) return null;
  try {
    const imported = await import(resolved);
    const runtime = imported.chromium ? imported : imported.default;
    return runtime?.chromium ? resolved : null;
  } catch {
    return null;
  }
}

async function resolveWithoutNpx() {
  const explicit = process.env[MODULE_ENV];
  if (explicit) {
    const validated = await validateModule(moduleUrl(explicit));
    if (validated) return validated;
  }

  for (const anchor of resolutionAnchors()) {
    const validated = await validateModule(resolveFromAnchor(anchor));
    if (validated) return validated;
  }
  return null;
}

function resolveViaNpx() {
  if (process.env[NPM_FALLBACK_ENV] === '0') return null;
  const npxCommand = process.platform === 'win32' ? 'npx.cmd' : 'npx';
  const result = spawnSync(
    npxCommand,
    ['--no-install', '--package', 'playwright', 'node', fileURLToPath(import.meta.url), 'resolve-path'],
    {
      encoding: 'utf8',
      env: { ...process.env, [NPM_FALLBACK_ENV]: '0' },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  if (result.status !== 0) return null;
  const resolved = result.stdout.trim().split('\n').at(-1);
  return resolved || null;
}

export async function resolvePlaywrightModule({ allowNpx = true } = {}) {
  const local = await resolveWithoutNpx();
  if (local) return local;

  if (allowNpx) {
    const npxResolved = resolveViaNpx();
    const validated = await validateModule(npxResolved);
    if (validated) return validated;
  }

  throw new Error(
    'Playwright Node package is not importable. CLI availability alone is insufficient; install the package in an importable framework runtime.',
  );
}

export async function loadPlaywright(resolvedModule = null) {
  const resolved = resolvedModule || await resolvePlaywrightModule();
  const imported = await import(resolved);
  return imported.chromium ? imported : imported.default;
}

export async function playwrightStatus() {
  let resolved;
  let runtime;
  try {
    resolved = await resolvePlaywrightModule();
    runtime = await loadPlaywright(resolved);
  } catch (error) {
    return {
      packageImportable: false,
      module: null,
      browserBinaryAvailable: false,
      browserExecutable: null,
      error: error.message,
    };
  }

  const configuredExecutable = process.env.AIDEVOPS_PLAYWRIGHT_EXECUTABLE;
  let browserExecutable = configuredExecutable || null;
  try {
    browserExecutable ||= runtime.chromium.executablePath();
  } catch {
    browserExecutable = null;
  }
  return {
    packageImportable: true,
    module: resolved,
    browserBinaryAvailable: Boolean(browserExecutable && existsSync(browserExecutable)),
    browserExecutable: browserExecutable || null,
  };
}

async function main() {
  const command = process.argv[2] || 'status';
  if (command === 'resolve' || command === 'resolve-path') {
    const resolved = await resolvePlaywrightModule({ allowNpx: command === 'resolve' });
    process.stdout.write(`${resolved}\n`);
    return 0;
  }

  const status = await playwrightStatus();
  if (command === 'status') {
    process.stdout.write(`${JSON.stringify(status)}\n`);
    return 0;
  }
  if (command === 'check') {
    if (!status.packageImportable) throw new Error(status.error);
    if (!status.browserBinaryAvailable) {
      throw new Error('Playwright Node package is importable, but its Chromium browser binary is unavailable. Run: npx playwright install chromium');
    }
    process.stdout.write(`${status.module}\n`);
    return 0;
  }

  throw new Error(`Unknown command: ${command}`);
}

const invokedPath = process.argv[1] ? pathToFileURL(realpathSync(process.argv[1])).href : '';
if (invokedPath === import.meta.url) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
