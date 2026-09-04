// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { constants as fsConstants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { basename, resolve } from "node:path";
import {
  assertNoSymlinkSegments,
  pathIsWithin,
  requireProjectRoot,
  requireRelativePath,
} from "./gpt-image-paths.mjs";

const MAX_REFERENCE_IMAGES = 8;
const MAX_REFERENCE_BYTES = 20 * 1024 * 1024;
const MAX_REFERENCE_TOTAL_BYTES = 50 * 1024 * 1024;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

async function readBoundedReference(handle, byteLimit) {
  const chunks = [];
  let totalBytes = 0;
  while (totalBytes <= byteLimit) {
    const chunk = Buffer.allocUnsafe(Math.min(1024 * 1024, byteLimit - totalBytes + 1));
    const { bytesRead } = await handle.read(chunk, 0, chunk.length, null);
    if (bytesRead === 0) break;
    totalBytes += bytesRead;
    if (totalBytes > byteLimit) throw new Error("Reference image exceeds the remaining safe size limit.");
    chunks.push(chunk.subarray(0, bytesRead));
  }
  return Buffer.concat(chunks, totalBytes);
}

function detectImageMime(buffer) {
  if (buffer.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)) return "image/png";
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return "image/jpeg";
  if (buffer.subarray(0, 4).toString("ascii") === "RIFF" && buffer.subarray(8, 12).toString("ascii") === "WEBP") {
    return "image/webp";
  }
  return "";
}

function validateReferenceBuffer(buffer, requested) {
  if (buffer.length === 0 || buffer.length > MAX_REFERENCE_BYTES) {
    throw new Error(`Reference image ${requested} must be between 1 byte and 20 MiB.`);
  }
  const mime = detectImageMime(buffer);
  if (!mime) throw new Error(`Reference image ${requested} must be PNG, JPEG, or WebP.`);
  return mime;
}

async function readReferenceImage(requested, root, remainingBytes) {
  const relativePath = requireRelativePath(requested, "Reference image");
  const target = resolve(root, relativePath);
  if (!pathIsWithin(root, target)) throw new Error("Reference image escapes the project root.");
  await assertNoSymlinkSegments(root, target);
  if (!fsConstants.O_NOFOLLOW) throw new Error("Secure reference-image reads are unsupported on this platform.");
  const flags = fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW;
  let handle;
  try {
    handle = await open(target, flags);
  } catch {
    throw new Error(`Reference image ${relativePath} is unavailable or unsafe.`);
  }
  let buffer;
  let operationError;
  try {
    const openedStats = await handle.stat();
    if (!openedStats.isFile()) throw new Error(`Reference image ${relativePath} is not a regular file.`);
    if (openedStats.size > MAX_REFERENCE_BYTES || openedStats.size > remainingBytes) {
      throw new Error(`Reference image ${relativePath} exceeds the remaining safe size limit.`);
    }
    const physical = await realpath(target);
    if (!pathIsWithin(root, physical)) throw new Error("Reference image resolves outside the project root.");
    const currentStats = await lstat(physical);
    if (openedStats.dev !== currentStats.dev || openedStats.ino !== currentStats.ino) {
      throw new Error("Reference image changed during secure open.");
    }
    buffer = await readBoundedReference(handle, Math.min(MAX_REFERENCE_BYTES, remainingBytes));
  } catch (error) {
    operationError = error?.code
      ? new Error(`Reference image ${relativePath} is unavailable or unsafe.`)
      : error;
  }
  let closeFailed = false;
  try {
    await handle.close();
  } catch {
    closeFailed = true;
  }
  if (operationError) throw operationError;
  if (closeFailed) throw new Error(`Reference image ${relativePath} could not be closed safely.`);
  const mime = validateReferenceBuffer(buffer, relativePath);
  return { buffer, mime, name: basename(relativePath), dataUrl: `data:${mime};base64,${buffer.toString("base64")}` };
}

export async function readReferenceImages(paths, projectRoot) {
  const requested = paths || [];
  if (!Array.isArray(requested) || requested.length > MAX_REFERENCE_IMAGES) {
    throw new Error(`Reference images must contain at most ${MAX_REFERENCE_IMAGES} paths.`);
  }
  const root = await requireProjectRoot(projectRoot);
  const images = [];
  let totalBytes = 0;
  for (const imagePath of requested) {
    const image = await readReferenceImage(imagePath, root, MAX_REFERENCE_TOTAL_BYTES - totalBytes);
    totalBytes += image.buffer.length;
    if (totalBytes > MAX_REFERENCE_TOTAL_BYTES) {
      throw new Error("Reference images exceed the 50 MiB combined limit.");
    }
    images.push(image);
  }
  return images;
}
