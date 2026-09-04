// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

const JPEG_FRAME_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
  0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

function pngDimensions(buffer) {
  if (buffer.length < 24) throw new Error("Image provider returned a PNG without dimensions.");
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

function jpegDimensions(buffer) {
  let offset = 2;
  while (offset + 1 < buffer.length) {
    if (buffer[offset] !== 0xff) throw new Error("Image provider returned a JPEG without dimensions.");
    while (offset < buffer.length && buffer[offset] === 0xff) offset += 1;
    const marker = buffer[offset];
    offset += 1;
    if (marker === 0xd9) break;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > buffer.length) break;
    const segmentLength = buffer.readUInt16BE(offset);
    const segmentEnd = offset + segmentLength;
    if (segmentLength < 2 || segmentEnd > buffer.length) break;
    if (JPEG_FRAME_MARKERS.has(marker) && segmentLength >= 7) {
      return { width: buffer.readUInt16BE(offset + 5), height: buffer.readUInt16BE(offset + 3) };
    }
    offset = segmentEnd;
  }
  throw new Error("Image provider returned a JPEG without dimensions.");
}

function webpChunkDimensions(type, chunk) {
  if (type === "VP8X" && chunk.length === 10) {
    return { width: 1 + chunk.readUIntLE(4, 3), height: 1 + chunk.readUIntLE(7, 3) };
  }
  if (type === "VP8 " && chunk.length >= 10 && chunk.subarray(3, 6).equals(Buffer.from([0x9d, 0x01, 0x2a]))) {
    return { width: chunk.readUInt16LE(6) & 0x3fff, height: chunk.readUInt16LE(8) & 0x3fff };
  }
  if (type === "VP8L" && chunk.length >= 5 && chunk[0] === 0x2f) {
    const bits = chunk.readUInt32LE(1);
    return { width: 1 + (bits & 0x3fff), height: 1 + ((bits >>> 14) & 0x3fff) };
  }
  return null;
}

function webpDimensions(buffer) {
  let offset = 12;
  while (offset + 8 <= buffer.length) {
    const type = buffer.subarray(offset, offset + 4).toString("ascii");
    const length = buffer.readUInt32LE(offset + 4);
    const end = offset + 8 + length;
    if (end > buffer.length) break;
    const dimensions = webpChunkDimensions(type, buffer.subarray(offset + 8, end));
    if (dimensions) return dimensions;
    offset = end + (length % 2);
  }
  throw new Error("Image provider returned a WebP without dimensions.");
}

export function generatedImageDimensions(buffer, format) {
  if (format === "png") return pngDimensions(buffer);
  if (format === "jpeg") return jpegDimensions(buffer);
  if (format === "webp") return webpDimensions(buffer);
  throw new Error("Unsupported generated image format.");
}
