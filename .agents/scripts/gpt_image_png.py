# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate bounded PNG structure for the secure GPT image writer."""

from __future__ import annotations

import zlib

MAX_PIXELS = 8_294_400
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


class PngValidationError(Exception):
    """Represent a safe user-facing PNG validation failure."""


def validate_png(payload: bytes) -> None:
    """Validate PNG chunks, CRCs, dimensions, and terminal structure."""
    if not payload.startswith(PNG_MAGIC):
        raise PngValidationError("image provider returned an invalid PNG")
    offset = len(PNG_MAGIC)
    chunk_index = 0
    color_type = -1
    data_state = "before"
    seen_chunks: set[bytes] = set()
    while offset + 12 <= len(payload):
        length = int.from_bytes(payload[offset : offset + 4], "big")
        end = offset + 12 + length
        if end > len(payload):
            raise PngValidationError("image provider returned a truncated PNG")
        chunk_type = payload[offset + 4 : offset + 8]
        chunk_data = payload[offset + 8 : offset + 8 + length]
        expected_crc = int.from_bytes(payload[offset + 8 + length : end], "big")
        if zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF != expected_crc:
            raise PngValidationError("image provider returned a PNG with an invalid checksum")
        if chunk_index == 0:
            color_type = validate_ihdr(chunk_type, chunk_data)
        validate_chunk_order(chunk_type, data_state, seen_chunks, color_type)
        if chunk_type == b"IDAT":
            data_state = "data"
        elif data_state == "data":
            data_state = "after"
        if chunk_type == b"IEND":
            if length != 0 or end != len(payload) or b"IDAT" not in seen_chunks:
                raise PngValidationError("image provider returned an invalid terminal PNG chunk")
            return
        seen_chunks.add(chunk_type)
        offset = end
        chunk_index += 1
    raise PngValidationError("image provider returned a PNG without a terminal chunk")


def validate_ihdr(chunk_type: bytes, data: bytes) -> int:
    """Validate the required first PNG header chunk."""
    if chunk_type != b"IHDR" or len(data) != 13:
        raise PngValidationError("image provider returned an invalid PNG header")
    width = int.from_bytes(data[0:4], "big")
    height = int.from_bytes(data[4:8], "big")
    bit_depth, color_type, compression, filtering, interlace = data[8:13]
    valid_depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8}, 4: {8, 16}, 6: {8, 16}}
    if width < 1 or height < 1 or width * height > MAX_PIXELS:
        raise PngValidationError("generated PNG dimensions exceed the safe limit")
    if bit_depth not in valid_depths.get(color_type, set()) or compression != 0 or filtering != 0 or interlace not in {0, 1}:
        raise PngValidationError("image provider returned unsupported PNG parameters")
    return color_type


def validate_chunk_order(
    chunk_type: bytes,
    data_state: str,
    seen_chunks: set[bytes],
    color_type: int,
) -> None:
    """Reject duplicate, misplaced, and unknown critical PNG chunks."""
    critical_chunks = {b"IHDR", b"PLTE", b"IDAT", b"IEND"}
    if chunk_type[0] & 0x20 == 0 and chunk_type not in critical_chunks:
        raise PngValidationError("image provider returned an unknown critical PNG chunk")
    if chunk_type == b"IHDR" and chunk_type in seen_chunks:
        raise PngValidationError("image provider returned a duplicate PNG header")
    if chunk_type == b"PLTE":
        if chunk_type in seen_chunks or data_state != "before" or color_type in {0, 4}:
            raise PngValidationError("image provider returned an invalid PNG palette")
    if chunk_type == b"IDAT":
        if data_state == "after" or (color_type == 3 and b"PLTE" not in seen_chunks):
            raise PngValidationError("image provider returned invalid PNG image-data ordering")
    if chunk_type == b"IEND" and data_state != "data":
        raise PngValidationError("image provider returned a PNG without contiguous image data")
