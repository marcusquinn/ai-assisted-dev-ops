# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate bounded JPEG structure for the secure GPT image writer."""

from __future__ import annotations

MAX_PIXELS = 8_294_400
STANDALONE_MARKERS = {0x01, *range(0xD0, 0xD8)}
FRAME_MARKERS = {
    0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
    0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
}


class JpegValidationError(Exception):
    """Represent a safe user-facing JPEG validation failure."""


def validate_dimensions(width: int, height: int) -> None:
    """Reject empty or excessively large decoded JPEG dimensions."""
    if width < 1 or height < 1 or width * height > MAX_PIXELS:
        raise JpegValidationError("generated JPEG dimensions exceed the safe limit")


def jpeg_scan_end(payload: bytes, offset: int) -> int:
    """Return the offset of the next non-stuffed JPEG marker after scan data."""
    while offset < len(payload):
        if payload[offset] != 0xFF:
            offset += 1
            continue
        marker_start = offset
        while offset < len(payload) and payload[offset] == 0xFF:
            offset += 1
        if offset >= len(payload):
            break
        marker = payload[offset]
        if marker == 0x00 or 0xD0 <= marker <= 0xD7:
            offset += 1
            continue
        return marker_start
    raise JpegValidationError("image provider returned a JPEG without a terminal marker")


def read_marker(payload: bytes, offset: int) -> tuple[int, int]:
    """Read one JPEG marker and return it with the following offset."""
    if payload[offset] != 0xFF:
        raise JpegValidationError("image provider returned invalid JPEG marker ordering")
    while offset < len(payload) and payload[offset] == 0xFF:
        offset += 1
    if offset >= len(payload):
        raise JpegValidationError("image provider returned a JPEG without a terminal marker")
    return payload[offset], offset + 1


def read_segment(payload: bytes, offset: int) -> tuple[bytes, int]:
    """Read one bounded length-prefixed JPEG segment."""
    if offset + 2 > len(payload):
        raise JpegValidationError("image provider returned an invalid JPEG marker")
    segment_length = int.from_bytes(payload[offset : offset + 2], "big")
    segment_end = offset + segment_length
    if segment_length < 2 or segment_end > len(payload):
        raise JpegValidationError("image provider returned a truncated JPEG segment")
    return payload[offset + 2 : segment_end], segment_end


def validate_frame(segment: bytes) -> None:
    """Validate dimensions from one JPEG start-of-frame segment."""
    if len(segment) < 6:
        raise JpegValidationError("image provider returned an invalid JPEG frame")
    validate_dimensions(
        int.from_bytes(segment[3:5], "big"),
        int.from_bytes(segment[1:3], "big"),
    )


def process_segment(payload: bytes, marker: int, offset: int) -> tuple[int, bool, bool]:
    """Validate one non-terminal marker and return parser-state updates."""
    if marker in STANDALONE_MARKERS:
        return offset, False, False
    if marker in {0x00, 0xD8}:
        raise JpegValidationError("image provider returned an invalid JPEG marker")
    segment, offset = read_segment(payload, offset)
    found_dimensions = marker in FRAME_MARKERS
    if found_dimensions:
        validate_frame(segment)
    found_scan = marker == 0xDA
    if found_scan:
        if len(segment) < 6:
            raise JpegValidationError("image provider returned an invalid JPEG scan")
        offset = jpeg_scan_end(payload, offset)
    return offset, found_dimensions, found_scan


def validate_terminal(offset: int, length: int, saw_dimensions: bool, saw_scan: bool) -> None:
    """Validate the final JPEG marker position and required prior segments."""
    if offset != length or not saw_dimensions or not saw_scan:
        raise JpegValidationError("image provider returned an invalid terminal JPEG marker")


def validate_jpeg(payload: bytes) -> None:
    """Validate JPEG segments, dimensions, scan presence, and terminal marker."""
    if len(payload) < 4 or payload[:2] != b"\xff\xd8":
        raise JpegValidationError("image provider returned an invalid JPEG")
    offset = 2
    saw_dimensions = False
    saw_scan = False
    while offset < len(payload):
        marker, offset = read_marker(payload, offset)
        if marker == 0xD9:
            validate_terminal(offset, len(payload), saw_dimensions, saw_scan)
            return
        offset, found_dimensions, found_scan = process_segment(payload, marker, offset)
        saw_dimensions = saw_dimensions or found_dimensions
        saw_scan = saw_scan or found_scan
    raise JpegValidationError("image provider returned a JPEG without a terminal marker")
