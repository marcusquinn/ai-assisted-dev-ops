// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { checkResearchStagingAccess } from "../research-staging-guard.mjs";

function fixture() {
  const tempRoot = mkdtempSync(join(tmpdir(), "aidevops-research-guard-"));
  const stagingRoot = join(tempRoot, "research-staging", "task-1");
  mkdirSync(stagingRoot, { recursive: true });
  return { tempRoot, stagingRoot, env: { AIDEVOPS_TEMP_DIR: tempRoot } };
}

test("allows regular staged reads and grep scopes", () => {
  const data = fixture();
  const artifact = join(data.stagingRoot, "artifact.txt");
  writeFileSync(artifact, "approved research text\n");

  try {
    assert.doesNotThrow(() => checkResearchStagingAccess("read", { filePath: artifact }, data.env));
    assert.doesNotThrow(() => checkResearchStagingAccess("grep", { path: data.stagingRoot }, data.env));
  } finally {
    rmSync(data.tempRoot, { recursive: true, force: true });
  }
});

test("blocks direct and recursive symlink escapes", () => {
  const data = fixture();
  const outside = mkdtempSync(join(tmpdir(), "aidevops-research-secret-"));
  const outsideFile = join(outside, "notes.txt");
  const link = join(data.stagingRoot, "escape");
  writeFileSync(outsideFile, "outside\n");
  symlinkSync(outside, link, "dir");

  try {
    assert.throws(
      () => checkResearchStagingAccess("read", { filePath: join(link, "notes.txt") }, data.env),
      /outside the managed staging root/,
    );
    assert.throws(
      () => checkResearchStagingAccess("grep", { path: data.stagingRoot }, data.env),
      /symlinks are denied/,
    );
  } finally {
    rmSync(data.tempRoot, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
});

test("blocks credential-like files from read and recursive search", () => {
  const data = fixture();
  const credential = join(data.stagingRoot, ".npmrc");
  writeFileSync(credential, "fixture-only\n");

  try {
    assert.throws(
      () => checkResearchStagingAccess("read", { filePath: credential }, data.env),
      /credential-like paths/,
    );
    assert.throws(
      () => checkResearchStagingAccess("grep", { path: data.stagingRoot }, data.env),
      /credential-like path/,
    );
  } finally {
    rmSync(data.tempRoot, { recursive: true, force: true });
  }
});

test("does not change access outside research staging", () => {
  const data = fixture();
  const sibling = join(data.tempRoot, "other", "artifact.txt");
  mkdirSync(join(data.tempRoot, "other"), { recursive: true });
  writeFileSync(sibling, "unrelated\n");

  try {
    assert.doesNotThrow(() => checkResearchStagingAccess("read", { filePath: sibling }, data.env));
  } finally {
    rmSync(data.tempRoot, { recursive: true, force: true });
  }
});
