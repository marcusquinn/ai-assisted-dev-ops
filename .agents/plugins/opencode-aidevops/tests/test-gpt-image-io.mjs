// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { readReferenceImages, saveGeneratedPng, validateImageOutputPath } from "../gpt-image-io.mjs";

const PNG_BYTES = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);
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
    assert.equal(first.projectPath, "assets/result.png");
    assert.equal(second.projectPath, "assets/result-v2.png");
    assert.deepEqual(await readFile(join(root, first.projectPath)), PNG_BYTES);
    assert.equal((await lstat(join(root, first.projectPath))).mode & 0o777, 0o600);
  });

  test("rejects traversal and symbolic-link output parents", async () => {
    const root = await projectRoot();
    const outside = await projectRoot();
    await symlink(outside, join(root, "linked"), "dir");
    await assert.rejects(validateImageOutputPath("../escape.png", root), /parent traversal/);
    await assert.rejects(validateImageOutputPath("linked/escape.png", root), /symbolic links/);
    await assert.rejects(validateImageOutputPath(".GIT/escape.png", root), /inside \.git/);
    await assert.rejects(validateImageOutputPath("nested/.GiT/escape.png", root), /inside \.git/);
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

  test("rejects a generated PNG with a corrupted chunk checksum", async () => {
    const root = await projectRoot();
    const corrupted = Buffer.from(PNG_BYTES);
    corrupted[45] ^= 0xff;
    await assert.rejects(
      saveGeneratedPng("assets/corrupt.png", root, corrupted.toString("base64")),
      /invalid checksum/,
    );
  });
});
