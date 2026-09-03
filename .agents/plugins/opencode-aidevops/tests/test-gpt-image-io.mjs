// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { readReferenceImages, saveGeneratedPng, validateImageOutputPath } from "../gpt-image-io.mjs";

const PNG_BYTES = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]);
const roots = [];

async function projectRoot() {
  const root = await mkdtemp(join(process.env.AIDEVOPS_TEMP_DIR || tmpdir(), "aidevops-gpt-image-"));
  roots.push(root);
  return root;
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("GPT image file safety", () => {
  test("creates private PNG output without overwriting an existing image", async () => {
    const root = await projectRoot();
    const first = await saveGeneratedPng("assets/result.png", root, PNG_BYTES.toString("base64"));
    const second = await saveGeneratedPng("assets/result.png", root, PNG_BYTES.toString("base64"));
    assert.equal(first.versioned, false);
    assert.equal(second.versioned, true);
    assert.match(second.savedPath, /result-v2\.png$/);
    assert.deepEqual(await readFile(first.savedPath), PNG_BYTES);
    assert.equal((await lstat(first.savedPath)).mode & 0o777, 0o600);
  });

  test("rejects traversal and symbolic-link output parents", async () => {
    const root = await projectRoot();
    const outside = await projectRoot();
    await symlink(outside, join(root, "linked"), "dir");
    await assert.rejects(validateImageOutputPath("../escape.png", root), /parent traversal/);
    await assert.rejects(validateImageOutputPath("linked/escape.png", root), /symbolic links/);
  });

  test("accepts only regular project-confined reference images with known magic bytes", async () => {
    const root = await projectRoot();
    await mkdir(join(root, "refs"));
    await writeFile(join(root, "refs", "source.png"), PNG_BYTES);
    const images = await readReferenceImages(["refs/source.png"], root);
    assert.equal(images[0].mime, "image/png");
    assert.match(images[0].dataUrl, /^data:image\/png;base64,/);
    await assert.rejects(readReferenceImages(["../source.png"], root), /parent traversal/);
  });
});
