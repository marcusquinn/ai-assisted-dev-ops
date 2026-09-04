# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate bounded WebP structure for the secure GPT image writer."""

from __future__ import annotations

from typing import Optional

MAX_PIXELS = 8_294_400
IMAGE_CHUNKS = {b"VP8 ", b"VP8L"}


class WebpValidationError(Exception):
    """Represent a safe user-facing WebP validation failure."""


def validate_dimensions(width: int, height: int) -> None:
    """Reject empty or excessively large decoded WebP dimensions."""
    if width < 1 or height < 1 or width * height > MAX_PIXELS:
        raise WebpValidationError("generated WebP dimensions exceed the safe limit")


def webp_dimensions(chunk_type: bytes, chunk: bytes) -> Optional[tuple[int, int]]:
    """Read dimensions from a WebP canvas or image-data chunk."""
    if chunk_type == b"VP8X" and len(chunk) == 10:
        return 1 + int.from_bytes(chunk[4:7], "little"), 1 + int.from_bytes(chunk[7:10], "little")
    if chunk_type == b"VP8 " and len(chunk) >= 10 and chunk[3:6] == b"\x9d\x01\x2a":
        return (
            int.from_bytes(chunk[6:8], "little") & 0x3FFF,
            int.from_bytes(chunk[8:10], "little") & 0x3FFF,
        )
    if chunk_type == b"VP8L" and len(chunk) >= 5 and chunk[0] == 0x2F:
        bits = int.from_bytes(chunk[1:5], "little")
        return 1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF)
    return None


def validate_header(payload: bytes) -> None:
    """Validate the outer RIFF and WebP container headers."""
    if (
        len(payload) < 20
        or payload[:4] != b"RIFF"
        or payload[8:12] != b"WEBP"
        or int.from_bytes(payload[4:8], "little") + 8 != len(payload)
    ):
        raise WebpValidationError("image provider returned an invalid WebP")


def read_chunk(payload: bytes, offset: int) -> tuple[bytes, bytes, int]:
    """Read one bounded RIFF chunk and its padded following offset."""
    chunk_type = payload[offset : offset + 4]
    chunk_length = int.from_bytes(payload[offset + 4 : offset + 8], "little")
    chunk_end = offset + 8 + chunk_length
    if chunk_end > len(payload):
        raise WebpValidationError("image provider returned a truncated WebP chunk")
    return chunk_type, payload[offset + 8 : chunk_end], chunk_end + (chunk_length % 2)


def inspect_chunk(
    chunk_type: bytes,
    chunk: bytes,
    dimensions: Optional[tuple[int, int]],
) -> tuple[Optional[tuple[int, int]], bool]:
    """Validate one WebP chunk and return dimensions plus image-data state."""
    candidate = webp_dimensions(chunk_type, chunk)
    if candidate is None:
        if chunk_type in IMAGE_CHUNKS:
            raise WebpValidationError("image provider returned invalid WebP image data")
        return dimensions, False
    validate_dimensions(*candidate)
    if dimensions is not None and dimensions != candidate:
        raise WebpValidationError("image provider returned inconsistent WebP dimensions")
    return candidate, chunk_type in IMAGE_CHUNKS


def validate_structure(
    offset: int,
    length: int,
    dimensions: Optional[tuple[int, int]],
    saw_image_data: bool,
) -> None:
    """Validate final RIFF alignment and required WebP image data."""
    if offset != length or dimensions is None or not saw_image_data:
        raise WebpValidationError("image provider returned an invalid WebP structure")


def validate_webp(payload: bytes) -> None:
    """Validate a static WebP RIFF container, dimensions, and image-data chunk."""
    validate_header(payload)
    offset = 12
    saw_image_data = False
    dimensions: Optional[tuple[int, int]] = None
    while offset + 8 <= len(payload):
        chunk_type, chunk, offset = read_chunk(payload, offset)
        dimensions, found_image_data = inspect_chunk(chunk_type, chunk, dimensions)
        saw_image_data = saw_image_data or found_image_data
    validate_structure(offset, len(payload), dimensions, saw_image_data)
