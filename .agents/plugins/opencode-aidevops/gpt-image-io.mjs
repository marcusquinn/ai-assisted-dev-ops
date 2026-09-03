// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  lstat,
  open,
  realpath,
} from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { secureWriteGeneratedPng } from "./gpt-image-secure-write.mjs";

const MAX_REFERENCE_IMAGES = 8;
const MAX_REFERENCE_BYTES = 20 * 1024 * 1024;
const MAX_REFERENCE_TOTAL_BYTES = 50 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const PNG_IEND = Buffer.from([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);

function pathIsWithin(parent, candidate) {
  const relation = relative(parent, candidate);
  return relation === "" || (relation !== ".." && !relation.startsWith(`..${sep}`) && !isAbsolute(relation));
}

function requireRelativePath(value, label) {
  const requested = String(value || "").trim();
  if (!requested || isAbsolute(requested) || requested.split(/[\\/]+/).includes("..")) {
    throw new Error(`${label} must be a project-relative path without parent traversal.`);
  }
  return requested;
}

async function requireProjectRoot(projectRoot) {
  try {
    const requestedRoot = resolve(projectRoot);
    const requestedStats = await lstat(requestedRoot);
    if (!requestedStats.isDirectory() || requestedStats.isSymbolicLink()) throw new Error("unsafe root");
    const root = await realpath(requestedRoot);
    const stats = await lstat(root);
    if (!stats.isDirectory() || stats.isSymbolicLink()) throw new Error("unsafe root");
    return root;
  } catch {
    throw new Error("OpenCode project root is unavailable or unsafe.");
  }
}

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

async function assertNoSymlinkSegments(root, target) {
  const relation = relative(root, target);
  let cursor = root;
  for (const segment of relation.split(sep).filter(Boolean)) {
    cursor = join(cursor, segment);
    try {
      const stats = await lstat(cursor);
      if (stats.isSymbolicLink()) throw new Error("Image paths cannot traverse symbolic links.");
    } catch (error) {
      if (error?.code === "ENOENT") return;
      if (error?.message === "Image paths cannot traverse symbolic links.") throw error;
      throw new Error("Image path is unavailable or unsafe.");
    }
  }
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
    if (error?.code) throw new Error(`Reference image ${relativePath} is unavailable or unsafe.`);
    throw error;
  } finally {
    try {
      await handle.close();
    } catch {
      throw new Error(`Reference image ${relativePath} could not be closed safely.`);
    }
  }
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
