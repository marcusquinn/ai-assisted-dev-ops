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
import { secureWriteGeneratedPng } from "./gpt-image-secure-write.mjs";

const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const PNG_IEND = Buffer.from([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);

export { readReferenceImages };

function validatePngBase64(base64) {
  const encoded = String(base64 || "").trim();
  if (!encoded || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
    throw new Error("Image provider returned invalid base64 data.");
  }
  const buffer = Buffer.from(encoded, "base64");
  const hasHeader = buffer.length >= 45
    && buffer.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)
    && buffer.readUInt32BE(8) === 13
    && buffer.subarray(12, 16).toString("ascii") === "IHDR";
  const hasEnd = buffer.subarray(-PNG_IEND.length).equals(PNG_IEND);
  if (buffer.length > MAX_OUTPUT_BYTES || !hasHeader || !hasEnd) {
    throw new Error("Image provider returned an invalid or oversized PNG.");
  }
  return buffer;
}

export async function validateImageOutputPath(out, projectRoot) {
  const requested = requireRelativePath(out, "Image output");
  if (extname(requested).toLowerCase() !== ".png") {
    throw new Error("Image output must end in .png.");
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

export async function saveGeneratedPng(out, projectRoot, base64, options = {}) {
  const buffer = validatePngBase64(base64);
  const requestedPath = await validateImageOutputPath(out, projectRoot);
  const root = await requireProjectRoot(projectRoot);
  return secureWriteGeneratedPng(buffer, requestedPath, root, options);
}
