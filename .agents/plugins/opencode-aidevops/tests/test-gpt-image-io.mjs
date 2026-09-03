// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { afterEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { readReferenceImages, saveGeneratedImage, validateImageOutputPath } from "../gpt-image-io.mjs";

const PNG_BYTES = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64",
);
const JPEG_BYTES = Buffer.from([
  0xff, 0xd8,
  0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00,
  0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0x00,
  0xff, 0xd9,
]);
const WEBP_BYTES = Buffer.from([
  0x52, 0x49, 0x46, 0x46, 0x12, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
  0x56, 0x50, 0x38, 0x4c, 0x05, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00, 0x00, 0x00,
]);
const OUTPUT_CASES = [
  { bytes: PNG_BYTES, extension: "png", format: "png" },
  { bytes: JPEG_BYTES, extension: "jpg", format: "jpeg" },
  { bytes: WEBP_BYTES, extension: "webp", format: "webp" },
];
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
  test("creates private raster outputs without overwriting existing images", async () => {
    const root = await projectRoot();
    for (const { bytes, extension, format } of OUTPUT_CASES) {
      const requested = `assets/result.${extension}`;
      const first = await saveGeneratedImage(requested, root, bytes.toString("base64"), format);
      const second = await saveGeneratedImage(requested, root, bytes.toString("base64"), format);
      assert.equal(first.versioned, false);
      assert.equal(second.versioned, true);
      assert.equal(first.projectPath, requested);
      assert.equal(second.projectPath, `assets/result-v2.${extension}`);
      assert.deepEqual(await readFile(join(root, first.projectPath)), bytes);
      assert.equal((await lstat(join(root, first.projectPath))).mode & 0o777, 0o600);
    }
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

  test("requires the output extension to match the selected native format", async () => {
    const root = await projectRoot();
    await validateImageOutputPath("assets/result.jpg", root, "jpeg");
    await validateImageOutputPath("assets/result.jpeg", root, "jpeg");
    await assert.rejects(validateImageOutputPath("assets/result.png", root, "webp"), /must match webp/);
    await assert.rejects(validateImageOutputPath("assets/result.svg", root, "png"), /must match png/);
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
      saveGeneratedImage("assets/corrupt.png", root, corrupted.toString("base64")),
      /invalid checksum/,
    );
  });

  test("rejects bytes that do not match the selected output format", async () => {
    const root = await projectRoot();
    await assert.rejects(
      saveGeneratedImage("assets/mismatch.webp", root, PNG_BYTES.toString("base64"), "webp"),
      /invalid WebP/,
    );
    await assert.rejects(
      saveGeneratedImage("assets/truncated.jpg", root, Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString("base64"), "jpeg"),
      /without a terminal marker|invalid terminal JPEG marker/,
    );
  });
});
