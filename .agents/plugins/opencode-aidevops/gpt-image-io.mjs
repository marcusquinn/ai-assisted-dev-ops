// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  link,
  lstat,
  mkdir,
  open,
  readFile,
  realpath,
  unlink,
} from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";

const MAX_REFERENCE_IMAGES = 8;
const MAX_REFERENCE_BYTES = 20 * 1024 * 1024;
const MAX_REFERENCE_TOTAL_BYTES = 50 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;
const MAX_OUTPUT_VERSION = 999;
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

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
  const root = await realpath(projectRoot);
  const stats = await lstat(root);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw new Error("OpenCode project root must be a regular directory.");
  }
  return root;
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
      throw error;
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

async function readReferenceImage(requested, root) {
  const relativePath = requireRelativePath(requested, "Reference image");
  const target = resolve(root, relativePath);
  if (!pathIsWithin(root, target)) throw new Error("Reference image escapes the project root.");
  await assertNoSymlinkSegments(root, target);
  const stats = await lstat(target);
  if (!stats.isFile() || stats.isSymbolicLink()) throw new Error(`Reference image ${relativePath} is not a regular file.`);
  const physical = await realpath(target);
  if (!pathIsWithin(root, physical)) throw new Error("Reference image resolves outside the project root.");
  const buffer = await readFile(physical);
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
    const image = await readReferenceImage(imagePath, root);
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
  if (buffer.length === 0 || buffer.length > MAX_OUTPUT_BYTES || !buffer.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)) {
    throw new Error("Image provider returned an invalid or oversized PNG.");
  }
  return buffer;
}

function versionedPath(requestedPath, version) {
  if (version === 1) return requestedPath;
  const extension = extname(requestedPath);
  const stem = basename(requestedPath, extension);
  return join(dirname(requestedPath), `${stem}-v${version}${extension}`);
}

export async function validateImageOutputPath(out, projectRoot) {
  const requested = requireRelativePath(out, "Image output");
  if (extname(requested).toLowerCase() !== ".png") {
    throw new Error("Image output must end in .png.");
  }
  if (requested.split(/[\\/]+/)[0] === ".git") {
    throw new Error("Image output cannot be written inside .git.");
  }
  const root = await requireProjectRoot(projectRoot);
  const target = resolve(root, requested);
  if (!pathIsWithin(root, target)) throw new Error("Image output escapes the project root.");
  const parent = dirname(target);
  await assertNoSymlinkSegments(root, parent);
  await mkdir(parent, { recursive: true, mode: 0o700 });
  await assertNoSymlinkSegments(root, parent);
  const physicalParent = await realpath(parent);
  if (!pathIsWithin(root, physicalParent)) throw new Error("Image output resolves outside the project root.");
  return join(physicalParent, basename(target));
}

async function writePrivateTempFile(target, buffer) {
  const tempPath = join(dirname(target), `.${basename(target)}.aidevops-${randomUUID()}.tmp`);
  const handle = await open(tempPath, "wx", 0o600);
  try {
    await handle.writeFile(buffer);
    await handle.sync();
  } finally {
    await handle.close();
  }
  return tempPath;
}

async function commitWithoutOverwrite(tempPath, requestedPath) {
  for (let version = 1; version <= MAX_OUTPUT_VERSION; version += 1) {
    const candidate = versionedPath(requestedPath, version);
    try {
      await link(tempPath, candidate);
      return { savedPath: candidate, versioned: version > 1 };
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
  }
  throw new Error(`No available image filename after ${MAX_OUTPUT_VERSION} versions.`);
}

export async function saveGeneratedPng(out, projectRoot, base64) {
  const buffer = validatePngBase64(base64);
  const requestedPath = await validateImageOutputPath(out, projectRoot);
  const tempPath = await writePrivateTempFile(requestedPath, buffer);
  try {
    return await commitWithoutOverwrite(tempPath, requestedPath);
  } finally {
    await unlink(tempPath).catch(() => {});
  }
}
