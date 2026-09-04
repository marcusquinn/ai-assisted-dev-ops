// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from 'node:crypto';
import {
  appendFileSync,
  chmodSync,
  closeSync,
  copyFileSync,
  existsSync,
  openSync,
  readdirSync,
  readSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { basename, extname, join } from 'node:path';
import { accountPaths, fail, STATE_ROOT, safePathSegment } from './gemini-media-playwright-browser.mjs';

const OUTPUT_EXTENSIONS = {
  image: new Set(['.jpeg', '.jpg', '.png', '.webp']),
  video: new Set(['.mov', '.mp4', '.webm']),
  music: new Set(['.m4a', '.mp3', '.mp4', '.wav']),
};

function listFiles(path, results = []) {
  if (!existsSync(path)) return results;
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const entryPath = join(path, entry.name);
    if (entry.isDirectory()) listFiles(entryPath, results);
    else if (entry.isFile()) results.push(entryPath);
  }
  return results;
}

function hashFile(path) {
  const hash = createHash('sha256');
  const descriptor = openSync(path, 'r');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    let bytesRead = 0;
    do {
      bytesRead = readSync(descriptor, buffer, 0, buffer.length, null);
      if (bytesRead > 0) hash.update(buffer.subarray(0, bytesRead));
    } while (bytesRead > 0);
  } finally {
    closeSync(descriptor);
  }
  return hash.digest('hex');
}

function uniqueDestination(directory, filename, hash) {
  const safeName = safePathSegment(basename(filename, extname(filename)));
  const extension = extname(filename).toLowerCase();
  const initial = join(directory, `${safeName}${extension}`);
  if (!existsSync(initial)) return initial;
  if (hashFile(initial) === hash) return initial;
  return join(directory, `${safeName}-${hash.slice(0, 10)}${extension}`);
}

export function deliver(account, modality) {
  const paths = accountPaths(account, modality);
  const allowed = OUTPUT_EXTENSIONS[modality];
  const sourceFiles = listFiles(paths.runtimeDir).filter((path) => allowed.has(extname(path).toLowerCase()));
  const delivered = [];
  for (const source of sourceFiles) {
    if (!statSync(source).isFile()) continue;
    const hash = hashFile(source);
    const destination = uniqueDestination(paths.downloadDir, basename(source), hash);
    if (!existsSync(destination)) copyFileSync(source, destination);
    const sidecar = `${destination}.json`;
    writeFileSync(sidecar, `${JSON.stringify({
      modality,
      file: basename(destination),
      sha256: hash,
      deliveredAt: new Date().toISOString(),
    }, null, 2)}\n`);
    delivered.push({ file: destination, sha256: hash });
  }
  console.log(JSON.stringify({ delivered, count: delivered.length }, null, 2));
}

function numericOrNull(value) {
  if (value === undefined || value === 'unknown') return null;
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) fail('budget values must be non-negative numbers or unknown');
  return number;
}

function safeNote(value) {
  return [...String(value || 'unknown')]
    .map((character) => character.codePointAt(0) < 32 ? ' ' : character)
    .join('')
    .slice(0, 240);
}

export function recordBudget(account, modality, flags) {
  const consumed = numericOrNull(flags.consumed);
  const remaining = numericOrNull(flags.remaining);
  const unit = safeNote(flags.unit || 'unknown');
  const estimatedGenerations = consumed && remaining !== null ? Math.floor(remaining / consumed) : null;
  const record = {
    timestamp: new Date().toISOString(),
    modality,
    consumed,
    remaining,
    unit,
    allowancePeriod: safeNote(flags.period),
    evidence: safeNote(flags.evidence),
    estimatedGenerations,
    estimateAssumption: estimatedGenerations === null
      ? 'Unavailable because per-request consumption or remaining allowance was not observable.'
      : 'Assumes future requests consume the same allowance as this request.',
  };
  const budgetPath = join(STATE_ROOT, 'accounts', account.id, 'budget.jsonl');
  appendFileSync(budgetPath, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  chmodSync(budgetPath, 0o600);
  console.log(JSON.stringify(record, null, 2));
}
