// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { dirname, extname, resolve } from "node:path";
import { readReferenceImages } from "./gpt-image-reference-io.mjs";
import {
  assertNoSymlinkSegments,
  pathIsWithin,
  requireProjectRoot,
  requireRelativePath,
} from "./gpt-image-paths.mjs";
import { secureWriteGeneratedImage } from "./gpt-image-secure-write.mjs";

const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const PNG_IEND = Buffer.from([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);
const IMAGE_EXTENSIONS = {
  png: new Set([".png"]),
  jpeg: new Set([".jpg", ".jpeg"]),
  webp: new Set([".webp"]),
};

export { readReferenceImages };

function requireImageFormat(format) {
  if (!Object.hasOwn(IMAGE_EXTENSIONS, format)) throw new Error("Unsupported generated image format.");
  return format;
}

function decodeBase64(base64) {
  const encoded = String(base64 || "").trim();
  if (!encoded || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
    throw new Error("Image provider returned invalid base64 data.");
  }
  const buffer = Buffer.from(encoded, "base64");
  if (buffer.length > MAX_OUTPUT_BYTES) throw new Error("Image provider returned an oversized image.");
  return buffer;
}

function validatePng(buffer) {
  const hasHeader = buffer.length >= 45
    && buffer.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)
    && buffer.readUInt32BE(8) === 13
    && buffer.subarray(12, 16).toString("ascii") === "IHDR";
  const hasEnd = buffer.subarray(-PNG_IEND.length).equals(PNG_IEND);
  if (!hasHeader || !hasEnd) throw new Error("Image provider returned an invalid PNG.");
}

function validateJpeg(buffer) {
  const hasStart = buffer.length >= 4 && buffer[0] === 0xff && buffer[1] === 0xd8;
  const hasEnd = buffer[buffer.length - 2] === 0xff && buffer[buffer.length - 1] === 0xd9;
  if (!hasStart || !hasEnd) throw new Error("Image provider returned an invalid JPEG.");
}

function validateWebp(buffer) {
  const hasHeader = buffer.length >= 20
    && buffer.subarray(0, 4).toString("ascii") === "RIFF"
    && buffer.subarray(8, 12).toString("ascii") === "WEBP"
    && buffer.readUInt32LE(4) + 8 === buffer.length;
  if (!hasHeader) throw new Error("Image provider returned an invalid WebP.");
  let offset = 12;
  let imageChunk = false;
  while (offset + 8 <= buffer.length) {
    const chunkType = buffer.subarray(offset, offset + 4).toString("ascii");
    const chunkSize = buffer.readUInt32LE(offset + 4);
    const end = offset + 8 + chunkSize;
    if (end > buffer.length) throw new Error("Image provider returned a truncated WebP.");
    if (["VP8 ", "VP8L", "VP8X"].includes(chunkType)) imageChunk = true;
    offset = end + (chunkSize % 2);
  }
  if (offset !== buffer.length || !imageChunk) throw new Error("Image provider returned an invalid WebP.");
}

function validateGeneratedImageBase64(base64, format) {
  const selected = requireImageFormat(format);
  const buffer = decodeBase64(base64);
  if (selected === "png") validatePng(buffer);
  else if (selected === "jpeg") validateJpeg(buffer);
  else validateWebp(buffer);
  return buffer;
}

export async function validateImageOutputPath(out, projectRoot, format = "png") {
  const requested = requireRelativePath(out, "Image output");
  const selected = requireImageFormat(format);
  if (!IMAGE_EXTENSIONS[selected].has(extname(requested).toLowerCase())) {
    throw new Error(`Image output extension must match ${selected}.`);
  }
  if (requested.split(/[\\/]+/).some((part) => part.toLowerCase() === ".git")) {
    throw new Error("Image output cannot be written inside .git.");
  }
  const root = await requireProjectRoot(projectRoot);
  const target = resolve(root, requested);
  if (!pathIsWithin(root, target)) throw new Error("Image output escapes the project root.");
  const parent = dirname(target);
  await assertNoSymlinkSegments(root, parent);
  return requested;
}

export async function saveGeneratedImage(out, projectRoot, base64, format = "png", options = {}) {
  const buffer = validateGeneratedImageBase64(base64, format);
  const requestedPath = await validateImageOutputPath(out, projectRoot, format);
  const root = await requireProjectRoot(projectRoot);
  return secureWriteGeneratedImage(buffer, requestedPath, root, options);
}
